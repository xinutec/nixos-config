# fleetwatch picade internal-health producer, on amun.
#
# Sibling to vpn-nodes.nix. That one reports whether each picade is *reachable*
# over WireGuard; this one reports whether a reachable cabinet is actually
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
# HOME=/root so ssh finds root's keys/known_hosts — root@amun already reaches the
# picades over WG, which is exactly what the manual `picade health` relies on.
#
# Ingest token: reuses amun's existing /var/lib/fleetwatch/token (see
# vpn-nodes.nix) — fleetwatch derives `source` from it, so this writes as
# amun/picade-health. No new secret. Until the file exists the run fails visibly
# in the journal and fleetwatch simply shows no picade-health data yet.
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
      # Runs as root (default): root@amun is the identity that can ssh to every
      # cabinet over the VPN.
      ExecStart = ''
        ${pkgs.python3}/bin/python3 -m picade_fleet.fleetwatch \
          --token-file ${tokenFile} \
          --url https://fleetwatch.xinutec.org/api/reports \
          --interval 900
      '';
      # Shares /var/lib/fleetwatch with vpn-nodes (root:root 0700); declaring it
      # here too keeps this unit self-sufficient if that one is ever removed.
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
