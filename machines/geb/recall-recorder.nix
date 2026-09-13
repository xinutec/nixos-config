# geb as a store-and-forward recorder (recall's docs/architecture.md, stage C3).
#
# LIVE since 2026-09-05 — this is geb's recorder, imported by ./configuration.nix.
# The cutover from ./recall-mic.nix (the streaming client) was a deliberate flip:
# the two cannot run together — one ALSA capture device, one reader — so there was
# no shadow period on this box; the flip was the change, made with someone around
# to hear it fail. Verified 2026-09-06: recall-capture and recall-pause-mirror
# active on geb, recall-mic inactive, and Isis holds 976 delivered geb segments.
#
# ./recall-mic.nix is therefore dead and no longer imported. It is kept for now
# rather than deleted, because the replacement has run for a day and this repo's
# rule is that a path dies once its replacement has survived real days.
#
# What changes, and why it is the better recorder:
#   - Audio is written to LOCAL segments first (60 s, capture-stamped) and
#     delivered to recalld on Isis with sha-256 receipts the uploader verifies
#     before anything counts as delivered. A network blip, a Mac outage, or a
#     recalld rollout now costs delivery latency, never audio — the streaming
#     client discards while disconnected, by documented design.
#   - The household pause still rules: audiod's pause-mirror polls the control
#     plane and maintains the same capture_paused_until file the capture loop
#     honours on every cycle. Isis unreachable = keep the last known state
#     (completeness outranks; a poller must never invent a pause).
#   - The device path keeps geb's own proven shape: ffmpeg opens ALSA (the
#     card-by-NAME lesson below still applies) and audiod only pumps bytes —
#     the same our-code-out-of-the-device-path rule as before.
#
# The ingest token is geb's own line in recall-secret's INGEST_TOKENS (write-
# only, pinned to source `geb`). It lives in /var/lib/recall-secrets/env as
#   RECALL_INGEST_TOKEN=…
# placed by hand, root-owned 0600 — this repository is public.

{ config, pkgs, lib, ... }:

let
  # audiod is PINNED OUT-OF-BAND: geb evaluates channels-style (no flakes in
  # nix.conf), so the flake build happens once by hand and the out-link is the
  # GC root this module points at. To bump:
  #   sudo nix --extra-experimental-features 'nix-command flakes' \
  #     build github:xinutec/recall/<rev>#audiod --out-link /opt/audiod
  # ⚠ Read the symlink for the live revision; it is `2adcafa` as of 2026-09-13.
  # The pin moves out of band, so this line cannot fail when they disagree.
  audiod = "/opt/audiod";

  # By CARD NAME, not index — the mic changed indexes across a reboot and an
  # index recorded -inf from an empty jack while looking healthy (see
  # recall-mic.nix, which learnt this first).
  #
  # ⚠ On any mic swap, measure the exact-zero sample fraction before trusting it.
  # A gating microphone passes every other check: it enumerates, ffmpeg opens it,
  # segments arrive, and the levels look flatteringly low. The last one gated to
  # digital zero between words (#1526).
  micDevice = "hw:CARD=Microphone,DEV=0";

  root = "/var/lib/recall";
  isisIngest = "http://10.100.0.2:8001";
  isisControl = "http://10.100.0.2:8000";

  hardening = {
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ProtectKernelTunables = true;
    ProtectControlGroups = true;
    RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
    ReadWritePaths = [ root ];
  };
in
{
  systemd.tmpfiles.rules = [ "d ${root} 0750 recall-recorder audio -" ];

  users.users.recall-recorder = {
    isSystemUser = true;
    group = "audio";
  };

  # The recorder proper: ffmpeg reads ALSA, audiod segments and stamps.
  systemd.services.recall-capture = {
    description = "Record geb's microphone into capture-stamped local segments";
    wantedBy = [ "multi-user.target" ];
    after = [ "sound.target" ];
    path = [ pkgs.ffmpeg ];
    serviceConfig = hardening // {
      User = "recall-recorder";
      ExecStart = "${audiod}/bin/audiod capture --root ${root} --id geb --device ${micDevice} --producer alsa";
      Restart = "always";
      RestartSec = "5s";
      # A recorder outranks whatever else the box does (recall #1330's lesson).
      Nice = -5;
      IOSchedulingClass = "best-effort";
      IOSchedulingPriority = 2;
      SupplementaryGroups = [ "audio" ];
    };
  };

  # Delivery: closed segments to recalld, receipts re-hashed. A timer, so a
  # crashed pass costs one interval. Eviction is NOT here yet — geb has disk
  # to spare and stage-B rules say only verified segments ever go, under a
  # ceiling, which arrives with the audiod eviction flag.
  systemd.services.recall-upload = {
    description = "Deliver geb's closed segments to recalld (verified receipts)";
    after = [ "network-online.target" ];
    serviceConfig = hardening // {
      User = "recall-recorder";
      Type = "oneshot";
      EnvironmentFile = "/var/lib/recall-secrets/env";
      ExecStart = "${audiod}/bin/audiod upload --root ${root} --url ${isisIngest} --max 500";
      Nice = 10;
      IOSchedulingClass = "idle";
    };
  };
  systemd.timers.recall-upload = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "1m"; OnUnitActiveSec = "1m"; };
  };

  # The pause: poll the control plane, maintain the same capture_paused_until
  # file the capture loop already honours. Conservative by construction —
  # unreachable control plane leaves the last state standing.
  systemd.services.recall-pause-mirror = {
    description = "Mirror the household pause onto geb's recorder";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    serviceConfig = hardening // {
      User = "recall-recorder";
      ExecStart = "${audiod}/bin/audiod pause-mirror --root ${root} --url ${isisControl}";
      Restart = "always";
      RestartSec = "10s";
    };
  };

  environment.systemPackages = [ pkgs.alsa-utils ];
}
