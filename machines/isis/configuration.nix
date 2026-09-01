# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

let net = import ../../network.nix;
in {
  # The picade fleet moved here from amun 2026-08-11: plan-run cannot build on
  # amun's held 25.05 (rustc 1.86 < the 1.88 let-chains need), and moving a
  # service off amun is the reinstall plan's direction anyway.
  imports = [
    ../../base-configuration.nix
    ./plan-run.nix
    ./plan-settings.nix
    ./picade-health.nix
    ./plan-picade.nix
    ../../plan-fleetwatch.nix
    # The host front door — #1294. ⚠ Importing this is the CUTOVER, and it does
    # not work alone: klipper's svclb holds :80/:443 by CNI hostport DNAT with no
    # destination restriction, so nginx binds both ports and receives nothing
    # until the ingress-nginx LoadBalancer Service is deleted. That Service goes
    # in the same change that adds this line.
    ./frontdoor.nix
  ];

  # #728: the firewall plan finds a rule nobody declared, and until this it had
  # nowhere to say so. Read-only by construction — `plans::firewall` has no
  # effects, deliberately: re-running the firewall script would rebuild the
  # one-way block, and deleting an unaccountable rule unattended could be
  # deleting the only thing holding a service up.
  # ⚠ `picade` ADDED 2026-08-28, and the reason is an incident: the convergence
  # was completely broken from 2026-08-22 (isis's root keys were rotated and the
  # cabinets still trusted the old pair) and nothing said so for six days. The
  # hourly unit exited 0/SUCCESS the whole time, because every picade goal is
  # advisory and a plan whose probes are all unreadable still settles. The
  # verdict and its summary were honest — `0 picade goals hold, 20 could not be
  # read` — and nobody was reading them, because this list did not have the plan
  # in it. See #1233.
  #
  # `<plan>: verified` is the check that would have caught it: its verdict is
  # `pass` only when `unread == 0 and adrift == 0`, so it goes amber the moment
  # the fleet stops being readable, independently of whether the plan converged.
  #
  # ⚠ IT IS AMBER TODAY AND WILL BE FOR MONTHS — picade3 and picade4 are off
  # (#70), so `verified` reports `8 could not be read`. Dry-run 2026-08-28:
  #
  #   picade: outcome   warn   6 step(s) pending — converged: 12 hold, 8 unread
  #   picade: verified  warn   6 held, 6 pending, 8 could not be read, 0 adrift
  #
  # This file warns twice that amber in the steady state is amber nobody reads,
  # and that warning is about `backup --simulate`, whose amber means "the plan is
  # doing its job" and can never clear. This one means "two cabinets are dead",
  # which is true, self-clearing, and carries a NUMBER (`value: 8.0 goals`) that
  # moves if a live cabinet joins them. Different thing, kept deliberately.
  # If it proves noisy, the tool is an EXPIRING MUTE on `picade: verified` —
  # which is itself the reminder that the cabinets are still out — not deleting
  # the entry.
  services.planFleetwatch.plans = [ "firewall" "picade" ];

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

  # ⚠ Reap a client that has vanished, or its listener outlives it and wedges
  # the port for everyone after it.
  #
  # 2026-09-01: the home ISP reassigned the Mac's public address. The tunnel's
  # connection died with it and no FIN was ever sent, so sshd went on believing
  # the session was alive and kept its listener. Every redial — now from the new
  # address — failed with `remote port forwarding failed` and exited, as
  # `ExitOnForwardFailure` is meant to make it. What the phone met was not a
  # refusal but a black hole: TCP connected, a TLS Client hello went out, and no
  # Server hello ever came back, which reads to the app as a slow network rather
  # than a broken route. It held for over two hours and 1050 redials, and
  # nothing reported it.
  #
  # A residential address change is ordinary and will happen again. Ninety
  # seconds of silence now ends the session and takes the listener with it,
  # which is what lets the next redial bind. The numbers match the Mac's own
  # ServerAliveInterval/ServerAliveCountMax in `console-tunnel.sh`, so both ends
  # give up on the same schedule.
  services.openssh.settings.ClientAliveInterval = 30;
  services.openssh.settings.ClientAliveCountMax = 3;

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
