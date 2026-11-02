# What the start of Kanidm's log, with the kubelet's timestamps, says of the start of its container at $started
# (suveraen-idm check, idm.sh): the version it runs; the steps of its own upgrade that failed, null where it upgraded
# nothing; the files it gave up on and why; and how many changes it skipped without a word, to entries it may not see.
# Null when the log no longer reaches back to that start, tells of no run of one or the other, or Kanidm hasn't started
# its web server yet.
#
# Kanidm brings its own entries up to date only as it raises its domain level, at its very first start and its first on
# a new minor version: a step it gives up on, such as a builtin entry whose name a person holds, it logs, goes on from
# and never tries again. host-checks.jq keeps what such a start left undone.
#
# Kanidm writes what a client sends into its log as it is, line breaks too, so anyone who reaches it can add lines that
# look like any of its own. It runs its migrations once, as it starts, and logs that it starts its web server before it
# takes a connection, so only what comes before that line counts, and only in a log that begins as the container did:
# the kubelet keeps only the newest of the files it rotates a log into, and a client can fill one. The kubelet, not
# Kanidm, stamps each line, and Kanidm logs its first within moments of starting.

def seconds:
  capture("^(?<s>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?<f>[.][0-9]+)?(?<z>Z|[+-][0-9]{2}:[0-9]{2})$")
  | .z as $z
  | (.s + "Z" | fromdateiso8601) + ("0\(.f // "")" | tonumber)
    - (if $z == "Z" then 0 else ($z[1:3] | tonumber) * 3600 + ($z[4:6] | tonumber) * 60 | if $z[0:1] == "-" then -. end end);

# Null for anything but a time, so the filter always answers.
def time: first((try seconds), null);

def web: startswith("00000000-0000-0000-0000-000000000000 INFO ") and endswith(" [info]: Starting the web server...");

# Not splits, whose time grows with the square of the log's length.
[split("\n")[] | select(. != "") | capture("^(?<at>[^ ]+) (?<line>.*)$") // {at: null, line: .}] as $lines
| ($started | time) as $start
| ($lines[0].at | time) as $first
| ([range($lines | length) | select($lines[.].line | web)] | first) as $web
# The API gives the start in whole seconds, and a first line may come before it is recorded.
| if $start == null or $first < $start - 1 or $first >= $start + 5 or $web == null then null
  else
    [$lines[:$web][].line] as $own
    | ([$own[] | capture("^00000000-0000-0000-0000-000000000000 INFO .*\\[info\\]: Starting Kanidmd \\| version: "
        + "(?<v>[0-9]+[.][0-9]+[.][0-9]+[0-9A-Za-z.+-]*)$") | .v] | first) as $version
    | ([$own[] | select(test("^[0-9a-f-]{36} +INFO +system_initialisation ")) | .[:36]] | last) as $upgrade
    | ([$own[] | select(test("^[0-9a-f-]{36} +INFO +migration_apply ")) | .[:36]] | last) as $run
    | if $version == null or $upgrade == null or $run == null then null
      else
        [$own[] | select(startswith($upgrade + " "))] as $init
        | [$init[] | select(test("^[^ ]+ +ERROR "))] as $errors
        # The line a step logs as Kanidm goes on without it names the step; the lines before it, its causes.
        | ([$errors[] | capture("\\| err: (?<err>[A-Za-z0-9_]+)[^|]*\\| msg: \"(?<step>[A-Za-z0-9 ._-]+)\"$")
            | "Kanidm's upgrade to \($version), \(.step): \(.err)"] | unique) as $steps
        | [$own[] | select(startswith($run + " "))] as $ops
        # What migration_apply logs as it gives up on a file, or on all of them.
        | (["Failed to apply migration", "Invalid JSON SCIM Assertion", "Unable to read migration",
            "Duplicate migration UUID found", "Unable to read directory entries"] | join("|")) as $gave_up
        | {version: $version,
           upgrade: (if $steps != [] then $steps
             elif $errors != [] then ["Kanidm's upgrade to \($version), \($errors | length) errors naming no step"]
             elif any($init[]; test("^[^ ]+ +WARN .*\\[warn\\]: Domain level has been (raised|bootstrapped) to [0-9]+$"))
             then []
             else null end),
           failed: [$ops[] | (capture("\\[error\\]: (?<what>\($gave_up))") | .what) as $what
             | ((capture("path: .*/(?<file>[0-9]{2}-[a-z0-9-]+\\.json)") | .file) // null) as $file
             | (if $what == "Failed to apply migration" then (capture("err: (?<err>[A-Za-z0-9_]+)") | .err) // $what
                else $what end) as $why
             | [$file // empty, $why] | join(": ")],
           denied: [$ops[] | select(contains("no entries were released"))] | length}
      end
  end
