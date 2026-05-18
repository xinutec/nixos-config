# grafana-alloy.nix — declarative config for Grafana Alloy via
# services.alloy. Replaces grafana-agent.nix and the docker
# `grafana` container in base-configuration.nix.
#
# Why: grafana-agent (static mode) was deprecated and reached EOL on
# 2025-11-01. Alloy is the supported successor. Migration was done
# by running `alloy convert --source-format=static` on the existing
# grafana-agent.yaml and cleaning up the result for native (non-
# docker) execution.
#
# The Mimir password is an agenix secret (agenix/grafana-agent-password.age),
# decrypted at activation to /run/agenix/grafana-agent-password. The
# NixOS services.alloy module runs alloy under systemd DynamicUser=true
# (no persistent alloy user to chgrp to), so the password is passed
# through systemd's LoadCredential — the unit's sandbox sees it at
# /run/credentials/alloy.service/mimir-password, referenced from
# grafana-alloy.alloy.

{ config, pkgs, lib, ... }:

{
  services.alloy = {
    enable = true;
    configPath = ./grafana-alloy.alloy;
  };

  age.secrets."grafana-agent-password".file =
    ./agenix/grafana-agent-password.age;

  systemd.services.alloy.serviceConfig.LoadCredential = [
    "mimir-password:${config.age.secrets."grafana-agent-password".path}"
  ];
}
