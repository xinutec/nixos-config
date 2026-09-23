# A host's plan timers, read from xinutec-infra's plan/tables/schedule.json in
# the revision this host pins plan-run at. The table is where each timer's
# calendar is held against the windows of the plan it applies and the monitor
# that watches it (xinutec-infra plan/core/tests/schedule.rs), so a timer here
# cannot sample a plan from a different commit than its binary.
#
# `timerFor unit` fails evaluation when the table has no row for this host and
# unit: a timer that applies a plan and is not in the table is the case the
# table exists to rule out.
{ lib, src, host }:

let
  rows = builtins.fromJSON (builtins.readFile (src + "/plan/tables/schedule.json"));
in
{
  timerFor = unit:
    let
      mine = builtins.filter (r: r.host == host && r.unit == unit) rows;
    in
    assert lib.assertMsg (builtins.length mine == 1)
      "plan-schedule: ${host} has no single row for ${unit} in schedule.json";
    let r = builtins.head mine; in
    { OnCalendar = r.on_calendar; }
    // lib.optionalAttrs (r.jitter_s > 0) {
      RandomizedDelaySec = "${toString r.jitter_s}s";
    };
}
