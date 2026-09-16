# shu — the second house box, and the one the fleet is ALLOWED TO LOSE: same shape as
# geb, but REBUILT ON PURPOSE, which is the only restore drill worth anything.
# Everything lax here — intermittent, no /data, no job anyone feels — follows.

{ config, pkgs, lib, ... }:

let
  # bleak pulls in dbus-fast for the shared reader's adapter power-cycle, which shu
  # does not need (see hardware.bluetooth below) — but a second code path to save a
  # minute of radio in a ten-minute slot is not worth it.
  goveePython = pkgs.python3.withPackages (ps: with ps; [ bleak ]);
  # SMB over TCP rather than a mount: no cifs, no mount, no root namespaces.
  airvisualPython = pkgs.python3.withPackages (ps: with ps; [ smbprotocol ]);

  # shu's checkout of xinutec-infra. That repo is private and this one is public, so
  # the code cannot be fetched at eval time.
  infra = "/opt/xinutec-infra";
in
{
  imports = [
    ../../base-configuration.nix
    ./plan-run.nix
    ./plan-settings.nix
    ../../plan-fleetwatch.nix
  ];

  # Only `firewall`: the one-way VPN block moved onto this host (#1403), and without
  # this nothing would check it. A row this host cannot answer is worse than no row.
  services.planFleetwatch.plans = [ "firewall" ];

  # UEFI, not the BIOS boot base-configuration assumes for the OVH machines.
  # CSM could not be disabled outright — the boot-option filter set to "UEFI only"
  # is what settles it. On any reinstall, check /sys/firmware/efi rather than the menu.
  boot.loader.grub.enable = lib.mkForce false;
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Installed on 26.05; the fleet-wide 21.11 is amun's install version, and claiming
  # it here would assert a migration history this disk does not have.
  system.stateVersion = lib.mkForce "26.05";

  # Wifi only, via NetworkManager so the PSK stays out of this public repo. 5 GHz
  # preferred with 2.4 GHz behind it, because this box is a floor up and headless.
  # Both must be `wpa-psk`. The 2.4 GHz profile said `sae` (WPA3) against a WPA2 AP
  # for two days and could never have associated — and nmcli blames a missing network
  # while the journal says "association took too long". Trust the journal.
  networking.networkmanager.enable = true;

  # Both NetworkManager and base-configuration define this plainly, so evaluation
  # fails outright rather than warning. mkForce settles it.
  networking.useDHCP = lib.mkForce false;

  # Without this the RTL8822CE is simply not present, and there is no cable.
  hardware.enableRedistributableFirmware = true;

  # base-configuration's kube-dns entry is a cluster IP not routed over WireGuard —
  # a dead first query on every lookup. Let NetworkManager write resolv.conf.
  networking.nameservers = lib.mkForce [ ];

  # Not a build node; the buildfarm worker would restart-loop on a config file this
  # host has no reason to have.
  virtualisation.oci-containers.containers = lib.mkForce { };

  # Realtek, NOT geb's Intel: this controller does not filter duplicates, so shu
  # needs no flush and must not inherit geb's rounds by copy-paste.
  # NOTHING WITH A USB 3 LINK MAY LIVE IN THIS BOX: two SuperSpeed sticks took it
  # from 6 of 7 sensors to 1, and it reads exactly like bad siting.
  # powerOnBoot because a soft-blocked adapter looks like sensors out of range.
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  # shu is in home_receivers.py's RECEIVERS, so its silence IS a fault — correct and
  # deliberate. A rebuild turns that row red, which is a true statement about the house.
  age.secrets."home-ingest-token" = {
    file = ../../agenix/home-ingest-token.age;
    mode = "0400";
  };

  # shu ONLY — see agenix/secrets.nix for why this duplicates a Keychain value.
  age.secrets."airvisual-smb-password" = {
    file = ../../agenix/airvisual-smb-password.age;
    mode = "0400";
  };

  systemd.services.govee-push = {
    description = "Scan the Govee BLE hygrometers and push their readings to home";
    # No network ordering: readings carry their own capture time and spool on failure.
    after = [ "bluetooth.service" ];
    requires = [ "bluetooth.service" ];
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "govee-push";
      # Clone if absent and deliberately never pull: a timer that fetched every run
      # would deploy whatever was last pushed. Updating is a manual `git pull`.
      ExecStartPre = ''
        ${pkgs.bash}/bin/bash -c 'test -d ${infra} || ${pkgs.git}/bin/git clone git@github.com:xinutec/xinutec-infra.git ${infra}'
      '';
      ExecStart = "${goveePython}/bin/python3 ${infra}/shu/govee-push.py";
      User = "root";
    };
  };

  # A second pusher for the IQAir Pro, so one Mac reboot is not an outage (#1409).
  # The Pro is on the home LAN and unreachable from isis, hence pushed not pulled.
  #
  # Two pushers are free HERE and would not be for Govee: an AirVisual reading is
  # the device's own measurement with its own timestamp, so both produce the same row
  # and `INSERT IGNORE` on (device, ts) keeps one. A Govee reading is a receiver's
  # capture and each ear's row is distinct.
  # It runs mac-mini/airvisual-push.py deliberately — the script is host-agnostic and
  # a shu/ copy would be a second file to keep level for nothing.
  systemd.services.airvisual-push = {
    description = "Read the IQAir AirVisual Pro over SMB and push to home";
    # Unlike govee-push this needs the network: LAN in, WAN out.
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStartPre = ''
        ${pkgs.bash}/bin/bash -c 'test -d ${infra} || ${pkgs.git}/bin/git clone git@github.com:xinutec/xinutec-infra.git ${infra}'
      '';
      ExecStart = "${airvisualPython}/bin/python3 ${infra}/mac-mini/airvisual-push.py";
      # PATHS, not values: a secret in the environment is readable from /proc.
      Environment = [
        "AIRVISUAL_SMB_PASSWORD_FILE=/run/agenix/airvisual-smb-password"
        "HOME_INGEST_TOKEN_FILE=/run/agenix/home-ingest-token"
      ];
    };
  };

  systemd.timers.airvisual-push = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # The Mac's launchd interval is not phase-locked, so this only avoids starting
      # together most of the time. Collisions are harmless — identical readings dedup.
      OnCalendar = "*:02/5";
      AccuracySec = "30s";
    };
  };

  systemd.timers.govee-push = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Phased against the Mac's :00 and geb's :05 so rows interleave.
      OnCalendar = "*:08/10";
      # A machine that has been asleep must not stack runs.
      AccuracySec = "30s";
    };
  };
}
