{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.suveraen.cluster;

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

  # Pods reach the node's own resolver at this link-local address, the same on every node.
  resolver = "169.254.53.53";
in
{
  options.suveraen.cluster = {
    enable = lib.mkEnableOption "a k3s server with Flux";

    repository = lib.mkOption {
      type = lib.types.str;
      example = "https://github.com/owner/suveraen";
      description = "Public Git repository that Flux keeps the cluster in sync with.";
    };

    branch = lib.mkOption {
      type = lib.types.str;
      default = "main";
      description = "Branch Flux follows.";
    };

    path = lib.mkOption {
      type = lib.types.str;
      example = "./clusters/example";
      description = "Directory in the repository that describes this cluster.";
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
            url = cfg.repository;
            ref.branch = cfg.branch;
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
      access-control = map (cidr: "${cidr} allow") podCIDRs;
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
