# Two lists, kept separate (#1049): sharing one makes root on any host root on
# every host, from two internet-facing machines.
let
  # Unrestricted deliberately: the control plane, and the way back in if a
  # `from=` below is wrong.
  macMini =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIODCVuDCe0SWwm5ZwG6yqwXD/8LcLxDvmCK8ZQB9W9N0 pippijn@mac-mini";

  # Phone, and the roaming laptop.
  termux =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPvQ3V6Vr8L+ckUBinwDYLLkortxz5S8tVGGKMSEcpdU u0_a522@localhost";
  roamMac =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE8e2iWRYdr+Wzy9uBca/VLzexcWCnHwYb8TQhaeGA7j pippijn@pippijn-mac.roam.internal";

  # ⚠ `pippijn@xinutec.org` (ed25519 and RSA) is retired and its private halves
  # are published. Never re-add it; see `agenix/README.md`.

  # Private half: agenix `root-ssh-fleet`, at /root/.ssh/id_fleet.
  # ⚠ Never add it to `pippijn` — that split is what #1049 bought.
  fleetRoot =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJX2wZbfLaVDaDGdDkEFna5dalacJqicRu1NzwYAEq1y fleet-root@xinutec";

  # odin is the only host that ssh's to another by automation. Its public address
  # is for when the tunnel is down, which is when a backup most needs to work;
  # 127.0.0.1 is the restore drill reaching odin from odin (drill/*.sh).
  fromOdin = "from=\"10.100.0.3,5.196.65.240,127.0.0.1,::1\"";
in
{
  # ⚠ sshd also reads `~pippijn/.ssh/authorized_keys`, which a rebuild can
  # neither manage nor remove. While that file exists this list is not the whole
  # answer for the account.
  pippijn = [
    macMini
    termux
    roamMac
  ];

  # Not `restrict`: the drill runs kubectl/docker/mariadb-dump over this key and
  # needs pty, port and agent forwarding. The bound is on WHERE it may be used.
  root = [
    macMini
    "${fromOdin} ${fleetRoot}"
  ];
}
