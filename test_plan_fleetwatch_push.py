"""What the plan → fleetwatch translation must say, and must not.

The push itself is one `urlopen`; what is worth pinning is the mapping, because
every way it can be wrong is a way the fleet reports something untrue about
itself and nobody is watching a terminal to catch it.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path
from typing import Any

_spec = importlib.util.spec_from_file_location(
    "plan_fleetwatch_push", Path(__file__).parent / "plan-fleetwatch-push.py"
)
assert _spec and _spec.loader
push = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(push)


def _converged(**over: Any) -> dict[str, Any]:
    obj: dict[str, Any] = {
        "outcome": "converged",
        "fact": "",
        "detail": "all firewall goals hold",
        "looked": [],
        "held": 2,
        "unread": 0,
        "adrift": 0,
    }
    obj.update(over)
    return obj


def _by_label(checks: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    return {str(c["label"]): c for c in checks}


def test_a_converged_plan_is_two_passing_checks() -> None:
    checks = push.verdict_checks("firewall", 0, _converged(), "")
    got = _by_label(checks)
    assert set(got) == {"firewall: outcome", "firewall: verified"}
    assert got["firewall: outcome"]["verdict"] == "pass"
    assert got["firewall: verified"]["verdict"] == "pass"


def test_labels_are_qualified_by_plan() -> None:
    # fleetwatch matches mutes on (source, collector, label) and ignores
    # section, so a bare `outcome` would be one identity shared by every plan on
    # the host — muting the noisy one would silence the rest.
    checks = push.verdict_checks("integrity", 0, _converged(), "")
    for c in checks:
        assert str(c["label"]).startswith("integrity: ")


def test_blocked_fails_and_names_the_goal() -> None:
    # A verdict that said only "blocked" would send someone to read both rows.
    # The firewall plan's two are DIFFERENT alarms.
    obj = _converged(outcome="blocked", fact="firewall:nothing-undeclared",
                     detail="no automatic remedy", held=0)
    checks = push.verdict_checks("firewall", 1, obj, "")
    outcome = _by_label(checks)["firewall: outcome"]
    assert outcome["verdict"] == "fail"
    assert "firewall:nothing-undeclared" in str(outcome["detail"])


def test_pending_work_warns_rather_than_fails() -> None:
    # Exit 2 on a read-only run is the world having drifted and the run
    # correctly declining to change it — real, but not the same as blocked.
    checks = push.verdict_checks("backup", 2, _converged(outcome="pending"), "")
    assert _by_label(checks)["backup: outcome"]["verdict"] == "warn"


def test_a_plan_that_could_not_be_read_does_not_report_as_holding() -> None:
    # The #734 shape, one layer up: a run whose probes all failed converges
    # vacuously. `outcome` passing is not the whole truth, and `verified` is
    # what stops that being the only thing said.
    obj = _converged(held=0, unread=2)
    checks = push.verdict_checks("firewall", 0, obj, "")
    got = _by_label(checks)
    assert got["firewall: outcome"]["verdict"] == "pass"
    assert got["firewall: verified"]["verdict"] == "warn"
    assert "2 could not be read" in str(got["firewall: verified"]["observed"])


def test_a_goal_that_did_not_hold_also_warns_verified() -> None:
    checks = push.verdict_checks("firewall", 0, _converged(held=1, adrift=1), "")
    assert _by_label(checks)["firewall: verified"]["verdict"] == "warn"


def test_a_blocked_run_verified_nothing_and_must_not_read_as_clean() -> None:
    # Blocking short-circuits before any goal is counted, so all three are zero
    # and "0 could not be read" would otherwise be a clean bill of health for a
    # run that established nothing. Found by ABLATION on isis 2026-08-12 — with
    # iptables off the unit's PATH the outcome check failed correctly and this
    # one still said pass.
    obj = _converged(outcome="blocked", fact="firewall:declared-applied",
                     detail="cannot judge", held=0, unread=0, adrift=0)
    got = _by_label(push.verdict_checks("firewall", 1, obj, ""))
    assert got["firewall: outcome"]["verdict"] == "fail"
    assert got["firewall: verified"]["verdict"] == "warn"
    assert "established nothing" in str(got["firewall: verified"]["observed"])


def test_a_report_with_no_counts_fails_rather_than_reading_them_as_zero() -> None:
    # "0 could not be read" is the strongest claim this producer makes. A runner
    # whose report changed shape must not be able to make it by omission — that
    # is #734 with the evidence deleted rather than merely unstated.
    obj = _converged()
    del obj["unread"]
    got = _by_label(push.verdict_checks("firewall", 0, obj, ""))
    assert got["firewall: verified"]["verdict"] == "fail"
    assert "no goal counts" in str(got["firewall: verified"]["observed"])


def test_a_boolean_is_not_a_count() -> None:
    # bool is a subclass of int in Python, so `True` would otherwise sail
    # through as a count of 1 that nobody wrote.
    got = _by_label(push.verdict_checks("firewall", 0, _converged(unread=True), ""))
    assert got["firewall: verified"]["verdict"] == "fail"


def test_a_broken_tool_is_red_not_silent() -> None:
    # A producer that dies quietly looks exactly like a fleet with nothing to
    # say, which is the failure this whole file exists to prevent.
    checks = push.verdict_checks("firewall", 3, None, "thread 'main' panicked")
    assert len(checks) == 1
    assert checks[0]["verdict"] == "fail"
    assert "panicked" in str(checks[0]["detail"])


def test_the_envelope_never_carries_a_source() -> None:
    # fleetwatch derives `source` from the bearer token. Sending one would be a
    # producer claiming to be a machine it is not, which is the single thing the
    # token design guarantees against.
    report = push.build_report(
        "firewall", [], interval_s=3600, duration_ms=1,
        collected_at="2026-08-12T00:00:00.000+00:00", report_id="X",
    )
    assert "source" not in report
    assert report["collector"] == "plan-firewall"


def test_ulid_is_26_crockford_characters_and_moves() -> None:
    a, b = push.ulid(), push.ulid()
    assert len(a) == 26 and set(a) <= set(push._CROCKFORD)
    assert a != b, "a fixed id would make fleetwatch dedupe every report but one"


def test_extra_arguments_reach_plan_run_after_simulate(monkeypatch: Any) -> None:
    """`drill` needs `--host`/`--prod-host`, and the collector cannot guess them.

    Pinned at the argv, not at the parser, because the defect this closes was
    never about parsing: `plans = [ "drill" ]` produced a well-formed command
    that exited 3 — "a defect in the plan" — and reported a red every hour for
    ever. The module's own comment claimed such a plan was one more line.
    """
    seen: dict[str, Any] = {}

    class _Proc:
        returncode = 0
        stdout = "{}"
        stderr = ""

    def _fake(argv: list[str], **kw: Any) -> _Proc:
        seen["argv"] = argv
        return _Proc()

    monkeypatch.setattr(push.subprocess, "run", _fake)
    push.run_plan("/bin/plan-run", "drill", "/etc/plan/settings.json",
                  ["--host", "odin", "--prod-host", "isis"])

    assert seen["argv"] == [
        "/bin/plan-run", "drill", "--settings", "/etc/plan/settings.json",
        "--simulate", "--json", "--host", "odin", "--prod-host", "isis",
    ]


def test_extra_arguments_cannot_displace_simulate(monkeypatch: Any) -> None:
    """⚠ The read-only property must not depend on what is in the settings.

    `--simulate` is emitted BEFORE the extras, so nothing passed here can take
    its place. If someone puts `--apply` in `args`, both flags reach the runner
    and it refuses the pair outright rather than resolving them by precedence —
    the run fails loudly instead of converging something unattended.
    """
    seen: dict[str, Any] = {}

    class _Proc:
        returncode = 0
        stdout = "{}"
        stderr = ""

    def _fake(argv: list[str], **kw: Any) -> _Proc:
        seen["argv"] = argv
        return _Proc()

    monkeypatch.setattr(push.subprocess, "run", _fake)
    push.run_plan("/bin/plan-run", "drill", "/s.json", ["--apply"])

    argv = seen["argv"]
    assert "--simulate" in argv, "a collector must never be able to lose --simulate"
    assert argv.index("--simulate") < argv.index("--apply")


def test_no_extra_arguments_is_the_ordinary_case(monkeypatch: Any) -> None:
    """Fourteen of fifteen call sites pass nothing; that path must stay bare."""
    seen: dict[str, Any] = {}

    class _Proc:
        returncode = 0
        stdout = "{}"
        stderr = ""

    def _fake(argv: list[str], **kw: Any) -> _Proc:
        seen["argv"] = argv
        return _Proc()

    monkeypatch.setattr(push.subprocess, "run", _fake)
    push.run_plan("/bin/plan-run", "firewall", "/s.json")
    assert seen["argv"][-1] == "--json"


def test_an_extra_argument_that_looks_like_a_flag_parses() -> None:
    """⚠ The values ARE flags, and that is what broke this on odin.

    `--arg --host` makes argparse refuse with *expected one argument*: a
    separate value beginning with `-` is read as the next option. Only the
    `--arg=VALUE` form takes it literally. The unit failed on its first run,
    with the whole chain otherwise correct.
    """
    ns = push.parser().parse_args([
        "--plan", "drill",
        "--arg=--host", "--arg=odin", "--arg=--prod-host", "--arg=isis",
    ])
    assert ns.arg == ["--host", "odin", "--prod-host", "isis"]


def test_no_extra_arguments_parses_to_an_empty_list() -> None:
    """The bare form must not need `--arg` at all, or fourteen call sites pay
    for the one that needs it."""
    assert push.parser().parse_args(["--plan", "firewall"]).arg == []


def test_a_warn_says_how_many_steps_are_pending() -> None:
    """⚠ "warn: all goals hold" reads like a broken dashboard.

    Under `--simulate` the verdict comes from the exit code and the words come
    from the report, and those describe different moments: `outcome`/`detail`
    are about the END of the predicted trajectory, exit 2 means steps were
    predicted to get there. The count is what makes the amber mean something.
    """
    obj = _converged(detail="all drill goals hold", predicted=[{}, {}, {}])
    checks = _by_label(push.verdict_checks("drill", 2, obj, ""))
    assert checks["drill: outcome"]["verdict"] == "warn"
    assert checks["drill: outcome"]["observed"] == (
        "3 step(s) pending — converged: all drill goals hold"
    )


def test_a_converged_run_with_nothing_pending_does_not_say_zero() -> None:
    """`0 step(s) pending` on a green check is noise; the ordinary case stays
    the plain sentence it was."""
    checks = _by_label(push.verdict_checks("firewall", 0, _converged(predicted=[]), ""))
    assert checks["firewall: outcome"]["observed"] == "converged: all firewall goals hold"


def test_a_report_with_no_predicted_field_still_reads() -> None:
    """An older runner, or a shape change: absence must not crash the collector
    or invent a count."""
    obj = _converged()
    obj.pop("predicted", None)
    checks = _by_label(push.verdict_checks("firewall", 0, obj, ""))
    assert "pending" not in str(checks["firewall: outcome"]["observed"])
