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
