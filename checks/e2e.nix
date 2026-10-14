# Boots a server built from the same modules as a real one, with internet access, and lets Flux deploy
# kubernetes/clusters/test from a signed commit on a git server inside the test. Every Kustomization and
# HelmRelease becomes Ready and no pod is refused; every route answers through the host firewall, ServiceLB,
# the gateway and the app's network policy with a certificate from the cluster's own CA, and port 80
# redirects there; the example app restarts when its settings change; and an unsigned commit is never applied.
{
  pkgs,
  module,
  kubernetes,
}:
let
  keys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;
  # git-http-backend runs as cgit and refuses repositories someone else owns.
  asCgit = "runuser -u cgit -- env HOME=/srv/git";
in
pkgs.testers.runNixOSTest {
  name = "suveraen-e2e";
  # Below the CI job's limit, so the waits in the script run out first and print what went wrong.
  globalTimeout = 3300;

  nodes.forge = {
    # Read-only smart HTTP; Flux can't fetch over dumb HTTP or git://.
    services.cgit."forge.test" = {
      enable = true;
      scanPath = "/srv/git";
      gitHttpBackend.checkExportOkFiles = false;
    };
    networking.firewall.allowedTCPPorts = [ 80 ];
    environment.systemPackages = [
      pkgs.git
      pkgs.openssh
      pkgs.curl
    ];
  };

  nodes.server =
    { lib, nodes, ... }:
    {
      imports = [
        module
        ./vm-server.nix
      ];

      virtualisation = {
        cores = 4;
        memorySize = 6144;
        diskSize = 16384;
      };

      services.unbound.settings.server = {
        # The test network's IPv6 route leads nowhere; without this every lookup waits on IPv6 name servers.
        do-ip6 = false;
        # Pods resolve through the node's resolver, which doesn't read /etc/hosts.
        local-data = [ ''"forge.test. A ${nodes.forge.networking.primaryIPAddress}"'' ];
      };
      # There's no release to upgrade to here.
      system.autoUpgrade.enable = lib.mkForce false;

      suveraen = {
        adminKeys = [ keys.snakeOilEd25519PublicKey ];
        source = {
          repository = "http://forge.test/suveraen.git";
          signers = [ keys.snakeOilEd25519PublicKey ];
        };
        cluster.path = "./kubernetes/clusters/test";
        alerts = {
          urlFile = toString (pkgs.writeText "alerts-url" "http://127.0.0.1:9/ops");
          tokenFile = toString (pkgs.writeText "alerts-token" "unused");
        };
      };
    };

  testScript =
    { nodes, ... }:
    let
      server = nodes.server.networking.primaryIPAddress;
    in
    ''
      import json

      start_all()

      with subtest("The forge serves a commit signed by a release signer"):
          forge.wait_for_unit("nginx.service")
          forge.succeed(
              "install -d -o cgit -g cgit /srv/git /srv/src"
              " && cp -r ${kubernetes} /srv/src/kubernetes && chmod -R u+w /srv/src && chown -R cgit:cgit /srv/src"
              " && install -o cgit -m 600 ${keys.snakeOilEd25519PrivateKey} /srv/signer"
          )
          forge.succeed(
              "cd /srv/src && ${asCgit} git init -q -b main && ${asCgit} git add -A"
              " && ${asCgit} git -c user.name=test -c user.email=test@example.org -c gpg.format=ssh"
              " -c user.signingkey=/srv/signer commit -q -S -m signed"
              " && ${asCgit} git clone -q --bare /srv/src /srv/git/suveraen.git"
          )
          signed = forge.succeed("${asCgit} git -C /srv/git/suveraen.git rev-parse main").strip()

      def diagnose():
          for cmd in [
              "kubectl get gitrepositories,ocirepositories,kustomizations,helmreleases -A",
              "kubectl get pods -A -o wide",
              "kubectl get events -A --sort-by=.lastTimestamp | tail -n 100",
              "kubectl -n flux-system logs deploy/source-controller --tail=50",
              "kubectl -n flux-system logs deploy/kustomize-controller --tail=100",
              "kubectl -n flux-system logs deploy/helm-controller --tail=100",
          ]:
              print(server.execute(cmd)[1])

      server.wait_for_unit("k3s.service")
      try:
          with subtest("Flux takes the signed commit"):
              server.wait_until_succeeds(
                  f"kubectl -n flux-system get gitrepository suveraen -o jsonpath='{{.status.artifact.revision}}' | grep -F {signed}",
                  timeout=600,
              )
              server.succeed("kubectl -n flux-system wait gitrepository suveraen --for=condition=SourceVerified --timeout=0")

          with subtest("Every Kustomization and HelmRelease becomes Ready"):
              # The root Kustomization is Ready only once it has created the others, so --all covers them all.
              server.wait_until_succeeds(
                  "kubectl -n flux-system wait kustomization --all --for=condition=Ready --timeout=0", timeout=1500
              )
              server.succeed("kubectl wait helmrelease -A --all --for=condition=Ready --timeout=0")

          with subtest("Every workload runs, and Pod Security refused nothing"):
              def items(kind):
                  return json.loads(server.succeed(f"kubectl get {kind} -A -o json"))["items"]

              for d in items("deployments") + items("statefulsets"):
                  want = d["spec"].get("replicas", 1)
                  assert d["status"].get("readyReplicas", 0) == want, (d["metadata"], d["status"])
              for d in items("daemonsets"):
                  assert d["status"].get("numberReady", 0) == d["status"]["desiredNumberScheduled"], (d["metadata"], d["status"])
              refused = [e["message"] for e in items("events") if "violates PodSecurity" in e.get("message", "")]
              assert not refused, refused

          with subtest("Every route answers through the gateway with the cluster's own CA, and port 80 redirects there"):
              ca = server.succeed("kubectl -n cert-manager get secret public-ca -o jsonpath='{.data.tls\\.crt}'").strip()
              forge.succeed(f"echo {ca} | base64 -d > /tmp/ca.crt")
              hosts = sorted({h for r in json.loads(server.succeed("kubectl get httproute -A -o json"))["items"] for h in r["spec"]["hostnames"]})
              assert hosts, "no routes"
              for host in hosts:
                  # -f: a refused connection, a bad certificate or an error status all fail.
                  forge.wait_until_succeeds(
                      f"curl -fsS -o /dev/null --cacert /tmp/ca.crt --resolve {host}:443:${server} https://{host}/", timeout=120
                  )
                  redirect = forge.succeed(
                      f"curl -sS -o /dev/null -w '%{{http_code}} %{{redirect_url}}' --resolve {host}:80:${server} http://{host}/"
                  ).split()
                  assert redirect == ["301", f"https://{host}/"], redirect

          hello = "curl -fsS --cacert /tmp/ca.crt --resolve hello.example.test:443:${server} https://hello.example.test/"

          with subtest("The example app gets the cluster's settings and restarts when they change"):
              forge.succeed(f"{hello} | grep -F 'hello from example.test'")
              server.succeed("""kubectl -n hello patch configmap hello --type merge -p '{"data":{"PODINFO_UI_MESSAGE":"changed"}}'""")
              forge.wait_until_succeeds(f"{hello} | grep -F changed", timeout=180)

          with subtest("An unsigned commit is never applied"):
              forge.succeed(
                  "cd /srv/src && ${asCgit} git rm -q -r kubernetes/apps"
                  " && ${asCgit} git -c user.name=test -c user.email=test@example.org commit -q -m unsigned"
                  " && ${asCgit} git push -q /srv/git/suveraen.git main"
              )
              server.succeed(
                  "kubectl -n flux-system annotate gitrepository suveraen --overwrite reconcile.fluxcd.io/requestedAt=$(date +%s)"
              )
              server.wait_until_succeeds(
                  "kubectl -n flux-system get gitrepository suveraen"
                  """ -o jsonpath='{.status.conditions[?(@.type=="SourceVerified")].status}' | grep -x False""",
                  timeout=300,
              )
              server.succeed(
                  f"kubectl -n flux-system get gitrepository suveraen -o jsonpath='{{.status.artifact.revision}}' | grep -F {signed}"
              )
              server.succeed("kubectl -n hello get deployment hello")
      except Exception:
          diagnose()
          raise
    '';
}
