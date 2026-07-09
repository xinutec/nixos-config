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
  ];

  # No machine-specific PUBLIC ports. Verified against live `ss` (2026-07):
  #   2223, 28192 → nothing was listening on isis; dead leftover rules.
  networking.firewall.allowedTCPPorts = [ ];

  # Let the Mac's reverse SSH tunnel (recall-tunnel) bind the recall web app on
  # this host's WireGuard address (10.100.0.2:8000) for VPN peers. The Mac is a
  # one-way WG peer and must dial out; `clientspecified` lets its `ssh -R` choose
  # the WG bind address. The public NIC stays closed (allowedTCPPorts = [] above),
  # so this cannot expose anything off-VPN — WireGuard peers are the only reach.
  services.openssh.settings.GatewayPorts = "clientspecified";

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
