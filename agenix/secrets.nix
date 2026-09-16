# agenix recipient rules: which keys can decrypt each .age file here. Recipients are
# each host's SSH host key plus the fleet admin age key (on the Mac and offline), which
# can always re-encrypt — e.g. to onboard a reinstalled host with a fresh host key.
let
  admin = "age16dmqs08qf9szzzzdx3w3na8tkavypq3q22dc393kgn6sv4myagtsuh6szu";

  amun = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBkU1yoga0n9hLZTmfzoj1CNPUs7lE7VzqQ6R1EiFdi6";
  isis = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFXU6IYZCUEdYeu4I83e8kp9haP7DhajHWXuajwxWVCB";
  odin = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBGB7SpLmQnKQZIiYgigWvyk3Gr5kRJ6LXlVASgnunC/";

  # A NixOS host, so it needs every secret base-configuration declares unconditionally,
  # not just its own WireGuard key.
  geb = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHknQkqhrNDTXrL0o6omTOb/1LZNF4/IWbMrGgpgKzPZ";

  # The box that gets REBUILT, so its host key changes deliberately and repeatedly.
  # Re-keying is part of that cycle, not an incident.
  shu = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGE069LNzN0xeKpgYwzWR9ABi4SIDf/CjwFQZ0WT/WP6";

  # Same class as geb and shu.
  tefnut = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINFHDsCe+/BArl+STKvhvucxNCdoeMjFwdJvy5g51c8s";

  allHosts = [ amun isis odin geb shu tefnut ];
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
  # Their other copies are both in the house and both on the same Mac: the
  # internal disk, and the recovery bundle on /Volumes/Backup. `geb.dhall` backs
  # that directory up into /data/restic-mac on geb, which looks like a third copy
  # and is not one — that repo is unlocked by geb-password, so the copy is inside
  # the box it opens. Lose the Mac and that disk together and /data/restic-mac is
  # unopenable: observe-data, recall, dicom-scan-download, the credential
  # exports (#836).
  #
  # ODIN, NOT GEB, and the difference is the point. geb HOLDS
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
  "wireguard-shu.age".publicKeys = [ shu admin ];
  "wireguard-tefnut.age".publicKeys = [ tefnut admin ];

  # Inter-host root SSH (backup rsyncs and the restore drill), encrypted to every
  # host plus the admin key. A key OF ITS OWN (#1049 step 1), never a re-key of
  # `pippijn@xinutec.org`: that one is also the key Pippijn logs in with, so
  # deploying it to /root/.ssh on four hosts, two internet-facing, makes reading
  # any one disk yield the credential that is him. `fleet-root@xinutec` has no
  # second job and can be rotated, confined or revoked without asking what else
  # it opens.
  "root-ssh-fleet.age".publicKeys = allHosts ++ [ admin ];

  # healthchecks.io check IDs. A check ID is a bearer capability, not a
  # name: anyone holding one can GET it to mark the check UP, which
  # SILENCES the dead-man's switch, or GET /fail to raise a false alarm.
  # It reveals nothing, but these three checks are exactly what notices
  # when the backup and the restore drill go quiet, so a leaked ID turns
  # "tell me when this stops" into "this never stops".
  #
  # This repo is PUBLIC, so an ID written into it in the clear is one a crawler
  # can follow — reporting a failed backup as successful.
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
  # POSTs readings with, the same value the Mac's Keychain and the phone app hold.
  # The house's always-on BLE receivers only, each pushing under its own `source`:
  # a token is a capability, and the rented machines have no sensors to push.
  "home-ingest-token.age".publicKeys = [ geb shu tefnut admin ];

  # The IQAir AirVisual Pro's SMB share password, so shu can read the Pro's
  # current reading and push it — a second source for air quality, where today
  # `airvisual-push` runs on the Mac and nowhere else (#1409).
  #
  # shu ONLY. The Pro is on the home LAN and shu already reaches it: no new
  # access, no new attack surface, one more credential held by one more machine
  # that is already inside the boundary.
  #
  # The Mac does NOT read this. It keeps the same value in its Keychain
  # (`airvisual-pro-smb`), which is where `airvisual.py` looks when no password
  # file is named. Two stores for one secret is worth knowing: rotating the
  # Pro's SMB password means changing BOTH, and the Mac's copy is not in any
  # repo.
  "airvisual-smb-password.age".publicKeys = [ shu admin ];

  "hc-ping-md.age".publicKeys = [ amun admin ];
  "hc-ping-backup.age".publicKeys = [ odin admin ];
  "hc-ping-drill.age".publicKeys = [ odin admin ];
  # The weekly `restic check` on odin's own repository.
  "hc-ping-integrity.age".publicKeys = [ odin admin ];
}
