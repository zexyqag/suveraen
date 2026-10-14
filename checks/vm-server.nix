# A cluster server as a node of a NixOS test: it boots from its own plain disk, so there's nothing to unlock,
# reaches the outside through eth0 and its peers on eth1, and loads k3s's own images from the release tarball.
{ config, lib, ... }:
{
  boot.initrd.network.enable = lib.mkForce false;

  # The test network has no IPv6 router; give the node an address and a route.
  networking.interfaces.eth1.ipv6 = {
    addresses = [
      {
        address = "fd00::2";
        prefixLength = 64;
      }
    ];
    routes = [
      {
        address = "::";
        prefixLength = 0;
        via = "fd00::1";
      }
    ];
  };

  services.k3s.images = [ config.services.k3s.package.airgap-images ];

  networking.hostId = "0400bdef";
  system.stateVersion = "26.05";

  suveraen = {
    storage.systemDisks = [
      "/dev/disk/by-id/test-0"
      "/dev/disk/by-id/test-1"
    ];
    # "en*" would also match eth1, the test network, through its alternative names.
    network.interface = "eth0";
    cluster = {
      enable = true;
      nodeIP = [
        config.networking.primaryIPAddress
        "fd00::2"
      ];
    };
  };
}
