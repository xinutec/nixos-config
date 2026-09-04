# geb as a recall microphone.
#
# The house's recorders are the Mac's USB mic and a set of phones. This makes geb a
# fourth kind: a mains-powered box that never leaves the room and never sleeps, so it
# is the only recorder that cannot be forgotten in a coat pocket or run flat.
#
# It speaks the phones' protocol (recall's docs/devices.md): one shared ingest port,
# a one-line handshake announcing the source id, then raw PCM. The recorder host
# auto-registers the source, so nothing is provisioned on the far side — this file is
# the whole deployment.
#
# What geb does NOT need, being a Linux box: an app, a heartbeat to prove it is alive
# (a dead unit is a failed service, which the fleet already sees), or a person to
# restart it.

{ config, pkgs, lib, ... }:

let
  # recall is a PUBLIC repository, so unlike xinutec-infra — which geb clones to
  # /opt precisely because this repo cannot hold the credentials to fetch it — it
  # can be fetched at evaluation time and pinned here, which is both declarative
  # and reproducible.
  #
  # To bump: change rev, then refresh the hash with
  #   nix-prefetch-url --unpack https://github.com/xinutec/recall/archive/<rev>.tar.gz
  recallRev = "27fb57066ac8ed0c9835a27f7d1e027ea8d4e5ac";
  recallSrc = builtins.fetchTarball {
    url = "https://github.com/xinutec/recall/archive/${recallRev}.tar.gz";
    sha256 = "1y0yr2x4wam62wh5hcv2jn3sks3wxjv4ls58128wvjb4y4wgvaxn";
  };

  # `recall.mic` and the `recall.wire` constants it shares with the server import
  # nothing outside the standard library, on purpose — so this runs on a plain
  # interpreter and geb never needs recall's store, web or ML dependencies.
  # `python3 -m recall` would pull all three in and fail here.
  micPython = pkgs.python3;

  # By CARD NAME, not `hw:1,0`. This is not a precaution, it is a report: the USB
  # mic was card 1 all morning, geb rebooted, and it came back as card 0 with the
  # motherboard's analog input at 1. Measured immediately after, `hw:1,0` captured
  # -inf — digital silence from a jack with nothing in it — while the name below
  # captured the room at -52.8 dB. An index would have recorded nothing, looking
  # exactly like a quiet house. The name comes from the device (/proc/asound/*/id).
  micDevice = "hw:CARD=N32,DEV=0";

  # The recorder host, BY NAME: the router registers DHCP hostnames, so this
  # survives a lease change where a pinned address would not (the same reasoning
  # the ssh config gives for reaching geb itself). The client re-resolves on every
  # reconnect, so a name that is briefly NXDOMAIN costs a retry, not the service.
  recorderHost = "mac-mini";
in
{
  # The mic is a USB conference unit: 48 kHz, and stereo only — its two channels
  # carry one capsule's signal duplicated, measured bit-identical, so the client
  # downmixes to mono and halves what goes on the wire.
  systemd.services.recall-mic = {
    description = "Stream geb's USB microphone to the recall ingester";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "sound.target" ];

    # ffmpeg opens ALSA and does the downmix; recall.mic only moves bytes to the
    # socket. Keeping our code out of the device path is recall's own rule for
    # real-time capture.
    path = [ pkgs.ffmpeg ];

    environment = {
      PYTHONPATH = "${recallSrc}/src";
      # Unbuffered, or the journal shows nothing until a buffer happens to flush —
      # and the first thing anyone asks this unit is "is it streaming right now".
      PYTHONUNBUFFERED = "1";
    };

    serviceConfig = {
      ExecStart = lib.concatStringsSep " " [
        "${micPython}/bin/python3 -m recall.mic"
        "--id geb"
        "--host ${recorderHost}"
        "--device ${micDevice}"
      ];

      # A recorder that is down is recording nothing, and nobody is watching this
      # box. Always, including a clean exit: the client returns non-zero when its
      # capture process dies, and that is exactly the case worth restarting.
      Restart = "always";
      RestartSec = "5s";

      # ⚠ A RECORDER MUST OUTRANK WHATEVER ELSE THE BOX IS DOING. On the Mac this
      # was learnt expensively: capture sat in macOS's throttled class by
      # configuration and dropped a quarter of its minutes under load, for weeks,
      # while looking healthy (recall #1330). geb is nearly idle today, so this
      # costs nothing today — the point is that it stays true when it stops being
      # idle, which is precisely when it stops being noticeable.
      Nice = -5;
      IOSchedulingClass = "best-effort";
      IOSchedulingPriority = 2;

      # No secrets and no state: the ingest port is deliberately unauthenticated
      # (recall's docs/devices.md — a mic that could 401 would report a credential
      # mistake as dead hardware), and nothing is written to disk.
      DynamicUser = true;
      SupplementaryGroups = [ "audio" ];  # /dev/snd
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
    };
  };

  # arecord/amixer. This box is headless with no monitor, and every question worth
  # asking about a microphone — is it muted, what rate does it offer, is it hearing
  # anything — is one of these commands. Diagnosing it without them meant fetching
  # a shell from the network first.
  environment.systemPackages = [ pkgs.alsa-utils ];
}
