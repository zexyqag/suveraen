{ config, lib, ... }:
let
  cfg = config.suveraen.unlock;
in
{
  options.suveraen.unlock = {
    port = lib.mkOption {
      type = lib.types.port;
      default = 2222;
      description = "Port of the SSH server that runs during boot to take the disk passphrase.";
    };

    hostKey = lib.mkOption {
      type = lib.types.str;
      default = "/etc/secrets/initrd/ssh_host_ed25519_key";
      description = ''
        Host key of the boot-time SSH server. It has to exist before installing.
        It is stored unencrypted on the boot partition, so it must not be the system's own host key.
      '';
    };
  };

  config = {
    boot.initrd.network = {
      enable = true;
      ssh = {
        enable = true;
        inherit (cfg) port;
        hostKeys = [ cfg.hostKey ];
        authorizedKeys = config.suveraen.adminKeys;
      };
    };

    # Logging in asks for the passphrase straight away.
    boot.initrd.systemd.users.root.shell = "/bin/systemd-tty-ask-password-agent";
  };
}
