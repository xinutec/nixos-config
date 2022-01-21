# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

let net = import ./network.nix; in
{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./options.nix
      <home-manager/nixos>
    ];

  boot.loader.grub = {
    # Use the GRUB 2 boot loader.
    enable = true;
    version = 2;
    # Define on which hard drive you want to install Grub.
    device = "/dev/sda";
  };

  boot.cleanTmpDir = true;
  zramSwap.enable = true;

  virtualisation.docker.enable = true;

  programs.neovim = {
    enable = true;
    viAlias = true;
  };

  networking = {
    enableIPv6 = true;
    useDHCP = true;
    dhcpcd.extraConfig = "static ip6_address=${config.node.ipv6}";
   
    # Resolve hostnames in domain.
    search = [ "xinutec.org" ];
    hostName = config.node.name; # Define your hostname.
   
    # enable NAT
    nat = {
      enable = true;
      externalInterface = "eth0";
      internalInterfaces = builtins.attrNames config.networking.wireguard.interfaces;
    };
   
    firewall = {
      # Or disable the firewall altogether.
#     enable = false;
      allowedTCPPorts = [ 25 80 443 993 6697 7005 ];
      allowedUDPPorts = [ ];
      trustedInterfaces = config.networking.nat.internalInterfaces;
      extraCommands = ''
        iptables -A nixos-fw -p tcp --source ${net.cluster} -j nixos-fw-accept
        iptables -A nixos-fw -p udp --source ${net.cluster} -j nixos-fw-accept
        iptables -A nixos-fw -p tcp --source ${net.nodes.amun.ipv4}/32 -j nixos-fw-accept
        iptables -A nixos-fw -p udp --source ${net.nodes.amun.ipv4}/32 -j nixos-fw-accept
        iptables -A nixos-fw -p tcp --source ${net.nodes.isis.ipv4}/32 -j nixos-fw-accept
        iptables -A nixos-fw -p udp --source ${net.nodes.isis.ipv4}/32 -j nixos-fw-accept
      '';
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
      root.openssh.authorizedKeys.keys = [
        "ssh-rsa AAAAB3NzaC1yc2EAAAABIwAABAEA3kaCLPpCNKW5QbB4bHxvhg2DvYgH6EgDjA48K3HuRdNqbFKtMLrDAwGtUfPdmjMZzh6woMiGER0T2IeEIwyw+MttcVkt1Rpd+K49uUaCMjqxy5wR8Q327XFTM7ysf38fyfr9qS3HHbKG95oKKYMYUNiFhr2t8RvAO39Be+yyedzCLbfnUirfRuRqcVptznySkFHWEPHk5O4U4yzq4bkMb9m1DgZKY2v0vR7FniP3ypNpmaKKZdQykcIC2clLvWovkwW1AclOdSeVyHZpGU61v6DGnKRaNhPDagaMm2ZTOGB8uW3M66+nRGACNkgKdW6LO3D05M1afnS67bJ9wOm5yoBaDD7G3csma1I3Sx48/s7UgVs6vhIc9ViWpR0aHAwYC40/qQeCBNO1WQ5m9MG42Jq5X5h+pr2HOIjVskNOFh2fNyCgmLN98C7aavYIo2XBknJoa5M5pZ4nJl2IANLylBLzizTk5ZO618zE0c+9/YPS2Y0YRoTne9t/p8TkSCsRLfbAgCKN/uQiv1gkqajY+P7rnjPVBAKbGdw8f7651Ovi9Q/fE5S171Dha+2Rnjz9I60+PepiLuDNgx7fhqYuEtAMtePpt5d7wXKHRTb+wQqvJUREcIGgxmoMe7hbUF1dMqDZoU9jW9wOMKHTfjtMZhWQjICHy5cjPXNB4p3lXcUBY1khPeTNZZ5y9WZaB4Snq1z8ZdZ7sqDw5v3kkNUHBV80+s7pfIiUErhVV9a0y8xysUrM93EuPIdmojpLyV9/KoJttp22l7LU+xrIkwiid+BylGOxz5p7j/Q8TfpH4OU1dJ48SIkoee7dzZe/zbt21vC9J6ppDRQ+L4ALy2p9MSyjkFvHX/1Wdbfqg4xTZsJ33X9zJqjYbotWKzrH3dtD4dFipyWSTDvfnr3OYKIeEU1ur+8MZRqRu0fP7kDWzTl9jESR4YIVwSwe/1z98BYGGvlOHBATwSsp0XyX6phBCUzgJ5zXdpZLSMcFalGRbjVdhXdfo6S23qw3pO74cVQ9pFzUeBsj61MkF7BmMG1i98F5RDkAf0DlRksnBcHIOztxoE4aaQDA/QI/mFT5uBmSKI/XkA20UPLln0xYwFAd04bdY+qimrRXpw1aRl0ByqynLPFdvmzMBLSkys5llp+v1Qq7gDU11G68ocOh6F0T4x6IHWXKmevOiO3OUg99jd4Iy1j5WGmAL+fo0XlXXQwTAFIfs+ewAwxAF8twbOEEPQwIDqssXOWjL0NKl0pg9X3swSZrhhEG2ADHYwe62w2TSYI0Nov180rwUeWu7e4yE4z7I+txCxK82/Luo9qOhfALmuaSFWmz1SAuktDsM6SsJOw4nJ+d34tGRplITr0BuQ== pippijn@xinutec.org" 
      ];

      pippijn = {
        uid = 1000;
        isNormalUser = true;
        shell = pkgs.zsh;
        home = "/home/pippijn";
        description = "Pippijn van Steenhoven";
        extraGroups = [ "docker" "wheel" ];
        openssh.authorizedKeys.keys = [ "ssh-rsa AAAAB3NzaC1yc2EAAAABIwAABAEA3kaCLPpCNKW5QbB4bHxvhg2DvYgH6EgDjA48K3HuRdNqbFKtMLrDAwGtUfPdmjMZzh6woMiGER0T2IeEIwyw+MttcVkt1Rpd+K49uUaCMjqxy5wR8Q327XFTM7ysf38fyfr9qS3HHbKG95oKKYMYUNiFhr2t8RvAO39Be+yyedzCLbfnUirfRuRqcVptznySkFHWEPHk5O4U4yzq4bkMb9m1DgZKY2v0vR7FniP3ypNpmaKKZdQykcIC2clLvWovkwW1AclOdSeVyHZpGU61v6DGnKRaNhPDagaMm2ZTOGB8uW3M66+nRGACNkgKdW6LO3D05M1afnS67bJ9wOm5yoBaDD7G3csma1I3Sx48/s7UgVs6vhIc9ViWpR0aHAwYC40/qQeCBNO1WQ5m9MG42Jq5X5h+pr2HOIjVskNOFh2fNyCgmLN98C7aavYIo2XBknJoa5M5pZ4nJl2IANLylBLzizTk5ZO618zE0c+9/YPS2Y0YRoTne9t/p8TkSCsRLfbAgCKN/uQiv1gkqajY+P7rnjPVBAKbGdw8f7651Ovi9Q/fE5S171Dha+2Rnjz9I60+PepiLuDNgx7fhqYuEtAMtePpt5d7wXKHRTb+wQqvJUREcIGgxmoMe7hbUF1dMqDZoU9jW9wOMKHTfjtMZhWQjICHy5cjPXNB4p3lXcUBY1khPeTNZZ5y9WZaB4Snq1z8ZdZ7sqDw5v3kkNUHBV80+s7pfIiUErhVV9a0y8xysUrM93EuPIdmojpLyV9/KoJttp22l7LU+xrIkwiid+BylGOxz5p7j/Q8TfpH4OU1dJ48SIkoee7dzZe/zbt21vC9J6ppDRQ+L4ALy2p9MSyjkFvHX/1Wdbfqg4xTZsJ33X9zJqjYbotWKzrH3dtD4dFipyWSTDvfnr3OYKIeEU1ur+8MZRqRu0fP7kDWzTl9jESR4YIVwSwe/1z98BYGGvlOHBATwSsp0XyX6phBCUzgJ5zXdpZLSMcFalGRbjVdhXdfo6S23qw3pO74cVQ9pFzUeBsj61MkF7BmMG1i98F5RDkAf0DlRksnBcHIOztxoE4aaQDA/QI/mFT5uBmSKI/XkA20UPLln0xYwFAd04bdY+qimrRXpw1aRl0ByqynLPFdvmzMBLSkys5llp+v1Qq7gDU11G68ocOh6F0T4x6IHWXKmevOiO3OUg99jd4Iy1j5WGmAL+fo0XlXXQwTAFIfs+ewAwxAF8twbOEEPQwIDqssXOWjL0NKl0pg9X3swSZrhhEG2ADHYwe62w2TSYI0Nov180rwUeWu7e4yE4z7I+txCxK82/Luo9qOhfALmuaSFWmz1SAuktDsM6SsJOw4nJ+d34tGRplITr0BuQ== pippijn@xinutec.org" ];
      };
    };
  };
}
