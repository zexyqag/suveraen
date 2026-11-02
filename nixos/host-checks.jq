# What host-checks.nix finds in what it read, judged at .now: a line saying whether this server checked the cluster
# (evaluated, skipped or unreadable), one when suveraen-idm check told of the tenants' Kanidm and one when it told of
# every one in full, then one per finding with its scope, key, ok, late or unknown, priority, the title it alerts
# under and what was found, separated by tabs, and last, when it told of them, what the report keeps of how each ran
# its migrations as it started and what its own upgrades left undone.

def time: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
def stamp: if . == null then null else time end;

def ago:
  ([., 0] | max) as $s
  | if $s >= 86400 then "\($s / 86400 | floor)d \($s % 86400 / 3600 | floor)h"
    elif $s >= 3600 then "\($s / 3600 | floor)h \($s % 3600 / 60 | floor)m"
    else "\($s / 60 | floor)m"
    end;

# Seconds as a limit is written: 3d, 26h, 90m.
def span: if . % 86400 == 0 then "\(. / 86400)d" elif . % 3600 == 0 then "\(. / 3600)h" else "\(. / 60)m" end;

def since($now): "\(todate) (\($now - . | ago) ago)";

def finding($scope; $key; $late; $priority; $title; $detail):
  [$scope, $key, (if $late then "late" else "ok" end), $priority, $title, ($detail | gsub("[\t\n\r]+"; " "))];

# When the last good copy was made, or with none yet, the time its age counts from.
def last($now; $at; $from):
  if $at != null then {age: ($now - $at), detail: "last \($at | since($now))"}
  else {age: ($now - $from), detail: "never, counted from \($from | since($now))"}
  end;

# Judges what f found ({age, detail}) by $obj's suveraen/max-age. Without a valid one an object is late once older
# than the grace, so a template that drops it can't silence its backups.
def limited($c; $key; $obj; f):
  ($obj.metadata.annotations["suveraen/max-age"] // null) as $set
  | ([$set // "" | capture("^(?<n>[1-9][0-9]*)(?<u>[mhd])$") | (.n | tonumber) * {m: 60, h: 3600, d: 86400}[.u]]
    | first) as $max
  | if $max == null then
      ($obj.metadata.creationTimestamp | time) as $made
      | finding("cluster"; $key; $c.now - $made > $c.grace; 4; "backups late";
          "no valid suveraen/max-age (\($set | tojson)) since \($made | since($c.now)), grace \($c.grace | span)")
    else
      f as $found
      | finding("cluster"; $key; $found.age > $max; 4; "backups late"; "\($found.detail), limit \($max | span)")
    end;

# Something the cluster should hold for what was made at $made, and doesn't.
def missing($c; $key; $made; $what):
  finding("cluster"; $key; $c.now - $made > $c.grace; 4; "backups late";
    "\($what), required since \($made | since($c.now)), grace \($c.grace | span)");

def cronjob($c; $ns; $name; $made):
  $c.cronjobs["\($ns)/\($name)"] as $job
  | if $job == null then missing($c; "\($ns)/\($name)"; $made; "missing")
    else
      limited($c; "\($ns)/\($name)"; $job;
        last($c.now; $job.status.lastSuccessfulTime | stamp; $job.metadata.creationTimestamp | time)
        | if ($job.status.active // []) != [] then .detail += ", a run in progress" end)
    end;

def postgres($c; $k):
  ($k.objectstores.items // [] | INDEX(.metadata.namespace + "/" + .metadata.name)) as $stores
  | $k.clusters.items // []
  | .[]
  | . as $cluster
  | .metadata.namespace as $ns
  | "\($ns)/\(.metadata.name)" as $id
  | (.metadata.creationTimestamp | time) as $made
  | ([.status.conditions[]? | select(.type == "ContinuousArchiving")] | first) as $archiving
  | ([.spec.plugins[]? | select(.name == "barman-cloud.cloudnative-pg.io")] | first | .parameters // {}) as $p
  | $stores["\($ns)/\($p.barmanObjectName)"] as $store
  # Each archive_command run sets the condition; nothing records when WAL was last archived.
  | limited($c; "\($id) WAL archiving"; $cluster;
      if $archiving.status == "True" then {age: 0, detail: "archiving"}
      elif $archiving != null then
        ($archiving.lastTransitionTime | time) as $since
        | {age: ($c.now - $since),
           detail: "failing since \($since | since($c.now)): \($archiving.message // "" | .[:200])"}
      else {age: ($c.now - $made), detail: "not reported since \($made | since($c.now))"}
      end),
    # A generation's backups are kept under its serverName; an older generation's don't count.
    (if $store == null then missing($c; "\($id) base backup"; $made; "no ObjectStore \($p.barmanObjectName // "named")")
     else
       limited($c; "\($id) base backup"; $store;
         last($c.now;
           $store.status.serverRecoveryWindow[$p.serverName // $cluster.metadata.name].lastSuccessfulBackupTime | stamp;
           $made))
     end),
    cronjob($c; $ns; "offsite", "offsite-check-1", "offsite-check-2"; $made);

def volumes($c; $k):
  ($k.replicationsources.items // []) as $sources
  | ($sources[]
      | . as $source
      | limited($c; "\(.metadata.namespace)/\(.metadata.name)"; $source;
          last($c.now; $source.status.lastSyncTime | stamp; $source.metadata.creationTimestamp | time)
          | if ($source.spec.trigger.manual // null) != null then .detail += ", no copy scheduled (manual trigger set)" end)),
    ($k.pvcs.items // []
      | .[]
      | .metadata as $m
      | range(1; 3) as $n
      | select(any($sources[]; .metadata.namespace == $m.namespace and .spec.sourcePVC == $m.name
          and .spec.restic.repository == "offsite-\($n)") | not)
      | missing($c; "\($m.namespace)/\($m.name) copy to offsite-\($n)"; $m.creationTimestamp | time;
          "no ReplicationSource copies it")),
    ($sources
      | group_by(.metadata.namespace)[]
      | cronjob($c; .[0].metadata.namespace; "offsite-check-1", "offsite-check-2";
          map(.metadata.creationTimestamp | time) | min));

# Ceph's health as Rook last reported it. Rook lists muted checks without saying so; Ceph's own health leaves them out.
def ceph($c; $cluster):
  ($cluster.status.ceph // {}) as $s
  | ($s.health // null) as $health
  | (($s.lastChecked // null | stamp) // ($cluster.metadata.creationTimestamp | time)) as $checked
  | ($cluster.spec.healthCheck.muteHealthWarning // {} | with_entries(select(.value.policy == "mute")) | keys) as $muted
  | finding("cluster"; "Ceph status"; $c.now - $checked > $c.stale; 4; "Ceph status not updated";
      "\($health // "no health yet"), checked \($checked | since($c.now)), limit \($c.stale | span)"),
    (select($health != null and $health != "HEALTH_OK")
      | [$s.details // {} | to_entries[] | select(.key | IN($muted[]) | not)] as $found
      | if $found == [] then
          finding("cluster"; "Ceph \($health)"; true; (if $health == "HEALTH_ERR" then 5 else 4 end); "Ceph \($health)";
            "nothing but muted checks: \($s.details // {} | keys | join(", "))")
        else
          $found[]
          | finding("cluster"; "Ceph \(.key)"; true;
              (if $health == "HEALTH_ERR" or (.key | IN("POOL_FULL", "OSD_FULL")) then 5 else 4 end); "Ceph \($health)";
              "\(.value.message // .value.severity); ceph health detail says more")
        end);

# What the checks could not tell this time, which stands as it was found last (host-checks.nix).
def unknown($key; $title; $detail): ["cluster", $key, "unknown", 4, $title, ($detail | gsub("[\t\n\r]+"; " "))];

def minor: split(".")[0:2];

# How each tenant's Kanidm ran its migrations as its container started, where this run or one before here read it from
# its log, and what its own upgrades left undone, by tenant: what the report keeps. A start that raised Kanidm's domain
# level brought all of its own entries up to date anew, so what it left undone replaces what an earlier one did, which
# any other start leaves standing. Kanidm raises the level with each minor version: a start on a minor version other
# than the last one read here that raised none follows one that did, which no check here read.
def judged($idm; $before):
  [$idm.tenants[] | .tenant as $t
    | if .migrations != null and .started != null then
        .migrations as $m
        | ($before[$t].migrations.version // null) as $was
        | {($t): {started, migrations: $m,
            upgrade: (if $m.upgrade != null then $m.upgrade
              elif $was != null and ($was | minor) != ($m.version | minor) then
                ($before[$t].upgrade // []) + ["Kanidm's upgrade from \($was) to \($m.version), which no check here read"]
              else $before[$t].upgrade // []
              end)}}
      else $before[$t] // empty | {($t): .}
      end]
  | add // {};

# Each tenant's Kanidm as suveraen-idm check found it (idm.nix): its admin accounts, how it ran its migrations as it
# started, the IDs they declare, and its clients.
def kanidm($c; $idm; $judged):
  $idm.tenants[]?
  | .tenant as $tenant
  | "\($tenant)-kanidm" as $ns
  | if .unchecked != null then unknown($ns; "Kanidm unchecked"; .unchecked)
    else
      ([.accounts | to_entries[] | select(.value == "unknown") | .key]) as $unanswered
      | ([.accounts | to_entries[] | select(.value == "enabled") | .key]) as $enabled
      | (if $unanswered != [] then
           unknown("\($ns) admin accounts"; "Kanidm admin accounts enabled"; "no answer for \($unanswered | join(", "))")
         else
           finding("cluster"; "\($ns) admin accounts"; $enabled != []; 4; "Kanidm admin accounts enabled";
             if $enabled == [] then "disabled"
             else "\($enabled | join(", ")) enabled, which suveraen-idm sync \($tenant) disables"
             end)
         end),
        # A long-running Kanidm's log no longer reaches back to its start, where it ran them, and a client can fill
        # one until the kubelet rotates it: a start whose run no check here read counts as failed once it had time.
        (.started as $started
         | ($judged[$tenant].upgrade // []) as $undone
         | (.migrations // ($judged[$tenant] | select(.started == $started) | .migrations) // null) as $run
         | if $run != null then
             ([$run.failed[], ($run | select(.denied > 0) | "\(.denied) changes skipped to entries it may not see")]
              | join("; ")) as $what
             | ($undone + [$what | select(. != "") | "as it started: \(.)"]) as $wrong
             | finding("cluster"; "\($ns) migrations"; $wrong != []; 4; "Kanidm migrations failed";
                 if $wrong == [] then "applied every file as it started" else $wrong | join("; ") end)
           elif $started == null then
             unknown("\($ns) migrations"; "Kanidm migrations failed"; "no start of a running container read")
           elif $c.now - ($started | time) > $c.grace then
             finding("cluster"; "\($ns) migrations"; true; 4; "Kanidm migrations failed";
               $undone + ["nothing here read how it ran them as it started at \($started), which counts as failed;"
                 + " restarting it runs them again"] | join("; "))
           else
             unknown("\($ns) migrations"; "Kanidm migrations failed";
               "nothing here read yet how it ran them as it started at \($started)")
           end),
        finding("cluster"; "\($ns) IDs"; .ids != []; 4; "Kanidm IDs invalid";
          if .ids == [] then "each a UUID of its own from Kanidm's dynamic range on" else .ids | join("; ") end),
        (.clients[]
          | if .secret | IN("unknown", "missing") then
              unknown("\($ns)/\(.client)"; "Kanidm clients out of sync";
                if .secret == "missing" then "the app has no Secret sso" else "no answer to the probe" end)
            elif .secret == "unusable" then
              finding("cluster"; "\($ns)/\(.client)"; true; 4; "Kanidm clients out of sync";
                "sso-\(.app) names no client suveraen-idm can use")
            else
              [if .secret == "wrong" then "the secret in the app's Secret sso is wrong for Kanidm"
               elif .secret == "placeholder" then "the app's Secret sso still holds the placeholder"
               elif .secret == "invalid" then "the app's Secret sso holds no secret Kanidm makes"
               else empty end,
               (select(.flags | not) | "its flags are not applied")] as $wrong
              | finding("cluster"; "\($ns)/\(.client)"; $wrong != []; 4; "Kanidm clients out of sync";
                  if $wrong == [] then "in sync" else "\($wrong | join(", ")); run suveraen-idm sync \($tenant)" end)
            end)
    end;

# Why suveraen-idm check left part of the tenants' Kanidm unchecked, all but migrations, which count as failed once
# they stay untold too long, or null.
def unchecked($idm; $rows):
  [$rows[] | select(.[2] == "unknown" and (.[1] | endswith(" migrations") | not)) | .[1]] as $parts
  | if ($idm | type) != "object" then "no answer from suveraen-idm check"
    elif $idm.busy then "another suveraen-idm run held its lock"
    elif $idm.failed != null then "suveraen-idm check: \($idm.failed)"
    elif $parts != [] then "nothing told of \($parts | join(", "))"
    else null
    end;

.now as $now
| .spec as $spec
| .files as $files
| .state as $state
| .cluster as $k
| ($k.unreadable // null) as $unreadable
# read lists only the servers and the volumes VolSync copies.
| [$k.nodes.items // [] | .[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
    | .metadata.name] as $ready
# The first Ready server by name checks the cluster, so a cluster of three alerts once; with none Ready, each that
# reads it does.
| (if $unreadable != null then "unreadable"
   elif $ready == [] or ($ready | min) == $spec.host then "evaluated"
   else "skipped"
   end) as $scope
| {now: $now, grace: $spec.missingGrace, stale: $spec.cephStaleAfter, cronjobs: ($k.cronjobs // {})} as $c
| (($k.idm.tenants? | type) == "array") as $told
| ($state.kanidmJudged // {} | if $told then judged($k.idm; .) end) as $judged
| [kanidm($c; $k.idm; $judged)] as $kanidm
| unchecked($k.idm; $kanidm) as $why
# Whether suveraen-idm check told of the tenants' Kanidm at all, and whether in full, which the report keeps the time
# of.
| ["cluster", $scope],
  (select($unreadable == null and $told) | ["kanidm", "answered"]),
  (select($unreadable == null and $why == null) | ["kanidm", "checked"]),
  ([
    ($spec.files | to_entries[]
      | .key as $name
      | .value.maxAge as $max
      | ($files[$name] // null) as $mtime
      | if $mtime != null then
          finding("host"; $name; $now - $mtime > $max; 4; "backups late";
            "last \($mtime | floor | since($now)), limit \($max | span)")
        else
          ($state.firstSeen[$name] // $now) as $seen
          | finding("host"; $name; $now - $seen > $max; 4; "backups late";
              "missing since \($seen | since($now)), limit \($max | span)")
        end),
    (if $unreadable == null then finding("host"; "cluster status"; false; 4; "cluster status unreadable"; "read")
     else
       ($state.lastRead // $now) as $read
       | finding("host"; "cluster status"; $now - $read > $spec.unreadableAfter; 4; "cluster status unreadable";
           "last read \($read | since($now)), limit \($spec.unreadableAfter | span): \($unreadable)")
     end),
    (select($scope == "evaluated")
      | postgres($c; $k), volumes($c; $k), (select($k.cephcluster != null) | ceph($c; $k.cephcluster)), $kanidm[],
        (($state.kanidmChecked // $now) as $checked
         | finding("cluster"; "Kanidm check"; $why != null and $now - $checked > $spec.unreadableAfter; 4;
             "Kanidm unchecked";
             if $why == null then "every tenant's Kanidm checked"
             else "every tenant's Kanidm last checked \($checked | since($now)), limit \($spec.unreadableAfter | span):"
               + " \($why)"
             end)))
  ] | unique_by(.[0:2])[]),
  (select($unreadable == null and $told)
    | ["kanidm", "judged", ($judged | tojson)])
| map(tostring) | join("\t")
