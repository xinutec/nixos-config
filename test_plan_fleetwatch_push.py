"""What the pusher must do around the runner's checks, and must not.

The checks themselves are graded in plan-core (`core/tests/fleetwatch.rs`
holds those cases); what is pinned here is the boundary: the command, its
read-only flag, a dead runner, the envelope and the kept report.
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


def test_a_broken_tool_is_red_not_silent() -> None:
    # A producer that dies quietly looks exactly like a fleet with nothing to
    # say, which is the failure this whole file exists to prevent.
    checks = push.verdict_checks("firewall", 3, None, "thread 'main' panicked")
    assert len(checks) == 1
    assert checks[0]["verdict"] == "fail"
    assert checks[0]["label"] == "firewall: outcome"
    assert "panicked" in str(checks[0]["detail"])


def test_the_runners_checks_pass_through_untouched() -> None:
    # Grading is the core's; a pusher that edited a check would be a second
    # judge, which is what this replaced.
    theirs: list[dict[str, object]] = [
        {"section": "firewall", "label": "firewall: outcome", "verdict": "warn", "observed": "x"},
    ]
    assert push.verdict_checks("firewall", 2, theirs, "") == theirs


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
        stdout = "[]"
        stderr = ""

    def _fake(argv: list[str], **kw: Any) -> _Proc:
        seen["argv"] = argv
        return _Proc()

    monkeypatch.setattr(push.subprocess, "run", _fake)
    push.run_plan("/bin/plan-run", "drill", "/etc/plan/settings.json",
                  ["--host", "odin", "--prod-host", "isis"])

    assert seen["argv"] == [
        "/bin/plan-run", "drill", "--settings", "/etc/plan/settings.json",
        "--simulate", "--fleetwatch", "--host", "odin", "--prod-host", "isis",
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
        stdout = "[]"
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
        stdout = "[]"
        stderr = ""

    def _fake(argv: list[str], **kw: Any) -> _Proc:
        seen["argv"] = argv
        return _Proc()

    monkeypatch.setattr(push.subprocess, "run", _fake)
    push.run_plan("/bin/plan-run", "firewall", "/s.json")
    assert seen["argv"][-1] == "--fleetwatch"


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


def test_the_last_report_is_kept_whole_and_replaces_the_one_before(tmp_path: Path) -> None:
    import json

    path = tmp_path / "plan-firewall.json"
    path.write_text("half of an older one")
    report = push.build_report(
        "firewall",
        [{"section": "firewall", "label": "firewall: outcome", "verdict": "pass", "observed": "converged"}],
        interval_s=3600, duration_ms=1, collected_at="2026-10-13T12:00:00.000+00:00",
        report_id="01ARZ3NDEKTSV4RRFFQ69G5FAV",
    )
    push.write_last_report(path, report)
    assert json.loads(path.read_text()) == report
    assert not (tmp_path / "plan-firewall.json.tmp").exists()
    assert [p.name for p in tmp_path.iterdir()] == ["plan-firewall.json"]


def test_reads_asks_plan_run_with_the_judges_own_arguments(monkeypatch: Any) -> None:
    """deploy-check asks each judge what hosts its plan reads, through the
    judge's own command line, so the answer is about the plan as judged."""
    seen: dict[str, Any] = {}

    class _Proc:
        returncode = 7

    def _fake(argv: list[str], **kw: Any) -> _Proc:
        seen["argv"] = argv
        return _Proc()

    monkeypatch.setattr(push.subprocess, "run", _fake)
    monkeypatch.setattr(push.sys, "argv", [
        "push", "--plan", "drill-report", "--plan-run", "/bin/plan-run",
        "--settings", "/etc/plan/settings.json", "--arg=--host", "--arg=odin", "--reads",
    ])

    assert push.main() == 7
    assert seen["argv"] == [
        "/bin/plan-run", "drill-report", "--settings", "/etc/plan/settings.json",
        "--host", "odin", "--reads",
    ]
