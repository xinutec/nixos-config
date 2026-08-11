# `plan-run picade --apply` on a timer: the picade fleet CONVERGES, rather than
# being observed drifting for ever.
#
# Sibling of picade-health.nix, and the split between them is the point. That
# one REPORTS — it runs the same plan `--simulate`, reaches the world exactly as
# much as observing does, writes nothing, and pushes a verdict per cabinet per
# layer to fleetwatch. This one ACTS. A reporter that also writes is a different
# kind of thing from a reporter, and the two would not want the same cadence,
# the same failure handling or the same blast radius.
#
# ┌─ WHY THIS EXISTS AT ALL — the recurring yellow that only closes by ACTING ──┐
# │ EmulationStation rewrites `es_settings.cfg` at exit with byte-identical     │
# │ content and a fresh mtime, so base drift goes yellow after anyone plays a   │
# │ cabinet and stays yellow. Measured 2026-08-09: a push closes it — `rsync    │
# │ -a` restores canonical's mtime and the next check is clean.                 │
# │                                                                            │
# │ So the permanent warn was an artefact of a checker with no remedy.          │
# │ `picade health` observed and warned for ever; `Fact::PicadeLayerInSync`     │
# │ has `Effect::PicadePushLayer` and can close it, at the cost of one small    │
# │ rsync per play session. That only holds if something runs `--apply`, which  │
# │ nothing did until this file. Approved by Pippijn 2026-08-11.                │
# └────────────────────────────────────────────────────────────────────────────┘
#
# ⚠ WHAT AN UNATTENDED APPLY WILL DELETE, stated rather than left to be found.
# Three of the four layers cannot delete by construction: `Base` is
# `mode = Upsert`, `Boot` is `prune = No`, and `Overlay` has no mode field at
# all. The fourth, `Operator`, force-pushes as an exact mirror and DOES delete —
# `rsync.py:build_operator_push_invocations` appends `--delete` unconditionally,
# because a path the fleet declares it owns holding a file nobody put there is
# the defect being corrected.
#
# That bites in exactly one place. OPERATOR_PATHS is six entries and five are
# FILES, where `--delete` is a no-op:
#
#     /etc/wpa_supplicant/wpa_supplicant.conf   file
#     /etc/sudoers                              file
#     /etc/ssh/sshd_config                      file
#     /etc/hosts                                file
#     /boot/config.txt                          file
#     /etc/sudoers.d                            DIRECTORY  <- pruned hourly
#
# So an hourly apply removes anything in a cabinet's `/etc/sudoers.d` that
# canonical does not have. That is the intended behaviour of an operator path
# and it is also the one thing here that can destroy something a human put
# somewhere by hand. `deploy --prune` and `--fresh`, the wide deletions, stay
# operator-invoked and are not expressible from `picade.dhall` at all.
#
# VERIFIED BY HAND FIRST, the way odin's backup cutover was: a full
# `plan-run picade --apply` ran on 2026-08-11 before this file existed and came
# back `converged: all picade goals hold` with ZERO effects — 12 live goals
# holding, 8 unreadable (picade3/picade4, off for months, #70). So the first
# scheduled run is also the safest possible one: it proves the wiring without
# changing anything. It equally means the PUSH path is unexercised by that run —
# what covers it is `runner/tests/picade_drift.rs`, which pins the probe and the
# push to one argv, and `picade deploy` having done this for years.

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
