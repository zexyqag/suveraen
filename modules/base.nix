{ config, lib, ... }:
let
  cfg = config.suveraen;
in
{
  options.suveraen = {
    domain = lib.mkOption {
      type = lib.types.str;
      example = "example.org";
      description = "Base domain. Services live on its subdomains.";
    };

    adminKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "SSH public keys that may log in as root and unlock the disks at boot.";
    };
  };

  config = {
    assertions = [
      {
        assertion = cfg.adminKeys != [ ];
        message = "suveraen.adminKeys needs at least one SSH public key.";
      }
    ];

    users.mutableUsers = false;
    users.users.root.openssh.authorizedKeys.keys = cfg.adminKeys;

    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "prohibit-password";
      };
    };

    networking.nftables.enable = true;

    nix = {
      channel.enable = false;
      settings.experimental-features = [
        "nix-command"
        "flakes"
      ];
      gc = {
        automatic = true;
        dates = "weekly";
        options = "--delete-older-than 30d";
      };
      optimise.automatic = true;
    };

    zramSwap.enable = true;
    time.timeZone = lib.mkDefault "UTC";
    services.journald.extraConfig = "SystemMaxUse=2G";
  };
}
