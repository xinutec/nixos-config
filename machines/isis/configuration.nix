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
  ];

  # No machine-specific PUBLIC ports. Verified against live `ss` (2026-07):
  #   2223, 28192 → nothing was listening on isis; dead leftover rules.
  networking.firewall.allowedTCPPorts = [ ];

  # recall web app, gated to the pippijn Nextcloud account.
  #
  # DELIBERATELY NOT on the shared k3s ingress: that ingress answers on isis's
  # PUBLIC interface too (confirmed for messages.xinutec.org — a private-only DNS
  # record there is "obscurity, not a firewall", since anyone can hit the public IP
  # with the right Host header regardless of what DNS says). recall must stay
  # off the public internet, so oauth2-proxy runs as a plain systemd service bound
  # directly to the WireGuard IP (a hard socket-level guarantee, not DNS-dependent):
  # the public NIC never has anything listening for it (allowedTCPPorts = [] above).
  #
  # The Mac's reverse SSH tunnel (recall-tunnel) publishes recall on isis-localhost
  # 127.0.0.1:8001 (loopback only); oauth2-proxy is the sole thing fronting it,
  # requiring a Nextcloud login (the built-in oauth2 app on dash.xinutec.org) and
  # membership of the `recall` NC group.
  #
  # TLS: recall.xinutec.org must resolve to the VPN IP (10.100.0.2) for the
  # redirect URI Nextcloud's OAuth2 client is registered with, so its cert needs
  # DNS-01 (HTTP-01 can't validate a hostname the CA can't reach). Reuses the same
  # Cloudflare API token already provisioned for cert-manager's letsencrypt-dns
  # ClusterIssuer (kubes/messages/k8s/00-letsencrypt-dns-issuer.yaml) — one token,
  # same scope (Zone:DNS:Edit), same purpose (VPN-only-IP hostnames), copied into
  # its own agenix secret since this cert is issued by the host, not by k8s.
  security.acme.acceptTerms = true;
  security.acme.defaults.email = "pip88nl@gmail.com";

  age.secrets."cloudflare-dns01-token".file = ../../agenix/cloudflare-dns01-token.age;
  security.acme.certs."recall.xinutec.org" = {
    dnsProvider = "cloudflare";
    environmentFile = config.age.secrets."cloudflare-dns01-token".path;
    group = "oauth2-proxy";
    reloadServices = [ "oauth2-proxy.service" ];
  };

  age.secrets."oauth2-proxy-recall-client-secret".file =
    ../../agenix/oauth2-proxy-recall-client-secret.age;
  age.secrets."oauth2-proxy-recall-cookie-secret".file =
    ../../agenix/oauth2-proxy-recall-cookie-secret.age;

  services.oauth2-proxy = {
    enable = true;
    provider = "nextcloud";
    loginURL = "https://dash.xinutec.org/apps/oauth2/authorize";
    redeemURL = "https://dash.xinutec.org/apps/oauth2/api/v1/token";
    validateURL = "https://dash.xinutec.org/ocs/v2.php/cloud/user?format=json";
    # Path matches the "recall" OAuth2 client already registered in Nextcloud
    # (redirect URI https://recall.xinutec.org/auth/callback) — proxy-prefix
    # below moves oauth2-proxy's own endpoints from its default /oauth2 to /auth
    # so the callback path lines up without re-registering the NC client.
    clientID = "hOeUDGGZXGHBcemsGaKh3f3WfwmA6ew5dbmwD6e4debtM8ykjFQE4qpVfpBq6C8B";
    clientSecretFile = config.age.secrets."oauth2-proxy-recall-client-secret".path;
    cookie.secretFile = config.age.secrets."oauth2-proxy-recall-cookie-secret".path;
    redirectURL = "https://recall.xinutec.org/auth/callback";
    upstream = [ "http://127.0.0.1:8001" ];
    email.domains = [ "*" ];        # any NC email; the group check is the real gate
    tls = {
      enable = true;
      httpsAddress = "${net.nodes.isis.vpn}:443";
      certificate = "${config.security.acme.certs."recall.xinutec.org".directory}/fullchain.pem";
      key = "${config.security.acme.certs."recall.xinutec.org".directory}/key.pem";
    };
    extraConfig = {
      "allowed-group" = "recall";     # only the `recall` NC group (pippijn) gets in
      "proxy-prefix" = "/auth";
      "skip-provider-button" = "true";
      "provider-display-name" = "Nextcloud";
    };
  };

  # The oauth2-proxy module does not auto-order against the ACME cert it reads by
  # path — without this, first activation can race (oauth2-proxy starting before
  # the cert is issued) and crash-loop on a missing file. `reloadServices` above
  # only covers restart-on-renewal, not this initial ordering.
  systemd.services.oauth2-proxy = {
    after = [ "acme-recall.xinutec.org.service" ];
    wants = [ "acme-recall.xinutec.org.service" ];
  };

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
}
