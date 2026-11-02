# What Kanidm's log, read whole, says of the last run of its migrations (suveraen-idm check, idm.sh): the files it gave
# up on and why, and how many changes it skipped without a word, to entries it may not see; null with no run in the
# log. Each run logs as one operation under an ID of its own, so another operation's errors, such as the probe's for a
# right secret, never count.
[splits("\n") | select(. != "")] as $lines
| ([$lines[] | select(test("^[0-9a-f-]{36} +INFO +migration_apply ")) | .[:36]] | last) as $run
| if $run == null then null
  else
    [$lines[] | select(startswith($run + " "))] as $ops
    # What migration_apply logs as it gives up on a file, or on all of them.
    | (["Failed to apply migration", "Invalid JSON SCIM Assertion", "Unable to read migration",
        "Duplicate migration UUID found", "Unable to read directory entries"] | join("|")) as $gave_up
    | {failed: [$ops[] | (capture("\\[error\\]: (?<what>\($gave_up))") | .what) as $what
        | ((capture("path: .*/(?<file>[0-9]{2}-[a-z0-9-]+\\.json)") | .file) // null) as $file
        | (if $what == "Failed to apply migration" then (capture("err: (?<err>[A-Za-z0-9_]+)") | .err) // $what
           else $what end) as $why
        | [$file // empty, $why] | join(": ")],
       denied: [$ops[] | select(contains("no entries were released"))] | length}
  end
