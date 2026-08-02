# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

let net = import ../../network.nix;
in {
  imports = [ ../../base-configuration.nix ];

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    kubectl # to manage kubernetes
    kubernetes-helm # to install kubernetes packages (helm charts)
    # odin's backup-prepare.sh ssh's in and runs `sqlite3 ... ".backup"` to take a
    # consistent snapshot of vaultwarden's DB. It must be present in the system
    # closure: fetching it at backup time (nix-shell -p) makes the backup depend on
    # working internet and an up binary cache — the conditions least likely to hold
    # when you need the backup to have run — and nix GC re-evicts it, so it never
    # settles. On this host that fetch was 101.6 MiB of stdenv, mid-backup.
    sqlite
  ];

  # No machine-specific PUBLIC ports. Verified against live `ss` (2026-07):
  #   2223, 28192 → nothing was listening on isis; dead leftover rules.
  networking.firewall.allowedTCPPorts = [ ];

  # List services that you want to enable:
  services.k3s = {
    enable = true;
    role = "server";
    extraFlags =
      "--disable traefik --advertise-address ${config.node.vpn} --flannel-iface=wg0 --secrets-encryption";
  };

  # List services that you want to enable:
#  services.k3s = {
#    enable = true;
#    role = "agent";
#    tokenFile = "/root/node-token";
#    serverAddr = "https://${net.nodes.master.vpn}:${toString net.k8sApiPort}";
#    extraFlags = "--node-ip ${config.node.vpn} --flannel-iface=wg0";
#  };

# fileSystems."/export/home" = {
#   device = "${net.nodes.master.vpn}:/export/home";
#   fsType = "nfs4";
# };

  # The agent console's way in, and the reason the Mac needs no open port.
  #
  # The Mac dials out and asks sshd to listen on this host's VPN address; the
  # phone connects there and the bytes go back down the tunnel the Mac opened.
  # The phone's TLS session terminates at the Mac, not here — so this host
  # carries ciphertext, holds no key that opens anything, and cannot inject or
  # impersonate. It can drop the tunnel, which is denial of service and
  # unavoidable for anything in the middle. See memview/docs/agent-console.md.
  #
  # `clientspecified` rather than `yes`: `yes` would bind every remote forward to
  # every interface, this host among other things being internet-facing. With
  # `clientspecified` the client names the address, and the key below is only
  # permitted to name one.
  services.openssh.settings.GatewayPorts = "clientspecified";

  # A key of its own, restricted to exactly that one listener — no shell, no
  # agent, no X11, no local forwards. An unattended tunnel that ran on the
  # ordinary admin key would give anything holding the Mac's disk a root session
  # here, which is a far larger thing than the console it exists to carry.
  users.users.pippijn.openssh.authorizedKeys.keys = [
    ''restrict,port-forwarding,permitlisten="${config.node.vpn}:${
      toString net.consolePort
    }" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBJAGJDba9uOuPZNe/LHngVUXao8Uv+2y5TDLvOA7icR console-tunnel@mac-mini''
  ];
}
