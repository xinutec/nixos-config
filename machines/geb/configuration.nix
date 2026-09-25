# geb — the house's own NixOS box: storage, one-way peer, home LAN, no public address,
# on wifi. Its distinguishing job is the microphone for recall
# (./recall-recorder.nix), so the wifi link is the path the audio crosses.

{ config, pkgs, lib, ... }:

let
  # bleak pulls in dbus-fast, which the reader uses to power-cycle the adapter
  # between scan rounds.
  goveePython = pkgs.python3.withPackages (ps: with ps; [ bleak ]);

  # geb's checkout of xinutec-infra. That repo is private and this one is public, so
  # it cannot be fetched at eval time — every other machine's `nixos-rebuild` would
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

  # UEFI, not the BIOS grub base-configuration sets for the OVH machines.
  boot.loader.grub.enable = lib.mkForce false;
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Installed on 26.05. It pins the stateful defaults this machine was BUILT with,
  # so it is not base-configuration's 21.11, which is amun's install version.
  system.stateVersion = lib.mkForce "26.05";

  # Wifi only, via NetworkManager so the PSK stays out of this public repo.
  networking.networkmanager.enable = true;

  # ⚠ NetworkManager and base-configuration both define this as a plain definition,
  # so evaluation FAILS rather than warning. mkForce gives it to NetworkManager.
  networking.useDHCP = lib.mkForce false;

  # iwlwifi needs redistributable firmware; without it the adapter is not present
  # at all, and this box has no cable.
  hardware.enableRedistributableFirmware = true;

  # NetworkManager writes resolv.conf from DHCP. base-configuration's kube-dns
  # (10.43.0.10) is not routed over WireGuard — a dead first query on every lookup —
  # and its OVH resolver is only near the rented machines.
  networking.nameservers = lib.mkForce [ ];

  # Not a build node: base-configuration's buildfarm worker mounts
  # ~/.config/buildfarm/${config.node.name}.yml, which geb has no reason to have, so
  # the container would restart-loop.
  virtualisation.oci-containers.containers = lib.mkForce { };

  # The 6 TB WD Elements. Here rather than in hardware-configuration.nix, which a
  # regeneration would drop; by UUID because sd* names follow enumeration order.
  # ⚠ `nofail`: without it an absent or slow USB disk stops the boot in emergency
  # mode, on a headless machine.
  fileSystems."/data" =
    { device = "/dev/disk/by-uuid/2099398b-e6b1-4f31-9096-54a51edda1b3";
      fsType = "ext4";
      options = [ "nofail" "x-systemd.device-timeout=30" ];
    };

  # powerOnBoot: a soft-blocked adapter reads exactly like sensors out of range.
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  # A Govee receiver, and the one that is always on, on mains, and doing nothing
  # else — which is the point: the Mac hears nothing from the up-floor sensors,
  # so without a fixed receiver up there a phone is the sole ear for three rooms.
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
      # 75 is govee.AdapterWedged: bluetoothd stopped powering the adapter under
      # the scan's power-cycles, and only a restart clears it.
      ExecStopPost = pkgs.writeShellScript "govee-bluetooth-recover" ''
        [ "$EXIT_STATUS" != 75 ] && exit 0
        echo "bluetoothd wedged: restarting bluetooth.service" >&2
        # --no-block: this unit Requires= bluetooth, so waiting on the restart
        # from inside its own stop would wait on itself.
        ${pkgs.systemd}/bin/systemctl restart --no-block bluetooth.service
      '';
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
