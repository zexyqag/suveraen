# What the rules on this server's own metrics found, as suveraen-metrics check read them from vmalert (metrics.nix):
# each alert that fires is late under its rule's name and key, and one still pending stands as it was found last, as
# does every finding of a rule that reads what an alert, pending or firing, names as lost. The rules are checked while
# the Watchdog fires and was evaluated within its last ten intervals before they were read, and no rule fails; until
# then every finding here stands, and once that lasts longer than unreadableAfter, it alerts.
include "rows";

def detail($why; $at; $c):
  "rules unchecked since \($at | since($c.now)), limit \($c.spec.unreadableAfter | span): \($why)";

def check($c):
  $c.told.metrics as $m
  | [$m.rules[]?] as $rules
  | (first($rules[] | select(.name == "Watchdog")) // null) as $dog
  | (if $dog != null and any($dog.alerts[]?; .state == "firing") then $dog.evaluated else null end) as $evaluated
  | [$rules[] | select(.health != "ok") | .name] as $failing
  | (if $m == null then "suveraen-metrics check gave nothing"
     elif $m.failed != null then "suveraen-metrics check: \($m.failed)"
     elif $evaluated == null then "the Watchdog doesn't fire"
     elif $m.checked - $evaluated > 10 * $m.interval then
       "the Watchdog was last evaluated \($evaluated | since($m.checked)) when the rules were read"
     elif $failing != [] then "rules failing: \($failing | join(", "))"
     else null
     end) as $why
  | if $why == null then
      finding("host"; "metric rules"; false; 4; "metric rules unchecked"; "every rule evaluated";
        "metric rules checked again"),
      complete("metric "),
      ($rules[]
        | select(.name != "Watchdog")
        | .name as $rule
        | .alerts[]
        | "metric \($rule)\(.annotations.key // "" | if . == "" then "" else " \(.)" end)" as $key
        | if .state == "firing" then
            finding("host"; $key; true; .priority | tonumber; .annotations.title; .annotations.detail;
              .annotations.cleared)
          else unknown("host"; $key; .annotations.title; "pending: \(.annotations.detail)"; .annotations.cleared)
          end),
      ([$rules[].alerts[] | .annotations.lost // empty] | unique[]) as $lost
      | $rules[]
      | select(any(.annotations.inputs // "" | split(" ")[]; . == $lost))
      | unknown("host"; "metric \(.name)"; .annotations.title; "held, as \($lost) can't be read";
          .annotations.cleared)
    else
      ($c.state.since["metric rules"] // $c.now) as $at
      | (if $c.now - $at > $c.spec.unreadableAfter then
           finding("host"; "metric rules"; true; 4; "metric rules unchecked"; detail($why; $at; $c);
             "metric rules checked again")
         else
           unknown("host"; "metric rules"; "metric rules unchecked"; detail($why; $at; $c); "metric rules checked again")
         end),
        first_seen("metric rules"; $at),
        hold("metric ")
    end;
