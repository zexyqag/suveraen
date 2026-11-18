{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.suveraen.alerts;
  undelivered = "/var/lib/suveraen-alert/undelivered";

  # Feeds curl the token on stdin so it never shows up in the process list.
  authorized =
    tokenFile:
    ''printf 'header = "Authorization: Bearer %s"\n' "$(< ${lib.escapeShellArg tokenFile})" | curl --config -'';

  alert = pkgs.writeShellApplication {
    name = "suveraen-alert";
    runtimeInputs = [
      pkgs.curl
      pkgs.glibc.bin
    ];
    text = ''
      title=$1
      # ntfy turns bodies over 4 KB, or invalid UTF-8, into attachments; keep the end of long logs as plain text.
      # iconv -c drops what isn't UTF-8 (such as a character cut in half) but still exits 1.
      message=$(printf '%s' "''${2:-$1}" | tail -c 3800 | { iconv -c -f utf-8 -t utf-8 || true; })
      priority=''${3:-4}

      # send <url file> <token file>; the token goes to curl on stdin, out of the process list.
      send() {
        printf 'header = "Authorization: Bearer %s"\n' "$(< "$2")" | curl --config - -fsS \
          --connect-timeout 10 --max-time 30 \
          --retry 10 --retry-all-errors --retry-max-time ${toString cfg.retrySeconds} \
          -H "Title: ${config.networking.hostName}: $title" -H "Priority: $priority" \
          --data-binary "$message" "$(< "$1")"
      }

      # Remember an alert that got nowhere, so the heartbeat can tell the watcher the alert path is broken.
      if send ${
        lib.escapeShellArgs [
          cfg.urlFile
          cfg.tokenFile
        ]
      }${
        lib.optionalString (cfg.fallback.urlFile != null)
          " || send ${
             lib.escapeShellArgs [
               cfg.fallback.urlFile
               cfg.fallback.tokenFile
             ]
           }"
      }; then
        rm -f ${undelivered}
      else
        mkdir -p "$(dirname ${undelivered})"
        date > ${undelivered}
        exit 1
      fi
    '';
  };

  smartAlert = pkgs.writeShellScript "smart-alert" ''
    exec ${lib.getExe alert} "$SMARTD_SUBJECT" "$SMARTD_FULLMESSAGE" 5
  '';

  mdadmAlert = pkgs.writeShellScript "mdadm-alert" ''
    case "$1" in
      Fail|FailSpare|DegradedArray|DeviceDisappeared|SparesMissing|TestMessage)
        exec ${lib.getExe alert} "RAID $1 on $2" "mdadm: $*" 5 ;;
    esac
  '';

in
{
  options.suveraen.alerts = {
    urlFile = lib.mkOption {
      type = lib.types.str;
      description = ''
        File holding the ntfy topic URL alerts are posted to. The topic name is a secret:
        iPhones are woken through ntfy.sh on a hash of it, so anyone who knows it could send them fake alerts.
      '';
    };

    tokenFile = lib.mkOption {
      type = lib.types.str;
      description = "File holding an ntfy access token that may publish to the topic.";
    };

    fallback = {
      urlFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "File holding a second ntfy topic URL, tried when the first can't be reached, so a dead watcher doesn't silence alerts. Best on another machine. The heartbeat also says there when the watcher's ntfy stops answering.";
      };

      tokenFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "File holding a token that may publish to the second topic.";
      };
    };

    retrySeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = "How long to keep retrying a channel, enough to ride out the watcher's own reboot.";
    };

    probeTopic = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9_-]+";
      default = "probe";
      description = ''
        The topic, beside the alerts' on the first channel's ntfy, that a host with a heartbeat publishes to once a day
        as an alert would, which no phone follows.
      '';
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
        description = "File holding this host's external endpoint token.";
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "5min";
        description = "How often the host reports in.";
      };

      stamps = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              path = lib.mkOption {
                type = lib.types.str;
                description = "File whose time of last change says when the job last ran to its end.";
              };
              maxAge = lib.mkOption {
                type = lib.types.ints.positive;
                description = "Seconds it may get old.";
              };
            };
          }
        );
        default = { };
        description = ''
          Jobs the host reports on with its heartbeat, by name: while one's stamp is older than its maxAge, the report
          fails, and the watcher raises an alert; the host's journal says "<name> stale". A stamp counts from no earlier
          than the host's first report since it booted, so a long wait for the disk passphrase, or to power off, isn't
          taken for a stop.
        '';
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
      description = "`suveraen-alert <title> [message] [priority 1-5]`, for other modules to send alerts.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = (cfg.fallback.urlFile == null) == (cfg.fallback.tokenFile == null);
          message = "suveraen.alerts.fallback.urlFile and tokenFile go together.";
        }
        {
          assertion = (cfg.heartbeat.url == null) == (cfg.heartbeat.tokenFile == null);
          message = "suveraen.alerts.heartbeat.url and tokenFile go together.";
        }
      ];

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
        # Short self-test daily, long one on Saturdays; repeat a warning daily while it lasts.
        defaults.autodetected = "-a -o on -s (S/../.././02|L/../../6/03) -n standby,q -m <nomailer> -M daily -M exec ${smartAlert}";
      };
    })

    (lib.mkIf (cfg.heartbeat.url != null) {
      systemd.services.heartbeat = {
        description = "Tell the watcher this host is alive";
        path = [ pkgs.curl ];
        serviceConfig = {
          Type = "oneshot";
          RuntimeDirectory = "heartbeat";
          RuntimeDirectoryPreserve = true;
        };
        script = ''
          misses=/run/heartbeat/misses
          # The first report since boot, which no stamp counts from before.
          [ -e /run/heartbeat/booted ] || date +%s >/run/heartbeat/booted
          booted=$(< /run/heartbeat/booted)
          now=$(date +%s)
          errors=()
          if [ -e ${undelivered} ]; then
            errors+=("alerts not delivered")
            # No alert may come to clear it.
            if [ $(( now - $(stat -c %Y ${undelivered}) )) -gt 3600 ]; then systemctl start --no-block alert-probe; fi
          fi
          ${lib.concatStrings (
            lib.mapAttrsToList (name: stamp: ''
              at=$(stat -c %Y ${lib.escapeShellArg stamp.path} 2>/dev/null || echo 0)
              if [ $(( now - (at > booted ? at : booted) )) -gt ${toString stamp.maxAge} ]; then
                errors+=(${lib.escapeShellArg "${name} stale"})
              fi
            '') cfg.heartbeat.stamps
          )}
          if [ ''${#errors[@]} = 0 ]; then
            report=(--data-urlencode success=true)
          else
            # Why goes in this journal alone: the watcher's status page is public.
            printf -v error '%s, ' "''${errors[@]}"
            echo "Reported unhealthy: ''${error%, }"
            report=(--data-urlencode success=false)
          fi
          if ${authorized cfg.heartbeat.tokenFile} -fsS --connect-timeout 10 --max-time 30 -X POST -G "''${report[@]}" \
            ${lib.escapeShellArg cfg.heartbeat.url}; then
            echo 0 > "$misses"
          ${lib.optionalString (cfg.fallback.urlFile != null) ''
            # Gatus took it, so the watcher is up, and its ntfy, whose host the topic's URL names, should answer too.
            # Gatus alerts through that ntfy alone.
            url=$(< ${lib.escapeShellArg cfg.urlFile})
            if curl -fsS --connect-timeout 10 --max-time 30 "''${url%/*}/v1/health" | grep -q '"healthy": *true'; then
              # Once it answers again after the alert that it didn't.
              if [ "$(cat /run/heartbeat/ntfy-misses 2>/dev/null || echo 0)" -ge 3 ]; then
                ${lib.getExe alert} "watcher's ntfy answering again" \
                  "The watcher's ntfy answers again: the servers' alerts and Gatus's reach the phone through it." 3
              fi
              echo 0 > /run/heartbeat/ntfy-misses
            else
              n=$(( $(cat /run/heartbeat/ntfy-misses 2>/dev/null || echo 0) + 1 ))
              echo "$n" > /run/heartbeat/ntfy-misses
              echo "The watcher's ntfy didn't answer ($n in a row)."
              # Once, on the third miss in a row; it reaches the second channel.
              if [ "$n" -eq 3 ]; then
                ${lib.getExe alert} "watcher's ntfy not answering" \
                  "The watcher took the heartbeat, but its ntfy didn't answer three times in a row. Neither the servers' alerts nor Gatus's reach the phone through it." 5
              fi
            fi
          ''}
          else
            n=$(( $(cat "$misses" 2>/dev/null || echo 0) + 1 ))
            echo "$n" > "$misses"
            echo "The watcher didn't take the heartbeat ($n in a row)."
            # Fail, and so alert, once: on the third miss in a row.
            [ "$n" -ne 3 ]
          fi
        '';
      };
      systemd.timers.heartbeat = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "1min";
          OnUnitActiveSec = cfg.heartbeat.interval;
          AccuracySec = "1s";
        };
      };

      # The way an alert takes, from this host's token to a topic of the watcher's ntfy, can break unseen while there
      # is nothing to alert, so this goes that way once a day, to a topic no phone follows, and the heartbeat reports
      # it when it gets nowhere, and has it go again hourly until it gets through.
      systemd.services.alert-probe = {
        description = "Publish as an alert would, to a topic no phone follows";
        startAt = "daily";
        path = [ pkgs.curl ];
        serviceConfig.Type = "oneshot";
        script = ''
          if url=$(< ${lib.escapeShellArg cfg.urlFile}) && ${authorized cfg.tokenFile} -fsS --connect-timeout 10 \
            --max-time 30 --retry 10 --retry-all-errors --retry-max-time ${toString cfg.retrySeconds} \
            -H "Title: ${config.networking.hostName}: alerts get through" -H "Priority: 1" \
            --data-binary "Published once a day, the way alerts go." "''${url%/*}/${cfg.probeTopic}"; then
            rm -f ${undelivered}
          else
            echo "The probe got nowhere."
            mkdir -p "$(dirname ${undelivered})"
            date > ${undelivered}
          fi
        '';
      };
      systemd.timers.alert-probe.timerConfig.Persistent = true;

      suveraen.alerts.units = [
        "heartbeat"
        "alert-probe"
      ];
    })
  ];
}
