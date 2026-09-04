# geb's settings for `plan-run` — what the names in a plan mean HERE.
#
# The smallest such file in the fleet, and every empty field below is a decision
# rather than an unfinished edit. geb runs exactly ONE plan, `firewall`, whose
# two probes read `/etc/plan/declared-firewall.json` and `iptables -S` on this
# machine. Neither takes a path, a login or an address, so there is nothing for
# `roots`, `repos` or `hosts` to resolve.
#
# ⚠ `--settings` IS STILL REQUIRED. Only `mirror-check` runs without one, so an
# empty settings file is what a plan that needs no settings looks like — not a
# sign the file was never filled in. Adding hosts here "for later" would invite
# a plan whose rows this machine cannot answer.
#
# ⚠ NO `monitor.checks`, for the reason isis's file gives: a healthchecks id is
# a bearer capability and THIS REPOSITORY IS PUBLIC. `plans::firewall` never
# checks in, so nothing is lost. `Monitor::url_for` refuses a name it does not
# hold, so a plan that tried to ping from here would stop rather than post to a
# guessed URL.

{ pkgs, ... }:

let
  settings = {
    roots = { };
    repos = { };
    hosts = { };
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
