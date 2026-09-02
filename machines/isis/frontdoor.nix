# The host front door, rendered from the fleet model.
#
# ⚠ **IMPORTED, AND THAT IMPORT IS THE CUTOVER** — see THE ORDER below, because
# it does not work alone.
#
# ⚠ **THE FIRST ATTEMPT TOOK ALL 15 SERVICES DOWN**, 2026-09-01. The LoadBalancer
# Service was deleted, nginx refused to start on a config error, and nothing
# served until the Service was restored and the generation rolled back. TWO
# config errors were involved, and `nixos-rebuild build` exited 0 on BOTH:
#
#     listen 2001:...::1:80    invalid port — the IPv6 literal needs brackets
#     variables_hash           one $upstream variable per route overflowed it
#
# ⚠ **A GREEN BUILD IS NOT A PASSING `nginx -t`.** Nothing runs nginx against
# this config until the service starts. Before switching, build and then run the
# built nginx against the generated nginx.conf by hand:
#
#     conf=$(grep -ho '/nix/store/[a-z0-9]*-nginx.conf' result/etc/systemd/system/nginx.service | head -1)
#     nginx=$(grep -ho '/nix/store/[a-z0-9]*-nginx-[0-9.]*/bin/nginx' result/etc/systemd/system/nginx.service | head -1)
#     "$nginx" -t -c "$conf"
#
# That check found the second error after the first had already caused an
# outage. It costs one command.
#
# WHAT IT REPLACES. `ingress-nginx` is archived upstream (read-only since March
# 2026, v1.15.1 terminal). This takes it out of the path entirely: nginx on the
# host terminates TLS and proxies straight to cluster Services. #1294.
#
# ⚠ **THE HOSTS COME FROM `../../frontdoor.json`, WHICH IS A COPY.** The source
# is `kubes/dhall/frontdoor.json`, rendered by the same model that renders the
# manifests. A copy rather than an import because isis builds from its own
# checkout and the kubes tree is not there — the same lockfile discipline
# `generate.sh --check` and `plan/tables/render.sh` already use deliberately.
# `plan-run frontdoor-check` is what stops it going stale.
#
# ⚠ **UPSTREAMS ARE NAMES, RESOLVED AT REQUEST TIME.** CoreDNS answers
# `cluster.local` with TTL 5, so a recreated Service is picked up within seconds.
# A literal ClusterIP would be a front door pointing at nothing from the next
# redeploy until a human noticed. That is why every `proxy_pass` goes through a
# variable: nginx resolves a literal upstream ONCE at startup and caches it
# forever, and only a variable makes it consult `resolver` per request.
#
# ⚠ **THE ORDER, and getting it wrong looks like a dead server rather than a
# misconfiguration.** klipper's svclb pod holds :80/:443 by CNI hostport DNAT,
# NOT by binding a socket — measured on isis 2026-09-01:
#
#     -A CNI-DN-2cd3d29... -p tcp -m tcp --dport 443 -j DNAT --to-destination 10.42.0.96:443
#
# There is no `-d` restriction, so it matches the public address AND the VPN
# address. nginx will therefore BIND :80/:443 happily and receive nothing,
# because PREROUTING diverts before local delivery. The ingress-nginx
# LoadBalancer Service must be deleted in the same change that starts nginx.
# isis activates by `boot`, so on reboot with the Service already gone no rules
# are created and nginx gets the traffic — and the previous generation is one
# power-cycle away in the boot menu.
{ config, lib, pkgs, ... }:

let
  net = import ../../network.nix;

  # k3s's CoreDNS Service address. Fixed by the cluster's service CIDR rather
  # than allocated, and already `nameserver` #1 in isis's /etc/resolv.conf.
  coreDnsIP = "10.43.0.10";

  cluster = "isis.xinutec.org";

  table = builtins.fromJSON (builtins.readFile ../../frontdoor.json);

  mine = builtins.filter (e: builtins.elem cluster e.clusters) table;

  hosts = lib.unique (map (e: e.host) mine);

  rulesFor = host: builtins.filter (e: e.host == host) mine;

  # ⚠ A HOST is VpnOnly if ANY of its rules is, and the direction matters: two
  # rules share `isis.xinutec.org`, and `server_name` is per host rather than
  # per location. Taking the safer of the two exposures is the only reading that
  # cannot accidentally publish something.
  vpnOnly = host: lib.any (e: e.exposure == "VpnOnly") (rulesFor host);

  # ⚠ **THIS IS THE WHOLE POINT OF THE MIGRATION.** A VpnOnly host listens on
  # the tunnel address and NOWHERE ELSE, so the public interface has no
  # `server_name` for it at all. Today `VpnOnly` is a DNS record and the shared
  # controller answers for the name on the public IP regardless (#1300) — a zone
  # file is not a boundary; a socket that never listens for the name is.
  # ⚠ **NO IPv6, AND `net.nodes.isis.ipv6` IS NOT EVIDENCE THAT THERE IS ANY.**
  # That field records the address OVH allocated; nothing assigns it. `ip -6 addr
  # show scope global` on isis returns NOTHING, and `base-configuration.nix` has
  # its `static ip6_address` line commented out. nginx cannot bind an address the
  # host does not hold — `bind() ... failed (99: Cannot assign requested
  # address)` — and it fails the WHOLE config, not just that listener.
  #
  # Dropping it is not a regression: klipper reached these services by iptables
  # DNAT, so the fleet has been IPv4-only throughout. Adding IPv6 means assigning
  # the address first, and then this list.
  #
  # (It also needs brackets when it comes back: `listenAddresses` is pasted into
  # `listen` verbatim, so a bare `2001:...::1` becomes `2001:...::1:80` and nginx
  # reads the final group as a port. That one caused the 2026-09-01 outage.)
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
  certFor = host: {
    name = host;
    value = {
      dnsProvider = "cloudflare";
      # ⚠ NOT IN THIS REPOSITORY — nixos-config is public. The token exists as
      # the `cloudflare-api-token` Secret in cert-manager; this wants it as an
      # environment file on the host, and provisioning it is a cutover step.
      environmentFile = "/var/lib/secrets/acme-cloudflare.env";
      group = "nginx";
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
