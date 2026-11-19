# Boots a server and a stand-in registry, which serves an image built here, sharing no layer with those k3s loads,
# under a name the server's mirror lists and one it doesn't. containerd's settings name the mirror alone, with no way
# past it to a registry; a pod runs the image through the mirror, which keeps it, so the pod runs again with the
# registry gone, the image's layers gone from containerd and zot restarted, which clears what a sync or an upload left;
# from the registry the mirror doesn't list nothing is pulled, though it serves the image too, not even under a path
# that begins with a listed registry's name. The mirror takes no push or delete, listens on loopback alone, where only
# root reaches it, and serves none of zot's debugging routes.
{ pkgs, module }:
let
  inherit (pkgs) lib;
  keys = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;

  listed = "registry.test";
  unlisted = "unlisted.test";
  repository = "library/busybox";

  # The stand-in's certificate, for both its names, from a CA made at build time, which the server trusts.
  tls = pkgs.runCommand "registry-tls" { nativeBuildInputs = [ pkgs.minica ]; } ''
    mkdir $out
    cd $out
    minica --domains ${listed},${unlisted}
  '';
  ca = "${tls}/minica.pem";

  # Pushed as it is laid out here, Docker's media types and all, so the test knows its digests.
  image = pkgs.dockerTools.buildImage {
    name = "busybox";
    tag = "latest";
    copyToRoot = pkgs.pkgsStatic.busybox;
    config.Cmd = [
      "sleep"
      "3600"
    ];
  };
  seed =
    pkgs.runCommand "registry-seed"
      {
        nativeBuildInputs = [
          pkgs.skopeo
          pkgs.jq
        ];
      }
      ''
        export HOME=$TMPDIR
        mkdir $out
        skopeo --insecure-policy --tmpdir $TMPDIR copy --format v2s2 --dest-compress docker-archive:${image} dir:$out/image
        manifest=$out/image/manifest.json
        jq --arg digest "sha256:$(sha256sum $manifest | cut -d ' ' -f 1)" \
          --slurpfile config $out/image/$(jq -r '.config.digest | ltrimstr("sha256:")' $manifest) \
          '{$digest, config: .config.digest, layers: [.layers[].digest], diffs: $config[0].rootfs.diff_ids}' \
          $manifest >$out/digests.json
      '';
in
pkgs.testers.runNixOSTest {
  name = "suveraen-mirror";

  nodes = {
    upstream = {
      # It takes pushes from anyone, and only the seed makes one.
      services.dockerRegistry = {
        enable = true;
        listenAddress = "0.0.0.0";
        port = 443;
        openFirewall = true;
        extraConfig.http.tls = {
          certificate = "${tls}/${listed}/cert.pem";
          key = "${tls}/${listed}/key.pem";
        };
      };
      security.pki.certificateFiles = [ ca ];
      networking.hosts."127.0.0.1" = [ listed ];

      systemd.services.registry-seed = {
        description = "Push the test's image to the registry";
        wantedBy = [ "multi-user.target" ];
        requires = [ "docker-registry.service" ];
        after = [ "docker-registry.service" ];
        path = [ pkgs.skopeo ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        # The registry may not listen yet.
        script = ''
          for _ in $(seq 30); do
            skopeo --insecure-policy copy --preserve-digests dir:${seed}/image docker://${listed}/${repository}:latest && exit 0
            sleep 2
          done
          exit 1
        '';
      };
    };

    server =
      { lib, nodes, ... }:
      {
        imports = [
          module
          ./vm-server.nix
        ];

        virtualisation = {
          memorySize = 2560;
          diskSize = 4096;
          cores = 2;
        };

        networking.hosts.${nodes.upstream.networking.primaryIPAddress} = [
          listed
          unlisted
        ];
        security.pki.certificateFiles = [ ca ];

        suveraen = {
          adminKeys = [ keys.snakeOilEd25519PublicKey ];
          source.repository = "https://example.invalid/suveraen.git";
          cluster.path = "./kubernetes/clusters/test";
          mirror.upstreams.${listed} = { };
          offsite = {
            recipients = [ keys.snakeOilEd25519PublicKey ];
            targets = lib.genAttrs [ "1" "2" ] (n: {
              endpoint = "https://s3-${n}.invalid";
              region = "us-east-1";
              bucket = "test-platform";
              credentialsFile = "/run/secrets/offsite-${n}";
            });
          };
          alerts = {
            urlFile = toString (pkgs.writeText "alerts-url" "http://127.0.0.1:9/ops");
            tokenFile = toString (pkgs.writeText "alerts-token" "unused");
          };
        };
      };
  };

  testScript =
    { nodes, ... }:
    let
      inherit (nodes.server.suveraen) mirror;
      mirrorURL = "http://127.0.0.1:${toString mirror.port}";
      mirrorDir = nodes.server.suveraen.storage.unsnapshotted.mirror.path;
    in
    ''
      import json
      import re
      import shlex

      start_all()
      # The checks and copies run when a test says.
      server.succeed("systemctl stop host-checks.timer offsite.timer")
      upstream.wait_for_unit("registry-seed.service")
      server.wait_for_unit("zot.service")
      server.wait_for_unit("k3s.service")
      server.wait_until_succeeds(
          "kubectl get node server -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep True",
          timeout=600,
      )

      seed = json.loads(server.succeed("cat ${seed}/digests.json"))
      digest = seed["digest"]
      image = f"${listed}/${repository}@{digest}"
      store = "${mirrorDir}/${listed}/${repository}"
      pod = json.dumps({
          "apiVersion": "v1",
          "kind": "Pod",
          "metadata": {"name": "mirrored"},
          "spec": {
              "terminationGracePeriodSeconds": 1,
              "securityContext": {"runAsNonRoot": True, "runAsUser": 65534, "seccompProfile": {"type": "RuntimeDefault"}},
              "containers": [{
                  "name": "busybox",
                  "image": image,
                  "securityContext": {"allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]}},
              }],
          },
      })

      with subtest("containerd's settings name the mirror alone, with no way past it to a registry"):
          hosts = "/var/lib/rancher/k3s/agent/etc/containerd/certs.d"
          found = {}
          for name in server.succeed(f"ls {hosts}").split():
              toml = server.succeed(f"cat {hosts}/{name}/hosts.toml")
              assert not re.search(r"^\s*server\s*=", toml, re.MULTILINE), (name, toml)
              found[name] = (re.findall(r'^\[host\."([^"]+)"\]', toml, re.MULTILINE), "override_path = true" in toml)
          wanted = {name: (["${mirrorURL}/v2/" + name], True) for name in ${builtins.toJSON (lib.attrNames mirror.upstreams)}}
          wanted["_default"] = (["${mirrorURL}/v2/unlisted"], True)
          assert found == wanted, found

      with subtest("A pod runs an image through the mirror, which keeps it"):
          # The account pods run as comes a little after the node.
          server.wait_until_succeeds("kubectl get serviceaccount default")
          server.succeed(f"echo {shlex.quote(pod)} | kubectl apply -f -")
          server.succeed("kubectl wait pod mirrored --for=condition=Ready --timeout=300s")
          for blob in [digest, seed["config"], *seed["layers"]]:
              server.succeed(f"test -s {store}/blobs/sha256/{blob.removeprefix('sha256:')}")

      with subtest("From a registry the mirror doesn't list nothing is pulled, though it serves the image, nor under a path that begins with a listed registry's name"):
          for name in ["${unlisted}/${repository}", "${unlisted}/${listed}/${repository}"]:
              out = server.fail(f"k3s crictl pull {name}@{digest} 2>&1")
              assert "not found" in out, out
          server.succeed(
              "curl -fsS -o /dev/null -H 'Accept: application/vnd.docker.distribution.manifest.v2+json'"
              f" https://${unlisted}/v2/${repository}/manifests/{digest}"
          )
          server.succeed("test ! -e ${mirrorDir}/${unlisted} && test ! -e ${mirrorDir}/unlisted && test ! -e ${mirrorDir}/library")

      with subtest("The pod runs again with its registry gone, its layers gone from containerd and zot restarted, which clears what a sync or an upload left"):
          upstream.succeed("systemctl stop docker-registry")
          server.fail("curl -sS -m 5 https://${listed}/v2/")
          server.succeed("kubectl delete pod mirrored --wait --timeout=120s")
          # Its containers hold the image's layers as their own, and go with its sandbox.
          server.succeed(
              "for sandbox in $(k3s crictl pods -q --label io.kubernetes.pod.name=mirrored); do k3s crictl rmp -f $sandbox; done"
          )
          server.succeed(f"k3s crictl rmi {image}")
          content = "/var/lib/rancher/k3s/agent/containerd/io.containerd.content.v1.content/blobs/sha256"
          for layer in seed["layers"]:
              server.wait_until_succeeds(f"test ! -e {content}/{layer.removeprefix('sha256:')}", timeout=60)
          # Its one layer's chain ID is its diff ID.
          server.wait_until_succeeds(
              f"snapshots=$(k3s ctr -n k8s.io snapshots ls) && ! grep -qF {seed['diffs'][0]} <<<\"$snapshots\"", timeout=60
          )
          server.succeed(
              f"runuser -u mirror -- mkdir -p {store}/.sync/left {store}/.uploads"
              f" && runuser -u mirror -- touch {store}/.uploads/left"
          )
          server.succeed("systemctl restart zot")
          server.succeed(f"test ! -e {store}/.sync && test ! -e {store}/.uploads")
          server.succeed(f"echo {shlex.quote(pod)} | kubectl apply -f -")
          server.succeed("kubectl wait pod mirrored --for=condition=Ready --timeout=300s")

      with subtest("The mirror takes no push or delete"):
          for method, path in [("POST", "blobs/uploads/"), ("DELETE", f"manifests/{digest}")]:
              code = server.succeed(
                  f"curl -s -o /dev/null -w '%{{http_code}}' -X {method} ${mirrorURL}/v2/${listed}/${repository}/{path}"
              )
              assert code == "401", (method, path, code)

      with subtest("The mirror listens on loopback alone"):
          pid = server.succeed("systemctl show -p MainPID --value zot").strip()
          listening = [line.split()[4] for line in server.succeed("ss -Htulnp").splitlines() if f"pid={pid}," in line]
          assert listening == ["127.0.0.1:${toString mirror.port}"], listening

      with subtest("On the host only root reaches the mirror: anyone else's connection is reset"):
          server.succeed("curl -fsS -o /dev/null ${mirrorURL}/v2/")
          # 7 is curl's for a connection refused, 28 for one that timed out.
          server.succeed("code=0; runuser -u nobody -- curl -sS -m 5 -o /dev/null ${mirrorURL}/v2/ || code=$?; test $code = 7")

      with subtest("The mirror serves none of zot's debugging routes"):
          for path in [
              "/v2/_zot/pprof/heap", "/v2/_zot/pprof/profile?seconds=1", "/swagger/v2/index.html",
              "/v2/_zot/debug/graphql-playground",
          ]:
              code = server.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' '${mirrorURL}{path}'")
              assert code == "404", (path, code)
          # What no other test measures: how much of the server's memory it takes.
          print("zot", server.succeed("ps -o rss= -p $(systemctl show -p MainPID --value zot)").strip(), "KiB resident")
    '';
}
