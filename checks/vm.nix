# Boots a watcher and a server in VMs. The server comes up dual-stack with Flux installed and
# pointed at the repository, secrets encrypted at rest and only SSH and web ports open. The
# watcher's ntfy only takes known publishers, the server's alerts reach a phone account, and
# Gatus raises an alert when the server's heartbeat stops.
{ pkgs, module }:
let
  repository = "https://example.invalid/suveraen.git";
  path = "./clusters/test";
  adminKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN9QsUU2i+9+MwdvtxOsPVD6L24UHYJXVJRI2oe+9oHP example";

  # ntfy tokens are "tk_" plus 29 characters.
  publisherToken = "tk_suveraentestpublisher00000000";
  gatusToken = "tk_suveraentestgatus000000000000";
  heartbeatToken = "heartbeat-test-token";
  phonePassword = "phone-test-password";

  secrets = pkgs.runCommand "watcher-test-secrets" { nativeBuildInputs = [ pkgs.ntfy-sh ]; } ''
    mkdir $out
    hash() { printf '%s\n%s\n' "$1" "$1" | ntfy user hash | grep -o '\$2a\$.*'; }
    cat > $out/ntfy.env <<EOF
    NTFY_AUTH_USERS='phone:$(hash ${phonePassword}):user,publisher:$(hash unused):user,gatus:$(hash unused):user'
    NTFY_AUTH_ACCESS='phone:ops:ro,publisher:ops:wo,gatus:ops:wo'
    NTFY_AUTH_TOKENS='publisher:${publisherToken},gatus:${gatusToken}'
    EOF
    cat > $out/gatus.env <<EOF
    NTFY_TOKEN=${gatusToken}
    HEARTBEAT_TOKEN=${heartbeatToken}
    EOF
    printf '%s' ${publisherToken} > $out/publisher-token
    printf '%s' ${heartbeatToken} > $out/heartbeat-token
  '';

  # "en*" would also match eth1, the test network, through its alternative names.
  uplink = "eth0";
  phone = "-u phone:${phonePassword}";
in
pkgs.testers.runNixOSTest {
  name = "suveraen";

  nodes = {
    watcher =
      { lib, ... }:
      {
        imports = [ module ];

        # Plain HTTP in the VM; certificates are nginx's ordinary ACME setup.
        services.nginx.virtualHosts = lib.genAttrs [ "alerts.test" "status.test" ] (_: {
          forceSSL = lib.mkForce false;
          enableACME = lib.mkForce false;
        });

        networking.hostId = "5c1e0a7d";
        system.stateVersion = "26.05";
        environment.systemPackages = [
          pkgs.netcat
          pkgs.jq
        ];

        suveraen = {
          adminKeys = [ adminKey ];
          storage = {
            systemDisks = [ "/dev/disk/by-id/test-0" ];
            encrypted = false;
          };
          network.interface = uplink;
          watcher = {
            enable = true;
            ntfyHost = "alerts.test";
            statusHost = "status.test";
            ntfyEnvironmentFile = "${secrets}/ntfy.env";
            gatusEnvironmentFile = "${secrets}/gatus.env";
            servers = [ "server" ];
            heartbeatTimeout = "30s";
          };
          alerts = {
            url = "http://127.0.0.1:2586/ops";
            tokenFile = "${secrets}/publisher-token";
            smart = false;
          };
        };
      };

    server =
      {
        config,
        lib,
        nodes,
        ...
      }:
      {
        imports = [ module ];

        virtualisation = {
          memorySize = 2048;
          diskSize = 4096;
          cores = 2;
        };

        # No LUKS or boot-time SSH in the VM: it boots from its own plain disk.
        boot.initrd.luks.devices = lib.mkForce { };
        boot.initrd.network.enable = lib.mkForce false;

        # The test network has no IPv6 router; give the node an address and a route.
        networking.interfaces.eth1.ipv6 = {
          addresses = [
            {
              address = "fd00::2";
              prefixLength = 64;
            }
          ];
          routes = [
            {
              address = "::";
              prefixLength = 0;
              via = "fd00::1";
            }
          ];
        };
        networking.hosts.${nodes.watcher.networking.primaryIPAddress} = [
          "alerts.test"
          "status.test"
        ];

        # The VM has no internet; k3s's own images come from the release tarball.
        services.k3s.images = [ config.services.k3s.package.airgap-images ];

        networking.hostId = "0400bdef";
        system.stateVersion = "26.05";
        environment.systemPackages = [ pkgs.netcat ];

        suveraen = {
          adminKeys = [ adminKey ];
          storage.systemDisks = [
            "/dev/disk/by-id/test-0"
            "/dev/disk/by-id/test-1"
          ];
          network.interface = uplink;
          cluster = {
            enable = true;
            inherit repository path;
            nodeIP = [
              config.networking.primaryIPAddress
              "fd00::2"
            ];
            sopsAgeKeyFile = toString (pkgs.writeText "age-key" "AGE-SECRET-KEY-TEST");
          };
          alerts = {
            url = "http://alerts.test/ops";
            tokenFile = "${secrets}/publisher-token";
            heartbeat = {
              url = "http://status.test/api/v1/endpoints/servers_server/external";
              tokenFile = "${secrets}/heartbeat-token";
              interval = "10s";
            };
          };
        };
      };
  };

  testScript = ''
    start_all()

    watcher.wait_for_unit("ntfy-sh.service")
    watcher.wait_for_unit("gatus.service")
    watcher.wait_for_unit("nginx.service")
    server.wait_for_unit("k3s.service")

    with subtest("The node is Ready and dual-stack"):
        server.wait_until_succeeds(
            "kubectl get node server -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep True",
            timeout=600,
        )
        server.wait_until_succeeds("kubectl get node server -o jsonpath='{.spec.podCIDRs}' | grep fd42", timeout=120)

    with subtest("Secrets are encrypted at rest"):
        server.succeed("k3s secrets-encrypt status | grep 'Encryption Status: Enabled'")

    with subtest("Flux is installed and follows the repository"):
        server.wait_until_succeeds("kubectl -n flux-system get deployment source-controller", timeout=300)
        server.wait_until_succeeds(
            "kubectl -n flux-system get gitrepository suveraen -o jsonpath='{.spec.url}' | grep -F '${repository}'"
        )
        server.succeed(
            "kubectl -n flux-system get kustomization cluster -o jsonpath='{.spec.path}' | grep -F '${path}'"
        )
        server.wait_until_succeeds("kubectl -n flux-system get secret sops-age", timeout=300)

    with subtest("Only SSH and web ports are open from outside"):
        watcher.succeed("nc -z -w 5 server 22")
        watcher.fail("nc -z -w 5 server 6443")
        watcher.fail("nc -z -w 5 server 10250")
        # NodePorts are forwarded before the host firewall sees them, so they only answer on loopback.
        server.succeed("kubectl -n kube-system rollout status deployment coredns --timeout=300s")
        server.succeed("kubectl -n kube-system expose deployment coredns --name=probe --type=NodePort --port=53 --protocol=TCP")
        port = server.succeed("kubectl -n kube-system get service probe -o jsonpath='{.spec.ports[0].nodePort}'").strip()
        server.wait_until_succeeds(f"nc -z -w 5 127.0.0.1 {port}")
        watcher.fail(f"nc -z -w 5 server {port}")

    with subtest("ntfy only takes messages from known publishers"):
        server.succeed("test $(curl -s -o /dev/null -w '%{http_code}' -d spam http://alerts.test/ops) = 403")
        server.succeed("test $(curl -s -o /dev/null -w '%{http_code}' ${phone} -d spam http://alerts.test/ops) = 403")
        server.fail("curl -fsS 'http://alerts.test/ops/json?poll=1'")

    with subtest("A failing check on the server reaches the phone"):
        # The VM has no ZFS pools, so the health check fails.
        server.fail("systemctl start zfs-health.service")
        watcher.wait_until_succeeds(
            "curl -fsS ${phone} 'http://127.0.0.1:2586/ops/json?poll=1' | grep 'server: zfs-health'"
        )

    with subtest("The watcher raises an alert when the server goes quiet"):
        watcher.wait_until_succeeds(
            "curl -fsS http://127.0.0.1:8080/api/v1/endpoints/statuses"
            " | jq -e '.[] | select(.key == \"servers_server\") | .results | any(.success)'",
            timeout=120,
        )
        # Gatus may have alerted before the first heartbeat; only a new alert counts.
        count = "curl -fsS ${phone} 'http://127.0.0.1:2586/ops/json?poll=1' | grep -c 'triggered.*No heartbeat from server' || true"
        before = int(watcher.succeed(count).strip())
        server.succeed("systemctl stop heartbeat.timer")
        watcher.wait_until_succeeds(f"test $({count}) -gt {before}", timeout=300)
  '';
}
