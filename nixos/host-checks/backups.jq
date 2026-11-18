# How old this server's backup files are, and where it checks the cluster, how old each tenant's WAL archiving, base
# backups, off-site copies, checks and volume copies are, against what their templates allow (suveraen/max-age).
include "rows";

def late($scope; $key; $late; $detail):
  finding($scope; $key; $late; 4; "backups late"; $detail; "backups on time again");

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
      | late("cluster"; $key; $c.now - $made > $c.grace;
          "no valid suveraen/max-age (\($set | tojson)) since \($made | since($c.now)), grace \($c.grace | span)")
    else
      f as $found
      | late("cluster"; $key; $found.age > $max; "\($found.detail), limit \($max | span)")
    end;

# Something the cluster should hold for what was made at $made, and doesn't.
def missing($c; $key; $made; $what):
  late("cluster"; $key; $c.now - $made > $c.grace;
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

def check($c):
  ($c.spec.files | to_entries[]
    | .key as $name
    | .value.maxAge as $max
    | ($c.files[$name] // null) as $mtime
    | if $mtime != null then
        late("host"; $name; $c.now - $mtime > $max; "last \($mtime | floor | since($c.now)), limit \($max | span)")
      else
        ($c.state.firstSeen[$name] // $c.now) as $seen
        | late("host"; $name; $c.now - $seen > $max; "missing since \($seen | since($c.now)), limit \($max | span)")
      end),
  (select($c.scope == "evaluated")
    | {now: $c.now, grace: $c.spec.missingGrace, cronjobs: ($c.cluster.cronjobs // {})} as $b
    | postgres($b; $c.cluster), volumes($b; $c.cluster));
