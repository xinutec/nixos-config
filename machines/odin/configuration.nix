# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

let net = import ../../network.nix;
in {
  imports = [ ../../base-configuration.nix ./backups.nix ./plan-run.nix ];

  # odin is a 4-thread Atom N2800 with 3 GB of RAM, and it now builds a Rust
  # program on every plan-run pin bump. amun is the same architecture with 8
  # cores and 31 GB, so it does the compiling and odin substitutes the result:
  # a bump costs a minute instead of a slow quarter-hour of a CPU that also owes
  # the 02:30 backup and the Sunday 12:00 drill.
  #
  # `root@amun` is already reachable from odin's root key, and amun has root in
  # its `trusted-users`, which is what a remote builder requires. Nothing about
  # this is specific to plan-run — any build odin needs goes the same way.
  nix.distributedBuilds = true;
  nix.buildMachines = [{
    hostName = "amun.vpn";
    sshUser = "root";
    system = "x86_64-linux";
    maxJobs = 8;
    speedFactor = 4;
    supportedFeatures = [ "big-parallel" "kvm" ];
  }];
  # Let amun pull dependencies from the binary cache itself rather than odin
  # fetching them and copying them over its own uplink.
  nix.settings.builders-use-substitutes = true;

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
