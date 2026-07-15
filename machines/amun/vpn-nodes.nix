# fleetwatch VPN-node liveness producer, on amun (the WireGuard hub).
#
# amun is the star-topology hub, so `wg show wg0 latest-handshakes` is the
# authoritative "which peer is up" table — read it locally every 10 min and POST a
# verdict-shaped report to fleetwatch (isis, 10.100.0.2, reachable over the VPN).
# The pusher (vpn-nodes-push.py) mirrors mac-mini/fleetwatch_push.py's wire format;
# `source` is derived server-side from the bearer token, so this writes as "amun".
#
# The pubkey -> {name, intermittent} map is rendered from network.nix here, so it
# stays the single source of truth: adding a peer there is the only edit needed, no
# drift. `intermittent` (default false) is the liveness class the pusher keys on — a
# peer that comes and goes (phone/laptop/picade) is SKIP when down, not FAIL.
#
# Ingest token: hand-placed at /var/lib/fleetwatch/token (0600), NOT in the repo —
# the fleet convention for producer tokens (cf. the Mac's Keychain item and bes's
# ~/.config/govee/token). Until it is present the service fails each run (visible in
# journal; fleetwatch simply shows no amun data yet) and starts working the moment
# the file appears. To install the token:
#   1. append  amun:<newtoken>  to FLEETWATCH_TOKENS in the fleetwatch-secret k8s
#      secret on isis, and restart the fleetwatch app (see kubes/fleetwatch/k8s);
#   2. echo -n '<newtoken>' > /var/lib/fleetwatch/token  on amun (chmod 600).
{ config, pkgs, lib, ... }:

let
  net = import ../../network.nix;
  # Invert network.nix's nodes to pubkey -> name (drop entries without a key).
  namedPeers = lib.filter (n: n ? publicKey) (lib.attrValues net.nodes);
  peerMap = lib.listToAttrs (map (n: lib.nameValuePair n.publicKey {
    name = n.name;
    intermittent = n.intermittent or false;
  }) namedPeers);
  peersJson = pkgs.writeText "fleetwatch-wg-peers.json" (builtins.toJSON peerMap);
  tokenFile = "/var/lib/fleetwatch/token";
in
{
  systemd.services.fleetwatch-vpn-nodes = {
    description = "Push WireGuard peer liveness to fleetwatch";
    # Try even if wg0 is down: the pusher turns a wg failure into a visible FAIL
    # rather than silence, so `after` (ordering) without `requires` is deliberate.
    after = [ "wireguard-wg0.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.wireguard-tools ];
    serviceConfig = {
      Type = "oneshot";
      # Runs as root (default): `wg show latest-handshakes` needs CAP_NET_ADMIN.
      ExecStart = ''
        ${pkgs.python3}/bin/python3 ${./vpn-nodes-push.py} \
          --interface wg0 \
          --peers ${peersJson} \
          --token-file ${tokenFile} \
          --url https://fleetwatch.xinutec.org/api/reports \
          --interval 600 \
          --fresh-secs 180
      '';
      # Creates /var/lib/fleetwatch (root:root 0700) so the token file has a home.
      StateDirectory = "fleetwatch";
      StateDirectoryMode = "0700";
    };
  };

  systemd.timers.fleetwatch-vpn-nodes = {
    description = "Run the fleetwatch VPN-node liveness push every 10 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/10";
      Persistent = true;
    };
  };
}
