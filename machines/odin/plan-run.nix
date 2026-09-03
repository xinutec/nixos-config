# plan-run — the reconciler from xinutec-infra/plan, packaged for odin.
#
# Fetched by revision rather than vendored: a copy would be a second source of truth
# for the table that decides what gets backed up, and a table that drifts produces a
# backup with a hole in it that reports success.
#
# ┌─ WHY A REVISION AND NOT `ref = "main"` ────────────────────────────────────┐
# │ Both work — these machines are channel-based, so an unlocked fetch is      │
# │ permitted where a flake would refuse it outright. The reason not to is     │
# │ that odin gets rebuilt for unrelated things — a kernel bump, a firewall    │
# │ edit — and a floating ref would ALSO swap in whatever had landed on        │
# │ xinutec-infra since, with nothing in this repo's history saying so.        │
# │                                                                            │
# │ Bumping the rev is the deliberate act, on this side of the line the        │
# │ reconciler's own remedy-less `LocalMatchesOrigin` refuses to cross: pull   │
# │ is not apply.                                                              │
# │                                                                            │
# │ Being behind may be a state you chose, so it is reported rather than       │
# │ enforced: xinutec-infra's `scripts/plan-pin.sh` fails only when this rev   │
# │ is not an ancestor of that repo's main — a dangling or force-pushed pin —  │
# │ and otherwise just says how far back it is.                                │
# └────────────────────────────────────────────────────────────────────────────┘
#
# To bump: change `rev`, run plan-pin.sh, rebuild. No hash to refresh — fetchGit
# verifies the commit itself.

{ pkgs, ... }:

let
  # Private repo. odin's root key is already authorised on it (the same key that pulls
  # this repo), so no deploy key or netrc was needed. The fetch happens at EVAL time,
  # so it must also work wherever the verify gate evaluates odin's config — currently
  # the Mac, which has access. `ref` only tells git where to look; `rev` is used.
  src = builtins.fetchGit {
    url = "git@github.com:xinutec/xinutec-infra.git";
    ref = "main";
    # ⚠ A pin may LEAD the settings that need it, and must never lag them.
    # `deny_unknown_fields` makes a binary older than its settings REFUSE to start —
    # correct, loud, and the fix for the day this host silently ran without `address`.
    # So a new capability lands here first and plan-settings.nix names it in a later
    # change; the reverse order fails the unit.
    #
    # Bumping both in ONE commit is fine when they render into one system closure and
    # activate together — the 2026-08-02 hazard was a pin lagging its settings across
    # SEPARATE deploys, with serde dropping a key it did not know.
    #
    # ⚠ A bump that changes what this host stages, drills or backs up deserves its own
    # deploy and its own verification: read the staged-artifact count back off the
    # machine rather than assuming it.
    #
    # isis pins an older rev deliberately — its plans are `picade` and `firewall`,
    # neither of which checks in, so a bump buys it a rebuild and nothing else.
    # plan-pin.sh reports the divergence on every commit, which is where that decision
    # gets re-read.
    rev = "8c19fee16e333499521b1d696bcd0621befacbb5";
  };

  # Built with odin's channel nixpkgs, while the Mac builds the same source through
  # xinutec-infra's own flake. Two toolchains for one program: worth knowing, not worth
  # fixing — nothing depends on the two binaries being bit-identical, and pinning them
  # together would need either a root flake in this repo (which breaks `nixos-rebuild`
  # on every host) or a second nixpkgs for odin to build against.
  #
  # NEEDS rustc >= 1.88. The crates are edition 2024 (1.85+), but the runner uses
  # let-chains, which only left nightly in 1.88. odin's nixos-26.05 has rustc 1.95, so
  # this is slack rather than a constraint — written down because the failure is a bare
  # `error[E0658]: 'let' expressions in this position are unstable`, with nothing in it
  # to suggest the toolchain. Measured on amun's 25.05 channel (rustc 1.86), where it
  # fails exactly that way.
  plan-run = pkgs.rustPlatform.buildRustPackage {
    pname = "plan-run";
    version = "0.1.0";
    src = src + "/plan";
    cargoLock.lockFile = src + "/plan/Cargo.lock";

    # ⚠ Keep this TRUE. While it was false, odin's plan-run built and installed having
    # run ZERO tests, on the machine that runs the backups — and the gate's `cargo
    # test` from a checkout is a different thing from the artefact being checked.
    #
    # It was false for two reasons, both gone. Five tests `include_str!`d this repo's
    # machines/odin/backup-prepare.sh to prove the plan and the shell named the same
    # PVCs, and two repositories cannot both be inside one src — that script is retired
    # and those tests went with it. Then `runner/tests/redis.rs` was recorded as
    # non-hermetic; right verdict, wrong cause — the dump script redirected to a
    # hard-coded /tmp/stage-redis.rdb, /tmp is sticky, and a build as _nixbld got
    # EACCES. The path is a parameter now.
    # ⚠ SECOND COPY OF xinutec-infra's `flake.nix` LINE, and it has to be.
    # That flake's `nativeCheckInputs` does not reach here: this host builds the
    # same source through its own channel nixpkgs (see the "two toolchains for one
    # program" note above), so the test closure is assembled twice.
    #
    # `runner/tests/cargo_sweep.rs` shells out to `ps` to ask whether a build is
    # running, and the sandbox has no `ps` on PATH even though every login shell
    # does. Measured 2026-08-31: odin's rebuild failed with
    # `ps runs: Os { code: 2, kind: NotFound }` on the amun builder while the same
    # commit built clean on the Mac through the flake. rsync for the mirror tests.
    nativeCheckInputs = [ pkgs.rsync pkgs.procps ];

    doCheck = true;
  };
in
{
  # In systemPackages, which is what actually fixes the bug this packaging is for:
  # plan-run existed on odin only as hand-copied store paths with no GC root — three of
  # them, and `nix-collect-garbage` had already eaten one. Anything scheduled must be
  # referenced by the system closure or it is not really installed.
  environment.systemPackages = [ plan-run ];

  # And to this host's other modules, so `backups.nix` can name the same derivation
  # rather than a second copy of this expression or a PATH lookup. The store path is
  # what pins the staging step to the generation it was built with;
  # `/run/current-system/sw/bin/plan-run` would resolve at run time to whatever is
  # current then, which is a different binary from the one this generation was tested
  # with.
  _module.args.planRun = plan-run;
}
