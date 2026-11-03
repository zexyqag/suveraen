# What host-checks.nix finds in what it read, judged at .now: a line saying whether this server checked the cluster
# (evaluated, skipped or unreadable), one when suveraen-idm check told of the tenants' Kanidm and one when it told of
# every one in full, then one per finding with its scope, key, ok, late, unknown or notice, priority, the title it
# alerts under and what was found, separated by tabs, and last, when it told of them, what the report keeps of how
# each ran its migrations as it started and what its own upgrades left undone, and when that changed, what it keeps of
# each tenant's mesh.

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

# What changed, which is told once and never stands (host-checks-alert.jq).
def notice($key; $title; $detail): ["cluster", $key, "notice", 3, $title, ($detail | gsub("[\t\n\r]+"; " "))];

def minor: split(".")[0:2];

# Whether each of this server's addresses answered a STUN binding request, where it answers them.
def stun($spec; $probes):
  $spec.stun // empty
  | .port as $port
  | .addresses[]
  | ($probes[.] // {answered: false, why: "not probed"}) as $probe
  | finding("host"; "STUN \(.)"; $probe.answered | not; 4; "STUN unanswered";
      if $probe.answered then "answered on UDP \($port)" else "no answer on UDP \($port): \($probe.why)" end);

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

# A release's version as numbers to compare, or null for what names none.
def release: [. // "" | capture("^v?(?<v>[0-9]+(\\.[0-9]+)*)").v | split(".") | map(tonumber) | (. + [0, 0])[0:3]]
  | first;

def tagged($kind): [capture("^\($kind)-(?<tag>[0-9a-f]{6})$").tag] | first;

def many($one; $more): if . == 1 then "1 \($one)" else "\(.) \($more)" end;

# The parts of a tenant's mesh the operator's rules hold it to, each a finding of its own, with the title it alerts
# under.
def meshtitles:
  {exit: "mesh exit open", public: "mesh exposed", all: "mesh rule for All", share: "mesh share outside the rules",
   foreign: "mesh peer in a foreign group", home: "mesh groups outside the rules",
   admins: "mesh admins outside the rules", tokens: "mesh tokens outside the rules",
   powers: "mesh powers outside the rules", settings: "mesh settings outside the rules",
   floor: "mesh below its version floor", leaver: "mesh leaver still in", changed: "mesh access changed",
   check: "mesh unchecked"};

# What changed between two summaries of who can reach what: policies and networks by ID, groups by tag or ID, people
# by their Kanidm IDs.
def changes($was; $now):
  def keyed($what; $one; f):
    ($was[$what] // {}) as $a | ($now[$what] // {}) as $b
    | ($b | keys[] as $k | select($a | has($k) | not) | "\($one) \($k) added"),
      ($a | keys[] as $k | select($b | has($k) | not) | "\($one) \($k) gone"),
      ($b | keys[] as $k | select(($a | has($k)) and $a[$k] != $b[$k]) | "\($one) \($k): \([$a[$k], $b[$k]] | f)");
  [keyed("policies"; "policy"; "changed"), keyed("networks"; "network"; "changed"),
   keyed("groups"; "group"; [(select(.[0].peers != .[1].peers) | "\(.[0].peers) to \(.[1].peers) peers"),
     (select(.[0].resources != .[1].resources) | "\(.[0].resources) to \(.[1].resources) resources")] | join(", ")),
   keyed("users"; "person"; [(select(.[0].devices != .[1].devices) | "\(.[0].devices) to \(.[1].devices) devices"),
     (select(.[0].unexpiring != .[1].unexpiring)
       | "\(.[0].unexpiring // 0) to \(.[1].unexpiring) devices that never sign in again"),
     (select(.[0].blocked != .[1].blocked) | if .[1].blocked then "blocked" else "unblocked" end),
     (select(.[0].pending != .[1].pending) | if .[1].pending then "pending approval" else "approved" end)]
     | join(", ")),
   ({setupKeys: "setup keys", routes: "routes"} | to_entries[] | select($was[.key] != $now[.key])
     | "\(.value): \($was[.key]) to \($now[.key])")];

# A tenant's mesh as suveraen-mesh check read it (mesh.sql), with how Kanidm answered for its people, judged by the
# operator's rules; and the state it keeps from one run to the next ($was): the owner and each person's own tag as
# first seen here, and who can reach what. Findings name policies, groups, peers, networks, resources and keys by their
# IDs, and people by their Kanidm IDs and tags, never by name.
def mesh($spec; $t; $m; $people; $was):
  "\($t)-netbird" as $ns
  | ($m.groups | INDEX(.id)) as $groups
  | ($m.users | INDEX(.id)) as $users
  | ($groups | map_values(.name | tagged("own")) | with_entries(select(.value != null))) as $own
  | ($groups | map_values(.name | tagged("home")) | with_entries(select(.value != null))) as $home
  | (reduce $m.groups[] as $g ({}; reduce $g.peers[] as $p (.; .[$p] += [$g.id]))) as $in
  # Boxes join by a setup key, and belong to no one.
  | [$m.peers[] | select(.user == null) | .id] as $boxes
  | def box: IN($boxes[]);
    # A group by its tag, or NetBird's own All, else by its ID: the owner chooses a group's name.
    def named: if $own[.] != null then "own-\($own[.])" elif $home[.] != null then "home-\($home[.])"
      elif $groups[.].name == "All" then "All" else . end;
    def tags: [$in[.][]? | $own[.] // $home[.] // empty] | unique;
    def ports: (.ports // []) != [] and (.portRanges // []) == [];
    def joins: if . == [] then "no group" else map(named) | join(", ") end;
  ($m.networks | map(.id as $n | .resources[] | {key: .id, value: $n}) | from_entries) as $network
  # The tags whose home boxes route each network.
  | ($m.networks | map({key: .id, value: [.routers[].peer // empty | tags[]] | unique}) | from_entries) as $routed
  | [$m.policies[] | .id as $p | .rules[] | {policy: $p} + .] as $rules
  # What a rule leads to: each group it names and the resources the group holds, which NetBird routes to the rule's
  # sources too, and its peer or resource, with the tags they belong to, and whether they hold a box.
  | def reached:
      ((.destinations // [])[] as $g
        | {what: "group \($g | named)", group: $g, tags: [$own[$g] // $home[$g] // empty],
           holds: ($home[$g] != null or any($groups[$g].peers[]?; box))},
          ($groups[$g].resources // [] | .[]
            | {what: "\(.Type) \(.ID) in group \($g | named)", resource: .Type,
               tags: ($routed[$network[.ID] // ""] // []), holds: false})),
      (.destinationResource // {} | select((.ID // "") != "")
        | if .Type == "peer" then {what: "peer \(.ID)", tags: (.ID | tags), holds: (.ID | box)}
          else {what: "\(.Type) \(.ID)", resource: .Type, tags: ($routed[$network[.ID] // ""] // []), holds: false}
          end);
  ($users | map_values([.autoGroups // [] | .[] | select($own[.] != null)])) as $ownGroups
  | ($ownGroups | map_values(if length == 1 then $own[.[0]] else null end)) as $tag
  | [$m.users[] | select(.blocked or .service | not)] as $active
  | [$m.users[] | select(.role == "owner") | .id] as $owners
  | ($spec.mesh.minimumClient | release) as $floor
  | [$m.postureChecks[] | select((.checks.NBVersionCheck.MinVersion | release) as $v | $v != null and $v >= $floor)
      | .id] as $floorChecks
  # A NetBird ID that is no Kanidm ID names no one there.
  | ($active | map({key: .id,
      value: (if .id | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$") then
        $people[.id]? // "unknown" else "gone" end)}) | from_entries) as $kanidm
  | def left: $kanidm[.] | IN("expired", "gone");
    def part($name; $problems; $fine):
      finding("cluster"; "\($ns) \($name)"; $problems != []; 4; meshtitles[$name];
        if $problems == [] then $fine else $problems | join("; ") end);
  {owner: ($was.owner // (if ($owners | length) == 1 then $owners[0] else null end)),
   tags: ($users | with_entries(.value = ($was.tags[.key] // $tag[.key]) | select(.value != null))),
   access: {
     policies: [$m.policies[] | select(.enabled) | {key: .id, value: [.rules[] | select(.enabled)
       | {from: [.sources // [] | .[] | named], to: [.destinations // [] | .[] | named],
          fromResource: ([.sourceResource // {} | select((.ID // "") != "") | "\(.Type) \(.ID)"] | first),
          toResource: ([.destinationResource // {} | select((.ID // "") != "") | "\(.Type) \(.ID)"] | first),
          action, protocol, ports: (.ports // []), portRanges: (.portRanges // []), bidirectional}]}] | from_entries,
     groups: [$m.groups[] | {key: (.id | named), value: {peers: (.peers | length),
       resources: (.resources // [] | length)}}] | from_entries,
     networks: [$m.networks[] | {key: .id, value: {routers: [.routers[] | [.peer, .peerGroups]],
       resources: [.resources[] | [.id, .type, .enabled, .digest]]}}] | from_entries,
     users: [$m.users[] | .id as $u | {key: $u, value: {devices: ([$m.peers[] | select(.user == $u)] | length),
       unexpiring: ([$m.peers[] | select(.user == $u and (.loginExpiry | not))] | length), blocked, pending}}]
       | from_entries,
     setupKeys: ($m.setupKeys | length),
     routes: ($m.routes | length)}} as $state
  | {state: $state, findings: [
      part("exit"; [
        ($m.routes[] | "route \(.), which leads anywhere through its router"),
        ($m.networks[].resources[]
          | if .type == "domain" then "resource \(.id) is a domain"
            elif .family != 4 then "resource \(.id) is not IPv4"
            elif .private | not then "resource \(.id) is outside the private ranges"
            elif .maskLength < 16 then "resource \(.id) is wider than /16"
            else empty end),
        ($m.networks[] | .id as $n | select(any(.routers[]; (.peerGroups // []) != [])) | "network \($n) routes by group"),
        ($m.counts.agentNetwork | select(. > 0) | "NetBird's agent network holds \(many("row"; "rows"))")];
        "no route, and nothing routed beyond a home's private range"),
      part("public"; [
        ($m.counts | to_entries[] | {proxyTokens: ["proxy token", "proxy tokens"],
            services: ["reverse-proxy service", "reverse-proxy services"],
            targets: ["reverse-proxy target", "reverse-proxy targets"],
            domains: ["reverse-proxy domain", "reverse-proxy domains"], proxies: ["proxy", "proxies"],
            accessLog: ["reverse-proxy log entry", "reverse-proxy log entries"], invites: ["invite", "invites"]}[.key]
            as $what
          | select($what != null and .value > 0) | .value | many($what[0]; $what[1])),
        ($m.peers[] | select(.embeddedProxy) | "peer \(.id) is a proxy"),
        ($m.settings // {} | select(.peerExpose) | "Peer Expose on")];
        "no proxy, service or invite"),
      part("all"; [$rules[] | select(any((.sources // []), (.destinations // []) | .[]; $groups[.].name == "All"))
        | "policy \(.policy) names All"] | unique; "no rule names All"),
      part("share"; [$rules[] | . as $r | (.sources // []) as $from
        | if ($from | length) != 1 or $own[$from[0]] == null or (.sourceResource.ID // "") != "" then
            "policy \(.policy) is not from one person's own group"
          else
            $own[$from[0]] as $s
            | reached
            | if any(.tags[]; . == $s) then
                select(.holds and ($r | ports | not)) | "policy \($r.policy) reaches \(.what) without ports"
              elif .group != null then "policy \($r.policy) reaches \(.what), not its own"
              elif .resource != null and .resource != "host" then
                "policy \($r.policy) reaches \(.what), which no box of own-\($s) routes"
              else
                .what as $what
                | [(select($r.bidirectional) | "both ways"),
                   (select($r.protocol | IN("tcp", "udp") | not) | "over \($r.protocol)"),
                   (select($r | ports | not) | "without ports")]
                | select(. != []) | "policy \($r.policy) reaches \($what), not its own, \(join(", "))"
              end
          end] | unique; "every rule from one person's own group, and to another's one way, on ports"),
      part("foreign"; [
        ($m.peers[] | .id as $p | [$in[$p][]? | select($own[.] != null or $home[.] != null)] as $mine
          | if .user == null then
              ($mine[] | select($own[.] != null) | "box \($p) in \(named)"),
              ([$mine[] | select($home[.] != null)] | select(length > 1) | "box \($p) in \(joins)")
            else
              .user as $u
              | $mine[] | select($home[.] != null or (IN($ownGroups[$u] // [] | .[]) | not))
              | "peer \($p) of \($u) in \(named)"
            end),
        ($ownGroups | to_entries | map(.key as $u | .value[] | {group: ., user: $u}) | group_by(.group)[]
          | select(length > 1) | "\(map(.user) | join(", ")) share \(.[0].group | named)"),
        ($tag | to_entries[] | select(.value != null and ($was.tags[.key] // .value) != .value)
          | "\(.key) is own-\(.value), first seen as own-\($was.tags[.key])"),
        ($m.groups[] | .id as $g | ($own[$g] // $home[$g]) as $groupTag | select($groupTag != null)
          | .resources // [] | .[] | select(any(($routed[$network[.ID] // ""] // [])[]; . == $groupTag) | not)
          | "\(.Type) \(.ID) in \($g | named), which no box in home-\($groupTag) routes")];
        "every device in its own person's group, every box in one home's, and a group's resources routed by its home's"
        + " box"),
      part("home"; [
        ($rules[] | . as $r
          | ((.sources // [])[] | select($home[.] != null or any($groups[.].peers[]?; box))
              | "policy \($r.policy) is from \(named), which holds a box"),
            (.sourceResource // {} | select(.Type == "peer" and (.ID | box)) | "policy \($r.policy) is from box \(.ID)"),
            (select(.bidirectional) | reached | select(.holds) | "policy \($r.policy) reaches \(.what) both ways")),
        ($m.setupKeys[] | (.autoGroups // []) as $g | select(($g | length) != 1 or $home[$g[0]] == null)
          | "setup key \(.id) joins \($g | joins)"),
        ($active[] | select(.pending | not) | (.autoGroups // []) as $g
          | select((($g | length) != 1 or $own[$g[0]] == null) and (.role != "owner" or $g != []))
          | "\(.id) joins \($g | joins)")] | unique;
        "no box a source, every key into one home's group, every person into their own"),
      part("admins"; [
        ($m.users[] | select(.role | IN("owner", "user") | not) | "\(.id) is \(.role)"),
        ($m.users[] | select(.service) | "service user \(.id)"),
        ($owners | select(length > 1) | "owners \(join(", "))"),
        ($was.owner // empty | select(IN($owners[]) | not)
          | "owner \($owners | if . == [] then "none" else join(", ") end), first seen \(.): to keep one moved there"
            + " on purpose, remove \($t) from /var/lib/host-checks/mesh.json on each server")];
        "one owner, as first seen, and people"),
      part("tokens"; [
        ($m.pats[] | "token \(.id) of \(.user)"),
        ($m.setupKeys[] | .id as $key
          | [(select(.type != "one-off") | .type),
             (select(.usageLimit != 1) | "\(if .usageLimit == 0 then "unlimited" else .usageLimit end) uses"),
             (if .validSeconds == null then "never expires"
              elif .validSeconds > 86400 then "valid \(.validSeconds | floor | span)" else empty end)]
          | select(. != []) | "setup key \($key): \(join(", "))")];
        "no token, every setup key for one box within a day"),
      part("powers"; [
        ($m.postureChecks[] | .id as $check
          | [.checks // {} | to_entries[] | select(.value != null and .key != "NBVersionCheck") | .key]
          | select(. != []) | "posture check \($check) checks \(join(", "))"),
        ($m.counts | to_entries[] | {jobs: ["job", "jobs"], nameserverGroups: ["nameserver group", "nameserver groups"],
            zones: ["DNS zone", "DNS zones"], records: ["DNS record", "DNS records"]}[.key] as $what
          | select($what != null and .value > 0) | .value | many($what[0]; $what[1])),
        ($rules[] | select(.protocol == "netbird-ssh" or (.authorizedGroups // {}) != {} or (.authorizedUser // "") != "")
          | "policy \(.policy) grants SSH")] | unique;
        "no check but the version, no job, DNS or SSH"),
      part("settings"; [($m.settings // empty
        | (select(.userApproval | not) | "user approval off"),
          (select(.jwtGroups) | "JWT groups on"),
          (select(.groupsPropagation | not) | "groups propagation off"),
          (select(.metricsPush) | "metrics push on"),
          (select(.autoUpdate != "disabled") | "auto-update \(.autoUpdate)"),
          (if .loginExpiry | not then "login expiry off"
           elif .loginExpirySeconds > $spec.mesh.loginExpiry then
             "login expiry \(.loginExpirySeconds | span), above \($spec.mesh.loginExpiry | span)"
           else empty end),
          (select((.ipv6Groups // []) != []) | "IPv6 for \(.ipv6Groups | joins)"),
          (select((.dnsDomain // "") != "") | "an account DNS domain")),
        # Boxes join by setup keys, whose peers NetBird never expires.
        ($m.peers[] | select(.user != null and (.loginExpiry | not)) | "peer \(.id) of \(.user) never signs in again")];
        "as the rules set them"),
      part("floor"; [
        ($m.policies[] | select(.enabled and (any(.postureChecks // [] | .[]; IN($floorChecks[])) | not))
          | "policy \(.id) checks for no version from \($spec.mesh.minimumClient)"),
        ($m.peers[] | select((.version | release) as $v | $v == null or $v < $floor)
          | "peer \(.id) runs \(.version // "no release")")];
        "every policy checks for \($spec.mesh.minimumClient) or later, which every peer runs"),
      ([$kanidm | to_entries[] | select(.value == "unknown") | .key] as $unanswered
       | if $unanswered != [] then
           unknown("\($ns) leaver"; meshtitles.leaver; "no answer from Kanidm for \($unanswered | join(", "))")
         else
           part("leaver"; [
             ($active[] | select(.id | left) | $tag[.id] as $tg
               | "\(.id)\(if $tg then " of own-\($tg)" else "" end) is \($kanidm[.id]) at Kanidm: block them"
                 + (if $tg then ", and delete the peers in home-\($tg)" else "" end)),
             ($m.groups[] | select($home[.id] != null and .peers != []) | $home[.id] as $tg
               | select(any($active[]; $tag[.id] == $tg and (.id | left | not)) | not)
               | "home-\($tg) holds \(.peers | length | many("peer"; "peers")) of no one still in: delete them")];
             "everyone still in at Kanidm")
         end),
      (if $was.access == null then finding("cluster"; "\($ns) changed"; false; 3; meshtitles.changed; "first seen")
       else changes($was.access; $state.access) as $changed
         | if $changed == [] then finding("cluster"; "\($ns) changed"; false; 3; meshtitles.changed; "as before")
           else notice("\($ns) changed"; meshtitles.changed; $changed | join("; "))
           end
       end)
    ]};

# Each tenant's mesh as suveraen-mesh check told of it (mesh.nix), or for the tenants it told of before, unchecked when
# it told nothing: the findings, which a tenant left unchecked has none of, and that stand as they were (host-checks.nix)
# until it has been unchecked too long; the cluster's STUN port where a tenant runs a mesh; and what the report keeps.
def meshes($now; $spec; $told; $was):
  (($told.tenants? | type) == "array") as $answered
  | (if $answered then $told.tenants
     elif ($told | type) == "object" and $told.failed != null then
       [$was | keys[] | {tenant: ., unchecked: "suveraen-mesh check: \($told.failed)"}]
     else [$was | keys[] | {tenant: ., unchecked: "no answer from suveraen-mesh check"}]
     end) as $tenants
  | [$tenants[] | .tenant as $t | ($was[$t] // {}) as $w
      | (if .unchecked != null then
           .unchecked as $why
           | {why: $why, state: $w,
              findings: [meshtitles | keys[] | select(. != "check") as $n
                | unknown("\($t)-netbird \($n)"; meshtitles[$n]; "unchecked: \($why)")]}
         else
           mesh($spec; $t; .mesh; .people; $w | del(.uncheckedSince))
           | .why = ([.findings[] | select(.[2] == "unknown") | .[5]] | first)
         end) as $r
      | ($w.uncheckedSince // $now) as $since
      | {tenant: $t, state: ($r.state + (if $r.why != null then {uncheckedSince: $since} else {} end)),
         findings: ($r.findings + [finding("cluster"; "\($t)-netbird check"; $r.why != null
           and $now - $since > $spec.unreadableAfter; 4; meshtitles.check;
           if $r.why == null then "checked"
           else "unchecked since \($since | since($now)), limit \($spec.unreadableAfter | span): \($r.why)" end)])}]
    as $judged
  | {state: ($judged | map({key: .tenant, value: .state}) | from_entries),
     findings: [$judged[].findings[]],
     host: [
       if $answered then
         $told.stunPort as $port | ($spec.stun.port // null) as $mine
         | select($told.tenants != [])
         | finding("host"; "mesh STUN port"; $port == null or $mine == null or ($port | tostring) != ($mine | tostring);
             4; "mesh STUN port wrong";
             if $port == null then "the cluster's settings name no STUN_PORT"
             elif $mine == null then "the cluster's STUN_PORT is \($port), where this server answers no STUN"
             elif ($port | tostring) != ($mine | tostring) then
               "the cluster's STUN_PORT is \($port), where this server answers STUN on UDP \($mine)"
             else "UDP \($mine), the cluster's STUN_PORT"
             end)
       elif $was != {} then
         ["host", "mesh STUN port", "unknown", 4, "mesh STUN port wrong",
          ($tenants[0].unchecked | gsub("[\t\n\r]+"; " "))]
       else empty
       end]};

.now as $now
| .spec as $spec
| .files as $files
| .stun as $probes
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
| ($state.mesh // {}) as $meshWas
| (if $unreadable == null then meshes($now; $spec; $k.mesh; $meshWas) else {state: $meshWas, findings: [], host: []} end)
  as $mesh
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
    stun($spec; $probes),
    $mesh.host[],
    (if $unreadable == null then finding("host"; "cluster status"; false; 4; "cluster status unreadable"; "read")
     else
       ($state.lastRead // $now) as $read
       | finding("host"; "cluster status"; $now - $read > $spec.unreadableAfter; 4; "cluster status unreadable";
           "last read \($read | since($now)), limit \($spec.unreadableAfter | span): \($unreadable)")
     end),
    (select($scope == "evaluated")
      | postgres($c; $k), volumes($c; $k), (select($k.cephcluster != null) | ceph($c; $k.cephcluster)), $kanidm[],
        $mesh.findings[],
        (($state.kanidmChecked // $now) as $checked
         | finding("cluster"; "Kanidm check"; $why != null and $now - $checked > $spec.unreadableAfter; 4;
             "Kanidm unchecked";
             if $why == null then "every tenant's Kanidm checked"
             else "every tenant's Kanidm last checked \($checked | since($now)), limit \($spec.unreadableAfter | span):"
               + " \($why)"
             end)))
  ] | unique_by(.[0:2])[]),
  (select($unreadable == null and $told)
    | ["kanidm", "judged", ($judged | tojson)]),
  (select($mesh.state != $meshWas) | ["mesh", "state", ($mesh.state | tojson)])
| map(tostring) | join("\t")
