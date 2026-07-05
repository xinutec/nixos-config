# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

let net = import ../../network.nix;
in {
  imports = [ ../../base-configuration.nix ./backups.nix ];

  fileSystems."/export/home" = {
    device = "${net.nodes.master.vpn}:/export/home";
    fsType = "nfs4";
  };

  virtualisation.oci-containers.containers = {
    buildfarm-redis = {
      image = "redis:alpine";
      # buildfarm's shared redis: host networking to serve the build cluster.
      # ast-grep-ignore: nix-oci-host-namespace
      extraOptions = [ "--network=host" ];
    };
  };
}
