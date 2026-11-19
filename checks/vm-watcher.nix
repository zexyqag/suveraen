# A watcher as a node of a NixOS test (module), whose ntfy and Gatus answer at alerts.test and status.test over plain
# HTTP, with the accounts and tokens the test's servers, Gatus and phone use (secrets), how the phone reads the alerts
# (ops), what a server's alerts reach the watcher with once it names the watcher's address alerts.test (alerts), and,
# in Python, how a test whose server is the node server reads its alerts on their way (reading).
pkgs:
let
  # ntfy tokens are "tk_" plus 29 characters.
  publisherToken = "tk_suveraentestpublisher00000000";
  gatusToken = "tk_suveraentestgatus000000000000";
  heartbeatToken = "heartbeattesttoken";
  phonePassword = "phone-test-password";
in
rec {
  secrets = pkgs.runCommand "watcher-test-secrets" { nativeBuildInputs = [ pkgs.ntfy-sh ]; } ''
    mkdir $out
    hash() { printf '%s\n%s\n' "$1" "$1" | ntfy user hash | grep -o '\$2a\$.*'; }
    cat > $out/ntfy.env <<EOF
    NTFY_AUTH_USERS='phone:$(hash ${phonePassword}):user,publisher:$(hash unused):user,gatus:$(hash unused):user'
    NTFY_AUTH_TOKENS='publisher:${publisherToken},gatus:${gatusToken}'
    EOF
    cat > $out/gatus.env <<EOF
    NTFY_TOPIC=ops
    NTFY_TOKEN=${gatusToken}
    HEARTBEAT_TOKEN_SERVER=${heartbeatToken}
    EOF
    printf '%s' ${publisherToken} > $out/publisher-token
    printf '%s' ${heartbeatToken} > $out/heartbeat-token
  '';

  phone = "-u phone:${phonePassword}";
  # Phones read through the public host name and nginx, as the apps do.
  ops = "curl -fsS ${phone} 'http://alerts.test/ops/json?poll=1'";

  alerts = {
    urlFile = toString (pkgs.writeText "alerts-url" "http://alerts.test/ops");
    tokenFile = "${secrets}/publisher-token";
  };

  # How a test reads its server's alerts on their way, from the rules on its metrics to the phone.
  reading = ''
    # What a rule on the server's metrics finds now: each alert's state and key.
    def found_by(rule):
        out = server.succeed(
            f"suveraen-metrics check | jq -c --arg rule {shlex.quote(rule)}"
            " '.rules[] | select(.name == $rule) | .alerts[] | {state, key: .annotations.key}'"
        )
        return [json.loads(line) for line in out.splitlines()]

    # The server's alerts so far with this title, as the phone reads them.
    def sent(title):
        out = server.succeed(f"${ops} | jq -c --arg t {shlex.quote(f'server: {title}')} 'select(.title == $t)'")
        return [json.loads(line) for line in out.splitlines()]

    def keys(lines):
        return {line.split(": ")[0] for line in lines.splitlines()}

    # The pods that wait on a pull of their images, by namespace and app.
    def pulling():
        return sorted(server.succeed(
            "kubectl get pods -A -o json | jq -r '.items[] | select(any(.status.containerStatuses[]?,"
            " .status.initContainerStatuses[]?; .state.waiting.reason | IN(\"ErrImagePull\", \"ImagePullBackOff\")))"
            " | \"\\(.metadata.namespace)/\\(.metadata.labels.app)\"'"
        ).split())

    # Flux's controllers, whose registry is out of reach of a test's server: their pulls keep failing for as long as the
    # test runs, and so stand still late in every message after the first that names them.
    def flux_controllers():
        return sorted(
            f"flux-system/{name}"
            for name in server.succeed("kubectl -n flux-system get deployments -o jsonpath='{.items[*].metadata.name}'").split()
        )

    pulls_late = {"Still late:", "metric image pulls failing"}
  '';

  module =
    { lib, ... }:
    {
      # Plain HTTP in the VM; certificates are nginx's ordinary ACME setup.
      services.nginx.virtualHosts = lib.genAttrs [ "alerts.test" "status.test" ] (_: {
        forceSSL = lib.mkForce false;
        enableACME = lib.mkForce false;
      });

      networking.hostId = "5c1e0a7d";
      system.stateVersion = "26.05";

      suveraen = {
        storage = {
          systemDisks = [ "/dev/disk/by-id/test-0" ];
          encrypted = false;
        };
        # "en*" would also match eth1, the test network, through its alternative names.
        network.interface = "eth0";
        watcher = {
          enable = true;
          ntfyHost = "alerts.test";
          statusHost = "status.test";
          readers = [ "phone" ];
          ntfyEnvironmentFile = "${secrets}/ntfy.env";
          gatusEnvironmentFile = "${secrets}/gatus.env";
        };
        alerts = {
          urlFile = toString (pkgs.writeText "alerts-url" "http://127.0.0.1:2586/ops");
          tokenFile = "${secrets}/publisher-token";
          smart = false;
        };
      };
    };
}
