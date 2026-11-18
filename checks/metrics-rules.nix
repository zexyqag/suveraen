# Runs vmalert-tool's tests (metrics/*.test.yaml) on the rules a server evaluates on its own metrics (nixos/metrics.nix),
# as checks/server.nix declares them, each test beside them as rules.yml, and fails while a rule has no test in which it
# fires; and compares what a server's evaluation refuses of the rules and jobs in metrics/refused.nix with
# metrics/refused.txt.
{
  pkgs,
  rulesFile,
  refused,
}:
pkgs.runCommand "metrics-rules"
  {
    nativeBuildInputs = [
      pkgs.victoriametrics
      pkgs.yq-go
    ];
    refused = pkgs.lib.concatMapStrings (message: message + "\n") refused;
    passAsFile = [ "refused" ];
  }
  ''
    failed=0
    cp ${rulesFile} rules.yml
    for test in ${./metrics}/*.test.yaml; do
      name=$(basename "$test")
      cp "$test" "$name"
      if vmalert-tool unittest --files "$name" >"$name.log" 2>&1; then
        echo "ok $name"
      else
        echo "WRONG $name"
        cat "$name.log"
        failed=1
      fi
    done
    yq '.groups[].rules[].alert' rules.yml | sort -u >rules
    yq '.tests[].alert_rule_test[] | select(.exp_alerts | length > 0) | .alertname' ./*.test.yaml | sort -u >fired
    untested=$(comm -23 rules fired)
    if [ -n "$untested" ]; then
      echo "WRONG: no test in which these fire: $untested"
      failed=1
    fi
    if diff -u ${./metrics/refused.txt} "$refusedPath"; then echo "ok refused"; else failed=1; fi
    [ "$failed" = 0 ]
    touch $out
  ''
