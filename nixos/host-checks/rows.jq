# The rows a family of checks gives the judge (judge.jq), and the times it judges by. A finding is its scope, host or
# cluster, its key, ok, late, unknown or notice, its priority, the title it alerts under, what was found, and the title
# it alerts under once it is ok again. A key names one finding of one family.
# Under jq 1.8.2 a function of a module that another module includes can't call one of its own, so none here does.

def time: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
# A time that may be missing.
def stamp: if . == null then null else sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 end;

# Seconds as a limit is written: 3d, 26h, 90m.
def span: if . % 86400 == 0 then "\(. / 86400)d" elif . % 3600 == 0 then "\(. / 3600)h" else "\(. / 60)m" end;

# A time, and how long before $now it was.
def since($now):
  ([$now - ., 0] | max) as $s
  | "\(todate) (\(if $s >= 86400 then "\($s / 86400 | floor)d \($s % 86400 / 3600 | floor)h"
    elif $s >= 3600 then "\($s / 3600 | floor)h \($s % 3600 / 60 | floor)m"
    else "\($s / 60 | floor)m"
    end) ago)";

def finding($scope; $key; $late; $priority; $title; $detail; $cleared):
  [$scope, $key, (if $late then "late" else "ok" end), $priority, $title, ($detail | gsub("[\t\n\r]+"; " ")), $cleared];

# What the checks could not tell this time, which stands as it was found last, and so does each finding of its family
# under its key, as a word or a path, such as a tenant's or a namespace's (alert.jq).
def unknown($scope; $key; $title; $detail; $cleared):
  [$scope, $key, "unknown", 4, $title, ($detail | gsub("[\t\n\r]+"; " ")), $cleared];

# What changed, which is told once and never stands, so never clears.
def notice($scope; $key; $title; $detail): [$scope, $key, "notice", 3, $title, ($detail | gsub("[\t\n\r]+"; " ")), ""];

# The family read all there is under the prefix: what it found late there before and no longer finds has cleared, but
# for what stands under an unknown key or a hold of its own.
def complete($prefix): ["complete", $prefix];

# The family could tell nothing under the prefix: what it found late there before stands, unless told of again.
def hold($prefix): ["hold", $prefix];

# When the family first found what $key names wrong, which the report keeps for the next run as $c.state.since[$key];
# what the family doesn't give again is forgotten.
def first_seen($key; $at): ["since", $key, $at];

# What the family first found wrong under the prefix, kept as it was while it can tell nothing.
def seen_before($c; $prefix):
  $c.state.since // {} | to_entries[] | select(.key | startswith($prefix)) | ["since", .key, .value];
