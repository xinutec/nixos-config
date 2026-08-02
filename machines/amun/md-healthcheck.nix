# Hourly heartbeat to healthchecks.io for amun's MD RAID state. Replaces
# the stock mdmonitor.service which insists on MAILADDR/PROGRAM and was
# stuck in "loaded failed". Healthchecks.io's own notification config
# (email pip88nl@gmail.com) covers both "RAID degraded" (explicit /fail
# ping) and "amun down" (heartbeat goes silent → dead-man-switch).

{ config, pkgs, lib, ... }:

let
  # Only the base is spelled here. The check ID is a bearer capability —
  # anyone holding it can mark this check UP and silence the very alarm
  # it exists to raise — so it lives in agenix and is read at run time.
  # See agenix/secrets.nix. Read at run time and not with builtins.readFile
  # because agenix decrypts during activation, i.e. after evaluation.
  base = "https://hc-ping.com";

  script = pkgs.writeShellScript "md-healthcheck" ''
    set -euo pipefail
    id="$(cat ${config.age.secrets."hc-ping-md".path})"
    # Any "_" in /proc/mdstat indicates a missing member disk in some
    # array — array names like md0/md127 contain no underscores, so a
    # bare grep -F is sufficient.
    if ${pkgs.gnugrep}/bin/grep -qF '_' /proc/mdstat; then
      ${pkgs.curl}/bin/curl -fsS --retry 2 -m 10 \
        --data-binary @/proc/mdstat \
        "${base}/$id/fail" > /dev/null
      exit 1
    fi
    ${pkgs.curl}/bin/curl -fsS --retry 2 -m 10 "${base}/$id" > /dev/null
  '';
in {
  age.secrets."hc-ping-md".file = ../../agenix/hc-ping-md.age;

  systemd.services.md-healthcheck = {
    description = "MD RAID heartbeat → healthchecks.io";
    # Persistent=true on the timer causes catch-up runs to fire
    # immediately at boot, before networking is configured; wait for
    # network-online or curl fails NXDOMAIN.
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${script}";
    };
  };
  systemd.timers.md-healthcheck = {
    description = "Hourly MD RAID heartbeat";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnCalendar = "hourly";
      Persistent = true;
    };
  };

  # Mask the stock mdmonitor.service — we replaced it with the above.
  systemd.services.mdmonitor.enable = false;
}
