# Builds a watcher with stand-in values; nothing here points at a real machine.
{ modulesPath, ... }:
{
  imports = [
    # Hetzner Cloud VMs need the virtio disk and PCI drivers at boot.
    (modulesPath + "/profiles/qemu-guest.nix")
    ./dns-example.nix
  ];

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
      # Static: the hidden signer lets peers in by address.
      ipv4 = "203.0.113.20/32";
      ipv4Gateway = "203.0.113.1";
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
      servers = [
        "example"
        "example-ns"
      ];
      checks = [
        {
          name = "accounts";
          url = "https://idm.example.org/status";
        }
      ];
    };
    dns.self = "example-watcher";
    alerts = {
      urlFile = "/run/secrets/alerts-url";
      tokenFile = "/run/secrets/alerts-token";
      smart = false;
    };
    # The watcher runs new changes first, before they are signed for the servers.
    source = {
      repository = "https://example.org/suveraen.git";
      branch = "staging";
    };
  };
}
