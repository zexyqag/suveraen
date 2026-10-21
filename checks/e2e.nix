# Boots a server built from the same modules as a real one, with internet access, and lets Flux deploy
# kubernetes/clusters/test from a signed commit on a git server inside the test, with two test ACME CAs and a
# nameserver standing in for the internet's. Every Kustomization and HelmRelease becomes Ready, every Secret
# is stored encrypted with secretbox, no pod is refused and no job fails; both CAs know our accounts, and every
# host's certificate comes over DNS-01, its challenge answered in our ACME zone through the node's Knot and
# removed again, also where an organisation's own DNS points the challenge there; the standby CA, which requires
# our external account, issues too; every route answers through the host firewall, ServiceLB, the gateway and
# the app's network policy with a certificate from the CA, and port 80 redirects there; the platform's pods run
# ahead of tenants'. Each tenant runs in exactly the namespaces its manifest asks for, and hello answers on each
# of its hosts with that tenant's own settings and restarts when they change; a tenant's pods reach neither other
# tenants' services nor the gateway's, and nothing outside reaches theirs; tenants can't take each other's
# namespaces or hosts or keep Gateways outside the gateway namespace, and stay within their quota; a host's key
# goes with its certificate; removing a tenant takes its Kustomizations, hosts, keys and pods but leaves its
# namespaces, which then go by its label; and an unsigned commit is never applied. Ceph runs healthy with three
# monitors and an encrypted OSD per disk, its DB on a partition of its own, three copies on every pool; block
# volumes bind, snapshot and restore, and outlive their claims; the object store hands out buckets with keys of
# their own to the pods allowed to reach it; and after a reboot Ceph comes back with its data. Each tenant's
# PostgreSQL archives WAL and base backups to its own bucket, takes no restore while it runs, and lets each app reach
# its own database alone, from its own namespace; a removed tenant's cluster and bucket go only with its namespaces.
# The bucket goes off-site to two providers, encrypted with the tenant's own key, where the cluster's keys can neither
# delete nor unlock a copy; and when the cluster's object store has lost it, a release brings the tenant's PostgreSQL
# back from a provider's copy as a new generation, with its apps' data.
{
  pkgs,
  module,
  kubernetes,
}:
let
  inherit (pkgs) lib;
  keys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;
  # git-http-backend runs as cgit and refuses repositories someone else owns.
  asCgit = "runuser -u cgit -- env HOME=/srv/git";

  transferKey = import ./transfer-key.nix pkgs;
  # The cluster the server's Flux applies, as it is in the store.
  clusterIn =
    nodes: "${kubernetes}/${lib.removePrefix "./kubernetes/" nodes.server.suveraen.cluster.path}";
  # The zones the server signs, and the one an organisation keeps at its own DNS host.
  ours = [
    "example.test"
    "one.test"
  ];
  acmeZone = "acme.example.test";
  theirs = "org.test";

  certs = import "${pkgs.path}/nixos/tests/common/acme/server/snakeoil-certs.nix";

  # The two providers that keep the off-site copies, each at its own address on the internet node, on port 80.
  providers = [
    1
    2
  ];
  s3Address = n: "192.168.1.10${toString n}";
  # A provider as it is at onboarding: each tenant's bucket locked, and the tenant's key, which may list it and write
  # copies under postgres/, but neither delete nor unlock them. The root keys are the provider's own, test stand-ins.
  s3 =
    { nodes, ... }:
    {
      boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1;
      networking.interfaces.eth1.ipv4.addresses = lib.mkAfter (
        map (n: {
          address = s3Address n;
          prefixLength = 24;
        }) providers
      );
      environment.systemPackages = [ pkgs.awscli2 ];
      systemd.services = lib.listToAttrs (
        lib.concatMap (
          n:
          let
            name = "s3-${toString n}";
            endpoint = "http://${s3Address n}";
            root = "--access root-${toString n} --secret root-${toString n}-test-secret";
            setup = pkgs.writeShellApplication {
              name = "${name}-setup";
              runtimeInputs = [
                pkgs.awscli2
                pkgs.versitygw
                pkgs.yq-go
                pkgs.jq
                pkgs.curl
              ];
              text = ''
                export AWS_ACCESS_KEY_ID=root-${toString n} AWS_SECRET_ACCESS_KEY=root-${toString n}-test-secret
                export AWS_DEFAULT_REGION=us-east-1 AWS_ENDPOINT_URL=${endpoint} HOME=$RUNTIME_DIRECTORY
                until curl -s -o /dev/null ${endpoint}; do sleep 1; done
                prefix=$(yq .data.BACKUP_${toString n}_BUCKET_PREFIX ${clusterIn nodes}/settings.yaml)
                for secrets in ${clusterIn nodes}/tenants/*/secrets.yaml; do
                  bucket=$prefix$(basename "$(dirname "$secrets")")
                  key=$(yq .stringData.POSTGRES_BACKUP_${toString n}_ACCESS_KEY_ID "$secrets")
                  versitygw admin ${root} --endpoint-url ${endpoint} create-user --role user --access "$key" \
                    --secret "$(yq .stringData.POSTGRES_BACKUP_${toString n}_SECRET_ACCESS_KEY "$secrets")"
                  aws s3api create-bucket --bucket "$bucket" --object-lock-enabled-for-bucket
                  aws s3api put-object-lock-configuration --bucket "$bucket" --object-lock-configuration \
                    '{"ObjectLockEnabled": "Enabled", "Rule": {"DefaultRetention": {"Mode": "COMPLIANCE", "Days": 1}}}'
                  aws s3api put-bucket-policy --bucket "$bucket" --policy "$(jq -cn --arg key "$key" --arg bucket "$bucket" '
                    {Version: "2012-10-17", Statement: [
                      {Effect: "Allow", Principal: {AWS: [$key]}, Action: ["s3:ListBucket"],
                        Resource: ["arn:aws:s3:::\($bucket)"]},
                      {Effect: "Allow", Principal: {AWS: [$key]},
                        Action: ["s3:GetObject", "s3:PutObject", "s3:PutObjectRetention"],
                        Resource: ["arn:aws:s3:::\($bucket)/postgres/*"]}]}')"
                done
              '';
            };
          in
          [
            (lib.nameValuePair name {
              wantedBy = [ "multi-user.target" ];
              serviceConfig = {
                StateDirectory = map (dir: "${name}/${dir}") [
                  "data"
                  "versions"
                  "iam"
                ];
                ExecStart =
                  "${pkgs.versitygw}/bin/versitygw --port ${s3Address n}:80 ${root} --iam-dir /var/lib/${name}/iam"
                  + " posix --versioning-dir /var/lib/${name}/versions /var/lib/${name}/data";
              };
            })
            (lib.nameValuePair "${name}-setup" {
              wantedBy = [ "multi-user.target" ];
              requires = [ "${name}.service" ];
              after = [ "${name}.service" ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                RuntimeDirectory = "${name}-setup";
                ExecStart = lib.getExe setup;
              };
            })
          ]
        ) providers
      );
      networking.firewall.allowedTCPPorts = [ 80 ];
    };
in
pkgs.testers.runNixOSTest {
  name = "suveraen-e2e";
  # Below the CI job's limit, so the waits in the script run out first and print what went wrong.
  globalTimeout = 6600;

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

  # The internet: two test ACME CAs (Pebble) with a resolver of their own, and a nameserver standing in for both our
  # published secondaries and an organisation's DNS host, which points its challenge into our ACME zone.
  nodes.acme =
    { config, nodes, ... }:
    let
      address = config.networking.primaryIPAddress;
      # A Pebble whose settings, a yq object, may read the test cluster's secrets.
      pebble =
        name: settings:
        pkgs.writeShellApplication {
          name = "pebble-${name}";
          runtimeInputs = [
            pkgs.pebble
            pkgs.yq-go
          ];
          text = ''
            yq -o json '{"pebble": ({
              "certificate": "${certs.${certs.domain}.cert}",
              "privateKey": "${certs.${certs.domain}.key}",
              "httpPort": 80,
              "tlsPort": 443} * ${settings})}' ${clusterIn nodes}/secrets.yaml >"$RUNTIME_DIRECTORY/config.json"
            exec pebble -config "$RUNTIME_DIRECTORY/config.json" -dnsserver 127.0.0.1:53
          '';
        };
    in
    {
      imports = [
        "${pkgs.path}/nixos/tests/common/acme/server"
        s3
      ];
      systemd.services.pebble.serviceConfig.ExecStart = lib.mkForce (
        lib.getExe (
          pebble "public" ''{"listenAddress": "0.0.0.0:443", "managementListenAddress": "0.0.0.0:15000"}''
        )
      );
      # The standby CA takes only accounts bound to an external account, as ZeroSSL does: the test cluster's.
      systemd.services.pebble-standby = {
        wantedBy = [ "multi-user.target" ];
        environment = {
          PEBBLE_VA_NOSLEEP = "1";
          PEBBLE_WFE_NONCEREJECT = "0";
        };
        serviceConfig = {
          RuntimeDirectory = "pebble-standby";
          ExecStart = lib.getExe (
            pebble "standby" ''
              {"listenAddress": "0.0.0.0:14000", "managementListenAddress": "0.0.0.0:15001",
                "externalAccountBindingRequired": true,
                "externalAccountMACKeys": {.stringData.ACME_STANDBY_EAB_KID: .stringData.ACME_STANDBY_EAB_HMAC}}''
          );
        };
      };

      services.unbound = {
        enable = true;
        settings = {
          # test. is one of Unbound's empty local zones, and isn't signed.
          server = {
            local-zone = [ ''"test." transparent'' ];
            domain-insecure = [ "test." ];
          };
          stub-zone = map (name: {
            inherit name;
            stub-addr = [ address ];
          }) (ours ++ [ theirs ]);
        };
      };

      services.knot = {
        enable = true;
        keyFiles = [ transferKey.file ];
        settings = {
          server.listen = [ "${address}@53" ];
          remote.signer = {
            address = [ nodes.server.networking.primaryIPAddress ];
            key = "transfer";
          };
          acl.signer = {
            address = [ nodes.server.networking.primaryIPAddress ];
            key = "transfer";
            action = "notify";
          };
          template.default = {
            zonefile-sync = -1;
            journal-content = "all";
          };
          zone =
            lib.genAttrs (ours ++ [ acmeZone ]) (_: {
              master = [ "signer" ];
              acl = [ "signer" ];
              zonefile-load = "none";
            })
            // {
              ${theirs}.file = pkgs.writeText "${theirs}.zone" ''
                $ORIGIN ${theirs}.
                $TTL 60
                @ SOA ns.${theirs}. hostmaster.${theirs}. 1 3600 900 604800 60
                @ NS ns.${theirs}.
                ns A ${address}
                _acme-challenge.hello CNAME _acme-challenge.k7wq2xv9p4m3.${acmeZone}.
              '';
            };
        };
      };

      networking.firewall = {
        allowedTCPPorts = [
          53
          14000
        ];
        allowedUDPPorts = [ 53 ];
      };
    };

  nodes.server =
    { lib, nodes, ... }:
    {
      imports = [
        module
        ./vm-server.nix
      ];

      # Ceph's three monitors and three OSDs take about 4 GiB; its images take room the monitors want free.
      virtualisation = {
        cores = 4;
        memorySize = 10240;
        diskSize = 32768;
      };

      services.unbound.settings = {
        server = {
          # The test network's IPv6 route leads nowhere; without this every lookup waits on IPv6 name servers.
          do-ip6 = false;
          # Pods resolve through the node's resolver, which doesn't read /etc/hosts.
          local-data = [
            ''"forge.test. A ${nodes.forge.networking.primaryIPAddress}"''
            ''"acme.test. A ${nodes.acme.networking.primaryIPAddress}"''
          ]
          ++ map (n: ''"s3-${toString n}.test. A ${s3Address n}"'') providers;
          # test. is one of Unbound's empty local zones, and isn't signed.
          local-zone = [ ''"test." transparent'' ];
          domain-insecure = [ "test." ];
        };
        # As a real cluster's are found through the registries, its zones are found at the published nameserver.
        stub-zone = map (name: {
          inherit name;
          stub-addr = [ nodes.acme.networking.primaryIPAddress ];
        }) (ours ++ [ theirs ]);
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
        dns = {
          self = "server";
          signer = "server";
          servers = {
            server.addresses = [ nodes.server.networking.primaryIPAddress ];
            ns1 = {
              name = "ns1.example.test";
              addresses = [ nodes.acme.networking.primaryIPAddress ];
            };
          };
          contact = "hostmaster@example.test";
          # The test cluster's hosts on the zones we serve.
          zones = {
            "example.test".certificates = [ "hello" ];
            "one.test".certificates = [ "@" ];
          };
          acme.zone = acmeZone;
          caa = {
            issuers = [ { domain = "acme.test"; } ];
            validationMethods = [ "dns-01" ];
          };
          transferKeyFile = toString transferKey.file;
          backup.recipients = [ keys.snakeOilEd25519PublicKey ];
        };
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
      cluster = clusterIn nodes;
      inherit (nodes.acme.test-support.acme) caCert;
      checkout = "/srv/src/${lib.removePrefix "./" nodes.server.suveraen.cluster.path}";
    in
    ''
      import base64
      import ipaddress
      import json
      import os
      import re
      import shlex
      import time

      def read(path, key):
          with open(path) as f:
              value = re.search(rf"^  {key}: (\S+)$", f.read(), re.MULTILINE)
          assert value, (path, key)
          return value.group(1)

      def setting(key):
          return read("${cluster}/settings.yaml", key)

      # The test cluster trusts the test ACME CAs' servers through this CA.
      with open("${caCert}", "rb") as ca:
          assert base64.b64decode(setting("ACME_CA_BUNDLE")) == ca.read(), "ACME_CA_BUNDLE isn't nixpkgs' test CA"

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
              "kubectl get clusterissuers,certificates,certificaterequests,orders,challenges -A",
              "kubectl -n cert-manager logs deploy/cert-manager --tail=100",
              "journalctl -u knot -u knot-acme-secret --no-pager | tail -n 50",
              "kubectl get cephclusters,cephblockpools,cephobjectstores -A -o wide",
              "kubectl -n rook-ceph get cephcluster rook-ceph -o jsonpath='{.status.ceph}'",
              "kubectl -n rook-ceph logs deploy/rook-ceph-operator --tail=100",
              "kubectl -n rook-ceph logs -l app=rook-ceph-osd-prepare --tail=50 --all-containers",
              "kubectl get pvc,volumesnapshots -A",
              "kubectl get clusters.postgresql.cnpg.io,backups.postgresql.cnpg.io,jobs -A",
              "lsblk -o NAME,TYPE,SIZE,PARTLABEL,FSTYPE",
              "free -m",
              "df -h /",
          ]:
              print(server.execute(cmd)[1])
          print(acme.execute("journalctl -u pebble -u knot -u 's3-*' --no-pager | tail -n 80")[1])
          images()

      # What each container runs, by digest: how images only known by tag here get pinned.
      def images():
          status, out = server.execute(
              "kubectl get pods -A -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}"
              "{.image}{\" \"}{.imageID}{\"\\n\"}{end}{end}' | sort -u"
          )
          print(out)

      # QEMU's peak memory per machine, and what the runner has left.
      def memory():
          try:
              for machine in machines:
                  with open(f"/proc/{getattr(machine, 'pid', None)}/status") as status:
                      print(machine.name, [line.strip() for line in status if line.startswith(("VmHWM", "VmRSS"))])
              with open("/proc/meminfo") as meminfo:
                  print([line.strip() for line in meminfo if line.startswith("MemAvailable")])
          except Exception as e:
              print("memory:", e)

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
                  "kubectl -n flux-system wait kustomization --all --for=condition=Ready --timeout=0", timeout=2700
              )
              server.succeed("kubectl wait helmrelease -A --all --for=condition=Ready --timeout=0")
              images()
              memory()

          with subtest("Both CAs know our accounts, and hosts got their certificates over DNS-01 through the ACME zone"):
              for issuer, directory in [("public", setting("ACME_SERVER")), ("standby", setting("ACME_STANDBY_SERVER"))]:
                  uri = server.succeed(f"kubectl get clusterissuer {issuer} -o jsonpath='{{.status.acme.uri}}'").strip()
                  assert uri.startswith(directory.removesuffix("dir")), (issuer, uri)
              # The answers went in with cert-manager's key, through the node's address for pods.
              server.succeed("journalctl -u knot | grep -q '${acmeZone}.\\] DDNS, finished, serial'")
              # And came out again once the CA had seen them.
              server.wait_until_succeeds(
                  "kdig @${server} AXFR ${acmeZone} > /tmp/acme.zone && grep -qw SOA /tmp/acme.zone && ! grep -qw TXT /tmp/acme.zone",
                  timeout=120,
              )

          with subtest("Every Secret, Flux's and the tenants' included, is stored encrypted with secretbox"):
              prefixes = server.succeed("secret-prefixes").split()
              assert prefixes == ["k8s:enc:secretbox:v1:secretboxkey:"], prefixes

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
              # Such as a chart's hook, whose release then only got through on a retry.
              failed = [
                  j["metadata"]["name"] for j in items("jobs")
                  if any(c["type"] == "Failed" and c["status"] == "True" for c in j.get("status", {}).get("conditions", []))
              ]
              assert not failed, failed
              # No chart's claim waits for a class nobody gives it.
              pending = [f"{c['metadata']['namespace']}/{c['metadata']['name']}" for c in items("pvc") if c["status"]["phase"] != "Bound"]
              assert not pending, pending
              classes = sorted(c["metadata"]["name"] for c in items("storageclasses"))
              assert classes == ["ceph-block", "ceph-bucket"], classes
              # The Barman plugin's certificates for its connection with the operator, from its own namespace's CA.
              server.succeed("kubectl -n cloudnative-pg wait certificate --all --for=condition=Ready --timeout=0")

          with subtest("The platform's pods run at its priority, tenants' at theirs"):
              labels = {n["metadata"]["name"]: n["metadata"].get("labels", {}) for n in items("namespaces")}
              for p in items("pods"):
                  ns = p["metadata"]["namespace"]
                  if "suveraen/tenant" in labels[ns]:
                      want = "tenant"
                  elif ns == "flux-system" or labels[ns].get("suveraen/tier") == "platform":
                      want = "platform"
                  else:
                      continue
                  assert p["spec"].get("priorityClassName") == want, (p["metadata"]["name"], ns, p["spec"].get("priorityClassName"))

          with subtest("The cluster's own ranges in its settings, which the way to the internet leaves out, hold its pods, Services and nodes"):
              def within(address, kind):
                  address = ipaddress.ip_address(address)
                  assert address in ipaddress.ip_network(setting(f"{kind}_CIDR_V{address.version}")), (kind, address)

              for p in items("pods"):
                  if not p["spec"].get("hostNetwork"):
                      for ip in p["status"].get("podIPs", []):
                          within(ip["ip"], "POD")
              for s in items("services"):
                  for ip in s["spec"].get("clusterIPs", []):
                      if ip != "None":
                          within(ip, "SERVICE")
              for n in items("nodes"):
                  for address in n["status"]["addresses"]:
                      if address["type"] == "InternalIP":
                          within(address["address"], "NODE")

          def ceph(args):
              return json.loads(server.succeed(
                  "kubectl -n rook-ceph exec deploy/rook-ceph-operator -- ceph --connect-timeout=10"
                  f" --conf=/var/lib/rook/rook-ceph/rook-ceph.config {args} -f json"
              ))

          def apply(obj):
              server.succeed(f"echo {shlex.quote(json.dumps(obj))} | kubectl apply -f -")

          def finished(namespace, pod, timeout=600):
              server.wait_until_succeeds(
                  f"kubectl -n {namespace} get pod {pod} -o jsonpath='{{.status.phase}}' | grep -xE 'Succeeded|Failed'",
                  timeout=timeout,
              )
              server.succeed(f"kubectl -n {namespace} get pod {pod} -o jsonpath='{{.status.phase}}' | grep -x Succeeded")
              return server.succeed(f"kubectl -n {namespace} logs {pod}")

          # A pod that meets the restricted standard, with the app's image, which has a shell and curl.
          podinfo = server.succeed(
              "kubectl get pods -A -o jsonpath='{.items[*].spec.containers[*].image}' | tr ' ' '\\n' | grep -m1 podinfo"
          ).strip()

          def restricted(namespace, name, command, labels={}, **spec):
              return {
                  "apiVersion": "v1",
                  "kind": "Pod",
                  "metadata": {"name": name, "namespace": namespace, "labels": labels},
                  "spec": {
                      "restartPolicy": "Never",
                      "securityContext": {
                          "runAsNonRoot": True, "runAsUser": 65534, "runAsGroup": 65534, "fsGroup": 65534,
                          "seccompProfile": {"type": "RuntimeDefault"},
                      },
                      "containers": [{
                          "name": "probe",
                          "image": podinfo,
                          "command": ["sh", "-c", command],
                          "securityContext": {"allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]}},
                          "volumeMounts": spec.pop("mounts", []),
                          "envFrom": spec.pop("env", []),
                      }],
                      **spec,
                  },
              }

          with subtest("Ceph is healthy: three monitors, an encrypted OSD per disk with its DB apart, three copies everywhere"):
              server.wait_until_succeeds(
                  "kubectl -n rook-ceph get cephcluster rook-ceph -o jsonpath='{.status.ceph.health}' | grep -x HEALTH_OK",
                  timeout=900,
              )
              disks = ${builtins.toJSON nodes.server.suveraen.storage.ceph.disks}
              assert len(ceph("mon dump")["mons"]) == 3
              osds = ceph("osd dump")["osds"]
              assert len(osds) == len(disks) and all(o["up"] == 1 and o["in"] == 1 for o in osds), osds
              assert sorted(ceph("osd crush class ls-osd hdd")) == sorted(o["osd"] for o in osds)
              for meta in ceph("osd metadata"):
                  assert meta["bluefs_dedicated_db"] == "1", meta

              def below(device):
                  tree = json.loads(server.succeed(f"lsblk -J -o NAME,TYPE {device}"))["blockdevices"][0]

                  def walk(d):
                      return [t for c in d.get("children", []) for t in [c["type"]] + walk(c)]

                  return walk(tree)

              # Both the data and the DB are opened through dm-crypt.
              for slot in range(len(disks)):
                  assert "crypt" in below(f"/dev/disk/by-osd/osd{slot}"), slot
                  assert "crypt" in below(f"/dev/disk/by-partlabel/osd{slot}-db"), slot
              domain = setting("CEPH_FAILURE_DOMAIN")
              rules = {r["rule_id"]: r["steps"] for r in ceph("osd crush rule dump")}
              pools = ceph("osd pool ls detail")
              assert {".mgr", "block", "objects.rgw.buckets.data"} <= {p["pool_name"] for p in pools}, pools
              for pool in pools:
                  assert (pool["size"], pool["min_size"]) == (3, 2), pool
                  assert any(step.get("type") == domain for step in rules[pool["crush_rule"]]), (pool, rules)

          with subtest("A block volume binds, its snapshot restores, and it outlives its claim"):
              server.succeed("kubectl create namespace volumes")

              def claim(name, **spec):
                  return {
                      "apiVersion": "v1",
                      "kind": "PersistentVolumeClaim",
                      "metadata": {"name": name, "namespace": "volumes"},
                      "spec": {
                          "storageClassName": "ceph-block",
                          "accessModes": ["ReadWriteOnce"],
                          "resources": {"requests": {"storage": "1Gi"}},
                      } | spec,
                  }

              def on(name, claim_name, command):
                  return restricted(
                      "volumes", name, command,
                      mounts=[{"name": "data", "mountPath": "/data"}],
                      volumes=[{"name": "data", "persistentVolumeClaim": {"claimName": claim_name}}],
                  )

              apply(claim("data"))
              apply(on("writer", "data", "echo kept > /data/marker && sync"))
              finished("volumes", "writer")
              apply({
                  "apiVersion": "snapshot.storage.k8s.io/v1",
                  "kind": "VolumeSnapshot",
                  "metadata": {"name": "data", "namespace": "volumes"},
                  "spec": {"volumeSnapshotClassName": "ceph-block", "source": {"persistentVolumeClaimName": "data"}},
              })
              server.wait_until_succeeds(
                  "kubectl -n volumes get volumesnapshot data -o jsonpath='{.status.readyToUse}' | grep -x true", timeout=300
              )
              apply(claim("restored", dataSource={"apiGroup": "snapshot.storage.k8s.io", "kind": "VolumeSnapshot", "name": "data"}))
              apply(on("reader", "restored", "cat /data/marker"))
              assert finished("volumes", "reader").strip() == "kept"
              volume = server.succeed("kubectl -n volumes get pvc data -o jsonpath='{.spec.volumeName}'").strip()
              server.succeed("kubectl -n volumes delete pod writer reader && kubectl -n volumes delete pvc data --timeout=120s")
              server.wait_until_succeeds(
                  f"kubectl get pv {volume} -o jsonpath='{{.status.phase}}' | grep -x Released", timeout=120
              )

          with subtest("The object store gives a claim a bucket and keys of its own, reached only by pods allowed to"):
              # Tenants' database namespaces are the store's clients (platform/ceph); this one stands in for one.
              server.succeed("kubectl create namespace objects && kubectl label namespace objects suveraen/app=postgres")
              apply({
                  "apiVersion": "objectbucket.io/v1alpha1",
                  "kind": "ObjectBucketClaim",
                  "metadata": {"name": "probe", "namespace": "objects"},
                  "spec": {"bucketName": "probe", "storageClassName": "ceph-bucket"},
              })
              server.wait_until_succeeds(
                  "kubectl -n objects get objectbucketclaim probe -o jsonpath='{.status.phase}' | grep -x Bound", timeout=600
              )
              s3 = (
                  'curl -fsS -m 10 --aws-sigv4 "aws:amz:''${BUCKET_REGION:-us-east-1}:s3"'
                  ' --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" "http://$BUCKET_HOST:$BUCKET_PORT/$BUCKET_NAME/marker"'
              )
              keys = [{"secretRef": {"name": "probe"}}, {"configMapRef": {"name": "probe"}}]
              apply(restricted(
                  "objects", "client", f"echo kept > /tmp/marker && {s3} -T /tmp/marker && {s3}",
                  labels={"suveraen/object-store": "client"}, env=keys,
              ))
              assert finished("objects", "client").strip() == "kept"
              apply(restricted("objects", "other", "sleep 600", env=keys))
              server.succeed("kubectl -n objects wait pod other --for=condition=Ready --timeout=300s")
              status, out = server.execute(f"kubectl -n objects exec other -- sh -c {shlex.quote(s3)} 2>&1")
              assert status in [7, 28], (status, out)

          with subtest("Every route answers through the gateway with a certificate from the CA, and port 80 redirects there"):
              forge.succeed("curl -fsS --cacert ${caCert} https://acme.test:15000/roots/0 > /tmp/ca.crt")
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

          # A tenant's own Kustomization is tenant-<id>, labelled with its ID.
          tenants = sorted(
              k["metadata"]["labels"]["suveraen/tenant"]
              for k in json.loads(server.succeed("kubectl -n flux-system get kustomization -l suveraen/tenant -o json"))["items"]
              if k["metadata"]["name"] == "tenant-" + k["metadata"]["labels"]["suveraen/tenant"]
          )
          assert tenants == sorted(os.listdir("${cluster}/tenants")), tenants
          assert len(tenants) >= 2, tenants
          first, second = tenants[0], tenants[1]

          def get(cmd):
              return json.loads(server.succeed(f"{cmd} -o json"))

          def routes(tenant):
              return get(f"kubectl get httproute -A -l suveraen/tenant={tenant}")["items"]

          def hosts_of(tenant, namespace=None):
              return sorted(
                  h for r in routes(tenant) if namespace in [None, r["metadata"]["namespace"]] for h in r["spec"]["hostnames"]
              )

          def backends(tenant):
              # Each Service a tenant's routes lead to: its namespace, name and port.
              return sorted(
                  {(r["metadata"]["namespace"], b["name"], b["port"]) for r in routes(tenant)
                   for rule in r["spec"].get("rules", []) for b in rule.get("backendRefs", [])}
              )

          def fetch(host):
              return f"curl -fsS --cacert /tmp/ca.crt --resolve {host}:443:${server} https://{host}/"

          with subtest("Each tenant runs in exactly the namespaces its manifest asks for"):
              for tenant in tenants:
                  with open(f"${cluster}/tenants/{tenant}/apps/kustomization.yaml") as manifest:
                      apps = set(re.findall(r"/apps/([a-z0-9]+)/ks\.yaml$", manifest.read(), re.MULTILINE))
                  namespaces = server.succeed(f"kubectl get namespace -l suveraen/tenant={tenant} -o name").split()
                  assert sorted(namespaces) == sorted(f"namespace/{tenant}-{app}" for app in apps), (tenant, namespaces)

          with subtest("Each tenant's hello answers on every one of its hosts with that tenant's own settings"):
              hello = {t: hosts_of(t, f"{t}-hello") for t in tenants}
              hello = {t: hosts for t, hosts in hello.items() if hosts}
              assert len(hello) >= 2, hello
              domains = {t: base64.b64decode(get(f"kubectl -n flux-system get secret tenant-{t}")["data"]["TENANT_DOMAIN"]).decode() for t in hello}
              for tenant, hosts in hello.items():
                  for host in hosts:
                      forge.succeed(f"{fetch(host)} | grep -F 'hello from {tenant} at {domains[tenant]}'")
              # A tenant may serve its own domain itself.
              assert any(domains[t] in hosts for t, hosts in hello.items()), domains

          with subtest("A tenant's pods reach its own services but no other tenant's or the gateway's, and nothing else reaches them"):
              def url(namespace, service, port):
                  return f"http://{service}.{namespace}.svc:{port}/"

              def blocked(cmd):
                  # Refused or dropped: not a name that doesn't resolve, nor a probe that didn't run.
                  status, out = server.execute(f"{cmd} 2>&1")
                  assert status in [7, 28], (cmd, status, out)

              home, service, _ = backends(first)[0]
              inside = f"kubectl -n {home} exec svc/{service} -- curl -fsS -m 5 -o /dev/null"
              for backend in backends(first):
                  if backend[0] == home:
                      server.succeed(f"{inside} {url(*backend)}")
              for other in tenants[1:]:
                  assert backends(other), other
                  for backend in backends(other):
                      blocked(f"{inside} {url(*backend)}")
              blocked(f"{inside} http://traefik.gateway.svc/")
              # The app's image has curl, so the probes outside the tenants use it too.
              image = server.succeed(f"kubectl -n {home} get pods -o jsonpath='{{.items[0].spec.containers[0].image}}'").strip()

              def probe(namespace, resources=None, **spec):
                  return {
                      "apiVersion": "v1",
                      "kind": "Pod",
                      "metadata": {"name": "probe", "namespace": namespace},
                      "spec": {
                          "securityContext": {"runAsNonRoot": True, "runAsUser": 65534, "seccompProfile": {"type": "RuntimeDefault"}},
                          "containers": [
                              {
                                  "name": "probe",
                                  "image": image,
                                  "securityContext": {"allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]}},
                                  "resources": resources or {},
                              }
                          ],
                          **spec,
                      },
                  }

              def create(obj, *flags):
                  return f"echo {shlex.quote(json.dumps(obj))} | kubectl create {' '.join(flags)} -f -"

              # A namespace without network policies of its own, so only the tenants' policies stand in the way.
              server.succeed(
                  f"kubectl create namespace probe && {create(probe('probe'))}"
                  " && kubectl -n probe wait pod probe --for=condition=Ready --timeout=300s"
              )
              outside = "kubectl -n probe exec probe -- curl -fsS -m 5 -o /dev/null"
              server.succeed(f"{outside} http://traefik.gateway.svc/")
              for tenant in tenants:
                  for backend in backends(tenant):
                      blocked(f"{outside} {url(*backend)}")

          with subtest("Tenants can't take each other's namespaces or hosts, keep Gateways outside the gateway, or outgrow their quota"):
              def denied_by(cmd, reason):
                  out = server.fail(f"{cmd} 2>&1")
                  assert reason in out, out

              def copy(kind, obj, change):
                  obj = get(f"kubectl -n {obj['metadata']['namespace']} get {kind} {obj['metadata']['name']}")
                  obj["metadata"] = {
                      "name": "probe",
                      "namespace": obj["metadata"]["namespace"],
                      "labels": obj["metadata"].get("labels", {}),
                  }
                  change(obj)
                  return create(obj, "--dry-run=server")

              def policy(name):
                  return f"ValidatingAdmissionPolicy '{name}'"

              denied_by(
                  f"kubectl label namespace {second}-hello suveraen/tenant={first} --overwrite --dry-run=server",
                  policy("tenant-namespaces"),
              )
              denied_by(f"kubectl create namespace {first}-probe --dry-run=server", policy("tenant-namespaces"))
              host = hosts_of(first)[0]
              theirs = routes(second)[0]
              gateway = {"metadata": {"namespace": "gateway", "name": theirs["spec"]["parentRefs"][0]["name"]}}
              denied_by(copy("httproute", theirs, lambda r: r["spec"].update(hostnames=[host])), policy("hostnames"))
              denied_by(copy("gateway", gateway, lambda g: g["spec"]["listeners"][0].update(hostname=host)), policy("hostnames"))
              denied_by(copy("certificate", gateway, lambda c: c["spec"].update(dnsNames=[host])), policy("hostnames"))
              denied_by(
                  copy("gateway", gateway, lambda g: g["metadata"].update(namespace=f"{second}-hello")), policy("edge-objects")
              )
              denied_by(create(probe(home, priorityClassName="platform"), "--dry-run=server"), policy("tenant-priority"))
              denied_by(create(probe(home, {"limits": {"memory": "64Gi"}}), "--dry-run=server"), "exceeded quota")

          def psql(namespace, pod, query, **conn):
              # Connects as the app does, with the Secret its namespace holds unless told otherwise.
              target = " ".join(f"{k}={v}" for k, v in conn.items())
              return server.execute(
                  f"kubectl -n {namespace} exec {pod} -- sh -c "
                  + shlex.quote(
                      'PGPASSWORD="$password" PGCONNECT_TIMEOUT=5 psql -tA -v ON_ERROR_STOP=1'
                      f' "host=$host port=$port dbname=$dbname user=$username sslmode=$sslmode {target}" -c "{query}"'
                  )
                  + " 2>&1"
              )

          postgres_image = server.succeed(
              "kubectl get clusterimagecatalog postgresql -o jsonpath='{.spec.images[0].image}'"
          ).strip()

          def client(namespace, secret):
              pod = restricted(namespace, "psql", "sleep 3600", env=[{"secretRef": {"name": secret}}])
              pod["spec"]["containers"][0] |= {
                  "image": postgres_image,
                  "resources": {"requests": {"cpu": "10m", "memory": "32Mi"}, "limits": {"memory": "96Mi"}},
              }
              apply(pod)
              server.succeed(f"kubectl -n {namespace} wait pod psql --for=condition=Ready --timeout=300s")

          def archived(namespace):
              # What was written so far, in a WAL segment of its own that is then archived.
              local = f"kubectl -n {namespace} exec postgres-1 -c postgres -- psql -tAc"
              count = int(server.succeed(f"{local} 'select archived_count from pg_stat_archiver'").strip())
              server.succeed(
                  f"{local} 'create table if not exists archived (at timestamptz); insert into archived values (now())'"
                  f" && {local} 'select pg_switch_wal()'"
              )
              server.wait_until_succeeds(
                  f"{local} 'select archived_count > {count} and failed_count = 0 from pg_stat_archiver' | grep -x t",
                  timeout=300,
              )

          def recoverable(namespace, generation):
              server.wait_until_succeeds(
                  f"kubectl -n {namespace} get objectstore postgres"
                  f" -o jsonpath='{{.status.serverRecoveryWindow.postgres-{generation}.firstRecoverabilityPoint}}' | grep .",
                  timeout=600,
              )

          with subtest("Each tenant's PostgreSQL archives its WAL and base backups to its own bucket"):
              for tenant in tenants:
                  ns = f"{tenant}-postgres"
                  server.succeed(
                      f"kubectl -n {ns} wait cluster postgres --for=condition=ContinuousArchiving --timeout=0"
                  )
                  recoverable(ns, "g1")
                  archived(ns)

          with subtest("An app reaches its own database alone, and only from its own namespace"):
              client(f"{first}-hello", "db")
              status, out = psql(f"{first}-hello", "psql", "create table probe (v text); insert into probe values ('kept')")
              assert status == 0, out
              for other in [{"dbname": "postgres"}, {"dbname": "app"}, {"user": "postgres"}, {"password": "wrong"}]:
                  status, out = psql(f"{first}-hello", "psql", "select 1", **other)
                  assert status != 0 and ("pg_hba.conf" in out or "authentication failed" in out), (other, out)
              # The other tenant's app, with its own credentials, and a namespace without policies don't get through.
              client(f"{second}-hello", "db")
              status, out = psql(f"{second}-hello", "psql", "select 1", host=f"postgres-rw.{first}-postgres.svc")
              assert status != 0 and "timeout expired" in out, out
              apply({"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "db", "namespace": "probe"},
                     "stringData": {"host": f"postgres-rw.{first}-postgres.svc", "port": "5432", "dbname": "hello",
                                    "username": "hello", "password": "unknown", "sslmode": "require"}})
              client("probe", "db")
              status, out = psql("probe", "psql", "select 1")
              assert status != 0 and "timeout expired" in out, out
              # Nor do apps reach the object store.
              blocked(f"{inside} http://rook-ceph-rgw-objects.rook-ceph.svc/")
              server.succeed(f"kubectl -n {first}-hello delete pod psql && kubectl -n {second}-hello delete pod psql")

          with subtest("A tenant's PostgreSQL takes no restore or new generation while it runs"):
              patch = f"kubectl -n {first}-postgres patch cluster postgres --dry-run=server --type merge -p"
              denied_by(f"""{patch} '{{"spec":{{"bootstrap":{{"recovery":{{"source":"origin"}}}}}}}}'""",
                        policy("postgres-clusters"))

          providers = ${builtins.toJSON (lib.genAttrs (map toString providers) s3Address)}

          def at(n, keys, args):
              key, secret = keys
              return acme.execute(
                  f"AWS_ACCESS_KEY_ID={key} AWS_SECRET_ACCESS_KEY={secret} AWS_DEFAULT_REGION=us-east-1"
                  f" AWS_ENDPOINT_URL=http://{providers[n]} HOME=/tmp aws {args} 2>&1"
              )

          def refused_at(n, keys, args):
              status, out = at(n, keys, args)
              assert status != 0 and "AccessDenied" in out, (n, args, out)

          def keys_of(tenant, n):
              secrets = f"${cluster}/tenants/{tenant}/secrets.yaml"
              return read(secrets, f"POSTGRES_BACKUP_{n}_ACCESS_KEY_ID"), read(secrets, f"POSTGRES_BACKUP_{n}_SECRET_ACCESS_KEY")

          def bucket_at(n, tenant):
              return setting(f"BACKUP_{n}_BUCKET_PREFIX") + tenant

          with subtest("A tenant's bucket goes off-site to both providers, encrypted, where the cluster's keys can't remove a copy"):
              ns = f"{first}-postgres"
              for n in providers:
                  assert setting(f"BACKUP_{n}_ENDPOINT") == f"http://s3-{n}.test", n
                  acme.wait_for_unit(f"s3-{n}-setup.service")
              archived(ns)
              server.succeed(f"kubectl -n {ns} create job push --from=cronjob/offsite")
              try:
                  server.wait_until_succeeds(f"kubectl -n {ns} wait job push --for=condition=Complete --timeout=0", timeout=600)
              finally:
                  print(server.execute(f"kubectl -n {ns} logs job/push --tail=40")[1])
              for n in providers:
                  root = (f"root-{n}", f"root-{n}-test-secret")
                  ours, bucket = keys_of(first, n), bucket_at(n, first)
                  # What the provider holds: rclone's encrypted files, under names it encrypted too.
                  data = f"/var/lib/s3-{n}/data/{bucket}"
                  stored = acme.succeed(f"cd {data} && find postgres -type f").split()
                  assert stored, n
                  # Encrypted names are base32hex, which has neither "-" nor "w".
                  plain = [f for f in stored if re.search(r"postgres-g|wals", f.removeprefix("postgres/"))]
                  assert not plain, plain
                  acme.succeed(
                      f"cd {data} && find postgres -type f | while read -r f; do test \"$(head -c 6 \"$f\")\" = RCLONE || exit 1; done"
                  )
                  key = stored[0]
                  status, out = at(n, root, f"s3api head-object --bucket {bucket} --key {key} --query '[ObjectLockMode,VersionId]' --output text")
                  assert status == 0, out
                  mode, version = out.split()
                  assert mode == "COMPLIANCE", out
                  # The cluster's key deletes nothing, shortens no lock, changes no bucket and reaches no other tenant's.
                  version = f"--bucket {bucket} --key {key} --version-id {version}"
                  refused_at(n, ours, f"s3api delete-object {version}")
                  refused_at(n, ours, f"s3api delete-object --bucket {bucket} --key {key}")
                  refused_at(n, ours, f"s3api put-object-retention {version} --retention"
                             f" Mode=GOVERNANCE,RetainUntilDate=$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)")
                  refused_at(n, ours, f"s3api put-object-lock-configuration --bucket {bucket} --object-lock-configuration"
                             """ '{"ObjectLockEnabled":"Enabled","Rule":{"DefaultRetention":{"Mode":"GOVERNANCE","Days":1}}}'""")
                  refused_at(n, ours, f"s3api delete-bucket-policy --bucket {bucket}")
                  refused_at(n, ours, f"s3api list-objects-v2 --bucket {bucket_at(n, second)}")
                  # Not even the provider's own key removes a locked copy.
                  refused_at(n, root, f"s3api delete-object {version}")

          def release(message, change):
              forge.succeed(
                  f"cd ${checkout} && {change}"
                  " && ${asCgit} git -c user.name=test -c user.email=test@example.org -c gpg.format=ssh"
                  f" -c user.signingkey=/srv/signer commit -q -a -S -m {message}"
                  " && ${asCgit} git push -q /srv/git/suveraen.git main"
              )
              signed = forge.succeed("${asCgit} git -C /srv/git/suveraen.git rev-parse main").strip()
              server.succeed(
                  "kubectl -n flux-system annotate gitrepository suveraen --overwrite reconcile.fluxcd.io/requestedAt=$(date +%s)"
              )
              server.wait_until_succeeds(
                  f"kubectl -n flux-system get gitrepository suveraen -o jsonpath='{{.status.artifact.revision}}' | grep -F {signed}",
                  timeout=300,
              )
              return signed

          with subtest("When the cluster's object store has lost a tenant's backups, a release brings its PostgreSQL back from a provider's copy"):
              ns = f"{first}-postgres"
              suspend = f"kubectl -n flux-system patch kustomization {first}-postgres-cluster --type merge -p"
              server.succeed(f"""{suspend} '{{"spec":{{"suspend":true}}}}'""")
              server.succeed(f"kubectl -n {ns} delete cluster postgres --timeout=300s")
              # The tenant's bucket in the cluster loses all its backups.
              wipe = restricted(
                  ns, "wipe",
                  "export HOME=/tmp RCLONE_CONFIG_RGW_TYPE=s3 RCLONE_CONFIG_RGW_PROVIDER=Ceph"
                  ' RCLONE_CONFIG_RGW_ENDPOINT="http://$BUCKET_HOST:$BUCKET_PORT"'
                  ' RCLONE_CONFIG_RGW_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" RCLONE_CONFIG_RGW_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"'
                  ' && rclone purge "rgw:$BUCKET_NAME/postgres-g1" && test -z "$(rclone lsf -R "rgw:$BUCKET_NAME")"',
                  labels={"suveraen/object-store": "client"},
                  env=[{"secretRef": {"name": "bucket"}}, {"configMapRef": {"name": "bucket"}}],
              )
              wipe["spec"]["containers"][0] |= {
                  "image": server.succeed(
                      f"kubectl -n {ns} get cronjob offsite -o jsonpath='{{.spec.jobTemplate.spec.template.spec.containers[0].image}}'"
                  ).strip(),
                  "resources": {"requests": {"cpu": "10m", "memory": "64Mi"}, "limits": {"memory": "256Mi"}},
              }
              apply(wipe)
              finished(ns, "wipe")
              knobs = {"POSTGRES_GENERATION": "g2", "POSTGRES_BOOTSTRAP": "recovery", "POSTGRES_ORIGIN": "g1",
                       "POSTGRES_RESTORE_FROM": "offsite-2"}
              lines = "".join(f"      {k}: {v}\\n" for k, v in knobs.items())
              release("restore", f"printf '{lines}' | ${asCgit} tee -a tenants/{first}/tenant.yaml >/dev/null")
              # Generation g1 comes back from the provider into the tenant's bucket first.
              server.wait_until_succeeds(f"kubectl -n {ns} wait job fetch-g2 --for=condition=Complete --timeout=0", timeout=600)
              server.wait_until_succeeds(
                  f"kubectl -n flux-system wait kustomization {first}-postgres --for=condition=Ready --timeout=0", timeout=600
              )
              server.succeed(f"""{suspend} '{{"spec":{{"suspend":false}}}}'""")
              server.wait_until_succeeds(f"kubectl -n {ns} wait cluster postgres --for=condition=Ready --timeout=0", timeout=1200)
              server.wait_until_succeeds(
                  f"kubectl -n flux-system wait kustomization {first}-postgres-cluster --for=condition=Ready --timeout=0",
                  timeout=600,
              )
              # With the app's data, which it reaches with its own credentials, and archiving as generation g2.
              client(f"{first}-hello", "db")
              for _ in range(60):
                  status, out = psql(f"{first}-hello", "psql", "select v from probe")
                  if status == 0:
                      break
                  time.sleep(5)
              assert status == 0 and out.strip() == "kept", out
              server.succeed(f"kubectl -n {first}-hello delete pod psql")
              recoverable(ns, "g2")

          with subtest("The standby CA issues too, with our external account there"):
              standby = {
                  "apiVersion": "cert-manager.io/v1",
                  "kind": "Certificate",
                  "metadata": {"name": "standby-probe", "namespace": "gateway", "labels": {"suveraen/tenant": first}},
                  "spec": {
                      "secretName": "standby-probe-tls",
                      "secretTemplate": {"labels": {"suveraen/tenant": first}},
                      "dnsNames": [hosts_of(first)[0]],
                      "issuerRef": {"kind": "ClusterIssuer", "name": "standby"},
                  },
              }
              server.succeed(f"echo {shlex.quote(json.dumps(standby))} | kubectl create -f -")
              server.wait_until_succeeds(
                  "kubectl -n gateway wait certificate standby-probe --for=condition=Ready --timeout=0", timeout=600
              )
              server.succeed("kubectl -n gateway delete certificate standby-probe")
              server.wait_until_fails("kubectl -n gateway get secret standby-probe-tls", timeout=120)

          with subtest("A host's key is labelled with its tenant, and goes with its certificate"):
              certs = get(f"kubectl -n gateway get certificate -l suveraen/tenant={first}")["items"]
              assert sorted(n for c in certs for n in c["spec"]["dnsNames"]) == sorted(set(hosts_of(first))), certs
              for cert in certs:
                  meta = get(f"kubectl -n gateway get secret {cert['spec']['secretName']}")["metadata"]
                  assert meta["labels"].get("suveraen/tenant") == first, meta
                  assert [(o["kind"], o["name"]) for o in meta.get("ownerReferences", [])] == [
                      ("Certificate", cert["metadata"]["name"])
                  ], meta

          with subtest("An app restarts when its settings change"):
              tenant = sorted(hello)[0]
              server.succeed(
                  f"kubectl -n {tenant}-hello patch configmap hello --type merge"
                  """ -p '{"data":{"PODINFO_UI_MESSAGE":"changed"}}'"""
              )
              forge.wait_until_succeeds(f"{fetch(hello[tenant][0])} | grep -F changed", timeout=180)

          with subtest("Removing a tenant takes its Kustomizations, hosts, keys and pods, and leaves its namespaces"):
              theirs = hosts_of(second)
              namespaces = server.succeed(f"kubectl get namespace -l suveraen/tenant={second} -o name").split()
              assert theirs and namespaces, (theirs, namespaces)
              signed = release(
                  "remove",
                  f"${asCgit} git rm -q -r tenants/{second} && ${asCgit} sed -i '\\#^  - ./tenants/{second}$#d' kustomization.yaml",
              )

              def gone(what):
                  server.wait_until_succeeds(f"test -z \"$(kubectl get {what} -o name)\"", timeout=600)

              gone(f"kustomization,secret -n flux-system -l suveraen/tenant={second}")
              gone(f"gateway,certificate,secret -n gateway -l suveraen/tenant={second}")
              gone(f"helmrelease,httproute,networkpolicy -A -l suveraen/tenant={second}")
              # Its PostgreSQL and bucket are never pruned: they go with the namespace alone.
              server.succeed(f"kubectl -n {second}-postgres get cluster postgres && kubectl -n {second}-postgres get objectbucketclaim bucket")
              for namespace in namespaces:
                  if namespace != f"namespace/{second}-postgres":
                      gone(f"pods -n {namespace.removeprefix('namespace/')}")
              assert server.succeed(f"kubectl get namespace -l suveraen/tenant={second} -o name").split() == namespaces
              for host in hosts_of(first):
                  forge.succeed(f"{fetch(host)} -o /dev/null")
              for host in theirs:
                  forge.wait_until_fails(f"{fetch(host)} -o /dev/null", timeout=120)
              server.succeed(f"kubectl delete namespace -l suveraen/tenant={second} --timeout=300s")
              gone(f"namespace -l suveraen/tenant={second}")

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
              server.succeed(f"kubectl -n {first}-hello get deployment hello")

          with subtest("After a reboot Ceph comes back healthy, and the volumes with their data"):
              server.shutdown()
              server.start()
              server.wait_for_unit("k3s.service")
              apply(on("after", "restored", "cat /data/marker"))
              assert finished("volumes", "after", timeout=1200).strip() == "kept"
              server.wait_until_succeeds(
                  "kubectl -n rook-ceph get cephcluster rook-ceph -o jsonpath='{.status.ceph.health}' | grep -x HEALTH_OK",
                  timeout=900,
              )
              osds = ceph("osd dump")["osds"]
              assert all(o["up"] == 1 for o in osds), osds
          memory()
      except Exception:
          diagnose()
          raise
    '';
}
