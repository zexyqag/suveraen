# Every server checks, from the status the controllers record and with an account that may read little else, how old
# each tenant's WAL archiving, base backups, off-site copies, checks and volume copies are against what their templates
# allow (suveraen/max-age), how old its own backup files are, and Ceph's health; whether Flux's objects are ready and
# applied the release the server runs, cert-manager renews every certificate in time, and each of the gateway's edges
# answers the server through the gateway; whether its own addresses answer STUN; what other modules tell it
# (suveraen.checks.told), such as what the rules on its own metrics find; and as root, with no credential, each tenant's
# Kanidm (suveraen-idm check, idm.nix) and each tenant's mesh against the operator's rules (suveraen-mesh check,
# mesh.nix). It alerts once when that changes, again while it lasts, and when it can't read the cluster, or check every
# tenant's Kanidm and mesh, and notes each change of who can reach what in a mesh once.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.suveraen.checks;
  alert = lib.getExe config.suveraen.alerts.command;
  inherit (config.suveraen.cluster) nodeIP stun gatewayCA;
  port = config.suveraen.cluster.webPorts.https;
  # How long a STUN binding request may wait for its answer.
  stunSeconds = 5;
  stunProbes = if stun.port == null then 0 else lib.length nodeIP;
  # What the checks keep from one run to the next, by the name systemd keeps it under.
  state = "host-checks";
  # The edges are asked all at once, each for no longer than maxTime: room to start them all.
  edgeCap = cfg.edges.maxTime + 10;
  ca = if gatewayCA == null then config.security.pki.caBundle else gatewayCA;
  # How long each part that tells the checks something may take.
  toldSeconds = 120;
  # Room for STUN's answers, what other modules tell the checks, suveraen-idm and suveraen-mesh check, the edges',
  # and suveraen-alert to try both channels.
  timeout =
    stunSeconds * stunProbes
    + toldSeconds * lib.length (lib.attrNames cfg.told)
    + edgeCap
    + 2 * config.suveraen.alerts.retrySeconds
    + 540;
  bootDelay = 600;

  inherit (import ./duration.nix lib) seconds;
  duration = (import ./duration.nix lib).type;

  # What the report runs: the judge on every family declared, each a jq module whose check gives its rows
  # (host-checks/judge.jq, host-checks/rows.jq), and the alert's grammar.
  families = lib.attrNames cfg.families;
  judge = pkgs.linkFarm "host-checks" (
    [
      {
        name = "judge.jq";
        path = ./host-checks/judge.jq;
      }
      {
        name = "rows.jq";
        path = ./host-checks/rows.jq;
      }
      {
        name = "alert.jq";
        path = ./host-checks/alert.jq;
      }
      {
        name = "main.jq";
        path = pkgs.writeText "main.jq" ''
          import "judge" as judge;
          ${lib.concatMapStrings (name: "import \"${name}\" as family_${name};\n") families}
          judge::judge(${
            if families == [ ] then
              "empty"
            else
              lib.concatMapStringsSep ", " (
                name: "{name: \"${name}\", rows: [family_${name}::check(.)]}"
              ) families
          })
        '';
      }
    ]
    ++ lib.mapAttrsToList (name: path: {
      name = "${name}.jq";
      inherit path;
    }) cfg.families
  );

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
      stun =
        if stun.port == null then
          null
        else
          {
            inherit (stun) port;
            addresses = nodeIP;
          };
      mesh = {
        inherit (cfg.mesh) minimumClient;
        loginExpiry = seconds cfg.mesh.loginExpiry;
      };
      flux = {
        # The root Kustomization, which applies the release.
        root = config.suveraen.cluster.fluxRoot;
        notReadyAfter = seconds cfg.flux.notReadyAfter;
        suspendedAfter = seconds cfg.flux.suspendedAfter;
        behindAfter = seconds cfg.flux.behindAfter;
      };
      certificates = {
        renewalGrace = seconds cfg.certificates.renewalGrace;
        inherit (cfg.certificates) urgentShare;
        # cert-manager issues within minutes; one with no certificate an hour after it was made failed to.
        issueGrace = 3600;
      };
      edges = {
        addresses = nodeIP;
        unansweredAfter = seconds cfg.edges.unansweredAfter;
        inherit (cfg.edges) maxTime;
        cap = edgeCap;
      };
    }
  );

  # Run before the others, whether the cluster can be read or not: whether each of the node's addresses answers a STUN
  # binding request from the node itself. turnutils_stunclient also exits 0 on an answer that isn't one.
  stunProbe = pkgs.writeShellApplication {
    name = "host-checks-stun";
    runtimeInputs = [
      pkgs.coturn
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.jq
    ];
    text = ''
      for address in ${lib.escapeShellArgs nodeIP}; do
        why=
        if ! out=$(turnutils_stunclient -t ${toString (stunSeconds * 1000)} -p ${toString stun.port} "$address" 2>&1) \
          || ! grep -q 'UDP reflexive addr: ' <<<"$out"; then
          why=$(tail -n 1 <<<"$out")
        fi
        jq -n --arg address "$address" --arg why "$why" \
          '{($address): (if $why == "" then {answered: true} else {answered: false, $why} end)}'
      done | jq -s 'add' >"$RUNTIME_DIRECTORY/stun.json"
    '';
  };

  # Run after read, as the check: each HTTPS or TLS listener of the gateway's Gateways, asked for its host at each of the
  # node's addresses, through the gateway's own Service, all at once. curl's errors name the host, so they go nowhere;
  # what each answered is kept by Gateway and listener.
  edgeProbe = pkgs.writeShellApplication {
    name = "host-checks-edges";
    runtimeInputs = [
      pkgs.curl
      pkgs.jq
    ];
    text = ''
      run=$RUNTIME_DIRECTORY
      [ -s "$run/gateways.json" ] || exit 0
      jq -r '.items // [] | .[] | .metadata.name as $gateway | .spec.listeners[]?
        | select((.protocol == "HTTPS" or .protocol == "TLS") and .hostname != null) | [$gateway, .name, .hostname]
        | @tsv' "$run/gateways.json" | {
        while IFS=$'\t' read -r gateway listener host; do
          for address in ${lib.escapeShellArgs nodeIP}; do
            (
              at=$address
              if [[ $at == *:* ]]; then at="[$at]"; fi
              status=0
              code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout ${toString cfg.edges.connectTimeout} \
                --max-time ${toString cfg.edges.maxTime} --cacert ${lib.escapeShellArg ca} \
                --resolve "$host:${toString port}:$at" "https://$host:${toString port}/" 2>/dev/null) || status=$?
              printf '%s\t%s\t%s\t%s\t%s\n' "$gateway" "$listener" "$address" "$code" "$status" >>"$run/edges.tsv"
            ) &
          done
        done
        wait
      }
    '';
  };

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

  # Run by root after prepare: suveraen-idm reads the apps' copies of their secrets to probe Kanidm with, and
  # suveraen-mesh each mesh's database by exec into its PostgreSQL, which the account below may not, and keep them to
  # themselves; and before it, so whether the cluster can be read or not, what other modules tell. A check that fails
  # says why, and alerts once it keeps failing.
  told =
    part: command:
    pkgs.writeShellApplication {
      name = "host-checks-${part}";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.jq
      ];
      text = ''
        run=$RUNTIME_DIRECTORY
        if [ -e "$run/unreadable" ]; then exit 0; fi
        status=0
        timeout ${toString toldSeconds} ${lib.getExe command} check >"$run/${part}.json" 2>"$run/${part}.err" \
          || status=$?
        if [ "$status" != 0 ]; then
          why=$(tail -n 1 "$run/${part}.err")
          if [ "$status" = 124 ]; then why="no answer within ${toString toldSeconds} seconds"; fi
          echo "${command.name} check: ''${why:-exit status $status}"
          jq -n --arg why "''${why:-exit status $status}" '{failed: $why}' >"$run/${part}.json"
        fi
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
      get /apis/kustomize.toolkit.fluxcd.io/v1/kustomizations "$run/kustomizations.json"
      get /apis/helm.toolkit.fluxcd.io/v2/helmreleases "$run/helmreleases.json"
      get /apis/source.toolkit.fluxcd.io/v1/gitrepositories "$run/gitrepositories.json"
      get /apis/source.toolkit.fluxcd.io/v1/helmcharts "$run/helmcharts.json"
      get /apis/cert-manager.io/v1/certificates "$run/certificates.json"
      get /apis/gateway.networking.k8s.io/v1/namespaces/gateway/gateways "$run/gateways.json"
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

      [ -s "$run/idm.json" ] || echo null >"$run/idm.json"
      [ -s "$run/mesh.json" ] || echo null >"$run/mesh.json"

      args=()
      for part in nodes clusters objectstores pvcs replicationsources cephcluster kustomizations helmreleases \
        gitrepositories helmcharts certificates gateways cronjobs idm mesh; do
        args+=(--slurpfile "$part" "$run/$part.json")
      done
      # Of Flux's objects, certificates and Gateways, only what the checks judge: a chart's values and a condition's
      # message can hold anything the release gives them.
      jq -n "''${args[@]}" '
        def listed(f): if . == null then null else {items: [.items[] | f]} end;
        def flux: {metadata: (.metadata | {name, namespace}), spec: (.spec | {suspend, dependsOn}),
          status: {conditions: [.status.conditions[]? | {type, status, reason}],
            lastAppliedRevision: .status.lastAppliedRevision}};
        {nodes: $nodes[0], clusters: $clusters[0], objectstores: $objectstores[0], pvcs: $pvcs[0],
          replicationsources: $replicationsources[0], cephcluster: $cephcluster[0],
          kustomizations: ($kustomizations[0] | listed(flux)), helmreleases: ($helmreleases[0] | listed(flux)),
          gitrepositories: ($gitrepositories[0] | listed(flux)), helmcharts: ($helmcharts[0] | listed(flux)),
          certificates: ($certificates[0] | listed({metadata: (.metadata | {name, namespace, creationTimestamp}),
            spec: (.spec | {secretName, dnsNames}), status: (.status // {} | {notBefore, notAfter, renewalTime})})),
          gateways: ($gateways[0] | listed({metadata: (.metadata | {name, namespace}),
            spec: {listeners: [.spec.listeners[]? | {name, protocol, hostname, tls: (.tls // {} | {certificateRefs})}]}})),
          cronjobs: ($cronjobs | add // {}), idm: $idm[0], mesh: $mesh[0]}' >"$run/cluster.json"
    '';
  };

  # Run by root after the check: it reads this server's backup files, judges everything, and alerts.
  report = pkgs.writeShellApplication {
    name = "host-checks-report";
    runtimeInputs = [
      pkgs.jq
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
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

      [ -e "$state/kanidm-judged.json" ] || echo '{}' >"$state/kanidm-judged.json"
      [ -e "$state/mesh.json" ] || echo '{}' >"$state/mesh.json"
      [ -e "$state/since.json" ] || echo '{}' >"$state/since.json"
      [ -e "$run/stun.json" ] || echo '{}' >"$run/stun.json"
      # What other modules told, by name, null for one that told nothing.
      told='{}'
      ${lib.concatMapStrings (name: ''
        [ -s "$run/told-${name}.json" ] || echo null >"$run/told-${name}.json"
        told=$(jq -c --arg name ${lib.escapeShellArg name} --argjson told "$told" '$told + {($name): .}' \
          "$run/told-${name}.json")
      '') (lib.attrNames cfg.told)}
      [ -e "$run/edges.tsv" ] || : >"$run/edges.tsv"
      # The release this host's upgrade resolved last, if it has yet.
      revision=$(cat ${config.suveraen.upgrade.revisionFile} 2>/dev/null || true)
      findings=$(jq -n --argjson now "$now" --slurpfile spec ${spec} --argjson files "$files" \
        --slurpfile stun "$run/stun.json" --argjson told "$told" --rawfile edges "$run/edges.tsv" \
        --arg revision "$revision" \
        --slurpfile seen "$state/first-seen.json" --argjson read "$(<"$state/last-read")" \
        --slurpfile judged "$state/kanidm-judged.json" \
        --slurpfile mesh "$state/mesh.json" --slurpfile since "$state/since.json" --slurpfile cluster "$cluster" \
        '{$now, spec: $spec[0], $files, stun: $stun[0], $told, cluster: $cluster[0],
          edges: [$edges | split("\n")[] | select(. != "") | split("\t")
            | {gateway: .[0], listener: .[1], address: .[2], code: (.[3] | tonumber), exit: (.[4] | tonumber)}],
          revision: (if $revision == "" then null else $revision end),
          state: {lastRead: $read, firstSeen: $seen[0], kanidmJudged: $judged[0],
            mesh: $mesh[0], since: $since[0]}}' \
        | jq -r -L ${judge} -f ${judge}/main.jq)
      judged=$(jq -R -r 'split("\t") | select(.[0:2] == ["kanidm", "judged"]) | .[2]' <<<"$findings")
      if [ -n "$judged" ]; then
        printf '%s\n' "$judged" >"$state/kanidm-judged.json.new"
        mv "$state/kanidm-judged.json.new" "$state/kanidm-judged.json"
      fi
      # When each finding was first found wrong, while any is, kept whether or not the alert gets through.
      since=$(jq -R -r 'split("\t") | select(.[0:2] == ["since", "state"]) | .[2]' <<<"$findings")
      if [ -z "$since" ]; then since='{}'; fi
      printf '%s\n' "$since" >"$state/since.json.new"
      mv "$state/since.json.new" "$state/since.json"
      jq -R -r 'split("\t") | select(.[0:2] != ["mesh", "state"] and .[0:2] != ["since", "state"])
        | if length == 8 then "\(.[2]) \(.[1]): \(.[5])" elif .[0] == "cluster" then "cluster scope: \(.[1])"
          elif length == 3 then "\(.[0]) \(.[1]): \(.[2])" else join(" ") end' <<<"$findings"

      touch "$state/late.tsv"
      decision=$(jq -R -s -c --rawfile alerted "$state/late.tsv" --argjson now "$now" \
        --argjson remind ${toString (seconds cfg.remindAfter)} \
        --argjson reminded "$(cat "$state/reminded-at" 2>/dev/null || echo 0)" -f ${judge}/alert.jq <<<"$findings")
      # What the heartbeat vouches for: the checks ran and were judged. Whether their alert got through, the
      # undelivered marker tells.
      touch "$state/checked"
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
      # Only once a change of who can reach what was sent, so one that got nowhere is noted again.
      mesh=$(jq -R -r 'split("\t") | select(.[0:2] == ["mesh", "state"]) | .[2]' <<<"$findings")
      if [ -n "$mesh" ]; then
        printf '%s\n' "$mesh" >"$state/mesh.json.new"
        mv "$state/mesh.json.new" "$state/mesh.json"
      fi
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

    stateQuota = lib.mkOption {
      type = lib.types.str;
      default = "64M";
      description = "Most space what the checks keep from one run to the next may take.";
    };

    mesh = {
      minimumClient = lib.mkOption {
        type = lib.types.strMatching "[0-9]+\\.[0-9]+\\.[0-9]+";
        default = "0.78.0";
        description = "The oldest NetBird release a tenant's mesh takes: every policy checks for it, and no peer runs one older.";
      };

      loginExpiry = lib.mkOption {
        type = duration;
        default = "7d";
        description = "The longest a device of a tenant's mesh may stay signed in before it signs in again.";
      };
    };

    flux = {
      notReadyAfter = lib.mkOption {
        type = duration;
        default = "1h";
        description = "How long one of Flux's Kustomizations, HelmReleases or sources may stay unready before it alerts.";
      };

      suspendedAfter = lib.mkOption {
        type = duration;
        default = "1d";
        description = "How long one of them may stay suspended before it alerts, at low priority.";
      };

      behindAfter = lib.mkOption {
        type = duration;
        default = "1d";
        description = ''
          How long the release Flux applied last may differ from the one this server's upgrade resolved last before it
          alerts. Flux takes a new release within minutes and the server the next night, so this is longer than from
          one upgrade to the next.
        '';
      };
    };

    certificates = {
      renewalGrace = lib.mkOption {
        type = duration;
        default = "1d";
        description = "How long past the time cert-manager meant to renew a certificate it may stay unrenewed before it alerts.";
      };

      urgentShare = lib.mkOption {
        type = lib.types.ints.between 1 99;
        default = 10;
        description = "The share of a certificate's lifetime, in percent, below which one late to renew alerts at top priority.";
      };
    };

    edges = {
      unansweredAfter = lib.mkOption {
        type = duration;
        default = "30m";
        description = "How long one of the gateway's edges may go unanswered before it alerts.";
      };

      connectTimeout = lib.mkOption {
        type = lib.types.ints.positive;
        default = 5;
        description = "How many seconds asking an edge may wait for its connection.";
      };

      maxTime = lib.mkOption {
        type = lib.types.ints.positive;
        default = 15;
        description = ''
          How many seconds asking an edge may take in all. The edges are asked all at once, so the checks take about
          this long longer.
        '';
      };
    };

    told = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.command = lib.mkOption {
            type = lib.types.package;
            description = "A program whose `check` prints what it tells, as JSON.";
          };
        }
      );
      default = { };
      description = ''
        What other modules tell the checks, by name: each a command the checks run as root before they read the
        cluster, whether or not it can be read, for two minutes at most, whose output the families find as
        $c.told.<name>, as {failed: why} when it failed, or as null when it told nothing.
      '';
    };

    families = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      description = ''
        The families of checks, by name: each a jq module beside host-checks/rows.jq, whose check($c) gives the rows of
        what it finds in what the server read ($c, with the scope it checks in), as host-checks/judge.jq describes.
      '';
    };

    judge = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      internal = true;
      default = judge;
      description = "The checks' judge on every family, and the grammar of their alerts, as the report runs them.";
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
        # Each names a file and a step of the checks.
        assertion = lib.all (name: builtins.match "[a-z][a-z0-9-]*" name != null) (lib.attrNames cfg.told);
        message = "suveraen.checks.told are named [a-z][a-z0-9-]*.";
      }
      {
        assertion = lib.all (f: lib.hasPrefix "/" f.path) (lib.attrValues cfg.files);
        message = "suveraen.checks.files' paths are absolute.";
      }
      {
        # Each is a module of the judge's, imported from its file under an alias no jq keyword can be.
        assertion = lib.all (
          name:
          builtins.match "[a-z][a-z0-9]*" name != null
          && !lib.elem name [
            "judge"
            "rows"
            "alert"
            "main"
          ]
        ) families;
        message = "suveraen.checks.families are named [a-z][a-z0-9]*, other than judge, rows, alert and main.";
      }
    ];

    suveraen.checks.families = {
      api = ./host-checks/api.jq;
      backups = ./host-checks/backups.jq;
      ceph = ./host-checks/ceph.jq;
      certificates = ./host-checks/certificates.jq;
      edges = ./host-checks/edges.jq;
      flux = ./host-checks/flux.jq;
      kanidm = ./host-checks/kanidm.jq;
      mesh = ./host-checks/mesh.jq;
      stun = ./host-checks/stun.jq;
    };

    # It may read the status it judges, by name where the kind holds more, and nothing else: no Secrets, ConfigMaps,
    # pods, logs or jobs. Flux's objects hold what the release gives them, which a Secret's values never reach
    # (checks/render.sh).
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
          {
            apiGroups = [ "kustomize.toolkit.fluxcd.io" ];
            resources = [ "kustomizations" ];
            verbs = [ "list" ];
          }
          {
            apiGroups = [ "helm.toolkit.fluxcd.io" ];
            resources = [ "helmreleases" ];
            verbs = [ "list" ];
          }
          {
            apiGroups = [ "source.toolkit.fluxcd.io" ];
            resources = [
              "gitrepositories"
              "helmcharts"
            ];
            verbs = [ "list" ];
          }
          {
            apiGroups = [ "cert-manager.io" ];
            resources = [ "certificates" ];
            verbs = [ "list" ];
          }
          # Read in the gateway's namespace alone, the only one the edge-objects policy lets hold Gateways.
          {
            apiGroups = [ "gateway.networking.k8s.io" ];
            resources = [ "gateways" ];
            verbs = [ "list" ];
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
      description = "Check how old the backups are, Ceph's health, Flux, the certificates, the edges and what other modules tell";
      # Not ordered after k3s: one that never gets ready would hold the check back with it, where prepare and read
      # report it as unreadable.
      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
        RuntimeDirectory = "host-checks";
        RuntimeDirectoryMode = "0700";
        StateDirectory = state;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        TimeoutStartSec = timeout;
        ExecStartPre =
          lib.optional (stun.port != null) (lib.getExe stunProbe)
          ++ lib.mapAttrsToList (name: t: "+${lib.getExe (told "told-${name}" t.command)}") cfg.told
          ++ [
            "+${lib.getExe prepare}"
            "+${lib.getExe (told "idm" config.suveraen.idm.command)}"
            "+${lib.getExe (told "mesh" config.suveraen.mesh.command)}"
          ];
        ExecStart = lib.getExe read;
        # Whatever the edges answer, or don't, within the cap, the report judges.
        ExecStartPost = [
          "-${pkgs.coreutils}/bin/timeout ${toString edgeCap} ${lib.getExe edgeProbe}"
          "+${lib.getExe report}"
        ];
      };
    };
    # What the checks keep names people of the tenants' meshes, and goes with the findings, not with the snapshots of
    # /var. They run as a dynamic user, whose state systemd keeps under /var/lib/private.
    suveraen.storage.unsnapshotted.host-checks = {
      path = "/var/lib/private/${state}";
      quota = cfg.stateQuota;
    };
    systemd.timers.host-checks = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "${toString bootDelay}s";
        OnUnitActiveSec = "${toString (seconds cfg.interval)}s";
      };
    };
    # Once three runs are due, or the first after boot, and as long as one may take, the checks have stopped.
    suveraen.alerts.heartbeat.stamps.checks = {
      path = "/var/lib/private/${state}/checked";
      maxAge = lib.max (3 * seconds cfg.interval) bootDelay + timeout;
    };
    # It alerts on what it finds by itself and exits 0; failing means the check itself broke.
    suveraen.alerts.units = [ "host-checks" ];
  };
}
