# plan-run — the reconciler from xinutec-infra/plan, packaged for isis.
#
# Sibling of machines/odin/plan-run.nix, and everything that file says about
# WHY the source is pinned by revision rather than a floating ref applies here
# unchanged: isis gets rebuilt for unrelated reasons, and a floating ref would
# silently swap in whatever had landed on xinutec-infra since, with nothing in
# this repo's history saying so. To bump: change `rev`, run xinutec-infra's
# `scripts/plan-pin.sh`, rebuild.
#
# ┌─ WHY ISIS AND NOT AMUN ────────────────────────────────────────────────────┐
# │ The picade fleet lives on amun, so amun is where this obviously belongs —  │
# │ and it CANNOT go there. The runner uses let-chains, stable only since      │
# │ rustc 1.88; amun is held on nixos-25.05 with rustc 1.86 and stays there    │
# │ until it is reinstalled from scratch, deliberately (see                    │
# │ project_amun_reinstall_plan). The build fails with a bare                  │
# │ `error[E0658]: 'let' expressions in this position are unstable`, which     │
# │ names the feature and not the toolchain. Measured 2026-08-11:              │
# │                                                                            │
# │     amun  nixos-25.05  rustc 1.86.0   <- cannot build plan-run             │
# │     isis  nixos-26.05  rustc 1.95.0                                        │
# │     odin  nixos-26.05  rustc 1.95.0                                        │
# │                                                                            │
# │ So the picade fleet moves to isis instead of waiting, which is also the    │
# │ direction the reinstall plan wants anyway: services leave amun one at a    │
# │ time until amun carries nothing that matters.                              │
# └────────────────────────────────────────────────────────────────────────────┘

{ pkgs, ... }:

let
  # Private repo. isis's root key is authorised on it — the same key that pulls
  # this repo — and the fetch happens at EVAL time, so it must also work
  # wherever the verify gate evaluates isis's config, currently the Mac.
  src = builtins.fetchGit {
    url = "git@github.com:xinutec/xinutec-infra.git";
    ref = "main";
    # a5b9dcf — `plan-run firewall`, the seventh plan: two `Includes` rows over
    # `/etc/plan/declared-firewall.json` and `iptables -S`, so a rule nobody
    # declared is a fact this host can be asked about rather than something
    # somebody notices. #728, and #727 is what it would have caught.
    #
    # c89e253, the previous pin, is the commit that stopped the verdict
    # claiming more than the run established. `plan-picade-apply` had been reporting `all picade goals
    # hold` on a fleet with two cabinets switched off since it was scheduled;
    # it now says `12 picade goals hold, 8 could not be read`, and the JSON
    # carries the three counts so a collector need not read the sentence.
    #
    # feb56e1, the previous pin, is where `--simulate --json` gained `looked`.
    # `picade_fleet.health` reads exactly that array for its per-cabinet drift
    # checks, so a runner older than THAT answers a report with no readings in
    # it and every drift check warns. 4409f7b is where `plans::picade` first
    # existed and is the earliest that can answer `plan-run picade` at all.
    # 77e77b3 — `plan-run picade-push --host H (--prune|--fresh)`: the operator
    # half of the picade path, and the reason `deploy.py` can eventually go.
    # `--fresh` turns a blank RetroPie SD into a fleet member and NOTHING in
    # Rust implemented it before this, so isis could not have rebuilt picade3
    # or picade4 without the Python. The mode is refused rather than defaulted:
    # the routine upsert is the hourly `picade` plan, so asking for this verb is
    # asking to delete.
    #
    # b779592 — `plan-run frontdoor`, the eighth plan (#1325): the host front
    # door judged at the SOCKET rather than the config. Two probes, TlsServedFor
    # and TlsAbsentFor, answered by curl; the plan builds from the model's
    # frontdoor.json (deployed to /etc/plan alongside settings, the same file
    # frontdoor.nix reads), resolving each name to its SERVING cluster's address
    # so isis probes amun's names at amun's IP. Observe-only. This pin is the one
    # that puts `frontdoor` on the fleetwatch list below — a runner older than it
    # answers "frontdoor: unknown plan" and the unit dies.
    #
    # b779592 also adds the CONSEQUENCE check (#1326): after `deploy` applies
    # manifests and converges, it re-observes the front-door witness for each
    # modelled name whose upstream is in the deployed namespace and returns 2 if
    # any stopped serving. That is why a deploy can now exit 2 having applied
    # successfully — the apply worked and something it fronts does not answer.
    #
    # 3d2eaec, the previous pin, is below.
    rev = "b77959287871da9193940b6bda1e550d76e02567";
  };

  plan-run = pkgs.rustPlatform.buildRustPackage {
    pname = "plan-run";
    version = "0.1.0";
    src = src + "/plan";
    cargoLock.lockFile = src + "/plan/Cargo.lock";

    # Runs the suite as part of the build, as odin's does. The artefact being
    # checked is a different claim from the gate's `cargo test` in a checkout.
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
  # In systemPackages so the closure holds a GC root. Anything scheduled that is
  # not referenced by the system closure is not really installed — odin learned
  # that with three hand-copied store paths, one of which had already been
  # garbage-collected.
  environment.systemPackages = [ plan-run ];

  # And to the other modules on this host, so picade-health.nix can name the
  # same derivation rather than resolve `plan-run` on PATH at run time — which
  # would pick up whatever generation is current then rather than the one this
  # generation was built and tested with.
  _module.args.planRun = plan-run;
}
