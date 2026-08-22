# agenix recipient rules — which keys can decrypt each .age secret in
# this directory. The agenix CLI reads this file (RULES) to know whom
# to encrypt each secret to.
#
# Recipients are each host's SSH host key (the identity agenix uses to
# decrypt at activation) plus the fleet admin age key — held on the Mac
# and in an offline copy — which can always decrypt and re-encrypt,
# e.g. to onboard a reinstalled host with a fresh host key.
let
  admin = "age16dmqs08qf9szzzzdx3w3na8tkavypq3q22dc393kgn6sv4myagtsuh6szu";

  amun = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBkU1yoga0n9hLZTmfzoj1CNPUs7lE7VzqQ6R1EiFdi6";
  isis = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFXU6IYZCUEdYeu4I83e8kp9haP7DhajHWXuajwxWVCB";
  odin = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBGB7SpLmQnKQZIiYgigWvyk3Gr5kRJ6LXlVASgnunC/";

  # The house box (#726), installed 2026-08-10. Not a Kubernetes node and not
  # public, but it is a NixOS host, so it needs every secret base-configuration
  # declares unconditionally — which is three of the four below, not just its
  # own WireGuard key.
  geb = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHknQkqhrNDTXrL0o6omTOb/1LZNF4/IWbMrGgpgKzPZ";

  allHosts = [ amun isis odin geb ];
in {
  # Grafana Cloud / Mimir push password — every host runs the alloy
  # metrics agent, so every host needs it.
  "grafana-agent-password.age".publicKeys = allHosts ++ [ admin ];

  # restic backup repo password — odin is the only backup host. The
  # admin key can still decrypt it, so a reinstalled odin can be
  # re-onboarded without losing access to the repo.
  "restic-password.age".publicKeys = [ odin admin ];

  # The Mac's two restic passwords. NOTHING IN THIS REPOSITORY READS THEM —
  # `offsite` and the geb backups run on the Mac, which has no NixOS module at
  # all (plan-fleetwatch.nix says so). They are here to be REPLICATED, not to be
  # consumed, and that is the whole point of the entry.
  #
  # Until 2026-08-21 each existed in exactly two places, both in the house and
  # both attached to the same Mac: the internal disk, and the recovery bundle on
  # /Volumes/Backup. `geb.dhall` backs the directory up into /data/restic-mac on
  # geb, which looks like a third copy and is not one — that repo is unlocked by
  # geb-password, so the copy is inside the box it opens. Lose the Mac and that
  # disk together and /data/restic-mac is unopenable: observe-data, recall,
  # dicom-scan-download, the credential exports (#836).
  #
  # ⚠ ODIN, NOT GEB, and the difference is the point. geb HOLDS
  # /data/restic-mac; encrypting its password to it would put the repository and
  # the key to it on one machine. odin holds neither, and is in-datacenter — so
  # this is also the copy that survives the house. Same rule as
  # restic-password.age above, for the same reason.
  #
  # The admin key decrypts both, as everywhere here — but it lives in those same
  # two in-house places, so it is odin that makes this a real third copy.
  "geb-restic-password.age".publicKeys = [ odin admin ];
  "offsite-restic-password.age".publicKeys = [ odin admin ];

  # WireGuard private keys — one per host. The VPN is hub-and-spoke,
  # so a host only ever needs its own key; each is encrypted just to
  # that host plus the admin key.
  "wireguard-amun.age".publicKeys = [ amun admin ];
  "wireguard-isis.age".publicKeys = [ isis admin ];
  "wireguard-odin.age".publicKeys = [ odin admin ];
  "wireguard-geb.age".publicKeys = [ geb admin ];

  # Root user's SSH private keys — one shared keypair of each type
  # across all hosts, used for inter-host root SSH (backup rsyncs and
  # the restore drill). Encrypted to every host plus the admin key.
  "root-ssh-ed25519.age".publicKeys = allHosts ++ [ admin ];
  "root-ssh-rsa.age".publicKeys = allHosts ++ [ admin ];

  # The fleet's OWN inter-host root key (#1049 step 1), generated 2026-08-22 for
  # this purpose and nothing else.
  #
  # ⚠ WHY A THIRD KEY RATHER THAN A RE-KEY OF THE TWO ABOVE. Their public halves
  # are `pippijn@xinutec.org` — the same key Pippijn logs in with personally. So
  # the private half of a PERSONAL identity sits in /root/.ssh on four hosts, two
  # of them internet-facing: reading one host's disk yields the credential that
  # is him. `fleet-root@xinutec` has no second job, appears in no personal key
  # list, and can therefore be rotated, confined or revoked without asking what
  # else it opens.
  #
  # The two above stay recipients until this one is verified on every edge; they
  # go in the same change that stops deploying them.
  "root-ssh-fleet.age".publicKeys = allHosts ++ [ admin ];

  # healthchecks.io check IDs. A check ID is a bearer capability, not a
  # name: anyone holding one can GET it to mark the check UP, which
  # SILENCES the dead-man's switch, or GET /fail to raise a false alarm.
  # It reveals nothing, but these three checks are exactly what notices
  # when the backup and the restore drill go quiet, so a leaked ID turns
  # "tell me when this stops" into "this never stops".
  #
  # They were literals in this repo — which is PUBLIC — from 2026-05-05
  # (backup, drill) and 2026-05-13 (md), and a crawler that merely
  # followed the URL would have reported a failed backup as successful.
  #
  # Only the ID is secret. The base URL stays spelled out in each module,
  # because where a host checks in is documentation, not a capability —
  # the same split plan/settings.json already makes between
  # `monitor.base_url` and the per-plan check name.
  #
  # One file per check rather than one shared file, on the wireguard
  # precedent: amun's RAID heartbeat and odin's backup are unrelated, and
  # neither host has any use for the other's.
  # home.xinutec.org's ingest token — the bearer credential a sensor receiver
  # POSTs readings with. The same value the Mac keeps in its Keychain and the
  # phone app holds; geb is the third receiver and the first that can be given
  # it declaratively. Only geb, because a token is a capability and the other
  # three machines have no sensors to push.
  "home-ingest-token.age".publicKeys = [ geb admin ];

  "hc-ping-md.age".publicKeys = [ amun admin ];
  "hc-ping-backup.age".publicKeys = [ odin admin ];
  "hc-ping-drill.age".publicKeys = [ odin admin ];
  # The weekly `restic check` on odin's own repository. Third of odin's
  # dead-man's switches and the last one to get an id — the check did not exist
  # until 2026-08-16, which is what #52 was actually waiting on once the runner
  # learned to read an id from a file.
  "hc-ping-integrity.age".publicKeys = [ odin admin ];
}
