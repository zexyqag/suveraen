# Boots a watcher and a server in VMs. The server comes up dual-stack with Flux installed and
# pointed at the repository, secrets encrypted at rest and only SSH and web ports open. Hosts and
# pods resolve names through the node's own resolver, and clocks use NTS. The watcher's ntfy only
# takes known publishers and keeps its account API, stats and attachments closed; the server's
# alerts reach a phone account; Gatus raises an alert when the server's heartbeat stops; and the
# server falls back to a second channel when the watcher is gone. The server and its Flux only take
# commits signed by a release signer.
{ pkgs, module }:
let
  repository = "https://example.invalid/suveraen.git";
  path = "./clusters/test";
  adminKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN9QsUU2i+9+MwdvtxOsPVD6L24UHYJXVJRI2oe+9oHP example";

  # ntfy tokens are "tk_" plus 29 characters.
  publisherToken = "tk_suveraentestpublisher00000000";
  gatusToken = "tk_suveraentestgatus000000000000";
  heartbeatToken = "heartbeattesttoken";
  phonePassword = "phone-test-password";

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

  # nixpkgs' well-known test keys: the ed25519 one signs releases, the other one isn't a signer.
  keys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;
  signer = keys.snakeOilEd25519PublicKey;

  # "en*" would also match eth1, the test network, through its alternative names.
  uplink = "eth0";
  phone = "-u phone:${phonePassword}";
  # Phones read through the public host name and nginx, as the apps do.
  ops = "curl -fsS ${phone} 'http://alerts.test/ops/json?poll=1'";
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
            readers = [ "phone" ];
            ntfyEnvironmentFile = "${secrets}/ntfy.env";
            gatusEnvironmentFile = "${secrets}/gatus.env";
            servers = [ "server" ];
            heartbeatTimeout = "30s";
          };
          alerts = {
            urlFile = toString (pkgs.writeText "alerts-url" "http://127.0.0.1:2586/ops");
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

        # A name only the node's own resolver knows, to show pods resolve through it.
        services.unbound.settings.server.local-data = [ ''"probe.test. A 192.0.2.53"'' ];

        # Stands in for the second alert channel, which would live on another machine.
        services.ntfy-sh = {
          enable = true;
          environmentFile = "${secrets}/ntfy.env";
          settings = {
            base-url = "http://fallback.test";
            listen-http = "127.0.0.1:2587";
          };
        };

        networking.hostId = "0400bdef";
        system.stateVersion = "26.05";
        environment.systemPackages = [
          pkgs.netcat
          pkgs.jq
          pkgs.git
        ];

        suveraen = {
          adminKeys = [ adminKey ];
          storage.systemDisks = [
            "/dev/disk/by-id/test-0"
            "/dev/disk/by-id/test-1"
          ];
          network.interface = uplink;
          source = {
            inherit repository;
            signers = [ signer ];
          };
          cluster = {
            enable = true;
            inherit path;
            nodeIP = [
              config.networking.primaryIPAddress
              "fd00::2"
            ];
            sopsAgeKeyFile = toString (pkgs.writeText "age-key" "AGE-SECRET-KEY-TEST");
          };
          alerts = {
            urlFile = toString (pkgs.writeText "alerts-url" "http://alerts.test/ops");
            tokenFile = "${secrets}/publisher-token";
            fallback = {
              urlFile = toString (pkgs.writeText "fallback-url" "http://127.0.0.1:2587/fallback");
              tokenFile = "${secrets}/publisher-token";
            };
            retrySeconds = 5;
            heartbeat = {
              url = "http://status.test/api/v1/endpoints/servers_server/external";
              tokenFile = "${secrets}/heartbeat-token";
              interval = "10s";
            };
          };
        };
      };
  };

  testScript =
    { nodes, ... }:
    let
      # The server's own upgrade reference, pointed at a repository inside the VM.
      releaseFlake =
        builtins.replaceStrings [ repository ] [ "file:///srv/release" ]
          nodes.server.system.autoUpgrade.flake;
    in
    ''
      start_all()

      watcher.wait_for_unit("ntfy-sh.service")
      watcher.wait_for_unit("gatus.service")
      # Gatus silently drops an alerting provider it considers invalid.
      watcher.wait_until_succeeds("journalctl -u gatus | grep -F 'configuredProviders=[ntfy]'")
      watcher.wait_for_unit("nginx.service")
      watcher.wait_until_succeeds("curl -fsS http://127.0.0.1:8080/health")
      watcher.wait_until_succeeds("curl -fsS http://127.0.0.1:2586/v1/health")
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

      with subtest("Flux and the server only deploy commits signed by a release signer"):
          server.succeed("kubectl -n flux-system get gitrepository suveraen -o jsonpath='{.spec.verify.mode}' | grep -x HEAD")
          server.wait_until_succeeds(
              "kubectl -n flux-system get secret release-signers -o jsonpath='{.data.signer-0\\.sshpub}'"
              " | base64 -d | grep -x '${pkgs.lib.concatStringsSep " " (pkgs.lib.take 2 (pkgs.lib.splitString " " signer))}'",
              timeout=120,
          )
          release_flake = """${releaseFlake}"""
          server.succeed(
              "install -m 600 ${keys.snakeOilEd25519PrivateKey} /root/signer"
            " && install -m 600 ${keys.snakeOilPrivateKey} /root/other && ssh-keygen -y -f /root/other > /root/other.pub"
              " && git init -q -b main /srv/release && cd /srv/release"
              " && git config user.name test && git config user.email test@example.org && git config gpg.format ssh"
              " && echo '{ outputs = _: { release = \"signed\"; }; }' > flake.nix && git add flake.nix"
              " && git -c user.signingkey=/root/signer commit -qS -m signed"
          )
          server.succeed(f"nix eval --raw {release_flake}#release | grep -x signed")
          server.succeed("cd /srv/release && git commit -q --allow-empty -m unsigned")
          server.fail(f"nix eval --raw {release_flake}#release")
          server.succeed("cd /srv/release && git -c user.signingkey=/root/other commit -q --allow-empty -S -m other")
          server.fail(f"nix eval --raw {release_flake}#release")

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

      with subtest("Hosts and pods resolve names through the node's own resolver"):
          for node in [server, watcher]:
              node.succeed("grep -qx 'nameserver 127.0.0.1' /etc/resolv.conf")
              node.fail("grep '^nameserver' /etc/resolv.conf | grep -vx -e 'nameserver 127.0.0.1' -e 'nameserver ::1'")
          server.succeed("getent hosts probe.test | grep -F 192.0.2.53")
          busybox = server.succeed("k3s crictl images -o json | jq -r '.images[].repoTags[]' | grep busybox | head -n1").strip()
          server.succeed(
              f"kubectl run dns-probe --image={busybox} --image-pull-policy=Never --restart=Never --command -- nslookup probe.test."
          )
          server.wait_until_succeeds(
              "kubectl get pod dns-probe -o jsonpath='{.status.phase}' | grep -xE 'Succeeded|Failed'", timeout=120
          )
          server.succeed("kubectl logs dns-probe | grep -F 192.0.2.53")
          server.succeed(
              f"kubectl run dns-probe-host --image={busybox} --image-pull-policy=Never --restart=Never"
              """ --overrides='{"spec":{"hostNetwork":true}}' --command -- nslookup probe.test."""
          )
          server.wait_until_succeeds(
              "kubectl get pod dns-probe-host -o jsonpath='{.status.phase}' | grep -xE 'Succeeded|Failed'", timeout=120
          )
          server.succeed("kubectl logs dns-probe-host | grep -F 192.0.2.53")

      with subtest("Clocks follow NTS servers"):
          for node in [server, watcher]:
              node.succeed("systemctl is-active chronyd")
              node.succeed(
                  "conf=$(systemctl show chronyd -p ExecStart --value | grep -o '/nix/store/[^ ;]*chrony.conf')"
                  " && grep -Eq '^server .* nts$' $conf && ! grep '^server ' $conf | grep -vq ' nts$'"
              )

      with subtest("ntfy only takes messages from known publishers"):
          server.succeed("test $(curl -s -o /dev/null -w '%{http_code}' -d spam http://alerts.test/ops) = 403")
          server.succeed("test $(curl -s -o /dev/null -w '%{http_code}' ${phone} -d spam http://alerts.test/ops) = 403")
          server.fail("curl -fsS 'http://alerts.test/ops/json?poll=1'")

      with subtest("ntfy's account API and stats are closed"):
          for p in ["/v1/account", "/v1/account/token", "/v1/stats"]:
              server.succeed(f"test $(curl -s -o /dev/null -w '%{{http_code}}' ${phone} http://alerts.test{p}) = 404")

      with subtest("A failing check on the server reaches the phone"):
          # The VM has no ZFS pools, so the health check fails.
          server.fail("systemctl start zfs-health.service")
          server.wait_until_succeeds("${ops} | grep 'server: ZFS pool unhealthy'")

      with subtest("Long alerts arrive as plain text, not as an attachment"):
          server.succeed("suveraen-alert big \"$(head -c 20000 /dev/zero | tr '\\0' x)\"")
          server.wait_until_succeeds(
              "${ops} | jq -e 'select(.title == \"server: big\") | (has(\"attachment\") | not) and (.message | length) <= 3800'"
          )

      with subtest("The watcher raises an alert when the server goes quiet"):
          watcher.wait_until_succeeds(
              "curl -fsS http://127.0.0.1:8080/api/v1/endpoints/statuses"
              " | jq -e '.[] | select(.key == \"servers_server\") | .results | any(.success)'",
              timeout=120,
          )
          # Gatus may have alerted before the first heartbeat; only a new alert counts.
          count = "${ops} | grep -c '{}.*No heartbeat from server' || true"
          before = int(server.succeed(count.format("triggered")).strip())
          server.succeed("systemctl stop heartbeat.timer")
          server.wait_until_succeeds(f"test $({count.format('triggered')}) -gt {before}", timeout=300)

      with subtest("The watcher says so when the server reports in again"):
          resolved = int(server.succeed(count.format("resolved")).strip())
          server.succeed("systemctl start heartbeat.timer")
          server.wait_until_succeeds(f"test $({count.format('resolved')}) -gt {resolved}", timeout=300)

      with subtest("The server falls back to its second channel when the watcher is gone"):
          watcher.succeed("systemctl stop nginx")
          server.wait_until_succeeds(
              "curl -fsS 'http://127.0.0.1:2587/fallback/json?poll=1' | grep 'server: heartbeat.service failed'",
              timeout=300,
          )
    '';
}
