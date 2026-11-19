# Every image the cluster pulls comes through the server's own mirror, Zot built with nothing but its sync: it fetches
# each from its registry the first time containerd asks for it and keeps it, on a bounded dataset of its own.
# containerd pulls from nowhere else, so an image from a registry the mirror doesn't list isn't pulled at all. It
# answers on loopback, to root alone, and takes no push or delete.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.suveraen.mirror;
  inherit (config.suveraen) cluster;
  dir = "/var/lib/mirror";
  port = toString cfg.port;

  zot = pkgs.buildGo127Module (finalAttrs: {
    pname = "zot";
    version = "2.1.23";
    src = pkgs.fetchFromGitHub {
      owner = "project-zot";
      repo = "zot";
      tag = "v${finalAttrs.version}";
      hash = "sha256-Q21qFoZzOpJe7oJP4RSGiBvhPF9znCF2ndegsVSHQnY=";
    };
    vendorHash = "sha256-ILHn4EUCHLpwdgSj/CBlX58R1D2zJhr+H6HkcAOdhis=";
    subPackages = [ "cmd/zot" ];
    tags = [ "sync" ];
    # As upstream's release build, minus -buildmode=pie: static, no ELF interpreter.
    env = {
      CGO_ENABLED = 0;
      GOEXPERIMENT = "jsonv2";
    };
    ldflags =
      let
        buildinfo = "zotregistry.dev/zot/v2/pkg/buildinfo";
      in
      [
        "-s"
        "-w"
        "-X ${buildinfo}.ReleaseTag=v${finalAttrs.version}"
        "-X ${buildinfo}.BinaryType=-sync"
        "-X ${buildinfo}.GoVersion=go${finalAttrs.passthru.go.version}"
      ];
    # cmd/zot's only test is a smoke test that costs a second full link (about 70 s).
    doCheck = false;
    meta = {
      description = "OCI-native container registry";
      homepage = "https://zotregistry.dev";
      license = lib.licenses.asl20;
      mainProgram = "zot";
    };
  });

  # Nothing is ever collected, so an image named by digest stays even once upstream has deleted it, and Docker's
  # manifests are kept as they are, so their digests still match. warn logs lines at every start and sync that tell
  # nothing.
  settings = pkgs.writeText "zot.json" (
    builtins.toJSON {
      distSpecVersion = "1.1.1";
      storage = {
        rootDirectory = dir;
        gc = false;
        dedupe = false;
        commit = true;
      };
      http = {
        address = "127.0.0.1";
        inherit port;
        compat = [ "docker2s2" ];
        accessControl.repositories."**".anonymousPolicy = [ "read" ];
      };
      log.level = "error";
      extensions.sync = {
        enable = true;
        registries = lib.mapAttrsToList (host: upstream: {
          urls = [ upstream.url ];
          onDemand = true;
          tlsVerify = true;
          content = [
            {
              prefix = "**";
              destination = "/${host}";
            }
          ];
        }) cfg.upstreams;
      };
    }
  );
  # Checked as the server is built, not as zot starts.
  configFile = pkgs.runCommand "zot.json" { } ''
    ${lib.getExe zot} verify ${settings}
    cp ${settings} $out
  '';

  # containerd asks the mirror for a listed registry's images under the registry's name, and for any other's under
  # "unlisted", which names no registry, so those aren't pulled. At the root, an image whose path began with a listed
  # registry's name would be that registry's.
  registries = (pkgs.formats.yaml { }).generate "registries.yaml" {
    mirrors =
      lib.mapAttrs (host: _: { endpoint = [ "http://127.0.0.1:${port}/v2/${host}" ]; }) cfg.upstreams
      // {
        "*".endpoint = [ "http://127.0.0.1:${port}/v2/unlisted" ];
      };
  };
in
{
  options.suveraen.mirror = {
    upstreams = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options.url = lib.mkOption {
              type = lib.types.str;
              default = "https://${name}";
              defaultText = lib.literalExpression ''"https://''${name}"'';
              description = "Where the registry answers.";
            };
          }
        )
      );
      description = ''
        The registries the cluster's images may come from, by the name images give them; an image from any other isn't
        pulled. The platform's, docker.io, ghcr.io, quay.io and registry.k8s.io, are always listed.
      '';
    };

    quota = lib.mkOption {
      type = lib.types.str;
      default = "64G";
      description = ''
        Most space the mirror may take. It removes nothing, so once it is full no image it lacks can be pulled; the
        dataset alerts before then.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      readOnly = true;
      internal = true;
      default = 5000;
      description = "The port on 127.0.0.1 at which containerd reaches the mirror.";
    };
  };

  config = lib.mkIf cluster.enable {
    assertions = [
      {
        # ServiceLB's host ports take connections to their port on loopback too, ahead of a host daemon's.
        assertion = !lib.elem cfg.port (lib.attrValues cluster.webPorts);
        message = "The mirror's port, ${port}, is one of suveraen.cluster.webPorts, whose host ports would take containerd's connections to it.";
      }
    ];

    suveraen.mirror.upstreams = {
      # Docker Hub's registry isn't at its name.
      "docker.io".url = lib.mkDefault "https://registry-1.docker.io";
      "ghcr.io" = { };
      "quay.io" = { };
      "registry.k8s.io" = { };
    };

    users.users.mirror = {
      isSystemUser = true;
      group = "mirror";
    };
    users.groups.mirror = { };

    # It never deletes, so the snapshots of /var would keep nothing more of it.
    suveraen.storage.unsnapshotted.mirror = {
      path = dir;
      inherit (cfg) quota;
    };
    systemd.tmpfiles.rules = [ "d ${dir} 0700 mirror mirror" ];

    systemd.services.zot = {
      description = "The mirror containerd pulls images through";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "notify";
        User = "mirror";
        Group = "mirror";
        # What a sync or an upload left when zot stopped short of its end, as when killed for memory: zot itself
        # leaves .uploads for good and .sync for hours.
        ExecStartPre = "${pkgs.findutils}/bin/find ${dir} -mindepth 2 ( -name .sync -o -name .uploads ) -prune -exec ${pkgs.coreutils}/bin/rm -rf -- {} +";
        ExecStart = "${lib.getExe zot} serve ${configFile}";
        ProtectSystem = "strict";
        ReadWritePaths = [ dir ];
        PrivateTmp = true;
        PrivateDevices = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        SystemCallFilter = "@system-service";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        MemoryMax = "1G";
        Restart = "on-failure";
        TimeoutStartSec = "5min";
      };
    };

    # k3s starts without the mirror too: pods whose images containerd holds run.
    systemd.services.k3s = {
      wants = [ "zot.service" ];
      after = [ "zot.service" ];
    };
    services.k3s.extraFlags = [
      "--private-registry=${registries}"
      # Nor straight to the registry when the mirror fails.
      "--disable-default-registry-endpoint"
    ];

    # Pods have loopback of their own. On the host, only root, as containerd runs, reaches the mirror: a daemon that
    # isn't root, coturn among them, can't make it fetch.
    networking.nftables.tables.mirror = {
      family = "inet";
      content = ''
        chain output {
          type filter hook output priority filter; policy accept;
          ip daddr 127.0.0.1 tcp dport ${port} meta skuid != 0 reject with tcp reset
        }
      '';
    };

    suveraen.alerts.units = [ "zot" ];
  };
}
