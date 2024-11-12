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

  networking.firewall.allowedTCPPorts = [ 2223 28192 ];

  # List services that you want to enable:
  services.k3s = {
    enable = true;
    role = "server";
    extraFlags =
      "--disable traefik --advertise-address ${config.node.vpn} --flannel-iface=wg0";
  };

  services.nfs.server = {
    enable = true;
    exports = ''
      /export/home ${net.nodes.isis.vpn}(rw,nohide,insecure,no_subtree_check) ${net.nodes.odin.vpn}(rw,nohide,insecure,no_subtree_check)
      /export/home/pi ${net.vpn}(rw,nohide,insecure,no_subtree_check)
    '';
  };

  fileSystems."/home" = {
    device = "/export/home";
    options = [ "bind" ];
  };

  virtualisation.oci-containers.containers = {
    buildfarm-server = {
      image = "toxchat/buildfarm-server";
      extraOptions = [ "--network=host" ];
      volumes = [
        "${config.users.users.pippijn.home}/.config/buildfarm/server.yml:/app/build_buildfarm/config.minimal.yml"
      ];
    };
  };
}
