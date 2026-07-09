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

  allHosts = [ amun isis odin ];
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

  # Root user's SSH private keys — one shared keypair of each type
  # across all hosts, used for inter-host root SSH (backup rsyncs and
  # the restore drill). Encrypted to every host plus the admin key.
  "root-ssh-ed25519.age".publicKeys = allHosts ++ [ admin ];
  "root-ssh-rsa.age".publicKeys = allHosts ++ [ admin ];

  # oauth2-proxy in front of recall, gated to the pippijn Nextcloud account. Only
  # isis runs the proxy, so it and the admin key are the recipients.
  "oauth2-proxy-recall-client-secret.age".publicKeys = [ isis admin ];
  "oauth2-proxy-recall-cookie-secret.age".publicKeys = [ isis admin ];

  # Cloudflare DNS-01 token for the recall.xinutec.org ACME cert (same token
  # already used by cert-manager's letsencrypt-dns ClusterIssuer, copied here
  # since this cert is issued host-side, not by k8s). isis + admin only.
  "cloudflare-dns01-token.age".publicKeys = [ isis admin ];
}
