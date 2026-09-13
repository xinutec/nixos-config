"""Does the order check FIRE? Every test here builds a chain that is wrong.

A check that cannot fail is worse than none, because the suite still counts it. So
each case below is a chain with one specific defect, and the test asserts the defect
is NAMED — not merely that something was reported.

The sound cases are at the end, and they are the weaker half: a check that passes
everything passes these too.
"""

import importlib.util
import sys
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "firewall_order", Path(__file__).with_name("firewall_order.py"))
assert _spec and _spec.loader
fo = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = fo
_spec.loader.exec_module(fo)

CHAIN = "xinutec-oneway"


def v4(*lines: str) -> list[str]:
    return fo.commands("\n".join(lines))


SOUND_V4 = [
    f"iptables -w -N {CHAIN}",
    f"iptables -w -A {CHAIN} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT",
    f"iptables -w -A {CHAIN} -s 10.100.0.11/32 -j ACCEPT",
    f"iptables -w -A {CHAIN} -j DROP",
    f"iptables -w -I INPUT 1 -i wg0 -j {CHAIN}",
]

SOUND_V6 = [
    f"ip6tables -w -N {CHAIN}",
    f"ip6tables -w -A {CHAIN} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT",
    f"ip6tables -w -A {CHAIN} -p ipv6-icmp -j ACCEPT",
    f"ip6tables -w -A {CHAIN} -s fe80::/10 -j ACCEPT",
    f"ip6tables -w -A {CHAIN} -j DROP",
    f"ip6tables -w -I INPUT 1 -i wlp0s20f3 -j {CHAIN}",
]


def test_established_after_the_drop_is_named() -> None:
    """MUST-FIRE. The Mac shipped this on 2026-06-10: the chain then drops the
    replies to traffic the host itself sent, so the VPN dies in the direction that
    was supposed to keep working."""
    cmds = v4(*[SOUND_V4[0], SOUND_V4[3], SOUND_V4[1], SOUND_V4[4]])
    faults = fo.violations(cmds, "iptables")
    assert faults, "an ESTABLISHED accept after the DROP was not reported at all"
    assert any("ESTABLISHED" in f and "AFTER the DROP" in f for f in faults), faults


def test_a_missing_established_accept_is_named() -> None:
    """MUST-FIRE. Omitting it fails the same way as ordering it late."""
    cmds = v4(SOUND_V4[0], SOUND_V4[3])
    faults = fo.violations(cmds, "iptables")
    assert any("ESTABLISHED" in f for f in faults), faults


def test_icmpv6_after_the_drop_is_named() -> None:
    """MUST-FIRE, and it is the subtle one. A neighbour advertisement carries the
    sender's GLOBAL address, so the fe80::/10 rule does NOT cover it; losing Packet
    Too Big makes large transfers hang rather than fail, which reads as a slow
    network rather than a firewall."""
    reordered = [SOUND_V6[0], SOUND_V6[1], SOUND_V6[3], SOUND_V6[4], SOUND_V6[2]]
    faults = fo.violations(v4(*reordered), "ip6tables")
    assert any("ICMPv6" in f and "AFTER the DROP" in f for f in faults), faults


def test_missing_icmpv6_is_named() -> None:
    """MUST-FIRE."""
    without = [ln for ln in SOUND_V6 if "ipv6-icmp" not in ln]
    faults = fo.violations(v4(*without), "ip6tables")
    assert any("ICMPv6" in f for f in faults), faults


def test_an_admit_below_the_drop_is_named() -> None:
    """MUST-FIRE. A `reachableFrom` ACCEPT under the DROP can never match, so the
    exception READS AS GRANTED while doing nothing — the failure mode the throw in
    `vpnOf` exists to prevent at the other end."""
    cmds = v4(SOUND_V4[0], SOUND_V4[1], SOUND_V4[3], SOUND_V4[2])
    faults = fo.violations(cmds, "iptables")
    assert any("AFTER the DROP" in f and "ACCEPT" in f for f in faults), faults


def test_an_uncreated_chain_is_named() -> None:
    """MUST-FIRE. The chain must exist on EVERY host, one-way or not: `iptables -S`
    on a missing chain errors, and the firewall plan reads that as Unreadable rather
    than as "declares nothing" — losing the judgement that does work."""
    faults = fo.violations(v4(SOUND_V4[1], SOUND_V4[3]), "iptables")
    assert any("never created" in f for f in faults), faults


def test_comments_are_not_ordering() -> None:
    """A `#` line inside the rendered script must not shift an index. The script is
    Nix `'' ''` output and DOES carry comments — that is what made them payload."""
    with_comments = v4(SOUND_V4[0], "# a comment", SOUND_V4[1], "# another",
                       SOUND_V4[2], SOUND_V4[3], SOUND_V4[4])
    assert fo.violations(with_comments, "iptables") == []


def test_a_sound_v4_chain_passes() -> None:
    assert fo.violations(v4(*SOUND_V4), "iptables") == []


def test_a_sound_v6_chain_passes() -> None:
    assert fo.violations(v4(*SOUND_V6), "ip6tables") == []


def test_a_host_that_is_not_one_way_passes() -> None:
    """The chain is created and left empty. No DROP means nothing to order."""
    cmds = v4(f"iptables -w -N {CHAIN}", f"ip6tables -w -N {CHAIN}")
    assert fo.violations(cmds, "iptables") == []
    assert fo.violations(cmds, "ip6tables") == []


def test_both_families_in_one_script_do_not_judge_each_other() -> None:
    """MUST-FIRE, and it caught a real bug in this checker rather than in the fleet.

    base-configuration renders BOTH families into one `extraCommands` string, so the
    v6 chain's accepts sit after the v4 chain's DROP by construction. A scan that
    matched `-A <chain> ... -j ACCEPT` without also matching the BINARY reported
    every one-way host — geb, shu and tefnut — which reads exactly like a finding.

    Every fixture above is single-family, which is why they all passed while the real
    model did not. A fixture that does not mirror the shape under test proves nothing
    about it."""
    both = v4(*(SOUND_V4 + SOUND_V6))
    assert fo.violations(both, "iptables") == []
    assert fo.violations(both, "ip6tables") == []
