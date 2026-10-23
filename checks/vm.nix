# Boots a watcher and a server in VMs. The server comes up dual-stack with Flux installed and pointed at the repository,
# out of reach of namespace admins, pods held to the restricted Pod Security Standard, secrets encrypted at rest with
# secretbox and only SSH and web ports open. Ceph's disks have stable names, their DB volumes lie on an array over both
# system disks, the kernel maps and decrypts Ceph's volumes without loading modules, and k3s keeps no volumes of its
# own. An app's charts reach only its own namespace and can neither widen who may act there nor publish ports, no
# namespace but Ceph's leaves restricted Pod Security, and no Service takes external IPs. A tenant's namespaces, names
# in flux-system and hosts are its own, Gateways, certificates and ACME orders stay in the gateway namespace, Issuers
# sign a namespace's own names only where the platform allows a private CA, a tenant's PostgreSQL takes no restore while
# it runs, and the platform's pods run at a priority no tenant's may ask for. Only the platform's backup jobs and movers
# reach out of a tenant's namespace, and its apps' charts can change neither what they run nor the keys their copies go
# with, nor make or delete a volume copied off-site. Hosts and pods resolve names through the node's own resolver, and
# clocks use NTS. The watcher's ntfy only takes known publishers and keeps its account API, stats and attachments
# closed; the server's alerts reach a phone account; Gatus raises an alert when the server's heartbeat stops; and the
# server falls back to a second channel when the watcher is gone. The server and its Flux only take commits signed by a
# release signer, the server never goes back to an older one, and it alerts when its configuration gets old. The
# server's checks read how old the backups the cluster records are and Ceph's health with an account that reads nothing
# else, and alert once per change, also when the cluster can't be read. Its etcd snapshots reach both providers
# encrypted to recovery keys, under a prefix its key can neither leave nor empty; with one provider down they still
# reach the other, and the phone hears of it. Wiped, the server comes back from a provider's copy through its restore
# command, with its token file alone; another token leaves a running server's own database in place.
# A LoadBalancer Service with the local traffic policy, as the gateway's is, hands its pods each client's own address.
{ pkgs, module }:
let
  repository = "https://example.invalid/suveraen.git";
  path = "./kubernetes/clusters/test";
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
  keys = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;
  signer = keys.snakeOilEd25519PublicKey;

  # "en*" would also match eth1, the test network, through its alternative names.
  uplink = "eth0";

  # The tenant policies match these kinds by group and resource, and the servers' checks read their status; their real
  # definitions come with the platform, which this test doesn't deploy.
  standIns = pkgs.writeText "stand-in-crds.json" (
    builtins.toJSON {
      apiVersion = "v1";
      kind = "List";
      items =
        map
          (
            {
              group,
              kind,
              scope ? "Namespaced",
              version ? "v1",
            }:
            let
              singular = pkgs.lib.toLower kind;
            in
            {
              apiVersion = "apiextensions.k8s.io/v1";
              kind = "CustomResourceDefinition";
              metadata = {
                name = "${singular}s.${group}";
                # Required for groups under k8s.io.
                annotations."api-approved.kubernetes.io" = "unapproved, stand-in for a test";
              };
              spec = {
                inherit group scope;
                names = {
                  inherit kind singular;
                  plural = "${singular}s";
                };
                versions = [
                  {
                    name = version;
                    served = true;
                    storage = true;
                    schema.openAPIV3Schema = {
                      type = "object";
                      x-kubernetes-preserve-unknown-fields = true;
                    };
                  }
                ];
              };
            }
          )
          [
            {
              group = "gateway.networking.k8s.io";
              kind = "Gateway";
            }
            {
              group = "gateway.networking.k8s.io";
              kind = "ListenerSet";
            }
            {
              group = "gateway.networking.k8s.io";
              kind = "HTTPRoute";
            }
            {
              group = "gateway.networking.k8s.io";
              kind = "ReferenceGrant";
            }
            {
              group = "cert-manager.io";
              kind = "Certificate";
            }
            {
              group = "cert-manager.io";
              kind = "CertificateRequest";
            }
            {
              group = "cert-manager.io";
              kind = "Issuer";
            }
            {
              group = "cert-manager.io";
              kind = "ClusterIssuer";
              scope = "Cluster";
            }
            {
              group = "acme.cert-manager.io";
              kind = "Order";
            }
            {
              group = "acme.cert-manager.io";
              kind = "Challenge";
            }
            {
              group = "postgresql.cnpg.io";
              kind = "Cluster";
            }
            {
              group = "barmancloud.cnpg.io";
              kind = "ObjectStore";
            }
            {
              group = "volsync.backube";
              kind = "ReplicationSource";
              version = "v1alpha1";
            }
            {
              group = "ceph.rook.io";
              kind = "CephCluster";
            }
          ];
    }
  );
  phone = "-u phone:${phonePassword}";
  # Phones read through the public host name and nginx, as the apps do.
  ops = "curl -fsS ${phone} 'http://alerts.test/ops/json?poll=1'";

  # The two providers the server copies its own state to, on the watcher at addresses of their own; its nginx holds
  # port 80.
  s3Address = n: "192.168.1.10${toString n}";
  s3Port = 9000;
  platformBucket = "test-platform";
in
pkgs.testers.runNixOSTest {
  name = "suveraen";

  nodes = {
    watcher =
      { lib, nodes, ... }:
      {
        imports = [
          module
          (import ./providers.nix {
            cluster = null;
            platform = {
              bucket = platformBucket;
              hosts = [ nodes.server.networking.hostName ];
            };
            address = s3Address;
            port = s3Port;
          })
        ];

        # Plain HTTP in the VM; certificates are nginx's ordinary ACME setup.
        services.nginx.virtualHosts = lib.genAttrs [ "alerts.test" "status.test" ] (_: {
          forceSSL = lib.mkForce false;
          enableACME = lib.mkForce false;
        });

        # The server's IPv6 node address is on the test network's link, but outside its prefix.
        networking.interfaces.eth1.ipv6.routes = map (address: {
          inherit address;
          prefixLength = 128;
        }) (lib.filter (lib.hasInfix ":") nodes.server.suveraen.cluster.nodeIP);

        networking.hostId = "5c1e0a7d";
        system.stateVersion = "26.05";
        environment.systemPackages = [
          pkgs.netcat
          pkgs.jq
          # What the operator restores the server with.
          pkgs.rclone
          pkgs.age
          pkgs.unzip
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
      { config, nodes, ... }:
      {
        imports = [
          module
          ./vm-server.nix
        ];

        virtualisation = {
          memorySize = 2048;
          diskSize = 4096;
          cores = 2;
        };

        # The test starts these far more often than their timers do.
        systemd.services.host-checks.startLimitIntervalSec = 0;
        systemd.services.offsite.startLimitIntervalSec = 0;
        systemd.services.offsite-collect.startLimitIntervalSec = 0;

        networking.hosts = {
          ${nodes.watcher.networking.primaryIPAddress} = [
            "alerts.test"
            "status.test"
          ];
          ${s3Address 1} = [ "s3-1.test" ];
          ${s3Address 2} = [ "s3-2.test" ];
        };

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

        environment.systemPackages = [
          pkgs.netcat
          pkgs.jq
          pkgs.git
        ];

        suveraen = {
          adminKeys = [ adminKey ];
          source = {
            inherit repository;
            signers = [ signer ];
          };
          cluster = {
            inherit path;
            sopsAgeKeyFile = toString (pkgs.writeText "age-key" "AGE-SECRET-KEY-TEST");
          };
          checks.files.probe = {
            path = "/var/lib/backup-probe";
            maxAge = "1h";
          };
          offsite = {
            recipients = [ keys.snakeOilEd25519PublicKey ];
            targets = pkgs.lib.genAttrs [ "1" "2" ] (n: {
              endpoint = "http://s3-${n}.test:${toString s3Port}";
              region = "us-east-1";
              bucket = platformBucket;
              credentialsFile = toString (
                pkgs.writeText "offsite-${n}" ''
                  AWS_ACCESS_KEY_ID=${config.networking.hostName}-${n}
                  AWS_SECRET_ACCESS_KEY=${config.networking.hostName}-${n}-test-secret
                ''
              );
            });
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
      # The server's own upgrade reference and resolve step, pointed at a repository inside the VM.
      inVM = builtins.replaceStrings [ repository ] [ "file:///srv/release" ];
      releaseFlake = pkgs.lib.escapeShellArg (inVM nodes.server.suveraen.source.flake);
      resolve = inVM nodes.server.systemd.services.nixos-upgrade.preStart;
      inherit (nodes.server.systemd.services.nixos-upgrade) postStart;
      staleDays = toString (nodes.server.suveraen.upgrade.staleAfterDays + 1);
    in
    ''
      import ipaddress
      import json
      import secrets
      import shlex

      start_all()
      # The checks and copies run when the test says.
      server.succeed("systemctl stop host-checks.timer offsite.timer")

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

      def stored_with_secretbox():
          prefixes = server.succeed("secret-prefixes").split()
          assert prefixes == ["k8s:enc:secretbox:v1:secretboxkey:"], prefixes

      with subtest("Secrets are encrypted at rest with secretbox"):
          status = json.loads(server.succeed("k3s secrets-encrypt status -o json"))
          assert status.get("enable") and status["activekey"] == "XSalsa20-POLY1305 secretboxkey", status
          stored_with_secretbox()

      with subtest("Flux is installed and follows the repository"):
          server.wait_until_succeeds("kubectl -n flux-system get deployment source-controller", timeout=300)
          server.wait_until_succeeds(
              "kubectl -n flux-system get gitrepository suveraen -o jsonpath='{.spec.url}' | grep -F '${repository}'"
          )
          # k3s applies its manifests one by one; the Kustomization may come a little after the GitRepository.
          server.wait_until_succeeds(
              "kubectl -n flux-system get kustomization cluster -o jsonpath='{.spec.path}' | grep -F '${path}'"
          )
          server.wait_until_succeeds("kubectl -n flux-system get secret sops-age", timeout=300)

      with subtest("Ceph's disks have stable names and DB volumes, each filling a group of its own on an array over both disks, and k3s keeps no volumes"):
          server.wait_for_unit("osd-db-volumes.service")
          for module in ["rbd", "dm_crypt"]:
              server.succeed(f"grep -q '^{module} ' /proc/modules")
          disks = ${builtins.toJSON nodes.server.suveraen.storage.ceph.disks}
          assert len(disks) == 3, disks
          for slot, disk in enumerate(disks):
              server.succeed(f"test $(readlink -f /dev/disk/by-osd/osd{slot}) = $(readlink -f {disk})")
              volume = f"/dev/disk/by-osd/osd{slot}-db"
              server.succeed(f"test $(readlink -f {volume}) = $(readlink -f /dev/osd{slot}-db/db)")
              counts = server.succeed(f"vgs --noheadings -o pv_count,lv_count,vg_free_count osd{slot}-db").split()
              assert counts == ["1", "1", "0"], (slot, counts)
              # On a partition of the array over the test's stand-ins for the two system disks.
              below = server.succeed(f"lsblk -snro NAME,TYPE $(readlink -f {volume})").split("\n")
              assert below[0].endswith(" lvm") and below[1].endswith(" part") and below[2].endswith(" raid1"), below
              for half in range(2):
                  name = server.succeed(f"basename $(readlink -f /dev/disk/by-id/virtio-db{half})").strip()
                  assert f"{name} disk" in below, (slot, below)
          server.fail("test -e /dev/disk/by-osd/osd3")
          server.succeed("test ! -e /var/lib/rancher/k3s/server/manifests/local-storage.yaml")
          server.succeed("test -z \"$(kubectl get storageclass -o name)\"")

      with subtest("Rights in a namespace don't extend to Flux, and Flux acts there only with that namespace's own account"):
          for controller in ["kustomize-controller", "helm-controller", "notification-controller"]:
              server.succeed(
                  f"kubectl -n flux-system get deployment {controller} -o jsonpath='{{.spec.template.spec.containers[0].args}}'"
                  " | grep -F -- --no-cross-namespace-refs=true"
              )
          for controller in ["kustomize-controller", "helm-controller"]:
              server.succeed(
                  f"kubectl -n flux-system get deployment {controller} -o jsonpath='{{.spec.template.spec.containers[0].args}}'"
                  " | grep -F -- --default-service-account=default"
              )
          server.succeed("kubectl -n flux-system get kustomization cluster -o jsonpath='{.spec.serviceAccountName}' | grep -x kustomize-controller")
          server.succeed(
              "kubectl create namespace member && kubectl -n member create serviceaccount member"
              " && kubectl -n member create rolebinding member --clusterrole=admin --serviceaccount=member:member"
          )
          member = "-n member --as=system:serviceaccount:member:member"
          server.wait_until_succeeds(f"kubectl auth can-i create deployments {member}")
          kinds = server.succeed("kubectl get crd -o name | grep -F .toolkit.fluxcd.io | cut -d/ -f2").split()
          assert len(kinds) >= 4, kinds
          for kind in kinds:
              server.fail(f"kubectl auth can-i create {kind} {member}")

      with subtest("Pods must meet the restricted Pod Security Standard unless the platform labels their namespace"):
          out = server.fail(f"kubectl run root --image=busybox --restart=Never {member} 2>&1")
          assert "violates PodSecurity" in out, out
          server.succeed(
              f"kubectl run restricted --image=busybox --restart=Never --dry-run=server {member}"
              """ --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"""
              """"containers":[{"name":"restricted","image":"busybox","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'"""
          )
          out = server.fail(f"kubectl label namespace member pod-security.kubernetes.io/enforce=privileged {member} 2>&1")
          assert "forbidden" in out, out
          # Flux's own pods are created, so they meet the standard too.
          server.wait_until_succeeds("test $(kubectl -n flux-system get pods --no-headers | wc -l) -ge 4", timeout=120)

      with subtest("An app's charts reach only its namespace, and can't widen who may act there or publish ports"):
          server.succeed(
              "kubectl apply -f ${../kubernetes/platform/policies/app/flux-app.yaml}"
              " -f ${../kubernetes/platform/policies/app/rolebinding-subjects.yaml}"
              " -f ${../kubernetes/platform/policies/app/published-services.yaml}"
          )
          # What components/app sets up in every app namespace.
          server.succeed(
              "kubectl create namespace app && kubectl label namespace app suveraen/tier=app"
              " && kubectl -n app create serviceaccount flux-deployer"
              " && kubectl -n app create rolebinding flux-deployer --clusterrole=flux-app --serviceaccount=app:flux-deployer"
          )
          deployer = "-n app --as=system:serviceaccount:app:flux-deployer"
          server.wait_until_succeeds(f"kubectl auth can-i create deployments {deployer}")
          for allowed in ["create secrets", "create services", "create roles", "create rolebindings", "create poddisruptionbudgets"]:
              server.succeed(f"kubectl auth can-i {allowed} {deployer}")
          for denied in [
              "create networkpolicies",
              "create ingresses",
              "create daemonsets",
              "create limitranges",
              "create resourcequotas",
              "create pods --subresource=exec",
              "patch namespaces",
              "create clusterrolebindings",
              "create customresourcedefinitions",
              "create helmreleases.helm.toolkit.fluxcd.io",
          ]:
              server.fail(f"kubectl auth can-i {denied} {deployer}")
          server.fail("kubectl auth can-i create deployments -n default --as=system:serviceaccount:app:flux-deployer")

          # Policies take a moment to load after they're created.
          def refused(cmd, policy):
              server.wait_until_fails(cmd)
              out = server.fail(f"{cmd} 2>&1")
              assert f"ValidatingAdmissionPolicy '{policy}'" in out, out

          refused(
              f"kubectl create rolebinding wide --clusterrole=flux-app --group=system:authenticated --dry-run=server {deployer}",
              "rolebinding-subjects",
          )
          refused(
              f"kubectl create rolebinding other --clusterrole=flux-app --serviceaccount=default:default --dry-run=server {deployer}",
              "rolebinding-subjects",
          )
          server.succeed(f"kubectl create rolebinding own --clusterrole=flux-app --serviceaccount=app:own --dry-run=server {deployer}")
          for kind in ["loadbalancer", "nodeport"]:
              refused(f"kubectl create service {kind} published --tcp=80 --dry-run=server {deployer}", "published-services")
          server.succeed(f"kubectl create service clusterip internal --tcp=80 --dry-run=server {deployer}")
          server.succeed(
              "kubectl create namespace published && kubectl label namespace published suveraen/publish=true"
              " && kubectl -n published create service loadbalancer published --tcp=80 --dry-run=server"
          )

      with subtest("No Service takes external IPs, which would be forwarded before the host firewall sees them"):
          out = server.fail(
              """echo '{"apiVersion":"v1","kind":"Service","metadata":{"name":"external","namespace":"default"},"""
              """"spec":{"ports":[{"port":80}],"externalIPs":["192.0.2.1"]}}' | kubectl create --dry-run=server -f - 2>&1"""
          )
          assert "externalIPs" in out, out
          # The added plugin comes on top of the one k3s enables itself.
          server.succeed("journalctl -u k3s | grep -F -- --enable-admission-plugins=NodeRestriction")

      with subtest("Pods get a process limit and the default seccomp filter"):
          kubelet = json.loads(server.succeed("kubectl get --raw /api/v1/nodes/server/proxy/configz"))["kubeletconfig"]
          assert kubelet["podPidsLimit"] == ${toString nodes.server.services.k3s.extraKubeletConfig.podPidsLimit}, kubelet
          assert kubelet["seccompDefault"], kubelet

      with subtest("Flux and the server only deploy commits signed by a release signer"):
          server.succeed("kubectl -n flux-system get gitrepository suveraen -o jsonpath='{.spec.verify.mode}' | grep -x HEAD")
          secret = server.succeed(
              "kubectl -n flux-system get gitrepository suveraen -o jsonpath='{.spec.verify.secretRef.name}'"
          ).strip()
          server.wait_until_succeeds(
              f"kubectl -n flux-system get secret {secret} -o jsonpath='{{.data.signer-0\\.sshpub}}'"
              " | base64 -d | grep -x '${pkgs.lib.concatStringsSep " " (pkgs.lib.take 2 (pkgs.lib.splitString " " signer))}'",
              timeout=120,
          )
          release_flake = """${releaseFlake}"""
          resolve = """${resolve}"""
          record = """${postStart}"""
          server.succeed(
              "install -m 600 ${keys.snakeOilEd25519PrivateKey} /root/signer"
              " && install -m 600 ${keys.snakeOilPrivateKey} /root/other && ssh-keygen -y -f /root/other > /root/other.pub"
              " && mkdir -p /run/suveraen-upgrade /var/lib/suveraen-upgrade"
              " && git init -q -b main /srv/release && cd /srv/release"
              " && git config user.name test && git config user.email test@example.org && git config gpg.format ssh"
              " && echo '{ outputs = _: { release = \"signed\"; }; }' > flake.nix && git add flake.nix"
              " && git -c user.signingkey=/root/signer commit -qS -m signed"
          )
          server.succeed(f"nix eval --raw {release_flake}#release | grep -x signed")
          server.succeed(f"{resolve} && grep -q '&rev=' /run/suveraen-upgrade/flake && {record}")
          # A newer signed release is taken; resetting the branch back to the older one isn't.
          server.succeed("cd /srv/release && git -c user.signingkey=/root/signer commit -q --allow-empty -S -m second")
          server.succeed(f"{resolve} && {record}")
          server.succeed("cd /srv/release && git reset -q --hard HEAD~1")
          server.fail(resolve)
          server.succeed("cd /srv/release && git reset -q --hard ORIG_HEAD")
          server.succeed("cd /srv/release && git commit -q --allow-empty -m unsigned")
          server.fail(f"nix eval --raw {release_flake}#release")
          server.fail(resolve)
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
          # The probes run as root and one on the host's network, which only a namespace the platform labels may do.
          server.succeed(
              "kubectl create namespace probe && kubectl label namespace probe pod-security.kubernetes.io/enforce=privileged"
          )
          busybox = server.succeed("k3s crictl images -o json | jq -r '.images[].repoTags[]' | grep busybox | head -n1").strip()
          server.succeed(
              f"kubectl -n probe run dns-probe --image={busybox} --image-pull-policy=Never --restart=Never --command -- nslookup probe.test."
          )
          server.wait_until_succeeds(
              "kubectl -n probe get pod dns-probe -o jsonpath='{.status.phase}' | grep -xE 'Succeeded|Failed'", timeout=120
          )
          server.succeed("kubectl -n probe logs dns-probe | grep -F 192.0.2.53")
          server.succeed(
              f"kubectl -n probe run dns-probe-host --image={busybox} --image-pull-policy=Never --restart=Never"
              """ --overrides='{"spec":{"hostNetwork":true}}' --command -- nslookup probe.test."""
          )
          server.wait_until_succeeds(
              "kubectl -n probe get pod dns-probe-host -o jsonpath='{.status.phase}' | grep -xE 'Succeeded|Failed'", timeout=120
          )
          server.succeed("kubectl -n probe logs dns-probe-host | grep -F 192.0.2.53")

      with subtest("Pods reach only the API server, the kubelet and the resolver on the host"):
          server.succeed(
              f"kubectl -n probe run host-ports --image={busybox} --image-pull-policy=Never --restart=Never --command -- sh -c"
              " 'for port in 6443 10250 2379; do timeout 10 nc -w 3 ${nodes.server.networking.primaryIPAddress} $port </dev/null"
              " && echo open $port || echo closed $port; done'"
          )
          server.wait_until_succeeds(
              "kubectl -n probe get pod host-ports -o jsonpath='{.status.phase}' | grep -xE 'Succeeded|Failed'", timeout=120
          )
          ports = server.succeed("kubectl -n probe logs host-ports")
          # etcd answers on the node's address, but only to the API server.
          for line in ["open 6443", "open 10250", "closed 2379"]:
              assert line in ports, ports

      with subtest("A load balancer with local traffic policy hands pods the client's own address"):
          # As the gateway's Service is (platform/gateway): ServiceLB only publishes the node's addresses, and
          # kube-proxy's rule for them hands a client's packets to a pod on that node, from the client's own address.
          server.succeed("k3s crictl images | grep -F rancher/klipper-lb")
          server.succeed("kubectl label namespace probe suveraen/publish=true")
          # The pod answers with the address each request came from, as it saw it.
          cgi = '#!/bin/sh\necho Content-Type: text/plain\necho\necho "$REMOTE_ADDR"\n'
          for obj in [
              {
                  "apiVersion": "v1",
                  "kind": "Pod",
                  "metadata": {"name": "lb-probe", "namespace": "probe", "labels": {"app": "lb-probe"}},
                  "spec": {
                      "containers": [{
                          "name": "httpd",
                          "image": busybox,
                          "imagePullPolicy": "Never",
                          "command": [
                              "sh", "-c", f"mkdir -p /www/cgi-bin && printf %s {shlex.quote(cgi)} > /www/cgi-bin/ip"
                              " && chmod +x /www/cgi-bin/ip && exec httpd -f -vv -p 8080 -h /www",
                          ],
                          "readinessProbe": {"tcpSocket": {"port": 8080}},
                      }],
                  },
              },
              {
                  "apiVersion": "v1",
                  "kind": "Service",
                  "metadata": {"name": "lb-probe", "namespace": "probe"},
                  "spec": {
                      "type": "LoadBalancer",
                      "ipFamilyPolicy": "PreferDualStack",
                      "externalTrafficPolicy": "Local",
                      "selector": {"app": "lb-probe"},
                      "ports": [{"port": 443, "targetPort": 8080}],
                  },
              },
          ]:
              server.succeed(f"echo {shlex.quote(json.dumps(obj))} | kubectl apply -f -")
          server.succeed("kubectl -n probe wait pod lb-probe --for=condition=Ready --timeout=300s")
          ingress = "kubectl -n probe get service lb-probe -o jsonpath='{.status.loadBalancer.ingress[*].ip}'"
          server.wait_until_succeeds(f"test $({ingress} | wc -w) = 2", timeout=300)
          published = {ipaddress.ip_address(a).version: a for a in server.succeed(ingress).split()}
          assert sorted(published) == [4, 6], published
          client = {
              4: ipaddress.ip_address("${nodes.watcher.networking.primaryIPAddress}"),
              6: ipaddress.ip_address("${nodes.watcher.networking.primaryIPv6Address}"),
          }

          def seen(version):
              address = published[version]
              host = f"[{address}]" if version == 6 else address
              # From the watcher's own address, not one of the providers' beside it.
              curl = f"curl -fsS -m 10 -g --interface {client[version]} http://{host}:443/cgi-bin/ip"
              try:
                  out = watcher.wait_until_succeeds(curl, timeout=120).strip()
              except Exception:
                  print(f"the watcher, at {client[version]}, got no answer from {address}:443")
                  explain()
                  raise
              try:
                  # busybox's httpd gives an IPv6 address in brackets, and its socket takes both families, so it sees an
                  # IPv4 client as a mapped IPv6 address.
                  at = ipaddress.ip_address(out.strip("[]"))
              except ValueError:
                  explain()
                  raise
              at = getattr(at, "ipv4_mapped", None) or at
              print(f"the watcher, at {client[version]}, reached {address}:443 and the pod saw it at {at}")
              return at

          # What rewrote or dropped the packets on the way: kube-proxy's and the host ports' rules, and those ServiceLB's
          # pod forwards by. Under the local policy that pod hands packets on to the node's NodePort, which this cluster
          # serves on loopback alone, so those go nowhere. Then the connections as conntrack holds them, whose reply
          # goes to the address the pod saw.
          def explain():
              chains = (
                  "'lb-probe|-A (PREROUTING|POSTROUTING|KUBE-SERVICES|KUBE-NODEPORTS|KUBE-POSTROUTING) "
                  "|-A (KUBE-EXT|KUBE-SVL|CNI-HOSTPORT|CNI-DN)-'"
              )
              svclb = "k3s crictl pods -q --label svccontroller.k3s.cattle.io/svcname=lb-probe"
              for cmd in [
                  "kubectl -n probe logs lb-probe --tail=20",
                  "kubectl -n kube-system get pods -o wide -l svccontroller.k3s.cattle.io/svcname=lb-probe",
                  "kubectl -n probe get service lb-probe -o yaml",
                  *[f"${pkgs.iptables}/bin/{save} -t nat | grep -E {chains}" for save in ["iptables-save", "ip6tables-save"]],
                  f"for pod in $({svclb}); do for c in $(k3s crictl ps -q --pod $pod); do"
                  " k3s crictl exec $c sh -c 'iptables-save -t nat; ip6tables-save -t nat; nft list ruleset'; done; done",
                  *[f"${pkgs.conntrack-tools}/bin/conntrack -L -f {family} -p tcp --dport 443"
                    for family in ["ipv4", "ipv6"]],
              ]:
                  print(f"$ {cmd}\n{server.execute(f'{cmd} 2>&1')[1]}")

          for version in [4, 6]:
              if seen(version) != client[version]:
                  explain()
                  raise AssertionError(f"the pod saw another address than the watcher's {client[version]}")

          # The cluster policy masquerades the packets, which the probe must be able to tell.
          policy = """kubectl -n probe patch service lb-probe -p '{"spec":{"externalTrafficPolicy":"%s"}}'"""
          server.succeed(policy % "Cluster")
          for version in [4, 6]:
              retry(lambda _: seen(version) != client[version], timeout_seconds=120)
          server.succeed(policy % "Local")
          for version in [4, 6]:
              retry(lambda _: seen(version) == client[version], timeout_seconds=120)

      with subtest("No namespace but Ceph's leaves the restricted Pod Security default, not even through Flux's own account"):
          # After the probes above, whose namespace the test labels privileged itself.
          server.succeed("kubectl apply -f ${../kubernetes/platform/policies/app/pod-security-labels.yaml}")
          flux = "--as=system:serviceaccount:flux-system:kustomize-controller"
          privileged = "kubectl label namespace member pod-security.kubernetes.io/enforce=privileged --dry-run=server"
          server.wait_until_fails(privileged)
          for cmd in [privileged, f"{privileged} {flux}"]:
              out = server.fail(f"{cmd} 2>&1")
              assert "pod-security-labels" in out, out
          server.succeed("kubectl label namespace member pod-security.kubernetes.io/enforce=restricted --dry-run=server")
          server.succeed("kubectl create namespace rook-ceph")
          for mode in ["enforce", "audit", "warn"]:
              server.succeed(f"kubectl label namespace rook-ceph pod-security.kubernetes.io/{mode}=privileged --dry-run=server {flux}")
              out = server.fail(f"kubectl label namespace rook-ceph pod-security.kubernetes.io/{mode}=baseline --dry-run=server 2>&1")
              assert "pod-security-labels" in out, out

      with subtest("A tenant's namespaces, names and hosts are its own, and Gateways and certificates stay at the gateway"):
          server.succeed(
              "kubectl apply -f ${standIns} && kubectl wait --for condition=established crd --all --timeout=120s"
              " && kubectl create namespace gateway && kubectl create namespace cert-manager"
              " && kubectl -n flux-system create configmap hostnames --from-literal=example.test=alpha"
              " --from-literal=one.test=alpha-hello --from-literal=org.test=bravo"
          )
          server.succeed(
              "kubectl apply -f ${../kubernetes/platform/policies/app/tenant-namespaces.yaml}"
              " -f ${../kubernetes/platform/policies/app/tenant-names.yaml}"
              " -f ${../kubernetes/platform/policies/app/edge-objects.yaml}"
              " -f ${../kubernetes/platform/policies/app/hostnames.yaml}"
              " -f ${../kubernetes/platform/policies/app/postgres-clusters.yaml}"
          )

          def dry(obj, verb="create"):
              return f"echo {shlex.quote(json.dumps(obj))} | kubectl {verb} --dry-run=server -f -"

          def labelled(tenant):
              return {"suveraen/tenant": tenant} if tenant else {}

          def namespace(name, tenant=None, **labels):
              labels = {f"suveraen/{k}": v for k, v in labels.items()} | labelled(tenant)
              return {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": name, "labels": labels}}

          def flux_system(kind, name, tenant):
              obj = {"metadata": {"name": name, "namespace": "flux-system", "labels": labelled(tenant)}}
              if kind == "Secret":
                  return obj | {"apiVersion": "v1", "kind": kind}
              spec = {"interval": "1h", "path": "./x", "prune": True, "sourceRef": {"kind": "GitRepository", "name": "x"}}
              return obj | {"apiVersion": "kustomize.toolkit.fluxcd.io/v1", "kind": kind, "spec": spec}

          def gateway(tenant, host, admits, namespace="gateway", source="Selector"):
              return {
                  "apiVersion": "gateway.networking.k8s.io/v1",
                  "kind": "Gateway",
                  "metadata": {"name": "probe", "namespace": namespace, "labels": labelled(tenant)},
                  "spec": {
                      "gatewayClassName": "traefik",
                      "listeners": [
                          {
                              "name": "https",
                              "protocol": "HTTPS",
                              "port": 8443,
                              "hostname": host,
                              "tls": {"mode": "Terminate", "certificateRefs": [{"name": "probe-tls"}]},
                              "allowedRoutes": {
                                  "kinds": [{"kind": "HTTPRoute"}],
                                  "namespaces": {
                                      "from": source,
                                      "selector": {"matchLabels": {"kubernetes.io/metadata.name": admits}},
                                  },
                              },
                          }
                      ],
                  },
              }

          def route(namespace, host):
              return {
                  "apiVersion": "gateway.networking.k8s.io/v1",
                  "kind": "HTTPRoute",
                  "metadata": {"name": "probe", "namespace": namespace},
                  "spec": {
                      "parentRefs": [{"name": "probe", "namespace": "gateway", "sectionName": "https"}],
                      "hostnames": [host],
                      "rules": [{"backendRefs": [{"name": "hello", "port": 9898}]}],
                  },
              }

          def certificate(tenant, namespace="gateway", **spec):
              return {
                  "apiVersion": "cert-manager.io/v1",
                  "kind": "Certificate",
                  "metadata": {"name": "probe", "namespace": namespace, "labels": labelled(tenant)},
                  "spec": {"secretName": "probe-tls", "issuerRef": {"kind": "ClusterIssuer", "name": "public"}} | spec,
              }

          # A namespace named <tenant>-<app> carries that tenant's label from creation, and only such a namespace does.
          refused(dry(namespace("alpha-x", tier="app")), "tenant-namespaces")
          for name in ["alpha-hello", "alpha-web", "bravo-hello"]:
              server.succeed(
                  f"echo {shlex.quote(json.dumps(namespace(name, name[:5], tier='app', app=name[6:])))} | kubectl create -f -"
              )
          refused(dry(namespace("alpha-y", "bravo", tier="app")), "tenant-namespaces")
          refused(dry(namespace("misc", "alpha", tier="app")), "tenant-namespaces")
          refused(dry(namespace("alpha-z", "alpha", tier="platform")), "tenant-namespaces")
          refused(dry(namespace("alpha-p", "alpha", tier="app", app="p", publish="true")), "tenant-namespaces")
          refused(dry(namespace("alpha-q", "alpha", tier="app")), "tenant-namespaces")
          refused(dry(namespace("alpha-q", "alpha", tier="app", app="web")), "tenant-namespaces")
          refused("kubectl label namespace bravo-hello suveraen/tenant=alpha --overwrite --dry-run=server", "tenant-namespaces")
          refused("kubectl label namespace bravo-hello suveraen/tenant- --dry-run=server", "tenant-namespaces")
          refused(dry(namespace("local-path", tier="platform")), "tenant-namespaces")
          server.succeed(dry(namespace("cert-manager"), "apply"))

          # tenant-<id> in flux-system is that tenant's, and its label goes on nothing else there.
          refused(dry(flux_system("Secret", "tenant-zzzzz", None)), "tenant-names")
          refused(dry(flux_system("Secret", "tenant-zzzzz", "alpha")), "tenant-names")
          refused(dry(flux_system("Secret", "alpha-hello", "alpha")), "tenant-names")
          refused(dry(flux_system("Kustomization", "tenant-zzzzz", None)), "tenant-names")
          refused(dry(flux_system("Kustomization", "reloader", "alpha")), "tenant-names")
          server.succeed(dry(flux_system("Secret", "tenant-alpha", "alpha")))
          server.succeed(dry(flux_system("Kustomization", "tenant-alpha", "alpha")))
          server.succeed(dry(flux_system("Kustomization", "alpha-hello-edge-hello", "alpha")))
          server.succeed(dry(flux_system("Kustomization", "reloader", None)))

          # Gateways and certificates only at the gateway, ClusterIssuers only from the platform; no ReferenceGrants or
          # Issuers.
          refused(dry(gateway("alpha", "hello.example.test", "alpha-hello", namespace="alpha-hello")), "edge-objects")
          refused(dry(certificate("alpha", "alpha-hello", dnsNames=["hello.example.test"])), "edge-objects")

          def request(namespace):
              return {
                  "apiVersion": "cert-manager.io/v1",
                  "kind": "CertificateRequest",
                  "metadata": {"name": "probe", "namespace": namespace},
                  "spec": {"request": "eA==", "issuerRef": {"kind": "ClusterIssuer", "name": "public"}},
              }

          def cluster_issuer(tenant):
              return {
                  "apiVersion": "cert-manager.io/v1",
                  "kind": "ClusterIssuer",
                  "metadata": {"name": "probe", "labels": labelled(tenant)},
                  "spec": {"selfSigned": {}},
              }

          refused(dry(request("alpha-hello")), "edge-objects")
          server.succeed(dry(request("gateway")))
          # cert-manager's startup check, a dry run in its own namespace, gets through; a real request there doesn't.
          server.succeed(dry(request("cert-manager")))
          refused(f"echo {shlex.quote(json.dumps(request('cert-manager')))} | kubectl create -f -", "edge-objects")

          def order(namespace):
              return {
                  "apiVersion": "acme.cert-manager.io/v1",
                  "kind": "Order",
                  "metadata": {"name": "probe", "namespace": namespace},
                  "spec": {"request": "eA==", "issuerRef": {"kind": "ClusterIssuer", "name": "public"}},
              }

          refused(dry(order("alpha-hello")), "edge-objects")
          refused(dry(order("cert-manager")), "edge-objects")
          server.succeed(dry(order("gateway")))
          refused(dry(cluster_issuer("alpha")), "edge-objects")
          server.succeed(dry(cluster_issuer(None)))
          refused(
              dry({"apiVersion": "cert-manager.io/v1", "kind": "Issuer", "metadata": {"name": "probe", "namespace": "alpha-hello"},
                   "spec": {"selfSigned": {}}}),
              "edge-objects",
          )
          refused(
              dry({"apiVersion": "gateway.networking.k8s.io/v1", "kind": "ReferenceGrant",
                   "metadata": {"name": "probe", "namespace": "alpha-hello"},
                   "spec": {"from": [{"group": "gateway.networking.k8s.io", "kind": "HTTPRoute", "namespace": "bravo-hello"}],
                            "to": [{"group": "", "kind": "Service"}]}}),
              "edge-objects",
          )
          refused(dry(certificate(None, "cert-manager", isCA=True, commonName="test CA")), "edge-objects")

          # Where the platform allows a private CA, a self-signed or CA Issuer signs the namespace's own internal names,
          # which the hostname map doesn't judge; ACME Issuers and ClusterIssuers don't sign there, nor Issuers elsewhere.
          server.succeed("kubectl create namespace private && kubectl label namespace private suveraen/private-ca=true")

          def issuer(namespace, **spec):
              meta = {"name": "probe", "namespace": namespace}
              return {"apiVersion": "cert-manager.io/v1", "kind": "Issuer", "metadata": meta, "spec": spec}

          own = {"group": "cert-manager.io", "kind": "Issuer", "name": "probe"}
          server.succeed(dry(issuer("private", selfSigned={})))
          server.succeed(dry(issuer("private", ca={"secretName": "probe-ca"})))
          server.succeed(dry(certificate(None, "private", commonName="barman-cloud-client", issuerRef=own)))
          server.succeed(dry(certificate(None, "private", dnsNames=["barman-cloud"], issuerRef=own)))
          server.succeed(dry(request("private") | {"spec": {"request": "eA==", "issuerRef": own}}))
          acme = {"server": "https://acme.test/dir", "privateKeySecretRef": {"name": "probe"}}
          refused(dry(issuer("private", acme=acme)), "edge-objects")
          # It names no host, so the hostname map can't refuse it as well.
          refused(dry(certificate(None, "private")), "edge-objects")
          refused(dry(certificate("alpha", dnsNames=["hello.example.test"], issuerRef=own)), "edge-objects")
          refused(dry(certificate("alpha", "alpha-hello", dnsNames=["hello.example.test"], issuerRef=own)), "edge-objects")
          refused(dry(namespace("alpha-ca", "alpha", tier="app", app="ca", **{"private-ca": "true"})), "tenant-namespaces")

          # A tenant's PostgreSQL takes no restore or new generation while it runs; resizing it is fine.
          cluster = {
              "apiVersion": "postgresql.cnpg.io/v1",
              "kind": "Cluster",
              "metadata": {"name": "postgres", "namespace": "alpha-web"},
              "spec": {
                  "instances": 1,
                  "bootstrap": {"initdb": {"database": "app", "owner": "app"}},
                  "plugins": [{"name": "barman-cloud.cloudnative-pg.io", "isWALArchiver": True,
                               "parameters": {"barmanObjectName": "postgres", "serverName": "postgres-g1"}}],
              },
          }
          server.succeed(f"echo {shlex.quote(json.dumps(cluster))} | kubectl create -f -")
          patch = "kubectl -n alpha-web patch cluster postgres --dry-run=server --type merge -p"
          server.succeed(f"""{patch} '{{"spec":{{"instances":2}}}}'""")
          refused(f"""{patch} '{{"spec":{{"bootstrap":{{"recovery":{{"source":"origin"}}}}}}}}'""", "postgres-clusters")
          refused(f"""{patch} '{{"spec":{{"externalClusters":[{{"name":"origin"}}]}}}}'""", "postgres-clusters")
          refused(
              "kubectl -n alpha-web patch cluster postgres --dry-run=server --type json"
              """ -p '[{"op":"replace","path":"/spec/plugins/0/parameters/serverName","value":"postgres-g2"}]'""",
              "postgres-clusters",
          )
          server.succeed("kubectl -n alpha-web delete cluster postgres")

          # Each host belongs to whom the longest matching entry of the hostname map names: a tenant, or one namespace.
          refused(dry(gateway("bravo", "hello.example.test", "bravo-hello")), "hostnames")
          server.succeed(dry(gateway("bravo", "hello.org.test", "bravo-hello")))
          server.succeed(dry(gateway("alpha", "hello.example.test", "alpha-hello")))
          server.succeed(dry(gateway("alpha", "one.test", "alpha-hello")))
          for obj in [
              gateway("alpha", "hello.org.test", "alpha-hello"),
              gateway("alpha", "hello.example.test", "bravo-hello"),
              gateway("alpha", "*.example.test", "alpha-hello"),
              gateway(None, "hello.example.test", "alpha-hello"),
              gateway("bravo", "evilorg.test", "bravo-hello"),
              gateway("alpha", "hello.example.test", "alpha-hello", source="All"),
              gateway("alpha", "one.test", "alpha-web"),
              route("bravo-hello", "hello.example.test"),
              route("alpha-web", "one.test"),
              certificate("alpha", dnsNames=["hello.org.test"]),
              certificate("alpha", dnsNames=["*.example.test"]),
              certificate("alpha", commonName="hello.org.test"),
              certificate("alpha", dnsNames=["hello.example.test"], commonName="hello.org.test"),
              certificate("alpha", dnsNames=["hello.example.test"], uris=["https://hello.org.test/"]),
              certificate("alpha", dnsNames=["hello.example.test"], ipAddresses=["192.0.2.1"]),
          ]:
              refused(dry(obj), "hostnames")
          for obj in [
              route("bravo-hello", "hello.org.test"),
              route("alpha-hello", "one.test"),
              certificate("bravo", dnsNames=["hello.org.test"]),
              certificate("alpha", dnsNames=["one.test", "hello.example.test"], commonName="one.test"),
          ]:
              server.succeed(dry(obj))
          server.succeed("""kubectl -n flux-system patch configmap hostnames --type merge -p '{"data":{"hello.org.test":"alpha"}}'""")
          refused(dry(gateway("bravo", "hello.org.test", "bravo-hello")), "hostnames")
          server.succeed("kubectl -n flux-system delete configmap hostnames")
          refused(dry(gateway("alpha", "hello.example.test", "alpha-hello")), "hostnames")

      with subtest("The platform's pods run ahead of tenants', whose pods can't ask for its priority"):
          server.succeed("kubectl get priorityclass tenant -o jsonpath='{.globalDefault}' | grep -x true")
          classes = server.succeed("kubectl -n flux-system get pods -o jsonpath='{.items[*].spec.priorityClassName}'").split()
          assert classes and set(classes) == {"platform"}, classes
          server.succeed("kubectl apply -f ${../kubernetes/platform/policies/app/tenant-priority.yaml}")

          def pod(namespace, priority=None):
              spec = {
                  "securityContext": {"runAsNonRoot": True, "runAsUser": 65534, "seccompProfile": {"type": "RuntimeDefault"}},
                  "containers": [
                      {
                          "name": "probe",
                          "image": "busybox",
                          "securityContext": {"allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]}},
                      }
                  ],
              }
              if priority:
                  spec["priorityClassName"] = priority
              return {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "probe", "namespace": namespace}, "spec": spec}

          refused(dry(pod("alpha-hello", "platform")), "tenant-priority")
          out = server.succeed(f"{dry(pod('alpha-hello'))} -o jsonpath='{{.spec.priorityClassName}}'")
          assert out.strip() == "tenant", out
          server.succeed(dry(pod("member", "platform")))

      with subtest("Only the platform's backup jobs reach out of a tenant's namespace, never its apps' charts"):
          server.succeed(
              "kubectl apply -f ${../kubernetes/platform/policies/app/egress-labels.yaml}"
              " && kubectl -n alpha-hello create rolebinding flux-deployer --clusterrole=flux-app"
              " --serviceaccount=alpha-hello:flux-deployer"
          )

          def labelled_pod(namespace, labels):
              obj = pod(namespace)
              obj["metadata"]["labels"] = labels
              return obj

          def template(kind, labels):
              spec = {"metadata": {"labels": labels}, "spec": pod("alpha-hello")["spec"] | {"restartPolicy": "Never"}}
              obj = {"metadata": {"name": "probe", "namespace": "alpha-hello"}}
              if kind == "Deployment":
                  spec["spec"]["restartPolicy"] = "Always"
                  return obj | {"apiVersion": "apps/v1", "kind": kind, "spec": {
                      "selector": {"matchLabels": labels}, "template": spec}}
              if kind == "Job":
                  return obj | {"apiVersion": "batch/v1", "kind": kind, "spec": {"template": spec}}
              return obj | {"apiVersion": "batch/v1", "kind": kind, "spec": {
                  "schedule": "0 0 * * *", "jobTemplate": {"spec": {"template": spec}}}}

          def by(account):
              return f"--as=system:serviceaccount:{account}"

          deployer = by("alpha-hello:flux-deployer")
          for label in ["suveraen/egress", "suveraen/object-store"]:
              labels = {label: "x"}
              refused(f"{dry(labelled_pod('alpha-hello', labels))} {deployer}", "egress-labels")
              for kind in ["Deployment", "Job", "CronJob"]:
                  refused(f"{dry(template(kind, labels))} {deployer}", "egress-labels")
              # Jobs' pods, and the jobs Flux applies from the repository and CronJobs make.
              server.succeed(f"{dry(labelled_pod('alpha-hello', labels))} {by('kube-system:job-controller')}")
              server.succeed(f"{dry(template('Job', labels))} {by('flux-system:kustomize-controller')}")
              server.succeed(f"{dry(template('Job', labels))} {by('kube-system:cronjob-controller')}")
              server.succeed(f"{dry(template('CronJob', labels))} {by('flux-system:kustomize-controller')}")
              # Outside tenants' namespaces nothing opens a way out for them.
              server.succeed(dry(labelled_pod("member", labels)))
          for kind in ["Deployment", "Job", "CronJob"]:
              server.succeed(f"{dry(template(kind, {'app': 'probe'}))} {deployer}")
          # Nor may they change what a pod or job that carries one runs, or the keys its copies go with, or delete a
          # volume that is copied off-site.
          mover = labelled_pod("alpha-hello", {"suveraen/egress": "internet"})
          server.succeed(f"echo {shlex.quote(json.dumps(mover))} | kubectl create -f - {by('kube-system:job-controller')}")
          refused(f"kubectl -n alpha-hello set image pod/probe probe=busybox:musl {deployer}", "egress-labels")
          refused(f"kubectl -n alpha-hello label pod probe suveraen/egress- {deployer}", "egress-labels")
          server.succeed(f"kubectl -n alpha-hello annotate pod probe probe=x {deployer}")
          server.succeed("kubectl -n alpha-hello delete pod probe --wait=false")
          # A CronJob's spec holds what its jobs run, such as the script that checks an app's copies.
          check = template("CronJob", {"suveraen/egress": "internet"})
          server.succeed(
              f"echo {shlex.quote(json.dumps(check))} | kubectl create -f - {by('flux-system:kustomize-controller')}"
          )
          command = json.dumps([
              {"op": "add", "path": "/spec/jobTemplate/spec/template/spec/containers/0/command", "value": ["sh"]}
          ])
          refused(
              f"kubectl -n alpha-hello patch cronjob probe --type=json -p {shlex.quote(command)} {deployer}",
              "egress-labels",
          )
          server.succeed("kubectl -n alpha-hello delete cronjob probe")
          server.succeed(
              "kubectl apply -f ${../kubernetes/platform/policies/app/backup-keys.yaml}"
              " -f ${../kubernetes/platform/policies/app/backup-volumes.yaml}"
              " && kubectl -n alpha-hello create secret generic offsite-1 --from-literal=RESTIC_REPOSITORY=s3:x"
          )
          refused(f"kubectl -n alpha-hello delete secret offsite-1 --dry-run=server {deployer}", "backup-keys")
          refused(
              f"kubectl -n alpha-hello patch secret offsite-1 -p '{{\"stringData\":{{\"RESTIC_REPOSITORY\":\"s3:y\"}}}}' {deployer}",
              "backup-keys",
          )
          refused(f"kubectl -n alpha-hello create secret generic offsite-2 --dry-run=server {deployer}", "backup-keys")
          server.succeed(f"kubectl -n alpha-hello create secret generic other --dry-run=server {deployer}")
          volume = {
              "apiVersion": "v1",
              "kind": "PersistentVolumeClaim",
              "metadata": {"name": "data", "namespace": "alpha-hello", "labels": {"suveraen/backup": "volsync"}},
              "spec": {"accessModes": ["ReadWriteOnce"], "resources": {"requests": {"storage": "1Gi"}}},
          }
          # Nor make one, which the servers' checks would expect copies of.
          refused(f"{dry(volume)} {deployer}", "backup-volumes")
          server.succeed(f"{dry(volume)} {by('flux-system:kustomize-controller')}")
          plain = volume | {"metadata": {"name": "plain", "namespace": "alpha-hello"}}
          server.succeed(f"{dry(plain)} {deployer}")
          server.succeed(f"echo {shlex.quote(json.dumps(volume))} | kubectl create -f -")
          server.succeed(f"echo {shlex.quote(json.dumps(plain))} | kubectl create -f -")
          refused(f"kubectl -n alpha-hello delete pvc data --dry-run=server {deployer}", "backup-volumes")
          refused(f"kubectl -n alpha-hello label pvc data suveraen/backup- {deployer}", "backup-volumes")
          refused(f"kubectl -n alpha-hello label pvc plain suveraen/backup=volsync {deployer}", "backup-volumes")
          server.succeed(f"kubectl -n alpha-hello annotate pvc data probe=x {deployer}")
          server.succeed("kubectl -n alpha-hello delete pvc/data pvc/plain secret/offsite-1")

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

      with subtest("A host running an old configuration says so"):
          server.succeed("systemctl start release-age.service")
          server.fail("${ops} | grep -F 'server: stale configuration'")
          server.succeed(
              "echo $(( $(date +%s) - ${staleDays} * 86400 )) > /var/lib/suveraen-upgrade/lastmodified"
          )
          server.succeed("systemctl start release-age.service")
          server.wait_until_succeeds("${ops} | grep -F 'server: stale configuration'")

      # The server's alerts so far with this title, as the phone reads them.
      def sent(title):
          out = server.succeed(f"${ops} | jq -c --arg t 'server: {title}' 'select(.title == $t)'")
          return [json.loads(line) for line in out.splitlines()]

      def keys(lines):
          return {line.split(": ")[0] for line in lines.splitlines()}

      def at(when):
          return server.succeed(f"date -u -d '{when}' +%FT%TZ").strip()

      def set_status(kind, ns, name, value, *flags):
          patch = shlex.quote(json.dumps([{"op": "add", "path": "/status", "value": value}]))
          server.succeed(f"kubectl -n {ns} patch {kind} {name} {' '.join(flags)} --type json -p {patch}")

      def create(obj):
          server.succeed(f"echo {shlex.quote(json.dumps(obj))} | kubectl create -f -")

      with subtest("The servers' checks read the backups' and Ceph's status and nothing else"):
          server.succeed("systemctl start host-checks")
          server.succeed("systemctl show host-checks -p DynamicUser --value | grep -x yes")
          checker = "--as=system:serviceaccount:kube-system:host-checks"
          review = json.loads(server.succeed(
              """echo '{"apiVersion":"authorization.k8s.io/v1","kind":"SelfSubjectRulesReview","spec":{"namespace":"default"}}'"""
              # Validating it would have kubectl list the CRDs as the account, which it rightly may not.
              f" | kubectl create -f - -o json --validate=false {checker}"
          ))
          # Beside what every account may do: ask what it may do.
          rules = sorted(
              (r["apiGroups"], r["resources"], r.get("resourceNames", []), r["verbs"])
              for r in review["status"]["resourceRules"]
              if not set(r["apiGroups"]) <= {"authorization.k8s.io", "authentication.k8s.io"}
          )
          assert rules == sorted([
              ([""], ["nodes"], [], ["list"]),
              ([""], ["persistentvolumeclaims"], [], ["list"]),
              (["postgresql.cnpg.io"], ["clusters"], [], ["list"]),
              (["barmancloud.cnpg.io"], ["objectstores"], [], ["list"]),
              (["volsync.backube"], ["replicationsources"], [], ["list"]),
              (["batch"], ["cronjobs"], ["offsite", "offsite-check-1", "offsite-check-2"], ["get"]),
              (["ceph.rook.io"], ["cephclusters"], ["rook-ceph"], ["get"]),
          ]), rules
          for denied in [
              "list secrets -A",
              "get secrets -n kube-system",
              "get pods --subresource=log -n default",
              "create pods --subresource=exec -n default",
              "get nodes --subresource=proxy",
              "list cronjobs -A",
              "get cronjobs/other -n default",
              "list configmaps -A",
              "list jobs -A",
          ]:
              server.fail(f"kubectl auth can-i {denied} {checker}")
          server.succeed(f"kubectl auth can-i get cronjobs/offsite -n default {checker}")

      with subtest("Late backups reach the phone once, and so does their recovery"):
          server.succeed("kubectl create namespace checks-db && kubectl create namespace checks-app")

          def meta(name, ns, max_age):
              return {"name": name, "namespace": ns, "annotations": {"suveraen/max-age": max_age}}

          def archiving(state, since="now"):
              return {"conditions": [{"type": "ContinuousArchiving", "status": state, "lastTransitionTime": at(since),
                                      "reason": "Probe", "message": "archive_command failed"}]}

          def backups(g1, g2):
              return {"serverRecoveryWindow": {f"postgres-{g}": {"lastSuccessfulBackupTime": at(t)}
                                               for g, t in [("g1", g1), ("g2", g2)]}}

          # A cluster on its second generation, whose first one's backups are recent and its own old.
          create({
              "apiVersion": "postgresql.cnpg.io/v1",
              "kind": "Cluster",
              "metadata": meta("postgres", "checks-db", "1h"),
              "spec": {"plugins": [{"name": "barman-cloud.cloudnative-pg.io", "isWALArchiver": True,
                                    "parameters": {"barmanObjectName": "postgres", "serverName": "postgres-g2"}}]},
              "status": archiving("True"),
          })
          create({"apiVersion": "barmancloud.cnpg.io/v1", "kind": "ObjectStore", "metadata": meta("postgres", "checks-db", "8d"),
                  "status": backups("now", "-9 days")})
          for ns, jobs in [("checks-db", ["offsite", "offsite-check-1", "offsite-check-2"]),
                           ("checks-app", ["offsite-check-1", "offsite-check-2"])]:
              for name in jobs:
                  job = {"spec": pod(ns)["spec"] | {"restartPolicy": "Never"}}
                  create({"apiVersion": "batch/v1", "kind": "CronJob", "metadata": meta(name, ns, "2h" if name == "offsite" else "3d"),
                          "spec": {"suspend": True, "schedule": "0 0 * * *", "jobTemplate": {"spec": {"template": job}}}})
                  set_status("cronjob", ns, name, {"lastSuccessfulTime": at("-3 hours" if name == "offsite" else "now")},
                             "--subresource=status")
          create({
              "apiVersion": "v1",
              "kind": "PersistentVolumeClaim",
              "metadata": {"name": "data", "namespace": "checks-app", "labels": {"suveraen/backup": "volsync"}},
              "spec": {"accessModes": ["ReadWriteOnce"], "resources": {"requests": {"storage": "1Gi"}}},
          })
          for n, synced in [(1, "now"), (2, "-48 hours")]:
              create({
                  "apiVersion": "volsync.backube/v1alpha1",
                  "kind": "ReplicationSource",
                  "metadata": meta(f"data-{n}", "checks-app", "3h"),
                  "spec": {"sourcePVC": "data", "trigger": {"schedule": "0 * * * *"}, "restic": {"repository": f"offsite-{n}"}},
                  "status": {"lastSyncTime": at(synced)},
              })

          # The probe file isn't there yet, but has been missed for less than its hour.
          server.succeed("systemctl start host-checks")
          [late] = sent("backups late: 3")
          assert keys(late["message"]) == {"New:", "checks-db/postgres base backup", "checks-db/offsite", "checks-app/data-2"}, late
          server.succeed("systemctl start host-checks")
          assert len([t for t in server.succeed("${ops} | jq -r .title").splitlines() if t.startswith("server: backups")]) == 1

          set_status("clusters.postgresql.cnpg.io", "checks-db", "postgres", archiving("False", "-2 hours"))
          server.succeed("touch -d '-2 hours' /var/lib/backup-probe")
          set_status("replicationsources.volsync.backube", "checks-app", "data-2", {"lastSyncTime": at("now")})
          server.succeed("systemctl start host-checks")
          [late] = sent("backups late: 2")
          before, new = late["message"].split("\nNew:\n")
          assert keys(new) == {"checks-db/postgres WAL archiving", "probe"}, late
          assert before.endswith("\nOn time again: checks-app/data-2"), late

          set_status("clusters.postgresql.cnpg.io", "checks-db", "postgres", archiving("True"))
          set_status("objectstores.barmancloud.cnpg.io", "checks-db", "postgres", backups("-9 days", "now"))
          set_status("cronjob", "checks-db", "offsite", {"lastSuccessfulTime": at("now")}, "--subresource=status")
          server.succeed("touch /var/lib/backup-probe")
          server.succeed("systemctl start host-checks")
          [back] = sent("backups on time again")
          assert back.get("priority", 3) == 3, back
          server.succeed("kubectl delete namespace checks-db checks-app")

      with subtest("Ceph's health reaches the phone once per change"):
          muted = {"AUTH_INSECURE_CLIENT_KEY_TYPE": "HEALTH_WARN"}
          create({
              "apiVersion": "ceph.rook.io/v1",
              "kind": "CephCluster",
              "metadata": {"name": "rook-ceph", "namespace": "rook-ceph"},
              "spec": {"healthCheck": {"muteHealthWarning": {code: {"policy": "mute"} for code in muted}}},
          })

          # What the phone got from one check of Ceph reported so.
          def reported(health, details, checked="now"):
              said = "${ops} | jq -c 'select(.title | startswith(\"server: Ceph\"))'"
              before = len(server.succeed(said).splitlines())
              set_status("cephclusters.ceph.rook.io", "rook-ceph", "rook-ceph", {"ceph": {
                  "health": health,
                  "lastChecked": at(checked),
                  "details": {code: {"severity": severity, "message": f"{code} in a test"} for code, severity in details.items()},
              }})
              server.succeed("systemctl start host-checks")
              return [(m["title"], m.get("priority", 3)) for m in map(json.loads, server.succeed(said).splitlines()[before:])]

          assert reported("HEALTH_OK", muted) == []
          near = {"POOL_NEAR_FULL": "HEALTH_WARN"} | muted
          assert reported("HEALTH_WARN", near) == [("server: Ceph HEALTH_WARN: POOL_NEAR_FULL", 4)]
          assert reported("HEALTH_WARN", near) == []
          assert reported("HEALTH_ERR", near | {"PG_DAMAGED": "HEALTH_ERR"}) == [("server: Ceph HEALTH_ERR: PG_DAMAGED", 5)]
          assert reported("HEALTH_OK", muted) == [("server: Ceph healthy again", 3)]
          assert reported("HEALTH_OK", muted, "-2 hours") == [("server: Ceph status not updated", 4)]
          server.succeed("kubectl -n rook-ceph delete cephclusters.ceph.rook.io rook-ceph")

      with subtest("With the cluster down, the server says so"):
          server.succeed("systemctl stop k3s")
          # As if the last good read were an hour ago.
          server.succeed("echo $(( $(date +%s) - 3600 )) > /var/lib/private/host-checks/last-read")
          server.succeed("systemctl start host-checks")
          assert len(sent("cluster status unreadable")) == 1
          server.succeed("systemctl start k3s")
          # Ready doesn't mean the custom resources are served yet: until their caches fill they answer 429.
          for path in [
              "/api/v1/nodes", "/api/v1/persistentvolumeclaims", "/apis/postgresql.cnpg.io/v1/clusters",
              "/apis/barmancloud.cnpg.io/v1/objectstores", "/apis/volsync.backube/v1alpha1/replicationsources",
              "/apis/ceph.rook.io/v1/cephclusters",
          ]:
              server.wait_until_succeeds(f"kubectl get --raw {path}", timeout=300)
          server.succeed("systemctl start host-checks")
          assert len(sent("cluster status readable again")) == 1

      snapshots = "/var/lib/rancher/k3s/server/db/snapshots"
      platform = "${platformBucket}"
      providers = ${
        builtins.toJSON (pkgs.lib.genAttrs [ "1" "2" ] (n: "${s3Address n}:${toString s3Port}"))
      }

      # A new etcd snapshot, as if k3s had made it a while ago: the copy leaves out one younger than a minute, which
      # may still be being written.
      def snapshot(name):
          server.succeed(f"k3s etcd-snapshot save --name {name}")
          [path] = server.succeed(f"ls {snapshots}/{name}-*.zip").split()
          server.succeed(f"touch -d '-2 minutes' {path}")
          return path.removeprefix(f"{snapshots}/")

      def copies(n):
          return f"/var/lib/s3-{n}/data/{platform}/hosts/server/etcd"

      # What provider n holds of the platform's bucket, old versions included.
      def held(n):
          return watcher.succeed(f"find /var/lib/s3-{n}/data/{platform} /var/lib/s3-{n}/versions -type f -printf '%p %s %T@\\n'")

      def stamp(n):
          return server.succeed(f"stat -c %Y /var/lib/offsite/state/etcd.{n}").strip()

      def mtime(name):
          return server.succeed(f"stat -c %Y {snapshots}/{name}").strip()

      def refused_at(n, key, args):
          status, out = watcher.execute(
              f"AWS_ACCESS_KEY_ID={key} AWS_SECRET_ACCESS_KEY={key}-test-secret AWS_DEFAULT_REGION=us-east-1"
              f" AWS_ENDPOINT_URL=http://{providers[str(n)]} HOME=/tmp aws {args} 2>&1"
          )
          assert status != 0 and "AccessDenied" in out, (n, args, out)

      with subtest("The server's etcd snapshots reach both providers encrypted to the recovery keys, under a prefix its key can neither leave nor empty"):
          marker = f"plain-marker-{secrets.token_hex(8)}"
          server.succeed(
              f"kubectl create configmap marker --from-literal=value={marker}"
              " && kubectl create secret generic drill --from-literal=value=kept"
          )
          drill = snapshot("drill")
          server.succeed("systemctl start offsite")
          for n in [1, 2]:
              watcher.succeed(f"test -s {copies(n)}/{drill}.age")
              watcher.succeed(
                  f"find /var/lib/s3-{n}/data/{platform}/hosts -type f"
                  " | while read -r f; do test \"$(head -c 21 \"$f\")\" = age-encryption.org/v1 || exit 1; done"
              )
              watcher.fail(f"grep -rqF {marker} /var/lib/s3-{n}")
              watcher.succeed(
                  f"age -d -i ${keys.snakeOilEd25519PrivateKey} -o /tmp/drill.zip {copies(n)}/{drill}.age"
                  f" && unzip -p /tmp/drill.zip | grep -aqF {marker}"
              )
              key = f"server-{n}"
              refused_at(n, key, f"s3api delete-object --bucket {platform} --key hosts/server/etcd/{drill}.age")
              refused_at(n, key, f"s3api list-objects-v2 --bucket {platform} --prefix hosts/other/")
              refused_at(n, key, f"s3api put-object --bucket {platform} --key kit/x --body /etc/hostname")
              refused_at(n, key, f"s3api get-object --bucket {platform} --key kit/marker /tmp/marker")
              assert stamp(n) == mtime(drill), (n, stamp(n), mtime(drill))
          uploaded = {n: held(n) for n in [1, 2]}
          server.succeed("systemctl start offsite")
          assert {n: held(n) for n in [1, 2]} == uploaded, uploaded
          # Nor is a snapshot encrypted again once its copy has left the spool, as when a rollback brings an older one
          # back among the newest: the providers would take the new ciphertext for a changed copy.
          server.succeed(f"rm /var/lib/offsite/spool/etcd/{drill}.age && systemctl start offsite")
          server.fail(f"test -e /var/lib/offsite/spool/etcd/{drill}.age")
          assert {n: held(n) for n in [1, 2]} == uploaded, uploaded

      with subtest("A provider that is down holds up neither the other's copy nor the alert"):
          watcher.succeed("systemctl stop s3-1")
          first = stamp(1)
          drill2 = snapshot("drill2")
          server.fail("systemctl start offsite")
          # The alert carries the unit's journal, which names the provider.
          server.wait_until_succeeds(
              "${ops} | jq -r 'select(.title == \"server: offsite.service failed\") | .message'"
              " | grep -Fx 'The copy to 1 failed.'"
          )
          watcher.succeed(f"test -s {copies(2)}/{drill2}.age")
          watcher.fail(f"test -e {copies(1)}/{drill2}.age")
          assert stamp(2) == mtime(drill2) and stamp(1) == first, (stamp(1), stamp(2), first)
          watcher.succeed("systemctl start s3-1")
          watcher.wait_until_succeeds(f"curl -s -o /dev/null http://{providers['1']}")
          server.succeed("systemctl start offsite")
          watcher.succeed(f"test -s {copies(1)}/{drill2}.age")
          assert stamp(1) == mtime(drill2), stamp(1)

      with subtest("The watcher keeps no record of who reads alerts"):
          # The phone account has read alerts through nginx above.
          watcher.fail("test -s /var/log/nginx/access.log")

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

      with subtest("A wiped server comes back from a provider's copy, decrypted with a recovery key, with its token file and not another, which leaves a running one as it was"):
          server.succeed("sha256sum /var/lib/rancher/k3s/server/token > /root/token.sum")
          # As the operator does: the newest copy at a provider, read with the kit's key and decrypted off the server.
          kit = (
              "RCLONE_CONFIG_KIT_TYPE=s3 RCLONE_CONFIG_KIT_PROVIDER=Other RCLONE_CONFIG_KIT_REGION=us-east-1"
              f" RCLONE_CONFIG_KIT_ENDPOINT=http://{providers['2']} RCLONE_CONFIG_KIT_ACCESS_KEY_ID=kit-2"
              " RCLONE_CONFIG_KIT_SECRET_ACCESS_KEY=kit-2-test-secret HOME=/tmp"
          )
          etcd = f"kit:{platform}/hosts/server/etcd/"
          newest = watcher.succeed(
              f"{kit} rclone lsf --files-only --format tp {etcd} | sort | tail -n 1 | cut -d ';' -f 2"
          ).strip()
          assert newest == f"{drill2}.age", newest
          watcher.succeed(
              f"{kit} rclone cat {etcd}{newest} | age -d -i ${keys.snakeOilEd25519PrivateKey} > /tmp/shared/restore.zip"
          )

          # It prints k3s's whole log, which is long.
          def restored(args="", timeout=600):
              status = server.execute(
                  f"timeout {timeout} suveraen-etcd-restore {args} < /tmp/shared/restore.zip"
                  " > /tmp/shared/restore.log 2>&1"
              )[0]
              return status, (server.shared_dir / "restore.log").read_text(errors="replace")

          other_token = "--token-file ${pkgs.writeText "other-token" "not-the-cluster-token"}"
          # In place, a token the snapshot wasn't made with fails and leaves the server as it was, with its own database
          # and credentials, so it starts again.
          server.succeed("kubectl create configmap since --from-literal=value=kept")
          status, out = restored(other_token, timeout=300)
          assert status != 0 and "the server is as it was" in out, (status, out[-2000:])
          server.fail("systemctl is-active k3s")
          server.succeed("systemctl start k3s")
          server.wait_until_succeeds("kubectl get configmap since", timeout=300)
          # What a new machine has: no CA, keys, encryption config or token of its own.
          wipe = (
              "systemctl stop k3s && rm -rf /var/lib/rancher/k3s/server"
              " && systemd-tmpfiles --create --prefix=/var/lib/rancher/k3s/server"
          )
          server.succeed(wipe)
          status, out = restored(other_token, timeout=300)
          assert status != 0 and "encrypted with different token" in out, (status, out[-2000:])
          server.fail("systemctl is-active k3s")
          server.succeed(wipe)
          status, out = restored()
          assert status == 0 and "membership has been reset" in out, (status, out[-2000:])
          server.succeed("test ! -e /var/lib/rancher/k3s/server/db/restore")
          server.wait_until_succeeds(
              "kubectl get secret drill -o jsonpath='{.data.value}' | base64 -d | grep -x kept", timeout=300
          )
          server.succeed(f"kubectl get configmap marker -o jsonpath='{{.data.value}}' | grep -x {marker}")
          server.succeed("sha256sum -c /root/token.sum")
          stored_with_secretbox()
    '';
}
