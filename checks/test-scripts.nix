# Fails when a function in a NixOS test script uses a global that the script binds again once the function exists: the
# driver runs every subtest in one namespace, so the function would see what a later subtest left there. First on cases
# whose findings are known, then on each test's script, beside the names the driver binds before it.
{ pkgs, tests }:
let
  inherit (pkgs) lib;
  scan = "python3 ${./test-scripts.py} --driver ${
    pkgs.path + "/nixos/lib/test-driver/src/test_driver/driver.py"
  }";
  script =
    name: test:
    let
      inherit (test.config) driverConfiguration testScriptString;
      flags =
        map (n: "--machine=${n}") (
          lib.attrNames (driverConfiguration.vms // driverConfiguration.containers)
        )
        ++ map (n: "--vlan=${toString n}") driverConfiguration.vlans;
      # Only its text is read, so what it names in the store needn't be built.
      text = builtins.toFile "${name}-test-script" (builtins.unsafeDiscardStringContext testScriptString);
    in
    ''
      ${scan} ${name} ${text} ${lib.escapeShellArgs flags} || failed=1
    '';
in
pkgs.runCommand "test-scripts" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  failed=0
  found=$(${scan} --machine=server cases ${./test-scripts/cases.py} || true)
  if diff -u ${./test-scripts/expected.txt} - <<<"$found"; then echo "ok cases"; else failed=1; fi
  ${lib.concatStrings (lib.mapAttrsToList script tests)}
  [ "$failed" = 0 ]
  touch $out
''
