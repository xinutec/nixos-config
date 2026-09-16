# SSH public keys. TWO LISTS, and the difference is the whole point (#1049): `pippijn`
# is the person, `root` is the Mac plus the fleet's own key. One shared list makes the
# fleet a flat mesh — root on any host is root on every host, from two internet-facing
# machines.
let
  # UNRESTRICTED deliberately: the Mac is the control plane and originates nearly every
  # root login. It is also the guaranteed way back in if a `from=` below is wrong.
  macMini =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIODCVuDCe0SWwm5ZwG6yqwXD/8LcLxDvmCK8ZQB9W9N0 pippijn@mac-mini";

  # Pippijn's other devices. The phone key reaches the Mac and the console tunnel
  # rather than the fleet directly; it is declared because removing a path he holds
  # is his call, not a tidy-up.
  termux =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPvQ3V6Vr8L+ckUBinwDYLLkortxz5S8tVGGKMSEcpdU u0_a522@localhost";
  roamMac =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE8e2iWRYdr+Wzy9uBca/VLzexcWCnHwYb8TQhaeGA7j pippijn@pippijn-mac.roam.internal";

  # `pippijn@xinutec.org` (ed25519 AND RSA) is RETIRED and its private halves are
  # published — do not re-add it to either list. It was at once Pippijn's personal
  # key and, as agenix `root-ssh-{ed25519,rsa}`, the fleet's inter-host root
  # credential, which is #1049. Why retired rather than rotated, and why deleting
  # its ciphertext bought nothing: `agenix/README.md`.

  # The fleet's OWN inter-host root key (#1049 step 1). Private half: agenix
  # `root-ssh-fleet`, at /root/.ssh/id_fleet on all four hosts. It is not in the
  # `pippijn` list below and never will be — that is the entire difference between
  # it and the two above.
  fleetRoot =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJX2wZbfLaVDaDGdDkEFna5dalacJqicRu1NzwYAEq1y fleet-root@xinutec";

  # Where the fleet key may be used FROM. odin is the only host that reaches
  # the others by automation; host-to-host ssh otherwise is interactive, and goes
  # from the Mac, whose key is unrestricted.
  #
  # BOTH OF ODIN'S ADDRESSES, or the backup breaks: odin reaches the others over
  # the VPN normally and over its public address when the tunnel is down, which is
  # exactly the circumstance in which a backup most needs to work. 127.0.0.1 is not
  # padding either — the restore drill ssh's odin to itself
  # (machines/odin/drill/*.sh, and `--host odin` in backups.nix).
  fromOdin = "from=\"10.100.0.3,5.196.65.240,127.0.0.1,::1\"";
in
{
  # The person: installed on the `pippijn` user, unrestricted.
  #
  # THIS LIST IS THE WHOLE ANSWER for the `pippijn` account only as long as
  # `~pippijn/.ssh/authorized_keys` does not exist. sshd consults both it and
  # `/etc/ssh/authorized_keys.d/pippijn`, which this writes; nothing ENFORCES the
  # first being absent, because a file a rebuild does not manage is a file a
  # rebuild cannot remove. Re-creating it puts a credential nobody can enumerate
  # back on every host.
  pippijn = [
    macMini
    termux
    roamMac
  ];

  # root: the Mac unrestricted, the fleet key bound to odin.
  #
  # NOT `restrict`, deliberately. That would also drop pty, port and agent
  # forwarding, and the drill runs kubectl/docker/mariadb-dump over this
  # credential — a general shell it genuinely needs (measured; see #1049). The
  # bound here is on WHERE the key may be used, which is the property that
  # closes the mesh. Narrowing WHAT it may run is a separate, harder question.
  root = [
    macMini
    "${fromOdin} ${fleetRoot}"
  ];
}
