# SSH public keys.
#
# TWO LISTS, and the difference between them is the whole point (#1049).
#
# `pippijn` is the person: every key Pippijn logs in with, installed on the
# `pippijn` USER account. `root` is the same keys with the shared ones bound to
# the only source that has ever legitimately used them.
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

  # The shared fleet keys. Their private halves live on all four hosts.
  sharedEd25519 =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFE2kAUmlendXKv1GGul0q/Nys/mGbMvBsdGvfqUzymK pippijn@xinutec.org";
  sharedRsa =
    "ssh-rsa AAAAB3NzaC1yc2EAAAABIwAABAEA3kaCLPpCNKW5QbB4bHxvhg2DvYgH6EgDjA48K3HuRdNqbFKtMLrDAwGtUfPdmjMZzh6woMiGER0T2IeEIwyw+MttcVkt1Rpd+K49uUaCMjqxy5wR8Q327XFTM7ysf38fyfr9qS3HHbKG95oKKYMYUNiFhr2t8RvAO39Be+yyedzCLbfnUirfRuRqcVptznySkFHWEPHk5O4U4yzq4bkMb9m1DgZKY2v0vR7FniP3ypNpmaKKZdQykcIC2clLvWovkwW1AclOdSeVyHZpGU61v6DGnKRaNhPDagaMm2ZTOGB8uW3M66+nRGACNkgKdW6LO3D05M1afnS67bJ9wOm5yoBaDD7G3csma1I3Sx48/s7UgVs6vhIc9ViWpR0aHAwYC40/qQeCBNO1WQ5m9MG42Jq5X5h+pr2HOIjVskNOFh2fNyCgmLN98C7aavYIo2XBknJoa5M5pZ4nJl2IANLylBLzizTk5ZO618zE0c+9/YPS2Y0YRoTne9t/p8TkSCsRLfbAgCKN/uQiv1gkqajY+P7rnjPVBAKbGdw8f7651Ovi9Q/fE5S171Dha+2Rnjz9I60+PepiLuDNgx7fhqYuEtAMtePpt5d7wXKHRTb+wQqvJUREcIGgxmoMe7hbUF1dMqDZoU9jW9wOMKHTfjtMZhWQjICHy5cjPXNB4p3lXcUBY1khPeTNZZ5y9WZaB4Snq1z8ZdZ7sqDw5v3kkNUHBV80+s7pfIiUErhVV9a0y8xysUrM93EuPIdmojpLyV9/KoJttp22l7LU+xrIkwiid+BylGOxz5p7j/Q8TfpH4OU1dJ48SIkoee7dzZe/zbt21vC9J6ppDRQ+L4ALy2p9MSyjkFvHX/1Wdbfqg4xTZsJ33X9zJqjYbotWKzrH3dtD4dFipyWSTDvfnr3OYKIeEU1ur+8MZRqRu0fP7kDWzTl9jESR4YIVwSwe/1z98BYGGvlOHBATwSsp0XyX6phBCUzgJ5zXdpZLSMcFalGRbjVdhXdfo6S23qw3pO74cVQ9pFzUeBsj61MkF7BmMG1i98F5RDkAf0DlRksnBcHIOztxoE4aaQDA/QI/mFT5uBmSKI/XkA20UPLln0xYwFAd04bdY+qimrRXpw1aRl0ByqynLPFdvmzMBLSkys5llp+v1Qq7gDU11G68ocOh6F0T4x6IHWXKmevOiO3OUg99jd4Iy1j5WGmAL+fo0XlXXQwTAFIfs+ewAwxAF8twbOEEPQwIDqssXOWjL0NKl0pg9X3swSZrhhEG2ADHYwe62w2TSYI0Nov180rwUeWu7e4yE4z7I+txCxK82/Luo9qOhfALmuaSFWmz1SAuktDsM6SsJOw4nJ+d34tGRplITr0BuQ== pippijn@xinutec.org";

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
  pippijn = [
    macMini
    sharedEd25519
    sharedRsa
  ];

  # root: the Mac unrestricted, the shared keys bound to odin.
  #
  # NOT `restrict`, deliberately. That would also drop pty, port and agent
  # forwarding, and the drill runs kubectl/docker/mariadb-dump over this
  # credential — a general shell it genuinely needs (measured; see #1049). The
  # bound here is on WHERE the key may be used, which is the property that
  # closes the mesh. Narrowing WHAT it may run is a separate, harder question.
  root = [
    macMini
    "${fromOdin} ${sharedEd25519}"
    "${fromOdin} ${sharedRsa}"
  ];
}
