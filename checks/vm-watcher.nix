# A watcher as a node of a NixOS test (module), whose ntfy and Gatus answer at alerts.test and status.test over plain
# HTTP, with the accounts and tokens the test's servers, Gatus and phone use (secrets), how the phone reads the alerts
# (ops), and what a server's alerts reach the watcher with once it names the watcher's address alerts.test (alerts).
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
