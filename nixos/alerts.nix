{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.suveraen.alerts;

  # Feeds curl the token on stdin so it never shows up in the process list.
  authorized =
    tokenFile:
    if tokenFile == null then
      "curl"
    else
      ''printf 'header = "Authorization: Bearer %s"\n' "$(< ${lib.escapeShellArg tokenFile})" | curl --config -'';

  alert = pkgs.writeShellApplication {
    name = "suveraen-alert";
    runtimeInputs = [ pkgs.curl ];
    text = ''
      title=$1
      message=''${2:-$1}
      ${authorized cfg.tokenFile} -fsS --retry 5 --retry-all-errors \
        -H "Title: ${config.networking.hostName}: $title" \
        --data-binary "$message" \
        ${lib.escapeShellArg cfg.url}
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
    url = lib.mkOption {
      type = lib.types.str;
      example = "https://alerts.example.org/ops";
      description = "ntfy topic URL that alerts are posted to.";
    };

    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "File holding an ntfy access token that may publish to the topic.";
    };

    smart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Watch the disks' SMART health. Virtual machines have no SMART data.";
    };

    heartbeat = {
      url = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "https://status.example.org/api/v1/endpoints/servers_example/external";
        description = "Gatus external endpoint this host reports to, so the watcher notices when the reports stop.";
      };

      tokenFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "File holding the external endpoint's token.";
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "5min";
        description = "How often the host reports in.";
      };
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

  config = lib.mkMerge [
    {
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

      boot.swraid.mdadmConf = "PROGRAM ${mdadmAlert}";
    }

    (lib.mkIf cfg.smart {
      services.smartd = {
        enable = true;
        notifications.wall.enable = false;
        # Short self-test daily, long one on Saturdays.
        defaults.autodetected = "-a -o on -s (S/../.././02|L/../../6/03) -n standby,q -m <nomailer> -M exec ${smartAlert}";
      };
    })

    (lib.mkIf (cfg.heartbeat.url != null) {
      systemd.services.heartbeat = {
        description = "Tell the watcher this host is alive";
        path = [ pkgs.curl ];
        serviceConfig.Type = "oneshot";
        script = ''
          ${authorized cfg.heartbeat.tokenFile} -fsS --max-time 30 -X POST \
            ${lib.escapeShellArg "${cfg.heartbeat.url}?success=true"}
        '';
      };
      systemd.timers.heartbeat = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "1min";
          OnUnitActiveSec = cfg.heartbeat.interval;
        };
      };
    })
  ];
}
