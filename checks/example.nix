# Builds the node layer with stand-in values; nothing here points at a real machine.
{
  nixpkgs.hostPlatform = "x86_64-linux";
  networking.hostName = "example";
  networking.hostId = "0400bdef";
  system.stateVersion = "26.05";

  suveraen = {
    adminKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN9QsUU2i+9+MwdvtxOsPVD6L24UHYJXVJRI2oe+9oHP example"
    ];
    storage.systemDisks = [
      "/dev/disk/by-id/nvme-example-0"
      "/dev/disk/by-id/nvme-example-1"
    ];
    network = {
      ipv4 = "203.0.113.10/32";
      ipv4Gateway = "203.0.113.1";
      ipv6 = "2001:db8::2/64";
      ipv6Gateway = "fe80::1";
    };
    cluster = {
      repository = "https://example.org/suveraen.git";
      path = "./clusters/example";
      nodeIP = [
        "203.0.113.10"
        "2001:db8::2"
      ];
      sopsAgeKeyFile = "/run/secrets/flux-age-key";
    };
    alerts.ntfyUrlFile = "/run/secrets/ntfy-url";
    upgrade.flake = "github:example/example";
  };
}
