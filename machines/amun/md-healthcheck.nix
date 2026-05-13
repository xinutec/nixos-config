# Hourly heartbeat to healthchecks.io for amun's MD RAID state. Replaces
# the stock mdmonitor.service which insists on MAILADDR/PROGRAM and was
# stuck in "loaded failed". Healthchecks.io's own notification config
# (email pip88nl@gmail.com) covers both "RAID degraded" (explicit /fail
# ping) and "amun down" (heartbeat goes silent → dead-man-switch).

{ config, pkgs, lib, ... }:

let
  url = "https://hc-ping.com/ada69331-519a-455f-9957-8a208fdb4d8e";

  script = pkgs.writeShellScript "md-healthcheck" ''
    set -euo pipefail
    # Any "_" in /proc/mdstat indicates a missing member disk in some
    # array — array names like md0/md127 contain no underscores, so a
    # bare grep -F is sufficient.
    if ${pkgs.gnugrep}/bin/grep -qF '_' /proc/mdstat; then
      ${pkgs.curl}/bin/curl -fsS --retry 2 -m 10 \
        --data-binary @/proc/mdstat \
        "${url}/fail" > /dev/null
      exit 1
    fi
    ${pkgs.curl}/bin/curl -fsS --retry 2 -m 10 "${url}" > /dev/null
  '';
in {
  systemd.services.md-healthcheck = {
    description = "MD RAID heartbeat → healthchecks.io";
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
