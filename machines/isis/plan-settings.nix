# isis's settings for `plan-run` — what the names in a plan mean HERE.
#
# A plan says `PicadeLayerInSync { host = "picade0" }`; this says how to reach
# picade0. The split is the reconciler's central one: the plan is pure and
# carries no path, no login and no address, so the same plan is correct on a
# machine that resolves them differently.
#
# ┌─ WHY EVERY CABINET IS LISTED, WHEN THE RUNNER HAS A FALLBACK ──────────────┐
# │ `Settings::address_for` falls back to the host NAME when the map has no    │
# │ entry — and on this fleet the bare name does not resolve. Only the `.vpn`  │
# │ form does, from the `extraHosts` block base-configuration.nix builds out   │
# │ of network.nix:                                                            │
# │                                                                            │
# │     getent hosts picade0       -> nothing                                  │
# │     getent hosts picade0.vpn   -> 10.100.0.100                             │
# │                                                                            │
# │ So an omitted cabinet does not fail loudly at startup; it resolves to a    │
# │ name that does not exist and the probe comes back `Unreadable`, which for  │
# │ an advisory goal reads exactly like a cabinet that is switched off. All    │
# │ five are named here so that "cannot reach it" always means the cabinet and │
# │ never this file.                                                           │
# └────────────────────────────────────────────────────────────────────────────┘
#
# NO REPOS AND NO CHECKS, and both are deliberate rather than unfinished.
# `repos` is empty because no plan run here touches restic — that is odin's
# job. `monitor.checks` is empty because a healthchecks id is a bearer
# capability and THIS REPO IS PUBLIC; `plans::picade` never checks in, so
# nothing is lost. `Monitor::url_for` refuses a name it does not hold, so a plan
# that tried to ping from here would stop rather than post to a guessed URL.

{ pkgs, ... }:

let
  net = import ../../network.nix;

  cabinet = name: {
    inherit name;
    value = {
      user = "root";
      # root@isis already reaches every cabinet over WireGuard with the shared
      # fleet key — verified 2026-08-11 against picade0-2, the three that are
      # up. This is the same path `picade health` uses by hand.
      address = "${name}.vpn";
    };
  };

  settings = {
    roots = { };
    repos = { };
    hosts = builtins.listToAttrs (
      map cabinet [ "picade0" "picade1" "picade2" "picade3" "picade4" ]
      ++ [
        { name = "amun"; value = { user = "root"; address = "amun.vpn"; }; }
        { name = "odin"; value = { user = "root"; address = "odin.vpn"; }; }
      ]
    );
    monitor = {
      base_url = "https://hc-ping.com";
      checks = { };
    };
    stamps = "/var/lib/plan-run/stamps.json";
    # The host front door (#1325). `table` is the SAME frontdoor.json the nginx
    # module reads — deployed to /etc/plan below from `../../frontdoor.json`, the
    # one source — so the plan and the running config cannot describe different
    # name sets. The table is FLEET-WIDE (isis and amun names both), so a name is
    # probed at the interface of the cluster that SERVES it, not at isis's: the
    # runner resolves each name's model cluster through this map, which is why
    # both clusters are here even though the plan runs on isis. Addresses from
    # network.nix. amun is included so isis probes amun.xinutec.org and the apex
    # at amun's public IP — the gap the 2026-09-01 fake-cert outage lived in.
    frontdoor = {
      table = "/etc/plan/frontdoor.json";
      clusters = {
        "isis.xinutec.org" = {
          public_addr = net.nodes.isis.ipv4;
          vpn_addr = net.nodes.isis.vpn;
        };
        "amun.xinutec.org" = {
          public_addr = net.nodes.amun.ipv4;
          vpn_addr = net.nodes.amun.vpn;
        };
      };
    };
  };
in
{
  environment.etc."plan/settings.json".source =
    pkgs.writeText "plan-settings.json" (builtins.toJSON settings);
  # The model's rendered name table, the same file `frontdoor.nix` reads. One
  # source, two consumers — the plan cannot drift from the config it checks.
  environment.etc."plan/frontdoor.json".source = ../../frontdoor.json;
  systemd.tmpfiles.rules = [ "d /var/lib/plan-run 0700 root root -" ];
}
