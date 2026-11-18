# Each cluster server keeps its own metrics, on loopback behind a password: VictoriaMetrics scrapes and stores what the
# jobs modules declare keep of their targets, on this host alone, and vmalert evaluates the rules modules declare on
# them and sends nothing. The servers' checks read what those rules find (suveraen-metrics check, host-checks/metrics.jq)
# and alert on it, and when the rules can't be checked.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.suveraen.metrics;
  yaml = pkgs.formats.yaml { };

  user = "metrics";
  passwordFile = "/var/lib/suveraen-metrics/password";
  # node_exporter's basic auth, by the password's hash, which the password unit writes at every start.
  nodeWebConfig = "/run/suveraen-metrics/node-web.yml";
  storePort = 8428;
  rulesPort = 8880;
  nodePort = config.services.prometheus.exporters.node.port;

  inherit (import ./duration.nix lib) seconds;
  duration = (import ./duration.nix lib).type;

  # The labels the metrics' own rules key by, which name no person, host or address.
  ownLabels = [
    "job"
    "family"
  ];

  # The family a selector keeps, as node_systemd_unit_state of node_systemd_unit_state{state="failed"}.
  family = selector: lib.head (builtins.match "([a-zA-Z_:][a-zA-Z0-9_:]*).*" selector);
  # Each family a job keeps, with the job.
  kept = lib.concatLists (
    lib.mapAttrsToList (job: j: map (s: lib.nameValuePair (family s) job) j.keep) cfg.jobs
  );
  sources = lib.foldl' (
    acc: f: acc // { ${f.name} = (acc.${f.name} or [ ]) ++ [ f.value ]; }
  ) { } kept;
  # What a rule reads: the families it names and where each comes from, so that a source or a family that is lost
  # holds its findings.
  inputs = r: lib.unique (lib.concatMap (f: sources.${f} or [ ] ++ [ f ]) r.reads);
  read = lib.unique (lib.concatMap (r: r.reads) (lib.attrValues cfg.rules));
  # The labels a rule may print, and key by: the metrics' own, and those the sources of what it reads say may be.
  printable =
    r:
    ownLabels
    ++ lib.concatMap (s: cfg.jobs.${s}.labels) (
      lib.unique (lib.concatMap (f: sources.${f} or [ ]) r.reads)
    );
  everyLabel = lib.unique (ownLabels ++ lib.concatMap (j: j.labels) (lib.attrValues cfg.jobs));

  # What vmalert may print of an alert: one of the labels given, or its value, as is or made readable.
  printed =
    labels: text:
    lib.all (
      part:
      if lib.isList part then
        builtins.match "[[:space:]]*(\\$labels\\.(${lib.concatStringsSep "|" labels})|\\$value([[:space:]]*\\|[[:space:]]*(humanize|humanize1024|humanizePercentage|humanizeDuration))?)[[:space:]]*" (
          lib.head part
        ) != null
      else
        !lib.hasInfix "{{" part && !lib.hasInfix "}}" part
    ) (builtins.split "\\{\\{([^}]*)}}" text);
  plain = text: !lib.hasInfix "{{" text && !lib.hasInfix "}}" text;

  alerting = name: r: {
    alert = name;
    inherit (r) expr for;
    # A condition that stops for an evaluation or two, as when a scrape fails, isn't taken for its end.
    keep_firing_for = cfg.holdFor;
    labels.priority = toString r.priority;
    annotations = {
      inherit (r) title cleared detail;
    }
    // lib.optionalAttrs (r.key != [ ]) {
      key = lib.concatMapStringsSep "/" (label: "{{ $labels.${label} }}") r.key;
    }
    // lib.optionalAttrs (r.inputs != [ ]) { inputs = lib.concatStringsSep " " r.inputs; }
    // lib.optionalAttrs (r.lost != null) { inherit (r) lost; };
  };

  jobs = lib.attrNames cfg.jobs;
  names = lib.attrNames cfg.rules ++ lib.attrNames own;
  # The rules on the metrics themselves. One whose alert names what is lost, pending or firing, holds the findings of
  # every rule reading that, as they can't be told.
  own = {
    "target down" = {
      expr = "max by (job) (${
        lib.concatMapStringsSep " or " (job: ''up{job="${job}"} == 0 or absent(up{job="${job}"})'') jobs
      })";
      for = cfg.holdFor;
      priority = 4;
      title = "metric target down";
      cleared = "metric targets up again";
      detail = "no answer to the scrape";
      key = [ "job" ];
      inputs = [ ];
      lost = "{{ $labels.job }}";
    };
  }
  // lib.optionalAttrs (read != [ ]) {
    # A family a rule reads that its source no longer gives, as after a rename, would keep the rule from ever firing.
    "inputs missing" = {
      expr = lib.concatMapStringsSep " or " (
        f:
        lib.concatMapStringsSep " or " (
          job: ''(label_set(absent(${f}{job="${job}"}), "family", "${f}") and on() up{job="${job}"} == 1)''
        ) sources.${f} or [ ]
      ) read;
      # Longer than a source takes to give every family once it starts.
      for = "30m";
      priority = 4;
      title = "metric inputs missing";
      cleared = "metric inputs back";
      detail = "absent while its source answers, so no rule reading it can fire";
      key = [ "family" ];
      inputs = lib.unique (lib.concatMap (f: sources.${f} or [ ]) read);
      lost = "{{ $labels.family }}";
    };
  };

  rules = {
    groups = [
      {
        name = "metrics";
        inherit (cfg) interval;
        rules = [
          # Always firing, so one not freshly evaluated says no rule is.
          {
            alert = "Watchdog";
            expr = "vector(1)";
          }
        ]
        ++ lib.mapAttrsToList alerting own
        ++ lib.mapAttrsToList (
          name: r:
          alerting name (
            r
            // {
              inputs = inputs r;
              lost = null;
            }
          )
        ) cfg.rules;
      }
    ];
  };

  # suveraen-metrics check: what the rules found, as the servers' checks judge it, read with the password from its
  # root-only file. curl takes it on stdin, out of the process list.
  command = pkgs.writeShellApplication {
    name = "suveraen-metrics";
    runtimeInputs = [
      pkgs.curl
      pkgs.jq
    ];
    text = ''
      if [ "''${1:-}" != check ]; then
        echo "usage: suveraen-metrics check" >&2
        exit 2
      fi
      printf 'user = "${user}:%s"\n' "$(< ${passwordFile})" \
        | curl --config - -fsS --max-time 20 http://127.0.0.1:${toString rulesPort}/api/v1/rules \
        | jq '
          # vmalert gives times in its own zone, to the nanosecond.
          def epoch:
            capture("^(?<at>[0-9-]+T[0-9:]+)(\\.[0-9]+)?(?<zone>Z|[+-][0-9]{2}:[0-9]{2})$") as $t
            | ($t.at + "Z" | fromdateiso8601)
              - (if $t.zone == "Z" then 0
                 else ($t.zone[1:3] | tonumber) * 3600 + ($t.zone[4:6] | tonumber) * 60
                   | if $t.zone[0:1] == "-" then -. else . end
                 end);
          {checked: (now | floor), interval: ${toString (seconds cfg.interval)},
           rules: [.data.groups[].rules[] | select(.type == "alerting")
             | {name, health, evaluated: (.lastEvaluation | epoch), annotations,
                alerts: [.alerts[]? | {state, priority: .labels.priority, annotations}]}]}'
    '';
  };

  # Units that alert when they fail, and their alerts, which a failed unit doesn't alert again for.
  alerted = "(${
    lib.concatMapStringsSep "|" lib.escapeRegex (lib.unique config.suveraen.alerts.units)
  })\\.service|alert@.+";
  # A unit by its name, but for an instance's, such as a socket's connection, which could name an address.
  unit = series: ''label_replace(${series}, "name", "$1@", "name", "([^@]+)@.*")'';

  # Every daemon here reaches nothing beyond the host's loopback.
  confined = {
    IPAddressDeny = "any";
    IPAddressAllow = "localhost";
  };
  password = [ "suveraen-metrics-password.service" ];
in
{
  options.suveraen.metrics = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.suveraen.cluster.enable;
      defaultText = lib.literalExpression "config.suveraen.cluster.enable";
      description = "Keep this server's metrics, on loopback alone, and judge the rules on them in its checks.";
    };

    retention = lib.mkOption {
      type = lib.types.strMatching "[1-9][0-9]*[dwy]";
      default = "14d";
      description = ''
        How long metrics are kept. VictoriaMetrics drops them a whole month at a time, on the first day of a month, so
        they last up to about a month longer. They are never backed up or snapshotted.
      '';
    };

    quota = lib.mkOption {
      type = lib.types.str;
      default = "8G";
      description = "Most space the metrics may take, on a dataset of their own outside the snapshots.";
    };

    interval = lib.mkOption {
      type = duration;
      default = "1m";
      description = "How often each target is scraped and the rules are evaluated.";
    };

    holdFor = lib.mkOption {
      type = duration;
      default = "15m";
      description = ''
        How long a rule's condition holds before it alerts, unless the rule says otherwise, and how long an alert
        stands after its condition last held.
      '';
    };

    jobs = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            scrape = lib.mkOption {
              type = yaml.type;
              description = ''
                Where its target is and how it is asked, as a scrape config of VictoriaMetrics', but for the job's name,
                the interval and what is kept. Its target is on loopback: nothing else is reached.
              '';
            };
            keep = lib.mkOption {
              type = lib.types.nonEmptyListOf lib.types.str;
              example = [ ''node_systemd_unit_state{state="failed"}'' ];
              description = "The series it keeps, by selectors; every family they name is one a rule reads.";
            };
            labels = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = ''
                The labels of what it keeps that a rule reading it may print and key its findings by, none of which
                names a person, a host or an address.
              '';
            };
          };
        }
      );
      default = { };
      description = "What VictoriaMetrics scrapes, by job, each declared by the module whose rules read it.";
    };

    rules = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            expr = lib.mkOption {
              type = lib.types.str;
              description = "A MetricsQL expression: each series it gives is an alert.";
            };
            for = lib.mkOption {
              type = duration;
              default = cfg.holdFor;
              defaultText = lib.literalExpression "config.suveraen.metrics.holdFor";
              description = "How long it holds before it alerts.";
            };
            priority = lib.mkOption {
              type = lib.types.ints.between 1 5;
              default = 4;
              description = "The alert's priority.";
            };
            title = lib.mkOption {
              type = lib.types.nonEmptyStr;
              description = "The title it alerts under.";
            };
            cleared = lib.mkOption {
              type = lib.types.nonEmptyStr;
              description = "The title it alerts under once it stops.";
            };
            detail = lib.mkOption {
              type = lib.types.nonEmptyStr;
              description = ''
                What it found, a template of vmalert's that prints nothing but the value, as `{{ $value }}` or through
                humanize, humanize1024, humanizePercentage or humanizeDuration, and the labels it may key by.
              '';
            };
            key = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "The labels that tell its alerts apart, which name each one's finding after the rule's name.";
            };
            reads = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "Every family its expression reads.";
            };
          };
        }
      );
      default = { };
      description = ''
        The rules on this server's metrics, by name, each declared by the module that owns what it judges. A rule's
        finding is "metric <name>", followed by its key's labels joined by a slash.
      '';
    };

    rulesFile = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      internal = true;
      # The very file vmalert's module makes of them.
      default = yaml.generate "rules.yml" rules;
      description = "Every rule, as vmalert reads them.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions =
      let
        # The rules that don't do as the message says, by name.
        refused = ok: lib.attrNames (lib.filterAttrs (name: r: !ok name r) cfg.rules);
        check = ok: message: {
          assertion = refused ok == [ ];
          message = "${message}: ${lib.concatStringsSep ", " (refused ok)}.";
        };
      in
      [
        {
          assertion = config.suveraen.cluster.enable;
          message = "suveraen.metrics needs suveraen.cluster.enable: the servers' checks judge its rules.";
        }
        # Each is a word or more of its findings' keys; Watchdog is the rules' own, and so is rules.
        (check
          (
            name: _:
            builtins.match "[A-Za-z][A-Za-z0-9 ]*[A-Za-z0-9]" name != null
            && !lib.elem name [
              "Watchdog"
              "rules"
            ]
            && !own ? ${name}
            && !lib.any (other: lib.hasPrefix "${name} " other || lib.hasPrefix "${other} " name) names
          )
          "suveraen.metrics.rules are named in letters, digits and spaces, apart from the metrics' own, and none begins another as a word"
        )
        (check (_: r: printed (printable r) r.detail && plain r.title && plain r.cleared)
          "suveraen.metrics.rules print nothing but their value and the labels the sources of what they read may print (${lib.concatStringsSep ", " everyLabel}), and in their detail alone"
        )
        (check (
          _: r: lib.all (label: lib.elem label (printable r)) r.key
        ) "suveraen.metrics.rules are keyed only by labels the sources of what they read may print")
        (check (
          _: r: lib.all (f: sources ? ${f}) r.reads
        ) "suveraen.metrics.rules read only families a job keeps")
        {
          assertion = lib.all (f: lib.elem f read) (lib.attrNames sources);
          message = "suveraen.metrics.jobs keep only families a rule reads: ${
            lib.concatStringsSep ", " (lib.filter (f: !(lib.elem f read)) (lib.attrNames sources))
          }.";
        }
      ];

    suveraen.metrics.jobs.node.scrape = {
      static_configs = [ { targets = [ "127.0.0.1:${toString nodePort}" ]; } ];
      basic_auth = {
        username = user;
        # VictoriaMetrics' own credential, which it fills in when it reads this.
        password_file = "%{CREDENTIALS_DIRECTORY}/basic_auth_password";
      };
    };

    systemd.services.suveraen-metrics-password = {
      description = "Make the password of this server's metrics, once";
      wantedBy = [ "multi-user.target" ];
      before = [
        "victoriametrics.service"
        "vmalert.service"
        "prometheus-node-exporter.service"
      ];
      path = [
        pkgs.coreutils
        pkgs.mkpasswd
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        PrivateNetwork = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        StateDirectory = "suveraen-metrics";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "suveraen-metrics";
        RuntimeDirectoryMode = "0700";
        UMask = "0077";
      };
      script = ''
        if [ ! -s ${passwordFile} ]; then
          head -c 32 /dev/urandom | base32 -w 0 | tr -d = >${passwordFile}.new
          mv ${passwordFile}.new ${passwordFile}
        fi
        printf 'basic_auth_users:\n  ${user}: %s\n' "$(mkpasswd -m bcrypt -s <${passwordFile})" >${nodeWebConfig}
      '';
    };

    # Outside the snapshots, and never backed up: gone once their retention is up.
    suveraen.storage.unsnapshotted.metrics = {
      path = "/var/lib/private/${config.services.victoriametrics.stateDir}";
      inherit (cfg) quota;
    };

    services.victoriametrics = {
      enable = true;
      listenAddress = "127.0.0.1:${toString storePort}";
      retentionPeriod = cfg.retention;
      basicAuthUsername = user;
      basicAuthPasswordFile = passwordFile;
      prometheusConfig = {
        global.scrape_interval = cfg.interval;
        scrape_configs = lib.mapAttrsToList (
          job: j:
          j.scrape
          // {
            job_name = job;
            metric_relabel_configs = [
              {
                action = "keep";
                "if" = j.keep;
              }
            ];
          }
        ) cfg.jobs;
      };
    };
    systemd.services.victoriametrics = {
      wants = password;
      after = password;
      serviceConfig = confined // {
        MemoryMax = "1G";
      };
    };

    services.vmalert.instances."" = {
      enable = true;
      inherit rules;
      settings = {
        "datasource.url" = "http://127.0.0.1:${toString storePort}";
        "datasource.basicAuth.username" = user;
        "datasource.basicAuth.passwordFile" = "%d/password";
        "httpListenAddr" = "127.0.0.1:${toString rulesPort}";
        "httpAuth.username" = user;
        "httpAuth.password" = "file://%d/password";
        # The servers' checks read what fires, and alone send it.
        "notifier.blackhole" = true;
        "evaluationInterval" = "${toString (seconds cfg.interval)}s";
      };
    };
    systemd.services.vmalert = {
      wants = password ++ [ "victoriametrics.service" ];
      after = password ++ [ "victoriametrics.service" ];
      serviceConfig = confined // {
        LoadCredential = [ "password:${passwordFile}" ];
        MemoryMax = "256M";
        # As the store's module has it.
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        PrivateDevices = true;
        PrivateUsers = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
        ];
      };
    };

    # Nothing but what a rule reads: these collectors for the node's own rules below.
    services.prometheus.exporters.node = {
      enable = true;
      listenAddress = "127.0.0.1";
      enabledCollectors = [
        "systemd"
        "meminfo"
        "pressure"
        "vmstat"
        "conntrack"
      ];
      # Off already; the module confines the exporter further for these.
      disabledCollectors = [
        "netdev"
        "timex"
      ];
      extraFlags = [
        "--collector.disable-defaults"
        "--collector.systemd.enable-restarts-metrics"
        "--web.config.file=%d/web.yml"
      ];
    };
    systemd.services.prometheus-node-exporter = {
      wants = password;
      after = password;
      serviceConfig = confined // {
        LoadCredential = [ "web.yml:${nodeWebConfig}" ];
        MemoryMax = "128M";
      };
    };

    # The node's own: units that fail without alerting by themselves, or keep restarting, memory running out, the
    # kernel killing for it, and the connection table filling, which drops connections for everyone.
    suveraen.metrics.jobs.node.labels = [ "name" ];
    suveraen.metrics.jobs.node.keep = [
      ''node_systemd_unit_state{state="failed"}''
      "node_systemd_service_restart_total"
      "node_memory_MemAvailable_bytes"
      "node_memory_MemTotal_bytes"
      "node_pressure_memory_stalled_seconds_total"
      "node_vmstat_oom_kill"
      "node_nf_conntrack_entries"
      "node_nf_conntrack_entries_limit"
    ];
    suveraen.metrics.rules = {
      "units failed" = {
        expr = "max by (name) (${unit ''node_systemd_unit_state{state="failed", name!~`${alerted}`}''}) == 1";
        title = "units failed";
        cleared = "units no longer failed";
        detail = "in the failed state";
        key = [ "name" ];
        reads = [ "node_systemd_unit_state" ];
      };
      "units restarting" = {
        expr = "max by (name) (${unit "increase(node_systemd_service_restart_total[1h])"}) >= 3";
        title = "units restarting";
        cleared = "units no longer restarting";
        detail = "restarted {{ $value | humanize }} times in the last hour";
        key = [ "name" ];
        reads = [ "node_systemd_service_restart_total" ];
      };
      "memory low" = {
        expr = "node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.1";
        title = "memory low";
        cleared = "memory available again";
        detail = "{{ $value | humanizePercentage }} of memory available";
        reads = [
          "node_memory_MemAvailable_bytes"
          "node_memory_MemTotal_bytes"
        ];
      };
      "memory stalled" = {
        expr = "rate(node_pressure_memory_stalled_seconds_total[15m]) > 0.01";
        title = "memory stalled";
        cleared = "memory no longer stalled";
        detail = "every task waited on memory {{ $value | humanizePercentage }} of the last 15 minutes";
        reads = [ "node_pressure_memory_stalled_seconds_total" ];
      };
      "OOM kills" = {
        expr = "increase(node_vmstat_oom_kill[1h]) > 0";
        title = "OOM kills";
        cleared = "no more OOM kills";
        detail = "the kernel killed {{ $value | humanize }} for want of memory in the last hour";
        reads = [ "node_vmstat_oom_kill" ];
      };
      "connection table filling" = {
        expr = "node_nf_conntrack_entries / node_nf_conntrack_entries_limit > 0.75";
        title = "connection table filling";
        cleared = "connection table has room again";
        detail = "{{ $value | humanizePercentage }} of the connection table in use";
        reads = [
          "node_nf_conntrack_entries"
          "node_nf_conntrack_entries_limit"
        ];
      };
    };

    suveraen.checks = {
      families.metrics = ./host-checks/metrics.jq;
      told.metrics = { inherit command; };
    };

    environment.systemPackages = [ command ];
  };
}
