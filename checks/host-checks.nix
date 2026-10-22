# Runs the servers' checks of backups and Ceph (nixos/host-checks.jq) on what a cluster might hold, each case on top of
# base.json, and compares what they find with what they should.
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
  [ "$failed" = 0 ]
  touch $out
''
