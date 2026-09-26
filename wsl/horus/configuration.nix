# horus's compute host: NixOS-WSL in the `claude` Windows account on Pippijn's
# gaming PC (RTX 4090). The Mac's Claude sessions use it over ssh for GPU work;
# design and setup are in xinutec-infra horus.md.
#
# Not a fleet machine: it does not build on base-configuration.nix. Windows runs
# the WireGuard tunnel (WSL shares its addresses through mirrored networking),
# and there is deliberately no agenix recipient and no fleet root key here.
#
# On horus, /etc/nixos is a checkout of this repository and its (gitignored)
# configuration.nix is one line: `{ imports = [ ./wsl/horus/configuration.nix ]; }`.
# Deploy: `git -C /etc/nixos pull && sudo nixos-rebuild switch`.
{ pkgs, ... }:
let
  macKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH0bjmIxl2osD4d1X6Jf2UDGF6fc7mqJaVXYA6OyZmW1 claude@mac-mini -> horus compute";
in
{
  imports = [ <nixos-wsl/modules> ];

  wsl.enable = true;
  wsl.defaultUser = "claude";
  networking.hostName = "horus";

  # Port 22 belongs to Windows' own OpenSSH server; the Windows firewall admits
  # 2222 from the VPN only (Hyper-V rule horus-wsl-ssh).
  services.openssh = {
    enable = true;
    ports = [ 2222 ];
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };
  users.users.claude.openssh.authorizedKeys.keys = [ macKey ];

  # CUDA: the GPU libraries come from the Windows driver. NixOS-WSL links them
  # into /run/opengl-driver/lib; pip wheels under nix-ld do not look there
  # unless told, and nvidia-smi lives outside the PATH.
  wsl.useWindowsDriver = true;
  programs.nix-ld.enable = true;
  environment.sessionVariables.LD_LIBRARY_PATH = [ "/run/opengl-driver/lib" ];

  # Isolation from Windows: no drive mounts, no launching Windows programs.
  wsl.wslConf.automount.enabled = false;
  wsl.wslConf.interop.enabled = false;
  wsl.wslConf.interop.appendWindowsPath = false;
  wsl.interop.register = false;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  environment.systemPackages = [
    pkgs.git
    pkgs.rsync # horus-run --repo copies repositories in from the Mac
    pkgs.uv
    (pkgs.writeShellScriptBin "nvidia-smi" ''exec /usr/lib/wsl/lib/nvidia-smi "$@"'')
  ];

  # The release this distribution was first installed from (NixOS-WSL 2605.7.2).
  system.stateVersion = "26.05";
}
