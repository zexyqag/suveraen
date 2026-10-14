# Renders every Flux Kustomization of every cluster under kubernetes/clusters the way Flux would, offline: the
# cluster's settings, a stand-in for each of its secrets (their names are readable even when encrypted), and
# strict substitution. Then checks the rules Flux itself wouldn't catch, on what was rendered rather than on what
# a file says: who each Kustomization and HelmRelease acts as, that apps create nothing cluster-wide and can't widen
# who may act in their namespace, that only the gateway may publish ports and no namespace leaves the restricted
# Pod Security default, and that nothing comes from a remote base.
{ pkgs, kubernetes }:
pkgs.runCommand "render"
  {
    nativeBuildInputs = [
      pkgs.fluxcd
      pkgs.yq-go
    ];
  }
  ''
    set -euo pipefail
    export HOME=$TMPDIR
    fail() { echo "$*" >&2; exit 1; }
    cp -r --no-preserve=mode ${kubernetes} kubernetes
    # Selects Flux Kustomizations, not kustomize's own files of the same kind.
    fluxks='.apiVersion == "kustomize.toolkit.fluxcd.io/v1" and .kind == "Kustomization"'

    for ks in $(find kubernetes/platform kubernetes/apps -name ks.yaml | sort); do
      # The root Kustomization, made by Nix, substitutes nothing.
      ! grep -q '[$][{]' "$ks" || fail "$ks: ks.yaml files can't use variables"
      ! yq -e 'select(.spec | (has("serviceAccountName") or has("sourceRef") or has("interval") or has("retryInterval")
        or has("timeout") or has("prune") or has("wait") or has("healthChecks") or has("healthCheckExprs")
        or has("decryption") or (.postBuild // {} | has("substituteFrom"))))' "$ks" >/dev/null 2>&1 \
        || fail "$ks sets a field components/defaults owns"
    done
    for ks in kubernetes/apps/*/ks.yaml; do
      # One name: the app's Kustomization, its namespace and APP, from which the components name everything else.
      yq -e '.spec.targetNamespace == .metadata.name and .spec.postBuild.substitute.APP == .metadata.name' "$ks" >/dev/null \
        || fail "$ks: an app's Kustomization, targetNamespace and APP must have the same name"
    done
    ! grep -rnE '^\s*-\s*[a-z]+://' kubernetes --include=kustomization.yaml \
      || fail "kustomize resources must be files in this repository (--no-remote-bases)"
    for app in kubernetes/apps/*/; do
      grep -qxF "  - ../../apps/$(basename "$app")/ks.yaml" kubernetes/clusters/test/kustomization.yaml \
        || fail "$app isn't in the test cluster"
    done

    for dir in kubernetes/clusters/*/; do
      cluster=$(basename "$dir")
      work=$TMPDIR/$cluster
      rendered=$out/$cluster
      mkdir -p "$work" "$rendered"

      yq -n ".apiVersion = \"kustomize.toolkit.fluxcd.io/v1\" | .kind = \"Kustomization\"
        | .metadata = {\"name\": \"cluster\", \"namespace\": \"flux-system\"} | .spec.path = \"./$dir\"" > "$work/root.yaml"
      flux build kustomization cluster --path "$dir" --kustomization-file "$work/root.yaml" --dry-run > "$rendered/cluster.yaml"

      yq ea '[select(.kind == "ConfigMap" and .metadata.name == "cluster-settings")] | .[0].data // {}' \
        "$rendered/cluster.yaml" > "$work/settings.yaml"
      yq ea '[select(.kind == "Secret" and .metadata.name == "cluster-secrets")]
        | (.[0].stringData // .[0].data // {}) | with_entries(.value = "stand-in")' "$rendered/cluster.yaml" > "$work/secrets.yaml"
      yq ea '. as $item ireduce ({}; . * $item)' "$work/settings.yaml" "$work/secrets.yaml" > "$work/vars.yaml"
      yq 'keys | sort | .[]' "$work/vars.yaml" > "$work/keys"

      # flux build --dry-run skips substituteFrom; inline values take precedence over it in Flux anyway.
      for name in $(yq ea "[select($fluxks) | .metadata.name] | .[]" "$rendered/cluster.yaml"); do
        yq ea "select($fluxks and .metadata.name == \"$name\")
          | .spec.postBuild.substitute = (load(\"$work/vars.yaml\") * (.spec.postBuild.substitute // {}))
          | del(.spec.postBuild.substituteFrom)" "$rendered/cluster.yaml" > "$work/$name.ks.yaml"
        path=$(yq '.spec.path' "$work/$name.ks.yaml")
        flux build kustomization "$name" --path "$path" --kustomization-file "$work/$name.ks.yaml" \
          --dry-run --strict-substitute > "$rendered/$name.yaml" || fail "$cluster/$name doesn't render"
        echo "$name $path" >> "$work/paths"
      done

      # Every Flux Kustomization, also those another one creates, acts as Flux's own account, in flux-system.
      bad=$(yq ea "[select($fluxks) | select(.spec.serviceAccountName != \"kustomize-controller\"
        or .metadata.namespace != \"flux-system\" or (.spec.sourceRef | has(\"namespace\"))
        or ((.spec.dependsOn // []) | any_c(has(\"namespace\")))) | .metadata.name] | .[]" "$rendered"/*.yaml)
      [ -z "$bad" ] || fail "$cluster: Kustomizations that don't follow the lockdown: $bad"
      known=$(yq ea "[select($fluxks) | .metadata.name] | .[]" "$rendered"/*.yaml)
      for dep in $(yq ea "[select($fluxks) | .spec.dependsOn[]?.name] | .[]" "$rendered"/*.yaml | sort -u); do
        grep -qxF "$dep" <<< "$known" || fail "$cluster: nothing is named $dep, which a Kustomization depends on"
      done

      while read -r name path; do
        file=$rendered/$name.yaml
        case $path in
          ./kubernetes/platform/*)
            # Operator charts install cluster-wide objects: they run as helm-controller, from flux-system.
            bad=$(yq ea '[select(.kind == "HelmRelease") | select(.metadata.namespace != "flux-system"
              or .spec.serviceAccountName != "helm-controller") | .metadata.name] | .[]' "$file")
            [ -z "$bad" ] || fail "$cluster/$name: platform HelmReleases must run as helm-controller from flux-system: $bad"
            ;;
          ./kubernetes/apps/*)
            bad=$(yq ea '[select(.kind == "HelmRelease") | select(.metadata.namespace == "flux-system"
              or .spec.serviceAccountName != "flux-deployer" or .spec.install.crds != "Skip" or .spec.upgrade.crds != "Skip"
              or (.spec | has("targetNamespace") or has("storageNamespace"))) | .metadata.name] | .[]' "$file")
            [ -z "$bad" ] || fail "$cluster/$name: app HelmReleases must run as flux-deployer in the app's namespace: $bad"
            bad=$(yq ea '[select(.kind != null and .kind != "Namespace" and (.metadata.namespace // "") == "") | .kind + "/" + .metadata.name] | .[]' "$file")
            [ -z "$bad" ] || fail "$cluster/$name: apps can't create cluster-wide objects: $bad"
            bad=$(yq ea '[select(.kind == "Namespace") | select(.metadata.labels."suveraen/tier" != "app")] | length' "$file")
            [ "$bad" = 0 ] || fail "$cluster/$name: an app's namespace must be labelled suveraen/tier=app"
            bad=$(yq ea '[select(.kind == "RoleBinding") | .metadata.namespace as $ns | select(
              (.roleRef.kind == "ClusterRole" and .roleRef.name != "flux-app")
              or ((.subjects // []) | any_c(.kind != "ServiceAccount" or ((.namespace // "") != "" and .namespace != $ns))))
              | .metadata.name] | .[]' "$file")
            [ -z "$bad" ] || fail "$cluster/$name: app role bindings may only give flux-app or the app's own roles to its own accounts: $bad"
            ;;
          *) fail "$cluster/$name: Kustomizations apply kubernetes/platform or kubernetes/apps, not $path" ;;
        esac
        bad=$(yq ea '[select(.kind == "Namespace") | select(.metadata.labels // {} | keys | any_c(test("^pod-security.kubernetes.io/")))
          | .metadata.name] | .[]' "$file")
        [ -z "$bad" ] || fail "$cluster/$name: namespaces keep the cluster's restricted Pod Security default: $bad"
        if [ "$name" != gateway ]; then
          bad=$(yq ea '[select(.kind == "Namespace" and .metadata.labels."suveraen/publish" == "true") | .metadata.name] | .[]' "$file")
          [ -z "$bad" ] || fail "$cluster/$name: only the gateway may publish ports: $bad"
        fi
      done < "$work/paths"
    done

    # Every cluster sets the same settings and secrets, so none is forgotten in one of them.
    [ "$(for keys in "$TMPDIR"/*/keys; do sha256sum < "$keys"; done | sort -u | wc -l)" = 1 ] \
      || fail "the clusters don't set the same settings and secrets"
  ''
