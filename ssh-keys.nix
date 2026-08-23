# SSH public keys.
#
# TWO LISTS, and the difference between them is the whole point (#1049).
#
# `pippijn` is the person: every key Pippijn logs in with, installed on the
# `pippijn` USER account. `root` is the Mac plus the fleet's own key, bound to
# the only source that has ever legitimately used it. Since 2026-08-23 the two
# lists share exactly one key, `macMini`, and nothing else.
#
# Until 2026-08-21 root's list WAS `pippijn`, and that single line made the fleet
# a flat mesh: `pippijn@xinutec.org` is also the agenix secret
# `root-ssh-{ed25519,rsa}`, deployed to /root/.ssh on every host, so root on any
# host was root on every host. A compromise of amun or isis — both
# internet-facing — yielded root everywhere.
let
  # The Mac. UNRESTRICTED, deliberately: it is the control plane, every plan,
  # collector and deploy originates there, and it made 77,195 of the fleet's
  # root logins in the 30 days to 2026-08-21. Restricting this would break the
  # fleet, and leaving it unrestricted is what guarantees a way back in if the
  # `from=` below is ever wrong.
  macMini =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIODCVuDCe0SWwm5ZwG6yqwXD/8LcLxDvmCK8ZQB9W9N0 pippijn@mac-mini";

  # Pippijn's other devices. These lived ONLY in `~pippijn/.ssh/authorized_keys`
  # — a plain file, hand-copied to four hosts, dated 9 July, not in git and not
  # touched by `nixos-rebuild` — until they were moved here 2026-08-22.
  #
  # ⚠ WHY THAT FILE WAS A PROBLEM even though every key in it was Pippijn's. It
  # sat outside review: nothing listed its contents, nothing diffed them between
  # hosts, and a rebuild could neither add to it nor take from it. What it held
  # when finally read was two keys named for Google corporate machines,
  # `pippijn@pip.lon.corp.google.com` and `pippijn@pip.c.googlers.com`, still
  # authorized on both internet-facing hosts and used 7 times in 90 days. They
  # were removed the same day. A standing credential nobody can enumerate is the
  # shape of the fault, not which machine it happened to name.
  #
  # A fifth entry, `pippijn@Mac.communityfibre.co.uk`, was byte-identical to
  # `macMini` above under a different comment — so the file's real content was
  # these three plus a duplicate.
  #
  # Logins as `pippijn` on isis over the 90 days to 2026-08-22, which is what
  # says these are live rather than inherited: roam.internal 25, JuiceSSH 0,
  # Termux 0. The two phone keys reach the Mac and the console tunnel rather than
  # the fleet directly; they are declared because removing a path Pippijn holds
  # is his call, not a tidy-up.
  juiceSsh =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMj378KHiDT4caf5n0vGOFU9WJo8QeWO0Hsb+4VCumpq JuiceSSH";
  termux =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPvQ3V6Vr8L+ckUBinwDYLLkortxz5S8tVGGKMSEcpdU u0_a522@localhost";
  roamMac =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE8e2iWRYdr+Wzy9uBca/VLzexcWCnHwYb8TQhaeGA7j pippijn@pippijn-mac.roam.internal";

  # ⚠ `pippijn@xinutec.org` (ed25519 AND RSA) WAS HERE UNTIL 2026-08-23 and is
  # RETIRED, not moved — do not re-add it to either list. It was simultaneously
  # Pippijn's personal key and, as agenix `root-ssh-{ed25519,rsa}`, the fleet's
  # inter-host root credential, which is #1049. Why it was retired rather than
  # rotated, and why deleting its ciphertext bought nothing: `agenix/README.md`.

  # The fleet's OWN inter-host root key (#1049 step 1), generated 2026-08-22.
  # Private half: agenix `root-ssh-fleet`, at /root/.ssh/id_fleet on all four
  # hosts. It is not in the `pippijn` list below and never will be — that is the
  # entire difference between it and the two above.
  fleetRoot =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJX2wZbfLaVDaDGdDkEFna5dalacJqicRu1NzwYAEq1y fleet-root@xinutec";

  # Where the shared keys may be used FROM. Measured, not guessed: every
  # `Accepted publickey for root` on all four hosts over the 30 days to
  # 2026-08-21. Every recurring connection was odin; everything else was a
  # person, on one day.
  #
  #   odin -> amun    1,288 via 10.100.0.3 + 148 via 5.196.65.240
  #   odin -> isis    2,219 via 10.100.0.3 + 313 via 5.196.65.240
  #   odin -> odin       12 via 127.0.0.1   (the restore drill's loopback)
  #   amun -> isis       22, ALL on Jul 23, one evening
  #   isis -> odin        8, ALL on Aug 01, two sittings
  #   isis -> amun        2, both on Aug 11, the picade move
  #   geb  -> odin        1, Aug 10, its install day
  #
  # ⚠ BOTH OF ODIN'S ADDRESSES, and this is the line that would have broken the
  # backup. odin reaches the others over the VPN normally and over its public
  # address when the tunnel is down — 461 logins in 30 days took the public
  # path, i.e. exactly the circumstance in which a backup most needs to work.
  #
  # ⚠ 127.0.0.1 IS NOT PADDING. The restore drill ssh's odin to itself
  # (machines/odin/drill/*.sh, and `--host odin` in backups.nix); those 12
  # logins arrive from the loopback, not from 10.100.0.3.
  #
  # What this drops: amun<->isis and isis/geb->odin. None of it was automation —
  # nothing in either host's config reaches the other over ssh — and the Mac key
  # still reaches every host, so the interactive work those represent is done
  # from the Mac instead.
  fromOdin = "from=\"10.100.0.3,5.196.65.240,127.0.0.1,::1\"";
in
{
  # The person: installed on the `pippijn` user, unrestricted.
  #
  # ⚠ THIS LIST IS NOW THE WHOLE ANSWER for the `pippijn` account. sshd consults
  # both `/etc/ssh/authorized_keys.d/pippijn`, which this writes, and
  # `~pippijn/.ssh/authorized_keys`, which it cannot see; the second held three
  # of these keys and two nobody had enumerated. The home file is deleted on
  # every host as of 2026-08-22, so what is written here is what may log in — but
  # nothing ENFORCES that, because a file a rebuild does not manage is a file a
  # rebuild cannot remove. Re-creating it puts the fleet back where it was.
  pippijn = [
    macMini
    juiceSsh
    termux
    roamMac
  ];

  # root: the Mac unrestricted, the shared keys bound to odin.
  #
  # NOT `restrict`, deliberately. That would also drop pty, port and agent
  # forwarding, and the drill runs kubectl/docker/mariadb-dump over this
  # credential — a general shell it genuinely needs (measured; see #1049). The
  # bound here is on WHERE the key may be used, which is the property that
  # closes the mesh. Narrowing WHAT it may run is a separate, harder question.
  # ⚠ THE SHARED KEYS ARE IN NEITHER LIST NOW. #1049 took them off root on
  # 2026-08-22 because the fleet must not authenticate to itself with a
  # credential that is also a person; 2026-08-23 took them off the person as
  # well, because their private halves are published. See the note above the
  # `let` bindings that used to be here.
  root = [
    macMini
    "${fromOdin} ${fleetRoot}"
  ];
}
