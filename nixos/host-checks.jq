# What host-checks.nix finds in what it read, judged at .now: a line saying whether this server checked the cluster
# (evaluated, skipped or unreadable), then one per finding with its scope, key, ok or late, priority, the title it
# alerts under and what was found, separated by tabs.

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
| ["cluster", $scope],
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
    (select($scope == "evaluated") | postgres($c; $k), volumes($c; $k), (select($k.cephcluster != null) | ceph($c; $k.cephcluster)))
  ] | unique_by(.[0:2])[])
| map(tostring) | join("\t")
