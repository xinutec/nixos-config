# geb — the house's own NixOS box. Storage, and a one-way VPN peer.
#
# Not a rented server and not a Kubernetes node: odin's sentence in network.nix
# ("Backup machine. No Kubernetes, only storage") is the closest existing shape.
# What it does NOT share with odin is where it sits — geb is on a home LAN
# behind the router, with no public address, and on wifi rather than ethernet.
#
# Everything below is a place where base-configuration.nix's assumptions — three
# rented BIOS-boot machines with public addresses and a Kubernetes cluster —
# had to be undone. Nothing here is geb's own feature: what geb is FOR — the
# fleet's third backup location and the house's third Govee receiver — is served
# by jobs on the Mac and by govee-push, not by anything in this file.

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
  ];

  # ⚠ ONE PLAN, and it is here because the thing it judges is here. The one-way
  # VPN block moved off the servers onto this host on 2026-09-04 (#1403), and
  # `plan-run` existed only on odin and isis — so without this the control that
  # keeps the VPN out of the house would be checked by nothing at all.
  #
  # No other plan: this host is not a Kubernetes node, drives no backups of its
  # own and pushes no cabinets. A row it cannot answer is worse than no row.
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

  # The only link today is wifi, so the machine is managed by NetworkManager
  # and its connection profile is machine state in
  # /etc/NetworkManager/system-connections — deliberately NOT a declarative
  # networking.wireless block, which would want the PSK in a Nix file and this
  # repository is public.
  networking.networkmanager.enable = true;

  # ⚠ Both NetworkManager and base-configuration define this, and both do it as
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

  # The 6 TB WD Elements freed from the Mac by #697 and reformatted ext4 here on
  # 2026-08-12. It lives in configuration.nix, not hardware-configuration.nix,
  # because the latter is generated and a regeneration would drop this.
  #
  # By UUID: the disk is USB, and sd* names are assigned in enumeration order,
  # so a second external device would silently swap them.
  #
  # ⚠ `nofail` because geb is headless on wifi with no monitor attached. Without
  # it, a disk that is unplugged, spun down or slow to enumerate stops the boot
  # in emergency mode on a machine that cannot show you why. The device timeout
  # bounds the wait rather than leaving it to the 90 s default, since a spinning
  # USB disk that is not there is not going to appear.
  fileSystems."/data" =
    { device = "/dev/disk/by-uuid/2099398b-e6b1-4f31-9096-54a51edda1b3";
      fsType = "ext4";
      options = [ "nofail" "x-systemd.device-timeout=30" ];
    };

  # The Intel AX combo card's other half. Enabled to find out whether geb can
  # hear the house's Govee hygrometers, which is a question about where it sits,
  # not about the radio — so it has to be measured from here rather than argued.
  #
  # `powerOnBoot` because the only consumer is a passive advertisement scan: an
  # adapter that comes up soft-blocked reads exactly like a sensor out of range,
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
