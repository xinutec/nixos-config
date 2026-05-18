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
}
