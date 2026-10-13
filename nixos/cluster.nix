{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.suveraen.cluster;
  source = config.suveraen.source;

  fluxComponents = pkgs.runCommand "flux-components.yaml" { } ''
    ${lib.getExe pkgs.fluxcd} install --export > $out
  '';

  podCIDRs = [
    "10.42.0.0/16"
    "fd42::/56"
  ];
  serviceCIDRs = [
    "10.43.0.0/16"
    "fd43::/112"
  ];

  # Named after its keys, so a changed list replaces the Secret instead of leaving removed keys in it.
  signersSecret = "release-signers-${
    builtins.substring 0 12 (builtins.hashString "sha256" (builtins.toJSON source.keys))
  }";

  # Pods reach the node's own resolver at this link-local address, the same on every node.
  resolver = "169.254.53.53";
in
{
  options.suveraen.cluster = {
    enable = lib.mkEnableOption "a k3s server with Flux";

    path = lib.mkOption {
      type = lib.types.str;
      example = "./clusters/example";
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

    sopsAgeKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "File holding the age key Flux decrypts the repository's secrets with.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = source.repository != null;
        message = "suveraen.cluster needs suveraen.source.repository for Flux to follow.";
      }
    ];

    services.k3s = {
      enable = true;
      # k3s only supports upgrading one minor version at a time.
      package = pkgs.k3s_1_36;
      role = "server";
      # Embedded etcd from the start, so more servers can join later.
      clusterInit = true;
      nodeIP = lib.concatStringsSep "," cfg.nodeIP;
      # Ingress is managed through Flux like everything else.
      disable = [ "traefik" ];
      # These must match on every server and can't change once the cluster exists.
      extraFlags = [
        "--secrets-encryption"
        "--flannel-backend=wireguard-native"
        "--flannel-ipv6-masq"
        "--cluster-cidr=${lib.concatStringsSep "," podCIDRs}"
        "--service-cidr=${lib.concatStringsSep "," serviceCIDRs}"
        # NodePorts are forwarded before the host firewall sees them; keep them off public addresses.
        "--kube-proxy-arg=nodeport-addresses=127.0.0.0/8,::1/128"
        # Without it k3s gives pods 8.8.8.8 when the host's resolver is on loopback.
        "--resolv-conf=${pkgs.writeText "resolv.conf" "nameserver ${resolver}\n"}"
      ];
      manifests = {
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

    systemd.network.netdevs."20-resolver".netdevConfig = {
      Kind = "dummy";
      Name = "resolver";
    };
    systemd.network.networks."20-resolver" = {
      matchConfig.Name = "resolver";
      address = [ "${resolver}/32" ];
      linkConfig.RequiredForOnline = "no";
    };
    services.unbound.settings.server = {
      interface = [ resolver ];
      # Host-network pods query from the resolver's own address.
      access-control = map (cidr: "${cidr} allow") (podCIDRs ++ [ "${resolver}/32" ]);
    };

    # Rook mounts Ceph block devices and file systems from the host kernel.
    boot.kernelModules = [
      "rbd"
      "ceph"
    ];

    environment.systemPackages = [ pkgs.kubectl ];
    environment.variables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";

    # Pods reach the host (API server, kubelet) through these; the public side stays closed.
    networking.firewall.trustedInterfaces = [
      "cni0"
      "flannel-wg"
      "flannel-wg-v6"
    ];
    networking.firewall.allowedTCPPorts = [
      80
      443
    ];
  };
}
