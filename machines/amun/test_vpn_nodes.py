"""What a peer's liveness class MEANS for its verdict.

The producer reads amun's `wg show latest-handshakes`. These pin the one decision that
feeds the notification channel: an always-on peer that is down is a FAIL (alert); an
intermittent peer that is down is expected and stays quiet (SKIP). Getting this wrong
either re-floods the alerts with sleeping phones or, worse, silences a dead server.
"""

import importlib.util
import sys
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "vpn_nodes_push", Path(__file__).with_name("vpn-nodes-push.py")
)
assert _spec and _spec.loader
mod = importlib.util.module_from_spec(_spec)
# Register before exec: the @dataclass on Peer resolves its annotations via
# sys.modules[cls.__module__], which is None until the module is inserted.
sys.modules[_spec.name] = mod
_spec.loader.exec_module(mod)

NOW = 1_000_000
FRESH = 180


def verdict(intermittent: bool, ts: int) -> str:
    return str(mod.classify("peer", intermittent, ts, NOW, FRESH)["verdict"])


def test_always_on_up_passes() -> None:
    assert verdict(False, NOW - 10) == "pass"


def test_always_on_down_fails() -> None:
    """A server past the fresh window is a real fault — this is the alert."""
    assert verdict(False, NOW - 3600) == "fail"


def test_always_on_never_handshaked_fails() -> None:
    assert verdict(False, 0) == "fail"


def test_intermittent_up_still_passes() -> None:
    """When a phone IS connected, show it green — the class only changes what DOWN means."""
    assert verdict(True, NOW - 10) == "pass"


def test_intermittent_down_skips_not_fails() -> None:
    """The whole point: a sleeping phone/laptop/picade is expected, not a problem."""
    assert verdict(True, NOW - 3600) == "skip"


def test_intermittent_never_handshaked_skips() -> None:
    """A picade that is simply switched off never handshakes — that is not a fault."""
    assert verdict(True, 0) == "skip"


def test_boundary_at_fresh_secs_is_up() -> None:
    """Exactly fresh_secs old still counts as up (matches `wg`'s own active window)."""
    assert verdict(False, NOW - FRESH) == "pass"
    assert verdict(False, NOW - FRESH - 1) == "fail"


def test_age_value_is_emitted_for_charting() -> None:
    """A handshaked peer carries its age as a numeric value/unit for the trend chart;
    a never-connected peer has no age to report."""
    up = mod.classify("peer", False, NOW - 42, NOW, FRESH)
    assert up["value"] == 42.0 and up["unit"] == "s"
    never = mod.classify("peer", True, 0, NOW, FRESH)
    assert "value" not in never
