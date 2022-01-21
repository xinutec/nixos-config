# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

let net = import ../network.nix; in
{
  imports = [ ../base-configuration.nix ];

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
  ];

  # Enable WireGuard
  networking.wireguard.interfaces = {
    # "wg0" is the network interface name. You can name the interface arbitrarily.
    wg0 = {
      peers = [
        # For a client configuration, one peer entry for the server will suffice.
        {
          # Public key of the server (not a file path).
          publicKey = net.nodes.amun.publicKey;

          # Forward all the traffic via VPN.
          #allowedIPs = [ "0.0.0.0/0" ];
          # Or forward only particular subnets
          allowedIPs = [ net.vpn ];

          # Set this to the server IP and port.
          endpoint = "${net.nodes.amun.ipv4}:${toString net.vpnPort}"; # ToDo: route to endpoint not automatically configured https://wiki.archlinux.org/index.php/WireGuard#Loop_routing https://discourse.nixos.org/t/solved-minimal-firewall-setup-for-wireguard-client/7577

          # Send keepalives every 25 seconds. Important to keep NAT tables alive.
          persistentKeepalive = 25;
        }
      ];
    };
  };

  # List services that you want to enable:
  services.k3s = {
    enable = true;
    role = "agent";
    tokenFile = "/root/node-token";
    serverAddr = "https://${net.nodes.amun.name}:6443";
  };

  fileSystems."/export" = {
    device = "${net.nodes.amun.vpn}:/export";
    fsType = "nfs";
  };
}
