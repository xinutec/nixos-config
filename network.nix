# Xinutec network layout.
#
# See options.nix for the schema for nodes below.
{
  cluster = "10.42.0.0/24";
  k8sApiPort = 6443;

  vpn = "10.100.0.0/24";
  vpnPort = 51820;

  # The agent console on the Mac. It is reachable through a tunnel the Mac itself
  # dials out to isis — nothing initiates toward the Mac, so the one-way rule
  # stands unamended. isis binds this port on its VPN address and forwards it back
  # down that tunnel; the phone's TLS session runs end to end through it, so isis
  # carries ciphertext and holds no key that opens anything. Named here because
  # both ends of the tunnel have to agree. See memview/docs/agent-console.md.
  consolePort = 8097;

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
      intermittent = true; # laptop — powered off when not in use
    };

    # Windows laptop, Lenovo.
    anubis = {
      name = "anubis";
      vpn = "10.100.0.7";
      publicKey = "lvu0kLY3Y1WMb47a81Y7QklEiEnM8rVrXUfUReOTUnQ=";
      intermittent = true; # laptop — powered off when not in use
    };

    # Raspberry Pi 4
    bes = {
      name = "bes";
      vpn = "10.100.0.9";
      publicKey = "2DCtNHc987vQ4Kxnt1fSpC6+NMlj4R7UTl1tp8tZtQQ=";
      intermittent = true; # general-purpose Pi again — powered on when it's wanted
    };

    # Android phones.
    pixel5 = {
      name = "pixel5";
      vpn = "10.100.0.10";
      publicKey = "FSaKx2UvFEM3LCMTeNrMr3S1RYg2h+FaWE8JkWn7R2s=";
      intermittent = true; # phone — connects only when actively passing traffic
    };
    pixel9 = {
      name = "pixel9";
      vpn = "10.100.0.12";
      publicKey = "bii6vS7aftv3h2CakeM1xr5SCucH8rtOkR6Zpryh+Qk=";
      intermittent = true; # phone — connects only when actively passing traffic
    };

    # iPhone (Pippijn). Private key generated on the Mac 2026-06-28, lives only
    # in the device's WireGuard tunnel (provisioned by QR); only the public key
    # is here. Split-tunnel client: AllowedIPs = the VPN subnet.
    iphone = {
      name = "iphone";
      vpn = "10.100.0.13";
      publicKey = "YqxVUL48NOPh6cbu1Dgu6BS9YUycByEVPrNiyHgtk0c=";
      intermittent = true; # phone — connects only when actively passing traffic
    };

    # Mac Mini — ONE-WAY peer: it may initiate into the VPN, but nothing on
    # the VPN may initiate toward it (it is the offsite-backup host; see
    # xinutec-infra/mac-mini.md). Enforced by the firewall rules that
    # base-configuration.nix generates for every node with `oneWay`, plus pf on
    # the Mac itself. Key generated on the Mac 2026-06-10; private key never
    # leaves it.
    mac-mini = {
      name = "mac-mini";
      vpn = "10.100.0.11";
      publicKey = "qe0nIvj/UUn4d3gOt/BC5VHKSqpkzhq16+jvYPDxCyg=";
      oneWay = true;
    };

    # The house's own NixOS box: storage, no Kubernetes — odin's shape rather
    # than isis's. ONE-WAY like mac-mini, and for the same reason: it sits on a
    # home LAN behind the router, so the fleet has no business dialling into it.
    #
    # No ipv4/ipv6: it has no public address at all. It reaches the VPN by
    # dialling amun, which is the only direction that has to work.
    #
    # Installed 2026-08-10 on NixOS 26.05 (#726). Both keys were generated ON
    # the machine; only the public one is here, and unlike mac-mini the private
    # key does go into agenix (wireguard-geb.age), because that is how every
    # NixOS host in this fleet carries its own.
    geb = {
      name = "geb";
      vpn = "10.100.0.5";
      publicKey = "VCTpVsYEoDmifhS8WGBQ6ejdRNW3rJoTRvU8275iWW0=";
      # The interface carrying its default route, which today is wifi. There IS
      # an ethernet port (enp1s0, down for want of a cable); swap this when the
      # cable exists, because the 396G restic repo and 326G Nextcloud mirror it
      # is meant to hold will not seed pleasantly over wifi.
      externalInterface = "wlp0s20f3";
      oneWay = true;
      # A new box with no service on it yet — no storage until the 6 TB HDD is
      # freed (#697), so "no handshake" is not yet a fault worth waking anyone.
      # Flip to false when it becomes a backup target and being down is real.
      intermittent = true;
    };

    # Dasha's phone. Private key generated on the Mac 2026-07-08, lives only in
    # the device's WireGuard tunnel (provisioned by QR); only the public key is
    # here. Split-tunnel client: AllowedIPs = the VPN subnet.
    dasha = {
      name = "dasha";
      vpn = "10.100.0.14";
      publicKey = "FyeFKOIM9xGZbUcjcTLpsI/zL7r5aoj4MIsPkb164To=";
      intermittent = true; # phone — connects only when actively passing traffic
    };

    # Picade
    picade0 = {
      name = "picade0";
      vpn = "10.100.0.100";
      publicKey = "SuoQCMx8H5/E+KtXuqm+scplFLflq8J8R2rKRhU4A3M=";
      intermittent = true; # arcade cabinet — powered on only when in use
    };
    picade1 = {
      name = "picade1";
      vpn = "10.100.0.101";
      publicKey = "2RrrIbbdtyBtZVKh5ygq/39OyQmZnJbIAkIJh2/k5Q0=";
      intermittent = true; # arcade cabinet — powered on only when in use
    };
    picade2 = {
      name = "picade2";
      vpn = "10.100.0.102";
      publicKey = "/enY3RTfb2h15K6ly3DkN0simlAvL3sQO+tAW7yXOF8=";
      intermittent = true; # arcade cabinet — powered on only when in use
    };
    picade3 = {
      name = "picade3";
      vpn = "10.100.0.103";
      publicKey = "vPyzu27jIEeI/A717eWg3oNFxu4PNoOK+a3oMJtiUyY=";
      intermittent = true; # arcade cabinet — powered on only when in use
    };
    picade4 = {
      name = "picade4";
      vpn = "10.100.0.104";
      publicKey = "HW/rKw7+MUrE7WV8FUsprcGzsgSWVyj7nqo/PiuFAAg=";
      intermittent = true; # arcade cabinet — powered on only when in use
    };
  };
}
