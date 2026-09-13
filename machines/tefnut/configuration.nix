# tefnut — the third house box. geb's actual hardware twin (same board, BIOS, CPU
# and wifi chip), so geb's answers transfer here; shu's do not, it only looked alike.
#
# Everything below undoes a base-configuration assumption that suits the three rented
# machines and not a house box. geb and shu needed each of these too.

{ config, pkgs, lib, ... }:

let
  # bleak pulls in dbus-fast, which the reader needs to power-cycle this Intel
  # adapter between scan rounds.
  goveePython = pkgs.python3.withPackages (ps: with ps; [ bleak ]);

  # tefnut's checkout of xinutec-infra. That repo is private and this one is public,
  # so the code cannot be fetched at eval time. Cloned with tefnut's own deploy key.
  infra = "/opt/xinutec-infra";
in
{
  imports = [
    ../../base-configuration.nix
    ./plan-run.nix
    ./plan-settings.nix
    ../../plan-fleetwatch.nix
  ];

  # Only `firewall`, because it is the only thing here to judge: this host's oneWay
  # INPUT chain. A row this host cannot answer would be worse than no row.
  services.planFleetwatch.plans = [ "firewall" ];

  # UEFI, not the BIOS boot base-configuration assumes for the OVH machines.
  # ⚠ The firmware boots USB before the internal disk and offers no way to say
  # otherwise — a stick left plugged in reads as "it did not come back up" (#1469).
  boot.loader.grub.enable = lib.mkForce false;
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Installed on 26.05; the fleet-wide 21.11 is amun's install version, and claiming
  # it here would assert a migration history this disk does not have.
  system.stateVersion = lib.mkForce "26.05";

  # Wifi only, via NetworkManager so the PSK stays out of this public repo. Two
  # profiles: 5 GHz at priority 10, 2.4 GHz behind it.
  # ⚠ Both must be `wpa-psk`. shu's copied profile said `sae` (WPA3) and the 2.4 GHz
  # AP is WPA2, so association timed out every time.
  networking.networkmanager.enable = true;

  # ⚠ Both NetworkManager and base-configuration define this plainly, so evaluation
  # fails outright rather than warning. mkForce settles it.
  networking.useDHCP = lib.mkForce false;

  # Without this the iwlwifi adapter does not exist, and there is no cable.
  hardware.enableRedistributableFirmware = true;

  # base-configuration's kube-dns entry is a cluster IP not routed over WireGuard —
  # a dead first query on every lookup. Let NetworkManager write resolv.conf.
  networking.nameservers = lib.mkForce [ ];

  # Not a build node; the buildfarm worker would restart-loop on a config file this
  # host has no reason to have.
  virtualisation.oci-containers.containers = lib.mkForce { };

  # ⚠ geb's Intel controller, NOT shu's Realtek: it hears each sensor ONCE and is
  # then deaf until the duplicate table is flushed. Dropping that flush does not
  # degrade the reading, it silently ENDS it — so model this pusher on geb's.
  # ⚠ NOTHING WITH A USB 3 LINK MAY LIVE IN THIS BOX: on shu, two SuperSpeed sticks
  # took it from 6 of 7 sensors to 1, and it reads exactly like bad siting.
  # powerOnBoot because a soft-blocked adapter looks like sensors out of range.
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  # The pusher reads this exact path with no fallback — a receiver that quietly
  # found some other token would push nowhere.
  age.secrets."home-ingest-token" = {
    file = ../../agenix/home-ingest-token.age;
    mode = "0400";
  };

  # A Govee receiver. Reach is a property of position — re-measure if it moves (#1469).
  systemd.services.govee-push = {
    description = "Scan the Govee BLE hygrometers and push their readings to home";
    # No network ordering: readings are stamped with their own capture time and spool
    # on failure, so a run during a router reboot buffers and replays.
    after = [ "bluetooth.service" ];
    requires = [ "bluetooth.service" ];
    serviceConfig = {
      Type = "oneshot";
      # The store-and-forward buffer, which must outlive a reboot.
      StateDirectory = "govee-push";
      # Clone if absent and deliberately never pull: a timer that fetched every run
      # would deploy whatever was last pushed. Updating is a manual `git pull`.
      ExecStartPre = ''
        ${pkgs.bash}/bin/bash -c 'test -d ${infra} || ${pkgs.git}/bin/git clone git@github.com:xinutec/xinutec-infra.git ${infra}'
      '';
      ExecStart = "${goveePython}/bin/python3 ${infra}/tefnut/govee-push.py";
      # Power-cycling the adapter is system-wide, and the secret needs root anyway.
      User = "root";
    };
  };

  systemd.timers.govee-push = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Phased against the Mac's :00, geb's :05 and shu's :08 so rows interleave.
      OnCalendar = "*:02/10";
      # A machine that has been asleep must not stack runs.
      AccuracySec = "30s";
    };
  };
}
