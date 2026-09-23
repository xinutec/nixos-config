# CoreDNS's upstreams (#1621). Without this k3s gives CoreDNS the node's
# resolv.conf, which names CoreDNS itself first.
#
# A host puts `config.xinutec.k3sDns.flag` into its `services.k3s.extraFlags`.
# Imported per host, not from the base: the flag restarts k3s, so a host takes it
# when a restart is planned.
{ lib, ... }:

{
  options.xinutec.k3sDns.flag = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
    default = "--resolv-conf=/etc/k3s-resolv.conf";
    description = "The k3s flag that gives CoreDNS the upstreams below.";
  };

  config.environment.etc."k3s-resolv.conf".text = ''
    nameserver 1.1.1.1
    nameserver 8.8.8.8
  '';
}
