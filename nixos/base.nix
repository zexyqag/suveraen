{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.suveraen;
  calendars = lib.unique (
    lib.concatMap (t: lib.filter (c: c != "") (lib.toList (t.timerConfig.OnCalendar or [ ]))) (
      lib.filter (t: t.enable) (lib.attrValues config.systemd.timers)
    )
  );
in
{
  options.suveraen = {
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

    # A calendar systemd can't parse fails the build: systemd would ignore it, leaving its timer to its other triggers.
    system.checks = lib.optional (calendars != [ ]) (
      pkgs.runCommand "timer-calendars" { nativeBuildInputs = [ config.systemd.package ]; } ''
        systemd-analyze calendar ${lib.escapeShellArgs calendars} >/dev/null
        touch $out
      ''
    );

    zramSwap.enable = true;
    time.timeZone = lib.mkDefault "UTC";
    # Logs hold visitors' and attackers' addresses; two weeks is enough to look into a problem. journald deletes only
    # whole files it has moved on from, by when they began, so it moves on daily.
    services.journald.extraConfig = ''
      SystemMaxUse=2G
      MaxRetentionSec=14day
      MaxFileSec=1day
    '';
  };
}
