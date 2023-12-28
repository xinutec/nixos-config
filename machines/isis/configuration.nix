# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

let net = import ../../network.nix;
in {
  imports = [ ../../base-configuration.nix ];

  # List services that you want to enable:
  services.k3s = {
    enable = true;
    role = "agent";
    tokenFile = "/root/node-token";
    serverAddr = "https://${net.nodes.master.vpn}:${toString net.k8sApiPort}";
    extraFlags = "--node-ip ${config.node.vpn} --flannel-iface=wg0";
  };

  fileSystems."/export" = {
    device = "${net.nodes.master.vpn}:/export";
    fsType = "nfs4";
  };

  virtualisation.oci-containers.containers = {
    buildfarm-worker = {
      image = "toxchat/buildfarm-worker";
      extraOptions = [ "--network=host" ];
      volumes = [
        "${config.users.users.pippijn.home}/.config/buildfarm/${config.node.name}.yml:/app/build_buildfarm/examples/config.minimal.yml"
      ];
    };
  };
}
