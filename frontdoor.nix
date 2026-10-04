# The host front door, rendered from the fleet model: nginx terminates TLS and
# proxies straight to Services (#1294).
#
# ⚠ A green build is NOT a passing `nginx -t`, and an error that builds clean takes
# every name down. Before switching, run the built nginx by hand:
#
#     conf=$(grep -ho '/nix/store/[a-z0-9]*-nginx.conf' result/etc/systemd/system/nginx.service | head -1)
#     nginx=$(grep -ho '/nix/store/[a-z0-9]*-nginx-[0-9.]*/bin/nginx' result/etc/systemd/system/nginx.service | head -1)
#     "$nginx" -t -c "$conf"
#
# Any node whose network.nix edge is "frontdoor" imports this: isis since #1294,
# amun since 2026-10-04 (ingress-nginx was archived upstream). Its certificates
# are frontdoor-certs.nix's.
#
# ./frontdoor.json is a COPY of kubes/dhall/frontdoor.json; `plan-run
# frontdoor-check` stops it going stale.
#
# ⚠ Every proxy_pass goes through a variable because nginx resolves a literal
# upstream once at startup and caches it for ever.
{ config, lib, pkgs, ... }:

let
  node = config.node;

  # Fixed by k3s's default service CIDR, the same on both clusters.
  coreDnsIP = "10.43.0.10";

  cluster = "${node.name}.xinutec.org";

  table = builtins.fromJSON (builtins.readFile ./frontdoor.json);

  mine = builtins.filter (e: builtins.elem cluster e.clusters) table;

  hosts = lib.unique (map (e: e.host) mine);

  rulesFor = host: builtins.filter (e: e.host == host) mine;

  # VpnOnly if ANY rule is: `server_name` is per host, not per location.
  vpnOnly = host: lib.any (e: e.exposure == "VpnOnly") (rulesFor host);

  # A VpnOnly host listens on the tunnel address and NOWHERE else — a DNS record
  # is not a boundary, a socket that never listens is.
  #
  # ⚠ No IPv6: `node.ipv6` records what OVH allocated, nothing assigns it (on
  # isis or amun), and nginx fails the WHOLE config on an address the host does
  # not hold.
  listenFor = host:
    if vpnOnly host
    then [ node.vpn ]
    else [ node.ipv4 node.vpn ];

  # ONE name reused in every location, not one per route: locations are mutually
  # exclusive within a request, and a name per route overflows nginx's
  # `variables_hash_bucket_size`.
  #
  # ⚠ The leading `$` is part of this string. `$${` in a Nix indented string
  # escapes a literal `${`.
  upstreamVar = "$fd_upstream";

  locationFor = e:
    if (e.redirectTo or null) != null
    then {
      # `return`, not `proxy_pass`, and no $request_uri: the apex sends visitors
      # to the front page, not to the same path on another host.
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
        # THE FILE MUST EXIST BEFORE CUTOVER. The credentials live as a
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
      # HSTS (#1320), per SERVER: nginx `add_header` is a per-block OVERRIDE, so
      # an http-scope header is discarded the day any location adds one of its
      # own. `always` so error responses carry it too.
      extraConfig = ''
        add_header Strict-Transport-Security "max-age=15724800; includeSubDomains" always;
      '';
      locations = builtins.listToAttrs
        (map (e: { name = e.path; value = locationFor e; }) (rulesFor host));
    };
  };

  publicAddrs = [ node.ipv4 node.ipv6 ];

  # One htpasswd per basicAuth Secret this node's rows name.
  authFiles = lib.unique (map
    (e: "${basicAuthDir}/${lib.replaceStrings [ "/" ] [ "-" ] (e.basicAuth or "")}.htpasswd")
    (builtins.filter (e: (e.basicAuth or null) != null) mine));

  # The one mistake here that would be SILENT: a VpnOnly host also listening on
  # the public address serves perfectly, it is just reachable by anyone who knows
  # the name (#1300). Hence an assertion rather than a comment.
  leaked = builtins.filter
    (h: vpnOnly h && lib.any (a: builtins.elem a publicAddrs) (listenFor h))
    hosts;
in
{
  imports = [ ./frontdoor-certs.nix ];

  frontdoor.certGroup = "nginx";

  # In `assertions`, not an `assert` around the module: it reads `config.node`,
  # and a module whose shape depends on config is an infinite recursion.
  assertions = [
    {
      assertion = leaked == [ ];
      message = "frontdoor: these VpnOnly hosts would listen on a public address: ${toString leaked}";
    }
    {
      assertion = config.node.edge == "frontdoor";
      message = "frontdoor.nix is imported on ${config.node.name}, whose network.nix edge is not \"frontdoor\"";
    }
  ];

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;

    # `valid=5s` matches CoreDNS's TTL. `ipv6=off` because Services are v4-only
    # and nginx treats a failed AAAA as a resolution failure.
    appendHttpConfig = ''
      resolver ${coreDnsIP} valid=5s ipv6=off;
    '';

    virtualHosts = builtins.listToAttrs (map vhostFor hosts);
  };

  # The htpasswd files are provisioned out of band; their PERMISSIONS are not.
  # nginx workers read them at request time and they land `root:root 0640` from
  # whatever wrote them, unreadable by nginx.
  #
  # ⚠ `z`, never `f`: `f` would replace a provisioned credential with an empty
  # file, and an empty htpasswd refuses every request.
  systemd.tmpfiles.rules = [ "d ${basicAuthDir} 0750 root nginx -" ]
    ++ map (f: "z ${f} 0640 root nginx -") authFiles;

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
