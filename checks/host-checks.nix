# Runs the servers' checks (nixos/host-checks.jq) on what a cluster might hold, each case on top of base.json; on some,
# what they then alert given the findings late before (nixos/host-checks-alert.jq); and suveraen-idm's filter for
# Kanidm's log (nixos/idm-migrations.jq) on logs Kanidm wrote, stamped as the kubelet shows them, with the time its
# container started; and compares what they find with what they should.
{ pkgs }:
pkgs.runCommand "host-checks" { nativeBuildInputs = [ pkgs.jq ]; } ''
  failed=0
  for case in ${./host-checks}/*/; do
    name=$(basename "$case")
    if jq -s '.[0] * .[1]' ${./host-checks/base.json} "$case/input.json" | jq -r -f ${../nixos/host-checks.jq} \
      | diff -u "$case/expected.tsv" -; then
      echo "ok $name"
    else
      echo "WRONG $name"
      failed=1
    fi
  done
  for case in ${./host-checks-alerts}/*/; do
    name=$(basename "$case")
    merged=$(jq -s '.[0] * .[1]' ${./host-checks/base.json} "$case/input.json")
    now=$(jq .now <<<"$merged")
    if jq -r -f ${../nixos/host-checks.jq} <<<"$merged" \
      | jq -R -s -c --rawfile alerted "$case/late.tsv" --argjson now "$now" --argjson remind 86400 \
        --argjson reminded "$now" -f ${../nixos/host-checks-alert.jq} \
      | diff -u <(jq -c . "$case/expected.json") -; then
      echo "ok alert $name"
    else
      echo "WRONG alert $name"
      failed=1
    fi
  done
  for case in ${./idm-migrations}/*/; do
    name=$(basename "$case")
    if jq -Rsc --arg started "$(<"$case/started")" -f ${../nixos/idm-migrations.jq} "$case/log" \
      | diff -u <(jq -c . "$case/expected.json") -; then
      echo "ok log $name"
    else
      echo "WRONG log $name"
      failed=1
    fi
  done
  # Each log that tells of a run again, its first line stamped in the second from 1 s before its container's start to
  # 4 s after, and in the seconds either side, or with no container running, where it tells of none.
  for case in ${./idm-migrations}/*/; do
    name=$(basename "$case")
    judged=$(jq -c . "$case/expected.json")
    [ "$judged" != null ] || continue
    first=$(head -n 1 "$case/log" | jq -Rr 'split(" ")[0] | sub("[.][0-9]+Z$"; "Z") | fromdateiso8601')
    for after in none -2 -1 4 5; do
      want=$judged started=
      case $after in none | -2 | 5) want=null ;; esac
      [ "$after" = none ] || started=$(jq -nr --argjson at "$((first - after))" '$at | todate')
      got=$(jq -Rsc --arg started "$started" -f ${../nixos/idm-migrations.jq} "$case/log")
      if [ "$got" = "$want" ]; then
        echo "ok log $name, started ''${started:-never}"
      else
        echo "WRONG log $name, started ''${started:-never}: $got"
        failed=1
      fi
    done
  done
  # A log of 8 MB, near the most the kubelet keeps, all but its start what clients had Kanidm log, within a minute: a
  # filter whose time grows with the square of its length takes hours.
  injected=${./idm-migrations/injected}
  sed '1,/Starting the web server/d' $injected/log >clients.log
  for _ in $(seq 11); do cat clients.log clients.log >twice.log && mv twice.log clients.log; done
  cat $injected/log clients.log >long.log
  if timeout 60 jq -Rsc --arg started "$(<$injected/started)" -f ${../nixos/idm-migrations.jq} long.log \
    | diff -u <(jq -c . $injected/expected.json) -; then
    echo "ok log long, $(stat -c %s long.log) bytes"
  else
    echo "WRONG log long"
    failed=1
  fi
  [ "$failed" = 0 ]
  touch $out
''
