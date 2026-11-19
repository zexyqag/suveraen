# Every image the cluster pulls comes through the server's own mirror, Zot built with nothing but its sync: it fetches
# each from its registry the first time containerd asks for it and keeps it, on a bounded dataset of its own.
# containerd pulls from nowhere else, so an image from a registry the mirror doesn't list isn't pulled at all. It
# answers on loopback, to root alone, and takes no push or delete. The server's metrics count the images containerd
# holds that the mirror doesn't hold whole, and tell whether it answers; `suveraen-mirror missing` names those images,
# and `suveraen-mirror fill` makes them whole again while their registries serve them.
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

  # How long the mirror has to answer the writer.
  probeSeconds = 5;
  inherit (pkgs.stdenv.hostPlatform) go;
  # A child of an index is this node's as containerd picks it: of the node's OS and architecture, with no variant or
  # the one containerd takes as none.
  baseVariant =
    {
      amd64 = "v1";
      arm64 = "v8";
    }
    .${go.GOARCH} or "";
  # What the mirror holds of the images containerd pulled, read from its store: asked for, zot would fetch what it
  # lacks.
  reading = ''
    store=${dir}
    zot=http://127.0.0.1:${port}
    component='[a-z0-9]([a-z0-9-]*[a-z0-9])?'
    reference="^$component(\\.$component)*(:[0-9]+)?(/[a-z0-9]+(([._]|__|-+)[a-z0-9]+)*)+@sha256:[0-9a-f]{64}\$"
    # The images containerd pulled, by <name>@<digest>, each once; those k3s loads itself it keeps pinned.
    held() {
      crictl images -o json | jq -r '[.images[] | select(.pinned | not) | .repoDigests[]?] | unique[]'
    }
    # Where the mirror keeps a blob of a repository's.
    blob() { echo "$store/$1/blobs/sha256/''${2#sha256:}"; }
    # What a blob names, a line each: of an index, its manifest for this node's platform; of a manifest, its config
    # and its layers.
    names() {
      jq -er --arg os ${go.GOOS} --arg arch ${go.GOARCH} --arg base "${baseVariant}" '
        def checked: if type == "string" and test("^sha256:[0-9a-f]{64}$") then . else error("no digest") end;
        if has("manifests") then
          first(.manifests[] | select(.platform.os == $os and .platform.architecture == $arch
            and (.platform.variant // "" | . == "" or . == $base)))
          | "manifest \(.digest | checked)"
        else
          "blob \(.config.digest | checked)", (.layers[] | "blob \(.digest | checked)")
        end' "$1" 2>/dev/null
    }
    # The blobs the mirror serves an image to this node with, a line each, by role and digest: the image's own (top),
    # for an index its manifest for this platform (manifest), and the manifest's config and layers (blob), as far as
    # the mirror holds them with the bytes their names say. It fails unless the mirror holds every one.
    walk() {
      local name=''${1%@*} role=top digest=''${1##*@} file named whole=0
      [[ $1 =~ $reference ]] || return 1
      while :; do
        echo "$role $digest"
        file=$(blob "$name" "$digest")
        # Read only once its bytes are what its name says, so that each step names a blob no earlier one did.
        [ -f "$file" ] && [ "$(sha256sum <"$file")" = "''${digest#sha256:}  -" ] || return 1
        named=$(names "$file") || return 1
        [[ $named == "manifest "* ]] || break
        role=manifest digest=''${named#manifest }
      done
      echo "$named"
      while read -r _ digest; do
        [ -f "$(blob "$name" "$digest")" ] || whole=1
      done <<<"$named"
      return "$whole"
    }
  '';

  command = pkgs.writeShellApplication {
    name = "suveraen-mirror";
    runtimeInputs = [
      cluster.crictl
      pkgs.jq
      pkgs.curl
      pkgs.coreutils
    ];
    text = reading + ''
      missing() {
        local images image
        images=$(held) || return 1
        for image in $images; do
          walk "$image" >/dev/null || echo "$image"
        done
      }

      # Asks the mirror for a manifest by digest, which it syncs with whatever else of it it lacks, while upstream
      # serves it. zot answers once it holds all of that, which for a big image over a slow link takes minutes.
      fetch() {
        curl -fsS --max-time 1800 -o /dev/null -H "Accept: ${
          lib.concatStringsSep ", " [
            "application/vnd.oci.image.index.v1+json"
            "application/vnd.oci.image.manifest.v1+json"
            "application/vnd.docker.distribution.manifest.list.v2+json"
            "application/vnd.docker.distribution.manifest.v2+json"
          ]
        }" "$zot/v2/$1/manifests/$2" || true
      }

      # zot serves a blob it holds as it is, and syncs no manifest it holds, however little of it it has.
      repair() {
        local name=''${1%@*} walked line digest file manifest="" gap=0 absent tried=""
        # Whatever of the image it holds whose bytes don't match their name goes,
        mapfile -t walked < <(walk "$1")
        for line in "''${walked[@]}"; do
          digest=''${line#* }
          file=$(blob "$name" "$digest")
          if [ -f "$file" ] && [ "$(sha256sum <"$file")" != "''${digest#sha256:}  -" ]; then rm -f -- "$file"; fi
        done
        # and so does its manifest when its config or a layer is missing, which it then syncs again, fetching only what
        # it lacks.
        mapfile -t walked < <(walk "$1")
        for line in "''${walked[@]}"; do
          case $line in
            "blob "*) [ -f "$(blob "$name" "''${line#blob }")" ] || gap=1 ;;
            *) manifest=''${line#* } ;;
          esac
        done
        if [ "$gap" = 1 ]; then rm -f -- "$(blob "$name" "$manifest")"; fi
        # Then each index or manifest missing, the first the walk comes to, until none is or one asked for still is.
        while :; do
          absent=""
          mapfile -t walked < <(walk "$1")
          for line in "''${walked[@]}"; do
            [[ $line == "blob "* ]] || [ -f "$(blob "$name" "''${line#* }")" ] || {
              absent=''${line#* }
              break
            }
          done
          if [ -z "$absent" ] || [ "$absent" = "$tried" ]; then return 0; fi
          tried=$absent
          fetch "$name" "$absent"
        done
      }

      fill() {
        local images image left
        for image; do
          [[ $image =~ $reference ]] || {
            echo "suveraen-mirror: not <name>@sha256:<digest>: $image" >&2
            exit 2
          }
        done
        if [ $# -gt 0 ]; then images=$(printf '%s\n' "$@"); else images=$(missing); fi
        for image in $images; do repair "$image"; done
        left=$(for image in $images; do walk "$image" >/dev/null || echo "$image"; done)
        if [ -n "$left" ]; then
          echo "$left"
          exit 1
        fi
      }

      case ''${1:-} in
        missing)
          [ $# = 1 ] || {
            echo "usage: suveraen-mirror missing" >&2
            exit 2
          }
          missing
          ;;
        fill)
          shift
          fill "$@"
          ;;
        *)
          echo "usage: suveraen-mirror missing | fill [<name>@<digest>...]" >&2
          exit 2
          ;;
      esac
    '';
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

    environment.systemPackages = [ command ];

    suveraen.metrics = lib.mkIf config.suveraen.metrics.enable {
      # Of the images containerd holds: one the mirror lost that no pod here pulled since goes unseen until asked for.
      textfiles.mirror = {
        path = [
          cluster.crictl
          pkgs.jq
          pkgs.curl
        ];
        needsCluster = true;
        after = [
          "k3s.service"
          "zot.service"
        ];
        # Up to 145 seconds for the runtime to answer, and then what the writer asks it and the mirror.
        timeout = 210;
        script = reading + ''
          # Read whole first, so a runtime that can't be asked fails the writer, and its file goes stale.
          images=$(held)
          lacking=0 whole=""
          for image in $images; do
            if walk "$image" >/dev/null; then whole=''${whole:-$image}; else lacking=$((lacking + 1)); fi
          done
          # Ready, and serving an image it holds whole, from its store.
          answering=0
          probe() { curl -fsS --max-time ${toString probeSeconds} -o /dev/null "$@"; }
          if probe "$zot/readyz" \
            && { [ -z "$whole" ] || probe -I "$zot/v2/''${whole%@*}/manifests/''${whole##*@}"; }; then
            answering=1
          fi
          printf '%s\n' '# TYPE mirror_missing gauge' "mirror_missing $lacking" \
            '# TYPE mirror_answering gauge' "mirror_answering $answering"
        '';
        families = [
          "mirror_missing"
          "mirror_answering"
        ];
      };
      rules = {
        "mirror lacks images this node holds" = {
          expr = "mirror_missing > 0";
          title = "mirror lacks images this node holds";
          cleared = "mirror holds the images this node holds again";
          detail = "{{ $value }} images this node holds are not wholly in the mirror: suveraen-mirror missing names them, fill fetches them while upstream serves them";
          reads = [ "mirror_missing" ];
        };
        # New pulls fail meanwhile; what containerd holds still runs.
        "mirror not answering" = {
          expr = "mirror_answering == 0";
          title = "mirror not answering";
          cleared = "mirror answering again";
          detail = "not ready, or not serving an image it holds whole, within ${toString probeSeconds} seconds";
          reads = [ "mirror_answering" ];
        };
      };
    };
  };
}
