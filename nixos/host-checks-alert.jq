# From a run's findings (host-checks.jq, on stdin) and the late ones last alerted ($alerted): at most one alert, and
# what counts as late from now on (host-checks.nix). A notice is alerted in the run that finds it, and kept by none.
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
           "cluster status unreadable": "cluster status readable again",
           "Kanidm admin accounts enabled": "Kanidm admin accounts disabled again",
           "Kanidm migrations failed": "Kanidm migrations applied again",
           "Kanidm IDs invalid": "Kanidm IDs valid again",
           "Kanidm clients out of sync": "Kanidm clients in sync again",
           "Kanidm unchecked": "Kanidm checked again", "STUN unanswered": "STUN answered again",
           "mesh exit open": "mesh exits closed", "mesh exposed": "mesh no longer exposed",
           "mesh rule for All": "mesh rules for All gone",
           "mesh share outside the rules": "mesh shares within the rules again",
           "mesh peer in a foreign group": "mesh peers in their own groups again",
           "mesh groups outside the rules": "mesh groups within the rules again",
           "mesh admins outside the rules": "mesh admins within the rules again",
           "mesh tokens outside the rules": "mesh tokens within the rules again",
           "mesh powers outside the rules": "mesh powers within the rules again",
           "mesh settings outside the rules": "mesh settings within the rules again",
           "mesh below its version floor": "mesh at its version floor again", "mesh leaver still in": "mesh leavers out",
           "mesh unchecked": "mesh checked again", "mesh STUN port wrong": "mesh STUN port right again"}[$t]
        end)
  | unique
  | join("; ");

rows as $rows
| ($rows | map(select(length == 2 and .[0] == "cluster")) | first | .[1]) as $scope
| any($rows[]; . == ["kanidm", "answered"]) as $answered
| [$rows[] | select(length == 6) | finding] as $found
| [$alerted | rows[] | finding] as $before
| [$found[] | select(.status == "unknown") | .key] as $unknown
| [$found[] | select(.status != "unknown") | .key] as $told
# What the checks couldn't tell stands as it was found last, and only that: a finding without an answer, the Kanidm
# findings of a tenant whose Kanidm couldn't be looked at, or all of them while suveraen-idm check tells nothing.
| [$before[]
    | .key as $k
    | (.title | startswith("Kanidm ")) as $kanidm
    | select(($k | IN($told[]) | not)
        and (any($unknown[]; . as $u | $k == $u or ($kanidm and ($k | startswith($u + " ") or startswith($u + "/"))))
          or ($scope == "evaluated" and ($answered | not) and $kanidm)))]
  as $kept
| ([$found[] | select(.status == "late")] + $kept) as $current
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
| [$found[] | select(.status == "notice")] as $notices
| [$notices | select(. != []) | headline] as $noted
| (if $notices != [] then ["Noted:"] + ($notices | map(line)) else [] end) as $notes
| if $new != [] then
    {title: ([$new | headline] + $noted | join("; ")), priority: ($new + $notices | map(.priority) | max),
     # suveraen-alert keeps the end of a long message.
     body: ((if $still != [] then ["Still late:"] + ($still | map(line)) else [] end)
       + (if $back != [] then ["On time again: \($back | map(.key) | join(", "))"] else [] end)
       + ["New:"] + ($new | map(line)) + $notes | join("\n"))}
  elif $back != [] then
    {title: ([$back | cleared($late)] + $noted | join("; ")), priority: ([3] + ($notices | map(.priority)) | max),
     body: (["On time again: \($back | map(.key) | join(", "))"]
       + (if $late != [] then ["Still late:"] + ($late | map(line)) else [] end) + $notes | join("\n"))}
  elif $notices != [] then
    {title: ($notices | headline), priority: ($notices | map(.priority) | max),
     body: ((if $late != [] then ["Still late:"] + ($late | map(line)) else [] end) + $notes | join("\n"))}
  elif $late != [] and $now - $reminded >= $remind then
    {title: "still: \($late | headline)", priority: ($late | map(.priority) | max), body: ($late | map(line) | join("\n"))}
  else {title: null}
  end
| .late = ([$late[] | [.scope, .key, .status, .priority, .title, .detail] | map(tostring) | join("\t") + "\n"] | add // "")
