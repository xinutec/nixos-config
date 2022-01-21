# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

let
  wgSubnet = "10.100.0.0/24";

  amunIP = "94.23.247.133";
  amunIP6 = "2001:41d0:2:7a85::1";
  amunWgIP = "10.100.0.1";
  isisIP = "188.165.200.180";
  isisIP6 = "2001:41d0:2:91b4::1";
  isisWgIP = "10.100.0.2";

  ownIP6 = isisIP6;
  ownHostName = "isis";

  kubeMasterIP = amunIP;
  kubeMasterAPIServerPort = 6443;
in
{
  imports =
    [ # Include the results of the hardware scan.
      ../hardware-configuration.nix
      <home-manager/nixos>
    ];

  # Use the GRUB 2 boot loader.
  boot.loader.grub.enable = true;
  boot.loader.grub.version = 2;
  # Define on which hard drive you want to install Grub.
  boot.loader.grub.device = "/dev/sda";
  boot.loader.timeout = 1;

  boot.cleanTmpDir = true;
  zramSwap.enable = true;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    git
    k3s
    vim
    wireguard
  ];

  networking.enableIPv6 = true;
  networking.useDHCP = true;
  networking.dhcpcd.extraConfig = "static ip6_address=${ownIP6}";

  # Resolve master hostname.
  networking.hostName = ownHostName; # Define your hostname.
  networking.search = [ "xinutec.org" ];

  # enable NAT
  networking.nat.enable = true;
  networking.nat.externalInterface = "eth0";
  networking.nat.internalInterfaces = [ "wg0" ];
  networking.firewall = {
    # Or disable the firewall altogether.
#   enable = false;
    allowedTCPPorts = [ ];
    allowedUDPPorts = [ 51820 ];
    extraCommands = ''
      iptables -A nixos-fw -p tcp --source ${wgSubnet} -j nixos-fw-accept
      iptables -A nixos-fw -p udp --source ${wgSubnet} -j nixos-fw-accept
      iptables -A nixos-fw -p tcp --source ${kubeMasterIP}/32 -j nixos-fw-accept
      iptables -A nixos-fw -p udp --source ${kubeMasterIP}/32 -j nixos-fw-accept
    '';
  };

  # Enable WireGuard
  networking.wireguard.interfaces = {
    # "wg0" is the network interface name. You can name the interface arbitrarily.
    wg0 = {
      # Determines the IP address and subnet of the client's end of the tunnel interface.
      ips = [ "10.100.0.2/24" ];
      listenPort = 51820; # to match firewall allowedUDPPorts (without this wg uses random port numbers)

      # Path to the private key file.
      #
      # Note: The private key can also be included inline via the privateKey option,
      # but this makes the private key world-readable; thus, using privateKeyFile is
      # recommended.
      privateKeyFile = "/root/wireguard-keys/private";

      peers = [
        # For a client configuration, one peer entry for the server will suffice.

        {
          # Public key of the server (not a file path).
          publicKey = "9iISDdDl9g57OE+yhQMNJjAVsaBqHurf4iUjnZ9GQF4=";

          # Forward all the traffic via VPN.
          #allowedIPs = [ "0.0.0.0/0" ];
          # Or forward only particular subnets
          allowedIPs = [ "10.100.0.0/24" ];

          # Set this to the server IP and port.
          endpoint = "${kubeMasterIP}:51820"; # ToDo: route to endpoint not automatically configured https://wiki.archlinux.org/index.php/WireGuard#Loop_routing https://discourse.nixos.org/t/solved-minimal-firewall-setup-for-wireguard-client/7577

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
    serverAddr = "https://amun:${toString kubeMasterAPIServerPort}";
  };

  fileSystems."/export" = {
    device = "10.100.0.1:/export";
    fsType = "nfs";
  };

  fileSystems."/home/pippijn/code" = {
    device = "/export/home/pippijn/code";
    options = [ "bind"] ;
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
        extraGroups = [ "wheel" ];
        openssh.authorizedKeys.keys = [ "ssh-rsa AAAAB3NzaC1yc2EAAAABIwAABAEA3kaCLPpCNKW5QbB4bHxvhg2DvYgH6EgDjA48K3HuRdNqbFKtMLrDAwGtUfPdmjMZzh6woMiGER0T2IeEIwyw+MttcVkt1Rpd+K49uUaCMjqxy5wR8Q327XFTM7ysf38fyfr9qS3HHbKG95oKKYMYUNiFhr2t8RvAO39Be+yyedzCLbfnUirfRuRqcVptznySkFHWEPHk5O4U4yzq4bkMb9m1DgZKY2v0vR7FniP3ypNpmaKKZdQykcIC2clLvWovkwW1AclOdSeVyHZpGU61v6DGnKRaNhPDagaMm2ZTOGB8uW3M66+nRGACNkgKdW6LO3D05M1afnS67bJ9wOm5yoBaDD7G3csma1I3Sx48/s7UgVs6vhIc9ViWpR0aHAwYC40/qQeCBNO1WQ5m9MG42Jq5X5h+pr2HOIjVskNOFh2fNyCgmLN98C7aavYIo2XBknJoa5M5pZ4nJl2IANLylBLzizTk5ZO618zE0c+9/YPS2Y0YRoTne9t/p8TkSCsRLfbAgCKN/uQiv1gkqajY+P7rnjPVBAKbGdw8f7651Ovi9Q/fE5S171Dha+2Rnjz9I60+PepiLuDNgx7fhqYuEtAMtePpt5d7wXKHRTb+wQqvJUREcIGgxmoMe7hbUF1dMqDZoU9jW9wOMKHTfjtMZhWQjICHy5cjPXNB4p3lXcUBY1khPeTNZZ5y9WZaB4Snq1z8ZdZ7sqDw5v3kkNUHBV80+s7pfIiUErhVV9a0y8xysUrM93EuPIdmojpLyV9/KoJttp22l7LU+xrIkwiid+BylGOxz5p7j/Q8TfpH4OU1dJ48SIkoee7dzZe/zbt21vC9J6ppDRQ+L4ALy2p9MSyjkFvHX/1Wdbfqg4xTZsJ33X9zJqjYbotWKzrH3dtD4dFipyWSTDvfnr3OYKIeEU1ur+8MZRqRu0fP7kDWzTl9jESR4YIVwSwe/1z98BYGGvlOHBATwSsp0XyX6phBCUzgJ5zXdpZLSMcFalGRbjVdhXdfo6S23qw3pO74cVQ9pFzUeBsj61MkF7BmMG1i98F5RDkAf0DlRksnBcHIOztxoE4aaQDA/QI/mFT5uBmSKI/XkA20UPLln0xYwFAd04bdY+qimrRXpw1aRl0ByqynLPFdvmzMBLSkys5llp+v1Qq7gDU11G68ocOh6F0T4x6IHWXKmevOiO3OUg99jd4Iy1j5WGmAL+fo0XlXXQwTAFIfs+ewAwxAF8twbOEEPQwIDqssXOWjL0NKl0pg9X3swSZrhhEG2ADHYwe62w2TSYI0Nov180rwUeWu7e4yE4z7I+txCxK82/Luo9qOhfALmuaSFWmz1SAuktDsM6SsJOw4nJ+d34tGRplITr0BuQ== pippijn@xinutec.org" ];
      };
    };
  };
}
