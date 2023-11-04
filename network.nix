# Xinutec network layout.
#
# See options.nix for the schema for nodes below.
{
  cluster = "10.42.0.0/24";
  k8sApiPort = 6443;

  vpn = "10.100.0.0/24";
  vpnPort = 51820;

  nodes = rec {
    master = amun;

    amun = {
      name = "amun";
      ipv4 = "94.23.247.133";
      ipv6 = "2001:41d0:2:7a85::1";
      vpn = "10.100.0.1";
      publicKey = "9iISDdDl9g57OE+yhQMNJjAVsaBqHurf4iUjnZ9GQF4=";
      externalInterface = "eno1";
    };

    isis = {
      name = "isis";
      ipv4 = "188.165.200.180";
      ipv6 = "2001:41d0:2:91b4::1";
      vpn = "10.100.0.2";
      publicKey = "F0NoDNdlJzcKh0JCNsVKPvof3SXQEpWwMsCF9zHCbTs=";
      externalInterface = "enp3s0";
    };

    odin = {
      name = "odin";
      ipv4 = "5.196.65.240";
      ipv6 = "fe80::222:4dff:feae:322d";
      vpn = "10.100.0.3";
      publicKey = "4raBwIpdh+masy1YSzEuX7jhnkn9pYG2RDalp8VrKl0=";
      externalInterface = "eno0";
    };

    osiris = {
      name = "osiris";
      vpn = "10.100.0.4";
      publicKey = "ODQiM8MGoywHcGYiR9obqP8gi8oAyJob02tW3d6VJ0A=";
    };

    phone = {
      name = "phone";
      vpn = "10.100.0.5";
      publicKey = "nNi2hDKeBzqRB4WyGX3F50N6VhA5vJ4ij/DSEk3PfGM=";
    };
  };
}
