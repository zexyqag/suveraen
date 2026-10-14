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
    source = {
      repository = "https://example.org/suveraen.git";
      signers = [
        "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIIRVCuHQX9vy2/6+Z12L+Hxgx/+KwH4eEKwiyK/r+ZKrAAAABHNzaDo= example"
      ];
    };
    cluster = {
      enable = true;
      path = "./kubernetes/clusters/example";
      nodeIP = [
        "203.0.113.10"
        "2001:db8::2"
      ];
      sopsAgeKeyFile = "/run/secrets/flux-age-key";
    };
    alerts = {
      urlFile = "/run/secrets/alerts-url";
      tokenFile = "/run/secrets/alerts-token";
      fallback = {
        urlFile = "/run/secrets/fallback-alerts-url";
        tokenFile = "/run/secrets/fallback-alerts-token";
      };
      heartbeat = {
        url = "https://status.example.org/api/v1/endpoints/servers_example/external";
        tokenFile = "/run/secrets/heartbeat-token";
      };
    };
  };
}
