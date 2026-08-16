# plan-run — the reconciler from xinutec-infra/plan, packaged for odin.
#
# It is here rather than vendored because a copy would be a second source of
# truth for the table that decides what gets backed up, and a table that drifts
# produces a backup with a hole in it that reports success. One source, fetched
# by revision.
#
# ┌─ WHY A REVISION AND NOT `ref = "main"` ────────────────────────────────────┐
# │ Both work — these machines are channel-based, so evaluation is impure and  │
# │ an unlocked fetch is permitted (a flake would refuse it outright). The     │
# │ reason not to is that odin gets rebuilt for unrelated things — a kernel    │
# │ bump, a firewall edit — and with a floating ref every one of those would   │
# │ ALSO swap in whatever had landed on xinutec-infra since, with nothing in   │
# │ this repo's history saying so.                                             │
# │                                                                            │
# │ That is the bar the reconciler itself refuses to cross: its                │
# │ `LocalMatchesOrigin` fact has no remedy on purpose, because the push is    │
# │ the line between testing and production. Bumping the rev below is the      │
# │ deliberate act on this side of that line — pull is not apply.              │
# │                                                                            │
# │ Being behind is a state you may have chosen, so it is reported rather than │
# │ enforced: xinutec-infra's gate runs `scripts/plan-pin.sh`, which fails only │
# │ when this rev is not an ancestor of that repo's main (a dangling or        │
# │ force-pushed pin) and otherwise just says how far back it is.              │
# └────────────────────────────────────────────────────────────────────────────┘
#
# To bump: change `rev`, run xinutec-infra's `scripts/plan-pin.sh`, rebuild.
# No hash to refresh — fetchGit verifies the commit itself.

{ pkgs, ... }:

let
  # Private repo. odin's root key is already authorised on it (it is the same
  # key that pulls this repo), so no deploy key or netrc had to be added; and
  # the fetch happens at EVAL time, which means it must also work wherever the
  # verify gate evaluates odin's config — currently the Mac, which has access.
  #
  # `ref` is given alongside `rev` only to tell git where to look; the rev is
  # what is used.
  src = builtins.fetchGit {
    url = "git@github.com:xinutec/xinutec-infra.git";
    ref = "main";
    # c89e253 — 78 commits on from 5dbe20e, 24 of them touching plan/. Bumped
    # 2026-08-12 as its own change rather than alongside a feature, because
    # SEVEN of those alter what this host actually backs up and drills, and a
    # backup-table change on the machine holding every backup deserves its own
    # deploy and its own verification:
    #
    #   0dbaba6  the tasks database joins the table — a primary copy with no
    #            git behind it, unlike the file-per-repo scheme it replaced
    #   350efca  picade-home is staged from isis, not amun; the fleet moved
    #   afa7dc9  the drill called nocodb drilled because Nextcloud was
    #   d4046fd  a proof nothing performs is a claim, not a capability
    #   b287840  every artifact says how its restore is proven
    #
    # MEASURED before and after: 36 staged artifacts before, 37 after, the new
    # one being stage-tasks-db.
    #
    # a5b9dcf, 2026-08-12: `plan-run firewall`, the seventh plan. Two `Includes`
    # rows over `/etc/plan/declared-firewall.json` and `iptables -S`, so a rule
    # nobody declared is a fact this host can be asked about rather than
    # something somebody notices — #728, and #727 is what it would have caught.
    # odin is the subject the ticket names first: no Kubernetes, so its live
    # chains are ours plus two docker jumps and the comparison is nearly exact.
    #
    # 9d6d00c, 2026-08-16: `monitor.check_files` — a check id may be named by a
    # FILE. Two commits on from a5b9dcf, one of them plan/README only, so the
    # whole runtime difference is an optional settings field: the diff over
    # plan/ touches settings.rs, three test files and the README, and no table,
    # plan, probe or effect. Nothing this host stages, drills or backs up can
    # change — and the staged artifact count was read back off the machine
    # afterwards to say so rather than to assume it.
    #
    # ⚠ THIS BUMP IS DELIBERATELY AHEAD OF THE SETTINGS THAT NEED IT, and the
    # order is the point rather than an accident of scheduling.
    # `deny_unknown_fields` means a binary older than its settings REFUSES to
    # start — correct, and loud, and the fix for the day this host silently ran
    # without `address`. So the capability lands first and plan-settings.nix
    # names `check_files` in a later change; the reverse order fails the unit.
    #
    # isis pins a5b9dcf still, and that is a choice rather than an oversight:
    # its plans are `picade` and `firewall`, neither of which checks in, so the
    # bump would buy it a rebuild and nothing else. plan-pin.sh reports the
    # divergence on every commit, which is where that decision gets re-read.
    #
    # c1cd2b8, 2026-08-16: `Repo::retry_lock_s` — an acting restic command may
    # WAIT for a contended lock instead of dying on it. Exactly one commit on
    # from 9d6d00c touches plan/ outside its README, and it is this one.
    #
    # ⚠ Bumped in the SAME commit as the setting that uses it, and that is not
    # the ordering mistake of 2026-08-02. The hazard there was a pin lagging its
    # settings across SEPARATE deploys, with serde dropping a key it did not
    # know. Here plan-run.nix and plan-settings.nix render into one system
    # closure and activate together, so there is no window in which an older
    # binary reads a newer settings file. Splitting it would add a deploy and
    # buy nothing.
    rev = "c1cd2b841090c5b86680ba1244ee92b278229b9c";
  };

  # Built with odin's channel nixpkgs, while the Mac builds the same source
  # through xinutec-infra's own flake. Two toolchains for one program, which is
  # worth knowing about but not worth fixing: nothing here depends on the two
  # binaries being bit-identical, and pinning them together would mean either a
  # root flake in this repo (which breaks `nixos-rebuild` on every host) or a
  # second nixpkgs for odin to build against.
  # NEEDS rustc >= 1.88. The crates are edition 2024 (1.85+), but the runner
  # uses let-chains — `if ok && let Some(key) = ...` — which only left nightly
  # in 1.88. odin's channel is nixos-26.05 with rustc 1.95, so this is slack
  # rather than a constraint; it is written down because the failure is a bare
  # `error[E0658]: 'let' expressions in this position are unstable` with nothing
  # in it to suggest the toolchain is the problem. Measured on amun's older
  # 25.05 channel (rustc 1.86), where it fails exactly that way.
  plan-run = pkgs.rustPlatform.buildRustPackage {
    pname = "plan-run";
    version = "0.1.0";
    src = src + "/plan";
    cargoLock.lockFile = src + "/plan/Cargo.lock";

    # TRUE since 2026-08-05, so this build runs the suite again. It was false
    # for two reasons, both now gone.
    #
    # Structural, and correctly diagnosed: five tests include_str!d this repo's
    # machines/odin/backup-prepare.sh to prove the plan and the shell it
    # replaced named the same PVCs, and two repositories cannot both be inside
    # one src. That script is retired and those tests went with it.
    #
    # Then `runner/tests/redis.rs` was recorded as "not hermetic — green from a
    # checkout, red in a nix sandbox". Right verdict, wrong cause: the dump
    # script redirected to a hard-coded /tmp/stage-redis.rdb, whoever ran the
    # tests first owned that file, and /tmp is sticky — so a build as _nixbld
    # got EACCES. The path is a parameter now. xinutec-infra's flake.nix carries
    # the long version.
    #
    # What this was costing: between the structural blocker being lifted and
    # today, odin's plan-run package built and installed having run ZERO tests,
    # on the machine that runs the backups. The gate's `cargo test` from a
    # checkout covered it, which is a different thing from the artefact being
    # checked.
    doCheck = true;
  };
in
{
  # In systemPackages, which is what actually fixes the bug this packaging is
  # for. Before this, plan-run existed on odin only as hand-copied store paths
  # with no GC root — three of them, and `nix-collect-garbage` had already eaten
  # one. Anything scheduled must be referenced by the system closure or it is
  # not really installed.
  environment.systemPackages = [ plan-run ];

  # And to the other modules on this host, so `backups.nix` can name the same
  # derivation rather than a second copy of this expression or a PATH lookup.
  # A store path in the unit is what makes the backup's staging step pinned to
  # the generation it was built with: `/run/current-system/sw/bin/plan-run`
  # would resolve at run time to whatever is current then, which is a different
  # binary from the one this generation was tested with.
  _module.args.planRun = plan-run;
}
