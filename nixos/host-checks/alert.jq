# From a run's findings (judge.jq, on stdin) and the late ones last alerted ($alerted): at most one alert, and what
# counts as late from now on (host-checks.nix). A notice is alerted in the run that finds it, and kept by none.
def rows: split("\n") | map(select(. != "") | split("\t"));
def finding:
  {scope: .[0], key: .[1], status: .[2], priority: (.[3] | tonumber), title: .[4], detail: .[5], cleared: .[6],
   family: .[7]};
def line: "\(.key): \(.detail)";
# Each title once, with how many findings it stands for when more than one.
def headline: group_by(.title) | map(if length > 1 then "\(.[0].title): \(length)" else .[0].title end) | join("; ");
# A key and those it begins as a word or a path, such as a tenant's or a namespace's.
def under($key): .key == $key or (.key | startswith($key + " ") or startswith($key + "/"));
# What findings back say: each the title it names for that, or its key alone while a finding still late names the same.
def cleared($late):
  map(.cleared as $cleared | if any($late[]; .cleared == $cleared) then "\(.key) cleared" else $cleared end)
  | unique
  | join("; ");

rows as $rows
| ($rows | map(select(length == 2 and .[0] == "cluster")) | first | .[1]) as $scope
| [$rows[] | select(length == 8) | finding] as $found
| [$rows[] | select(length == 3 and (.[0] | IN("complete", "hold"))) | {kind: .[0], family: .[1], prefix: .[2]}]
  as $marks
| [$alerted | rows[] | finding] as $before
| [$found[] | select(.status == "unknown")] as $unknown
| [$found[] | select(.status != "unknown") | .key] as $told
# What the checks couldn't tell stands as it was found last, and only that: a finding without an answer and those of
# its family under its key, those under what their family could tell nothing of, and unread, the cluster's.
| [$before[]
    | . as $b
    | select((.key | IN($told[]) | not)
        and (any($unknown[]; .key as $u | .family == $b.family and ($b | under($u)))
          or any($marks[]; .prefix as $p | .kind == "hold" and .family == $b.family and ($b.key | startswith($p)))
          or ($scope == "unreadable" and .scope == "cluster")))]
  as $kept
| ([$found[] | select(.status == "late")] + $kept) as $late
| [$found[] | select(.status == "ok") | .key] as $ok
| [$found[].key] as $keys
# New, as is one whose priority rose since it was alerted.
| [$late[] | . as $l | select(any($before[]; .key == $l.key and .priority >= $l.priority) | not)] as $new
# What a family read all of and no longer finds has cleared, unless it stands as above; anything else no longer found
# went with what it was about.
| [$before[]
    | . as $b
    | select((.key | IN($ok[]))
        or ((.key | IN($keys[]) or IN($kept[].key) | not)
          and any($marks[];
            .prefix as $p | .kind == "complete" and .family == $b.family and ($b.key | startswith($p)))))]
  as $back
| [$late[] | select(.key | IN($new[].key) | not)] as $still
| [$found[] | select(.status == "notice")] as $notices
| [$notices | select(. != []) | headline] as $noted
| (if $notices != [] then ["Noted:"] + ($notices | map(line)) else [] end) as $notes
| (if $back != [] then ["Cleared: \($back | map(.key) | join(", "))"] else [] end) as $cleared
# suveraen-alert keeps the end of a long message, so what is still late comes first.
| if $new != [] then
    {title: ([$new | headline] + $noted | join("; ")), priority: ($new + $notices | map(.priority) | max),
     body: ((if $still != [] then ["Still late:"] + ($still | map(line)) else [] end) + $cleared
       + ["New:"] + ($new | map(line)) + $notes | join("\n"))}
  elif $back != [] then
    {title: ([$back | cleared($late)] + $noted | join("; ")), priority: ([3] + ($notices | map(.priority)) | max),
     body: ((if $late != [] then ["Still late:"] + ($late | map(line)) else [] end) + $cleared + $notes | join("\n"))}
  elif $notices != [] then
    {title: ($notices | headline), priority: ($notices | map(.priority) | max),
     body: ((if $late != [] then ["Still late:"] + ($late | map(line)) else [] end) + $notes | join("\n"))}
  elif $late != [] and $now - $reminded >= $remind then
    {title: "still: \($late | headline)", priority: ($late | map(.priority) | max), body: ($late | map(line) | join("\n"))}
  else {title: null}
  end
| .late = ([$late[] | [.scope, .key, .status, .priority, .title, .detail, .cleared, .family] | map(tostring)
    | join("\t") + "\n"] | add // "")
