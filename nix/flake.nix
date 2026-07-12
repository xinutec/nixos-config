{
  description = "nixos-config — toolchain for the verify gate (NOT the machines' build)";

  # ┌─ WHY THIS IS IN nix/ AND NOT THE REPO ROOT ─────────────────────────────────┐
  # │ The repo root IS /etc/nixos on each host, and `nixos-rebuild` treats a root │
  # │ flake.nix as the thing to build: nixos-rebuild-ng "uses /etc/nixos/flake.   │
  # │ nix if it exists" and implies --flake. This flake provides only devShells,  │
  # │ no nixosConfigurations, so a root flake.nix would make `nixos-rebuild       │
  # │ switch` fail on every machine the moment it pulled. Keep it in a subdir.    │
  # └────────────────────────────────────────────────────────────────────────────┘
  #
  # This flake exists for the VERIFY GATE, not for deployment. The machines are still
  # channel-based (`nixos-rebuild switch` on the host, `<nixpkgs>` from its channel) —
  # nothing here changes how they are built or deployed. What it buys is a *pinned*
  # nixpkgs + home-manager for scripts/verify.sh, so the gate can evaluate each
  # machine's configuration on a known revision instead of whatever channel the
  # machine running the check happens to have. (The Mac that runs the fleet check has
  # no channels at all, so an unpinned eval could not work there.)
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # <home-manager/nixos> is imported by base-configuration.nix, so the eval needs it
    # on NIX_PATH. Follows nixpkgs: a home-manager built against a different nixpkgs
    # than the one it is evaluated with fails on renamed options.
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.python313 # the two operational scripts (vpn-nodes-push, backup_preview)
            pkgs.ruff
            pkgs.mypy
            pkgs.shellcheck # the host-side shell scripts (backup-prepare, drill, setup)
          ];
          # The gate evaluates each machine against THESE revisions. Exported here
          # rather than passed as `-I` flags in verify.sh so a manual eval from an
          # interactive `nix develop` shell resolves exactly what the gate does.
          shellHook = ''
            export NIX_PATH="nixpkgs=${nixpkgs}:home-manager=${home-manager}"
          '';
        };
      });
}
