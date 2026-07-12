# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

let net = import ../../network.nix;
in {
  imports = [ ../../base-configuration.nix ./md-healthcheck.nix ./vpn-nodes.nix ];

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    kubectl # to manage kubernetes
    kubernetes-helm # to install kubernetes packages (helm charts)
  ];

  # No machine-specific PUBLIC ports. Verified against live `ss` (2026-07):
  #   2223 (toktok container SSH) → VPN-only; still binds 0.0.0.0 but the
  #         firewall now blocks it publicly, reachable over WireGuard (trusted).
  #   28192, 33445 → nothing was listening on either; dead leftover rules.
  networking.firewall.allowedTCPPorts = [ ];

  # List services that you want to enable:
  services.k3s = {
    enable = true;
    # No explicit package: take the channel default, like isis. On this machine's
    # channel (25.05) that is 1.32.7+k3s1 — exactly what it already runs, so this is
    # not an upgrade. It replaces a `k3s_1_32` pin that nixpkgs has since removed as
    # upstream-EOL, which is the recurring cost of pinning a minor by name.
    #
    # The version now moves with the channel, so a channel bump IS a Kubernetes
    # upgrade: 26.05 ships 1.35.6+k3s1, i.e. 1.32 → 1.35 in one step. k3s supports
    # only one minor at a time. Before bumping this machine off 25.05, pin the package
    # explicitly and step it (1.33 → 1.34 → 1.35), rebuilding at each step.
    role = "server";
    extraFlags =
      "--disable traefik --advertise-address ${config.node.vpn} --flannel-iface=wg0 --secrets-encryption";
  };

  services.nfs.server = {
    enable = true;
    exports = ''
      /export/home ${net.nodes.isis.vpn}(rw,nohide,insecure,no_subtree_check) ${net.nodes.odin.vpn}(rw,nohide,insecure,no_subtree_check)
    '';
  };

  fileSystems."/home" = {
    device = "/export/home";
    options = [ "bind" ];
  };

  virtualisation.oci-containers.containers = {
    buildfarm-server = {
      image = "toxchat/buildfarm-server";
      # Bazel buildfarm scheduler: host networking to serve the internal worker
      # cluster; trusted CI component, not a public service.
      # ast-grep-ignore: nix-oci-host-namespace
      extraOptions = [ "--network=host" ];
      volumes = [
        "${config.users.users.pippijn.home}/.config/buildfarm/server.yml:/app/build_buildfarm/config.minimal.yml"
      ];
    };

   toktok = {
     image = "xinutec/toktok:latest";
     # VPN-only: bind the published SSH port to the WireGuard IP, not
     # 0.0.0.0. Docker's DNAT bypasses the host firewall, so dropping 2223
     # from allowedTCPPorts alone leaves it public — the bind IP is what
     # actually closes it. Reach it at ${config.node.vpn}:2223 over the VPN.
     ports = [ "${config.node.vpn}:2223:22" ];
     extraOptions = [
       "--memory=10g"
       # toktok is a VPN-only Nix build/dev container (bound to the WireGuard IP
       # above): nix's sandboxed builds need broad privileges + setuid wrappers
       # (nix-daemon build users, /run/wrappers). Candidate for narrowing to
       # specific --cap-add later; --privileged is the current known-working set.
       # ast-grep-ignore: nix-oci-privileged
       "--privileged"
       "--tmpfs=/run"
       # setuid build wrappers (nix-daemon) live here.
       # ast-grep-ignore: nix-oci-exec-suid-tmpfs
       "--tmpfs=/run/wrappers:exec,suid"
       # build actions execute from /tmp.
       # ast-grep-ignore: nix-oci-exec-suid-tmpfs
       "--tmpfs=/tmp:exec"
     ];
     volumes = [
       "${config.users.users.pippijn.home}/code/kubes/vps/toktok/home/.cache/clangd:/home/builder/.cache/clangd"
       "${config.users.users.pippijn.home}/code/kubes/vps/toktok/workspace:/src/workspace"
       "${config.users.users.pippijn.home}/.local/share/vscode/config:/src/workspace/.vscode"
       "${config.users.users.pippijn.home}/.local/share/vscode/server:/home/builder/.vscode-server"
       "${config.users.users.pippijn.home}/.local/share/zsh/toktok:/home/builder/.local/share/zsh"
       # Persist Claude Code state across --rm container rebuilds.
       "${config.users.users.pippijn.home}/.local/share/toktok/claude:/home/builder/.claude"
       "${config.users.users.pippijn.home}/.local/share/toktok/claude.json:/home/builder/.claude.json"
       # Persist toxxi (Tox client) state — same survival reason.
       # Includes savedata.tox (Tox identity private key) and the
       # state.json chat history.
       "${config.users.users.pippijn.home}/.local/share/toxxi:/home/builder/.local/share/toxxi"
     ];
   };
  };

  # The toktok container publishes its port on the WireGuard IP, so its
  # Docker unit must not start until wg0 exists — otherwise the bind fails
  # with "cannot assign requested address" on boot.
  systemd.services.docker-toktok = {
    after = [ "wireguard-wg0.service" ];
    requires = [ "wireguard-wg0.service" ];
  };
}
