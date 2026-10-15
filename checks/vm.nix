# Boots a watcher and a server in VMs. The server comes up dual-stack with Flux installed and
# pointed at the repository, out of reach of namespace admins, pods held to the restricted Pod
# Security Standard, secrets encrypted at rest with secretbox and only SSH and web ports open. An
# app's charts reach only its own namespace and can neither widen who may act there nor publish
# ports, no namespace leaves restricted Pod Security, and no Service takes external IPs. A tenant's
# namespaces, names in flux-system and hosts are its own, Gateways and certificates stay in the
# gateway namespace, and the platform's pods run at a priority no tenant's may ask for. Hosts and
# pods resolve names through the node's own resolver, and clocks use NTS. The watcher's ntfy only
# takes known publishers and keeps its account API, stats and attachments closed; the server's
# alerts reach a phone account; Gatus raises an alert when the server's heartbeat stops; and the
# server falls back to a second channel when the watcher is gone. The server and its Flux only take
# commits signed by a release signer, the server never goes back to an older one, and it alerts when
# its configuration gets old. Wiped, the server comes back from an etcd snapshot with its token file
# alone.
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
  keys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;
  signer = keys.snakeOilEd25519PublicKey;

  # "en*" would also match eth1, the test network, through its alternative names.
  uplink = "eth0";

  # The tenant policies match these kinds by group and resource; their real definitions come with the platform,
  # which this test doesn't deploy.
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
                    name = "v1";
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
          ];
    }
  );
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
      { nodes, ... }:
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

        networking.hosts.${nodes.watcher.networking.primaryIPAddress} = [
          "alerts.test"
          "status.test"
        ];

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
      # k3s as its unit starts it, restoring a snapshot instead, with the given token file.
      restore =
        token:
        pkgs.lib.replaceStrings
          [ "--token-file ${nodes.server.suveraen.cluster.tokenFile}" ]
          [ "--token-file ${token}" ]
          nodes.server.systemd.services.k3s.serviceConfig.ExecStart
        + " --cluster-reset --cluster-reset-restore-path=/root/drill";
      staleDays = toString (nodes.server.suveraen.upgrade.staleAfterDays + 1);
    in
    ''
      import json
      import shlex

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

      with subtest("No namespace leaves the restricted Pod Security default, not even through Flux's own account"):
          # After the probes above, whose namespace the test labels privileged itself.
          server.succeed("kubectl apply -f ${../kubernetes/platform/policies/app/pod-security-labels.yaml}")
          privileged = "kubectl label namespace member pod-security.kubernetes.io/enforce=privileged --dry-run=server"
          server.wait_until_fails(privileged)
          out = server.fail(f"{privileged} 2>&1")
          assert "pod-security-labels" in out, out
          server.succeed("kubectl label namespace member pod-security.kubernetes.io/enforce=restricted --dry-run=server")

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
              server.succeed(f"echo {shlex.quote(json.dumps(namespace(name, name[:5], tier='app')))} | kubectl create -f -")
          refused(dry(namespace("alpha-y", "bravo", tier="app")), "tenant-namespaces")
          refused(dry(namespace("misc", "alpha", tier="app")), "tenant-namespaces")
          refused(dry(namespace("alpha-z", "alpha", tier="platform")), "tenant-namespaces")
          refused(dry(namespace("alpha-p", "alpha", tier="app", publish="true")), "tenant-namespaces")
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
          server.succeed(dry(certificate(None, "cert-manager", isCA=True, commonName="test CA")))

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

      with subtest("A wiped server comes back from an etcd snapshot with its token file, and not with another token"):
          server.succeed(
              "kubectl create secret generic drill --from-literal=value=kept && k3s etcd-snapshot save --name drill"
              " && cp /var/lib/rancher/k3s/server/db/snapshots/drill-* /root/drill"
              " && sha256sum /var/lib/rancher/k3s/server/token > /root/token.sum"
          )
          # What a new machine has: no CA, keys, encryption config or token of its own.
          wipe = (
              "systemctl stop k3s && rm -rf /var/lib/rancher/k3s/server"
              " && systemd-tmpfiles --create --prefix=/var/lib/rancher/k3s/server"
          )
          other = """${restore (pkgs.writeText "other-token" "not-the-cluster-token")}"""
          assert "other-token" in other, other
          server.succeed(wipe)
          status, out = server.execute(f"timeout 300 {other} 2>&1")
          assert status != 0 and "encrypted with different token" in out, (status, out[-2000:])
          server.succeed(wipe)
          _, out = server.execute("timeout 300 ${restore nodes.server.suveraen.cluster.tokenFile} 2>&1")
          assert "membership has been reset" in out, out[-2000:]
          server.succeed("systemctl start k3s")
          server.wait_until_succeeds(
              "kubectl get secret drill -o jsonpath='{.data.value}' | base64 -d | grep -x kept", timeout=300
          )
          server.succeed("sha256sum -c /root/token.sum")
          stored_with_secretbox()
    '';
}
