# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, lib, ... }:

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

  boot.tmp.cleanOnBoot = true;
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

  virtualisation.oci-containers.containers = {
    grafana = {
      image = "grafana/agent:v0.38.1";
      extraOptions = [
        "--net=host"
        "--pid=host"
        "--cap-add=SYS_TIME"
      ];
      volumes = [
        "/var/lib/grafana-agent:/etc/agent/data"
        "/etc/grafana-agent.yaml:/etc/agent/agent.yaml:ro"
        "/:/host/root:ro,rslave"
        "/sys:/host/sys:ro,rslave"
        "/proc:/host/proc:ro,rslave"
      ];
    };

    buildfarm-worker = {
      image = "toxchat/buildfarm-worker";
      extraOptions = [
        "--network=host"
        "--tmpfs=/tmp:exec"
      ];
      volumes = [
        "${config.users.users.pippijn.home}/.config/buildfarm/${config.node.name}.yml:/app/build_buildfarm/config.minimal.yml"
      ];
    };
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

    extraHosts = lib.concatStrings(
      lib.lists.unique(
        lib.lists.naturalSort(
          builtins.map
            (node: "${node.vpn} ${node.name}.vpn\n" )
            (builtins.attrValues net.nodes))));

    # Resolve hostnames in domain.
    search = [ config.networking.domain ];
    nameservers = [
      "10.43.0.10" # kube-dns.kube-system.svc.cluster.local
      "213.186.33.99" # cdns.ovh.net
    ];
    hostName = config.node.name; # Define your hostname.
    domain = "xinutec.org";

    # enable NAT
    nat = {
      enable = true;
      externalInterface = config.node.externalInterface;
      internalInterfaces =
        builtins.attrNames config.networking.wireguard.interfaces;
    };

    firewall = {
      enable = true;

      # No need for explicitly allowing ports here. Kubernetes takes care of
      # opening ports as needed. We only need 10250 (kubelet) and the Wireguard port.
      allowedTCPPorts = [ 10250 net.vpnPort ];
      allowedUDPPorts = [ net.vpnPort ];

      # Allow traffic to flow freely inside the VPN.
      trustedInterfaces = config.networking.nat.internalInterfaces ++ [ "docker0" ];

      extraCommands = ''
        # Allow containers to access the API, but don't give them full access
        # to all internal ports.
        iptables -A nixos-fw -p tcp --source ${net.cluster} --dport ${
          toString net.k8sApiPort
        } -j nixos-fw-accept
        iptables -A nixos-fw -p udp --source ${net.cluster} --dport ${
          toString net.k8sApiPort
        } -j nixos-fw-accept
      '';
    };
  };

  networking.wireguard.interfaces = {
    # "wg0" is the network interface name. You can name the interface arbitrarily.
    wg0 = let
      networkConfig = {
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
      peerConfig = if config.node.name == net.nodes.master.name then {
        # This allows the wireguard server to route your traffic to the internet and hence be like a VPN
        # For this to work you have to set the dnsserver IP of your router (or dnsserver of choice) in your clients
        postSetup = ''
          ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s ${net.vpn} -o eth0 -j MASQUERADE
        '';

        # This undoes the above command
        postShutdown = ''
          ${pkgs.iptables}/bin/iptables -t nat -D POSTROUTING -s ${net.vpn} -o eth0 -j MASQUERADE
        '';

        # Allow all other nodes to be peers.
        peers = builtins.map (node: {
          publicKey = "${node.publicKey}";
          allowedIPs = [ "${node.vpn}/32" ];
        }) (builtins.filter (node: node.name != config.node.name) (builtins.attrValues net.nodes));
      } else {
        peers = [
          # For a client configuration, one peer entry for the server will suffice.
          {
            # Public key of the server (not a file path).
            publicKey = net.nodes.master.publicKey;

            # Forward all the traffic via VPN.
            #allowedIPs = [ "0.0.0.0/0" ];
            # Or forward only particular subnets
            allowedIPs = [ net.vpn ];

            # Set this to the server IP and port.
            # TODO: route to endpoint not automatically configured https://wiki.archlinux.org/index.php/WireGuard#Loop_routing https://discourse.nixos.org/t/solved-minimal-firewall-setup-for-wireguard-client/7577
            endpoint = "${net.nodes.master.ipv4}:${toString net.vpnPort}";

            # Send keepalives every 25 seconds. Important to keep NAT tables alive.
            persistentKeepalive = 25;
          }
        ];
      };
    in pkgs.lib.mkMerge [ networkConfig peerConfig ];
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
