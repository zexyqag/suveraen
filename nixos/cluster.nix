{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.suveraen.cluster;
  source = config.suveraen.source;
  snapshots = cfg.etcdSnapshots;
  snapshotDir = "/var/lib/rancher/k3s/server/db/snapshots";

  # Flux's install grants create rights on its own kinds to the built-in admin and edit roles, while its
  # controllers apply with cluster-admin rights; anyone with admin or edit in a namespace could then take over the
  # cluster. Drop those grants, and lock the controllers down so that a Flux object only gets the rights of the
  # service account it names, with no references into other namespaces or to remote bases.
  # A tenant's Kustomization can start on a new revision before the root one, cluster, gives it the release's
  # settings. Those then cut short that run's health checks, which would otherwise hold them back for up to its
  # timeout.
  fluxComponents = pkgs.runCommand "flux-components.yaml" { } ''
    ${lib.getExe pkgs.fluxcd} install --export | ${lib.getExe pkgs.yq-go} '
      (select(.kind == "ClusterRole").metadata.labels) |=
        with_entries(select(.key | test("^rbac.authorization.k8s.io/aggregate-to-") | not))
      | (select(.kind == "Deployment" and .metadata.name == "kustomize-controller").spec.template.spec.containers[0].args) +=
        ["--no-cross-namespace-refs=true", "--no-remote-bases=true", "--default-service-account=default",
         "--feature-gates=CancelHealthCheckOnNewRevision=true"]
      | (select(.kind == "Deployment" and .metadata.name == "helm-controller").spec.template.spec.containers[0].args) +=
        ["--no-cross-namespace-refs=true", "--default-service-account=default"]
      | (select(.kind == "Deployment" and .metadata.name == "notification-controller").spec.template.spec.containers[0].args) +=
        ["--no-cross-namespace-refs=true"]
      | (select(.kind == "Deployment").spec.template.spec.priorityClassName) = "platform"
    ' > $out
  '';

  # Every pod must meet the "restricted" Pod Security Standard unless the platform labels its namespace otherwise;
  # namespace admins can't change namespace labels. kube-system holds k3s's own pods.
  admissionConfig = pkgs.writeText "admission.json" (
    builtins.toJSON {
      apiVersion = "apiserver.config.k8s.io/v1";
      kind = "AdmissionConfiguration";
      plugins = [
        {
          name = "PodSecurity";
          configuration = {
            apiVersion = "pod-security.admission.config.k8s.io/v1";
            kind = "PodSecurityConfiguration";
            defaults = {
              enforce = "restricted";
              enforce-version = "latest";
              # Also flags Deployments and the like whose pods would be refused.
              warn = "restricted";
              warn-version = "latest";
            };
            exemptions.namespaces = [ "kube-system" ];
          };
        }
      ];
    }
  );

  inherit (cfg) podCIDRs serviceCIDRs;

  # Named after its keys, so a changed list replaces the Secret instead of leaving removed keys in it.
  signersSecret = "release-signers-${
    builtins.substring 0 12 (builtins.hashString "sha256" (builtins.toJSON source.keys))
  }";

  inherit (cfg.nodeServices) resolver;

  inherit (cfg) edge;
  webPorts = [
    80
    443
  ];
  limit = "limit rate over ${toString edge.rate}/second burst ${toString edge.burst} packets";

  # Blocks live in the firewall's sets alone, so they end with their timeout, a reboot or a reload of the firewall.
  block = pkgs.writeShellApplication {
    name = "suveraen-block";
    runtimeInputs = [ pkgs.nftables ];
    text = ''
      usage() {
        echo "usage: suveraen-block ADDRESS[/LENGTH] DURATION" >&2
        echo "       suveraen-block --remove ADDRESS[/LENGTH]" >&2
        echo "DURATION is in minutes, hours or days (30m, 12h, 3d), at most ${toString edge.maxBlockHours}h." >&2
        exit 2
      }
      if [ $# != 2 ]; then
        usage
      elif [ "$1" = --remove ]; then
        target=$2 duration=
      else
        target=$1 duration=$2
      fi
      address=''${target%%/*}
      # Checked here, so that nft never takes a name to look up.
      if [[ $address =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        set=blocked4 longest=32
      elif [[ $address =~ ^[0-9a-fA-F:]*:[0-9a-fA-F:]*$ ]]; then
        # The firewall counts an IPv6 client by its /64, which is what one client is given.
        set=blocked6 longest=64
      else
        usage
      fi
      length=$longest
      if [[ $target == */* ]]; then
        length=''${target#*/}
        if ! [[ $length =~ ^[1-9][0-9]?$ ]] || [ "$length" -gt "$longest" ]; then
          echo "suveraen-block: the prefix length must be 1 to $longest." >&2
          exit 2
        fi
      fi
      element="$address/$length"
      if [ -z "$duration" ]; then
        exec nft "delete element inet edge $set { $element }"
      fi
      if ! [[ $duration =~ ^([1-9][0-9]{0,5})([mhd])$ ]]; then
        usage
      fi
      n=''${BASH_REMATCH[1]}
      case ''${BASH_REMATCH[2]} in
        m) minutes=$n ;;
        h) minutes=$((n * 60)) ;;
        d) minutes=$((n * 1440)) ;;
      esac
      if [ "$minutes" -gt ${toString (edge.maxBlockHours * 60)} ]; then
        echo "suveraen-block: a block lasts at most ${toString edge.maxBlockHours}h." >&2
        exit 2
      fi
      # Added again, an element keeps the timeout it has, so it is replaced in the same transaction.
      exec nft "add element inet edge $set { $element }; delete element inet edge $set { $element };" \
        "add element inet edge $set { $element timeout ''${minutes}m }"
    '';
  };

  restore = pkgs.writeShellApplication {
    name = "suveraen-etcd-restore";
    runtimeInputs = [
      config.systemd.package
      pkgs.coreutils
      pkgs.unzip
      pkgs.gnugrep
      pkgs.gnutar
      pkgs.findutils
    ];
    text = ''
      token_file=${lib.escapeShellArg cfg.tokenFile}
      if [ $# = 2 ] && [ "$1" = --token-file ]; then
        token_file=$2
      elif [ $# != 0 ] || [ -t 0 ]; then
        echo "usage: suveraen-etcd-restore [--token-file FILE] < snapshot.zip" >&2
        exit 2
      fi
      token=$(<"$token_file")

      server=/var/lib/rancher/k3s/server
      db=$server/db
      # Not in the snapshots directory, whose files k3s lists as snapshots.
      work=$db/restore
      rm -rf "$work"
      install -d -m 0700 "$work"
      trap 'rm -rf "$work"' EXIT
      cat >"$work/snapshot.zip"
      unzip -tq "$work/snapshot.zip"
      # k3s 1.36.4 joins its snapshot directory with the path of a zip it is given, so it only unpacks zips named
      # from inside that directory.
      unzip -p "$work/snapshot.zip" >"$work/snapshot"

      systemctl stop k3s
      # A failed restore leaves the server as it found it. Before a token the snapshot wasn't made with shows, k3s has
      # written the server's credentials with that token, which a later start would refuse as newer than the
      # cluster's, and moved the database to etcd-old-<seconds> to put the snapshot in its place.
      tar -C "$server" --exclude=./db -cf "$work/server.tar" .
      started=$(date +%s)
      flagged=$([ -e "$db/reset-flag" ] && echo 1 || true)
      # k3s as its unit starts it, restoring the snapshot instead. A restore checks for the token before it reads
      # --token-file, so the token also goes in K3S_TOKEN.
      K3S_TOKEN=$token ${
        lib.replaceStrings [ "--token-file ${cfg.tokenFile}" ] [ ''--token-file "$token_file"'' ]
          config.systemd.services.k3s.serviceConfig.ExecStart
      } \
        --cluster-reset --cluster-reset-restore-path="$work/snapshot" 2>&1 | tee "$work/k3s.log" || true
      if ! grep -q "membership has been reset" "$work/k3s.log"; then
        for old in "$db"/etcd-old-*; do
          if [ -d "$old" ] && [ "''${old##*-}" -ge "$started" ]; then
            rm -rf "$db/etcd"
            mv "$old" "$db/etcd"
          fi
        done
        [ -n "$flagged" ] || rm -f "$db/reset-flag"
        find "$server" -mindepth 1 -maxdepth 1 ! -name db -exec rm -rf {} +
        tar -C "$server" -xpf "$work/server.tar"
        echo "The snapshot wasn't restored; the server is as it was, and k3s stays stopped." >&2
        exit 1
      fi
      systemctl start k3s
      echo "Restored. On each other server: stop k3s, move /var/lib/rancher/k3s/server/db/etcd aside, start k3s."
    '';
  };
in
{
  options.suveraen.cluster = {
    enable = lib.mkEnableOption "a k3s server with Flux";

    path = lib.mkOption {
      type = lib.types.str;
      example = "./kubernetes/clusters/example";
      description = "Directory in suveraen.source.repository that describes this cluster.";
    };

    nodeIP = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      example = [
        "203.0.113.10"
        "2001:db8::1"
      ];
      description = "This node's IPv4 and IPv6 address; the cluster is dual-stack.";
    };

    tokenFile = lib.mkOption {
      type = lib.types.str;
      example = "/run/secrets/k3s-token";
      description = ''
        File holding the cluster's server token, a random password (`openssl rand -hex 32`). Every etcd snapshot
        carries the cluster's CA keys and secrets key encrypted with it, so a snapshot restores only with this token
        (`suveraen-etcd-restore [--token-file FILE] < snapshot.zip`): keep a copy off the machine and apart from the
        snapshots. Change it only through `k3s token rotate`, and keep the old token for as long as snapshots made with
        it are kept.
      '';
    };

    etcdSnapshots = {
      everyHours = lib.mkOption {
        type = lib.types.ints.between 1 24;
        default = 6;
        description = ''
          How often k3s snapshots etcd, in hours. It divides 24: the schedule starts over at midnight, so the snapshots
          stay evenly spaced.
        '';
      };

      keep = lib.mkOption {
        type = lib.types.ints.positive;
        default = 8;
        description = ''
          How many snapshots k3s keeps. That many compressed snapshots must fit rpool/etcd's reservation beside the
          database.
        '';
      };
    };

    edge = {
      rate = lib.mkOption {
        type = lib.types.ints.positive;
        default = 50;
        description = ''
          New connections a second that one address, or one IPv6 /64, may open to the web ports. The firewall counts
          them in memory alone, and forgets an address a minute after its last new connection.
        '';
      };

      burst = lib.mkOption {
        type = lib.types.ints.positive;
        default = 200;
        description = "New connections one address may open at once before its rate applies.";
      };

      maxBlockHours = lib.mkOption {
        type = lib.types.ints.positive;
        default = 72;
        description = ''
          The longest `suveraen-block ADDRESS[/LENGTH] DURATION` keeps an address or prefix from the web ports.
        '';
      };
    };

    sopsAgeKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "File holding the age key Flux decrypts the repository's secrets with.";
    };

    podCIDRs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      internal = true;
      default = [
        "10.42.0.0/16"
        "fd42::/56"
      ];
      description = "The pods' address ranges, fixed when the cluster is created.";
    };

    serviceCIDRs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      internal = true;
      default = [
        "10.43.0.0/16"
        "fd43::/112"
      ];
      description = "The Services' address ranges, fixed when the cluster is created.";
    };

    nodeServices = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      internal = true;
      default = {
        resolver = "169.254.53.53";
        dnsUpdates = "169.254.53.54";
      };
      description = ''
        Link-local addresses, the same on every node, at which pods reach the node's own resolver and, on the DNS
        signer, the Knot that takes certificate challenges (dns.nix).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = source.repository != null;
        message = "suveraen.cluster needs suveraen.source.repository for Flux to follow.";
      }
      {
        assertion = lib.mod 24 snapshots.everyHours == 0;
        message = "suveraen.cluster.etcdSnapshots.everyHours must divide 24.";
      }
      {
        assertion = lib.length (lib.attrNames config.suveraen.offsite.targets) >= 2;
        message = "suveraen.cluster needs two suveraen.offsite.targets, at independent providers: the cluster's state goes to both.";
      }
    ];

    services.k3s = {
      enable = true;
      # k3s only supports upgrading one minor version at a time.
      package = pkgs.k3s_1_36;
      role = "server";
      inherit (cfg) tokenFile;
      # Embedded etcd from the start, so more servers can join later.
      clusterInit = true;
      nodeIP = lib.concatStringsSep "," cfg.nodeIP;
      # Ingress is managed through Flux like everything else, and volumes come from Ceph, which keeps three copies.
      disable = [
        "traefik"
        "local-storage"
      ];
      extraFlags = [
        # These must match on every server and can't change once the cluster exists.
        "--secrets-encryption"
        # XSalsa20-Poly1305; Kubernetes advises against the default, AES-CBC.
        "--secrets-encryption-provider=secretbox"
        "--flannel-backend=wireguard-native"
        "--flannel-ipv6-masq"
        "--cluster-cidr=${lib.concatStringsSep "," podCIDRs}"
        "--service-cidr=${lib.concatStringsSep "," serviceCIDRs}"

        # NodePorts are forwarded before the host firewall sees them; keep them off public addresses.
        "--kube-proxy-arg=nodeport-addresses=127.0.0.0/8,::1/128"
        # So would a Service's external IPs, for any address it names.
        "--kube-apiserver-arg=enable-admission-plugins+=DenyServiceExternalIPs"
        "--kube-apiserver-arg=admission-control-config-file=${admissionConfig}"
        # Without it k3s gives pods 8.8.8.8 when the host's resolver is on loopback.
        "--resolv-conf=${pkgs.writeText "resolv.conf" "nameserver ${resolver}\n"}"
        # Flux deploys everything; k3s's own chart installer would be one more way to cluster-wide rights.
        "--disable-helm-controller"

        # Snapshots of etcd, which suveraen-etcd-restore restores. The module puts flags into ExecStart as they are,
        # so the schedule's spaces are quoted for systemd.
        (utils.escapeSystemdExecArg "--etcd-snapshot-schedule-cron=0 */${toString snapshots.everyHours} * * *")
        "--etcd-snapshot-retention=${toString snapshots.keep}"
        "--etcd-snapshot-compress"
      ];
      extraKubeletConfig = {
        # A fork bomb in one pod can't use up the node's process IDs.
        podPidsLimit = 4096;
        # Pods that don't name a seccomp profile get the runtime's default filter.
        seccompDefault = true;
      };
      manifests = {
        # When the nodes run short, the platform's pods (priorityClassName platform) are scheduled ahead of tenants',
        # which get the default and may be evicted to make room.
        priority-classes.content = [
          {
            apiVersion = "scheduling.k8s.io/v1";
            kind = "PriorityClass";
            metadata.name = "platform";
            value = 100000;
            description = "The platform every tenant relies on.";
          }
          {
            apiVersion = "scheduling.k8s.io/v1";
            kind = "PriorityClass";
            metadata.name = "tenant";
            value = 1000;
            globalDefault = true;
            description = "Tenants' apps.";
          }
        ];
        flux-components.source = fluxComponents;
        flux-source.content = {
          apiVersion = "source.toolkit.fluxcd.io/v1";
          kind = "GitRepository";
          metadata = {
            name = "suveraen";
            namespace = "flux-system";
          };
          spec = {
            interval = "5m";
            url = source.repository;
            ref.branch = source.branch;
          }
          # Flux keeps the last verified commit when the head isn't signed by a signer.
          // lib.optionalAttrs (source.signers != [ ]) {
            verify = {
              mode = "HEAD";
              secretRef.name = signersSecret;
            };
          };
        };
        flux-signers = lib.mkIf (source.signers != [ ]) {
          content = {
            apiVersion = "v1";
            kind = "Secret";
            metadata = {
              name = signersSecret;
              namespace = "flux-system";
            };
            # Public keys, so the world-readable store is fine. Flux wants just "type key" per entry.
            stringData = lib.listToAttrs (
              lib.imap0 (i: k: lib.nameValuePair "signer-${toString i}.sshpub" "${k.type} ${k.key}") source.keys
            );
          };
        };
        flux-sync.content = {
          apiVersion = "kustomize.toolkit.fluxcd.io/v1";
          kind = "Kustomization";
          metadata = {
            name = "cluster";
            namespace = "flux-system";
          };
          spec = {
            interval = "10m";
            sourceRef = {
              kind = "GitRepository";
              name = "suveraen";
            };
            inherit (cfg) path;
            prune = true;
            # Flux applies the signed repository with its own cluster-wide account. The cluster directory gives every
            # Kustomization it lists the same; charts in an app's namespace get only that namespace's deployer account.
            serviceAccountName = "kustomize-controller";
          }
          // lib.optionalAttrs (cfg.sopsAgeKeyFile != null) {
            decryption = {
              provider = "sops";
              secretRef.name = "sops-age";
            };
          };
        };
      };
    };

    # An hour past when the next snapshot was due.
    suveraen.checks.files.etcd-snapshots = {
      path = snapshotDir;
      maxAge = "${toString (snapshots.everyHours + 1)}h";
    };
    suveraen.offsite.sources.etcd = {
      directory = snapshotDir;
      pattern = "*.zip";
      verify = "${lib.getExe pkgs.unzip} -tq";
      inherit (snapshots) keep everyHours;
    };

    systemd.services.flux-sops-key = lib.mkIf (cfg.sopsAgeKeyFile != null) {
      description = "Give Flux the key to the repository's secrets";
      after = [ "k3s.service" ];
      wants = [ "k3s.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ config.services.k3s.package ];
      environment.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
      serviceConfig = {
        Type = "oneshot";
        Restart = "on-failure";
        RestartSec = 10;
      };
      script = ''
        until kubectl get namespace flux-system >/dev/null 2>&1; do sleep 5; done
        kubectl -n flux-system create secret generic sops-age \
          --from-file=age.agekey=${lib.escapeShellArg cfg.sopsAgeKeyFile} \
          --dry-run=client -o yaml | kubectl apply -f -
      '';
    };

    systemd.network.netdevs."20-node-services".netdevConfig = {
      Kind = "dummy";
      Name = "node-services";
    };
    systemd.network.networks."20-node-services" = {
      matchConfig.Name = "node-services";
      address = map (a: "${a}/32") (lib.attrValues cfg.nodeServices);
      linkConfig.RequiredForOnline = "no";
    };
    services.unbound.settings.server = {
      interface = [ resolver ];
      # Host-network pods query from the resolver's own address.
      access-control = map (cidr: "${cidr} allow") (podCIDRs ++ [ "${resolver}/32" ]);
    };

    # Ceph's block devices map through the host kernel, and its OSDs open their disks with dm-crypt. The CSI plugin
    # can't load modules from NixOS's module path, so they are loaded at boot.
    boot.kernelModules = [
      "rbd"
      "dm_crypt"
    ];

    environment.systemPackages = [
      pkgs.kubectl
      restore
      block
    ];
    environment.variables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";

    # Pods may reach the API server, the kubelet and the node's resolver on the host, and on the DNS signer its Knot
    # (dns.nix); nothing else there.
    networking.firewall.extraInputRules =
      let
        v4 = lib.filter (cidr: !lib.hasInfix ":" cidr) podCIDRs;
        v6 = lib.filter (lib.hasInfix ":") podCIDRs;
        set = cidrs: "{ ${lib.concatStringsSep ", " cidrs} }";
      in
      ''
        ip saddr ${set v4} tcp dport { 6443, 10250 } accept
        ip6 saddr ${set v6} tcp dport { 6443, 10250 } accept
        ip saddr ${set v4} ip daddr ${resolver} meta l4proto { tcp, udp } th dport 53 accept
      '';
    networking.firewall.allowedTCPPorts = webPorts;

    # Ahead of kube-proxy's rules, while packets still carry the node's own address and port.
    networking.nftables.tables.edge = {
      family = "inet";
      content = ''
        set blocked4 { type ipv4_addr; flags interval, timeout; }
        set blocked6 { type ipv6_addr; flags interval, timeout; }
        set new4 { type ipv4_addr; size 65536; flags dynamic, timeout; timeout 1m; }
        set new6 { type ipv6_addr; size 65536; flags dynamic, timeout; timeout 1m; }
        chain prerouting {
          type filter hook prerouting priority dstnat - 10; policy accept;
          meta l4proto != tcp return
          fib daddr type != local return
          tcp dport != { ${lib.concatMapStringsSep ", " toString webPorts} } return
          ip saddr @blocked4 drop
          ip6 saddr @blocked6 drop
          ct state != new return
          update @new4 { ip saddr ${limit} } drop
          update @new6 { ip6 saddr & ffff:ffff:ffff:ffff:: ${limit} } drop
        }
      '';
    };
  };
}
