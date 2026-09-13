# geb — the house's own NixOS box: storage, one-way peer, home LAN, no public address,
# on wifi. Most of what follows undoes a base-configuration assumption that suits the
# three rented machines and not a house box.
#
# Its distinguishing job is the microphone for recall (./recall-recorder.nix) — which
# is why the wifi link is worth caring about: it is the path the audio crosses.

{ config, pkgs, lib, ... }:

let
  # The Govee pusher's runtime. bleak pulls in dbus-fast, which is what the
  # reader uses to power-cycle the adapter between scan rounds.
  goveePython = pkgs.python3.withPackages (ps: with ps; [ bleak ]);

  # geb's checkout of xinutec-infra, where the pusher and the shared modules
  # live. That repository is private and this one is public, so the code cannot
  # be fetched at evaluation time — every other machine's `nixos-rebuild` would
  # then need credentials it has no reason to hold.
  infra = "/opt/xinutec-infra";
in
{
  imports = [
    ../../base-configuration.nix
    ./plan-run.nix
    ./plan-settings.nix
    ../../plan-fleetwatch.nix
    ./recall-recorder.nix
  ];

  # Only `firewall`: the one-way VPN block moved onto this host (#1403), and without
  # this nothing would check it. A row this host cannot answer is worse than no row.
  services.planFleetwatch.plans = [ "firewall" ];

  # UEFI, not BIOS. base-configuration sets `boot.loader.grub.device =
  # "/dev/sda"` for the OVH machines. This box shipped with Windows 11, which
  # cannot be installed on anything but UEFI, so it is UEFI with certainty —
  # confirmed at install by /sys/firmware/efi being present.
  boot.loader.grub.enable = lib.mkForce false;
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Installed on 26.05, 2026-08-10. The fleet-wide 21.11 in base-configuration
  # is amun's install version; stateVersion is not "which NixOS is this", it
  # pins the stateful defaults a machine was BUILT with, and claiming 21.11 on
  # a disk formatted in 2026 asserts a migration history it does not have.
  system.stateVersion = lib.mkForce "26.05";

  # Wifi only, via NetworkManager so the PSK stays out of this public repo.
  networking.networkmanager.enable = true;

  # Both NetworkManager and base-configuration define this, and both do it as
  # plain definitions, so the module system cannot pick one and evaluation
  # fails outright rather than warning. mkForce settles it in NetworkManager's
  # favour, which is what "NM owns the link" means.
  networking.useDHCP = lib.mkForce false;

  # iwlwifi needs redistributable firmware. Without it the adapter is simply
  # not present and the connection profile has nothing to bind to — a headless
  # box with no cable and no wifi is one you carry back to a monitor.
  hardware.enableRedistributableFirmware = true;

  # Let NetworkManager write resolv.conf from DHCP. base-configuration points
  # every host at kube-dns (10.43.0.10) and OVH's resolver: the first is a
  # cluster service IP that is not routed over WireGuard, so it is a dead first
  # query on every lookup, and the second is only near the rented machines.
  networking.nameservers = lib.mkForce [ ];

  # Not a build node. base-configuration runs a buildfarm worker on every host,
  # mounting ~/.config/buildfarm/${config.node.name}.yml — a file geb has no
  # reason to have, so the container would restart-loop indefinitely.
  virtualisation.oci-containers.containers = lib.mkForce { };

  # The 6 TB WD Elements, here rather than in the generated hardware-configuration.nix,
  # which a regeneration would drop. By UUID because sd* names follow enumeration order.
  # `nofail`: geb is headless, and without it an absent or slow USB disk stops the
  # boot in emergency mode on a machine that cannot show you why.
  fileSystems."/data" =
    { device = "/dev/disk/by-uuid/2099398b-e6b1-4f31-9096-54a51edda1b3";
      fsType = "ext4";
      options = [ "nofail" "x-systemd.device-timeout=30" ];
    };

  # powerOnBoot because a soft-blocked adapter reads exactly like sensors out of range,
  # and this box is headless.
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  # The house's third Govee receiver, after the Mac and the pixel5 phone. It is
  # the only one of the three that is always on, on mains, and doing nothing
  # else — which is the point: measured 2026-08-09 the Mac hears nothing from
  # the up-floor sensors, so the phone was the sole receiver for three rooms.
  #
  # Ingest token, decrypted at activation with geb's own host key. The pusher
  # reads this exact path; there is no fallback, because a receiver that quietly
  # finds some other token pushes nowhere.
  age.secrets."home-ingest-token" = {
    file = ../../agenix/home-ingest-token.age;
    mode = "0400";
  };

  systemd.services.govee-push = {
    description = "Scan the Govee BLE hygrometers and push their readings to home";
    # Bluetooth is the whole job, and the pusher stamps each reading with its
    # own capture time and spools on failure, so it does not wait on the
    # network: a run during a router reboot buffers and replays.
    after = [ "bluetooth.service" ];
    requires = [ "bluetooth.service" ];
    serviceConfig = {
      Type = "oneshot";
      # /var/lib/govee-push — the store-and-forward buffer, which must outlive
      # a reboot to be worth anything.
      StateDirectory = "govee-push";
      # Clone if absent, and deliberately never pull: a timer that fetched code
      # every run would deploy whatever was last pushed, half-finished or not.
      # Updating geb is `git -C /opt/xinutec-infra pull`, on purpose.
      ExecStartPre = ''
        ${pkgs.bash}/bin/bash -c 'test -d ${infra} || ${pkgs.git}/bin/git clone git@github.com:xinutec/xinutec-infra.git ${infra}'
      '';
      ExecStart = "${goveePython}/bin/python3 ${infra}/geb/govee-push.py";
      # Powering the adapter off and on between scan rounds is a system-wide
      # BlueZ operation, and reading the agenix secret needs root anyway.
      User = "root";
    };
  };

  systemd.timers.govee-push = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # The :05 phase, against the Mac's :00/:10/:20…, so the two receivers'
      # rows interleave rather than landing together.
      OnCalendar = "*:05/10";
      # A run is four flushed scan rounds plus delivery — comfortably inside the
      # ten-minute slot, but a machine that has been asleep must not stack them.
      AccuracySec = "30s";
    };
  };
}
