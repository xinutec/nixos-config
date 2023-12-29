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

  fileSystems."/export/home" = {
    device = "${net.nodes.master.vpn}:/export/home";
    fsType = "nfs4";
  };

  virtualisation.oci-containers.containers = {
    toktok = {
      image = "xinutec/toktok:latest";
      ports = [ "2223:22" ];
      extraOptions = [
        "--tmpfs=/run"
        "--tmpfs=/run/wrappers:exec,suid"
        "--tmpfs=/tmp:exec"
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
