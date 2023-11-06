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
    exports = "/export ${net.vpn}(rw,nohide,insecure,no_subtree_check)";
  };

  fileSystems."/home" = {
    device = "/export/home";
    options = [ "bind" ];
  };

  virtualisation.oci-containers.containers = {
    toktok = {
      image = "xinutec/toktok:latest";
      ports = [ "2223:22" ];
      extraOptions = [
        "--tmpfs=/run"
        "--tmpfs=/run/wrappers:exec,suid"
        "--tmpfs=/tmp"
      ];
      volumes = [
        "/sys/fs/cgroup:/sys/fs/cgroup"
        "${config.users.users.pippijn.home}/code/kubes/vps/toktok/home/.config/tox:/home/builder/.config/tox"
        "${config.users.users.pippijn.home}/code/kubes/vps/toktok/workspace:/src/workspace"
        "${config.users.users.pippijn.home}/.local/share/vscode/config:/src/workspace/.vscode"
        "${config.users.users.pippijn.home}/.local/share/vscode/server:/home/builder/.vscode-server"
        "${config.users.users.pippijn.home}/.local/share/zsh/toktok:/home/builder/.local/share/zsh"
      ];
    };
  };
}
