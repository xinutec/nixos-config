# `plan-run picade --apply` on a timer, so the picade fleet CONVERGES rather than
# being observed drifting for ever. Sibling of picade-health.nix, which only REPORTS —
# a reporter that also writes is a different kind of thing, and would not want the
# same cadence or blast radius.
#
# It exists because EmulationStation rewrites es_settings.cfg at exit with identical
# content and a fresh mtime, so drift went yellow after anyone played and stayed
# yellow. Only an apply can close it.
#
# ⚠ WHAT AN UNATTENDED APPLY DELETES: three layers cannot delete by construction, but
# `Operator` force-pushes an exact mirror with `--delete`. Five of its six paths are
# files, where that is a no-op; the sixth is `/etc/sudoers.d`, so an hourly apply
# removes anything there that canonical does not have. Intended, and the one thing
# here that can destroy something a human put on a cabinet.
{ config, pkgs, lib, planRun, ... }:

{
  systemd.services.plan-picade-apply = {
    description = "Converge the picade fleet against canonical";
    after = [ "wireguard-wg0.service" "network-online.target" ];
    wants = [ "network-online.target" ];

    # rsync and ssh are what the effects actually run; plan-run itself decides
    # nothing about the world it cannot read. A unit's `path` IS its whole PATH
    # — /run/current-system/sw/bin is NOT on it — which picade-health.nix
    # learned the expensive way on 2026-08-11.
    path = [ pkgs.openssh pkgs.rsync ];
    environment.HOME = "/root";

    serviceConfig = {
      Type = "oneshot";
      # root@isis is the identity that reaches every cabinet over WireGuard with
      # the shared fleet key, and the one whose known_hosts holds them.
      #
      # By store path rather than the name on PATH, as odin's backup staging
      # does: this pins the run to the binary this generation was built and
      # tested with, instead of whichever generation is current when the timer
      # fires.
      #
      # `--apply` because observe is the default — the runner is handed an
      # `Effect` only under apply, so a missing flag here would converge nothing
      # and report success.
      ExecStart =
        "${planRun}/bin/plan-run picade --settings /etc/plan/settings.json --apply";

      # Twenty goals, two of them against cabinets that answer at TCP-timeout
      # speed. Comfortably under the hour between runs, so a wedged run cannot
      # still be going when the next one starts.
      TimeoutStartSec = "30min";
    };
  };

  systemd.timers.plan-picade-apply = {
    description = "Converge the picade fleet hourly";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # HOURLY, and at :07 deliberately. picade-health runs on the *:0/15 grid,
      # so anything on that grid would have two rsyncs walking the same 150,000
      # files at the same moment. :07 is clear of :00/:15/:30/:45.
      #
      # Hourly rather than every fifteen minutes because of what this closes: an
      # mtime that changes when someone stops playing. Four times an hour would
      # cost four times the traffic to notice the same thing later the same
      # hour.
      OnCalendar = "*:07";
      # A cabinet that drifted while isis was down is still drifted when it
      # comes back, so catching up is the correct behaviour rather than waiting
      # out the hour.
      Persistent = true;
    };
  };
}
