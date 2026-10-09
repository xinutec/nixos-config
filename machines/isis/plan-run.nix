# plan-run — the reconciler from xinutec-infra/plan, packaged for isis.
#
# The pin, and why it is one, are in ../../plan-run-package.nix.
#
# NOT AMUN, where the picade fleet actually lives: the runner needs rustc >= 1.88
# for let-chains and amun is held on 25.05 with 1.86 until its reinstall. The failure
# there is a bare E0658 that names the feature, not the toolchain.

{ config, lib, pkgs, ... }:

let
  # The pin and the build are the fleet's, shared by every host.
  inherit (import ../../plan-run-package.nix { inherit pkgs; }) src plan-run;
in
{
  # Must be in the closure so it has a GC root — see odin's note.
  environment.systemPackages = [ plan-run ];

  # So picade-health.nix names this derivation rather than resolving PATH at run time.
  _module.args.planRun = plan-run;

  # This host's plan timers, from the same revision as the binary above.
  _module.args.planSchedule = import ../../plan-schedule.nix {
    inherit lib src;
    host = config.node.name;
  };
}
