# shu — the second house box, and the one the fleet is ALLOWED TO LOSE.
#
# Storage-class rather than a Kubernetes node, so odin's sentence in network.nix
# ("Backup machine. No Kubernetes, only storage") is the closest existing shape,
# and geb is the closest existing machine: a home LAN behind the router, no
# public address, wifi, one-way VPN peer admitting only the Mac.
#
# ⚠ WHAT MAKES IT DIFFERENT FROM geb IS NOT THE HARDWARE, IT IS THE PROMISE.
# geb must not go quietly down, because it holds backups. shu is REBUILT ON
# PURPOSE: a restore drill against a machine that was really doing something is
# the only kind that proves anything, and a staging box with synthetic data
# proves the mechanism rather than the recovery. Everything here that looks
# lax — `intermittent = true` in network.nix, no /data, a job whose absence
# nobody feels — follows from that and is not an omission.
#
# Everything below undoes an assumption in base-configuration.nix (three rented
# BIOS-boot machines with public addresses and a Kubernetes cluster), and every
# one of them is a line geb needed too.

{ config, pkgs, lib, ... }:

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

  # UEFI, not BIOS. base-configuration sets `boot.loader.grub.device` for the
  # OVH machines. Verified at install rather than assumed: /sys/firmware/efi was
  # present and efivars writable.
  #
  # ⚠ The firmware would NOT let CSM be disabled outright — the boot-option
  # filter set to "UEFI only" is what actually settles it, and the installer
  # booted in legacy mode first because the firmware offers the same USB stick
  # twice. If this box is ever reinstalled, check /sys/firmware/efi before
  # trusting the menu.
  boot.loader.grub.enable = lib.mkForce false;
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Installed on 26.05, 2026-09-04. The fleet-wide 21.11 in base-configuration is
  # amun's install version; stateVersion pins the stateful defaults a machine was
  # BUILT with, and claiming 21.11 on a disk formatted in 2026 asserts a
  # migration history it does not have.
  system.stateVersion = lib.mkForce "26.05";

  # Wifi only, so NetworkManager owns the link and the connection profile is
  # machine state in /etc/NetworkManager/system-connections — deliberately NOT a
  # declarative networking.wireless block, which would want the PSK in a Nix
  # file and this repository is public.
  #
  # Two profiles live there: 5 GHz preferred (it associates at -63 dBm from
  # where it sits) and 2.4 GHz behind it, because this box is a floor up and a
  # headless machine that cannot associate is a trip to a monitor.
  networking.networkmanager.enable = true;

  # ⚠ Both NetworkManager and base-configuration define this as plain
  # definitions, so the module system cannot pick one and evaluation fails
  # outright rather than warning. mkForce settles it in NetworkManager's favour.
  networking.useDHCP = lib.mkForce false;

  # The RTL8822CE (rtw88) needs redistributable firmware. Without it the adapter
  # is simply not present, the connection profile has nothing to bind to, and
  # there is no cable to fall back on.
  hardware.enableRedistributableFirmware = true;

  # base-configuration points every host at kube-dns (10.43.0.10) and OVH's
  # resolver: the first is a cluster service IP not routed over WireGuard, so it
  # is a dead first query on every lookup, and the second is only near the
  # rented machines. Let NetworkManager write resolv.conf from DHCP.
  networking.nameservers = lib.mkForce [ ];

  # Not a build node. base-configuration runs a buildfarm worker on every host,
  # mounting ~/.config/buildfarm/${config.node.name}.yml — a file shu has no
  # reason to have, so the container would restart-loop indefinitely.
  virtualisation.oci-containers.containers = lib.mkForce { };

  # The Realtek half of the RTL8822CE, for the Govee scan.
  #
  # ⚠ THIS ADAPTER DOES NOT BEHAVE LIKE geb's. geb has Intel `btintel`, whose
  # controller reports each sensor once and then goes deaf until the duplicate
  # table is flushed — which is what `LINUX_ROUNDS` in xinutec-infra exists for.
  # Measured here 2026-09-04: one uninterrupted 60 s scan, no flush, reported
  # A562 nine times, 525D nine and B7AC five, spread over 52 s. So shu needs no
  # flushing, and must not inherit geb's rounds by copy-paste.
  #
  # ⚠ AND NOTHING WITH A USB 3 LINK MAY LIVE IN THIS BOX while it is a BLE
  # receiver. Measured the same day: with two SuperSpeed sticks plugged in, the
  # strong sensor came through at an unchanged rate while ALL FIVE weaker ones
  # vanished — 6 of 7 sensors became 1 of 7. Textbook desensitisation, and it
  # reads exactly like bad siting.
  #
  # powerOnBoot because the only consumer is a passive advertisement scan: an
  # adapter that comes up soft-blocked reads exactly like a sensor out of range,
  # and this box is headless.
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };
}
