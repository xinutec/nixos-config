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
  };
in
{
  environment.etc."plan/settings.json".source =
    pkgs.writeText "plan-settings.json" (builtins.toJSON settings);
  systemd.tmpfiles.rules = [ "d /var/lib/plan-run 0700 root root -" ];
}
