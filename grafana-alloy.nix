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
# The Mimir password file at /etc/grafana-agent-password stays mode
# 600 root:root. The NixOS services.alloy module runs alloy under
# systemd DynamicUser=true (no persistent alloy user to chgrp to),
# so we pass the password through systemd's LoadCredential — the
# unit's sandbox sees it at /run/credentials/alloy.service/mimir-password,
# referenced from grafana-alloy.alloy. Cleaner than relaxing file
# perms; pending agenix migration anyway.

{ config, pkgs, lib, ... }:

{
  services.alloy = {
    enable = true;
    configPath = ./grafana-alloy.alloy;
  };

  systemd.services.alloy.serviceConfig.LoadCredential = [
    "mimir-password:/etc/grafana-agent-password"
  ];
}
