# Builds a nameserver of its own (a small VM) with stand-in values; nothing here points at a real machine.
{ modulesPath, ... }:
{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ./dns-example.nix
  ];

  nixpkgs.hostPlatform = "x86_64-linux";
  networking.hostName = "example-ns";
  networking.hostId = "7d3a51c2";
  system.stateVersion = "26.05";

  suveraen = {
    adminKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN9QsUU2i+9+MwdvtxOsPVD6L24UHYJXVJRI2oe+9oHP example"
    ];
    storage = {
      systemDisks = [ "/dev/vda" ];
      encrypted = false;
      reserve = "1G";
      arcMax = 128 * 1024 * 1024;
    };
    network = {
      ipv4 = "203.0.113.30/24";
      ipv4Gateway = "203.0.113.1";
      ipv6 = "2001:db8:3::1/64";
      ipv6Gateway = "fe80::1";
    };
    dns.self = "example-ns";
    alerts = {
      urlFile = "/run/secrets/alerts-url";
      tokenFile = "/run/secrets/alerts-token";
      smart = false;
      heartbeat = {
        url = "https://status.example.org/api/v1/endpoints/servers_example-ns/external";
        tokenFile = "/run/secrets/heartbeat-token";
      };
    };
    source.repository = "https://example.org/suveraen.git";
  };
}
