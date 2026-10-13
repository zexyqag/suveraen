# Builds a watcher with stand-in values; nothing here points at a real machine.
{ modulesPath, ... }:
{
  # Hetzner Cloud VMs need the virtio disk and PCI drivers at boot.
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  nixpkgs.hostPlatform = "x86_64-linux";
  networking.hostName = "example-watcher";
  networking.hostId = "5c1e0a7d";
  system.stateVersion = "26.05";

  suveraen = {
    adminKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN9QsUU2i+9+MwdvtxOsPVD6L24UHYJXVJRI2oe+9oHP example"
    ];
    storage = {
      systemDisks = [ "/dev/sda" ];
      encrypted = false;
      reserve = "2G";
      arcMax = 256 * 1024 * 1024;
    };
    network = {
      ipv6 = "2001:db8:2::1/64";
      ipv6Gateway = "fe80::1";
    };
    watcher = {
      enable = true;
      ntfyHost = "alerts.example.org";
      statusHost = "status.example.org";
      readers = [ "example" ];
      ntfyEnvironmentFile = "/run/secrets/ntfy-env";
      gatusEnvironmentFile = "/run/secrets/gatus-env";
      servers = [ "example" ];
      checks = [
        {
          name = "accounts";
          url = "https://idm.example.org/status";
        }
      ];
    };
    alerts = {
      urlFile = "/run/secrets/alerts-url";
      tokenFile = "/run/secrets/alerts-token";
      smart = false;
    };
    upgrade.flake = "github:example/example";
  };
}
