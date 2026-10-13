# Builds the modules with stand-in values; nothing here points at a real machine.
{
  nixpkgs.hostPlatform = "x86_64-linux";
  networking.hostName = "example";
  networking.hostId = "0400bdef";
  system.stateVersion = "26.05";

  suveraen = {
    domain = "example.org";
    adminKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN9QsUU2i+9+MwdvtxOsPVD6L24UHYJXVJRI2oe+9oHP example"
    ];
    storage = {
      systemDisks = [
        "/dev/disk/by-id/nvme-example-0"
        "/dev/disk/by-id/nvme-example-1"
      ];
      bulkDisks = [
        "/dev/disk/by-id/ata-example-0"
        "/dev/disk/by-id/ata-example-1"
      ];
    };
    network = {
      ipv6 = "2001:db8::2/64";
      ipv6Gateway = "fe80::1";
    };
    identity.enable = true;
    backup = {
      enable = true;
      repo = "ssh://backup@backup.example.org:23/./example";
      knownHosts = "[backup.example.org]:23 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN9QsUU2i+9+MwdvtxOsPVD6L24UHYJXVJRI2oe+9oHP";
      passphraseFile = "/run/secrets/backup-passphrase";
      sshKeyFile = "/run/secrets/backup-ssh-key";
    };
    alerts.ntfyUrlFile = "/run/secrets/ntfy-url";
    upgrade.flake = "github:example/example";
  };
}
