# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

let
  net = import ./network.nix;
  sshKeys = import ./ssh-keys.nix;
in {
  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
    ./options.nix
    <home-manager/nixos>
  ];

  system.stateVersion = "21.11";
  nix = {
    gc.automatic = true;
    optimise.automatic = true;
  };

  # Define on which hard drive you want to install Grub.
  boot.loader.grub.device = "/dev/sda";

  boot.cleanTmpDir = true;
  zramSwap.enable = true;

  virtualisation.docker = {
    enable = true;
    extraOptions = "--config-file=${
        pkgs.writeText "daemon.json" (builtins.toJSON {
          ipv6 = true;
          "fixed-cidr-v6" = "fd00::/80";
        })
      }";
  };

  programs.mosh.enable = true;
  programs.zsh.enable = true;

  programs.neovim = {
    enable = true;
    viAlias = true;
  };

  networking = {
    enableIPv6 = true;
    useDHCP = true;
#   dhcpcd.extraConfig = "static ip6_address=${config.node.ipv6}";

    # Resolve hostnames in domain.
    search = [ config.networking.domain ];
    nameservers = [
      "10.43.0.10" # kube-dns.kube-system.svc.cluster.local
      "213.186.33.99" # cdns.ovh.net
    ];
    hostName = config.node.name; # Define your hostname.
    domain = "xinutec.org";

#    # enable NAT
#    nat = {
#      enable = true;
#      externalInterface = "eth0";
#      internalInterfaces =
#        builtins.attrNames config.networking.wireguard.interfaces;
#    };

    firewall = {
      enable = true;

      # No need for explicitly allowing ports here. Kubernetes takes care of
      # opening ports as needed. We only need 10250 (kubelet) and the Wireguard port.
      allowedTCPPorts = [ 10250 net.vpnPort ];
      allowedUDPPorts = [ net.vpnPort ];

      # Allow traffic to flow freely inside the VPN.
#      trustedInterfaces = config.networking.nat.internalInterfaces;

#      extraCommands = ''
#        # Allow containers to access the API, but don't give them full access
#        # to all internal ports.
#        iptables -A nixos-fw -p tcp --source ${net.cluster} --dport ${
#          toString net.k8sApiPort
#        } -j nixos-fw-accept
#        iptables -A nixos-fw -p udp --source ${net.cluster} --dport ${
#          toString net.k8sApiPort
#        } -j nixos-fw-accept
#      '';
    };
  };

  networking.wireguard.interfaces = {
    # "wg0" is the network interface name. You can name the interface arbitrarily.
    wg0 = {
      # Determines the IP address and subnet of the server's end of the tunnel interface.
      ips = [ "${config.node.vpn}/24" ];

      # The port that WireGuard listens to. Must be accessible by the client.
      listenPort = net.vpnPort;

      # Path to the private key file.
      #
      # Note: The private key can also be included inline via the privateKey option,
      # but this makes the private key world-readable; thus, using privateKeyFile is
      # recommended.
      privateKeyFile = "/root/wireguard-keys/private";
    };
  };

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;

  users = {
    mutableUsers = false;

    users = {
      root.openssh.authorizedKeys.keys = sshKeys.pippijn;

      pippijn = {
        uid = 1000;
        isNormalUser = true;
        shell = pkgs.zsh;
        home = "/home/pippijn";
        description = "Pippijn van Steenhoven";
        extraGroups = [ "docker" "wheel" ];
        openssh.authorizedKeys.keys = sshKeys.pippijn;
      };
    };
  };
}
