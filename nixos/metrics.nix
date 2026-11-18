# Each cluster server keeps its own metrics, on loopback behind a password: VictoriaMetrics scrapes and stores what the
# jobs modules declare keep of their targets, on this host alone, or only what they aggregate of it, and of what the
# writers modules declare measure, and vmalert evaluates the rules modules declare on them and sends nothing. The
# servers' checks read what those rules find (suveraen-metrics check, host-checks/metrics.jq) and alert on it, and when
# the rules can't be checked.
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
    "writer"
    "family"
  ];

  # The node's target reads the files the writers write, each <name>.prom.
  textfiles = "/run/suveraen-metrics-textfiles";
  textfile = name: "${textfiles}/${name}.prom";
  # A writer's file is stale once three of its runs are due.
  staleAfter = 3 * seconds cfg.textfileInterval;

  # What the store reads its targets with, each <name>, readable by root and, through a group of their own, the store.
  credentials = "/run/suveraen-metrics-credentials";
  credentialsGroup = baseNameOf credentials;
  # The units credentials are made after, and again whenever one starts.
  following = lib.unique (lib.concatMap (c: c.after) (lib.attrValues cfg.credentials));

  # The family a selector keeps, as node_systemd_unit_state of node_systemd_unit_state{state="failed"}.
  family = selector: lib.head (builtins.match "([a-zA-Z_:][a-zA-Z0-9_:]*).*" selector);
  # What a job stores: each family it keeps but those it aggregates, and what it makes of those.
  gives =
    j:
    lib.subtractLists (map (a: a.input) (lib.attrValues j.aggregate)) (map family j.keep)
    ++ lib.attrNames j.aggregate;
  # Each family a job stores, with the job.
  kept = lib.concatLists (
    lib.mapAttrsToList (job: j: map (f: lib.nameValuePair f job) (gives j)) cfg.jobs
  );
  keptBy = lib.foldl' (
    acc: f: acc // { ${f.name} = (acc.${f.name} or [ ]) ++ [ f.value ]; }
  ) { } kept;
  # Each family a writer writes, with the writer.
  writtenBy = lib.foldl' (acc: w: acc // lib.genAttrs cfg.textfiles.${w}.families (_: w)) { } (
    lib.attrNames cfg.textfiles
  );
  # Where each family comes from: the jobs that keep it, or its writer and the node's target, which reads its file.
  sources =
    keptBy
    // lib.mapAttrs (_: w: [
      "node"
      w
    ]) writtenBy;
  # What a rule reads: the families it names and where each comes from, so that a source or a family that is lost
  # holds its findings.
  inputs = r: lib.unique (lib.concatMap (f: sources.${f} or [ ] ++ [ f ]) r.reads);
  read = lib.unique (lib.concatMap (r: r.reads) (lib.attrValues cfg.rules));
  # The labels a rule may print, and key by: the metrics' own, and those the sources of what it reads say may be.
  printable =
    r:
    ownLabels
    ++ lib.concatMap (s: (cfg.jobs.${s} or cfg.textfiles.${s}).labels) (
      lib.unique (lib.concatMap (f: sources.${f} or [ ]) r.reads)
    );
  everyLabel = lib.unique (
    ownLabels ++ lib.concatMap (s: s.labels) (lib.attrValues cfg.jobs ++ lib.attrValues cfg.textfiles)
  );
  # What a source gives whenever it answers.
  optional = lib.concatMap (s: s.optional) (lib.attrValues cfg.jobs ++ lib.attrValues cfg.textfiles);
  always = lib.filter (f: !lib.elem f optional) read;

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
      # A label an alert lacks is left out of its key.
      key =
        "{{ $labels.${lib.head r.key} }}"
        + lib.concatMapStrings (label: "{{ with $labels.${label} }}/{{ . }}{{ end }}") (lib.tail r.key);
    }
    // lib.optionalAttrs (r.inputs != [ ]) { inputs = lib.concatStringsSep " " r.inputs; }
    // lib.optionalAttrs (r.lost != null) { inherit (r) lost; };
  };

  # What jobs aggregate as VictoriaMetrics streams it in, under the names rules read; each output keeps the job, which
  # tells its source's target down and missing families.
  aggregated = lib.concatLists (
    lib.mapAttrsToList (
      job: j:
      lib.mapAttrsToList (name: a: {
        match = ''${a.input}{job="${job}"}'';
        inherit (cfg) interval;
        by = [ "job" ] ++ a.by;
        outputs = [ a.output ];
        output_relabel_configs = [
          {
            target_label = "__name__";
            replacement = name;
          }
        ];
      }) j.aggregate
    ) cfg.jobs
  );

  jobs = lib.attrNames cfg.jobs;
  writers = lib.attrNames cfg.textfiles;
  # A source that answers only while this host's cluster does: its alert carries needs="cluster", and stands as it was
  # while the servers' checks can't read the cluster, until they have read it again for holdFor, and once it holds no
  # more (host-checks/metrics.jq).
  needing =
    source: expr: if source.needsCluster then ''label_set(${expr}, "needs", "cluster")'' else expr;
  names = lib.attrNames cfg.rules ++ lib.attrNames own;
  fresh = w: "time() - node_textfile_mtime_seconds{file=\"${textfile w}\"}";
  generated = {
    for = cfg.holdFor;
    priority = 4;
  };
  # The rules on the metrics themselves. One whose alert names what is lost, pending or firing, holds the findings of
  # every rule reading that, as they can't be told.
  own = lib.mapAttrs (_: r: generated // r) (
    {
      "target down" = {
        expr = lib.concatMapStringsSep " or " (
          job: needing cfg.jobs.${job} ''max by (job) (up{job="${job}"} == 0 or absent(up{job="${job}"}))''
        ) jobs;
        title = "metric target down";
        cleared = "metric targets up again";
        detail = "no answer to the scrape";
        key = [ "job" ];
        inputs = [ ];
        lost = "{{ $labels.job }}";
      };
    }
    // lib.optionalAttrs (writers != [ ]) {
      # A writer that failed, timed out or wrote what the node's target can't read keeps its file as it was.
      "input stale" = {
        expr = lib.concatMapStringsSep " or " (
          w:
          needing cfg.textfiles.${w} (
            "(max by (writer) (label_set(${fresh w}, \"writer\", \"${w}\") > ${toString staleAfter}"
            + " or label_set(absent(node_textfile_mtime_seconds{file=\"${textfile w}\"}), \"writer\", \"${w}\"))"
            + " and on() up{job=\"node\"} == 1)"
          )
        ) writers;
        title = "metric input stale";
        cleared = "metric inputs fresh again";
        detail = "not written by its last three runs, or unreadable";
        key = [ "writer" ];
        inputs = [ "node" ];
        lost = "{{ $labels.writer }}";
      };
    }
    // lib.optionalAttrs (always != [ ]) {
      # A family a rule reads that its source no longer gives, as after a rename, would keep the rule from ever firing.
      "inputs missing" = {
        expr = lib.concatMapStringsSep " or " (
          f:
          let
            missing = job: ''label_set(absent(${f}{job="${job}"}), "family", "${f}")'';
          in
          if writtenBy ? ${f} then
            "(${missing "node"} and on() (${fresh writtenBy.${f}} <= ${toString staleAfter}))"
          else
            lib.concatMapStringsSep " or " (
              job: ''(${missing job} and on() up{job="${job}"} == 1)''
            ) keptBy.${f} or [ ]
        ) always;
        # Longer than a source takes to give every family once it starts.
        for = "30m";
        title = "metric inputs missing";
        cleared = "metric inputs back";
        detail = "absent while its source answers, so no rule reading it can fire";
        key = [ "family" ];
        inputs = lib.unique (lib.concatMap (f: sources.${f} or [ ]) always);
        lost = "{{ $labels.family }}";
      };
    }
  );

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
           holdFor: ${toString (seconds cfg.holdFor)},
           rules: [.data.groups[].rules[] | select(.type == "alerting")
             | {name, health, evaluated: (.lastEvaluation | epoch), annotations,
                alerts: [.alerts[]?
                  | {state, stabilizing, priority: .labels.priority, needs: .labels.needs, annotations}]}]}'
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

  # Where the scripts modules declare run: each in turn and within its own timeout, so one that hangs or fails leaves
  # the others' files fresh, and its own as it was; as root, but on a read-only system and reaching nothing beyond
  # loopback.
  scripted =
    scripts:
    confined
    // {
      Type = "oneshot";
      TimeoutStartSec = lib.foldl' (sum: t: sum + t.timeout) 30 (lib.attrValues scripts);
      MemoryMax = "256M";
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      LockPersonality = true;
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
    };
  program =
    kind: name: t:
    lib.getExe (
      pkgs.writeShellApplication {
        name = "metrics-${kind}-${name}";
        runtimeInputs = t.path;
        text = t.script;
      }
    );
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

    textfileInterval = lib.mkOption {
      type = duration;
      default = "5m";
      description = "How often the writers in textfiles run.";
    };

    textfiles = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            script = lib.mkOption {
              type = lib.types.lines;
              description = ''
                A bash script, run by root, that prints what it measures in Prometheus's text format, which becomes the
                file the node's target reads once the script has run to its end.
              '';
            };
            path = lib.mkOption {
              type = lib.types.listOf lib.types.package;
              default = [ ];
              description = "Packages whose programs the script runs.";
            };
            timeout = lib.mkOption {
              type = lib.types.ints.positive;
              default = 60;
              description = "How many seconds it may run.";
            };
            families = lib.mkOption {
              type = lib.types.nonEmptyListOf lib.types.str;
              description = "The families it writes, each one a rule reads.";
            };
            labels = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = ''
                The labels of what it writes that a rule reading it may print and key its findings by, none of which
                names a person, a host or an address.
              '';
            };
            optional = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = ''
                Those of its families that a host may lack, such as one of what is mounted. Any other alerts as missing
                while the script runs without it.
              '';
            };
            needsCluster = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Whether what it reads answers only while this host's cluster does. Its file going stale then stands as
                it was while the servers' checks can't read the cluster, until they have read it again for holdFor, and
                once it is fresh again.
              '';
            };
          };
        }
      );
      default = { };
      description = ''
        What modules measure that no target gives, by name: each a script the metrics' writer runs every
        textfileInterval, in turn and each within its own timeout, as root, but on a read-only system and reaching
        nothing beyond loopback, and whose file the node's target reads. One whose file goes stale alerts, and holds the
        findings of the rules reading it.
      '';
    };

    credentialInterval = lib.mkOption {
      type = duration;
      default = "5m";
      description = "How often the credentials are made again, well within the time any of them lasts.";
    };

    credentials = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              script = lib.mkOption {
                type = lib.types.lines;
                description = ''
                  A bash script, run by root, that prints the credential, which becomes its file once the script has
                  run to its end. If it fails, the last line it prints on stderr goes to the journal; if it runs out of
                  time, that it did.
                '';
              };
              path = lib.mkOption {
                type = lib.types.listOf lib.types.package;
                default = [ ];
                description = "Packages whose programs the script runs.";
              };
              timeout = lib.mkOption {
                type = lib.types.ints.positive;
                default = 60;
                description = "How many seconds it may run.";
              };
              after = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = "The units it is made after, and made again whenever one of them starts.";
              };
              file = lib.mkOption {
                type = lib.types.str;
                readOnly = true;
                internal = true;
                default = "${credentials}/${name}";
                description = "Where the store reads it, as a job's bearer_token_file or tls_config.ca_file.";
              };
            };
          }
        )
      );
      default = { };
      description = ''
        What the store reads targets with, such as a token or a CA, by name, each made by a script: the metrics'
        credentials unit runs them after the units they follow, again whenever one of those starts and every
        credentialInterval, in turn and each within its own timeout, as root, but on a read-only system and reaching
        nothing beyond loopback. A credential's file, which root and the store alone may read, is replaced once its
        script has run to its end, and the store reads it again at each scrape; one whose script fails keeps it as it
        was.
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
              description = ''
                The series it keeps, by selectors; every family they name is one a rule reads, or one it aggregates.
              '';
            };
            relabel = lib.mkOption {
              type = lib.types.listOf yaml.type;
              default = [ ];
              description = "What is done to the series it keeps once kept, as VictoriaMetrics' metric_relabel_configs.";
            };
            aggregate = lib.mkOption {
              type = lib.types.attrsOf (
                lib.types.submodule {
                  options = {
                    input = lib.mkOption {
                      type = lib.types.str;
                      description = "A family it keeps, which is stored only as this.";
                    };
                    by = lib.mkOption {
                      type = lib.types.listOf lib.types.str;
                      description = "The labels it is aggregated by, beside the job.";
                    };
                    output = lib.mkOption {
                      type = lib.types.enum [
                        "rate_sum"
                        "rate_avg"
                      ];
                      description = "How, once every interval: the sum, or the average, of each series' rate.";
                    };
                  };
                }
              );
              default = { };
              description = ''
                Families it makes, by name, each of one it keeps as it is scraped, whose own series are never stored.
              '';
            };
            optional = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = ''
                Those of its families that a target may lack, such as one of the volumes it has. Any other alerts as
                missing while the target answers without it.
              '';
            };
            needsCluster = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Whether its target answers only while this host's cluster does, as one k3s serves. Its target down then
                stands as it was while the servers' checks can't read the cluster, until they have read it again for
                holdFor, and once the target answers again.
              '';
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
        # The rules, or writers, that don't do as the message says, by name.
        refused = set: ok: lib.attrNames (lib.filterAttrs (name: r: !ok name r) set);
        checking = set: ok: message: {
          assertion = refused set ok == [ ];
          message = "${message}: ${lib.concatStringsSep ", " (refused set ok)}.";
        };
        check = checking cfg.rules;
        writing = checking cfg.textfiles;
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
        ) "suveraen.metrics.rules read only families a job keeps or a writer writes")
        {
          assertion = lib.all (f: lib.elem f read) (lib.attrNames sources);
          message = "suveraen.metrics.jobs and textfiles keep and write only families a rule reads: ${
            lib.concatStringsSep ", " (lib.filter (f: !(lib.elem f read)) (lib.attrNames sources))
          }.";
        }
        (checking cfg.jobs (
          _: j:
          lib.all (a: lib.elem a.input (map family j.keep)) (lib.attrValues j.aggregate)
          && lib.all (f: lib.elem f (gives j)) j.optional
        ) "suveraen.metrics.jobs aggregate only families they keep, and may lack only those they store")
        (writing (
          w: _: builtins.match "[a-z][a-z0-9-]*" w != null && !cfg.jobs ? ${w}
        ) "suveraen.metrics.textfiles are named [a-z][a-z0-9-]*, other than a job")
        (writing
          (
            _: t:
            lib.all (f: lib.elem f t.families) t.optional
            && lib.all (
              f:
              !keptBy ? ${f} && lib.length (lib.filter (v: lib.elem f cfg.textfiles.${v}.families) writers) == 1
            ) t.families
          )
          "suveraen.metrics.textfiles write families of their own, which no job keeps, and may lack only those"
        )
        (checking cfg.credentials (
          c: _: builtins.match "[a-z][a-z0-9-]*" c != null
        ) "suveraen.metrics.credentials are named [a-z][a-z0-9-]*")
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
                # The node's target reads the writers' files too.
                "if" =
                  j.keep
                  ++ lib.optionals (job == "node" && writers != [ ]) (
                    [ "node_textfile_mtime_seconds" ] ++ lib.attrNames writtenBy
                  );
              }
            ]
            ++ j.relabel;
          }
        ) cfg.jobs;
      };
      extraOptions = lib.optional (
        aggregated != [ ]
      ) "-streamAggr.config=${yaml.generate "aggregate.yml" aggregated}";
    };
    systemd.services.victoriametrics = {
      wants = password;
      after = password;
      serviceConfig =
        confined
        // {
          MemoryMax = "1G";
        }
        // lib.optionalAttrs (cfg.credentials != { }) {
          SupplementaryGroups = [ credentialsGroup ];
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

    # Nothing but what a rule reads: these collectors for the node's own rules below; a module whose rules read another
    # enables it.
    services.prometheus.exporters.node = {
      enable = true;
      listenAddress = "127.0.0.1";
      enabledCollectors = [
        "systemd"
        "meminfo"
        "pressure"
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
      ]
      ++ lib.optionals (writers != [ ]) [
        "--collector.textfile"
        "--collector.textfile.directory=${textfiles}"
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

    # The node's own: units that fail without alerting by themselves, or keep restarting, memory running out, and the
    # connection table filling, which drops connections for everyone.
    suveraen.metrics.jobs.node.labels = [ "name" ];
    suveraen.metrics.jobs.node.keep = [
      ''node_systemd_unit_state{state="failed"}''
      "node_systemd_service_restart_total"
      "node_memory_MemAvailable_bytes"
      "node_memory_MemTotal_bytes"
      "node_pressure_memory_stalled_seconds_total"
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

    systemd.services.suveraen-metrics-textfiles = lib.mkIf (writers != [ ]) {
      description = "Write what modules measure for this server's metrics";
      serviceConfig = scripted cfg.textfiles // {
        RuntimeDirectory = baseNameOf textfiles;
        RuntimeDirectoryMode = "0755";
        RuntimeDirectoryPreserve = true;
      };
      script = lib.concatStrings (
        lib.mapAttrsToList (name: t: ''
          if ${pkgs.coreutils}/bin/timeout ${toString t.timeout} ${program "textfile" name t} >${textfile name}.new; then
            mv ${textfile name}.new ${textfile name}
          else
            echo "${name}: exit status $?"
            rm -f ${textfile name}.new
          fi
        '') cfg.textfiles
      );
    };
    systemd.timers.suveraen-metrics-textfiles = lib.mkIf (writers != [ ]) {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "30s";
        OnUnitActiveSec = cfg.textfileInterval;
      };
    };

    users.groups = lib.mkIf (cfg.credentials != { }) { ${credentialsGroup} = { }; };
    systemd.services.suveraen-metrics-credentials = lib.mkIf (cfg.credentials != { }) {
      description = "Make what this server's metrics read their targets with";
      wantedBy = following;
      after = following;
      serviceConfig = scripted cfg.credentials // {
        # Each file root's and the group's, which only the store has.
        Group = credentialsGroup;
        UMask = "0027";
        RuntimeDirectory = baseNameOf credentials;
        RuntimeDirectoryMode = "0750";
        RuntimeDirectoryPreserve = true;
      };
      script = ''
        err=$(mktemp)
        # credential <name> <file> <seconds> <script>
        credential() {
          local status=0 why
          timeout "$3" "$4" >"$2.new" 2>"$err" || status=$?
          if [ "$status" = 0 ]; then
            mv "$2.new" "$2"
            return
          fi
          rm -f "$2.new"
          why=$(tail -n 1 "$err")
          if [ "$status" = 124 ]; then why="no end within $3 seconds"; fi
          echo "$1 not made again: ''${why:-exit status $status}"
        }
      ''
      + lib.concatStrings (
        lib.mapAttrsToList (name: c: ''
          credential ${name} ${c.file} ${toString c.timeout} ${program "credential" name c}
        '') cfg.credentials
      );
    };
    systemd.timers.suveraen-metrics-credentials = lib.mkIf (cfg.credentials != { }) {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "30s";
        OnUnitActiveSec = cfg.credentialInterval;
      };
    };

    suveraen.checks = {
      families.metrics = ./host-checks/metrics.jq;
      told.metrics = { inherit command; };
    };

    environment.systemPackages = [ command ];
  };
}
