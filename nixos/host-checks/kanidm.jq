# Each tenant's Kanidm as suveraen-idm check found it (idm.nix), where this server checks the cluster: its admin
# accounts, how it ran its migrations as it started, the IDs they declare, and its clients; and whether it told of every
# one in full, which the report keeps the time of, and what it keeps of how each ran its migrations as it started and
# what its own upgrades left undone.
include "rows";

# The title each part alerts under, and the one once it is ok again.
def titles:
  {accounts: ["Kanidm admin accounts enabled", "Kanidm admin accounts disabled again"],
   migrations: ["Kanidm migrations failed", "Kanidm migrations applied again"],
   ids: ["Kanidm IDs invalid", "Kanidm IDs valid again"],
   clients: ["Kanidm clients out of sync", "Kanidm clients in sync again"],
   check: ["Kanidm unchecked", "Kanidm checked again"]};

def part($key; $part; $late; $detail): titles[$part] as [$t, $c] | finding("cluster"; $key; $late; 4; $t; $detail; $c);
def untold($key; $part; $detail): titles[$part] as [$t, $c] | unknown("cluster"; $key; $t; $detail; $c);

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

def kanidm($c; $idm; $judged):
  $idm.tenants[]?
  | .tenant as $tenant
  | "\($tenant)-kanidm" as $ns
  | if .unchecked != null then untold($ns; "check"; .unchecked)
    else
      ([.accounts | to_entries[] | select(.value == "unknown") | .key]) as $unanswered
      | ([.accounts | to_entries[] | select(.value == "enabled") | .key]) as $enabled
      | (if $unanswered != [] then
           untold("\($ns) admin accounts"; "accounts"; "no answer for \($unanswered | join(", "))")
         else
           part("\($ns) admin accounts"; "accounts"; $enabled != [];
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
             | part("\($ns) migrations"; "migrations"; $wrong != [];
                 if $wrong == [] then "applied every file as it started" else $wrong | join("; ") end)
           elif $started == null then
             untold("\($ns) migrations"; "migrations"; "no start of a running container read")
           elif $c.now - ($started | time) > $c.grace then
             part("\($ns) migrations"; "migrations"; true;
               $undone + ["nothing here read how it ran them as it started at \($started), which counts as failed;"
                 + " restarting it runs them again"] | join("; "))
           else
             untold("\($ns) migrations"; "migrations";
               "nothing here read yet how it ran them as it started at \($started)")
           end),
        part("\($ns) IDs"; "ids"; .ids != [];
          if .ids == [] then "each a UUID of its own from Kanidm's dynamic range on" else .ids | join("; ") end),
        (.clients[]
          | if .secret | IN("unknown", "missing") then
              untold("\($ns)/\(.client)"; "clients";
                if .secret == "missing" then "the app has no Secret sso" else "no answer to the probe" end)
            elif .secret == "unusable" then
              part("\($ns)/\(.client)"; "clients"; true; "sso-\(.app) names no client suveraen-idm can use")
            else
              [if .secret == "wrong" then "the secret in the app's Secret sso is wrong for Kanidm"
               elif .secret == "placeholder" then "the app's Secret sso still holds the placeholder"
               elif .secret == "invalid" then "the app's Secret sso holds no secret Kanidm makes"
               else empty end,
               (select(.flags | not) | "its flags are not applied")] as $wrong
              | part("\($ns)/\(.client)"; "clients"; $wrong != [];
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

def check($c):
  $c.cluster.idm as $idm
  | (($c.cluster.unreadable // null) == null) as $read
  | (($idm.tenants? | type) == "array") as $told
  | ($c.state.kanidmJudged // {} | if $told then judged($idm; .) end) as $judged
  | [kanidm({now: $c.now, grace: $c.spec.missingGrace}; $idm; $judged)] as $kanidm
  | unchecked($idm; $kanidm) as $why
  | ($c.state.since["Kanidm check"] // $c.now) as $unchecked
  | (select($c.scope == "evaluated")
      | $kanidm[],
        part("Kanidm check"; "check"; $why != null and $c.now - $unchecked > $c.spec.unreadableAfter;
          if $why == null then "every tenant's Kanidm checked"
          else "every tenant's Kanidm unchecked since \($unchecked | since($c.now)), limit"
            + " \($c.spec.unreadableAfter | span): \($why)"
          end),
        # While suveraen-idm check tells nothing, the tenants' Kanidm stand as they were found last.
        (select($told | not) | hold(""))),
    # Kept, whichever server checks the cluster, until every tenant's Kanidm is checked.
    (select($why != null or ($read | not)) | first_seen("Kanidm check"; $unchecked)),
    (select($read and $told) | ["kanidm", "judged", ($judged | tojson)]);
