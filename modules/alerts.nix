{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.suveraen.alerts;

  alert = pkgs.writeShellApplication {
    name = "suveraen-alert";
    runtimeInputs = [ pkgs.curl ];
    text = ''
      title=$1
      message=''${2:-$1}
      curl -fsS --retry 5 --retry-all-errors \
        -H "Title: ${config.networking.hostName}: $title" \
        --data-binary "$message" \
        "$(cat ${lib.escapeShellArg cfg.ntfyUrlFile})"
    '';
  };

  smartAlert = pkgs.writeShellScript "smart-alert" ''
    exec ${lib.getExe alert} "$SMARTD_SUBJECT" "$SMARTD_FULLMESSAGE"
  '';

  mdadmAlert = pkgs.writeShellScript "mdadm-alert" ''
    case "$1" in
      Fail|FailSpare|DegradedArray|DeviceDisappeared|SparesMissing|TestMessage)
        exec ${lib.getExe alert} "RAID $1 on $2" "mdadm: $*" ;;
    esac
  '';
in
{
  options.suveraen.alerts = {
    ntfyUrlFile = lib.mkOption {
      type = lib.types.str;
      description = ''
        File holding the ntfy topic URL that alerts are posted to, e.g. https://ntfy.sh/<long random topic>.
        Anyone who knows the URL can read the alerts, so keep it secret.
      '';
    };

    units = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "systemd services that send an alert when they fail.";
    };

    command = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = alert;
      description = "`suveraen-alert <title> [message]`, for other modules to send alerts.";
    };
  };

  config = {
    environment.systemPackages = [ alert ];

    systemd.services = {
      "alert@" = {
        description = "Alert that %i failed";
        serviceConfig.Type = "oneshot";
        scriptArgs = "%i";
        script = ''
          ${lib.getExe alert} "$1 failed" "$(${config.systemd.package}/bin/journalctl -u "$1" -n 30 -o cat --no-pager)"
        '';
      };
    }
    // lib.genAttrs cfg.units (_: {
      onFailure = [ "alert@%n.service" ];
    });

    services.smartd = {
      enable = true;
      notifications.wall.enable = false;
      # Short self-test daily, long one on Saturdays.
      defaults.autodetected = "-a -o on -s (S/../.././02|L/../../6/03) -n standby,q -m <nomailer> -M exec ${smartAlert}";
    };

    boot.swraid.mdadmConf = "PROGRAM ${mdadmAlert}";
  };
}
