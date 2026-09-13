# The host front door, rendered from the fleet model. Replaces ingress-nginx, which is
# archived upstream: nginx here terminates TLS and proxies straight to Services (#1294).
#
# ⚠ IMPORTING THIS IS THE CUTOVER, and it does not work alone. klipper's svclb holds
# :80/:443 by CNI hostport DNAT with no `-d` restriction, so nginx binds both ports and
# receives NOTHING until the ingress-nginx LoadBalancer Service is deleted in the same
# change. Getting the order wrong looks like a dead server, not a misconfiguration.
#
# ⚠ A GREEN BUILD IS NOT A PASSING `nginx -t` — nothing runs nginx against this config
# until the service starts, and the first attempt took all 15 services down on two
# errors that both built clean. Before switching, run the built nginx by hand:
#
#     conf=$(grep -ho '/nix/store/[a-z0-9]*-nginx.conf' result/etc/systemd/system/nginx.service | head -1)
#     nginx=$(grep -ho '/nix/store/[a-z0-9]*-nginx-[0-9.]*/bin/nginx' result/etc/systemd/system/nginx.service | head -1)
#     "$nginx" -t -c "$conf"
#
# ⚠ ../../frontdoor.json IS A COPY of kubes/dhall/frontdoor.json, because isis builds
# from its own checkout. `plan-run frontdoor-check` is what stops it going stale.
#
# ⚠ Upstreams are NAMES resolved per request, which is why every proxy_pass goes
# through a variable: nginx resolves a literal upstream once at startup and caches it
# for ever, so a recreated Service would leave the door pointing at nothing.
{ config, lib, pkgs, ... }:

let
  net = import ../../network.nix;

  # Fixed by the service CIDR, and already nameserver #1 in isis's resolv.conf.
  coreDnsIP = "10.43.0.10";

  cluster = "isis.xinutec.org";

  table = builtins.fromJSON (builtins.readFile ../../frontdoor.json);

  mine = builtins.filter (e: builtins.elem cluster e.clusters) table;

  hosts = lib.unique (map (e: e.host) mine);

  rulesFor = host: builtins.filter (e: e.host == host) mine;

  # ⚠ VpnOnly if ANY rule is: `server_name` is per host, not per location, so taking
  # the safer exposure is the only reading that cannot accidentally publish something.
  vpnOnly = host: lib.any (e: e.exposure == "VpnOnly") (rulesFor host);

  # ⚠ THE POINT OF THE MIGRATION: a VpnOnly host listens on the tunnel address and
  # NOWHERE ELSE. A DNS record is not a boundary; a socket that never listens is.
  # ⚠ No IPv6, and `net.nodes.isis.ipv6` is NOT evidence there is any — that field
  # records what OVH allocated, nothing assigns it, and nginx fails the WHOLE config
  # on an address the host does not hold.
  listenFor = host:
    if vpnOnly host
    then [ net.nodes.isis.vpn ]
    else [ net.nodes.isis.ipv4 net.nodes.isis.vpn ];

  # ⚠ **ONE VARIABLE NAME, REUSED IN EVERY LOCATION — NOT ONE PER ROUTE.**
  # Locations are mutually exclusive within a request, so `$fd_upstream` holds
  # whichever route matched and there is nothing to collide with. Naming them
  # per route instead produced 15 variables with names like
  # `upstream_isis_xinutec_org_share_share_cc58ab5c727c4a25`, and nginx refused
  # the whole config: "could not build variables_hash, you should increase
  # variables_hash_bucket_size: 64". Raising that knob would also work and is
  # the worse fix — it tunes a limit to accommodate names nothing needed.
  #
  # Found 2026-09-01 by running `nginx -t` against the GENERATED config. The
  # build does not run it, and this is the second config error in a row that a
  # green `nixos-rebuild build` reported as fine.
  # ⚠ The leading `$` is PART OF THIS STRING. In a Nix indented string `$${` is
  # an escape for a literal `${`, so writing `$${upstreamVar}` emits the text
  # `${upstreamVar}` rather than the variable reference — checked, not assumed.
  upstreamVar = "$fd_upstream";

  locationFor = e:
    if (e.redirectTo or null) != null
    then {
      # A redirect proxies nothing. `return` rather than `proxy_pass`, and no
      # $request_uri appended: the apex sends visitors to the site's front page,
      # not to the same path on another host.
      return = "301 https://${e.redirectTo or ""}";
    }
    else {
      extraConfig = ''
        set ${upstreamVar} ${e.upstream};
        proxy_pass ${e.scheme}://${upstreamVar}:${toString e.port};
      ''
      + lib.optionalString ((e.maxBodySize or null) != null) ''
        client_max_body_size ${e.maxBodySize or ""};
      ''
      + lib.optionalString ((e.readTimeout or null) != null) ''
        proxy_read_timeout ${toString (e.readTimeout or 0)};
      ''
      + lib.optionalString ((e.basicAuth or null) != null) ''
        auth_basic "Authentication required";
        # ⚠ THE FILE MUST EXIST BEFORE CUTOVER. The credentials live as a
        # git-crypt'd Kubernetes Secret (${e.basicAuth or ""}) and nothing puts them
        # on the host yet. nginx refuses to start on a missing file, which is
        # the right failure: silently dropping auth would publish the share.
        auth_basic_user_file ${basicAuthDir}/${
          lib.replaceStrings [ "/" ] [ "-" ] (e.basicAuth or "")
        }.htpasswd;
      '';
    };

  basicAuthDir = "/var/lib/nginx-frontdoor";

  vhostFor = host: {
    name = host;
    value = {
      listenAddresses = listenFor host;
      forceSSL = true;
      useACMEHost = host;
      # ⚠ HSTS, restored (#1320) — ingress-nginx sent exactly this value on every
      # name it served, and the cutover silently dropped it; measured 2026-09-02.
      # Per SERVER, not at http scope: nginx `add_header` is per-block-OVERRIDE —
      # any block that adds its own headers discards every inherited one, so a
      # server-level header survives today's locations (they add none;
      # recommendedProxySettings is `proxy_set_header`, a different directive)
      # and an http-level one would be shadowed the day a location grows an
      # `add_header`. `always` so error responses carry it too. VpnOnly names get
      # it like everything else — ingress-nginx made no distinction either.
      extraConfig = ''
        add_header Strict-Transport-Security "max-age=15724800; includeSubDomains" always;
      '';
      locations = builtins.listToAttrs
        (map (e: { name = e.path; value = locationFor e; }) (rulesFor host));
    };
  };

  # ⚠ **DNS-01 FOR EVERY NAME, INCLUDING THE PUBLIC ONES.** VpnOnly names have
  # no choice — HTTP-01 cannot reach a name that resolves inside the tunnel. The
  # public ones could use HTTP-01, and deliberately do not: the cutover is
  # precisely the moment :80 changes hands, so depending on :80 to issue the
  # certificates that :443 needs would make renewal fail exactly when it is
  # least recoverable.
  # ⚠ **`irc-tls` HAS NO OTHER RENEWER, AND THAT WAS SILENT FOR TEN DAYS.**
  # inspircd does not read `/var/lib/acme`; it mounts the `irc-tls` Kubernetes
  # Secret. Until #1294 a cert-manager Certificate filled that Secret, and the
  # migration removed every Certificate on this cluster — so nothing renewed it
  # and the served certificate was set to expire 2026-11-10 with no successor.
  # The check that should have said so read a WARN, because a probe that cannot
  # ask its question never gets to answer it (fixed, xinutec-infra 18935dc).
  #
  # **Why `postRun` and not a timer.** A separate sync unit is one more thing
  # that can stop quietly, which is the failure being repaired here. `postRun`
  # is `ExecStartPost` of the acme unit itself: it runs as root (systemd `+`
  # prefix), in the certificate's own directory, and ONLY when a renewal
  # actually happened — the module guards it on the `renewed` marker. So the
  # copy cannot drift from the renewal: either both happen or the acme unit
  # fails where systemd can see it.
  #
  # **Why not mount the host certificate directly** and drop the Secret, which
  # would leave exactly one copy of the key: it needs a per-certificate group
  # (the pod is uid/gid 39, these files are `acme:nginx` 0640, and granting
  # `nginx` would hand the IRC server read access to EVERY certificate here,
  # including the vault's), a `hostPath` volume the model has no constructor
  # for, and a `gnutls.conf` repoint in a repository that auto-deploys in five
  # minutes. All of that ends in a pod rollout, and every rollout is a visible
  # reconnect for everyone on the server. This is the same end state without
  # disconnecting anybody.
  #
  # `kubectl apply` rather than `create`: it must update an existing Secret, and
  # it must be idempotent because a renewal can be retried.
  ircdSecretSync = ''
    ${pkgs.k3s}/bin/kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
      -n ircd create secret tls irc-tls \
      --cert=fullchain.pem --key=key.pem \
      --dry-run=client -o yaml \
    | ${pkgs.k3s}/bin/kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml apply -f -
  '';

  certFor = host: {
    name = host;
    value = {
      dnsProvider = "cloudflare";
      # ⚠ NOT IN THIS REPOSITORY — nixos-config is public. The token exists as
      # the `cloudflare-api-token` Secret in cert-manager; this wants it as an
      # environment file on the host, and provisioning it is a cutover step.
      environmentFile = "/var/lib/secrets/acme-cloudflare.env";
      group = "nginx";
    } // lib.optionalAttrs (host == "irc.xinutec.net") {
      postRun = ircdSecretSync;
    };
  };
  publicAddrs = [ net.nodes.isis.ipv4 net.nodes.isis.ipv6 ];

  # ⚠ **THE ONE MISTAKE HERE THAT WOULD BE SILENT.** Every other error in this
  # file announces itself: a wrong upstream 502s, a missing htpasswd refuses to
  # start, a bad certificate shows in the browser. A VpnOnly host that also
  # listens on the public address serves perfectly — it is simply reachable by
  # anyone who knows the name, which is exactly the state this migration exists
  # to end (#1300). So it is an assertion rather than a comment, and it lives
  # beside the thing it protects so it holds at cutover and not only in CI.
  leaked = builtins.filter
    (h: vpnOnly h && lib.any (a: builtins.elem a publicAddrs) (listenFor h))
    hosts;
in
assert lib.assertMsg (leaked == [ ])
  "frontdoor: these VpnOnly hosts would listen on a public address: ${toString leaked}";
{
  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;

    # ⚠ `valid=5s` MATCHES CoreDNS's TTL rather than overriding it. `ipv6=off`
    # because Services are v4-only here and nginx treats a failed AAAA as a
    # resolution failure.
    appendHttpConfig = ''
      resolver ${coreDnsIP} valid=5s ipv6=off;
    '';

    virtualHosts = builtins.listToAttrs (map vhostFor hosts);
  };

  security.acme = {
    acceptTerms = true;
    defaults.email = "pip88nl@gmail.com";
    certs = builtins.listToAttrs (map certFor hosts);
  };

  # ⚠ **THE htpasswd FILES ARE PROVISIONED OUT OF BAND, BUT THEIR PERMISSIONS
  # ARE NOT.** The content comes from git-crypt'd Kubernetes Secrets and cannot
  # live in this repository, so a human or a script puts it here. Ownership is a
  # different question and belongs in the model: `nginx` workers read
  # `auth_basic_user_file` at request time, and the files land `root:root 0640`
  # from whatever wrote them — unreadable by nginx, and the `nginx` group does
  # not even exist until this module is imported. Declaring it means activation
  # fixes it rather than somebody remembering to.
  #
  # `z` rather than `f`: adjust an existing file's mode and owner, never create
  # or truncate one. A `f` here would silently replace a provisioned credential
  # with an empty file, and empty htpasswd means every request is refused.
  systemd.tmpfiles.rules = [
    "d ${basicAuthDir} 0750 root nginx -"
    "z ${basicAuthDir}/web-basic-auth.htpasswd 0640 root nginx -"
    "z ${basicAuthDir}/web-slides-auth.htpasswd 0640 root nginx -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
