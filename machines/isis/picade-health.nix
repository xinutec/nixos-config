# fleetwatch picade internal-health producer, on isis.
#
# MOVED FROM AMUN 2026-08-11, with the rest of the picade fleet. amun cannot
# build plan-run (rustc 1.86 against the 1.88 let-chains need) and is held on
# 25.05 until it is reinstalled, so the fleet moved to isis instead of waiting —
# which is also the reinstall plan's direction. vpn-nodes.nix stayed behind
# deliberately: it reads `wg show` on the WireGuard HUB, which only amun is.
#
# Sibling to that module. It reports whether each picade is *reachable* over
# WireGuard; this one reports whether a reachable cabinet is actually
# healthy — USB stick on the bus, no ext4 errors, config in sync, wpa/wg fine —
# the failures that hid behind "every systemd unit is green" on picade2 (see the
# picade-sd-resilience notes in xinutec-infra). It runs `picade fleetwatch-push`,
# which is the *same* check_picade the CLI uses, and POSTs a verdict report to
# fleetwatch (isis, 10.100.0.2, over the VPN), one section per cabinet.
#
# The tool is the rsync-deployed picade_fleet package at /home/pi/picade_fleet
# (installed by its ./install), NOT a store path — so this references a mutable
# path on purpose, the same package the operator runs by hand. It is pure-stdlib
# at runtime, so we invoke it with a plain python3 plus ssh/rsync on PATH rather
# than its nix-shell wrapper (which would need to evaluate on every timer tick).
# HOME=/root so ssh finds root's keys/known_hosts — root@isis reaches every
# cabinet over WG with the shared fleet key (verified 2026-08-11 against
# picade0-2, the three that are up), which is what `picade health` relies on.
#
# ⚠ INGEST TOKEN: THIS IS THE ONE THING THE MOVE COULD NOT CARRY.
# fleetwatch derives `source` from the token, so a producer can only ever write
# as its mapped source — that is the whole guarantee the token design has. On
# amun this reused the existing /var/lib/fleetwatch/token and wrote as
# `amun/picade-health`; isis has no such token, and reusing amun's would make
# isis write as amun, which is a lie the design exists to prevent.
#
# So isis needs its own `isis:<token>` pair in FLEETWATCH_TOKENS, and the source
# becomes `isis/picade-health`. Historical `amun/picade-health` data keeps the
# old name and stops being added to; nothing rewrites it.
#
# Until /var/lib/fleetwatch/token exists here the run fails visibly in the
# journal and fleetwatch simply shows no picade-health data yet — which is the
# honest state while the token is being minted, not a silent gap.
{ config, pkgs, lib, ... }:

let
  pkgDir = "/home/pi/picade_fleet";
  tokenFile = "/var/lib/fleetwatch/token";
in
{
  systemd.services.fleetwatch-picade-health = {
    description = "Push picade internal-health verdicts to fleetwatch";
    # Ordering only, no `requires`: if wg0 is down the checks fail and that
    # failure is the honest signal, exactly as in vpn-nodes.nix.
    after = [ "wireguard-wg0.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    # ssh reaches the picades; rsync runs the drift dry-run against them. Both
    # run locally on amun, so both belong on the service PATH.
    path = [ pkgs.openssh pkgs.rsync ];
    environment = {
      PYTHONPATH = pkgDir;
      HOME = "/root";
    };
    serviceConfig = {
      Type = "oneshot";
      # Runs as root (default): root@isis is the identity that can ssh to every
      # cabinet over the VPN.
      ExecStart = ''
        ${pkgs.python3}/bin/python3 -m picade_fleet.fleetwatch \
          --token-file ${tokenFile} \
          --url https://fleetwatch.xinutec.org/api/reports \
          --interval 900
      '';
      # On amun this shared /var/lib/fleetwatch with vpn-nodes; here it is the
      # only user of the directory, so declaring it is what creates it.
      StateDirectory = "fleetwatch";
      StateDirectoryMode = "0700";
    };
  };

  systemd.timers.fleetwatch-picade-health = {
    description = "Run the fleetwatch picade-health push every 15 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/15";
      Persistent = true;
    };
  };
}
