# Xinutec network layout. See options.nix for the node schema.
{
  cluster = "10.42.0.0/24";
  k8sApiPort = 6443;

  vpn = "10.100.0.0/24";
  vpnPort = 51820;

  # The Mac's agent console, tunnelled out to isis. Named here because both ends
  # must agree; see memview/docs/agent-console.md.
  consolePort = 8097;

  nodes = rec {
    # Star topology: every node peers with amun and nothing else.
    master = amun;

    # Kubernetes/NFS/Wireguard master.
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

    # Windows desktop PC. Retired 2026-06-21 (be31bb0), back 2026-09-13.
    # NOT its old .6 — that has been shu's since 2026-09-04.
    horus = {
      name = "horus";
      vpn = "10.100.0.16";
      publicKey = "vMPacQKiSO+/6OjAYFZxKu7RSNQcRAN6z0cY9EaASFc=";
      intermittent = true; # desktop PC — powered off when not in use
    };

    # Raspberry Pi 4
    bes = {
      name = "bes";
      vpn = "10.100.0.9";
      publicKey = "2DCtNHc987vQ4Kxnt1fSpC6+NMlj4R7UTl1tp8tZtQQ=";
      intermittent = true; # general-purpose Pi again — powered on when it's wanted
    };

    # Android phones. These are always-on: a gap is a fault to act on, not a
    # duty cycle. pixel9 and dasha are exceptions, reasoned on their own lines.
    pixel5 = {
      name = "pixel5";
      vpn = "10.100.0.10";
      publicKey = "FSaKx2UvFEM3LCMTeNrMr3S1RYg2h+FaWE8JkWn7R2s=";
      intermittent = false;
    };
    pixel9 = {
      name = "pixel9";
      vpn = "10.100.0.12";
      publicKey = "bii6vS7aftv3h2CakeM1xr5SCucH8rtOkR6Zpryh+Qk=";
      # Exception: its gaps are flights and the metro, which are not actionable.
      intermittent = true;
    };
    # OnePlus 6T, a recall recorder. Re-keyed 2026-09-08 — the LineageOS wipe
    # destroyed the old private key, which existed nowhere else.
    oneplus6t = {
      name = "oneplus6t";
      vpn = "10.100.0.8";
      publicKey = "b8BIWhtElkAFcXZ1f/mvLoXak6zus8Q2UGAP1YF+8AY=";
      intermittent = false; # a gap here is lost audio
    };

    # iPhone (Pippijn). Never leaves the house, so a gap is a real fault — see
    # #1597, and do not silence it by flipping this back to intermittent.
    iphone = {
      name = "iphone";
      vpn = "10.100.0.13";
      publicKey = "YqxVUL48NOPh6cbu1Dgu6BS9YUycByEVPrNiyHgtk0c=";
      intermittent = false;
    };

    # ONE-WAY: it may dial the VPN, nothing on the VPN may dial it. The firewall
    # rules come from `oneWay` in base-configuration.nix, plus pf on the Mac.
    mac-mini = {
      name = "mac-mini";
      vpn = "10.100.0.11";
      publicKey = "qe0nIvj/UUn4d3gOt/BC5VHKSqpkzhq16+jvYPDxCyg=";
      oneWay = true;
    };

    # House NixOS box: storage, no Kubernetes, no public address — it dials out.
    geb = {
      name = "geb";
      vpn = "10.100.0.5";
      publicKey = "VCTpVsYEoDmifhS8WGBQ6ejdRNW3rJoTRvU8275iWW0=";
      # Wifi by decision, not for want of a cable: the link is stable and fast.
      externalInterface = "wlp0s20f3";
      oneWay = true;
      # The Mac administers it, and does so over the LAN today. Naming it here
      # keeps that working if the Mac ever has to reach geb over the VPN.
      reachableFrom = [ "mac-mini" ];
      # It holds backups, so a quiet handshake failure must be a fault.
      intermittent = false;
    };

    # Second house box, and the one we are ALLOWED TO LOSE: it exists to be
    # wiped and rebuilt, because that is the only restore drill worth anything.
    shu = {
      name = "shu";
      vpn = "10.100.0.6";
      publicKey = "Ls3RbTPsbp6uUtVBZyPgWFWdpv22iR6RCxul2QW5NnM=";
      # 5 GHz wifi, with a 2.4 GHz profile behind it. No cable wanted.
      externalInterface = "wlp1s0";
      oneWay = true;
      reachableFrom = [ "mac-mini" ];
      # true here and false on geb, which is the point of the pair: we rebuild
      # shu on purpose, so always-on would cry wolf every time we did that.
      intermittent = true;
    };

    # Third house box, geb's actual hardware twin, with NO JOB YET.
    tefnut = {
      name = "tefnut";
      vpn = "10.100.0.15";
      publicKey = "onPLb2wm036baPhMjHMG9Tz5CnH/Auw9ZOIsce1ibgU=";
      externalInterface = "wlp0s20f3";
      oneWay = true;
      reachableFrom = [ "mac-mini" ];
      # Mains-powered and meant to be on, so a gap is true news.
      # REVISIT WHEN IT GETS A JOB that involves powering it off.
      intermittent = false;
    };

    # Dasha's phone.
    dasha = {
      name = "dasha";
      vpn = "10.100.0.14";
      publicKey = "FyeFKOIM9xGZbUcjcTLpsI/zL7r5aoj4MIsPkb164To=";
      # Has barely connected since 2026-08-18. Always-on would be a permanent
      # red nobody can act on — retire it or fix it, do not let it alert.
      intermittent = true;
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
