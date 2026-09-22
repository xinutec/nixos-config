# agenix recipient rules: which keys can decrypt each .age file here. Recipients are
# each host's SSH host key plus the fleet admin age key (on the Mac and offline), which
# can always re-encrypt — e.g. to onboard a reinstalled host with a fresh host key.
let
  admin = "age16dmqs08qf9szzzzdx3w3na8tkavypq3q22dc393kgn6sv4myagtsuh6szu";

  amun = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBkU1yoga0n9hLZTmfzoj1CNPUs7lE7VzqQ6R1EiFdi6";
  isis = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFXU6IYZCUEdYeu4I83e8kp9haP7DhajHWXuajwxWVCB";
  odin = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBGB7SpLmQnKQZIiYgigWvyk3Gr5kRJ6LXlVASgnunC/";

  # A NixOS host, so it needs every secret base-configuration declares
  # unconditionally, not just its own WireGuard key.
  geb = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHknQkqhrNDTXrL0o6omTOb/1LZNF4/IWbMrGgpgKzPZ";

  # REBUILT on purpose, so its host key changes repeatedly. Re-keying is part of
  # that cycle, not an incident.
  shu = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGE069LNzN0xeKpgYwzWR9ABi4SIDf/CjwFQZ0WT/WP6";

  # Same class as geb and shu.
  tefnut = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINFHDsCe+/BArl+STKvhvucxNCdoeMjFwdJvy5g51c8s";

  allHosts = [ amun isis odin geb shu tefnut ];
in {
  # Grafana Cloud / Mimir push — every host runs the alloy metrics agent.
  "grafana-agent-password.age".publicKeys = allHosts ++ [ admin ];

  # odin is the only backup host. The admin key can still decrypt, so a reinstalled
  # odin can be re-onboarded without losing the repo.
  "restic-password.age".publicKeys = [ odin admin ];

  # The Mac's two restic passwords. NOTHING HERE READS THEM — the jobs run on the
  # Mac, which has no NixOS module. They are here to be REPLICATED.
  #
  # ⚠ ODIN, NOT GEB. geb holds /data/restic-mac, so encrypting its password to geb
  # would put the repository and its key on one machine. Their only other copies
  # are the Mac's disk and the recovery bundle beside it, both in the house — odin
  # is what makes this a third copy that survives the house (#836).
  "geb-restic-password.age".publicKeys = [ odin admin ];
  "offsite-restic-password.age".publicKeys = [ odin admin ];

  # Hub-and-spoke, so a host only ever needs its own key.
  "wireguard-amun.age".publicKeys = [ amun admin ];
  "wireguard-isis.age".publicKeys = [ isis admin ];
  "wireguard-odin.age".publicKeys = [ odin admin ];
  "wireguard-geb.age".publicKeys = [ geb admin ];
  "wireguard-shu.age".publicKeys = [ shu admin ];
  "wireguard-tefnut.age".publicKeys = [ tefnut admin ];

  # Inter-host root SSH: backup rsyncs and the restore drill.
  # ⚠ A key of its own (#1049), never a re-key of `pippijn@xinutec.org` — that one
  # is also the key Pippijn logs in with, so reading any one host's /root/.ssh
  # would yield the credential that is him.
  "root-ssh-fleet.age".publicKeys = allHosts ++ [ admin ];

  # healthchecks.io check IDs, each a bearer capability: anyone holding one can GET
  # it to mark the check UP, which SILENCES the dead-man's switch. ⚠ This repo is
  # PUBLIC, so an ID in the clear is one a crawler can follow.
  #
  # Only the ID is secret — the base URL stays spelled out in each module. One file
  # per check, so no host holds another's.

  # home.xinutec.org's ingest token, the same value the Mac's Keychain and the phone
  # app hold. The house's always-on BLE receivers only: a token is a capability and
  # the rented machines have no sensors to push.
  "home-ingest-token.age".publicKeys = [ geb shu tefnut admin ];

  # The IQAir AirVisual Pro's SMB password, so shu can read and push it (#1409).
  # shu ONLY: it already reaches the Pro on the home LAN, so no new access.
  #
  # ⚠ The Mac keeps the same value in its Keychain (`airvisual-pro-smb`), which is
  # not in any repo. Rotating the Pro's password means changing BOTH.
  "airvisual-smb-password.age".publicKeys = [ shu admin ];

  # isis's DNS-01 token for every certificate its host nginx serves.
  "acme-cloudflare.age".publicKeys = [ isis admin ];

  "hc-ping-md.age".publicKeys = [ amun admin ];
  "hc-ping-backup.age".publicKeys = [ odin admin ];
  "hc-ping-drill.age".publicKeys = [ odin admin ];
  # The weekly `restic check` on odin's own repository.
  "hc-ping-integrity.age".publicKeys = [ odin admin ];
}
