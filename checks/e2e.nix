# Boots a server built from the same modules as a real one, with internet access, and lets Flux deploy
# kubernetes/clusters/test from a signed commit on a git server inside the test, with two test ACME CAs and a nameserver
# standing in for the internet's. Every Kustomization and HelmRelease becomes Ready, every Secret is stored encrypted
# with secretbox, no pod is refused and no job fails; both CAs know our accounts, and every host's certificate comes
# over DNS-01, its challenge answered in our ACME zone through the node's Knot and removed again, also where an
# organisation's own DNS points the challenge there; the standby CA, which requires our external account, issues too;
# every route answers through the host firewall, kube-proxy, the gateway and the app's network policy with a certificate
# from the CA, and port 80 redirects there; the platform's pods run ahead of tenants', and Ceph's monitors, OSDs and CSI
# node plugin at the node's priority, above every pod with a volume. Each tenant runs in exactly the
# namespaces its manifest asks for, and hello answers on each of its hosts with that tenant's own settings and restarts
# when they change; a tenant's pods reach neither other tenants' services nor the gateway's, and nothing outside reaches
# theirs; tenants can't take each other's namespaces or hosts or keep Gateways outside the gateway namespace, and stay
# within their quota; a host's key goes with its certificate; removing a tenant takes its Kustomizations, hosts, keys
# and pods but leaves its namespaces, which then go by its label; and an unsigned commit is never applied. Ceph runs
# healthy with three monitors and an encrypted OSD per disk, its DB on a volume of its own mirrored over both system
# disks, three copies on every pool and as many placement groups as its OSDs and pools call for, with room for one more
# pool, and the pools that hold data capped at what its disks hold with room to recover; block volumes bind, snapshot
# and restore, and go with their claims; the object store hands out buckets with keys of their own to the pods allowed
# to reach it; and a poweroff stops tenants' pods first and Ceph's last, once every volume is unmapped, so PostgreSQL
# shuts down cleanly, no lock is left behind, and after the reboot Ceph comes back with its data and the volumes with
# what was written just before. Each tenant's PostgreSQL archives WAL and base backups to its own bucket, takes no
# restore while it runs, and lets each app reach its own database alone, from its own namespace; a removed tenant's
# cluster and bucket go only with its namespaces. The bucket's running generation goes off-site to two providers,
# encrypted with the tenant's own key and locked for as long as the template says, where the cluster's keys can neither
# delete nor unlock a copy, nor reach another app's; when the cluster's object store has lost it, a release brings the
# tenant's PostgreSQL back from a provider's copy as a new generation, with its apps' data, and later copies leave the
# old generation's alone. A check that only reads proves each provider's copy whole and decrypting to what the bucket
# holds, and fails at that provider alone when a copy there changes or goes. An app's volume goes to both providers too,
# encrypted with the app's own password, and comes back from either as it was copied, without the files deleted before,
# and a check without restic's lock reads each copy back, fails at that provider alone when a copy there changes or has
# lost its config, and passes for an app that has copied nothing yet, whose first restore left an empty repository at
# one provider and none at the other; nothing is left of the volumes copies and restores worked on, and every volume in
# a tenant's namespace is backed up or VolSync's.
# Apps see a pseudonym per host in place of each client's address, never an address a client names in a header. The
# gateway gets each client's own address, limits each by it, and changes its key when it restarts; neither it nor a
# tenant's pod logs a client's address.
# Each tenant's Kanidm serves its own host through the gateway, which passes it through to Kanidm's own certificate,
# to clients that Kanidm sees as the gateway whatever they claim, and to that tenant's apps alone under the same name;
# it holds the platform's groups and each app's client as their files declare, an app's under IDs of the tenant's own
# from its Secret, which no other tenant's Kanidm holds, and hello signs in with its client in each. suveraen-idm, which
# reaches each Kanidm at the server's own gateway and never looks its name up, makes its first platform admin, who may
# enrol nothing but a passkey of an approved make, and a tenant admin, who makes the tenant's people and changes its
# groups' members but can't touch a platform admin or an admin group, nor delete or make a group, and sets Kanidm's own
# groups; refuses to make an admin of a person who exists already; copies each confidential client's secret from Kanidm
# into its app, so the release that adds an app is the only one, recovering idm_admin only when something is wrong;
# gives a client a new secret; passes on nothing an app's namespace writes but a secret as Kanidm makes them; and leaves
# idm_admin, admin and anonymous disabled. The checks take no run of Kanidm's migrations from lines a client had it log.
# A tenant's mesh answers on its own host, which the gateway passes through to its edge, whose port alone the gateway
# reaches; it reaches its tenant's PostgreSQL and Kanidm and nothing else, and once its database is back from a restore,
# suveraen-mesh raises its network serial and starts its management again. It starts at the release before its own: the
# first person of its group to sign in owns it, no one outside the group gets in, and it holds no policy and serves
# nothing but its own paths. Members' devices, which run NetBird's own client, one at the oldest release a mesh takes,
# sign in through Kanidm's pages and wait for approval, a box at home joins by a one-off key and routes to a camera that
# can't run NetBird, and each reaches what its policies name, one way, on their ports, and nothing else, relayed or
# not; a token from another tenant's Kanidm gets nowhere. The mesh keeps no device's address and calls nowhere, and its
# devices keep to it through an upgrade by a signed release, through the restore, whose lost changes they leave behind,
# and through the server's reboot, without signing in again.
# Kanidm's volume comes back with its people and keys, and with secrets its apps no longer hold, which rotate --all
# replaces; the server's checks alert once when an app holds a wrong one, and when that clears.
# The server's alerts reach a phone. Its etcd snapshots go to both providers encrypted, with a key that reaches no
# tenant's bucket, as no tenant's key reaches them. Its checks find every backup's last good copy where its controller
# records it, its own off-site copies included, none of them late, and each mesh within the operator's rules, in a
# session that takes no write; one more pool still fits, and when it passes its quota's warning they alert once, and
# once more when that clears, as for an exit, a token and a person who left in a mesh, with the change of who can reach
# what. Its etcd comes back in place from a provider's copy, decrypted off the server, as it was when copied, and Ceph
# stays healthy.
{
  pkgs,
  module,
  kubernetes,
  netbird,
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

  # The clients' way to the server's IPv6 node address, which is on the test network's link but outside its prefix.
  toServer =
    nodes:
    map (address: {
      inherit address;
      prefixLength = 128;
    }) (lib.filter (lib.hasInfix ":") nodes.server.suveraen.cluster.nodeIP);
  # A third client of the gateway, on acme but in an IPv6 /64 of its own, which the server reaches through acme.
  apartPrefix = "2001:db8:ffff::";
  apartClient = "${apartPrefix}1";

  # Members' devices run NetBird's own Linux client from its releases, as daemons that keep the mesh in userspace and so
  # touch no route, firewall rule or resolver of their node; each reaches the mesh through a SOCKS port of its own.
  netbirdClient =
    version:
    pkgs.runCommand "netbird-client-${version}" { } ''
      mkdir -p $out/bin
      tar -xzf ${
        pkgs.fetchurl {
          url = "https://github.com/netbirdio/netbird/releases/download/v${version}/netbird_${version}_linux_amd64.tar.gz";
          hash = netbird.clients.${version};
        }
      } -C $out/bin netbird
    '';
  devices = nodes: {
    # A person's laptop, whose own services the mesh reaches at its address.
    laptop = {
      node = "acme";
      version = netbird.version;
      n = 1;
      env.NB_ENABLE_NETSTACK_LOCAL_FORWARDING = "true";
    };
    # Another person's phone at the oldest release a mesh takes, which never connects directly.
    phone = {
      node = "acme";
      version = nodes.server.suveraen.checks.mesh.minimumClient;
      n = 2;
      env.NB_FORCE_RELAY = "true";
    };
    # The first person's box at home, joined by a setup key, which routes to a camera on its network.
    home = {
      node = "forge";
      version = netbird.version;
      n = 3;
      env.NB_ENABLE_NETSTACK_LOCAL_FORWARDING = "true";
    };
  };
  device =
    nodes: name:
    let
      d = (devices nodes).${name};
    in
    {
      inherit (d) node;
      netbird = "${netbirdClient d.version}/bin/netbird";
      daemon = "unix:///run/netbird-${name}/daemon.sock";
      socks = 1080 + d.n;
      wireguard = 51820 + d.n;
      interface = "wt${toString d.n}";
    };
  # Where the test puts what the devices trust and the names they reach the server by, before it starts them.
  meshFiles = "/run/netbird-e2e";
  devicesOn =
    nodes: node:
    lib.mapAttrs' (
      name: d:
      lib.nameValuePair "netbird-${name}" {
        description = "NetBird's client as ${name}";
        environment = {
          NB_USE_NETSTACK_MODE = "true";
          NB_FORCE_USERSPACE_FIREWALL = "true";
          NB_SOCKS5_LISTENER_PORT = toString (device nodes name).socks;
          SSL_CERT_FILE = "${meshFiles}/roots.pem";
        }
        // d.env;
        serviceConfig = {
          ExecStart = "${(device nodes name).netbird} service run --daemon-addr ${(device nodes name).daemon} --log-file console";
          StateDirectory = "netbird-${name}";
          RuntimeDirectory = "netbird-${name}";
          BindPaths = [ "/var/lib/netbird-${name}:/var/lib/netbird" ];
          BindReadOnlyPaths = [
            "${meshFiles}/hosts:/etc/hosts"
            "${meshFiles}/nsswitch.conf:/etc/nsswitch.conf"
          ];
        };
      }
    ) (lib.filterAttrs (_: d: d.node == node) (devices nodes));
  # A node's devices, the ports of their direct connections, which its firewall would otherwise leave to hole punching,
  # and the services the mesh reaches there.
  meshNode = nodes: node: services: {
    systemd.services = devicesOn nodes node // lib.listToAttrs services;
    networking.firewall.allowedUDPPorts = lib.mapAttrsToList (name: _: (device nodes name).wireguard) (
      lib.filterAttrs (_: d: d.node == node) (devices nodes)
    );
  };
  # What a device or the camera serves: its own name, or at /paced a line a second for 100 seconds.
  listener = pkgs.writers.writePython3 "listener" { flakeIgnore = [ "E501" ]; } ''
    import http.server
    import sys
    import time

    name, address, port = sys.argv[1], sys.argv[2], int(sys.argv[3])


    class Answer(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            lines = [f"{name} {i}\n".encode() for i in range(100)] if self.path == "/paced" else [f"{name}\n".encode()]
            self.send_response(200)
            self.send_header("Content-Length", str(sum(map(len, lines))))
            self.end_headers()
            for i, line in enumerate(lines):
                if i:
                    time.sleep(1)
                self.wfile.write(line)
                self.wfile.flush()

        def log_message(self, *_):
            pass


    http.server.ThreadingHTTPServer((address, port), Answer).serve_forever()
  '';
  listen =
    name: address: port: extra:
    lib.nameValuePair "listen-${toString port}-${address}" (
      lib.recursiveUpdate {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${listener} ${name} ${address} ${toString port}";
      } extra
    );
  # A camera that can't run NetBird, on a network of its own behind the home box, which nothing else routes to; and a
  # second address there that no policy names.
  camera = "192.168.50.10";
  other = "192.168.50.11";
  inCamera = {
    requires = [ "camera.service" ];
    after = [ "camera.service" ];
    serviceConfig.NetworkNamespacePath = "/run/netns/camera";
  };
  # The server images as the HelmRelease names them, at a release.
  netbirdTags =
    release:
    map (image: "tag: ${release.version}@${release.digests.${image}}") [
      "management"
      "signal"
      "relay"
    ];
  netbirdImages =
    release:
    map (image: "ghcr.io/netbirdio/${image}:${release.version}@${release.digests.${image}}") [
      "management"
      "signal"
      "relay"
    ];
  signin = pkgs.writers.writePython3Bin "signin" { flakeIgnore = [ "E501" ]; } (
    builtins.readFile ./signin.py
  );

  # The driver's builder gets the script in an environment variable, which holds no more than 128 KiB, so each driver,
  # the interactive one and the one the test's own run uses too, gets its attributes from a file instead.
  runTest =
    args:
    let
      test = pkgs.testers.runNixOSTest args;
      structured =
        priority: driver: lib.mkOverride priority (driver.overrideAttrs { __structuredAttrs = true; });
    in
    test.extend {
      modules = [
        {
          driver = structured 50 test.config.driver;
          # The interactive test is this whole test again, with its own driver over this one.
          interactive.driver = structured 40 test.config.interactive.driver;
        }
      ];
    };
in
runTest {
  name = "suveraen-e2e";
  # Below the CI job's limit, so the waits in the script run out first and print what went wrong.
  globalTimeout = 7800;

  nodes.forge =
    { nodes, ... }:
    {
      # Read-only smart HTTP; Flux can't fetch over dumb HTTP or git://.
      services.cgit."forge.test" = {
        enable = true;
        scanPath = "/srv/git";
        gitHttpBackend.checkExportOkFiles = false;
      };
      imports = [
        (meshNode nodes "forge" [
          # The box's services, which the mesh reaches at its address: one shared, one never.
          (listen "forge:3389" "127.0.0.1" 3389 { })
          (listen "forge:5900" "127.0.0.1" 5900 { })
          (listen "camera:8080" camera 8080 inCamera)
          (listen "camera:8081" camera 8081 inCamera)
          (listen "other:8080" other 8080 inCamera)
        ])
      ];
      networking.firewall.allowedTCPPorts = [ 80 ];
      networking.interfaces.eth1.ipv6.routes = toServer nodes;
      environment.systemPackages = [
        pkgs.git
        pkgs.openssh
        pkgs.curl
      ];

      systemd.services.camera = {
        description = "A camera's network behind the home box";
        wantedBy = [ "multi-user.target" ];
        path = [ pkgs.iproute2 ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ip netns add camera
          ip link add camera type veth peer name eth0 netns camera
          ip address add 192.168.50.1/24 dev camera
          ip link set camera up
          ip -n camera address add ${camera}/24 dev eth0
          ip -n camera address add ${other}/24 dev eth0
          ip -n camera link set eth0 up
        '';
      };
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
        (meshNode nodes "acme" [
          # The laptop's services, which the mesh reaches at its address.
          (listen "acme:3389" "127.0.0.1" 3389 { })
          (listen "acme:8000" "127.0.0.1" 8000 { })
        ])
      ];
      environment.systemPackages = [
        # To find a tenant's copies there by the names its crypt encrypts.
        pkgs.rclone
        # To decrypt the server's own copies as the operator does.
        pkgs.age
        # The browser of the people whose devices sign in here.
        signin
      ];
      # Two CAs, two nameservers, two object stores and two NetBird clients.
      virtualisation.memorySize = 1536;
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
                _acme-challenge.idm CNAME _acme-challenge.vv1yn42a950j.${acmeZone}.
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
      # A second client of the gateway, and from its address in a /64 of its own, a third.
      networking.interfaces.eth1.ipv6 = {
        routes = toServer nodes;
        addresses = lib.mkAfter [
          {
            address = apartClient;
            prefixLength = 64;
          }
        ];
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

      networking.interfaces.eth1.ipv6.routes = [
        {
          address = apartPrefix;
          prefixLength = 64;
          via = nodes.acme.networking.primaryIPv6Address;
        }
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
          # What pods look up, so the test sees that a mesh's management asks for no name of its makers'.
          log-queries = true;
        };
        # As a real cluster's are found through the registries, its zones are found at the published nameserver.
        stub-zone = map (name: {
          inherit name;
          stub-addr = [ nodes.acme.networking.primaryIPAddress ];
        }) (ours ++ [ theirs ]);
      };
      # There's no release to upgrade to here.
      system.autoUpgrade.enable = lib.mkForce false;

      # No name of the tenants' identity hosts resolves here, so suveraen-idm proves it reaches each at the server's
      # own gateway, under certificates from the test CA, whose root the test puts where suveraen-idm looks for it.
      suveraen.idm.caFile = "/var/lib/test-ca.pem";
      # For the test's own looks into Kanidm, and at the certificates the hosts serve.
      environment.systemPackages = [
        config.suveraen.idm.kanidm
        pkgs.openssl
        signin
      ];

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
            "example.test".certificates = [
              "hello"
              "netbird"
            ];
            "one.test".certificates = [
              "@"
              "idm"
            ];
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
      import hashlib
      import ipaddress
      import json
      import os
      import re
      import shlex
      import time
      from datetime import datetime
      from urllib.parse import parse_qs, quote, urlsplit

      def read(path, key):
          with open(path) as f:
              value = re.search(rf'^  {key}: "?([^"\s]+)"?$', f.read(), re.MULTILINE)
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
          # The test CAs make their roots as they start, which apps in the cluster that reach its hosts trust
          # (PUBLIC_CA_BUNDLE).
          roots = ""
          for unit, port in [("pebble", 15000), ("pebble-standby", 15001)]:
              acme.wait_for_unit(f"{unit}.service")
              acme.wait_for_open_port(port)
              roots += acme.succeed(
                  f"curl -fsS --cacert ${caCert} --resolve acme.test:{port}:127.0.0.1 https://acme.test:{port}/roots/0"
              ).strip() + "\n"
          bundle = base64.b64encode(roots.encode()).decode()
          forge.succeed(
              f"${asCgit} sed -i 's|^  PUBLIC_CA_BUNDLE: \"\"$|  PUBLIC_CA_BUNDLE: {bundle}|' ${checkout}/settings.yaml"
              f" && grep -qxF '  PUBLIC_CA_BUNDLE: {bundle}' ${checkout}/settings.yaml"
          )
          # A tenant's mesh starts at the release before its own, which a later release upgrades.
          nb_release = "/srv/src/kubernetes/apps/netbird/app/helmrelease.yaml"
          nb_now, nb_before = ${builtins.toJSON (netbirdTags netbird)}, ${builtins.toJSON (netbirdTags netbird.previous)}
          forge.succeed(" && ".join(
              f"${asCgit} sed -i 's|{now}$|{before}|' {nb_release} && grep -qF '{before}' {nb_release}"
              f" && ! grep -qF '{now}' {nb_release}"
              for now, before in zip(nb_now, nb_before)
          ))
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

      # Ceph through the operator, as there's no toolbox.
      ceph_cli = (
          "kubectl -n rook-ceph exec deploy/rook-ceph-operator -- timeout 30 ceph --connect-timeout=10"
          " --conf=/var/lib/rook/rook-ceph/rook-ceph.config"
      )

      # The server's alerts so far, as the phone reads them.
      phone = "curl -fsS -u phone:${phonePassword} 'http://127.0.0.1:2587/ops/json?poll=1'"

      def alerts():
          server.succeed(f"{phone} > /tmp/shared/alerts")
          return [json.loads(line) for line in (server.shared_dir / "alerts").read_text().splitlines() if line]

      def diagnose():
          memory()
          # Most of what follows asks the API server, which may be restarting.
          server.execute("timeout 180 sh -c 'until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 5; done'")
          for cmd in [
              "kubectl get gitrepositories,ocirepositories,kustomizations,helmreleases -A",
              "kubectl get pods -A -o wide",
              "kubectl get pods -A --field-selector=status.phase=Failed"
              " -o jsonpath='{range .items[*]}{.metadata.namespace}{\" \"}{.metadata.name}{\"\\n\"}{end}'"
              " | while read -r ns pod; do"
              " kubectl -n $ns get pod $pod -o jsonpath='{.status.containerStatuses[*].state.terminated}{\"\\n\"}';"
              " kubectl -n $ns logs $pod --all-containers --tail=30 --prefix; done",
              "kubectl get networkpolicies -A",
              # What each namespace being deleted still waits for.
              "kubectl get namespaces --field-selector status.phase=Terminating"
              " -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions}{\"\\n\"}{end}'",
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
              # How starved the server is: steal (st) is time the runner didn't give it.
              "uptime; vmstat 1 5; grep . /proc/pressure/*; cat /proc/mdstat",
              "journalctl -b -k -o short-monotonic --no-pager"
              " | grep -iE 'clocksource|blocked for more than|\\bmd[0-9]+|resync' | tail -n 30",
              # Why k3s stopped or restarted in this boot, without the leftover containers each restart lists, and what
              # held up the last poweroff.
              "systemctl show k3s -p NRestarts; journalctl -b -u k3s -o short-precise --no-pager"
              " | grep -E 'level=fatal| F[0-9]{4} |panic:|[Ll]eaderelection lost|k3s\\.service|k3s service|Starting k3s '"
              " | grep -vE 'left-over process|unclean termination|remains running after' | tail -n 120",
              "journalctl --list-boots --no-pager",
              # Without the kernel's retries to reach a stopped monitor, three lines each, which would hide where a hang
              # began.
              "journalctl -b -1 -o short-monotonic --no-pager"
              " | grep -iE 'timed out|SIGKILL|still around|Failed unmounting|blocked for more than|libceph|rbd'"
              " | grep -vE 'libceph: (connect \\(|ceph_tcp_connect failed|mon[0-9]+ .* connect error)' | tail -n 60",
              # How the kubelet's last shutdown went: when it began and ended, when it told each pod to stop (it logs
              # its groups' progress only at a higher verbosity), what it unmounted, and how long logind held the
              # poweroff back for it.
              "cat /var/lib/kubelet/graceful_node_shutdown_state;"
              " kubectl get events -A --field-selector reason=NodeShutdown;"
              " kubectl get events -A --field-selector reason=Killing --sort-by=.lastTimestamp"
              " -o custom-columns=LAST:.lastTimestamp,NAMESPACE:.metadata.namespace,POD:.involvedObject.name,MESSAGE:.message"
              " | tail -n 150;"
              " journalctl -b -1 -u systemd-logind -o short-monotonic --no-pager | tail -n 20;"
              " journalctl -b -1 -u k3s -o short-monotonic --no-pager"
              " | grep -iE 'shutdown manager|UnmountDevice|Failed while waiting' | tail -n 60",
              "journalctl -u host-checks -o cat --no-pager | tail -n 80",
              # Each tenant's Kanidm: how it applied its migrations, and what it answered last.
              "kubectl get pods -A -l app.kubernetes.io/controller=kanidm"
              " -o jsonpath='{range .items[*]}{.metadata.namespace}{\" \"}{.metadata.name}{\"\\n\"}{end}'"
              " | while read -r ns pod; do kubectl -n $ns logs $pod -c app --prefix | grep -E 'migration|ERROR'"
              " | tail -n 40; kubectl -n $ns logs $pod -c app --prefix --tail=40; done",
              "suveraen-idm check",
              "suveraen-mesh check",
              phone,
          ]:
              print(f"$ {cmd}\n{shown(cmd)}")
          print(acme.execute("journalctl -u pebble -u knot -u 's3-*' --no-pager | tail -n 80")[1])
          images()
          diagnose_ceph()

      # Rook, Ceph through the operator (there's no toolbox), the object store and who may reach it, the CSI drivers,
      # the host's disks, and last ceph-volume's and the OSD prepare pods' own logs.
      def diagnose_ceph():
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
              *[f"{ceph_cli} {args}" for args in
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
              # What each OSD's activation did last, with xtrace, before and after its last restart; from the kubelet's
              # files, as the API server may be down.
              "for log in /var/log/pods/rook-ceph_rook-ceph-osd-[0-9]*/activate/*.log; do"
              " echo \"==> $log\"; tail -n 100 $log; done",
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

      # QEMU's peak memory per running machine, and what the runner has left of memory and CPU.
      def memory():
          for machine in machines_qemu:
              if machine.pid is not None:
                  with open(f"/proc/{machine.pid}/status") as status:
                      print(machine.name, [line.strip() for line in status if line.startswith(("VmHWM", "VmRSS"))])
          with open("/proc/meminfo") as meminfo:
              print([line.strip() for line in meminfo if line.startswith("MemAvailable")])
          print("runner load", os.getloadavg(), "on", os.cpu_count(), "CPUs")

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

          with subtest("The platform's pods run at its priority, tenants' at theirs, and Ceph's monitors, OSDs and CSI node plugin at the node's, which a shutdown stops last"):
              labels = {n["metadata"]["name"]: n["metadata"].get("labels", {}) for n in items("namespaces")}
              # Rook gives the monitors' class to their canaries and to each controller's version check too, and the
              # OSDs' to their prepare jobs.
              last = {"rook-ceph-mon", "rook-ceph-osd", "rook-ceph-osd-prepare", "rook-ceph.rbd.csi.ceph.com-nodeplugin"}
              platform = int(server.succeed("kubectl get priorityclass platform -o jsonpath='{.value}'"))
              for p in items("pods"):
                  ns, app = p["metadata"]["namespace"], p["metadata"].get("labels", {}).get("app", "")
                  # The platform's group of a shutdown waits for every volume to be unmapped, so no pod with one stops
                  # after it.
                  if any("persistentVolumeClaim" in v for v in p["spec"].get("volumes", [])):
                      priority = p["spec"].get("priority", 0)
                      assert priority <= platform, (p["metadata"]["name"], ns, priority)
                  if "suveraen/tenant" in labels[ns]:
                      want = "tenant"
                  elif ns == "rook-ceph" and (app in last or app.endswith("-detect-version")):
                      want = "system-node-critical"
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

          # A pod that meets the restricted standard, with the app's image, which has a shell and curl. No grep -m1:
          # under pipefail its early exit fails the pipe once the list outgrows tr's buffer.
          podinfo = server.succeed(
              "kubectl get pods -A -o jsonpath='{.items[*].spec.containers[*].image}' | tr ' ' '\\n' | grep podinfo"
          ).split()[0]

          # For a pod that only asks a service something, small enough to leave an app's quota room for its movers.
          light = {
              "requests": {"cpu": "10m", "memory": "32Mi", "ephemeral-storage": "1Mi"},
              "limits": {"memory": "64Mi", "ephemeral-storage": "16Mi"},
          }

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
                          "resources": spec.pop("resources", {}),
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
              passthrough = {h: r["metadata"]["namespace"] for r in items("tlsroute") for h in r["spec"]["hostnames"]}
              assert passthrough, "no routes passed through"
              # What each app passed through answers on without a sign-in.
              unsigned = {"kanidm": "status", "netbird": "api/instance"}
              for host in hosts + sorted(passthrough):
                  # -f: a refused connection, a bad certificate or an error status all fail.
                  path = unsigned[passthrough[host].split("-", 1)[1]] if host in passthrough else ""
                  forge.wait_until_succeeds(
                      f"curl -fsS -o /dev/null --cacert /tmp/ca.crt --resolve {host}:443:${server} https://{host}/{path}",
                      timeout=300,
                  )
                  redirect = forge.succeed(
                      f"curl -sS -o /dev/null -w '%{{http_code}} %{{redirect_url}}' --resolve {host}:80:${server} http://{host}/"
                  ).split()
                  assert redirect == ["301", f"https://{host}/"], redirect
              # A host passed through is served with the app's own certificate, which the gateway never holds.
              def fingerprint(pem):
                  return server.succeed(f"{pem} | openssl x509 -noout -fingerprint -sha256").strip()

              for host, namespace in passthrough.items():
                  served = fingerprint(f"openssl s_client -connect ${server}:443 -servername {host} </dev/null 2>/dev/null")
                  held = fingerprint(f"kubectl -n {namespace} get secret tls -o jsonpath='{{.data.tls\\.crt}}' | base64 -d")
                  assert served == held, (host, served, held)

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

          def fetch(host, address="${server}"):
              return f"curl -fsS --cacert /tmp/ca.crt --resolve {host}:443:{address} https://{host}/"

          # Headers in which a client names an address of its own choosing, in several spellings.
          forged = [
              "X-Forwarded-For", "X-Real-Ip", "Forwarded", "True-Client-Ip", "X.Forwarded.For", "X_Forwarded_For",
              "Client-Ip", "X-Forwarded", "Forwarded-For", "X-Originating-Ip", "Proxy-Client-Ip", "WL-Proxy-Client-IP",
              "X-Appengine-User-Ip", "Cf-Pseudo-Ipv4", "HTTP_CLIENT_IP",
          ]
          ranges = [ipaddress.ip_network(setting(f"GATEWAY_PSEUDONYM_V{v}")) for v in [4, 6]]

          # The client's address as hello's podinfo is told it, from the headers it echoes.
          def pseudonym(node, host, address="${server}", source=None):
              forging = " ".join(f"-H '{name}: 192.0.2.1'" for name in forged)
              bind = f" --interface {source}" if source else ""
              out = node.succeed(f"{fetch(host, address)}headers {forging}{bind}")
              assert "192.0.2.1" not in out, out
              told = {name.lower(): values for name, values in json.loads(out).items()}
              assert "forwarded" not in told and "true-client-ip" not in told, told
              assert len(told.get("x-forwarded-for", [])) == 1 and told["x-forwarded-for"] == told.get("x-real-ip"), told
              address = ipaddress.ip_address(told["x-real-ip"][0])
              assert any(address in r for r in ranges), (address, ranges)
              return address

          with subtest("Apps see a pseudonym per host, never a client's address or the headers it forges"):
              here, there = hosts_of(first, f"{first}-hello")[0], hosts_of(second, f"{second}-hello")[0]
              forge_here = pseudonym(forge, here)
              print(f"forge is {forge_here} to {here}")
              assert pseudonym(forge, here) == forge_here, "the pseudonym changed within its period"
              forge_there = pseudonym(forge, there)
              print(f"forge is {forge_there} to {there}")
              assert forge_there != forge_here, "two hosts see the same pseudonym"

              # Another client, with an address of its own. Were the pseudonyms the same, the gateway would have seen
              # one address for both: the way to it would still masquerade clients.
              acme.succeed("curl -fsS --cacert ${caCert} --resolve acme.test:15000:127.0.0.1 https://acme.test:15000/roots/0 > /tmp/ca.crt")
              acme_here = pseudonym(acme, here)
              print(f"acme is {acme_here} to {here}")
              assert acme_here != forge_here, "two clients share a pseudonym: the gateway saw one address for both"
              # Over IPv6 a client is its /64: forge and acme share one, and acme has an address in a /64 of its own
              # too. Were the pseudonyms of the two /64s the same, the gateway would have seen one address for both.
              published = server.succeed(
                  "kubectl -n gateway get service traefik -o jsonpath='{.status.loadBalancer.ingress[*].ip}'"
              ).split()
              six = [a for a in published if ipaddress.ip_address(a).version == 6]
              assert len(six) == 1, published
              # Each from the address meant: both of acme's suit the server's alike, and it would send from the newer.
              forge_six = pseudonym(forge, here, f"[{six[0]}]", "${nodes.forge.networking.primaryIPv6Address}")
              acme_six = pseudonym(acme, here, f"[{six[0]}]", "${nodes.acme.networking.primaryIPv6Address}")
              apart_six = pseudonym(acme, here, f"[{six[0]}]", "${apartClient}")
              print(f"forge is {forge_six}, acme {acme_six} and ${apartClient} {apart_six} to {here} over IPv6")
              assert forge_six.version == 6 and forge_six == acme_six, (forge_six, acme_six)
              assert apart_six.version == 6 and apart_six != forge_six, "two /64s share a pseudonym"

              # The limit counts each client apart: forge runs out of requests, acme doesn't.
              average, burst = int(setting("GATEWAY_RATE_AVERAGE")), int(setting("GATEWAY_RATE_BURST"))
              statuses = forge.succeed(
                  f"seq {3 * burst} | xargs -P {burst} -I@ curl -sS -o /dev/null -w '%{{http_code}}\\n'"
                  f" --cacert /tmp/ca.crt --resolve {here}:443:${server} https://{here}/"
              ).split()
              print(f"forge's {len(statuses)} requests at once: {sorted(statuses)}")
              assert "429" in statuses and "200" in statuses, statuses
              acme.succeed(f"{fetch(here)} -o /dev/null")
              # Until forge's allowance is whole again.
              time.sleep(burst / average)

              # The clients' own addresses reached the gateway but are in none of its logs, nor any tenant's.
              clients = [
                  "${nodes.forge.networking.primaryIPAddress}",
                  "${nodes.forge.networking.primaryIPv6Address}",
                  "${nodes.acme.networking.primaryIPAddress}",
                  "${nodes.acme.networking.primaryIPv6Address}",
                  "${apartClient}",
              ]
              namespaces = ["gateway"] + [
                  n.removeprefix("namespace/") for n in server.succeed("kubectl get namespace -l suveraen/tenant -o name").split()
              ]
              logs = shown(
                  f"for ns in {' '.join(namespaces)}; do for pod in $(kubectl -n $ns get pods -o name); do"
                  " kubectl -n $ns logs $pod --all-containers --prefix; done; done"
              )
              leaked = [a for a in clients if re.search(rf"\b{re.escape(a)}\b", logs)]
              assert not leaked, [line for line in logs.splitlines() if any(a in line for a in leaked)][:20]

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
                  # Refused, or dropped before curl connected: not a name that doesn't resolve, a probe that didn't run,
                  # nor a server that took too long to answer.
                  status, out = server.execute(f"{cmd} -w ' connects=%{{num_connects}}' 2>&1")
                  assert status == 7 or (status == 28 and "connects=0" in out.split()), (cmd, status, out)

              home, service, port = backends(first)[0]
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
              # Until k3s's policy controller has a pod's address, every policy that names its clients refuses the pod,
              # right or wrong. Each sync rebuilds them all from the pods it knows, so once a pod started after the
              # probe gets into its own namespace's service, what refuses the probes below is the policies.
              apply(restricted(
                  home, "admitted",
                  f"curl -fsS -m 5 --retry 30 --retry-delay 1 --retry-connrefused -o /dev/null {url(home, service, port)}",
                  resources=light,
              ))
              finished(home, "admitted")
              server.succeed(f"kubectl -n {home} delete pod admitted")
              inside = f"kubectl -n {home} exec svc/{service} -- curl -fsS -m 5 -o /dev/null"
              for backend in backends(first):
                  if backend[0] == home:
                      server.succeed(f"{inside} {url(*backend)}")
              for other in tenants[1:]:
                  assert backends(other), other
                  for backend in backends(other):
                      blocked(f"{inside} {url(*backend)}")
              blocked(f"{inside} http://traefik.gateway.svc/")
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
              # Nor a host passed through to another tenant's app.
              [passing] = get(f"kubectl -n {second}-kanidm get tlsroute")["items"]
              [ours] = [h for h, namespace in passthrough.items() if namespace == f"{first}-kanidm"]
              denied_by(copy("tlsroute", passing, lambda r: r["spec"].update(hostnames=[ours])), policy("hostnames"))
              denied_by(
                  copy("gateway", gateway, lambda g: g["metadata"].update(namespace=f"{second}-hello")), policy("edge-objects")
              )
              denied_by(create(probe(home, priorityClassName="platform"), "--dry-run=server"), policy("tenant-priority"))
              denied_by(create(probe(home, {"limits": {"memory": "64Gi"}}), "--dry-run=server"), "exceeded quota")

          # Each tenant's Kanidm at its public name, which the server reaches through the gateway as anyone does.
          idm = {t: h for h, namespace in passthrough.items() for t in tenants if namespace == f"{t}-kanidm"}
          assert sorted(idm) == tenants, idm
          kanidm_ca = "${nodes.server.suveraen.idm.caFile}"
          # The test's own requests reach Kanidm as suveraen-idm does, at the server's gateway, as no name of it
          # resolves there: curl by its address, and the client in a mount namespace whose hosts file names it.
          reach = {t: f"--cacert {kanidm_ca} --resolve {h}:443:${server}" for t, h in idm.items()}
          server.succeed(
              f"echo '${server} {' '.join(idm.values())}' > /run/e2e-hosts && echo 'hosts: files' > /run/e2e-nsswitch"
          )
          pinned = (
              "unshare --mount sh -c 'mount --bind /run/e2e-hosts /etc/hosts && mount --bind /run/e2e-nsswitch"
              " /etc/nsswitch.conf && { [ ! -d /run/nscd ] || mount -t tmpfs none /run/nscd; } && exec \"$@\"' sh"
          )

          def discovery(t):
              return f"https://{idm[t]}/oauth2/openid/hello-oidc/.well-known/openid-configuration"

          # How Kanidm answers the first step of a sign-in as an account.
          def signing_in(t, name):
              body = shlex.quote(json.dumps({"step": {"init": name}}))
              out = server.succeed(
                  f"curl -fsS {reach[t]} -H 'Content-Type: application/json' -d {body} https://{idm[t]}/v1/auth"
              )
              return json.loads(out)["state"]

          # What Kanidm's address of a client from outside is: the gateway's, whatever the client says.
          def seen_by_kanidm():
              out = forge.succeed(
                  f"curl -fsS --cacert /tmp/ca.crt --resolve {idm[first]}:443:${server} -H 'X-Forwarded-For: 192.0.2.1'"
                  f" -H 'Forwarded: for=192.0.2.1' https://{idm[first]}/v1/debug/ipinfo"
              )
              seen = ipaddress.ip_address(json.loads(out))
              if isinstance(seen, ipaddress.IPv6Address) and seen.ipv4_mapped:
                  seen = seen.ipv4_mapped
              assert any(seen in ipaddress.ip_network(setting(f"POD_CIDR_V{v}")) for v in [4, 6]), seen
              assert str(seen) not in ["192.0.2.1", "${nodes.forge.networking.primaryIPAddress}"], seen

          with subtest("Each tenant's Kanidm serves its own host to its own apps under the public name, and nothing else reaches it"):
              server.succeed(f"curl -fsS --cacert ${caCert} https://acme.test:15000/roots/0 > {kanidm_ca}")
              for t in tenants:
                  server.wait_until_succeeds(f"curl -fsS -o /dev/null {reach[t]} {discovery(t)}", timeout=300)

              # From a tenant's hello, with the test CA, which the cluster's DNS sends to that tenant's Kanidm Service.
              def from_hello(t, url):
                  return server.execute(
                      f"kubectl -n {t}-hello exec -i deploy/hello -- sh -c"
                      f" 'cat > /tmp/ca.crt && curl -fsS -m 10 --cacert /tmp/ca.crt {url}' < {kanidm_ca} 2>&1"
                  )

              for t in tenants:
                  status, out = from_hello(t, discovery(t))
                  assert status == 0, (t, status, out)
                  assert json.loads(out)["issuer"] == f"https://{idm[t]}/oauth2/openid/hello-oidc", (t, out)
              status, out = from_hello(second, discovery(first))
              assert status in [7, 28], (status, out)
              for t in tenants:
                  blocked(f"kubectl -n probe exec probe -- curl -fsS -m 5 -k https://{idm[t]}/status")
              seen_by_kanidm()

          with subtest("A tenant's mesh takes connections from the gateway on its edge's port alone, reaches its own PostgreSQL and Kanidm from management alone, and nothing else"):
              meshes = sorted(
                  n["metadata"]["labels"]["suveraen/tenant"] for n in items("namespaces")
                  if n["metadata"].get("labels", {}).get("suveraen/app") == "netbird"
              )
              assert meshes, meshes
              for mesh_t in meshes:
                  mesh_ns = f"{mesh_t}-netbird"
                  mesh_edge = f"https://netbird.{mesh_ns}.svc/api/instance"
                  blocked(f"{outside} -k {mesh_edge}")
                  blocked(f"{outside} http://netbird-management.{mesh_ns}.svc:8081/api/instance")
                  # Once a pod of the gateway's gets through to the edge, the policies know it.
                  server.succeed(
                      f"{create(probe('gateway'))} && kubectl -n gateway wait pod probe --for=condition=Ready --timeout=300s"
                  )
                  at_gateway = "kubectl -n gateway exec probe -- curl -fsS -m 5 -o /dev/null"
                  server.wait_until_succeeds(f"{at_gateway} -k {mesh_edge}", timeout=120)
                  for controller, ports in [("netbird", [10000, 8082, 9091, 9092, 9000]), ("management", [8081, 9090])]:
                      address = server.succeed(
                          f"kubectl -n {mesh_ns} get pod -l app.kubernetes.io/controller={controller}"
                          " -o jsonpath='{.items[0].status.podIP}'"
                      ).strip()
                      for port in ports:
                          blocked(f"{at_gateway} http://{address if ':' not in address else f'[{address}]'}:{port}/")
                  server.succeed("kubectl -n gateway delete pod probe")
                  # From a pod labelled as management's, its own Kanidm at the public name and its own PostgreSQL, once
                  # the policies know the pod; from one labelled as the edge's, which faces the internet, neither, once
                  # it gets through to the edge's Service; and from either, nothing else.
                  for controller in ["management", "netbird"]:
                      apply(restricted(
                          mesh_ns, "inside", "sleep 3600", {"app.kubernetes.io/controller": controller}, resources=light
                      ))
                      server.succeed(f"kubectl -n {mesh_ns} wait pod inside --for=condition=Ready --timeout=300s")
                      inside_mesh = f"kubectl -n {mesh_ns} exec inside -- curl -sS -m 5 -o /dev/null"
                      mesh_kanidm = f"-k https://{idm[mesh_t]}/status"
                      mesh_postgres = f"telnet://postgres-rw.{mesh_t}-postgres.svc:5432"
                      if controller == "management":
                          server.wait_until_succeeds(f"{inside_mesh} -f {mesh_kanidm}", timeout=120)
                          # PostgreSQL waits for a sign-in that never comes, so the connection is made and times out.
                          status, out = server.execute(
                              f"{inside_mesh} -w ' connects=%{{num_connects}}' {mesh_postgres} 2>&1"
                          )
                          assert "connects=1" in out.split(), (status, out)
                      else:
                          server.wait_until_succeeds(f"{inside_mesh} -f -k {mesh_edge}", timeout=120)
                          blocked(f"{inside_mesh} {mesh_kanidm}")
                          blocked(f"{inside_mesh} {mesh_postgres}")
                      for t in tenants:
                          if t != mesh_t:
                              blocked(f"{inside_mesh} -k https://{idm[t]}/status")
                      blocked(f"{inside_mesh} https://acme.test/")
                      blocked(f"{inside_mesh} http://forge.test/")
                      server.succeed(f"kubectl -n {mesh_ns} delete pod inside")

          with subtest("Lines a client has Kanidm log, as it logs what a client sends as it is, never count as a run of its migrations"):
              client_lines = ["11111111-2222-3333-4444-555555555555 " + line for line in [
                  "INFO     migration_apply [ 1.00ms | 1.00% / 100.00% ]",
                  "ERROR    [error]: Failed to apply migration | err: AccessDenied | path: /migrations/10-groups.json",
                  "INFO     x",
              ]]
              client_id = quote("\n".join(["e2e"] + client_lines), safe="")
              server.succeed(
                  f"curl -sS -o /dev/null {reach[first]} 'https://{idm[first]}/oauth2/authorise?response_type=code"
                  f"&client_id={client_id}&redirect_uri=https%3A%2F%2Fe2e.test%2F&scope=openid'"
              )
              server.succeed(f"kubectl -n {first}-kanidm logs kanidm-0 -c app | grep -Fx {shlex.quote(client_lines[1])}")
              found = {t["tenant"]: t["migrations"] for t in parsed("suveraen-idm check")["tenants"]}
              # Kanidm's own entries came as it first started, a later start upgrades nothing.
              assert {t: (m["upgrade"] or [], m["failed"], m["denied"]) for t, m in found.items()} == {
                  t: ([], [], 0) for t in tenants
              }, found

          # A new password for an account, which Kanidm's recovery by exec gives whatever kind of credential the
          # account may enrol, and takes at a sign-in.
          def recovered(t, name):
              out = json.loads(server.succeed(
                  f"kubectl -n {t}-kanidm exec kanidm-0 -c app -- /sbin/kanidmd scripting recover-account {name}"
              ))
              assert out["status"] == "ok", out
              return out["output"]

          # As an operator by hand: an account recovered by exec, and the client signed in with its new password.
          def signed_in(t, name):
              server.succeed(
                  f"KANIDM_PASSWORD={recovered(t, name)} {pinned} kanidm login -H https://{idm[t]} -C {kanidm_ca} -D {name}"
              )

          def as_idm_admin(t):
              server.succeed("rm -rf /root/.cache/kanidm_tokens")
              signed_in(t, "idm_admin")

          def cli(t, args, name="idm_admin"):
              return f"{pinned} kanidm -H https://{idm[t]} -C {kanidm_ca} -D {name} {args}"

          def kanidm(t, args):
              return parsed(cli(t, f"-o json {args}"))

          def disable_idm_admin(t):
              server.succeed(f"kubectl -n {t}-kanidm exec kanidm-0 -c app -- /sbin/kanidmd disable-account idm_admin")
              assert signing_in(t, "idm_admin") == {"denied": "account expired"}

          with subtest("suveraen-idm makes a platform admin and a tenant admin, who can't touch the platform's, sets Kanidm's own groups, and leaves no admin account usable"):
              # Without the makes and models platform-admins trusts, no one could enrol: a CA of the test's own.
              der = base64.b64decode(server.succeed(
                  "openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj /CN=e2e-attestation"
                  " -days 2 -keyout /dev/null -outform DER 2>/dev/null | base64 -w0"
              ))

              def b64url(data):
                  return base64.urlsafe_b64encode(data).decode().rstrip("=")

              cas = {"cas": {b64url(hashlib.sha256(der).digest()): {"ca": b64url(der), "aaguids": {}, "blanket_allow": True}}}
              server.succeed(f"echo {shlex.quote(json.dumps(cas))} > /tmp/cas.json")
              out = server.fail(f"suveraen-idm admin {first} platform e2eops 'E2E operator' 2>&1")
              assert "platform-admins has no attestation CA list" in out, out
              out = server.succeed(f"suveraen-idm admin {first} platform e2eops 'E2E operator' /tmp/cas.json")
              [token] = re.findall(rf"This link: https://{re.escape(idm[first])}/ui/reset\?token=(\S+)", out)
              # It comes with the way to open it pinned to the server, and with nothing else that holds the token, such
              # as a code a phone would open by DNS.
              hosts_line = f'"${lib.head nodes.server.suveraen.cluster.nodeIP} {idm[first]}"'
              assert hosts_line in out and out.count(token) == 1, out
              # The link lets them enrol a passkey of an approved make and model, and nothing else.
              exchanged = json.loads(server.succeed(
                  f"curl -fsS {reach[first]} -H 'Content-Type: application/json' -d '\"{token}\"'"
                  f" https://{idm[first]}/v1/credential/_exchange_intent"
              ))[1]
              assert [exchanged[k] for k in ["primary_state", "passkeys_state", "attested_passkeys_state"]] == [
                  "PolicyDeny", "PolicyDeny", "Modifiable"
              ], exchanged
              out = server.succeed(f"suveraen-idm admin {first} tenant e2eorg 'E2E organisation admin'")
              assert f"This link: https://{idm[first]}/ui/reset?token=" in out, out
              for name in ["idm_admin", "admin", "anonymous"]:
                  assert signing_in(first, name) == {"denied": "account expired"}, name
              as_idm_admin(first)
              domain = idm[first]

              def group(name):
                  return kanidm(first, f"group get {name}")["attrs"]

              admins, org = group("platform-admins"), group("tenant-admins")
              assert (admins["credential_type_minimum"], admins["authsession_expiry"], admins["privilege_expiry"]) == (
                  ["attested_passkey"], ["3600"], ["300"]
              ), admins
              assert (org["credential_type_minimum"], org["authsession_expiry"], org["privilege_expiry"]) == (
                  ["passkey"], ["3600"], ["600"]
              ), org
              assert "webauthn_attestation_ca_list" in admins, admins
              assert admins["member"] == [f"e2eops@{domain}"] and org["member"] == [f"e2eorg@{domain}"], (admins, org)
              assert not group("members").get("member")
              for name in ["idm_people_self_name_write", "idm_people_self_mail_write"]:
                  assert not group(name).get("member"), (name, group(name))
              assert sorted(group("idm_admins")["member"]) == [f"idm_admin@{domain}", f"platform-admins@{domain}"]
              for name in ["idm_people_on_boarding", "idm_service_desk"]:
                  assert f"tenant-admins@{domain}" in group(name)["member"], (name, group(name))
              for name in ["idm_people_admins", "idm_group_admins"]:
                  assert group(name)["member"] == [f"idm_admins@{domain}"], (name, group(name))
              for name in ["members", "hello-users"]:
                  assert group(name)["entry_managed_by"] == [f"tenant-admins@{domain}"], (name, group(name))
              client = kanidm(first, "system oauth2 get hello-oidc")["attrs"]
              assert client["oauth2_rs_scope_map"] == [f'hello-users@{domain}: {{"openid", "profile"}}'], client
              disable_idm_admin(first)
              # A person who exists already joins no admin group, as no one can say what credentials they hold.
              out = server.fail(f"suveraen-idm admin {first} platform e2eorg 'E2E organisation admin' /tmp/cas.json 2>&1")
              assert "e2eorg is a person outside platform-admins already" in out, out

              # A tenant admin, here with a password Kanidm doesn't yet refuse as they sign in, makes the tenant's
              # people and changes the members of its groups, but touches no platform admin, nor any admin group of
              # Kanidm's or the platform's, and deletes, renames or makes no group: Kanidm would keep a declared
              # group's ID, and fail every later file that names it.
              signed_in(first, "e2eorg")

              def as_org(args):
                  return cli(first, args, name="e2eorg")

              server.succeed(as_org("person create e2emember 'E2E member'") + f" && {as_org('group add-members members e2emember')}")
              assert "This link:" in server.succeed(as_org("person credential create-reset-token e2emember"))
              # The client exits 0 for a reset or removal Kanidm refused, and says so.
              assert "This link:" not in server.succeed(as_org("person credential create-reset-token e2eops") + " 2>&1")
              assert "failure" in server.succeed(as_org("person delete e2eops") + " 2>&1")
              server.fail(as_org("person validity expire-at e2eops now"))
              for name in ["platform-admins", "idm_admins", "idm_people_admins", "idm_people_self_mail_write"]:
                  server.fail(as_org(f"group add-members {name} e2eorg"))
              for args in ["group delete members", "group delete hello-users", "group rename hello-users hello-x",
                           "group set-entry-manager hello-users e2eorg"]:
                  server.fail(as_org(args))
              assert "Http(403" in server.succeed(as_org("group create e2e-users") + " 2>&1")
              server.fail(as_org("system oauth2 show-basic-secret hello-oidc") + " | grep -Ex '[a-hjkp-z0-9]{48}'")
              as_idm_admin(first)
              ops = kanidm(first, "person get e2eops")["attrs"]
              assert "account_expire" not in ops and f"platform-admins@{domain}" in ops["directmemberof"], ops
              disable_idm_admin(first)
              # No one can have a reset sent by mail, and the pages and the address check still work without anonymous.
              server.succeed(
                  f"curl -fsS {reach[first]} https://{idm[first]}/ui/recover | grep -F 'Account recovery has been disabled'"
              )
              server.succeed(f"curl -fsS -o /dev/null {reach[first]} https://{idm[first]}/ui/login")
              seen_by_kanidm()

          def sso_secret(t):
              return server.succeed(
                  f"kubectl -n {t}-hello get secret sso -o jsonpath='{{.data.client-secret}}' | base64 -d"
              )

          def set_sso_secret(t, value):
              data = {"data": {"client-secret": base64.b64encode(value.encode()).decode()}}
              server.succeed(f"kubectl -n {t}-hello patch secret sso --type merge -p {shlex.quote(json.dumps(data))}")

          # Kanidm's answer to a token request as hello-oidc with that secret and a junk code: 400 for the right
          # secret, 401 for a wrong one.
          def probe_token(t, secret):
              app_domain = read(f"${cluster}/tenants/{t}/secrets.yaml", "TENANT_APP_DOMAIN")
              return server.succeed(
                  f"printf %s {shlex.quote(secret)} | curl -sS -o /dev/null -w '%{{http_code}}' {reach[t]}"
                  " -d grant_type=authorization_code -d code=junk"
                  f" --data-urlencode redirect_uri=https://hello.{app_domain}/oauth2/callback"
                  " -d code_verifier=e2eprobee2eprobee2eprobee2eprobee2eprobee2eprobe --data-urlencode client_id=hello-oidc"
                  f" --data-urlencode client_secret@- https://{idm[t]}/oauth2/token"
              ).strip()

          # What suveraen-idm check finds of hello-oidc in each tenant.
          def hello_client():
              return {
                  t["tenant"]: [c for c in t["clients"] if c["client"] == "hello-oidc"]
                  for t in parsed("suveraen-idm check")["tenants"]
              }

          def recoveries(t):
              log = f"kubectl -n {t}-kanidm logs kanidm-0 -c app"
              return int(shown(f"{log} | grep -c handle_admin_recover_account").strip())

          # hello reads the secret from its Secret as it starts, and Reloader restarts it when that changes.
          def hello_holds(t, secret):
              server.wait_until_succeeds(
                  f"kubectl -n {t}-hello rollout status deployment hello --timeout=0 && test"
                  f" \"$(kubectl -n {t}-hello exec deploy/hello -- printenv OIDC_CLIENT_SECRET)\" = {shlex.quote(secret)}",
                  timeout=300,
              )

          with subtest("suveraen-idm sync copies each confidential client's secret from Kanidm into its app, so one release does, and recovers idm_admin only when something is wrong"):
              # Flux made each app's Secret with the placeholder, which Kanidm takes for a wrong secret.
              for t in tenants:
                  assert sso_secret(t) == "pending" and probe_token(t, "pending") == "401", t
              found = hello_client()
              assert {t: [c["secret"] for c in found[t]] for t in tenants} == {t: ["placeholder"] for t in tenants}, found
              out = server.succeed("suveraen-idm sync 2>&1")
              for t in tenants:
                  assert f"{t}: hello-oidc: its secret in {t}-hello/sso" in out, out
                  secret = sso_secret(t)
                  assert re.fullmatch(r"[a-hjkp-z0-9]{48}", secret), t
                  assert probe_token(t, secret) == "400", t
                  assert probe_token(t, "a" * 48) == "401", t
                  hello_holds(t, secret)
                  for name in ["idm_admin", "admin", "anonymous"]:
                      assert signing_in(t, name) == {"denied": "account expired"}, (t, name)
              found = hello_client()
              assert {t: [(c["secret"], c["flags"]) for c in found[t]] for t in tenants} == {
                  t: [("right", True)] for t in tenants
              }, found
              # With nothing wrong, nothing is recovered.
              before = {t: recoveries(t) for t in tenants}
              out = server.succeed("suveraen-idm sync 2>&1")
              assert "recovering" not in out and all(f"{t}: hello-oidc: in line" in out for t in tenants), out
              assert {t: recoveries(t) for t in tenants} == before, before

          with subtest("Each tenant's Kanidm holds hello's group and client under IDs of the tenant's own, from its Secret, and hello signs in with its client in each"):
              held = {}
              for t in tenants:
                  as_idm_admin(t)
                  held[t] = [kanidm(t, f"{kind} get {name}")["attrs"]["uuid"] for kind, name in [
                      ("group", "hello-users"), ("system oauth2", "hello-oidc")
                  ]]
                  disable_idm_admin(t)
                  secrets = f"${cluster}/tenants/{t}/secrets.yaml"
                  assert held[t] == [[read(secrets, key)] for key in ["HELLO_USERS_ID", "HELLO_OIDC_ID"]], (t, held[t])
                  assert probe_token(t, sso_secret(t)) == "400", t
              assert not {i for [i] in held[first]} & {i for [i] in held[second]}, held
              found = {t["tenant"]: t["ids"] for t in parsed("suveraen-idm check")["tenants"]}
              assert found == {t: [] for t in tenants}, found

          with subtest("suveraen-idm rotate gives a client a new secret, and no value an app's namespace writes reaches curl but a secret"):
              old = sso_secret(first)
              out = server.succeed(f"suveraen-idm rotate {first} hello-oidc 2>&1")
              assert f"{first}: hello-oidc: a new secret in {first}-hello/sso" in out, out
              new = sso_secret(first)
              assert new != old and probe_token(first, old) == "401" and probe_token(first, new) == "400"
              hello_holds(first, new)
              # A value that, written into a curl config, would read a file and write it elsewhere.
              crafted = 'x"\nurl = "file:///etc/machine-id"\noutput = "/tmp/crafted"\nx = "'
              set_sso_secret(first, crafted)
              assert [c["secret"] for c in hello_client()[first]] == ["invalid"]
              out = server.succeed(f"suveraen-idm sync {first} 2>&1")
              assert f"{first}: hello-oidc: holds no secret Kanidm makes" in out, out
              assert sso_secret(first) == new and probe_token(first, crafted) == "401"
              server.fail("test -e /tmp/crafted")

          with subtest("A suveraen-idm run that never holds the lock leaves the session of the one that does, and the next to hold it clears what a killed run left"):
              # A home as a run that holds the lock signs in with, or as one that was killed leaves.
              server.succeed("mkdir /run/suveraen-idm/home.held")
              out = server.succeed(
                  "flock /run/suveraen-idm/lock sh -c 'suveraen-idm check;"
                  " suveraen-idm bogus 2>/dev/null; echo usage $?;"
                  " timeout 5 suveraen-idm sync 2>/dev/null; echo waited $?;"
                  " test -d /run/suveraen-idm/home.held && echo held'"
              )
              assert out.splitlines() == ['{"busy": true}', "usage 2", "waited 124", "held"], out
              server.succeed("suveraen-idm check")
              server.fail("test -e /run/suveraen-idm/home.held")

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

          # A tenant's mesh as people use it: its owner through the dashboard's API, members' devices that run
          # NetBird's own client and sign in at the tenant's Kanidm or join by a setup key, and a camera behind a box at
          # someone's home.
          nb_ns = f"{first}-netbird"
          [nb_host] = [h for h, namespace in passthrough.items() if namespace == nb_ns]
          nb_reach = f"--cacert {kanidm_ca} --resolve {nb_host}:443:${server}"
          nb_db = (
              f"kubectl -n {first}-postgres exec $(kubectl -n {first}-postgres get pod -l cnpg.io/instanceRole=primary"
              " -o name) -c postgres -- psql -tA -d netbird -c"
          )
          nb_devices = ${builtins.toJSON (lib.genAttrs (lib.attrNames (devices nodes)) (device nodes))}
          nb_nodes = {"acme": acme, "forge": forge}
          nb_camera, nb_other = "${camera}", "${other}"
          # Its people by name, with their Kanidm IDs, passwords and tags; IDs the test keeps; the owner's token.
          nb_people = {}
          nb_ids = {}
          nb_owner_token = {}

          def nb_sign_in_token(t, person, password):
              return (
                  f"signin --cacert {kanidm_ca} --resolve {idm[t]}:${server} token https://{idm[t]} netbird-oidc"
                  f" https://{nb_host}/nb-auth {person} {shlex.quote(password)}"
              )

          # Kanidm's access token for the dashboard's client, as the dashboard gets it.
          def nb_token(t, person, password):
              return json.loads(server.succeed(nb_sign_in_token(t, person, password)))["access_token"]

          def nb_owner():
              # Kanidm's access tokens last 15 minutes.
              if time.monotonic() - nb_owner_token.get("at", -3600.0) > 600:
                  nb_owner_token.update(value=nb_token(first, "op", nb_people["op"]["password"]), at=time.monotonic())
              return nb_owner_token["value"]

          # NetBird's API through the gateway, as the owner unless a token is given: the status, and what it said.
          def nb_call(method, path, body=None, token=None):
              send = "" if body is None else f" -H 'Content-Type: application/json' -d {shlex.quote(json.dumps(body))}"
              status = server.succeed(
                  f"curl -sS {nb_reach} -o /tmp/shared/nb -w '%{{http_code}}' -X {method}"
                  f" -H 'Authorization: Bearer {token or nb_owner()}'{send} https://{nb_host}{path}"
              )
              text = (server.shared_dir / "nb").read_text()
              try:
                  return int(status), json.loads(text)
              except json.JSONDecodeError:
                  return int(status), text

          def nb(method, path, body=None):
              status, answer = nb_call(method, path, body)
              assert status == 200, (method, path, status, answer)
              return answer

          def nb_peers():
              return {p["name"]: p for p in nb("GET", "/api/peers")}

          # A policy as the operator makes them: one rule, from one member's own group, with the version check.
          def nb_policy(name, source, protocol="all", ports=None, two_way=False, group=None, resource=None):
              rule = {"name": name, "enabled": True, "action": "accept", "bidirectional": two_way, "protocol": protocol,
                      "sources": [source]}
              if ports:
                  rule["ports"] = ports
              if group:
                  rule["destinations"] = [group]
              if resource:
                  rule["destinationResource"] = resource
              return {"name": name, "enabled": True, "source_posture_checks": [nb_ids["floor"]], "rules": [rule]}

          # The operator's onboarding of a person whose first device waits for approval: a random tag, their own group
          # and their home's, the policy within their own group, their own as the one group their devices join, and
          # approval.
          def nb_onboard(name):
              person = nb_people[name]
              person["tag"] = os.urandom(3).hex()
              person["own"] = nb("POST", "/api/groups", {"name": f"own-{person['tag']}"})["id"]
              person["home"] = nb("POST", "/api/groups", {"name": f"home-{person['tag']}"})["id"]
              nb("POST", "/api/policies", nb_policy(f"own-{person['tag']}", person["own"], two_way=True,
                                                    group=person["own"]))
              nb("PUT", f"/api/users/{person['uuid']}", {"role": "user", "auto_groups": [person["own"]], "is_blocked": False})
              nb("POST", f"/api/users/{person['uuid']}/approve")

          # Who is in the mesh and what they may reach, without what changes as devices come and go.
          def nb_state():
              def ids(objects):
                  return sorted(o["id"] for o in objects or [])

              peers = sorted(
                  (p["id"], p["name"], p["ip"], p["dns_label"], p["user_id"], ids(p["groups"]))
                  for p in nb("GET", "/api/peers")
              )
              groups = sorted((g["id"], g["name"], ids(g.get("peers"))) for g in nb("GET", "/api/groups"))
              policies = sorted(
                  (q["id"], q["name"], q["enabled"], sorted(q.get("source_posture_checks") or []), sorted(
                      (r["bidirectional"], r["protocol"], sorted(r.get("ports") or []), ids(r.get("sources")),
                       ids(r.get("destinations")), json.dumps(r.get("destinationResource"), sort_keys=True))
                      for r in q["rules"]
                  ))
                  for q in nb("GET", "/api/policies")
              )
              networks = sorted(
                  (n["id"], n["name"],
                   sorted((r["id"], r.get("peer"), r["enabled"]) for r in nb("GET", f"/api/networks/{n['id']}/routers")),
                   sorted((r["id"], r["address"], r["enabled"]) for r in nb("GET", f"/api/networks/{n['id']}/resources")))
                  for n in nb("GET", "/api/networks")
              )
              return {"peers": peers, "groups": groups, "policies": policies, "networks": networks}

          def nb_cli(name, args):
              return f"{nb_devices[name]['netbird']} {args} --daemon-addr {nb_devices[name]['daemon']}"

          def nb_node(name):
              return nb_nodes[str(nb_devices[name]["node"])]

          # Runs netbird up on a device in the background, as its owner would: it ends once the device is in, or
          # refused. Where it writes what it says.
          def nb_up(name, flags=""):
              d, node, log = nb_devices[name], nb_node(name), f"/tmp/netbird-up-{name}"
              up = nb_cli(
                  name,
                  f"up --no-browser --management-url https://{nb_host} --hostname {name}"
                  f" --wireguard-port {d['wireguard']} --interface-name {d['interface']} {flags}",
              )
              # Run from a desktop session, the client signs in through a browser and a listener of its own (PKCE).
              node.succeed(
                  f"rm -f {log} {log}.status && (DESKTOP_SESSION=e2e {up} > {log} 2>&1; echo $? > {log}.status)"
                  " < /dev/null > /dev/null 2>&1 &"
              )
              return log

          # Whether a device's netbird up got it in, and what it said.
          def nb_ended(name, log):
              node = nb_node(name)
              node.wait_until_succeeds(f"test -s {log}.status", timeout=300)
              return node.succeed(f"cat {log}.status").strip() == "0", node.succeed(f"cat {log}")

          # A device signs in as a person: netbird up prints Kanidm's page, which a browser holding no session walks,
          # and the code goes back to the device's own listener. The page it was sent to, and how up ended.
          def nb_sign_in(name, person):
              node, log = nb_node(name), nb_up(name)
              page = f"https://{idm[first]}/ui/oauth2?"
              node.wait_until_succeeds(f"grep -qF {shlex.quote(page)} {log}", timeout=120)
              [authorize] = re.findall(rf"{re.escape(page)}\S+", node.succeed(f"cat {log}"))
              node.succeed(
                  f"signin --cacert ${meshFiles}/roots.pem --resolve {idm[first]}:${server} deliver"
                  f" {shlex.quote(authorize)} {person} {shlex.quote(nb_people[person]['password'])}"
              )
              return (authorize, *nb_ended(name, log))

          # A device's own view of the mesh, or None while its daemon doesn't answer.
          def nb_status(name):
              status, out = nb_node(name).execute(f"{nb_cli(name, 'status --json')} > /tmp/shared/nb-{name} 2>&1")
              text = (nb_node(name).shared_dir / f"nb-{name}").read_text()
              return json.loads(text) if status == 0 else None

          # What a device gets from an address through its SOCKS port: curl's status and what it printed.
          def nb_fetch(name, target):
              return nb_node(name).execute(
                  f"curl -sS -m 3 --socks5 127.0.0.1:{nb_devices[name]['socks']} http://{target}/ 2>&1"
              )

          # Lets nothing through: curl times out, or the device says it has no way there.
          def nb_blocked(name, target):
              status, out = nb_fetch(name, target)
              assert status in [28, 97], (name, target, status, out)

          def nb_reaches(name, target, served):
              retry(lambda _: nb_fetch(name, target) == (0, f"{served}\n"), timeout_seconds=120)

          # Once the policy that let it through is gone.
          def nb_refused(name, target):
              retry(lambda _: nb_fetch(name, target)[0] in [28, 97], timeout_seconds=60)

          # Each device's daemon answers, and holds its streams to management and signal.
          def nb_back(name):
              def back(_):
                  view = nb_status(name)
                  return bool(view) and view["management"]["connected"] and view["signal"]["connected"]

              return back


          # The release Helm has deployed last, and those before, newest first.
          def nb_history():
              status, out = server.execute(f"kubectl -n {nb_ns} get helmrelease netbird -o jsonpath='{{.status.history}}'")
              return sorted(json.loads(out), key=lambda s: s["version"], reverse=True) if status == 0 and out else []

          def nb_deployed(version):
              return lambda _: [(s["version"], s["status"]) for s in nb_history()[:1]] == [(version, "deployed")]

          def nb_running():
              return sorted(i for i in server.succeed(
                  f"kubectl -n {nb_ns} get deployments -o jsonpath='{{.items[*].spec.template.spec.containers[*].image}}'"
              ).split() if i.startswith("ghcr.io/"))

          # Lines of a device's log since a moment that say it lost or found management or signal.
          def nb_reconnects(name, since):
              return nb_node(name).execute(
                  f"journalctl -u netbird-{name} --since @{since} -o cat --no-pager"
                  " | grep -E '(connected to|disconnected from) the (Management|Signal)'"
              )[1]

          with subtest("A tenant's mesh, at the release before its own, makes the first person of its group its owner, refuses anyone outside the group, holds no policy, and serves nothing but its five paths"):
              assert nb_running() == sorted(${builtins.toJSON (netbirdImages netbird.previous)}), nb_running()
              # Its people, in its group from the start, so a passkey is all they could enrol; and one outside it.
              as_idm_admin(first)
              for who in ["op", "alice", "bob", "eve"]:
                  server.succeed(cli(first, f"person create {who} {who.capitalize()}"))
                  nb_people[who] = {"uuid": kanidm(first, f"person get {who}")["attrs"]["uuid"][0]}
              server.succeed(cli(first, "group add-members netbird-users op alice bob"))
              disable_idm_admin(first)
              for who, entry in nb_people.items():
                  entry["password"] = recovered(first, who)
              status, out = server.execute(f"{nb_sign_in_token(first, 'eve', nb_people['eve']['password'])} 2>&1")
              assert status != 0 and "Access Denied" in out, out
              # The first to sign in owns it.
              nb_me = nb("GET", "/api/users/current")
              assert (nb_me["id"], nb_me["role"]) == (nb_people["op"]["uuid"], "owner"), nb_me
              assert nb("GET", "/api/policies") == [], "a policy came with the account"
              assert [g["name"] for g in nb("GET", "/api/groups")] == ["All"]
              [nb_account] = nb("GET", "/api/accounts")
              nb_settings = nb_account["settings"]
              assert nb_settings["extra"]["user_approval_required"] and not nb_settings.get("jwt_groups_enabled"), nb_settings
              assert not nb_settings["peer_expose_enabled"] and not nb_settings.get("dns_domain"), nb_settings
              # The owner's settings before any device joins: a week's login, no IPv6 in the mesh, and a version check
              # for every policy.
              nb_settings |= {"peer_login_expiration_enabled": True, "peer_login_expiration": 7 * 86400, "ipv6_enabled_groups": []}
              nb("PUT", f"/api/accounts/{nb_account['id']}", {"settings": nb_settings})
              [nb_account] = nb("GET", "/api/accounts")
              assert nb_account["settings"]["peer_login_expiration"] == 7 * 86400, nb_account
              assert not nb_account["settings"].get("ipv6_enabled_groups"), nb_account
              nb_ids["floor"] = nb("POST", "/api/posture-checks", {
                  "name": "floor", "description": "The oldest release a mesh takes",
                  "checks": {"nb_version_check": {"min_version": "${nodes.server.suveraen.checks.mesh.minimumClient}"}},
              })["id"]

              # Without a token: paths of NetBird's own it doesn't route and those it refuses get the dashboard's 404
              # page, the API answers as management.
              def unsigned(path, method="GET"):
                  status = server.succeed(
                      f"curl -sS {nb_reach} -o /tmp/shared/nb -w '%{{http_code}}' -X {method} https://{nb_host}{path}"
                  )
                  return int(status), (server.shared_dir / "nb").read_text()

              page = unsigned("/404.html")
              assert page[0] == 200 and "<html" in page[1], page
              for path, method in [
                  ("/management.ProxyService/", "POST"), ("/ws-proxy/management", "GET"), ("/oauth2/", "GET"),
                  ("/api/setup", "POST"), ("/api/users/invites/nbi_x", "GET"), ("/api/reverse-proxy/callback", "GET"),
                  # The dashboard's own pages that no file holds, which its 404 page renders.
                  ("/nb-auth", "GET"), ("/team/users", "GET"),
              ]:
                  got = unsigned(path, method)
                  assert got == (404, page[1]), (path, got)
              got = unsigned("/api/setup-keys")
              assert got[0] == 401 and got[1] != page[1], got
              assert nb("GET", "/api/setup-keys") == []
              # The dashboard's page runs no script of its own, under the policy nginx was given.
              server.succeed(f"curl -fsS {nb_reach} -D /tmp/shared/nb-headers -o /tmp/shared/nb https://{nb_host}/")
              index = (server.shared_dir / "nb").read_text()
              assert not re.search(r"<script(?![^>]*\ssrc=)[^>]*>(?!\s*</script>)", index), "the dashboard's page runs an inline script"
              conf = server.succeed(f"kubectl -n {nb_ns} get configmap netbird -o jsonpath='{{.data.nginx\\.conf}}'")
              [wanted] = re.findall(r'add_header Content-Security-Policy "([^"]+)" always;', conf)
              headers = [h.split(":", 1) for h in (server.shared_dir / "nb-headers").read_text().splitlines() if ":" in h]
              assert [v.strip() for k, v in headers if k.lower() == "content-security-policy"] == [wanted], headers
              assert server.succeed(
                  f"{nb_db} \"select pg_encoding_to_char(encoding) from pg_database where datname = 'netbird'\""
              ).strip() == "UTF8"
              # Management asked no resolver for its makers' names: they lead nowhere in its pod.
              queries = shown("journalctl -u unbound -o cat --no-pager").splitlines()
              assert not [line for line in queries if re.search(r"\b(netbird\.io|api\.github\.com)\. ", line)]

          with subtest("A member's device asks for a fresh sign-in and waits for approval, then joins its person's own group"):
              # Kanidm applies the group's minimum as a person enrols: their reset offers no password.
              as_idm_admin(first)
              out = server.succeed(cli(first, "person credential create-reset-token alice"))
              disable_idm_admin(first)
              [reset] = re.findall(rf"This link: https://{re.escape(idm[first])}/ui/reset\?token=(\S+)", out)
              exchanged = json.loads(server.succeed(
                  f"curl -fsS {reach[first]} -H 'Content-Type: application/json' -d '\"{reset}\"'"
                  f" https://{idm[first]}/v1/credential/_exchange_intent"
              ))[1]
              assert [exchanged[k] for k in ["primary_state", "passkeys_state"]] == ["PolicyDeny", "Modifiable"], exchanged
              for node in [acme, forge]:
                  node.succeed(
                      f"mkdir -p ${meshFiles} && printf %s {shlex.quote(roots)} > ${meshFiles}/roots.pem"
                      f" && printf '127.0.0.1 localhost\\n::1 localhost\\n${server} {nb_host} {idm[first]}\\n'"
                      " > ${meshFiles}/hosts && echo 'hosts: files dns' > ${meshFiles}/nsswitch.conf"
                  )
              for name in nb_devices:
                  nb_node(name).succeed(f"systemctl start netbird-{name}")
                  nb_node(name).wait_until_succeeds(nb_cli(name, "status"), timeout=60)
              # Two people's first devices, back to back: each is refused until its person is approved.
              for name, who in [("laptop", "alice"), ("phone", "bob")]:
                  authorize, joined, said = nb_sign_in(name, who)
                  asked = parse_qs(urlsplit(authorize).query)
                  assert (asked["prompt"], asked["scope"]) == (["login"], ["openid"]), authorize
                  assert not joined and "pending approval" in said, said
              nb_users = {u["id"]: u for u in nb("GET", "/api/users")}
              assert all(nb_users[nb_people[who]["uuid"]]["pending_approval"] for who in ["alice", "bob"]), nb_users
              # It keeps a person as their Kanidm ID alone.
              assert server.succeed(
                  f"{nb_db} 'select count(*) from users where coalesce(length(name), 0) + coalesce(length(email), 0) > 0'"
              ).strip() == "0"
              for who in ["alice", "bob"]:
                  nb_onboard(who)
              for name, who in [("laptop", "alice"), ("phone", "bob")]:
                  _, joined, said = nb_sign_in(name, who)
                  assert joined and "Connected" in said, said
              nb_seen = nb_peers()
              for name, who in [("laptop", "alice"), ("phone", "bob")]:
                  assert nb_seen[name]["user_id"] == nb_people[who]["uuid"], nb_seen[name]
                  assert sorted(g["name"] for g in nb_seen[name]["groups"]) == ["All", f"own-{nb_people[who]['tag']}"], nb_seen

          with subtest("A box at home joins by a one-off key, reaches nobody, and routes to a camera that can't run NetBird"):
              nb_alice = nb_people["alice"]
              nb_key = nb("POST", "/api/setup-keys", {
                  "name": f"home-{nb_alice['tag']}", "type": "one-off", "expires_in": 86400, "usage_limit": 1,
                  "auto_groups": [nb_alice["home"]],
              })
              joined, said = nb_ended("home", nb_up("home", f"--setup-key {nb_key['key']} --disable-client-routes"))
              assert joined and "Connected" in said, said
              nb_seen = nb_peers()
              nb_home, nb_laptop, nb_phone = nb_seen["home"], nb_seen["laptop"], nb_seen["phone"]
              assert sorted(g["name"] for g in nb_home["groups"]) == ["All", f"home-{nb_alice['tag']}"], nb_home
              assert not nb_home["user_id"] and not nb_home["login_expiration_enabled"], nb_home
              # Its person reaches its desktop, on the port the policy names, and nothing else of it.
              nb_box = {"id": nb_home["id"], "type": "peer"}
              nb_ids["box"] = nb("POST", "/api/policies", nb_policy(
                  f"box-{nb_alice['tag']}", nb_alice["own"], "tcp", ["3389"], resource=nb_box
              ))["id"]
              nb_network = nb("POST", "/api/networks", {"name": f"home-{nb_alice['tag']}"})
              nb("POST", f"/api/networks/{nb_network['id']}/routers",
                 {"peer": nb_home["id"], "metric": 9999, "masquerade": True, "enabled": True})
              nb_ids["camera"] = nb("POST", f"/api/networks/{nb_network['id']}/resources", {
                  "name": "camera", "address": f"{nb_camera}/32", "enabled": True, "groups": [],
              })["id"]
              nb("POST", "/api/policies", nb_policy(
                  f"camera-{nb_alice['tag']}", nb_alice["own"], "tcp", ["8080"], resource={"id": nb_ids["camera"], "type": "host"}
              ))
              nb_reaches("laptop", f"{nb_camera}:8080", "camera:8080")
              nb_reaches("laptop", f"{nb_home['ip']}:3389", "forge:3389")
              nb_blocked("laptop", f"{nb_home['ip']}:5900")
              # A rule both ways opens the way back from the box on that port, and one way closes it again.
              nb_blocked("home", f"{nb_laptop['ip']}:3389")
              for two_way in [True, False]:
                  nb("PUT", f"/api/policies/{nb_ids['box']}", nb_policy(
                      f"box-{nb_alice['tag']}", nb_alice["own"], "tcp", ["3389"], two_way=two_way, resource=nb_box
                  ))
                  if two_way:
                      nb_reaches("home", f"{nb_laptop['ip']}:3389", "acme:3389")
                  else:
                      nb_refused("home", f"{nb_laptop['ip']}:3389")

          with subtest("Two members' devices stay apart"):
              view = nb_status("phone")
              assert view and not view["peers"]["details"], view
              for target in [f"{nb_camera}:8080", f"{nb_home['ip']}:3389", f"{nb_laptop['ip']}:8000"]:
                  nb_blocked("phone", target)
              nb_blocked("laptop", f"{nb_phone['ip']}:8000")

          with subtest("An upgrade by a signed release keeps the mesh, and its devices come back to it by themselves"):
              nb_kept = nb_state()
              top = nb_history()[0]["version"]
              since = {name: int(nb_node(name).succeed("date +%s")) for name in nb_devices}
              release("netbird-upgrade", " && ".join(
                  f"${asCgit} sed -i 's|{before}$|{now}|' {nb_release}" for now, before in zip(nb_now, nb_before)
              ))
              retry(nb_deployed(top + 1), timeout_seconds=1200)
              # Helm upgraded it once, and neither rolled it back nor uninstalled it.
              assert [(s["version"], s["status"]) for s in nb_history()[:2]] == [(top + 1, "deployed"), (top, "superseded")]
              assert nb_running() == sorted(${builtins.toJSON (netbirdImages netbird)}), nb_running()
              server.wait_until_succeeds(f"curl -fsS -o /dev/null {nb_reach} https://{nb_host}/api/instance", timeout=600)
              assert nb_state() == nb_kept
              for name in nb_devices:
                  retry(nb_back(name), timeout_seconds=300)
                  assert "connected to the Management Service stream" in nb_reconnects(name, since[name]), name
              nb_reaches("laptop", f"{nb_camera}:8080", "camera:8080")

          with subtest("A share gives one port one way, relayed, past the gateway's timeouts"):
              nb_bob = nb_people["bob"]
              nb("POST", "/api/policies", nb_policy(
                  f"share-{nb_bob['tag']}-camera", nb_bob["own"], "tcp", ["8080"], resource={"id": nb_ids["camera"], "type": "host"}
              ))
              nb("POST", "/api/policies", nb_policy(
                  f"share-{nb_bob['tag']}-box", nb_bob["own"], "tcp", ["3389"], resource={"id": nb_home["id"], "type": "peer"}
              ))
              nb_reaches("phone", f"{nb_camera}:8080", "camera:8080")
              nb_reaches("phone", f"{nb_home['ip']}:3389", "forge:3389")
              # The box routes no other port of the camera's, and nothing routes to its neighbour.
              for target in [f"{nb_camera}:8081", f"{nb_other}:8080", f"{nb_home['ip']}:5900", f"{nb_laptop['ip']}:8000"]:
                  nb_blocked("phone", target)
              # Nor does the box get back to the phone: dropped, not answered.
              status, out = nb_fetch("home", f"{nb_phone['ip']}:3389")
              assert status == 28, (status, out)
              [via] = [p for p in nb_status("phone")["peers"]["details"] if p["fqdn"].startswith("home.")]
              assert (via["connectionType"], via["relayAddress"]) == ("Relayed", f"rels://{nb_host}:443"), via
              # Longer than any request timeout on the way, joined once the next subtests are done.
              since = {name: int(nb_node(name).succeed("date +%s")) for name in nb_devices}
              acme.succeed(
                  f"(curl -sS -m 300 --socks5 127.0.0.1:{nb_devices['phone']['socks']} http://{nb_camera}:8080/paced"
                  " > /tmp/paced 2>&1; echo $? > /tmp/paced.status) < /dev/null > /dev/null 2>&1 &"
              )

          with subtest("The mesh keeps no member's address, names its peers under its own suffix, routes nothing but the camera, and calls nowhere"):
              with open("${kubernetes}/apps/netbird/ks.yaml") as template:
                  suffix = re.search(r"NETBIRD_DNS_DOMAIN:=([^}]+)\}", template.read())
              assert suffix, "the template has no default suffix"
              pods = [ipaddress.ip_network(setting(f"POD_CIDR_V{v}")) for v in [4, 6]]
              for peer in nb("GET", "/api/peers"):
                  assert any(ipaddress.ip_address(peer["connection_ip"]) in r for r in pods), peer
                  assert peer["dns_label"].endswith(f".{suffix.group(1)}") and not peer.get("ipv6"), peer
              for name in nb_devices:
                  view = nb_status(name)
                  assert view and not view.get("netbirdIpv6"), view
                  routed = set(view.get("networks") or []) | {
                      n for p in view["peers"]["details"] or [] for n in p.get("networks") or []
                  }
                  assert routed <= {f"{nb_camera}/32"}, (name, routed)
              # What the mesh's pods logged names no device's own address: nginx dropped what a device could claim, and
              # management trusts no one's word for theirs.
              logs = shown(
                  f"for pod in $(kubectl -n {nb_ns} get pods -o name); do kubectl -n {nb_ns} logs $pod --all-containers"
                  " --prefix; done"
              )
              nb_addresses = [
                  "${nodes.forge.networking.primaryIPAddress}",
                  "${nodes.forge.networking.primaryIPv6Address}",
                  "${nodes.acme.networking.primaryIPAddress}",
                  "${nodes.acme.networking.primaryIPv6Address}",
              ]
              leaked = [a for a in nb_addresses if re.search(rf"\b{re.escape(a)}\b", logs)]
              assert not leaked, [line for line in logs.splitlines() if any(a in line for a in leaked)][:20]
              relayed = shown(f"kubectl -n {nb_ns} logs deploy/netbird -c relay")
              assert "connected from" not in relayed, relayed
              # Nor has management asked a resolver for its makers' names since it was upgraded.
              queries = shown("journalctl -u unbound -o cat --no-pager").splitlines()
              assert any(re.search(r"info: \S+ \S+\. A IN", line) for line in queries), "Unbound logged no query"
              asked = [line for line in queries if re.search(r"\b(netbird\.io|api\.github\.com)\. ", line)]
              assert not asked, asked

          with subtest("A token from another tenant's Kanidm, for a client of the same name, gets nowhere in this tenant's mesh"):
              as_idm_admin(second)
              for args in [
                  f"system oauth2 create-public netbird-oidc NetBird https://{nb_host}",
                  f"system oauth2 add-redirect-url netbird-oidc https://{nb_host}/nb-auth",
                  "system oauth2 update-scope-map netbird-oidc idm_all_persons openid",
                  "person create mallory Mallory",
              ]:
                  server.succeed(cli(second, args))
              disable_idm_admin(second)
              nb_theirs = nb_token(second, "mallory", recovered(second, "mallory"))
              assert nb_call("GET", "/api/users/current", token=nb_theirs)[0] == 401
              assert nb_call("GET", "/api/users/current")[0] == 200
              as_idm_admin(second)
              server.succeed(cli(second, "system oauth2 delete netbird-oidc") + " && " + cli(second, "person delete mallory"))
              disable_idm_admin(second)

          with subtest("The shared camera's slow page came through whole, and no device lost management or signal meanwhile"):
              acme.wait_until_succeeds("test -s /tmp/paced.status", timeout=300)
              paced = acme.succeed("cat /tmp/paced")
              assert acme.succeed("cat /tmp/paced.status").strip() == "0", paced
              assert paced.splitlines() == [f"camera:8080 {i}" for i in range(100)], paced
              for name in nb_devices:
                  assert not nb_reconnects(name, since[name]).strip(), (name, nb_reconnects(name, since[name]))

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
              pod = restricted(namespace, "psql", "sleep 3600", env=[{"secretRef": {"name": secret}}], resources=light)
              pod["spec"]["containers"][0]["image"] = postgres_image
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
              # A pod of the first tenant's app, which asks the object store below.
              apply(restricted(f"{first}-hello", "store", "sleep 3600", resources=light))
              server.succeed(f"kubectl -n {first}-hello wait pod store --for=condition=Ready --timeout=300s")
              client(f"{second}-hello", "db")
              # Until k3s's policy controller has a new pod's address, every policy that names its clients refuses the
              # pod, right or wrong. Each sync rebuilds them all from the pods it knows, so the one that lets the newest
              # pod into its own database knows every older one.
              reached(f"{second}-hello", "select 1")
              status, out = psql(f"{second}-hello", "psql", "select 1", host=f"postgres-rw.{first}-postgres.svc")
              assert status != 0 and ("Connection refused" in out or "timeout expired" in out), out
              status, out = psql("probe", "psql", "select 1")
              assert status != 0 and ("Connection refused" in out or "timeout expired" in out), out
              # Nor do apps reach the object store. The pod that asks is older than the newest client; hello's, which
              # the rotate subtest replaced without waiting, may not be.
              blocked(
                  f"kubectl -n {first}-hello exec store -- curl -fsS -m 5 -o /dev/null"
                  " http://rook-ceph-rgw-objects.rook-ceph.svc/"
              )
              server.succeed(
                  f"kubectl -n {first}-hello delete pod store psql && kubectl -n {second}-hello delete pod psql"
              )

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
              # The tenant's mesh, whose state is in that database, with a device that stays on throughout.
              assert first in meshes, meshes
              mesh_accounts = f"{nb_db} 'select id, network_serial from accounts'"
              # Nothing goes off-site from here on, so what the mesh does next is lost with the cluster.
              merge(ns, "cronjob offsite", {"spec": {"suspend": True}})
              server.wait_until_succeeds(
                  f"test -z \"$(kubectl -n {ns} get cronjob offsite -o jsonpath='{{.status.active}}')\"", timeout=600
              )
              mesh_serials = dict(line.split("|") for line in server.succeed(mesh_accounts).split())
              nb_kept = nb_state()
              # A port opened and closed again, which the device follows, takes its serial past the one restored.
              nb_vnc = nb_policy(f"vnc-{nb_alice['tag']}", nb_alice["own"], "tcp", ["5900"], resource=nb_box)
              nb_ids["vnc"] = nb("POST", "/api/policies", nb_vnc)["id"]
              nb_reaches("laptop", f"{nb_home['ip']}:5900", "forge:5900")
              nb("DELETE", f"/api/policies/{nb_ids['vnc']}")
              nb_refused("laptop", f"{nb_home['ip']}:5900")
              lost = dict(line.split("|") for line in server.succeed(mesh_accounts).split())
              assert all(int(lost[a]) >= int(n) + 2 for a, n in mesh_serials.items()), (mesh_serials, lost)
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
              # Its mesh runs again under serials past those its devices hold, which they would take no map below.
              out = server.succeed(f"suveraen-mesh after-restore {first}")
              # As the update found and left each one: once management starts again, devices coming back may step it.
              raised = {m.group(1): (m.group(2), m.group(3)) for m in re.finditer(
                  rf"^{first}: raised the network serial of account (\S+) from ([0-9]+) to ([0-9]+)$", out, re.M
              )}
              assert raised == {a: (n, str(int(n) + 1000000)) for a, n in mesh_serials.items()}, (mesh_serials, out)
              server.succeed(f"kubectl -n {first}-netbird wait deployment netbird-management --for=condition=Available --timeout=0")
              # The device that ran on takes the mesh as restored, and what changes after: the serial it holds from the
              # lost moments is below the new ones.
              retry(nb_back("laptop"), timeout_seconds=300)
              nb_ids["vnc"] = nb("POST", "/api/policies", nb_vnc)["id"]
              nb_reaches("laptop", f"{nb_home['ip']}:5900", "forge:5900")
              nb("DELETE", f"/api/policies/{nb_ids['vnc']}")
              nb_refused("laptop", f"{nb_home['ip']}:5900")
              assert nb_state() == nb_kept
              merge(ns, "cronjob offsite", {"spec": {"suspend": False}})

          with subtest("An app's volume goes to both providers, encrypted, and comes back from either as it was copied, Kanidm's with its people and keys"):
              hello_ns, idm_ns = f"{first}-hello", f"{first}-kanidm"
              # VolSync copies a snapshot of the volume, which holds only what has reached its disk.
              server.succeed(
                  f"kubectl -n {hello_ns} exec deploy/hello -- sh -c 'echo kept > /data/marker && echo gone > /data/removed && sync'"
              )
              # A person and Kanidm's signing keys, which its volume holds.
              as_idm_admin(first)
              server.succeed(cli(first, "person create probe Probe"))
              person = kanidm(first, "person get probe")["attrs"]["uuid"]
              disable_idm_admin(first)

              def signing_keys():
                  jwks = server.succeed(
                      f"curl -fsS {reach[first]} https://{idm[first]}/oauth2/openid/hello-oidc/public_key.jwk"
                  )
                  return sorted(k["kid"] for k in json.loads(jwks)["keys"])

              keys_before = signing_keys()

              # Copies both volumes to both providers at once.
              def copy_volumes(value):
                  copies = [(namespace, f"data-{n}") for namespace in [hello_ns, idm_ns] for n in providers]
                  for namespace, name in copies:
                      # A copy already running would take the new trigger as its own, though its snapshot may predate
                      # the files.
                      started = f"kubectl -n {namespace} get replicationsource {name} -o jsonpath='{{.status.lastSyncStartTime}}'"
                      server.wait_until_succeeds(f"t=$({started}) && test -z \"$t\"", timeout=600)
                      merge(namespace, f"replicationsource {name}", {"spec": {"trigger": {"manual": value}}})
                  for namespace, name in copies:
                      server.wait_until_succeeds(
                          f"kubectl -n {namespace} get replicationsource {name} -o jsonpath='{{.status.lastManualSync}}'"
                          f" | grep -x {value}",
                          timeout=600,
                      )

              # Restores both volumes in one release.
              def restore(value, provider):
                  knobs = "".join(
                      f"      {app}_DATA_RESTORE: {value}\\n      {app}_DATA_RESTORE_FROM: offsite-{provider}\\n"
                      for app in ["HELLO", "KANIDM"]
                  )
                  release(
                      f"restore-volume-{value}",
                      f"${asCgit} sed -i '/_DATA_RESTORE/d' tenants/{first}/tenant.yaml"
                      f" && printf '{knobs}' | ${asCgit} tee -a tenants/{first}/tenant.yaml >/dev/null",
                  )
                  for namespace in [hello_ns, idm_ns]:
                      server.wait_until_succeeds(
                          f"kubectl -n {namespace} get replicationdestination data -o jsonpath='{{.status.lastManualSync}}'"
                          f" | grep -x {value}",
                          timeout=600,
                      )
                      server.wait_until_succeeds(
                          f"kubectl -n flux-system wait kustomization {namespace} --for=condition=Ready --timeout=0",
                          timeout=600,
                      )

              # Reads a volume as the latest restore left it, in a pod of the app's user.
              def read_restored(namespace, uid, command):
                  image = server.succeed(
                      f"kubectl -n {namespace} get replicationdestination data -o jsonpath='{{.status.latestImage.name}}'"
                  ).strip()
                  apply({
                      "apiVersion": "v1",
                      "kind": "PersistentVolumeClaim",
                      "metadata": {"name": "restored", "namespace": namespace},
                      "spec": {
                          "storageClassName": "ceph-block",
                          "accessModes": ["ReadWriteOnce"],
                          "resources": {"requests": {"storage": "1Gi"}},
                          "dataSource": {"apiGroup": "snapshot.storage.k8s.io", "kind": "VolumeSnapshot", "name": image},
                      },
                  })
                  pod = restricted(
                      namespace, "reader", command,
                      mounts=[{"name": "data", "mountPath": "/data"}],
                      volumes=[{"name": "data", "persistentVolumeClaim": {"claimName": "restored"}}],
                  )
                  pod["spec"]["securityContext"] |= {"runAsUser": uid, "runAsGroup": uid, "fsGroup": uid}
                  apply(pod)
                  out = finished(namespace, "reader")
                  server.succeed(f"kubectl -n {namespace} delete pod reader && kubectl -n {namespace} delete pvc restored")
                  return out

              copy_volumes("first")
              for n in providers:
                  for app, secret in [("hello", "kept"), ("kanidm", "e2eops")]:
                      copies = f"/var/lib/s3-{n}/data/{bucket_at(n, first)}/volsync/{app}"
                      acme.succeed(
                          f"test -f {copies}/config && test -n \"$(find {copies}/data -type f)\""
                          f" && ! grep -rq {secret} {copies}"
                      )
                  # The app's key reaches its own prefix alone, and can't take the repository's config or keys away.
                  ours, bucket = keys_of(first, n, "HELLO"), bucket_at(n, first)
                  refused_at(n, ours, f"s3api list-objects-v2 --bucket {bucket} --prefix postgres/")
                  refused_at(n, ours, f"s3api list-objects-v2 --bucket {bucket} --prefix volsync/kanidm/")
                  refused_at(n, ours, f"s3api delete-object --bucket {bucket} --key volsync/hello/config")
                  key = acme.succeed(f"cd /var/lib/s3-{n}/data/{bucket} && find volsync/hello/keys -type f | head -1").strip()
                  refused_at(n, ours, f"s3api delete-object --bucket {bucket} --key {key}")

              # Provider 1's copies, restored, hold both files, and Kanidm's database with its own copy beside it.
              restore("one", 1)
              assert read_restored(hello_ns, 65534, "cat /data/marker /data/removed").split() == ["kept", "gone"]
              listed = read_restored(idm_ns, 389, "ls /data").split()
              assert "kanidm.db" in listed and any(re.fullmatch(r"backup-.*\.json\.gz", f) for f in listed), listed

              # A file deleted before the next copies is gone again from provider 2's copy, restored over the first.
              server.succeed(f"kubectl -n {hello_ns} exec deploy/hello -- sh -c 'rm /data/removed && sync'")
              copy_volumes("second")
              # Kanidm's secret for hello changes after the copies, so the restore brings back one the app no longer
              # holds.
              server.succeed(f"suveraen-idm rotate {first} hello-oidc")
              restore("two", 2)
              # Once nothing mounts the lost volume, which its deletion waits for, Flux makes it anew from the restore.
              for namespace, kind, name in [(hello_ns, "deployment", "hello"), (idm_ns, "statefulset", "kanidm")]:
                  server.succeed(
                      f"kubectl -n {namespace} scale {kind} {name} --replicas=0"
                      f" && kubectl -n {namespace} delete pvc data --timeout=300s"
                      f" && kubectl -n flux-system annotate kustomization {namespace} --overwrite"
                      " reconcile.fluxcd.io/requestedAt=$(date +%s)"
                  )
                  server.wait_until_succeeds(
                      f"kubectl -n {namespace} get pvc data -o jsonpath='{{.status.phase}}' | grep -x Bound", timeout=600
                  )
                  server.succeed(
                      f"kubectl -n {namespace} scale {kind} {name} --replicas=1"
                      f" && kubectl -n {namespace} rollout status {kind} {name} --timeout=300s"
                  )
              assert server.succeed(f"kubectl -n {hello_ns} exec deploy/hello -- cat /data/marker").strip() == "kept"
              server.fail(f"kubectl -n {hello_ns} exec deploy/hello -- test -e /data/removed")
              server.wait_until_succeeds(f"curl -fsS -o /dev/null {reach[first]} {discovery(first)}", timeout=300)
              assert signing_keys() == keys_before
              as_idm_admin(first)
              assert kanidm(first, "person get probe")["attrs"]["uuid"] == person
              disable_idm_admin(first)
              # The restored Kanidm holds the secret from before the rotation, which a sync would hand the app again;
              # rotate --all gives every confidential client a new one.
              assert [c["secret"] for c in hello_client()[first]] == ["wrong"]
              out = server.succeed(f"suveraen-idm rotate --all {first} 2>&1")
              assert f"{first}: hello-oidc: a new secret in {first}-hello/sso" in out, out
              assert [c["secret"] for c in hello_client()[first]] == ["right"]
              hello_holds(first, sso_secret(first))

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
              # Its findings come by scope and then key, so with a mesh in the cluster, its STUN port's comes last.
              server.wait_until_succeeds(f"{journal} | grep -Eq '^(ok|late|unknown) mesh STUN port: '", timeout=60)
              findings = {}
              scope = None
              for line in shown(journal).splitlines():
                  if line.startswith("cluster scope: "):
                      scope = line.removeprefix("cluster scope: ")
                  elif m := re.fullmatch(r"(ok|late|unknown|notice) (.+?): (.*)", line):
                      findings[m.group(2)] = (m.group(1), m.group(3))
              return scope, findings

          # What the server's checks have alerted so far, as the phone got it.
          def checks_said():
              ours = ("backups ", "Ceph ", "cluster status ", "Kanidm ", "STUN ", "mesh ", "still: ")
              return [(a["title"], a.get("priority", 3)) for a in alerts() if a.get("title", "").removeprefix(
                  "${nodes.server.networking.hostName}: ").startswith(ours)]

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
              # And each tenant's Kanidm, which the checks find in order, with the client of each app that signs in there.
              sso_clients = {
                  f"{c['metadata']['namespace']}/{c['metadata']['name'].removeprefix('sso-')}-oidc"
                  for c in items("configmaps") if c["metadata"]["name"].startswith("sso-")
              }
              identities = {"Kanidm check"} | sso_clients | {
                  f"{t}-kanidm{part}" for t in tenants for part in [" admin accounts", " migrations", " IDs"]
              }
              stun_findings = {f"STUN {a}" for a in ${builtins.toJSON nodes.server.suveraen.cluster.nodeIP}}
              # Each tenant's mesh, part by part, and this server's STUN port as the cluster names it.
              mesh_parts = {f"{t}-netbird {part}" for t in meshes for part in [
                  "exit", "public", "all", "share", "foreign", "home", "admins", "tokens", "powers", "settings", "floor",
                  "leaver", "changed", "check",
              ]} | {"mesh STUN port"}
              assert findings.keys() == (
                  before.keys() | archiving | offsite | identities | stun_findings | mesh_parts
                  | {"Ceph status", "cluster status", "etcd-snapshots"}
              ), findings
              assert all(state == "ok" for state, _ in findings.values()), findings
              # How each tenant's Kanidm ran its migrations as it started, which the checks go by once its log no longer
              # reaches back there.
              judged = json.loads(server.succeed("cat /var/lib/private/host-checks/kanidm-judged.json"))
              assert sorted(judged) == tenants, judged
              assert all(
                  j["migrations"]["failed"] == [] and j["migrations"]["denied"] == 0 and j["upgrade"] == []
                  for j in judged.values()
              ), judged
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
              # The first run that finds a mesh keeps its owner and its people's tags as it found them.
              kept = json.loads(server.succeed("cat /var/lib/private/host-checks/mesh.json"))
              assert kept[first]["owner"] == nb_people["op"]["uuid"], kept[first]
              assert kept[first]["tags"] == {nb_people[w]["uuid"]: nb_people[w]["tag"] for w in ["alice", "bob"]}, kept
              # The check's session takes no write, though its query reaches the whole database.
              status, out = server.execute(
                  "{ cat ${../nixos/mesh.sql}; echo 'UPDATE accounts SET network_serial = network_serial + 1;'; }"
                  f" | suveraen-mesh sql {first} 2>&1"
              )
              assert status != 0 and "cannot execute UPDATE in a read-only transaction" in out, (status, out)
              # It signs in as the mesh's own role, never the superuser, which would run what that role planted in its
              # database with every right.
              who = server.succeed(
                  "echo 'select current_user, session_user, rolsuper from pg_roles where rolname = session_user'"
                  f" | suveraen-mesh sql {first}"
              ).strip()
              assert who == "netbird|netbird|f", who

          with subtest("A planted exit, a token and a person who left reach the phone once, with the change of access, and so does their fix; once the owner blocks the person, their device is out of the mesh"):
              said = len(checks_said())
              host = "${nodes.server.networking.hostName}"
              nb_op, nb_bob = nb_people["op"], nb_people["bob"]
              # The owner can make what the rules forbid: a way to everywhere through the box, and a token.
              nb_ids["anywhere"] = nb("POST", f"/api/networks/{nb_network['id']}/resources", {
                  "name": "anywhere", "address": "0.0.0.0/0", "enabled": True, "groups": [],
              })["id"]
              nb_ids["token"] = nb("POST", f"/api/users/{nb_op['uuid']}/tokens", {
                  "name": "planted", "expires_in": 1,
              })["personal_access_token"]["id"]
              as_idm_admin(first)
              server.succeed(cli(first, "person validity expire-at bob now"))
              disable_idm_admin(first)
              assert signing_in(first, "bob") == {"denied": "account expired"}
              left = f"{nb_bob['uuid']} of own-{nb_bob['tag']} is expired at Kanidm"
              _, findings = host_checks()
              assert [findings[f"{nb_ns} {part}"][0] for part in ["exit", "tokens", "leaver", "changed"]] == [
                  "late", "late", "late", "notice",
              ], findings
              assert left in findings[f"{nb_ns} leaver"][1], findings[f"{nb_ns} leaver"]
              assert checks_said()[said:] == [
                  (f"{host}: mesh exit open; mesh leaver still in; mesh tokens outside the rules; mesh access changed", 4),
              ], checks_said()[said:]
              assert left in alerts()[-1]["message"], alerts()[-1]
              nb("DELETE", f"/api/networks/{nb_network['id']}/resources/{nb_ids['anywhere']}")
              nb("DELETE", f"/api/users/{nb_op['uuid']}/tokens/{nb_ids['token']}")
              nb("PUT", f"/api/users/{nb_bob['uuid']}", {"role": "user", "auto_groups": [nb_bob["own"]], "is_blocked": True})
              # Management ends the device's login, and refuses it as it comes back.
              retry(lambda _: (nb_status("phone") or {}).get("daemonStatus") in ["NeedsLogin", "SessionExpired"],
                    timeout_seconds=120)
              assert nb_peers()["phone"]["login_expired"], nb_peers()["phone"]
              status, out = nb_fetch("phone", f"{nb_camera}:8080")
              assert status != 0, (status, out)
              nb_reaches("laptop", f"{nb_camera}:8080", "camera:8080")
              _, findings = host_checks()
              assert [findings[f"{nb_ns} {part}"][0] for part in ["exit", "tokens", "leaver", "changed"]] == [
                  "ok", "ok", "ok", "notice",
              ], findings
              assert checks_said()[said + 1:] == [
                  (f"{host}: mesh exits closed; mesh leavers out; mesh tokens within the rules again; mesh access changed", 3),
              ], checks_said()[said + 1:]

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

          with subtest("An app whose copy of its client's secret is wrong reaches the phone once, and so does its sync"):
              said = len(checks_said())
              set_sso_secret(first, "a" * 48)
              _, findings = host_checks()
              assert findings[f"{first}-kanidm/hello-oidc"][0] == "late", findings
              assert checks_said()[said:] == [("${nodes.server.networking.hostName}: Kanidm clients out of sync", 4)]
              server.succeed(f"suveraen-idm sync {first}")
              _, findings = host_checks()
              assert findings[f"{first}-kanidm/hello-oidc"][0] == "ok", findings
              assert checks_said()[said + 1:] == [("${nodes.server.networking.hostName}: Kanidm clients in sync again", 3)]

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
              # A host passed through has its key with the app alone.
              [own] = get(f"kubectl -n {first}-kanidm get certificate")["items"]
              assert own["spec"]["dnsNames"] == [idm[first]], own
              for cert in certs + [own]:
                  where = cert["metadata"]["namespace"]
                  meta = get(f"kubectl -n {where} get secret {cert['spec']['secretName']}")["metadata"]
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
              # Flux puts git's setting back now, or a later release would, restarting the app when no step expects it.
              server.succeed(
                  f"kubectl -n flux-system annotate kustomization {tenant}-hello --overwrite"
                  " reconcile.fluxcd.io/requestedAt=$(date +%s)"
              )
              forge.wait_until_succeeds(
                  f"{fetch(hello[tenant][0])} | grep -F 'hello from {tenant} at {domains[tenant]}'", timeout=300
              )

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
              gone(f"helmrelease,httproute,tlsroute,networkpolicy -A -l suveraen/tenant={second}")
              # Its app's file goes from its Kanidm, whose database stays on its volume; its PostgreSQL and bucket are
              # never pruned: they go with the namespace alone.
              server.wait_until_fails(f"kubectl -n {second}-kanidm get configmap sso-hello", timeout=600)
              server.succeed(f"kubectl -n {second}-kanidm get pvc data")
              server.succeed(f"kubectl -n {second}-postgres get cluster postgres && kubectl -n {second}-postgres get objectbucketclaim bucket")
              for namespace in namespaces:
                  if namespace != f"namespace/{second}-postgres":
                      gone(f"pods -n {namespace.removeprefix('namespace/')}")
              assert server.succeed(f"kubectl get namespace -l suveraen/tenant={second} -o name").split() == namespaces
              for host in hosts_of(first):
                  forge.succeed(f"{fetch(host)} -o /dev/null")
              for host in theirs:
                  forge.wait_until_fails(f"{fetch(host)} -o /dev/null", timeout=120)
              forge.wait_until_fails(f"{fetch(idm[second])}status -o /dev/null", timeout=120)
              forge.succeed(f"{fetch(idm[first])}status -o /dev/null")
              asked = int(server.succeed("date +%s"))
              start = time.monotonic()
              server.succeed(f"kubectl delete namespace -l suveraen/tenant={second} --timeout=300s")
              print(f"the tenant's namespaces took {time.monotonic() - start:.0f} seconds to go")
              # No policy stood in the namespace controller's way.
              refusals = shown(
                  f"journalctl -u k3s --since @{asked} -o cat --no-pager"
                  " | grep -F 'Deletion of namespace failed' | grep -F forbidden"
              )
              assert not refusals.strip(), refusals

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

          with subtest("A poweroff stops tenants' pods first and Ceph's last, once every volume is unmapped, and after the reboot Ceph comes back healthy, and the volumes with what was written just before"):
              groups = ${builtins.toJSON nodes.server.services.k3s.extraKubeletConfig.shutdownGracePeriodByPodPriority}
              login = "org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager"

              # k3s restarted with the restore; its kubelet holds logind's delay lock again.
              def held(_):
                  status, out = server.execute(f"busctl --json=short call {login} ListInhibitors")
                  return status == 0 and any(
                      i[:2] == ["shutdown", "kubelet"] and i[3] == "delay" for i in json.loads(out)["data"][0]
                  )

              retry(held, timeout_seconds=300)
              pg = f"{first}-postgres"
              postgres = f"kubectl -n {pg} get cluster postgres -o jsonpath="
              smart = int(server.succeed(f"{postgres}'{{.spec.smartShutdownTimeout}}'"))
              primary = server.succeed(f"{postgres}'{{.status.currentPrimary}}'").strip()
              # PostgreSQL turns from a smart to a fast shutdown in time to stop within the tenants' group, which is all
              # its pod asks for.
              stop = server.succeed(
                  f"kubectl -n {pg} get pod {primary} -o jsonpath='{{.spec.terminationGracePeriodSeconds}}'"
              )
              assert 2 * smart <= int(stop) == groups[0]["shutdownGracePeriodSeconds"], (smart, stop, groups)
              epoch = ceph("osd dump")["epoch"]
              ns, token = f"{first}-hello", str(time.time_ns())
              # The restore may leave hello between two pods, which its controllers end only once the copy's leases
              # have run out, or with a pod whose container the kubelet is still starting again.
              server.succeed(f"kubectl -n {ns} rollout status deployment hello --timeout=600s")
              server.wait_until_succeeds(f"kubectl -n {ns} exec deploy/hello -- true", timeout=600)
              # Written just before the poweroff, and read back after it.
              server.succeed(f"kubectl -n {ns} exec deploy/hello -- sh -c 'echo {token} > /data/unsynced'")
              mapped = server.succeed("ls /sys/bus/rbd/devices").split()
              assert mapped, "no volume is mapped"
              # What the pod that holds the platform's group sees is the host's: the images mapped, and the rbd
              # module's references, which each image holds until its client has let go of it.
              barrier = "kubectl -n rook-ceph exec ds/unmap-barrier --"
              seen = server.succeed(f"{barrier} ls /sys/bus/rbd/devices").split()
              assert seen == mapped, (seen, mapped)
              references = shown(f"{barrier} cat /sys/module/rbd/refcnt").strip()
              assert references.isdigit() and int(references) >= len(mapped), (references, mapped)
              # It may take the platform's whole share of the shutdown.
              grace = server.succeed(
                  "kubectl -n rook-ceph get ds unmap-barrier -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}'"
              )
              assert int(grace) == groups[1]["shutdownGracePeriodSeconds"], (grace, groups)
              asked = int(server.succeed("date +%s"))
              start = time.monotonic()
              server.shutdown()
              took = time.monotonic() - start
              print(f"the poweroff took {took:.0f} seconds")
              server.start()
              server.wait_for_unit("k3s.service")
              # The boot started the server's checks and copies again.
              server.succeed("systemctl stop host-checks.timer offsite.timer")
              booted = int(server.succeed("date +%s"))

              # A single unmount that hangs on a stopped Ceph costs systemd 900 seconds here.
              assert took < 600, took
              hangs = [
                  "blocked for more than", "Mount process", "Unmounting timed out",
                  "Failed unmounting /var/lib/kubelet/", "Syncing filesystems and block devices - timed out",
                  "Delay lock is active", "Failed while waiting for all the volumes",
                  # An OSD closing an idle connection is logged in state OPEN, and does no harm.
                  "libceph: .*(error|failed|socket closed \\(con state (PREOPEN|V[12]_))",
              ]
              since = f"journalctl -b -1 --since @{asked} -o cat --no-pager"
              hung = shown(f"{since} | grep -E {shlex.quote('|'.join(hangs))}")
              assert not hung.strip(), hung
              # The kubelet stopped every group, and let the poweroff go before logind would have.
              state = json.loads(server.succeed("cat /var/lib/kubelet/graceful_node_shutdown_state"))
              began, ended = moment(state["startTime"]).timestamp(), moment(state["endTime"]).timestamp()
              most = ${toString nodes.server.services.logind.settings.Login.InhibitDelayMaxSec}
              assert asked <= began <= ended <= began + most, (asked, state)
              # Every volume mapped then was written back and unmounted while Ceph still ran.
              for n in mapped:
                  server.succeed(f"{since} -k | grep -qF 'EXT4-fs (rbd{n}): unmounting filesystem'")

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
              # hello's new pod reads what it wrote last.
              server.wait_until_succeeds(f"kubectl -n {ns} exec deploy/hello -- true", timeout=600)
              unsynced = shown(f"kubectl -n {ns} exec deploy/hello -- cat /data/unsynced").strip()
              assert unsynced == token, (unsynced, token)

              # PostgreSQL's new instance pod starts from a clean shutdown, with no recovery to run.
              def restarted(_):
                  status, out = server.execute(
                      f"kubectl -n {pg} get pod {primary} -o jsonpath="
                      """'{.metadata.creationTimestamp} {.status.conditions[?(@.type=="Ready")].status}'"""
                  )
                  created, _, ready = out.strip().partition(" ")
                  return status == 0 and ready == "True" and moment(created).timestamp() >= asked

              retry(restarted, timeout_seconds=900)
              pglog = shown(f"kubectl -n {pg} logs {primary} -c postgres")
              assert "database system was shut down at" in pglog and "not properly shut down" not in pglog, (
                  [line for line in pglog.splitlines() if re.search("shut down|recovery|redo", line)][-40:] or pglog[-3000:]
              )
              # Their clients unmapped the volumes at the poweroff, so none left a lock to break.
              broken = shown("journalctl -b -k --no-pager | grep -E 'rbd: rbd[0-9]+: breaking (header|object map) lock'")
              assert not broken.strip(), broken

          with subtest("After a reboot apps see another pseudonym, as its key lived in the gateway's memory alone"):
              forge.wait_until_succeeds(f"{fetch(here)} -o /dev/null", timeout=600)
              forge_after = pseudonym(forge, here)
              print(f"forge is {forge_after} to {here} after the reboot, {forge_here} before")
              assert forge_after != forge_here, "the key outlived the reboot"

          with subtest("Devices that ran on while the server rebooted come back to the mesh without a new sign-in, and take its changes"):
              server.wait_until_succeeds(
                  f"kubectl -n {nb_ns} wait deployment netbird-management --for=condition=Available --timeout=0", timeout=900
              )

              def nb_rejoined(name):
                  def rejoined(_):
                      view = nb_status(name)
                      return bool(view) and view["daemonStatus"] == "Connected" and view["management"]["connected"] and (
                          view["signal"]["connected"]
                      ) and any(r["uri"] == f"rels://{nb_host}:443" and r["available"] for r in view["relays"]["details"] or [])

                  return rejoined

              # The phone's person left before.
              for name in ["laptop", "home"]:
                  retry(nb_rejoined(name), timeout_seconds=600)
              nb_ids["vnc"] = nb("POST", "/api/policies", nb_vnc)["id"]
              nb_reaches("laptop", f"{nb_home['ip']}:5900", "forge:5900")
              nb("DELETE", f"/api/policies/{nb_ids['vnc']}")
              nb_refused("laptop", f"{nb_home['ip']}:5900")
              nb_reaches("laptop", f"{nb_camera}:8080", "camera:8080")
          memory()
      except Exception:
          diagnose()
          raise
    '';
}
