# The front door's certificates: one per host ../frontdoor.json places on this
# node, issued by DNS-01. frontdoor.nix serves them; this half exists on its own
# so a node can hold its certificates BEFORE its nginx takes ports 80 and 443
# (amun, 2026-10-04: issued while ingress-nginx still served, then the cutover).
#
# DNS-01 for every name. VpnOnly names have no choice, and the public ones are
# deliberately the same: depending on :80 to issue the certificates :443 needs
# would break renewal exactly when :80 changes hands.
{ config, lib, pkgs, ... }:

let
  cluster = "${config.node.name}.xinutec.org";

  table = builtins.fromJSON (builtins.readFile ./frontdoor.json);

  hosts = lib.unique (map (e: e.host)
    (builtins.filter (e: builtins.elem cluster e.clusters) table));

  # Its own cache dir: these units have no HOME, so kubectl made `.kube` in the
  # working directory, the certificate's, and lego's `chmod -R` there then
  # failed every renewal (2026-10-05).
  kubectl = "${pkgs.k3s}/bin/kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml --cache-dir /var/cache/frontdoor-kubectl";

  # ⚠ A delegated certificate has NO other renewer: the workload mounts the
  # Kubernetes Secret and does not read /var/lib/acme, so this `postRun` IS the
  # renewal and its absence is silent. `postRun` rather than a timer because it
  # is `ExecStartPost` of the acme unit: same run, same directory, and only when
  # a renewal happened. `apply`, not `create`: it updates an existing Secret and
  # a renewal can retry.
  #
  # Not a hostPath mount of the certificate instead: granting the pod's group
  # read access would hand it EVERY certificate here.
  secretSync = d: ''
    ${kubectl} -n ${d.namespace} create secret tls ${d.secret} \
      --cert=fullchain.pem --key=key.pem \
      --dry-run=client -o yaml \
    | ${kubectl} apply -f -
  '';

  certFor = host: {
    name = host;
    value = {
      dnsProvider = "cloudflare";
      environmentFile = config.age.secrets."acme-cloudflare".path;
      group = config.frontdoor.certGroup;
    } // lib.optionalAttrs (config.frontdoor.delegations ? ${host}) {
      postRun = secretSync config.frontdoor.delegations.${host};
    };
  };
in
{
  # Not read off `services.nginx.enable`: nginx's module reads these
  # certificates back, and asking it here is an infinite recursion.
  options.frontdoor.certGroup = lib.mkOption {
    type = lib.types.str;
    default = "acme";
    description = "Who may read the certificates: acme's own until nginx serves them (frontdoor.nix).";
  };

  options.frontdoor.delegations = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        namespace = lib.mkOption { type = lib.types.str; };
        secret = lib.mkOption { type = lib.types.str; };
      };
    });
    default = { };
    description = ''
      Certificates a cluster workload mounts as a Kubernetes TLS Secret, by host:
      each renewal is written into that Secret. Declared per machine, so one can
      be switched on at the moment its old renewer (cert-manager on amun) stops,
      and the two never fight over the Secret.
    '';
  };

  config = {
    assertions = [
      {
        assertion = lib.all (h: builtins.elem h hosts) (builtins.attrNames config.frontdoor.delegations);
        message = "frontdoor.delegations names a host frontdoor.json does not place on ${config.node.name}";
      }
    ];

    # `CLOUDFLARE_DNS_API_TOKEN=…`, scoped Zone:DNS:Edit.
    age.secrets."acme-cloudflare".file = ./agenix/acme-cloudflare.age;

    # The same sync once when a delegation is switched on, and on every boot, as
    # well as at each renewal (`postRun` above): a renewal comes only within 30
    # days of expiry, and the Secret's previous renewer (cert-manager on amun)
    # may have left a certificate that expires first.
    systemd.services = lib.mapAttrs'
      (host: d: lib.nameValuePair "frontdoor-delegate-${lib.replaceStrings [ "." ] [ "-" ] host}" {
        description = "Write ${host}'s certificate into the ${d.namespace}/${d.secret} Secret";
        wantedBy = [ "multi-user.target" ];
        wants = [ "acme-finished-${host}.target" ];
        after = [ "acme-finished-${host}.target" "k3s.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          WorkingDirectory = "/var/lib/acme/${host}";
        };
        script = secretSync d;
      })
      config.frontdoor.delegations;

    security.acme = {
      acceptTerms = true;
      defaults.email = "pip88nl@gmail.com";
      certs = builtins.listToAttrs (map certFor hosts);
    };
  };
}
