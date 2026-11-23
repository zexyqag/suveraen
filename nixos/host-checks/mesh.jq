# Each tenant's mesh as suveraen-mesh check read it (mesh.sql), with how Kanidm answered for its people, judged by the
# operator's rules where this server checks the cluster, the cluster's STUN port where a tenant runs a mesh, and, when
# that changed, what the report keeps of each tenant's mesh.
include "rows";

# A release's version as numbers to compare, or null for what names none.
def release: [. // "" | capture("^v?(?<v>[0-9]+(\\.[0-9]+)*)").v | split(".") | map(tonumber) | (. + [0, 0])[0:3]]
  | first;

def tagged($kind): [capture("^\($kind)-(?<tag>[0-9a-f]{6})$").tag] | first;

# The parts of a tenant's mesh the operator's rules hold it to, each a finding of its own, with the title it alerts
# under and the one once it is ok again.
def meshtitles:
  {exit: ["mesh exit open", "mesh exits closed"], public: ["mesh exposed", "mesh no longer exposed"],
   all: ["mesh rule for All", "mesh rules for All gone"],
   share: ["mesh share outside the rules", "mesh shares within the rules again"],
   foreign: ["mesh peer in a foreign group", "mesh peers in their own groups again"],
   home: ["mesh groups outside the rules", "mesh groups within the rules again"],
   admins: ["mesh admins outside the rules", "mesh admins within the rules again"],
   tokens: ["mesh tokens outside the rules", "mesh tokens within the rules again"],
   powers: ["mesh powers outside the rules", "mesh powers within the rules again"],
   settings: ["mesh settings outside the rules", "mesh settings within the rules again"],
   floor: ["mesh below its version floor", "mesh at its version floor again"],
   leaver: ["mesh leaver still in", "mesh leavers out"],
   scrub: ["mesh inventory kept", "mesh inventory scrubbed again"],
   changed: ["mesh access changed", ""], check: ["mesh unchecked", "mesh checked again"]};

def untold($key; $part; $detail): meshtitles[$part] as [$t, $c] | unknown("cluster"; $key; $t; $detail; $c);

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
      meshtitles[$name] as [$title, $cleared]
      | finding("cluster"; "\($ns) \($name)"; $problems != []; 4; $title;
          if $problems == [] then $fine else $problems | join("; ") end; $cleared);
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
           untold("\($ns) leaver"; "leaver"; "no answer from Kanidm for \($unanswered | join(", "))")
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
      part("scrub"; [
        ($m.scrub.trigger | if . == null then "no trigger scrub on peers"
          elif .enabled != "O" then "trigger scrub disabled"
          elif .definition != "CREATE TRIGGER scrub BEFORE INSERT OR UPDATE ON public.peers FOR EACH ROW EXECUTE"
            + " FUNCTION scrub_peer()" then "trigger scrub is another: \(.definition)"
          else empty end),
        ($m.scrub.gone[] | "no column \(.), which the scrub blanks"),
        ($m.scrub.unreviewed[] | "column \(.) unreviewed"),
        ($m.scrub.unscrubbed | select(. != []) | "\(length | many("peer holds"; "peers hold")) what the scrub blanks: "
          + join(", ")),
        ($m.scrub.networkAddresses | select(. > 0) | "network_addresses holds \(many("row"; "rows"))")];
        "a trigger blanks every device's inventory as it is written, on the columns reviewed"),
      (meshtitles.changed[0] as $title
       | if $was.access == null then finding("cluster"; "\($ns) changed"; false; 3; $title; "first seen"; "")
         else changes($was.access; $state.access) as $changed
           | if $changed == [] then finding("cluster"; "\($ns) changed"; false; 3; $title; "as before"; "")
             else notice("cluster"; "\($ns) changed"; $title; $changed | join("; "))
             end
         end)
    ]};

# Each tenant's mesh as suveraen-mesh check told of it (mesh.nix), or for the tenants it told of before, unchecked when
# it told nothing: the findings, which a tenant left unchecked has none of, and that stand as they were (alert.jq)
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
                | untold("\($t)-netbird \($n)"; $n; "unchecked: \($why)")]}
         else
           mesh($spec; $t; .mesh; .people; $w | del(.uncheckedSince))
           | .why = ([.findings[] | select(.[2] == "unknown") | .[5]] | first)
         end) as $r
      | ($w.uncheckedSince // $now) as $since
      | {tenant: $t, state: ($r.state + (if $r.why != null then {uncheckedSince: $since} else {} end)),
         findings: ($r.findings + [meshtitles.check as [$title, $cleared]
           | finding("cluster"; "\($t)-netbird check"; $r.why != null and $now - $since > $spec.unreadableAfter; 4;
               $title;
               if $r.why == null then "checked"
               else "unchecked since \($since | since($now)), limit \($spec.unreadableAfter | span): \($r.why)" end;
               $cleared)])}]
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
             end;
             "mesh STUN port right again")
       elif $was != {} then
         unknown("host"; "mesh STUN port"; "mesh STUN port wrong"; $tenants[0].unchecked; "mesh STUN port right again")
       else empty
       end]};

def check($c):
  ($c.state.mesh // {}) as $was
  | (if ($c.cluster.unreadable // null) == null then meshes($c.now; $c.spec; $c.cluster.mesh; $was)
     else {state: $was, findings: [], host: []}
     end) as $mesh
  | $mesh.host[], (select($c.scope == "evaluated") | $mesh.findings[]),
    (select($mesh.state != $was) | ["mesh", "state", ($mesh.state | tojson)]);
