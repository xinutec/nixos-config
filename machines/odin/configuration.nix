# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

let net = import ../../network.nix;
in {
  imports = [ ../../base-configuration.nix ];

  fileSystems."/export" = {
    device = "${net.nodes.master.vpn}:/export";
    fsType = "nfs4";
  };

  virtualisation.oci-containers.containers = {
    buildfarm-redis = {
      image = "redis:alpine";
      extraOptions = [ "--network=host" ];
    };
  };

  # Enable cron service
  services.cron = {
    enable = true;
    systemCronJobs = [
      "0 * * * *        root    /etc/nixos/machines/${config.node.name}/backup.sh"
    ];
  };
}
