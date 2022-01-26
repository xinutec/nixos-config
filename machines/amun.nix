# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

let net = import ../network.nix; in
{
  imports =
    [ # Include the results of the hardware scan.
      ../hardware-configuration.nix
      ../base-configuration.nix
      <home-manager/nixos>
    ];

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    kubectl
    kubernetes-helm
  ];

  networking.wireguard.interfaces = {
    # "wg0" is the network interface name. You can name the interface arbitrarily.
    wg0 = {
      # This allows the wireguard server to route your traffic to the internet and hence be like a VPN
      # For this to work you have to set the dnsserver IP of your router (or dnsserver of choice) in your clients
      postSetup = ''
        ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s ${net.vpn} -o eth0 -j MASQUERADE
      '';

      # This undoes the above command
      postShutdown = ''
        ${pkgs.iptables}/bin/iptables -t nat -D POSTROUTING -s ${net.vpn} -o eth0 -j MASQUERADE
      '';

      # List of allowed peers.
      peers = builtins.map (node: {
        publicKey = "${node.publicKey}";
        allowedIPs = [ "${node.vpn}/32" ];
      }) [ net.nodes.isis ];
    };
  };

  # List services that you want to enable:
  services.k3s = {
    enable = true;
    role = "server";
    extraFlags = "--disable traefik --advertise-address ${config.node.vpn} --flannel-iface=wg0";
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
