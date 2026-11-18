# What host-checks.nix finds in what it read, judged at .now by each family of checks the server declares: families
# gives each family's name and rows (rows.jq) for what was read, with the scope it is checked in. The judge says first
# whether this server checked the cluster, evaluated, skipped or unreadable; then every family's findings, by scope and
# key, each with its family's name; what each family read all of, or could tell nothing of, with its name; what the
# report keeps for a family from one run to the next, and when the families first found what each key names wrong,
# while any is; and last that the checks are done.
def judge(families):
  (.cluster.unreadable // null) as $unreadable
  # read lists only the servers.
  | [.cluster.nodes.items // [] | .[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
      | .metadata.name] as $ready
  # The first Ready server by name checks the cluster, so a cluster of three alerts once; with none Ready, each that
  # reads it does.
  | (if $unreadable != null then "unreadable"
     elif $ready == [] or ($ready | min) == .spec.host then "evaluated"
     else "skipped"
     end) as $scope
  | [. + {scope: $scope} | families | .name as $name | .rows[] | {name: $name, row: .}] as $rows
  | ["cluster", $scope],
    ([$rows[] | select(.row | length == 7) | .row + [.name]] | unique_by(.[0:2])[]),
    ($rows[] | select(.row | length != 7 and .[0] != "since")
      | if .row[0] | IN("complete", "hold") then [.row[0], .name, .row[1]] else .row end),
    ([$rows[].row | select(length == 3 and .[0] == "since") | {key: .[1], value: .[2]}] | select(. != [])
      | ["since", "state", (from_entries | tojson)]),
    ["checks", "done"]
  | map(tostring)
  | join("\t");
