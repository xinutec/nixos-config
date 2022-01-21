# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

let net = import ../network.nix; in
{
  imports =
    [ # Include the results of the hardware scan.
      ../hardware-configuration.nix
      (import ../base-configuration.nix { config = config; pkgs = pkgs; node = net.amun; })
      <home-manager/nixos>
    ];

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    kubectl
    kubernetes-helm
  ];

  networking.dhcpcd.extraConfig = "static ip6_address=${net.amun.ipv6}";

  networking.wireguard.interfaces = {
    # "wg0" is the network interface name. You can name the interface arbitrarily.
    wg0 = {
      # Determines the IP address and subnet of the server's end of the tunnel interface.
      ips = [ "${net.amun.vpn}/24" ];

      # The port that WireGuard listens to. Must be accessible by the client.
      listenPort = 51820;

      # This allows the wireguard server to route your traffic to the internet and hence be like a VPN
      # For this to work you have to set the dnsserver IP of your router (or dnsserver of choice) in your clients
      postSetup = ''
        ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s ${net.vpn} -o eth0 -j MASQUERADE
      '';

      # This undoes the above command
      postShutdown = ''
        ${pkgs.iptables}/bin/iptables -t nat -D POSTROUTING -s ${net.vpn} -o eth0 -j MASQUERADE
      '';

      # Path to the private key file.
      #
      # Note: The private key can also be included inline via the privateKey option,
      # but this makes the private key world-readable; thus, using privateKeyFile is
      # recommended.
      privateKeyFile = "/root/wireguard-keys/private";

      peers = [
        # List of allowed peers.
        { # isis
          publicKey = "F0NoDNdlJzcKh0JCNsVKPvof3SXQEpWwMsCF9zHCbTs=";
          # List of IPs assigned to this peer within the tunnel subnet. Used to configure routing.
          allowedIPs = [ "10.100.0.2/32" ];
        }
      ];
    };
  };

  # List services that you want to enable:
  services.k3s = {
    enable = true;
    role = "server";
    extraFlags = "--no-deploy traefik";
  };

  services.nfs.server = {
    enable = true;
    exports = "/export ${net.vpn}(rw,nohide,insecure,no_subtree_check)";
  };

  fileSystems."/home" = {
    device = "/export/home";
    options = [ "bind" ];
  };
}
