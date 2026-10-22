# Every server checks, from the status the controllers record and with an account that may read little else, how old
# each tenant's WAL archiving, base backups, off-site copies, checks and volume copies are against what their templates
# allow (suveraen/max-age), how old its own backup files are, and Ceph's health. It alerts once when that changes,
# again while it lasts, and when it can't read the cluster.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.suveraen.checks;
  alert = lib.getExe config.suveraen.alerts.command;

  duration = lib.types.strMatching "[1-9][0-9]*[mhd]";
  seconds =
    s:
    let
      m = builtins.match "([0-9]+)([mhd])" s;
    in
    lib.toInt (lib.head m)
    * {
      m = 60;
      h = 3600;
      d = 86400;
    }
    .${lib.last m};

  spec = pkgs.writeText "host-checks.json" (
    builtins.toJSON {
      # The k3s node name: cluster.nix sets no other.
      host = config.networking.hostName;
      unreadableAfter = seconds cfg.unreadableAfter;
      # Rook records Ceph's health every minute.
      cephStaleAfter = 1800;
      # Flux makes what a backup needs together with it; a missing part is late once it had time to come.
      missingGrace = 3600;
      files = lib.mapAttrs (_: f: {
        inherit (f) path;
        maxAge = seconds f.maxAge;
      }) cfg.files;
    }
  );

  # Run by root before the check: a token for the account below, valid for 10 minutes, and the API server's CA. The
  # check itself runs without root, so it can't read the admin's kubeconfig.
  prepare = pkgs.writeShellApplication {
    name = "host-checks-prepare";
    runtimeInputs = [
      config.services.k3s.package
      pkgs.coreutils
    ];
    text = ''
      run=$RUNTIME_DIRECTORY
      unreadable() {
        echo "$1: $(tail -n 1 "$run/prepare.err")" >"$run/unreadable"
        exit 0
      }
      token=$(kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml --request-timeout=20s --cache-dir "$run/cache" \
        -n kube-system create token host-checks --duration=10m 2>"$run/prepare.err") || unreadable "no token"
      printf 'Authorization: Bearer %s\n' "$token" >"$run/header"
      # Readable by the check, whatever mode k3s gives the original.
      install -m 644 /var/lib/rancher/k3s/server/tls/server-ca.crt "$run/ca.crt" 2>"$run/prepare.err" || unreadable "no CA"
    '';
  };

  read = pkgs.writeShellApplication {
    name = "host-checks-read";
    runtimeInputs = [
      pkgs.curl
      pkgs.jq
      pkgs.coreutils
    ];
    text = ''
      run=$RUNTIME_DIRECTORY
      if [ -e "$run/unreadable" ]; then exit 0; fi

      # get <path> <file>; a 404 is a kind that isn't installed, or an object that isn't there. A body cut short
      # still reports its headers' code, so only a whole one counts.
      get() {
        local code
        code=$(curl -sS --max-time 20 --cacert "$run/ca.crt" -H @"$run/header" -o "$2" -w '%{http_code}' \
          "https://127.0.0.1:6443$1" 2>"$run/read.err") || code=
        case $code in
          200) ;;
          404) echo null >"$2" ;;
          *)
            echo "$1: $(tail -n 1 "$run/read.err" | grep . || echo "HTTP $code")" >"$run/unreadable"
            exit 0
            ;;
        esac
      }

      get "/api/v1/nodes?labelSelector=node-role.kubernetes.io%2Fcontrol-plane%3Dtrue" "$run/nodes.json"
      get /apis/postgresql.cnpg.io/v1/clusters "$run/clusters.json"
      get /apis/barmancloud.cnpg.io/v1/objectstores "$run/objectstores.json"
      get "/api/v1/persistentvolumeclaims?labelSelector=suveraen%2Fbackup%3Dvolsync" "$run/pvcs.json"
      get /apis/volsync.backube/v1alpha1/replicationsources "$run/replicationsources.json"
      get /apis/ceph.rook.io/v1/namespaces/rook-ceph/cephclusters/rook-ceph "$run/cephcluster.json"
      : >"$run/cronjobs.json"
      cronjobs() {
        for ns in $(jq -r '.items // [] | map(.metadata.namespace) | unique[]' "$1"); do
          for name in "''${@:2}"; do
            get "/apis/batch/v1/namespaces/$ns/cronjobs/$name" "$run/cronjob.json"
            jq -c --arg key "$ns/$name" '{($key): .}' "$run/cronjob.json" >>"$run/cronjobs.json"
          done
        done
      }
      cronjobs "$run/clusters.json" offsite offsite-check-1 offsite-check-2
      cronjobs "$run/replicationsources.json" offsite-check-1 offsite-check-2

      args=()
      for part in nodes clusters objectstores pvcs replicationsources cephcluster cronjobs; do
        args+=(--slurpfile "$part" "$run/$part.json")
      done
      jq -n "''${args[@]}" '{nodes: $nodes[0], clusters: $clusters[0], objectstores: $objectstores[0], pvcs: $pvcs[0],
        replicationsources: $replicationsources[0], cephcluster: $cephcluster[0], cronjobs: ($cronjobs | add // {})}' \
        >"$run/cluster.json"
    '';
  };

  # From this run's findings and the late ones last alerted: at most one alert, and what counts as late from now on.
  decide = pkgs.writeText "host-checks-alert.jq" ''
    def rows: split("\n") | map(select(. != "") | split("\t"));
    def finding: {scope: .[0], key: .[1], status: .[2], priority: (.[3] | tonumber), title: .[4], detail: .[5]};
    def line: "\(.key): \(.detail)";
    def health: .title | startswith("Ceph HEALTH");
    def headline:
      group_by(.title)
      | map(.[0].title as $t
          | if $t == "backups late" then "backups late: \(length)"
            elif .[0] | health then
              (map(.key | ltrimstr("Ceph ")) - [$t | ltrimstr("Ceph ")]) as $codes
              | if $codes == [] then $t else "\($t): \($codes | join(", "))" end
            else $t
            end)
      | join("; ");
    def cleared($late):
      group_by(.title)
      | map(.[0].title as $t
          | if .[0] | health then
              if any($late[]; health) then "Ceph \(map(.key | ltrimstr("Ceph ")) | join(", ")) cleared"
              else "Ceph healthy again"
              end
            else
              {"backups late": "backups on time again", "Ceph status not updated": "Ceph status updated again",
               "cluster status unreadable": "cluster status readable again"}[$t]
            end)
      | unique
      | join("; ");

    rows as $rows
    | ($rows | map(select(length == 2)) | first | .[1]) as $scope
    | [$rows[] | select(length == 6) | finding] as $found
    | [$alerted | rows[] | finding] as $before
    | [$found[] | select(.status == "late")] as $current
    | [$found[] | select(.status == "ok") | .key] as $ok
    | [$found[].key] as $keys
    | [$before[].key] as $was
    | any($found[]; .key == "Ceph status") as $ceph
    | [$current[] | select(.key | IN($was[]) | not)] as $new
    # A Ceph check that is gone has cleared; anything else no longer found went with what it was about.
    | [$before[] | select((.key | IN($ok[])) or ($ceph and health and (.key | IN($keys[]) | not)))] as $back
    # Unread, the cluster's findings stand as they were.
    | ($current + if $scope == "unreadable" then [$before[] | select(.scope == "cluster")] else [] end) as $late
    | [$late[] | select(.key | IN($new[].key) | not)] as $still
    | if $new != [] then
        {title: ($new | headline), priority: ($new | map(.priority) | max),
         # suveraen-alert keeps the end of a long message.
         body: ((if $still != [] then ["Still late:"] + ($still | map(line)) else [] end)
           + (if $back != [] then ["On time again: \($back | map(.key) | join(", "))"] else [] end)
           + ["New:"] + ($new | map(line)) | join("\n"))}
      elif $back != [] then
        {title: ($back | cleared($late)), priority: 3,
         body: (["On time again: \($back | map(.key) | join(", "))"]
           + (if $late != [] then ["Still late:"] + ($late | map(line)) else [] end) | join("\n"))}
      elif $late != [] and $now - $reminded >= $remind then
        {title: "still: \($late | headline)", priority: ($late | map(.priority) | max), body: ($late | map(line) | join("\n"))}
      else {title: null}
      end
    | .late = ([$late[] | [.scope, .key, .status, .priority, .title, .detail] | map(tostring) | join("\t") + "\n"] | add // "")
  '';

  # Run by root after the check: it reads this server's backup files, judges everything, and alerts.
  report = pkgs.writeShellApplication {
    name = "host-checks-report";
    runtimeInputs = [
      pkgs.jq
      pkgs.coreutils
      pkgs.findutils
    ];
    text = ''
      state=$STATE_DIRECTORY
      run=$RUNTIME_DIRECTORY
      now=$(date +%s)

      # The newest file at each path, or null; one missing counts from when it was first missed.
      files=$(jq -r '.files | to_entries[] | [.key, .value.path] | @tsv' ${spec} | while IFS=$'\t' read -r name path; do
        newest=$({ find "$path" -maxdepth 1 -type f -printf '%T@\n' 2>/dev/null || true; } | sort -n | tail -n 1)
        jq -n --arg name "$name" --arg newest "$newest" '{($name): ($newest | if . == "" then null else tonumber end)}'
      done | jq -s 'add // {}')
      [ -e "$state/first-seen.json" ] || echo '{}' >"$state/first-seen.json"
      jq --argjson files "$files" --argjson now "$now" \
        '. as $seen | $files | with_entries(select(.value == null) | .value = ($seen[.key] // $now))' \
        "$state/first-seen.json" >"$state/first-seen.json.new"
      mv "$state/first-seen.json.new" "$state/first-seen.json"

      if [ -e "$run/cluster.json" ] || [ ! -e "$state/last-read" ]; then echo "$now" >"$state/last-read"; fi
      cluster=$run/cluster.json
      if [ ! -e "$cluster" ]; then
        cluster=$run/unreadable.json
        jq -n --rawfile reason "$run/unreadable" '{unreadable: ($reason | rtrimstr("\n"))}' >"$cluster"
      fi

      findings=$(jq -n --argjson now "$now" --slurpfile spec ${spec} --argjson files "$files" \
        --slurpfile seen "$state/first-seen.json" --argjson read "$(<"$state/last-read")" --slurpfile cluster "$cluster" \
        '{$now, spec: $spec[0], $files, state: {lastRead: $read, firstSeen: $seen[0]}, cluster: $cluster[0]}' \
        | jq -r -f ${./host-checks.jq})
      jq -R -r 'split("\t") | if length == 2 then "cluster scope: \(.[1])" else "\(.[2]) \(.[1]): \(.[5])" end' \
        <<<"$findings"

      touch "$state/late.tsv"
      decision=$(jq -R -s -c --rawfile alerted "$state/late.tsv" --argjson now "$now" \
        --argjson remind ${toString (seconds cfg.remindAfter)} \
        --argjson reminded "$(cat "$state/reminded-at" 2>/dev/null || echo 0)" -f ${decide} <<<"$findings")
      title=$(jq -r '.title // empty' <<<"$decision")
      if [ -n "$title" ]; then
        # The state stays as it was, so the next run sends it again.
        if ! ${alert} "$title" "$(jq -r .body <<<"$decision")" "$(jq -r .priority <<<"$decision")"; then
          echo "The alert got nowhere; the next run tries again."
          exit 0
        fi
        echo "$now" >"$state/reminded-at"
      fi
      jq -j .late <<<"$decision" >"$state/late.tsv"
    '';
  };
in
{
  options.suveraen.checks = {
    interval = lib.mkOption {
      type = duration;
      default = "15m";
      description = "How often each server checks.";
    };

    unreadableAfter = lib.mkOption {
      type = duration;
      default = "30m";
      description = "How long a server may fail to read the cluster's status before it alerts.";
    };

    remindAfter = lib.mkOption {
      type = duration;
      default = "1d";
      description = "How often to alert again while something stays late.";
    };

    files = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            path = lib.mkOption {
              type = lib.types.str;
              description = "A file, or a directory whose newest file counts.";
            };
            maxAge = lib.mkOption {
              type = duration;
              description = "How old that file may get.";
            };
          };
        }
      );
      default = { };
      description = "Backups on this server, judged by their newest file's age, read by root while the cluster is down too.";
    };
  };

  config = lib.mkIf config.suveraen.cluster.enable {
    assertions = [
      {
        # They name findings beside the cluster's, which all hold a slash or a space.
        assertion = lib.all (name: builtins.match "[a-z0-9-]+" name != null) (lib.attrNames cfg.files);
        message = "suveraen.checks.files are named [a-z0-9-]+.";
      }
      {
        assertion = lib.all (f: lib.hasPrefix "/" f.path) (lib.attrValues cfg.files);
        message = "suveraen.checks.files' paths are absolute.";
      }
    ];

    # It may read the status it judges, by name where the kind holds more, and nothing else: no Secrets, pods, logs or
    # jobs.
    services.k3s.manifests.host-checks.content = [
      {
        apiVersion = "v1";
        kind = "ServiceAccount";
        metadata = {
          name = "host-checks";
          namespace = "kube-system";
        };
      }
      {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        metadata.name = "suveraen-host-checks";
        rules = [
          {
            apiGroups = [ "" ];
            resources = [ "nodes" ];
            verbs = [ "list" ];
          }
          {
            apiGroups = [ "" ];
            resources = [ "persistentvolumeclaims" ];
            verbs = [ "list" ];
          }
          {
            apiGroups = [ "postgresql.cnpg.io" ];
            resources = [ "clusters" ];
            verbs = [ "list" ];
          }
          {
            apiGroups = [ "barmancloud.cnpg.io" ];
            resources = [ "objectstores" ];
            verbs = [ "list" ];
          }
          {
            apiGroups = [ "volsync.backube" ];
            resources = [ "replicationsources" ];
            verbs = [ "list" ];
          }
          {
            apiGroups = [ "batch" ];
            resources = [ "cronjobs" ];
            resourceNames = [
              "offsite"
              "offsite-check-1"
              "offsite-check-2"
            ];
            verbs = [ "get" ];
          }
          {
            apiGroups = [ "ceph.rook.io" ];
            resources = [ "cephclusters" ];
            resourceNames = [ "rook-ceph" ];
            verbs = [ "get" ];
          }
        ];
      }
      {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        metadata.name = "suveraen-host-checks";
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "ClusterRole";
          name = "suveraen-host-checks";
        };
        subjects = [
          {
            kind = "ServiceAccount";
            name = "host-checks";
            namespace = "kube-system";
          }
        ];
      }
    ];

    systemd.services.host-checks = {
      description = "Check how old the backups are, and Ceph's health";
      # Not ordered after k3s: one that never gets ready would hold the check back with it, where prepare and read
      # report it as unreadable.
      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
        RuntimeDirectory = "host-checks";
        RuntimeDirectoryMode = "0700";
        StateDirectory = "host-checks";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        # Room for suveraen-alert to try both channels.
        TimeoutStartSec = 2 * config.suveraen.alerts.retrySeconds + 300;
        ExecStartPre = "+${lib.getExe prepare}";
        ExecStart = lib.getExe read;
        ExecStartPost = "+${lib.getExe report}";
      };
    };
    systemd.timers.host-checks = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10min";
        OnUnitActiveSec = "${toString (seconds cfg.interval)}s";
      };
    };
    # It alerts on what it finds by itself and exits 0; failing means the check itself broke.
    suveraen.alerts.units = [ "host-checks" ];
  };
}
