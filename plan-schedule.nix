# A host's plan timers, from xinutec-infra's plan/tables/schedule.json at the
# revision this host pins plan-run at, where each is tested against its plan's
# windows and its monitor. A unit with no row fails evaluation.
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
