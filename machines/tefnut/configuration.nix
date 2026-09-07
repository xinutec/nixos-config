# tefnut — the third house box, and the one with NO JOB YET.
#
# Named for shu's twin. Storage-class rather than a Kubernetes node, on a home
# LAN behind the router, no public address, wifi, one-way VPN peer admitting
# only the Mac — the shape geb and shu already share.
#
# ⚠ THIS IS THE FIRST HOUSE BOX THAT IS ACTUALLY geb's TWIN. Same Quieter 4C
# board, same `Rev TWL6-DDR4 1.10`, same `ML_TWL6 V11.7` BIOS, same N150, same
# 31 GiB, same `wlp0s20f3` — and its generated hardware-configuration.nix
# differs from geb's ONLY in the two filesystem UUIDs. shu looked like a twin
# and was not (sold as an N150, actually an i3-6006U), so this was read off the
# DMI rather than inferred. Everything geb does about its hardware applies here
# unchanged; nothing shu does about ITS hardware necessarily does.
#
# ⚠ WHAT IT IS FOR IS NOT DECIDED, and that is the honest state rather than an
# unfinished edit. geb was installed with no job on 2026-08-10 and got one two
# days later; its own file is explicit that a job gets DECIDED rather than
# inherited from what the disk used to hold. Until there is one, this file
# contains only what every house box needs and nothing speculative.
#
# Everything below undoes an assumption in base-configuration.nix (three rented
# BIOS-boot machines with public addresses and a Kubernetes cluster), and every
# one of them is a line geb and shu needed too.

{ config, pkgs, lib, ... }:

let
  # The Govee pusher's runtime. bleak pulls in dbus-fast, which the shared reader
  # uses to power-cycle the adapter between scan rounds — needed HERE, because
  # this is geb's Intel controller and not shu's Realtek one.
  goveePython = pkgs.python3.withPackages (ps: with ps; [ bleak ]);

  # tefnut's checkout of xinutec-infra, where the pusher and the shared modules
  # live. That repository is private and this one is public, so the code cannot
  # be fetched at evaluation time — every other machine's `nixos-rebuild` would
  # then need credentials it has no reason to hold. Cloned with tefnut's own
  # read-only deploy key at /root/.ssh/id_github_infra, mapped to github.com by
  # base-configuration's ssh_config.
  infra = "/opt/xinutec-infra";
in
{
  imports = [
    ../../base-configuration.nix
    ./plan-run.nix
    ./plan-settings.nix
    ../../plan-fleetwatch.nix
  ];

  # ⚠ ONE PLAN, and it is here because the thing it judges is here. tefnut is a
  # `oneWay` node, so base-configuration generates the block that keeps the VPN
  # out of the house onto THIS host's own INPUT chain — and from install until
  # 2026-09-07 nothing on the machine checked that it was still there.
  #
  # No other plan: this host is not a Kubernetes node, drives no backups of its
  # own and pushes no cabinets. A row it cannot answer is worse than no row.
  services.planFleetwatch.plans = [ "firewall" ];

  # UEFI, not BIOS. base-configuration sets `boot.loader.grub.device` for the
  # OVH machines. Verified at install rather than assumed: /sys/firmware/efi
  # was present, efivars mounted, fw_platform_size 64.
  #
  # ⚠ The firmware boots USB before the internal disk, and offers no obvious
  # way to say otherwise from the one-shot menu — F7 picks the NVMe for one
  # boot only. A stick left plugged in takes over the boot silently, which on a
  # headless box reads as "it did not come back up".
  boot.loader.grub.enable = lib.mkForce false;
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Installed on 26.05, 2026-09-06. The fleet-wide 21.11 in base-configuration is
  # amun's install version; stateVersion pins the stateful defaults a machine was
  # BUILT with, and claiming 21.11 on a disk formatted in 2026 asserts a
  # migration history it does not have.
  system.stateVersion = lib.mkForce "26.05";

  # Wifi only, so NetworkManager owns the link and the connection profile is
  # machine state in /etc/NetworkManager/system-connections — deliberately NOT a
  # declarative networking.wireless block, which would want the PSK in a Nix
  # file and this repository is public.
  #
  # TWO profiles, because the question about where it sits is now answered:
  # upstairs in the guest room, beside the thermometer there. That is shu's
  # situation, so it gets shu's arrangement — 5 GHz at autoconnect-priority 10,
  # 2.4 GHz at 5 behind it.
  #
  # ⚠ THE PROFILE COPIED FROM shu WAS BROKEN, and testing it is the only reason
  # that is known. It specified `key-mgmt=sae` (WPA3) while the 2.4 GHz AP
  # advertises WPA2, so association timed out every time. See the note in
  # machines/shu/configuration.nix. Both are `wpa-psk` now and both were
  # exercised on the machine rather than assumed.
  networking.networkmanager.enable = true;

  # ⚠ Both NetworkManager and base-configuration define this as plain
  # definitions, so the module system cannot pick one and evaluation fails
  # outright rather than warning. mkForce settles it in NetworkManager's favour.
  networking.useDHCP = lib.mkForce false;

  # The iwlwifi adapter does not exist without this, the connection profile has
  # nothing to bind to, and there is no cable to fall back on. Same part as
  # geb's, so same requirement.
  hardware.enableRedistributableFirmware = true;

  # base-configuration points every host at kube-dns (10.43.0.10) and OVH's
  # resolver: the first is a cluster service IP not routed over WireGuard, so it
  # is a dead first query on every lookup, and the second is only near the
  # rented machines. Let NetworkManager write resolv.conf from DHCP.
  networking.nameservers = lib.mkForce [ ];

  # Not a build node. base-configuration runs a buildfarm worker on every host,
  # mounting ~/.config/buildfarm/${config.node.name}.yml — a file tefnut has no
  # reason to have, so the container would restart-loop indefinitely.
  virtualisation.oci-containers.containers = lib.mkForce { };

  # The radio for the Govee scan. Enabled 2026-09-07, when the job was assigned:
  # tefnut stays online as a thermometer receiver.
  #
  # ⚠ THIS IS geb's CONTROLLER, NOT shu's, and the difference decides how the
  # reader must work. Read off dmesg rather than inferred: tefnut reports
  # `Device revision is 2` and `Bootloader timestamp 2019.40 buildtype 1 build
  # 38`, byte-identical to geb's lines, where shu reports `RTL: lmp_subver=8822`.
  # geb's Intel controller hears each sensor ONCE and is then deaf to it until
  # the duplicate table is flushed — which is what `LINUX_ROUNDS` in
  # xinutec-infra exists for. Removing the flush does not degrade the reading on
  # that controller, it silently ENDS it. So tefnut's pusher is modelled on geb's
  # and must not inherit shu's flushless assumption by copy-paste.
  #
  # `powerOnBoot` because the only consumer is a passive advertisement scan: an
  # adapter that comes up soft-blocked reads exactly like a sensor out of range,
  # and this box is headless.
  #
  # ⚠ NOTHING WITH A USB 3 LINK MAY LIVE IN THIS BOX while it is a BLE receiver.
  # Measured on shu: two SuperSpeed sticks took it from 6 of 7 sensors to 1 of 7,
  # and it reads exactly like bad siting.
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  # Ingest token, decrypted at activation with tefnut's own host key. The pusher
  # reads this exact path; there is no fallback, because a receiver that quietly
  # finds some other token pushes nowhere.
  age.secrets."home-ingest-token" = {
    file = ../../agenix/home-ingest-token.age;
    mode = "0400";
  };

  # The house's FIFTH Govee receiver, after the Mac, the pixel5, geb and shu.
  #
  # ⚠ IT DOES NOT CLOSE THE GAP THAT EXISTS, and that was measured before it was
  # built. Union over six 60 s scans from where it sits, 2026-09-07: five of
  # seven — A562 6/6 at -65, B7AC 5/6 at -75, 014E 4/6 at -89, 525D 1/6 at -90,
  # 0345 1/6 at -91. It does NOT hear 251B or 267F, and 267F is precisely the
  # sensor with fewest ears (Mac, pixel5, shu — one of them a phone that has gone
  # flat twice). Every sensor tefnut hears already had four. So this is a fifth
  # ear on well-covered sensors, run because redundancy is the goal and a
  # listening machine costs nothing — not because the numbers asked for it.
  #
  # ⚠ THAT MEASUREMENT DESCRIBES ONE ROOM. tefnut is in Pippijn's room because
  # the guest room is occupied; the guest room may still be where it ends up.
  # Reach is a property of position — re-measure if it moves, and do not carry
  # these figures across.
  systemd.services.govee-push = {
    description = "Scan the Govee BLE hygrometers and push their readings to home";
    # Bluetooth is the whole job, and the pusher stamps each reading with its own
    # capture time and spools on failure, so it does not wait on the network: a
    # run during a router reboot buffers and replays.
    after = [ "bluetooth.service" ];
    requires = [ "bluetooth.service" ];
    serviceConfig = {
      Type = "oneshot";
      # /var/lib/govee-push — the store-and-forward buffer, which must outlive a
      # reboot to be worth anything.
      StateDirectory = "govee-push";
      # Clone if absent, and deliberately never pull: a timer that fetched code
      # every run would deploy whatever was last pushed, half-finished or not.
      # Updating tefnut is `git -C /opt/xinutec-infra pull`, on purpose — and it
      # is the step that bit both geb and shu on their first day (#1403).
      ExecStartPre = ''
        ${pkgs.bash}/bin/bash -c 'test -d ${infra} || ${pkgs.git}/bin/git clone git@github.com:xinutec/xinutec-infra.git ${infra}'
      '';
      ExecStart = "${goveePython}/bin/python3 ${infra}/tefnut/govee-push.py";
      # Powering the adapter off and on between scan rounds is a system-wide BlueZ
      # operation, and reading the agenix secret needs root anyway.
      User = "root";
    };
  };

  systemd.timers.govee-push = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # The :02 phase, against the Mac's :00, geb's :05 and shu's :08, so the
      # receivers' rows interleave rather than landing together.
      OnCalendar = "*:02/10";
      # A run is four flushed scan rounds plus delivery — comfortably inside the
      # ten-minute slot, but a machine that has been asleep must not stack them.
      AccuracySec = "30s";
    };
  };
}
