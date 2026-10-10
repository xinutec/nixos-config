# plan-run, the reconciler from xinutec-infra/plan: the fleet's one pin and one
# build. Each machines/<host>/plan-run.nix imports this and adds only its own
# wiring, so every host runs the same revision and a bump is one line.
#
# Fetched by revision, not vendored and not `ref = "main"`: hosts get rebuilt
# for unrelated reasons, and a floating ref would silently swap the reconciler.
# To bump: change `rev`, run xinutec-infra's scripts/plan-pin.sh, rebuild.

{ pkgs }:

rec {
  # Private repo, fetched at EVAL time, so it needs a credential wherever the
  # config is evaluated: each host's own read-only deploy key (`Host github.com`
  # in base-configuration.nix), and the Mac, which runs the verify gate.
  #
  # A MISSING KEY FAILS LATE, NOT NOW. fetchGit reaches the network only for a
  # rev the store does not already hold, so every rebuild that KEEPS the pin
  # succeeds and the first BUMP is what fails.
  src = builtins.fetchGit {
    url = "git@github.com:xinutec/xinutec-infra.git";
    ref = "main";
    # A FLOOR, never pinned backwards, and it may LEAD the settings but never lag
    # them: `deny_unknown_fields` makes a runner older than its settings refuse
    # to start, an older runner ignores new frontdoor.json fields and reports
    # healthy on evidence that cannot show it, and one older than fbc135a reads
    # declared-firewall.json's v6 rules as IPv4. New capability here first.
    rev = "e8410827b3d440078dd0f14b003f66fb3029deaf";
  };

  # NEEDS rustc >= 1.88 for let-chains: amun, held on 25.05 with 1.86, cannot
  # build it, and the failure is a bare E0658 that does not name the toolchain.
  plan-run = pkgs.rustPlatform.buildRustPackage {
    pname = "plan-run";
    version = "0.1.0";
    src = src + "/plan";
    cargoLock.lockFile = src + "/plan/Cargo.lock";

    # A copy of xinutec-infra's flake line, and it has to be: hosts build the
    # same source through their own channel nixpkgs. `ps` for cargo_sweep's
    # build probe, rsync for the mirror tests, git for git_probes.
    nativeCheckInputs = [ pkgs.rsync pkgs.procps pkgs.git ];

    # Held true by dev-lint's nix-rust-package-docheck-false.
    doCheck = true;
  };
}
