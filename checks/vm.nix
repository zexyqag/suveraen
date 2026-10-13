# Boots the node layer in VMs: the k3s server comes up dual-stack with Flux installed and
# pointed at the repository, secrets are encrypted at rest, only SSH and web ports are open,
# and a failing check reaches ntfy.
{ pkgs, module }:
let
  repository = "https://example.invalid/suveraen.git";
  path = "./clusters/test";
in
pkgs.testers.runNixOSTest {
  name = "suveraen";

  nodes = {
    ntfy = {
      services.ntfy-sh = {
        enable = true;
        settings = {
          base-url = "http://ntfy";
          listen-http = ":80";
        };
      };
      networking.firewall.allowedTCPPorts = [ 80 ];
      environment.systemPackages = [ pkgs.netcat ];
    };

    server =
      { config, lib, ... }:
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

        # The VM has no internet; k3s's own images come from the release tarball.
        services.k3s.images = [ config.services.k3s.package.airgap-images ];

        networking.hostId = "0400bdef";
        system.stateVersion = "26.05";
        environment.systemPackages = [ pkgs.netcat ];

        suveraen = {
          adminKeys = [
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN9QsUU2i+9+MwdvtxOsPVD6L24UHYJXVJRI2oe+9oHP example"
          ];
          storage.systemDisks = [
            "/dev/disk/by-id/test-0"
            "/dev/disk/by-id/test-1"
          ];
          # "en*" would also match eth1, the test network, through its alternative names.
          network.interface = "eth0";
          cluster = {
            inherit repository path;
            nodeIP = [
              config.networking.primaryIPAddress
              "fd00::2"
            ];
            sopsAgeKeyFile = toString (pkgs.writeText "age-key" "AGE-SECRET-KEY-TEST");
          };
          alerts.ntfyUrlFile = toString (pkgs.writeText "ntfy-url" "http://ntfy/alerts");
        };
      };
  };

  testScript = ''
    start_all()

    ntfy.wait_for_unit("ntfy-sh.service")
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
        ntfy.succeed("nc -z -w 5 server 22")
        ntfy.fail("nc -z -w 5 server 6443")
        ntfy.fail("nc -z -w 5 server 10250")
        # NodePorts are forwarded before the host firewall sees them, so they only answer on loopback.
        server.succeed("kubectl -n kube-system rollout status deployment coredns --timeout=300s")
        server.succeed("kubectl -n kube-system expose deployment coredns --name=probe --type=NodePort --port=53 --protocol=TCP")
        port = server.succeed("kubectl -n kube-system get service probe -o jsonpath='{.spec.ports[0].nodePort}'").strip()
        server.wait_until_succeeds(f"nc -z -w 5 127.0.0.1 {port}")
        ntfy.fail(f"nc -z -w 5 server {port}")

    with subtest("A failing check sends an alert"):
        # The VM has no ZFS pools, so the health check fails.
        server.fail("systemctl start zfs-health.service")
        ntfy.wait_until_succeeds("curl -fsS 'http://localhost/alerts/json?poll=1' | grep zfs-health")
  '';
}
