# geb — the house's own NixOS box. Storage, and a one-way VPN peer.
#
# Not a rented server and not a Kubernetes node: odin's sentence in network.nix
# ("Backup machine. No Kubernetes, only storage") is the closest existing shape.
# What it does NOT share with odin is where it sits — geb is on a home LAN
# behind the router, with no public address, and today no cable either.
#
# Everything below is a place where base-configuration.nix's assumptions — three
# rented BIOS-boot machines with public addresses and a Kubernetes cluster —
# had to be undone. There is nothing here that is yet geb's own feature, because
# what geb is FOR is still open (#726).

{ config, pkgs, lib, ... }:

{
  imports = [ ../../base-configuration.nix ];

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
}
