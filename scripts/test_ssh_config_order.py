"""Does the ssh_config order check fire? Every case here is a config that is wrong.

The failure it guards is latent: `builtins.fetchGit` only reaches the network for a
revision the store lacks, so a host with the wrong order rebuilds happily and breaks
on the first pin bump. A check that cannot fail would leave that exactly as it was.
"""

import importlib.util
import sys
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "ssh_config_order", Path(__file__).with_name("ssh_config_order.py"))
assert _spec and _spec.loader
so = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = so
_spec.loader.exec_module(so)

SOUND = """
Host github.com
  IdentityFile /root/.ssh/id_github_infra

Match localuser root
  IdentityFile /root/.ssh/id_fleet
"""

INVERTED = """
Match localuser root
  IdentityFile /root/.ssh/id_fleet

Host github.com
  IdentityFile /root/.ssh/id_github_infra
"""


def faults(text: str) -> list[str]:
    return so.violations(so.directives(text))


def test_the_root_match_before_github_is_named() -> None:
    """Must fire. This is the whole reason the comment existed: root would offer the
    fleet key to GitHub, which is authorised on the fleet and not on GitHub."""
    out = faults(INVERTED)
    assert out, "an inverted ssh_config was not reported at all"
    assert any("AFTER" in f and "github.com" in f for f in out), out


def test_github_naming_the_fleet_key_is_named() -> None:
    """Must fire. Right order, wrong key — the same outcome by another route, which
    an ordering-only check would pass."""
    out = faults(SOUND.replace("id_github_infra", "id_fleet"))
    assert any("FLEET key" in f for f in out), out


def test_github_naming_no_key_is_named() -> None:
    """Must fire. With no IdentityFile of its own the block inherits whatever the
    later match pins, so the order holds and the outcome does not."""
    out = faults("Host github.com\n\nMatch localuser root\n  IdentityFile /root/.ssh/id_fleet\n")
    assert any("no IdentityFile" in f for f in out), out


def test_keywords_are_case_insensitive_like_ssh_itself() -> None:
    """Must fire. ssh_config keywords are case-insensitive, so a check matching
    `Host` exactly would pass a config spelled `host` that ssh reads identically —
    a green that means the check did not look."""
    out = faults(INVERTED.replace("Match", "match").replace("Host", "host"))
    assert any("AFTER" in f for f in out), out


def test_a_sound_config_passes() -> None:
    assert faults(SOUND) == []


def test_a_host_declaring_neither_has_nothing_to_order() -> None:
    assert faults("Host example.com\n  Port 22\n") == []


def test_comments_and_blank_lines_do_not_shift_the_order() -> None:
    noisy = "\n# a note\n\nHost github.com\n  IdentityFile /root/.ssh/id_github_infra\n\n# another\nMatch localuser root\n  IdentityFile /root/.ssh/id_fleet\n"
    assert faults(noisy) == []


def test_a_root_match_with_no_github_block_is_named() -> None:
    """Must fire. The order cannot be wrong if the block is missing, so an
    ordering-only check reports nothing — and root still offers the fleet key to
    GitHub. This is the shape that made the whole checker vacuous: `return` on a
    missing block reads as "nothing to order" rather than "I could not look"."""
    out = faults("Match localuser root\n  IdentityFile /root/.ssh/id_fleet\n")
    assert any("no `Host github.com`" in f for f in out), out
