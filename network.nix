# Xinutec network layout.
#
# See options.nix for the schema for nodes below.
{
  cluster = "10.42.0.0/24";
  k8sApiPort = 6443;

  vpn = "10.100.0.0/24";
  vpnPort = 51820;

  nodes = rec {
    # amun is the Kubernetes/NFS/Wireguard master. All other nodes connect to
    # it. If it is down, other nodes still work, e.g. isis deployments still
    # run, and nothing on any of the nodes should depend on the NFS share, but
    # communication between the nodes will be broken, because we have a star
    # topology for the VPN.
    master = amun;

    # Kubernetes/NFS/Wireguard master (and node).
    amun = {
      name = "amun";
      ipv4 = "94.23.247.133";
      ipv6 = "2001:41d0:2:7a85::1";
      vpn = "10.100.0.1";
      publicKey = "9iISDdDl9g57OE+yhQMNJjAVsaBqHurf4iUjnZ9GQF4=";
      externalInterface = "eno1";
    };

    # Kubernetes node.
    isis = {
      name = "isis";
      ipv4 = "188.165.200.180";
      ipv6 = "2001:41d0:2:91b4::1";
      vpn = "10.100.0.2";
      publicKey = "F0NoDNdlJzcKh0JCNsVKPvof3SXQEpWwMsCF9zHCbTs=";
      externalInterface = "enp3s0";
    };

    # Backup machine. No Kubernetes, only storage.
    odin = {
      name = "odin";
      ipv4 = "5.196.65.240";
      ipv6 = "2001:41d0:a:f9f0::1";
      vpn = "10.100.0.3";
      publicKey = "4raBwIpdh+masy1YSzEuX7jhnkn9pYG2RDalp8VrKl0=";
      externalInterface = "eno0";
    };

    # Windows laptop, HP.
    osiris = {
      name = "osiris";
      vpn = "10.100.0.4";
      publicKey = "ODQiM8MGoywHcGYiR9obqP8gi8oAyJob02tW3d6VJ0A=";
    };

    # Windows laptop, Lenovo.
    anubis = {
      name = "anubis";
      vpn = "10.100.0.7";
      publicKey = "lvu0kLY3Y1WMb47a81Y7QklEiEnM8rVrXUfUReOTUnQ=";
    };

    # Raspberry Pi 4
    bes = {
      name = "bes";
      vpn = "10.100.0.9";
      publicKey = "2DCtNHc987vQ4Kxnt1fSpC6+NMlj4R7UTl1tp8tZtQQ=";
    };

    # Android phones.
    pixel5 = {
      name = "pixel5";
      vpn = "10.100.0.10";
      publicKey = "FSaKx2UvFEM3LCMTeNrMr3S1RYg2h+FaWE8JkWn7R2s=";
    };
    pixel9 = {
      name = "pixel9";
      vpn = "10.100.0.12";
      publicKey = "bii6vS7aftv3h2CakeM1xr5SCucH8rtOkR6Zpryh+Qk=";
    };

    # iPhone (Pippijn). Private key generated on the Mac 2026-06-28, lives only
    # in the device's WireGuard tunnel (provisioned by QR); only the public key
    # is here. Split-tunnel client: AllowedIPs = the VPN subnet.
    iphone = {
      name = "iphone";
      vpn = "10.100.0.13";
      publicKey = "YqxVUL48NOPh6cbu1Dgu6BS9YUycByEVPrNiyHgtk0c=";
    };

    # Mac Mini — ONE-WAY peer: it may initiate into the VPN, but nothing on
    # the VPN may initiate toward it (it is the offsite-backup host; see
    # xinutec-infra/mac-mini.md). Enforced by firewall rules in
    # base-configuration.nix keyed on this vpn address, plus pf on the Mac
    # itself. Key generated on the Mac 2026-06-10; private key never leaves it.
    mac-mini = {
      name = "mac-mini";
      vpn = "10.100.0.11";
      publicKey = "qe0nIvj/UUn4d3gOt/BC5VHKSqpkzhq16+jvYPDxCyg=";
    };

    # Picade
    picade0 = {
      name = "picade0";
      vpn = "10.100.0.100";
      publicKey = "SuoQCMx8H5/E+KtXuqm+scplFLflq8J8R2rKRhU4A3M=";
    };
    picade1 = {
      name = "picade1";
      vpn = "10.100.0.101";
      publicKey = "2RrrIbbdtyBtZVKh5ygq/39OyQmZnJbIAkIJh2/k5Q0=";
    };
    picade2 = {
      name = "picade2";
      vpn = "10.100.0.102";
      publicKey = "/enY3RTfb2h15K6ly3DkN0simlAvL3sQO+tAW7yXOF8=";
    };
    picade3 = {
      name = "picade3";
      vpn = "10.100.0.103";
      publicKey = "vPyzu27jIEeI/A717eWg3oNFxu4PNoOK+a3oMJtiUyY=";
    };
    picade4 = {
      name = "picade4";
      vpn = "10.100.0.104";
      publicKey = "HW/rKw7+MUrE7WV8FUsprcGzsgSWVyj7nqo/PiuFAAg=";
    };
  };
}
