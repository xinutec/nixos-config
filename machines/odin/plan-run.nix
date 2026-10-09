# plan-run — the reconciler from xinutec-infra/plan, packaged for odin.
#
# The pin, and why it is one, are in ../../plan-run-package.nix.

{ config, lib, pkgs, ... }:

let
  # The pin and the build are the fleet's, shared by every host.
  inherit (import ../../plan-run-package.nix { inherit pkgs; }) src plan-run;
in
{
  # Must be in the closure, or nix-collect-garbage eats it: a store path with no GC
  # root is not installed, however present it looks.
  environment.systemPackages = [ plan-run ];

  # So backups.nix names this derivation rather than a PATH lookup — the store path
  # pins staging to the generation it was tested with.
  _module.args.planRun = plan-run;

  # This host's plan timers, from the same revision as the binary above.
  _module.args.planSchedule = import ../../plan-schedule.nix {
    inherit lib src;
    host = config.node.name;
  };
}
