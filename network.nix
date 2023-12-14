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
      ipv6 = "fe80::222:4dff:feae:322d";
      vpn = "10.100.0.3";
      publicKey = "4raBwIpdh+masy1YSzEuX7jhnkn9pYG2RDalp8VrKl0=";
      externalInterface = "eno0";
    };

    # Windows laptop.
    osiris = {
      name = "osiris";
      vpn = "10.100.0.4";
      publicKey = "ODQiM8MGoywHcGYiR9obqP8gi8oAyJob02tW3d6VJ0A=";
    };

    # Android phone.
    pixel7 = {
      name = "pixel7";
      vpn = "10.100.0.5";
      publicKey = "nNi2hDKeBzqRB4WyGX3F50N6VhA5vJ4ij/DSEk3PfGM=";
    };

    # Mouad's devices
    mouad-phone = {
      name = "mouad-phone";
      vpn = "10.100.0.50";
      publicKey = "BNwlNpho/n9Jx121L5kWbW015Mk+9Gei4ltyWttS4Fo=";
    };
    mouad = {
      name = "mouad";
      vpn = "10.100.0.51";
      publicKey = "eLXKgq+CXQGaah4B3LNaLzvdjv46lt8K87XpaQuA/j4=";
    };

    # Windows PC.
    horus = {
      name = "horus";
      vpn = "10.100.0.6";
      publicKey = "vMPacQKiSO+/6OjAYFZxKu7RSNQcRAN6z0cY9EaASFc=";
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
