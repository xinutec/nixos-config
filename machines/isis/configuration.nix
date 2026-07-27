# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

let net = import ../../network.nix;
in {
  imports = [ ../../base-configuration.nix ];

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    kubectl # to manage kubernetes
    kubernetes-helm # to install kubernetes packages (helm charts)
    # odin's backup-prepare.sh ssh's in and runs `sqlite3 ... ".backup"` to take a
    # consistent snapshot of vaultwarden's DB. It must be present in the system
    # closure: fetching it at backup time (nix-shell -p) makes the backup depend on
    # working internet and an up binary cache — the conditions least likely to hold
    # when you need the backup to have run — and nix GC re-evicts it, so it never
    # settles. On this host that fetch was 101.6 MiB of stdenv, mid-backup.
    sqlite
  ];

  # No machine-specific PUBLIC ports. Verified against live `ss` (2026-07):
  #   2223, 28192 → nothing was listening on isis; dead leftover rules.
  networking.firewall.allowedTCPPorts = [ ];

  # List services that you want to enable:
  services.k3s = {
    enable = true;
    role = "server";
    extraFlags =
      "--disable traefik --advertise-address ${config.node.vpn} --flannel-iface=wg0 --secrets-encryption";
  };

  # List services that you want to enable:
#  services.k3s = {
#    enable = true;
#    role = "agent";
#    tokenFile = "/root/node-token";
#    serverAddr = "https://${net.nodes.master.vpn}:${toString net.k8sApiPort}";
#    extraFlags = "--node-ip ${config.node.vpn} --flannel-iface=wg0";
#  };

# fileSystems."/export/home" = {
#   device = "${net.nodes.master.vpn}:/export/home";
#   fsType = "nfs4";
# };
}
