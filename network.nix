# Xinutec network layout.
#
# See options.nix for the schema for nodes below.
{
  cluster = "10.42.0.0/24";
  k8sApiPort = 6443;

  vpn = "10.100.0.0/24";
  vpnPort = 51820;

  nodes = {
    amun = {
      name = "amun";
      ipv4 = "94.23.247.133";
      ipv6 = "2001:41d0:2:7a85::1";
      vpn = "10.100.0.1";
      publicKey = "9iISDdDl9g57OE+yhQMNJjAVsaBqHurf4iUjnZ9GQF4=";
    };

    isis = {
      name = "isis";
      ipv4 = "188.165.200.180";
      ipv6 = "2001:41d0:2:91b4::1";
      vpn = "10.100.0.2";
      publicKey = "F0NoDNdlJzcKh0JCNsVKPvof3SXQEpWwMsCF9zHCbTs=";
    };

    odin = {
      name = "odin";
      ipv4 = "5.196.65.240";
      ipv6 = "fe80::222:4dff:feae:322d";
      vpn = "10.100.0.3";
      publicKey = "4raBwIpdh+masy1YSzEuX7jhnkn9pYG2RDalp8VrKl0=";
    };
  };
}
