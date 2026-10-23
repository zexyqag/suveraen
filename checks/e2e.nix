# Boots a server built from the same modules as a real one, with internet access, and lets Flux deploy
# kubernetes/clusters/test from a signed commit on a git server inside the test, with two test ACME CAs and a nameserver
# standing in for the internet's. Every Kustomization and HelmRelease becomes Ready, every Secret is stored encrypted
# with secretbox, no pod is refused and no job fails; both CAs know our accounts, and every host's certificate comes
# over DNS-01, its challenge answered in our ACME zone through the node's Knot and removed again, also where an
# organisation's own DNS points the challenge there; the standby CA, which requires our external account, issues too;
# every route answers through the host firewall, ServiceLB, the gateway and the app's network policy with a certificate
# from the CA, and port 80 redirects there; the platform's pods run ahead of tenants'. Each tenant runs in exactly the
# namespaces its manifest asks for, and hello answers on each of its hosts with that tenant's own settings and restarts
# when they change; a tenant's pods reach neither other tenants' services nor the gateway's, and nothing outside reaches
# theirs; tenants can't take each other's namespaces or hosts or keep Gateways outside the gateway namespace, and stay
# within their quota; a host's key goes with its certificate; removing a tenant takes its Kustomizations, hosts, keys
# and pods but leaves its namespaces, which then go by its label; and an unsigned commit is never applied. Ceph runs
# healthy with three monitors and an encrypted OSD per disk, its DB on a volume of its own mirrored over both system
# disks, three copies on every pool and as many placement groups as its OSDs and pools call for, with room for one more
# pool, and the pools that hold data capped at what its disks hold with room to recover; block volumes bind, snapshot
# and restore, and go with their claims; the object store hands out buckets with keys of their own to the pods allowed
# to reach it; and after a reboot Ceph comes back with its data. Each tenant's PostgreSQL archives WAL and base backups
# to its own bucket, takes no restore while it runs, and lets each app reach its own database alone, from its own
# namespace; a removed tenant's cluster and bucket go only with its namespaces. The bucket's running generation goes
# off-site to two providers, encrypted with the tenant's own key and locked for as long as the template says, where the
# cluster's keys can neither delete nor unlock a copy, nor reach another app's; when the cluster's object store has lost
# it, a release brings the tenant's PostgreSQL back from a provider's copy as a new generation, with its apps' data, and
# later copies leave the old generation's alone. A check that only reads proves each provider's copy whole and
# decrypting to what the bucket holds, and fails at that provider alone when a copy there changes or goes. An app's
# volume goes to both providers too, encrypted with the app's own password, and comes back from either as it was copied,
# without the files deleted before, and a check without restic's lock reads each copy back, fails at that provider alone
# when a copy there changes or has lost its config, and passes for an app that has copied nothing yet, whose first
# restore left an empty repository at one provider and none at the other; nothing is left of the volumes copies
# and restores worked on, and every volume in a tenant's namespace is backed up or VolSync's.
# The server's alerts reach a phone. Its etcd snapshots go to both providers encrypted, with a key that reaches no
# tenant's bucket, as no tenant's key reaches them. Its checks find every backup's last good copy where its controller
# records it, its own off-site copies included, none of them late; one more pool still fits, and when it passes its
# quota's warning they alert once, and once more when that clears. Its etcd comes back in place from a provider's copy,
# decrypted off the server, as it was when copied, and Ceph stays healthy.
{
  pkgs,
  module,
  kubernetes,
}:
let
  inherit (pkgs) lib;
  keys = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;
  # git-http-backend runs as cgit and refuses repositories someone else owns.
  asCgit = "runuser -u cgit -- env HOME=/srv/git";

  transferKey = import ./transfer-key.nix pkgs;
  # The server's alerts go to an ntfy beside it, which only the publisher posts to and only the phone reads, as at the
  # watcher. ntfy tokens are "tk_" plus 29 characters.
  publisherToken = "tk_suveraentestpublisher00000000";
  phonePassword = "phone-test-password";
  alertSecrets = pkgs.runCommand "e2e-alert-secrets" { nativeBuildInputs = [ pkgs.ntfy-sh ]; } ''
    mkdir $out
    hash() { printf '%s\n%s\n' "$1" "$1" | ntfy user hash | grep -o '\$2a\$.*'; }
    cat > $out/ntfy.env <<EOF
    NTFY_AUTH_USERS='phone:$(hash ${phonePassword}):user,publisher:$(hash unused):user'
    NTFY_AUTH_TOKENS='publisher:${publisherToken}'
    EOF
    printf '%s' ${publisherToken} > $out/publisher-token
  '';
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

  certs = import (pkgs.path + "/nixos/tests/common/acme/server/snakeoil-certs.nix");

  # The two providers that keep the off-site copies, each at its own address on the internet node, on port 80.
  providers = [
    1
    2
  ];
  s3Address = n: "192.168.1.10${toString n}";
  # Where the servers copy their own state at each provider.
  platformBucket = "test-platform";
in
pkgs.testers.runNixOSTest {
  name = "suveraen-e2e";
  # Below the CI job's limit, so the waits in the script run out first and print what went wrong.
  globalTimeout = 9000;

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
        (pkgs.path + "/nixos/tests/common/acme/server")
        (import ./providers.nix {
          cluster = clusterIn nodes;
          platform = {
            bucket = platformBucket;
            hosts = [ nodes.server.networking.hostName ];
          };
          address = s3Address;
          port = 80;
        })
      ];
      environment.systemPackages = [
        # To find a tenant's copies there by the names its crypt encrypts.
        pkgs.rclone
        # To decrypt the server's own copies as the operator does.
        pkgs.age
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
    {
      config,
      lib,
      nodes,
      ...
    }:
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

      # The test starts these far more often than their timers do.
      systemd.services.host-checks.startLimitIntervalSec = 0;
      systemd.services.offsite.startLimitIntervalSec = 0;
      systemd.services.offsite-collect.startLimitIntervalSec = 0;

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

      # Every run of every container of Rook's OSD prepare pods, kept for diagnose(): the Job deletes its pod once it
      # gives up, and ceph-volume says why it failed only there.
      systemd.services.osd-prepare-logs = {
        description = "Keep the logs of Rook's OSD prepare pods";
        wantedBy = [ "multi-user.target" ];
        after = [ "k3s.service" ];
        path = [ pkgs.kubectl ];
        environment.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
        serviceConfig.Restart = "always";
        script = ''
          dir=/var/log/osd-prepare
          mkdir -p "$dir"
          keep() {
            if kubectl --request-timeout=20s -n rook-ceph logs "$1" -c "$2" --timestamps "''${@:4}" \
              >"$dir/.part" 2>&1; then
              mv "$dir/.part" "$dir/$1-$2-$3.log"
            fi
          }
          runs='{range .items[*]}{.metadata.name}{range .status.initContainerStatuses[*]}{" "}{.name}={.restartCount}{end}'
          runs+='{range .status.containerStatuses[*]}{" "}{.name}={.restartCount}{end}{"\n"}{end}'
          while sleep 5; do
            kubectl --request-timeout=20s -n rook-ceph get pods -l app=rook-ceph-osd-prepare -o jsonpath="$runs" \
              2>/dev/null | while read -r pod containers; do
              for container in $containers; do
                name=''${container%=*} count=''${container#*=}
                keep "$pod" "$name" "$count"
                [ "$count" = 0 ] || keep "$pod" "$name" $((count - 1)) --previous
              done
            done
          done
        '';
      };

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
        offsite = {
          recipients = [ keys.snakeOilEd25519PublicKey ];
          targets = lib.genAttrs (map toString providers) (n: {
            endpoint = "http://s3-${n}.test";
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
          urlFile = toString (pkgs.writeText "alerts-url" "http://127.0.0.1:2587/ops");
          tokenFile = "${alertSecrets}/publisher-token";
          # Its ntfy is on the same machine, so there's no reboot of the watcher to ride out.
          retrySeconds = 5;
        };
      };

      # Stands in for the watcher's ntfy.
      services.ntfy-sh = {
        enable = true;
        environmentFile = "${alertSecrets}/ntfy.env";
        settings = {
          base-url = "http://alerts.test";
          listen-http = "127.0.0.1:2587";
          auth-default-access = "deny-all";
          auth-access = [
            "phone:*:ro"
            "publisher:*:wo"
          ];
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
      from datetime import datetime

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
      # The server's checks and copies run when the test says.
      server.succeed("systemctl stop host-checks.timer offsite.timer")

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

      # The console drops output the driver doesn't read in time, so long output comes through the shared directory.
      def parsed(cmd):
          server.succeed(f"{cmd} > /tmp/shared/output")
          out = (server.shared_dir / "output").read_bytes()
          try:
              return json.loads(out)
          except json.JSONDecodeError as e:
              raise ValueError(f"{cmd}: {e}, in {len(out)} bytes: {e.doc[max(e.pos - 200, 0):e.pos + 200]!r}") from e

      # What a command prints, errors included, whether or not it fails.
      def shown(cmd):
          server.execute(f"set +e; ( {cmd} ) > /tmp/shared/output 2>&1")
          return (server.shared_dir / "output").read_bytes().decode(errors="replace")

      # The server's alerts so far, as the phone reads them.
      phone = "curl -fsS -u phone:${phonePassword} 'http://127.0.0.1:2587/ops/json?poll=1'"

      def alerts():
          server.succeed(f"{phone} > /tmp/shared/alerts")
          return [json.loads(line) for line in (server.shared_dir / "alerts").read_text().splitlines() if line]

      def diagnose():
          for cmd in [
              "kubectl get gitrepositories,ocirepositories,kustomizations,helmreleases -A",
              "kubectl get pods -A -o wide",
              "kubectl get pods -A --field-selector=status.phase=Failed"
              " -o jsonpath='{range .items[*]}{.metadata.namespace}{\" \"}{.metadata.name}{\"\\n\"}{end}'"
              " | while read -r ns pod; do"
              " kubectl -n $ns get pod $pod -o jsonpath='{.status.containerStatuses[*].state.terminated}{\"\\n\"}';"
              " kubectl -n $ns logs $pod --all-containers --tail=30 --prefix; done",
              "kubectl get networkpolicies -A",
              "kubectl get events -A --sort-by=.lastTimestamp | tail -n 100",
              "kubectl get events -A --field-selector reason=FailedCreate",
              "kubectl -n flux-system logs deploy/source-controller --tail=50",
              "kubectl -n flux-system logs deploy/kustomize-controller --tail=100",
              "kubectl -n flux-system logs deploy/helm-controller --tail=100",
              "kubectl get clusterissuers,certificates,certificaterequests,orders,challenges -A",
              "kubectl -n cert-manager logs deploy/cert-manager --tail=100",
              "journalctl -u knot -u knot-acme-secret --no-pager | tail -n 50",
              "kubectl get pv,pvc,volumesnapshots -A",
              "kubectl get clusters.postgresql.cnpg.io,backups.postgresql.cnpg.io,jobs -A",
              "kubectl get replicationsources,replicationdestinations -A -o wide",
              # VolSync deletes a mover once done, but keeps its result and filtered log in the status.
              "kubectl get replicationsources,replicationdestinations -A -o jsonpath='{range .items[*]}"
              "{.kind} {.metadata.namespace}/{.metadata.name}: trigger {.spec.trigger}, last manual {.status.lastManualSync},"
              " managers {.metadata.managedFields[*].manager}{\"\\n\"}{.status.latestMoverStatus}{\"\\n\"}{end}'",
              "kubectl -n volsync logs deploy/volsync --all-containers --tail=100",
              "kubectl get pods -A -l app.kubernetes.io/created-by=volsync"
              " -o jsonpath='{range .items[*]}{.metadata.namespace}{\" \"}{.metadata.name}{\"\\n\"}{end}'"
              " | while read -r ns pod; do kubectl -n $ns logs $pod --all-containers --tail=30 --prefix; done",
              "free -m",
              "df -h /",
              # Why k3s stopped or restarted in this boot, and what held up the last poweroff.
              "journalctl -b -u k3s -o short-precise --no-pager"
              " | grep -E 'level=fatal| F[0-9]{4} |panic:|k3s\\.service|k3s service|Starting k3s v' | tail -n 60",
              "journalctl --list-boots --no-pager",
              "journalctl -b -1 -o short-monotonic --no-pager"
              " | grep -iE 'timed out|SIGKILL|still around|Failed unmounting|blocked for more than|libceph|rbd' | tail -n 60",
              "journalctl -u host-checks -o cat --no-pager | tail -n 80",
              phone,
          ]:
              print(f"$ {cmd}\n{shown(cmd)}")
          print(acme.execute("journalctl -u pebble -u knot -u 's3-*' --no-pager | tail -n 80")[1])
          images()
          diagnose_ceph()

      # Rook, Ceph through the operator (there's no toolbox), the object store and who may reach it, the CSI drivers,
      # the host's disks, and last ceph-volume's and the OSD prepare pods' own logs.
      def diagnose_ceph():
          ceph = (
              "kubectl -n rook-ceph exec deploy/rook-ceph-operator -- timeout 30 ceph --connect-timeout=10"
              " --conf=/var/lib/rook/rook-ceph/rook-ceph.config"
          )
          operator = "kubectl -n rook-ceph logs deploy/rook-ceph-operator --tail=-1"
          errors = "grep -E ' (E|W) \\| |op-osd|failed to provision|exec timeout' | tail -n 200"
          for cmd in [
              "kubectl get cephclusters,cephblockpools,cephobjectstores -A -o wide",
              "kubectl -n rook-ceph get cephcluster rook-ceph -o jsonpath='{.status.ceph}{\"\\n\"}{.status.conditions}'",
              "kubectl -n rook-ceph get events --sort-by=.lastTimestamp",
              "kubectl -n rook-ceph get jobs,pods -l app=rook-ceph-osd-prepare -o yaml",
              "kubectl -n rook-ceph describe jobs -l app=rook-ceph-osd-prepare",
              "kubectl -n rook-ceph get configmaps -l app=rook-ceph-osd,status=provisioning -o yaml",
              f"{operator} | {errors}",
              f"{operator} --previous | {errors}",
              "kubectl -n rook-ceph logs deploy/rook-ceph-operator --tail=100",
              *[f"{ceph} {args}" for args in
                ["status", "health detail", "osd tree", "osd dump", "osd crush class ls", "pg stat", "df", "crash ls"]],
              "kubectl get objectbucketclaims,objectbuckets -A -o wide",
              # Endpoints, claims and phases; the keys stay in the claims' Secrets.
              "kubectl get objectbuckets -o yaml",
              "kubectl -n rook-ceph get svc,endpointslices -l app=rook-ceph-rgw -o wide",
              f"{operator} | grep -E 'op-bucket-prov|object-controller' | tail -n 50",
              # A line per request with the client's address and the status: none means it never got there.
              "kubectl -n rook-ceph logs -l app=rook-ceph-rgw --all-containers --prefix --tail=200",
              # What k3s's policy controller lets reach the store, with each rule's counters, and the pods it admits.
              "${pkgs.iptables}/bin/iptables-save -c | grep -F object-store-clients;"
              " for set in $(${pkgs.iptables}/bin/iptables-save | grep -F object-store-clients"
              " | grep -oE 'KUBE-SRC-[A-Z0-9]+' | sort -u); do ${pkgs.ipset}/bin/ipset list $set; done",
              "kubectl -n rook-ceph get drivers.csi.ceph.io,operatorconfigs.csi.ceph.io,cephconnections.csi.ceph.io"
              ",clientprofiles.csi.ceph.io -o yaml",
              "kubectl -n rook-ceph get deploy,ds,rs,sa -o wide",
              "kubectl -n rook-ceph logs deploy/ceph-csi-controller-manager --tail=100",
              # Why any of Rook's containers restarted, and what the CSI controller said before and after.
              "kubectl -n rook-ceph get pods -o jsonpath='{range .items[*]}{.metadata.name}"
              "{range .status.initContainerStatuses[*]}{\" \"}{.name}={.restartCount}:{.lastState.terminated.reason}"
              "/{.lastState.terminated.exitCode}{end}{range .status.containerStatuses[*]}"
              "{\" \"}{.name}={.restartCount}:{.lastState.terminated.reason}/{.lastState.terminated.exitCode}{end}{\"\\n\"}{end}'",
              # What each OSD's activation did last, with xtrace, before and after its last restart.
              "for pod in $(kubectl -n rook-ceph get pods -l app=rook-ceph-osd -o name); do"
              " kubectl -n rook-ceph logs $pod -c activate --prefix --tail=100;"
              " kubectl -n rook-ceph logs $pod -c activate --prefix --previous --tail=100; done",
              "kubectl get volumeattachments -o wide",
              "kubectl -n rook-ceph logs deploy/rook-ceph.rbd.csi.ceph.com-ctrlplugin --all-containers --prefix --tail=50",
              "kubectl -n rook-ceph logs deploy/rook-ceph.rbd.csi.ceph.com-ctrlplugin --all-containers --prefix --previous --tail=50",
              "lsblk -o NAME,KNAME,TYPE,SIZE,ROTA,PARTLABEL,PARTUUID,FSTYPE,MOUNTPOINTS",
              "ls -l /dev/disk/by-osd/",
              "for link in /dev/disk/by-osd/*; do echo $link; udevadm info --query=property $(readlink -f $link)"
              " | grep -E '^(DEVLINKS|ID_PART_ENTRY_NAME|DM_VG_NAME|DM_LV_NAME)='; done",
              "pvs; vgs; lvs -o lv_name,vg_name,lv_size,lv_tags,devices",
              "dmsetup ls --tree",
              "grep -E '^(dm_crypt|dm_mod|raid1) ' /proc/modules",
              "mdadm --detail /dev/md/osd-db",
              # Each DB group's metadata headers and copies, with the sequence number each write gave it.
              "for pv in /dev/disk/by-id/md-name-any:osd-db-part*; do pvck --dump headers $pv;"
              " pvck --dump metadata_search $pv; done",
              "tail -n 200 /var/lib/rook/rook-ceph/log/ceph-volume.log",
              "for log in /var/log/osd-prepare/*.log; do echo \"==> $log\"; tail -n 150 $log; done",
          ]:
              print(f"$ {cmd}\n{shown(cmd)}")

      # What each container runs, by digest: how images only known by tag here get pinned.
      def images():
          status, out = server.execute(
              "kubectl get pods -A -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}"
              "{.image}{\" \"}{.imageID}{\"\\n\"}{end}{end}' | sort -u"
          )
          print(out)

      # QEMU's peak memory per running machine, and what the runner has left.
      def memory():
          for machine in machines_qemu:
              if machine.pid is not None:
                  with open(f"/proc/{machine.pid}/status") as status:
                      print(machine.name, [line.strip() for line in status if line.startswith(("VmHWM", "VmRSS"))])
          with open("/proc/meminfo") as meminfo:
              print([line.strip() for line in meminfo if line.startswith("MemAvailable")])

      server.wait_for_unit("k3s.service")
      try:
          with subtest("The server's alerts reach the phone"):
              server.wait_until_succeeds("curl -fsS http://127.0.0.1:2587/v1/health")
              server.succeed("suveraen-alert e2e-probe")
              titles = [a.get("title") for a in alerts()]
              assert "${nodes.server.networking.hostName}: e2e-probe" in titles, titles

          with subtest("Flux takes the signed commit"):
              server.wait_until_succeeds(
                  f"kubectl -n flux-system get gitrepository suveraen -o jsonpath='{{.status.artifact.revision}}' | grep -F {signed}",
                  timeout=600,
              )
              server.succeed("kubectl -n flux-system wait gitrepository suveraen --for=condition=SourceVerified --timeout=0")

          with subtest("Every Kustomization and HelmRelease becomes Ready"):
              # The root Kustomization is Ready only once it has created the others, so --all covers them all. A failed
              # OSD prepare job ends the wait at once: the rest of it would only run out.
              def ready(_):
                  failed = server.execute(
                      "kubectl -n rook-ceph get jobs -l app=rook-ceph-osd-prepare"
                      " -o jsonpath='{..conditions[?(@.type==\"Failed\")].status}'"
                  )[1]
                  assert "True" not in failed, "an OSD prepare job failed"
                  return server.execute(
                      "kubectl -n flux-system wait kustomization --all --for=condition=Ready --timeout=0"
                  )[0] == 0

              retry(ready, timeout_seconds=2700)
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
                  return parsed(f"kubectl get {kind} -A -o json")["items"]

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

          ceph_cli = (
              "kubectl -n rook-ceph exec deploy/rook-ceph-operator -- ceph --connect-timeout=10"
              " --conf=/var/lib/rook/rook-ceph/rook-ceph.config"
          )

          def ceph(args):
              return parsed(f"{ceph_cli} {args} -f json")

          def apply(obj):
              server.succeed(f"echo {shlex.quote(json.dumps(obj))} | kubectl apply -f -")

          def finished(namespace, pod):
              phase = f"kubectl -n {namespace} get pod {pod} -o jsonpath='{{.status.phase}}'"
              try:
                  server.wait_until_succeeds(f"{phase} | grep -xE 'Succeeded|Failed'", timeout=600)
                  server.succeed(f"{phase} | grep -x Succeeded")
              except Exception:
                  print(server.execute(
                      f"set +e; ( kubectl -n {namespace} describe pod {pod}; kubectl -n {namespace} logs {pod} ) 2>&1"
                  )[1])
                  raise
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

          with subtest("Ceph is healthy: three monitors, an encrypted OSD per disk with its DB apart, three copies everywhere, room to spare"):
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
                  tree = parsed(f"lsblk -J -o NAME,TYPE {device}")["blockdevices"][0]

                  def walk(d):
                      return [t for c in d.get("children", []) for t in [c["type"]] + walk(c)]

                  return walk(tree)

              # Both the data and the DB are opened through dm-crypt, the DB on the array over both system disks.
              for slot in range(len(disks)):
                  assert "crypt" in below(f"/dev/disk/by-osd/osd{slot}"), slot
                  assert "crypt" in below(f"/dev/disk/by-osd/osd{slot}-db"), slot
              server.succeed("mdadm --detail /dev/md/osd-db | grep -Eq 'Active Devices : 2'")
              domain = setting("CEPH_FAILURE_DOMAIN")
              rules = {r["rule_id"]: r["steps"] for r in ceph("osd crush rule dump")}
              pools = ceph("osd pool ls detail")
              assert {".mgr", "block", "objects.rgw.buckets.data"} <= {p["pool_name"] for p in pools}, pools
              for pool in pools:
                  assert (pool["size"], pool["min_size"]) == (3, 2), pool
                  assert any(step.get("type") == domain for step in rules[pool["crush_rule"]]), (pool, rules)
              config = parsed("kubectl -n rook-ceph get cephcluster rook-ceph -o json")["spec"]["cephConfig"]["mgr"]
              for key, value in config.items():
                  assert float(ceph(f"config get mgr {key}")) == float(value), (key, value)

              # Once the autoscaler has done all it recommends, the two pools that hold data split what the others leave
              # evenly, and one more pool at its floor of 32 placement groups still fits under Ceph's limit per OSD.
              def settled(_):
                  return all(p["pg_num"] == p["pg_num_target"] for p in ceph("osd pool ls detail")) and all(
                      p["pg_num_final"] == p["pg_num_target"] for p in ceph("osd pool autoscale-status")
                  )

              retry(settled, timeout_seconds=600)
              pools = ceph("osd pool ls detail")
              pgs = {p["pool_name"]: p["pg_num"] for p in pools}
              assert pgs["block"] == pgs["objects.rgw.buckets.data"], pgs
              copies = sum(p["pg_num"] * p["size"] for p in pools) + 32 * 3
              assert copies / len(osds) <= ceph("config get mgr mon_max_pg_per_osd"), pgs

              # The pools that hold data stop at the cluster's quotas, Ceph's own at none, and every copy of what the
              # quotas allow fits in 0.80 of the disks once a lost OSD's copies have moved (settings.yaml).
              def size(quantity):
                  match = re.fullmatch(r"(\d+)([KMGT]i|[kMGT])?", quantity)
                  assert match, quantity
                  scale = {"Ki": 2**10, "Mi": 2**20, "Gi": 2**30, "Ti": 2**40, "k": 10**3, "M": 10**6, "G": 10**9, "T": 10**12}
                  return int(match.group(1)) * scale.get(match.group(2), 1)

              quotas = {"block": size(setting("CEPH_BLOCK_QUOTA")),
                        "objects.rgw.buckets.data": size(setting("CEPH_OBJECTS_QUOTA"))}
              assert {p["pool_name"]: p["quota_max_bytes"] for p in pools} == {
                  p["pool_name"]: quotas.get(p["pool_name"], 0) for p in pools
              }, pools
              capacity = sum(
                  int(server.succeed(f"blockdev --getsize64 /dev/disk/by-osd/osd{slot}")) for slot in range(len(disks))
              )
              spare = (len(osds) - 1) / len(osds) if len(osds) > 3 else 1
              stored = sum(quotas[p["pool_name"]] * p["size"] for p in pools if p["pool_name"] in quotas)
              assert stored <= 0.80 * capacity * spare, (quotas, capacity)

          with subtest("A block volume binds, its snapshot restores, and it goes with its claim"):
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
              server.wait_until_fails(f"kubectl get pv {volume}", timeout=120)

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
              request = (
                  ' --aws-sigv4 "aws:amz:''${BUCKET_REGION:-us-east-1}:s3"'
                  ' --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" "http://$BUCKET_HOST:$BUCKET_PORT/$BUCKET_NAME/marker"'
              )
              s3 = "curl -fsS -m 10" + request
              # The store admits a new pod only once k3s's policy controller has its address, which comes after it starts.
              admitted = "curl -fsS -m 10 --retry 30 --retry-delay 1 --retry-connrefused" + request
              keys = [{"secretRef": {"name": "probe"}}, {"configMapRef": {"name": "probe"}}]
              # Started first, so the sync that lets the client in has this pod's address too: what keeps it out then
              # is the policy, not the controller's lag.
              apply(restricted("objects", "other", "sleep 3600", env=keys))
              server.succeed("kubectl -n objects wait pod other --for=condition=Ready --timeout=300s")
              apply(restricted(
                  "objects", "client", f"echo kept > /tmp/marker && {admitted} -T /tmp/marker && {admitted}",
                  labels={"suveraen/object-store": "client"}, env=keys,
              ))
              # Each refused try leaves curl's error in the log ahead of the object.
              assert finished("objects", "client").splitlines()[-1:] == ["kept"]
              status, out = server.execute(f"kubectl -n objects exec other -- sh -c {shlex.quote(s3)} 2>&1")
              assert status in [7, 28], (status, out)

          with subtest("Every route answers through the gateway with a certificate from the CA, and port 80 redirects there"):
              forge.succeed("curl -fsS --cacert ${caCert} https://acme.test:15000/roots/0 > /tmp/ca.crt")
              hosts = sorted({h for r in items("httproute") for h in r["spec"]["hostnames"]})
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

          def get(cmd):
              return parsed(f"{cmd} -o json")

          # A tenant's own Kustomization is tenant-<id>, labelled with its ID.
          tenants = sorted(
              k["metadata"]["labels"]["suveraen/tenant"]
              for k in get("kubectl -n flux-system get kustomization -l suveraen/tenant")["items"]
              if k["metadata"]["name"] == "tenant-" + k["metadata"]["labels"]["suveraen/tenant"]
          )
          assert tenants == sorted(os.listdir("${cluster}/tenants")), tenants
          assert len(tenants) >= 2, tenants
          first, second = tenants[0], tenants[1]

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

          def reached(namespace, query):
              # A new pod gets past the database's policy only once k3s's policy controller has its address.
              for _ in range(60):
                  status, out = psql(namespace, "psql", query)
                  if status == 0:
                      return out
                  time.sleep(5)
              raise AssertionError(out)

          postgres_image = server.succeed(
              "kubectl get clusterimagecatalog postgresql -o jsonpath='{.spec.images[0].image}'"
          ).strip()

          def client(namespace, secret):
              pod = restricted(namespace, "psql", "sleep 3600", env=[{"secretRef": {"name": secret}}])
              pod["spec"]["containers"][0] |= {
                  "image": postgres_image,
                  "resources": {"requests": {"cpu": "10m", "memory": "32Mi"}, "limits": {"memory": "64Mi"}},
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
              reached(f"{first}-hello", "create table probe (v text); insert into probe values ('kept')")
              for other in [{"dbname": "postgres"}, {"dbname": "app"}, {"user": "postgres"}, {"password": "wrong"}]:
                  status, out = psql(f"{first}-hello", "psql", "select 1", **other)
                  assert status != 0 and ("pg_hba.conf" in out or "authentication failed" in out), (other, out)
              # The other tenant's app, with its own credentials, and a namespace without policies don't get through:
              # refused or dropped, as blocked() takes it.
              apply({"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "db", "namespace": "probe"},
                     "stringData": {"host": f"postgres-rw.{first}-postgres.svc", "port": "5432", "dbname": "hello",
                                    "username": "hello", "password": "unknown", "sslmode": "require"}})
              client("probe", "db")
              client(f"{second}-hello", "db")
              # Until k3s's policy controller has a new pod's address, every policy that names its clients refuses the
              # pod, right or wrong. Each sync rebuilds them all from the pods it knows, so the one that lets the newest
              # pod into its own database knows both.
              reached(f"{second}-hello", "select 1")
              status, out = psql(f"{second}-hello", "psql", "select 1", host=f"postgres-rw.{first}-postgres.svc")
              assert status != 0 and ("Connection refused" in out or "timeout expired" in out), out
              status, out = psql("probe", "psql", "select 1")
              assert status != 0 and ("Connection refused" in out or "timeout expired" in out), out
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

          def keys_of(tenant, n, app="POSTGRES"):
              secrets = f"${cluster}/tenants/{tenant}/secrets.yaml"
              return read(secrets, f"{app}_BACKUP_{n}_ACCESS_KEY_ID"), read(secrets, f"{app}_BACKUP_{n}_SECRET_ACCESS_KEY")

          def stored_at(n, tenant, prefix):
              # What the provider holds under a prefix: each file with its size and modification time.
              data = f"/var/lib/s3-{n}/data/{bucket_at(n, tenant)}"
              out = acme.succeed(f"cd {data} && find {prefix} -type f -printf '%p %s %T@\\n'")
              return dict(line.split(" ", 1) for line in out.splitlines())

          def bucket_at(n, tenant):
              return setting(f"BACKUP_{n}_BUCKET_PREFIX") + tenant

          def push(ns, job):
              server.succeed(f"kubectl -n {ns} create job {job} --from=cronjob/offsite")
              try:
                  server.wait_until_succeeds(f"kubectl -n {ns} wait job {job} --for=condition=Complete --timeout=0", timeout=600)
              finally:
                  print(server.execute(f"kubectl -n {ns} logs job/{job} --tail=40")[1])

          with subtest("A tenant's bucket goes off-site to both providers, encrypted, where the cluster's keys can't remove a copy"):
              ns = f"{first}-postgres"
              for n in providers:
                  assert setting(f"BACKUP_{n}_ENDPOINT") == f"http://s3-{n}.test", n
                  acme.wait_for_unit(f"s3-{n}-setup.service")
              archived(ns)
              # What the bucket holds by now, the push copies.
              pushed = server.succeed("date -u +%Y-%m-%dT%H:%M:%SZ").strip()
              push(ns, "push")
              with open("${kubernetes}/apps/postgres/ks.yaml") as template:
                  days = re.search(r"POSTGRES_OFFSITE_LOCK:=(\d+)d", template.read())
              assert days, "the template has no default lock"
              lock = int(days.group(1))
              first_copies = {}
              for n in providers:
                  root = (f"root-{n}", f"root-{n}-test-secret")
                  ours, bucket = keys_of(first, n), bucket_at(n, first)
                  # What the provider holds: rclone's encrypted files, under names it encrypted too.
                  data = f"/var/lib/s3-{n}/data/{bucket}"
                  first_copies[n] = stored_at(n, first, "postgres")
                  stored = sorted(first_copies[n])
                  assert stored, n
                  # Encrypted names are base32hex, which has neither "-" nor "w".
                  plain = [f for f in stored if re.search(r"postgres-g|wals", f.removeprefix("postgres/"))]
                  assert not plain, plain
                  acme.succeed(
                      f"cd {data} && find postgres -type f | while read -r f; do test \"$(head -c 6 \"$f\")\" = RCLONE || exit 1; done"
                  )
                  key = stored[0]
                  status, out = at(
                      n, root, f"s3api head-object --bucket {bucket} --key {key}"
                      " --query '[ObjectLockMode,ObjectLockRetainUntilDate,VersionId]' --output text"
                  )
                  assert status == 0, out
                  mode, until, version = out.split()
                  assert mode == "COMPLIANCE", out
                  # rclone's own lock, well beyond the bucket's one-day default.
                  now = int(acme.succeed("date +%s"))
                  assert datetime.fromisoformat(until).timestamp() > now + (lock - 1) * 86400, (out, lock)
                  # The cluster's key deletes nothing, shortens no lock, changes no bucket and reaches no other tenant's.
                  version = f"--bucket {bucket} --key {key} --version-id {version}"
                  refused_at(n, ours, f"s3api delete-object {version}")
                  refused_at(n, ours, f"s3api delete-object --bucket {bucket} --key {key}")
                  refused_at(n, ours, f"s3api put-object-retention {version} --retention"
                             f" Mode=GOVERNANCE,RetainUntilDate=$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)")
                  refused_at(n, ours, f"s3api put-object-lock-configuration --bucket {bucket} --object-lock-configuration"
                             """ '{"ObjectLockEnabled":"Enabled","Rule":{"DefaultRetention":{"Mode":"GOVERNANCE","Days":1}}}'""")
                  refused_at(n, ours, f"s3api delete-bucket-policy --bucket {bucket}")
                  refused_at(n, ours, f"s3api list-objects-v2 --bucket {bucket} --prefix volsync/")
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

          # Flux takes over what kubectl's own field managers set, so the object's next apply would drop the change.
          def merge(namespace, obj, change):
              server.succeed(
                  f"kubectl -n {namespace} patch {obj} --field-manager=flux-client-side-apply --type merge"
                  f" -p {shlex.quote(json.dumps(change))}"
              )

          # Runs a check now, as its CronJob would with some of its settings changed, and tells whether it passed, with
          # its log. A check that passed leaves no Job, so its log is read while it runs, from each of its pods in turn:
          # the last one's result is the one that counts.
          def checked(ns, cronjob, job, env, backoff=None):
              spec = parsed(f"kubectl -n {ns} create job {job} --from=cronjob/{cronjob} --dry-run=client -o json")
              container = spec["spec"]["template"]["spec"]["containers"][0]
              container["env"] = [e for e in container.get("env", []) if e["name"] not in env] + [
                  {"name": k, "value": v} for k, v in env.items()
              ]
              if backoff is not None:
                  spec["spec"]["backoffLimit"] = backoff
              log = f"{ns}-{job}.log"
              server.succeed(
                  f"(seen=; for _ in $(seq 2400); do"
                  f" for pod in $(kubectl -n {ns} get pods -l job-name={job} -o name"
                  " --sort-by=.metadata.creationTimestamp 2>/dev/null); do"
                  f' case " $seen " in *" $pod "*) ;; *) kubectl -n {ns} logs -f $pod > /tmp/{log}.part 2>/dev/null'
                  f' && mv /tmp/{log}.part /tmp/{log} && seen="$seen $pod" ;; esac; done;'
                  f" state=$(kubectl -n {ns} get job {job} --ignore-not-found"
                  " -o jsonpath='{.metadata.name} {.status.conditions[?(@.status==\"True\")].type}');"
                  ' case $state in "" | *Complete* | *Failed*) [ -n "$seen" ] && break ;; esac;'
                  f" sleep 0.5; done; mv /tmp/{log} /tmp/shared/{log}) </dev/null >/dev/null 2>&1 &"
              )
              apply(spec)
              conditions = []

              def ended(_):
                  status, out = server.execute(
                      f"kubectl -n {ns} get job {job} --ignore-not-found"
                      " -o jsonpath='{.metadata.name} {.status.conditions[?(@.status==\"True\")].type}'"
                  )
                  if status != 0:
                      return False
                  conditions[:] = out.split()[1:] if out.split() else ["Gone"]
                  return bool({"Complete", "Failed", "Gone"} & set(conditions))

              retry(ended, timeout_seconds=1200)
              server.wait_until_succeeds(f"test -e /tmp/shared/{log}", timeout=60)
              return "Failed" not in conditions, (server.shared_dir / log).read_text()

          def flip(path):
              # Inverts a byte of a file at a provider, in what rclone's crypt and restic both authenticate.
              byte = int(acme.succeed(f"od -An -tu1 -j40 -N1 {path}"))
              acme.succeed(f"printf '\\{255 - byte:03o}' | dd of={path} bs=1 seek=40 conv=notrunc status=none")

          with subtest("Each provider's copy of a tenant's PostgreSQL proves whole and readable with reads alone, and a damaged copy fails at that provider only"):
              ns = f"{first}-postgres"
              # No copy runs meanwhile, so the providers' files change only if a check writes them.
              merge(ns, "cronjob offsite", {"spec": {"suspend": True}})
              server.wait_until_succeeds(
                  f"test -z \"$(kubectl -n {ns} get cronjob offsite -o jsonpath='{{.status.active}}')\"", timeout=600
              )
              # All the bucket held before the push, read back in full.
              settings = {"CHECK_MIN_AGE": pushed, "CHECK_CYCLE": "1d"}
              before = {n: stored_at(n, first, "postgres") for n in providers}
              for n in providers:
                  passed, log = checked(ns, f"offsite-check-{n}", f"check-{n}", settings)
                  matching = [int(m) for m in re.findall(r" (\d+) matching files", log)]
                  assert passed and log.count(" 0 differences found") == 2 and len(matching) == 2 and min(matching) > 0, log
                  server.wait_until_succeeds(
                      f"kubectl -n {ns} get cronjob offsite-check-{n}"
                      " -o jsonpath='{.status.lastSuccessfulTime}' | grep .",
                      timeout=60,
                  )
              assert {n: stored_at(n, first, "postgres") for n in providers} == before
              # At provider 2 the copy of the first base backup's data changes a byte, and the copy of its record goes;
              # rclone's crypt gives their names there.
              secrets = f"${cluster}/tenants/{first}/secrets.yaml"
              copies = f"/var/lib/s3-2/data/{bucket_at(2, first)}/postgres"
              rclone = (
                  f"HOME=/tmp RCLONE_CONFIG_COPY_TYPE=crypt RCLONE_CONFIG_COPY_REMOTE={copies}"
                  f" RCLONE_CONFIG_COPY_PASSWORD=$(rclone obscure {read(secrets, 'POSTGRES_CRYPT_PASSWORD')})"
                  f" RCLONE_CONFIG_COPY_PASSWORD2=$(rclone obscure {read(secrets, 'POSTGRES_CRYPT_SALT')}) rclone"
              )
              info, data = sorted(acme.succeed(f"{rclone} lsf -R --files-only copy:postgres-g1/base").split())[:2]
              info, data = (
                  f"{copies}/{line.split()[-1]}" for line in acme.succeed(
                      f"{rclone} cryptdecode --reverse copy: postgres-g1/base/{info} postgres-g1/base/{data}"
                  ).splitlines()
              )
              acme.succeed(f"touch -r {data} /var/lib/s3-2/changed && mv {info} /var/lib/s3-2/missing")
              flip(data)
              passed, log = checked(ns, "offsite-check-2", "check-2-damaged", settings, backoff=0)
              assert not passed and "file not in" in log and "failed to authenticate decrypted block" in log, log
              passed, log = checked(ns, "offsite-check-1", "check-1-again", settings)
              assert passed, log
              # Put back as they were, for the restore from provider 2 below.
              flip(data)
              acme.succeed(f"touch -r /var/lib/s3-2/changed {data} && mv /var/lib/s3-2/missing {info}")
              assert stored_at(2, first, "postgres") == before["2"]
              passed, log = checked(ns, "offsite-check-2", "check-2-again", settings)
              assert passed, log
              merge(ns, "cronjob offsite", {"spec": {"suspend": False}})

          with subtest("When the cluster's object store has lost a tenant's backups, a release brings its PostgreSQL back from a provider's copy"):
              ns = f"{first}-postgres"
              merge("flux-system", f"kustomization {first}-postgres-cluster", {"spec": {"suspend": True}})
              server.succeed(f"kubectl -n {ns} delete cluster postgres --timeout=300s")
              # Its instance archives WAL until it stops, which would land after the wipe.
              server.wait_until_succeeds(f'test -z "$(kubectl -n {ns} get pods -l cnpg.io/cluster=postgres -o name)"', timeout=300)
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
              # The suspend held: a Cluster made before the restore's settings arrived would keep them out.
              server.fail(f"kubectl -n {ns} get cluster postgres")
              merge("flux-system", f"kustomization {first}-postgres-cluster", {"spec": {"suspend": False}})
              server.wait_until_succeeds(f"kubectl -n {ns} wait cluster postgres --for=condition=Ready --timeout=0", timeout=1200)
              server.wait_until_succeeds(
                  f"kubectl -n flux-system wait kustomization {first}-postgres-cluster --for=condition=Ready --timeout=0",
                  timeout=600,
              )
              # With the app's data, which it reaches with its own credentials, and archiving as generation g2.
              client(f"{first}-hello", "db")
              out = reached(f"{first}-hello", "select v from probe")
              assert out.strip() == "kept", out
              server.succeed(f"kubectl -n {first}-hello delete pod psql")
              recoverable(ns, "g2")
              # The next push sends generation g2 alone, not g1 again, fetched back as it was.
              push(ns, "push-g2")
              for n in providers:
                  now = stored_at(n, first, "postgres")
                  assert {f: t for f, t in now.items() if f in first_copies[n]} == first_copies[n], n
                  assert set(now) - set(first_copies[n]), n
              # The tenant's apps waited for their database, so the release reaches them last.
              server.wait_until_succeeds(
                  f"kubectl -n flux-system wait kustomization -l suveraen/tenant={first} --for=condition=Ready --timeout=0",
                  timeout=600,
              )

          with subtest("An app's volume goes to both providers, encrypted, and comes back from either as it was copied"):
              ns = f"{first}-hello"
              # VolSync copies a snapshot of the volume, which holds only what has reached its disk.
              server.succeed(
                  f"kubectl -n {ns} exec deploy/hello -- sh -c 'echo kept > /data/marker && echo gone > /data/removed && sync'"
              )

              def sync(kind, name, value):
                  # A copy already running would take the new trigger as its own, though its snapshot may predate the files.
                  server.wait_until_succeeds(
                      f"t=$(kubectl -n {ns} get {kind} {name} -o jsonpath='{{.status.lastSyncStartTime}}') && test -z \"$t\"",
                      timeout=600,
                  )
                  merge(ns, f"{kind} {name}", {"spec": {"trigger": {"manual": value}}})
                  server.wait_until_succeeds(
                      f"kubectl -n {ns} get {kind} {name} -o jsonpath='{{.status.lastManualSync}}' | grep -x {value}",
                      timeout=600,
                  )

              def restore(value, provider):
                  knobs = f"      HELLO_DATA_RESTORE: {value}\\n      HELLO_DATA_RESTORE_FROM: offsite-{provider}\\n"
                  release(
                      f"restore-volume-{value}",
                      f"${asCgit} sed -i '/HELLO_DATA_RESTORE/d' tenants/{first}/tenant.yaml"
                      f" && printf '{knobs}' | ${asCgit} tee -a tenants/{first}/tenant.yaml >/dev/null",
                  )
                  server.wait_until_succeeds(
                      f"kubectl -n {ns} get replicationdestination data -o jsonpath='{{.status.lastManualSync}}' | grep -x {value}",
                      timeout=600,
                  )
                  server.wait_until_succeeds(
                      f"kubectl -n flux-system wait kustomization {ns} --for=condition=Ready --timeout=0", timeout=600
                  )

              for n in providers:
                  sync("replicationsource", f"data-{n}", "first")
                  copies = f"/var/lib/s3-{n}/data/{bucket_at(n, first)}/volsync/hello"
                  acme.succeed(f"test -f {copies}/config && test -n \"$(find {copies}/data -type f)\" && ! grep -rq kept {copies}")
                  # The app's key reaches its own prefix alone, and can't take the repository's config or keys away.
                  ours, bucket = keys_of(first, n, "HELLO"), bucket_at(n, first)
                  refused_at(n, ours, f"s3api list-objects-v2 --bucket {bucket} --prefix postgres/")
                  refused_at(n, ours, f"s3api delete-object --bucket {bucket} --key volsync/hello/config")
                  key = acme.succeed(f"cd {copies}/.. && find hello/keys -type f | head -1").strip()
                  refused_at(n, ours, f"s3api delete-object --bucket {bucket} --key volsync/{key}")

              # Provider 1's copy, restored, holds both files.
              restore("one", 1)
              image = server.succeed(
                  f"kubectl -n {ns} get replicationdestination data -o jsonpath='{{.status.latestImage.name}}'"
              ).strip()
              apply({
                  "apiVersion": "v1",
                  "kind": "PersistentVolumeClaim",
                  "metadata": {"name": "restored", "namespace": ns},
                  "spec": {
                      "storageClassName": "ceph-block",
                      "accessModes": ["ReadWriteOnce"],
                      "resources": {"requests": {"storage": "1Gi"}},
                      "dataSource": {"apiGroup": "snapshot.storage.k8s.io", "kind": "VolumeSnapshot", "name": image},
                  },
              })
              apply(restricted(
                  ns, "reader", "cat /data/marker /data/removed",
                  mounts=[{"name": "data", "mountPath": "/data"}],
                  volumes=[{"name": "data", "persistentVolumeClaim": {"claimName": "restored"}}],
              ))
              assert finished(ns, "reader").split() == ["kept", "gone"]
              server.succeed(f"kubectl -n {ns} delete pod reader && kubectl -n {ns} delete pvc restored")

              # A file deleted before the next copies is gone again from provider 2's copy, restored over the first.
              server.succeed(f"kubectl -n {ns} exec deploy/hello -- sh -c 'rm /data/removed && sync'")
              for n in providers:
                  sync("replicationsource", f"data-{n}", "second")
              restore("two", 2)
              # Once nothing mounts the lost volume, which its deletion waits for, Flux makes it anew from the restore.
              server.succeed(
                  f"kubectl -n {ns} scale deployment hello --replicas=0 && kubectl -n {ns} delete pvc data --timeout=300s"
                  f" && kubectl -n flux-system annotate kustomization {ns} --overwrite reconcile.fluxcd.io/requestedAt=$(date +%s)"
              )
              server.wait_until_succeeds(
                  f"kubectl -n {ns} get pvc data -o jsonpath='{{.status.phase}}' | grep -x Bound", timeout=600
              )
              server.succeed(
                  f"kubectl -n {ns} scale deployment hello --replicas=1"
                  f" && kubectl -n {ns} rollout status deployment hello --timeout=300s"
              )
              assert server.succeed(f"kubectl -n {ns} exec deploy/hello -- cat /data/marker").strip() == "kept"
              server.fail(f"kubectl -n {ns} exec deploy/hello -- test -e /data/removed")

          with subtest("Nothing is left of the volumes copies and restores worked on, and tenants' volumes are backed up"):
              server.wait_until_succeeds(
                  "test -z \"$(kubectl get pv -o jsonpath='{.items[?(@.status.phase!=\"Bound\")].metadata.name}')\"",
                  timeout=300,
              )
              # Each volume in a tenant's namespace is one the platform backs up, or one VolSync works on.
              labels = {n["metadata"]["name"]: n["metadata"].get("labels", {}) for n in items("namespaces")}
              for c in items("pvc"):
                  meta = c["metadata"]
                  if "suveraen/tenant" in labels[meta["namespace"]]:
                      assert "suveraen/backup" in meta.get("labels", {}) or (
                          meta.get("labels", {}).get("app.kubernetes.io/created-by") == "volsync"
                      ), meta

          with subtest("Each copy of an app's volume proves whole and readable without a lock, a damaged copy or one that lost its config fails at that provider only, and an app that has copied nothing yet passes"):
              ns = f"{first}-hello"
              settings = {"CYCLE": "1d"}

              def repository(n):
                  return f"/var/lib/s3-{n}/data/{bucket_at(n, first)}/volsync/hello"

              # Nothing copies the volume now (its copies were triggered by hand above), so only a check could change
              # what the providers hold, old versions included.
              def listed(n):
                  versions = f"/var/lib/s3-{n}/versions/{bucket_at(n, first)}"
                  return acme.succeed(f"find {repository(n)} {versions} -printf '%p %s %T@\\n' | sort")

              before = {n: listed(n) for n in providers}
              for n in providers:
                  passed, log = checked(ns, f"offsite-check-{n}", f"check-{n}", settings)
                  assert passed and "read group #1 of" in log and "no errors were found" in log, log
              assert {n: listed(n) for n in providers} == before
              pack = acme.succeed(f"find {repository(2)}/data -type f | sort | head -1").strip()
              acme.succeed(f"touch -r {pack} /var/lib/s3-2/pack")
              flip(pack)
              passed, log = checked(ns, "offsite-check-2", "check-2-damaged", settings, backoff=0)
              assert not passed and "repository contains errors" in log, log
              passed, log = checked(ns, "offsite-check-1", "check-1-again", settings)
              assert passed, log
              flip(pack)
              acme.succeed(f"touch -r /var/lib/s3-2/pack {pack}")
              assert listed(2) == before["2"]
              # Nothing wrote to the other tenant's volume, so VolSync copied none of it: its first restore made an
              # empty repository at provider 1, where it looked, and provider 2 holds nothing.
              empty = {n: f"/var/lib/s3-{n}/data/{bucket_at(n, second)}/volsync/hello" for n in providers}
              acme.succeed(f"test -e {empty['1']}/config")
              acme.fail(f"test -e {empty['2']}")
              for n, said in [("1", "no errors were found"), ("2", "no repository yet")]:
                  passed, log = checked(f"{second}-hello", f"offsite-check-{n}", f"check-{n}", settings)
                  assert passed and said in log, log
              # Without its config, a repository that holds anything is no new one.
              acme.succeed(f"mv {empty['1']}/config /var/lib/s3-1/config")
              passed, log = checked(f"{second}-hello", "offsite-check-1", "check-1-unconfigured", settings, backoff=0)
              assert not passed and "lost its config, but still holds: keys/" in log, log
              acme.succeed(f"mv /var/lib/s3-1/config {empty['1']}/config")

          # Runs the server's checks once, and what they found, from that run's journal: whether they read the cluster,
          # and each finding's state and what it says.
          def host_checks():
              server.succeed("systemctl start host-checks")
              invocation = server.succeed("systemctl show -p InvocationID --value host-checks").strip()
              journal = f"journalctl -o cat _SYSTEMD_INVOCATION_ID={invocation}"
              # Its own files come last.
              server.wait_until_succeeds(f"{journal} | grep -Eq '^(ok|late) etcd-snapshots: '", timeout=60)
              findings = {}
              scope = None
              for line in shown(journal).splitlines():
                  if line.startswith("cluster scope: "):
                      scope = line.removeprefix("cluster scope: ")
                  elif m := re.fullmatch(r"(ok|late) (.+?): (.*)", line):
                      findings[m.group(2)] = (m.group(1), m.group(3))
              return scope, findings

          # What the server's checks have alerted so far, as the phone got it.
          def checks_said():
              return [(a["title"], a.get("priority", 3)) for a in alerts() if a.get("title", "").removeprefix(
                  "${nodes.server.networking.hostName}: ").startswith(("backups ", "Ceph ", "cluster status ", "still: "))]

          # A new etcd snapshot, as if k3s had made it a while ago: the copy leaves out one younger than a minute, which
          # may still be being written.
          def etcd_snapshot(name):
              server.succeed(f"k3s etcd-snapshot save --name {name}")
              [path] = server.succeed(f"ls /var/lib/rancher/k3s/server/db/snapshots/{name}-*.zip").split()
              server.succeed(f"touch -d '-2 minutes' {path}")
              return path.rsplit("/", 1)[1]

          platform = "${platformBucket}"

          def etcd_copies(n):
              return f"/var/lib/s3-{n}/data/{platform}/hosts/${nodes.server.networking.hostName}/etcd"

          with subtest("The server's cluster state goes to both providers, encrypted, under a key that reaches nothing else"):
              snapshot_name = etcd_snapshot("e2e")
              server.succeed("systemctl start offsite")
              for n in providers:
                  acme.succeed(f"test \"$(head -c 21 {etcd_copies(n)}/{snapshot_name}.age)\" = age-encryption.org/v1")
                  server_keys = (f"${nodes.server.networking.hostName}-{n}", f"${nodes.server.networking.hostName}-{n}-test-secret")
                  for tenant in tenants:
                      refused_at(n, server_keys, f"s3api list-objects-v2 --bucket {bucket_at(n, tenant)}")
                      refused_at(n, keys_of(tenant, n), f"s3api list-objects-v2 --bucket {platform}")

          with subtest("The server finds every backup's last good copy where its controller records it, and none is late"):
              # When each backup was last good, as the controllers record it, under the name the server gives it.
              def recorded():
                  stores = {(o["metadata"]["namespace"], o["metadata"]["name"]): o for o in items("objectstores")}
                  jobs = {(j["metadata"]["namespace"], j["metadata"]["name"]): j for j in items("cronjobs")}
                  backups = {}
                  for c in items("clusters.postgresql.cnpg.io"):
                      ns = c["metadata"]["namespace"]
                      [p] = [p["parameters"] for p in c["spec"]["plugins"] if p["name"] == "barman-cloud.cloudnative-pg.io"]
                      window = stores[(ns, p["barmanObjectName"])].get("status", {}).get("serverRecoveryWindow", {})
                      backups[f"{ns}/{c['metadata']['name']} base backup"] = (
                          window.get(p["serverName"], {}).get("lastSuccessfulBackupTime")
                      )
                      for name in ["offsite", "offsite-check-1", "offsite-check-2"]:
                          backups[f"{ns}/{name}"] = jobs[(ns, name)].get("status", {}).get("lastSuccessfulTime")
                  for r in items("replicationsources"):
                      ns = r["metadata"]["namespace"]
                      backups[f"{ns}/{r['metadata']['name']}"] = r.get("status", {}).get("lastSyncTime")
                      for name in ["offsite-check-1", "offsite-check-2"]:
                          backups[f"{ns}/{name}"] = jobs[(ns, name)].get("status", {}).get("lastSuccessfulTime")
                  return backups

              def moment(t):
                  return datetime.fromisoformat(t.replace("Z", "+00:00"))

              # The checks judge Ceph as Rook last recorded it.
              server.wait_until_succeeds(
                  "kubectl -n rook-ceph get cephcluster rook-ceph -o jsonpath='{.status.ceph.health}' | grep -x HEALTH_OK",
                  timeout=600,
              )
              before = recorded()
              scope, findings = host_checks()
              after = recorded()
              assert scope == "evaluated", scope
              # A copy may have finished while the checks ran.
              assert before.keys() == after.keys(), (before, after)
              archiving = {f"{c['metadata']['namespace']}/{c['metadata']['name']} WAL archiving"
                           for c in items("clusters.postgresql.cnpg.io")}
              assert len(archiving) == len(tenants), archiving
              offsite = {f"etcd-offsite-{n}" for n in providers}
              assert findings.keys() == before.keys() | archiving | offsite | {"Ceph status", "cluster status", "etcd-snapshots"}, findings
              assert all(state == "ok" for state, _ in findings.values()), findings
              for key in before:
                  detail, times = findings[key][1], [before[key], after[key]]
                  if detail.startswith("never, "):
                      assert None in times, (key, detail, times)
                  else:
                      m = re.match(r"last (\S+) \(", detail)
                      assert m and moment(m.group(1)) in {moment(t) for t in times if t}, (key, detail, times)
              # The off-site copies count from the snapshot each provider holds last.
              for n in providers:
                  stamp = int(server.succeed(f"stat -c %Y /var/lib/offsite/state/etcd.{n}"))
                  m = re.match(r"last (\S+) \(", findings[f"etcd-offsite-{n}"][1])
                  assert m and moment(m.group(1)).timestamp() == stamp, (n, findings[f"etcd-offsite-{n}"], stamp)
              assert findings["Ceph status"][1].startswith("HEALTH_OK, "), findings["Ceph status"]
              assert checks_said() == [], checks_said()

          with subtest("A pool past its quota's warning reaches the phone, one more pool still fits, and the alert clears"):
              apply({
                  "apiVersion": "ceph.rook.io/v1",
                  "kind": "CephBlockPool",
                  "metadata": {"name": "probe", "namespace": "rook-ceph"},
                  "spec": {
                      "failureDomain": setting("CEPH_FAILURE_DOMAIN"),
                      "replicated": {"size": 3, "requireSafeReplicaSize": True},
                      "parameters": {"min_size": "2"},
                      "quotas": {"maxSize": "4Mi"},
                  },
              })
              server.wait_until_succeeds(
                  "kubectl -n rook-ceph get cephblockpool probe -o jsonpath='{.status.phase}' | grep -x Ready", timeout=600
              )
              # Rook makes the pool with one placement group, which the autoscaler raises to its floor of 32 on its next
              # pass, once a minute.
              retry(lambda _: ceph("osd pool get probe pg_num")["pg_num"] == 32, timeout_seconds=300)
              retry(lambda _: all(s["state_name"] == "active+clean" for s in ceph("status")["pgmap"]["pgs_by_state"]),
                    timeout_seconds=300)
              # 3.5 MiB of 4: past the 80% at which Ceph warns, short of the 90% it calls an error.
              server.succeed(
                  "head -c 3670016 /dev/zero | kubectl -n rook-ceph exec -i deploy/rook-ceph-operator --"
                  " rados --conf=/var/lib/rook/rook-ceph/rook-ceph.config -p probe put fill -"
              )

              # Ceph's checks as Rook records them, but those the cluster mutes.
              def raised(_):
                  c = parsed("kubectl -n rook-ceph get cephcluster rook-ceph -o json")
                  muted = {k for k, v in c["spec"]["healthCheck"].get("muteHealthWarning", {}).items() if v["policy"] == "mute"}
                  return set(c["status"]["ceph"].get("details", {})) - muted == {"POOL_NEAR_FULL"}

              retry(raised, timeout_seconds=300)
              said = len(checks_said())
              host_checks()
              assert checks_said()[said:] == [("${nodes.server.networking.hostName}: Ceph HEALTH_WARN: POOL_NEAR_FULL", 4)]
              server.succeed("kubectl -n rook-ceph delete cephblockpool probe --timeout=300s")
              server.wait_until_succeeds(
                  "kubectl -n rook-ceph get cephcluster rook-ceph -o jsonpath='{.status.ceph.health}' | grep -x HEALTH_OK",
                  timeout=300,
              )
              host_checks()
              assert checks_said()[said + 1:] == [("${nodes.server.networking.hostName}: Ceph healthy again", 3)]

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

          with subtest("etcd comes back in place from a provider's copy, decrypted off the server, as it was when copied, and Ceph stays healthy"):
              server.succeed("kubectl create configmap before --from-literal=value=kept")
              snapshot_name = etcd_snapshot("in-place")
              server.succeed("systemctl start offsite")
              server.succeed("kubectl create configmap after --from-literal=value=lost")
              # As the operator does: the newest copy at a provider, read with the kit's key and decrypted off the server.
              kit = (
                  "RCLONE_CONFIG_KIT_TYPE=s3 RCLONE_CONFIG_KIT_PROVIDER=Other RCLONE_CONFIG_KIT_REGION=us-east-1"
                  f" RCLONE_CONFIG_KIT_ENDPOINT=http://{providers['1']} RCLONE_CONFIG_KIT_ACCESS_KEY_ID=kit-1"
                  " RCLONE_CONFIG_KIT_SECRET_ACCESS_KEY=kit-1-test-secret HOME=/tmp"
              )
              etcd = f"kit:{platform}/hosts/${nodes.server.networking.hostName}/etcd/"
              newest = acme.succeed(
                  f"{kit} rclone lsf --files-only --format tp {etcd} | sort | tail -n 1 | cut -d ';' -f 2"
              ).strip()
              assert newest == f"{snapshot_name}.age", newest
              acme.succeed(
                  f"{kit} rclone cat {etcd}{newest} | age -d -i ${keys.snakeOilEd25519PrivateKey} > /tmp/shared/etcd.zip"
              )
              restored = int(server.succeed("date +%s"))
              # It prints k3s's whole log, which is long.
              status = server.execute(
                  "timeout 600 suveraen-etcd-restore < /tmp/shared/etcd.zip > /tmp/shared/restore.log 2>&1"
              )[0]
              out = (server.shared_dir / "restore.log").read_text(errors="replace")
              assert status == 0 and "membership has been reset" in out, (status, out[-2000:])

              # The snapshot says the node was Ready; only the kubelet's own report since the restore counts.
              def reported(_):
                  status, out = server.execute(
                      "kubectl get node ${nodes.server.networking.hostName} -o jsonpath="
                      """'{range .status.conditions[?(@.type=="Ready")]}{.status} {.lastHeartbeatTime}{end}'"""
                  )
                  state, _, beat = out.strip().partition(" ")
                  return status == 0 and state == "True" and moment(beat).timestamp() >= restored

              retry(reported, timeout_seconds=600)
              server.succeed("kubectl get configmap before")
              server.fail("kubectl get configmap after")

              # Ceph as Rook has checked it since a moment: the health it recorded before says nothing.
              def healthy_since(t):
                  def healthy(_):
                      status, out = server.execute(
                          "kubectl -n rook-ceph get cephcluster rook-ceph"
                          " -o jsonpath='{.status.ceph.health} {.status.ceph.lastChecked}'"
                      )
                      health, _, checked = out.strip().partition(" ")
                      return status == 0 and health == "HEALTH_OK" and moment(checked).timestamp() >= t

                  return healthy

              retry(healthy_since(restored), timeout_seconds=600)

          with subtest("After a reboot Ceph comes back healthy, and the volumes with their data"):
              epoch = ceph("osd dump")["epoch"]
              server.shutdown()
              server.start()
              server.wait_for_unit("k3s.service")
              booted = int(server.succeed("date +%s"))

              # Each OSD marks itself up again as it starts, in a later map than the last before the reboot. Until then
              # the monitors may still count it up from before.
              def started(_):
                  if server.execute(f"{ceph_cli} osd dump -f json > /tmp/shared/output")[0] != 0:
                      return False
                  osds = json.loads((server.shared_dir / "output").read_bytes())["osds"]
                  return len(osds) == len(disks) and all(o["up"] == 1 and o["up_from"] > epoch for o in osds)

              retry(started, timeout_seconds=1200)
              # Their activations left the DB groups readable.
              for slot in range(len(disks)):
                  server.succeed(f"vgs osd{slot}-db")
              apply(on("after", "restored", "cat /data/marker"))
              assert finished("volumes", "after").strip() == "kept"
              retry(healthy_since(booted), timeout_seconds=900)
          memory()
      except Exception:
          diagnose()
          raise
    '';
}
