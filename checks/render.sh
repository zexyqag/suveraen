# Renders every Flux Kustomization of every cluster under kubernetes/clusters the way Flux would, offline, also those
# other Kustomizations create: the cluster's, each tenant's, then the tenant's apps and hosts. Each gets the values
# its own sources hold, a stand-in for each encrypted one, and strict substitution. Then checks the rules Flux itself
# wouldn't catch, on what was rendered rather than on what a file says.
# Usage: render.sh <kubernetes directory> <output directory>
set -euo pipefail
out=$2
work=$(mktemp -d)
cp -r --no-preserve=mode "$1" "$work/kubernetes"
cd "$work"
fail() {
  echo "$*" >&2
  exit 1
}
# Flux Kustomizations, not kustomize's own files of the same kind.
fluxks='(.apiVersion == "kustomize.toolkit.fluxcd.io/v1" and .kind == "Kustomization")'
owned='(has("serviceAccountName") or has("sourceRef") or has("interval") or has("retryInterval") or has("timeout")
  or has("prune") or has("wait") or has("healthChecks") or has("healthCheckExprs") or has("decryption")
  or has("commonMetadata") or ((.postBuild // {}) | has("substituteFrom")))'
# Five characters, so <tenant>-<app> names split without a lookup and never look like a platform namespace.
tenantre='^[a-z][a-z0-9]{4}$'
namere='^[a-z][a-z0-9]{1,15}$'
tenantlike='^[a-z][a-z0-9]{4}-'
up='../../../../..'
# What an app's quota covers, each sized by its template.
quotas='QUOTA_CONFIGMAPS,QUOTA_CPU,QUOTA_EPHEMERAL_STORAGE,QUOTA_JOBS,QUOTA_MEMORY,QUOTA_PODS,QUOTA_SECRETS'
quotas+=',QUOTA_SERVICES,QUOTA_STORAGE,QUOTA_VOLUMES'
hard='count/configmaps,count/jobs.batch,count/secrets,limits.ephemeral-storage,limits.memory'
hard+=',persistentvolumeclaims,pods,requests.cpu,requests.ephemeral-storage,requests.memory,requests.storage'
hard+=',services,services.loadbalancers,services.nodeports'
export quotas hard

# A whole Kubernetes quantity in thousandths of its unit, so CPU's "m" compares too.
quantity() {
  local n=$1 f=1000
  case $n in
    *m) n=${n%m} f=1 ;;
    *Ki) n=${n%Ki} f=$((1000 * 1024)) ;;
    *Mi) n=${n%Mi} f=$((1000 * 1024 ** 2)) ;;
    *Gi) n=${n%Gi} f=$((1000 * 1024 ** 3)) ;;
    *Ti) n=${n%Ti} f=$((1000 * 1024 ** 4)) ;;
    *k) n=${n%k} f=$((1000 * 1000)) ;;
    *M) n=${n%M} f=$((1000 * 1000 ** 2)) ;;
    *G) n=${n%G} f=$((1000 * 1000 ** 3)) ;;
    *T) n=${n%T} f=$((1000 * 1000 ** 4)) ;;
  esac
  [[ $n =~ ^[0-9]+$ ]] || fail "$1 isn't a whole quantity"
  echo $((n * f))
}

for ks in $(find kubernetes/platform -name ks.yaml | sort); do
  # The root Kustomization, made by Nix, substitutes nothing.
  ! grep -q '[$][{]' "$ks" || fail "$ks: platform ks.yaml files can't use variables"
  [ "$(yq ea "[.spec | $owned] | any" "$ks")" = false ] || fail "$ks sets a field components/defaults owns"
done

# An app's templates, which tenants list: ks.yaml (the app and the hosts every tenant gets), and edge-<key>.yaml for
# each host a tenant may add.
for dir in kubernetes/apps/*/; do
  dir=${dir%/}
  app=$(basename "$dir")
  [[ $app =~ $namere ]] || fail "$dir: app names are 2 to 16 lowercase letters and digits, starting with a letter"
  [ -f "$dir/ks.yaml" ] || fail "$dir: an app's template is ks.yaml"
  knob=$(tr a-z A-Z <<<"$app")_
  export app
  for file in "$dir"/ks.yaml "$dir"/edge-*.yaml; do
    [ -e "$file" ] || continue
    # A tenant fills in its ID, and may size the app through ${<APP>_<NAME>:=<default>}.
    bad=$(grep -o '[$][{][^}]*[}]' "$file" | sort -u \
      | grep -vxE "[$][{]TENANT[}]|[$][{]$knob[A-Z0-9_]+:=[^}$]+[}]" || true)
    [ -z "$bad" ] || fail "$file: a template may use only \${TENANT} and \${$knob<NAME>:=<default>}: $bad"
    [ "$(yq ea "[($fluxks | not) or (.spec | $owned)] | any" "$file")" = false ] \
      || fail "$file holds only Flux Kustomizations, without fields components/defaults or components/tenant own"
    docs=$(yq ea '[.] | length' "$file")
    first=0
    if [ "$file" = "$dir/ks.yaml" ]; then
      first=1
      yq ea -e 'select(documentIndex == 0) | (.metadata.name == ("${TENANT}-" + strenv(app))
        and .spec.targetNamespace == .metadata.name and .spec.path == ("./kubernetes/apps/" + strenv(app) + "/app")
        and .spec.postBuild.substitute.APP == strenv(app)
        and ([.spec.postBuild.substitute | keys | .[] | select(test("^QUOTA_"))] | sort | join(","))
          == strenv(quotas))' \
        "$file" >/dev/null || fail "$file: the app is \${TENANT}-$app in its own namespace, from" \
          "./kubernetes/apps/$app/app, with APP $app and its quota: ${quotas//,/, }"
    else
      [ "$docs" = 1 ] || fail "$file holds one host"
    fi
    for ((i = first; i < docs; i++)); do
      yq ea -e "select(documentIndex == $i)"' | ((.metadata | keys | join(",")) == "name"
        and (.spec | keys | sort | join(",")) == "dependsOn,path,postBuild"
        and (.spec.path | test("^[.]/kubernetes/edge/(app|identity|apex)$"))
        and ([.spec.dependsOn[].name] | sort | join(",")) == (["${TENANT}-" + strenv(app), "gateway", "issuer"]
          | sort | join(","))
        and (.spec.postBuild | keys | join(",")) == "substitute"
        and .spec.postBuild.substitute.APP == strenv(app)
        and (.spec.postBuild.substitute.EDGE | test("^[a-z][a-z0-9]{1,15}$"))
        and .metadata.name == ("${TENANT}-" + strenv(app) + "-edge-" + .spec.postBuild.substitute.EDGE)
        and (.spec.postBuild.substitute | has("ROUTE_PORT"))
        and (.spec.postBuild.substitute | has("HOST")) == (.spec.path != "./kubernetes/edge/apex")
        and ([.spec.postBuild.substitute | keys | .[]
          | select(test("^(APP|EDGE|HOST|ROUTE_PORT|ROUTE_SERVICE|ROUTE_TARGET_PORT)$") | not)] | length) == 0)' \
        "$file" >/dev/null || fail "$file: a host is \${TENANT}-$app-edge-<EDGE> from ./kubernetes/edge/<zone>," \
          "after the app, the gateway and the issuer, with APP $app, EDGE, ROUTE_PORT, and HOST unless it is the apex"
    done
    if [ "$file" != "$dir/ks.yaml" ]; then
      key=$(yq '.spec.postBuild.substitute.EDGE' "$file")
      [ "$file" = "$dir/edge-$key.yaml" ] || fail "$file holds host $key, so it is edge-$key.yaml"
    fi
  done
done

! grep -rnE '^\s*-\s*[a-z]+://' kubernetes --include=kustomization.yaml \
  || fail "kustomize resources must be files in this repository (--no-remote-bases)"

for tenant in kubernetes/clusters/*/tenants/*/; do
  tenant=${tenant%/}
  t=$(basename "$tenant")
  cluster=$(basename "$(dirname "$(dirname "$tenant")")")
  [[ $t =~ $tenantre ]] || fail "$tenant: tenant IDs are five lowercase letters and digits, starting with a letter"
  secrets=$(cd "$tenant" && ls secrets.yaml secrets.sops.yaml 2>/dev/null || true)
  [ "$(wc -w <<<"$secrets")" = 1 ] || fail "$tenant: a tenant has one secrets.yaml or secrets.sops.yaml"
  [ "$(yq '(keys | join(",")) + " " + (.resources | join(","))' "$tenant/kustomization.yaml")" \
    = "apiVersion,kind,resources ./tenant.yaml,./$secrets" ] \
    || fail "$tenant/kustomization.yaml lists tenant.yaml and $secrets and nothing else"
  grep -qxF "  - ./tenants/$t" "kubernetes/clusters/$cluster/kustomization.yaml" || fail "$tenant isn't in its cluster"
  ! grep -q '[$][{]' "$tenant/tenant.yaml" || fail "$tenant/tenant.yaml can't use variables"
  export t tenant
  yq ea -e "[.] | (length == 1 and (.[0] | $fluxks))" "$tenant/tenant.yaml" >/dev/null \
    || fail "$tenant/tenant.yaml holds one Flux Kustomization"
  yq -e '.metadata.name == ("tenant-" + strenv(t)) and (.metadata.labels | to_entries | length) == 1
    and .metadata.labels."suveraen/tenant" == strenv(t) and (.spec | keys | sort | join(",")) == "path,postBuild"
    and .spec.path == ("./" + strenv(tenant) + "/apps") and (.spec.postBuild | keys | join(",")) == "substitute"
    and .spec.postBuild.substitute.TENANT == strenv(t)' "$tenant/tenant.yaml" >/dev/null \
    || fail "$tenant/tenant.yaml: Kustomization tenant-$t, labelled with its tenant, applies ./$tenant/apps" \
      "with TENANT=$t and its sizes"
  yq -e '.kind == "Secret" and .metadata.name == ("tenant-" + strenv(t))
    and .metadata.labels."suveraen/tenant" == strenv(t)' "$tenant/$secrets" >/dev/null \
    || fail "$tenant/$secrets holds Secret tenant-$t, labelled with its tenant"
  manifest=$tenant/apps/kustomization.yaml
  [ "$(yq '(keys | join(",")) + " " + .namespace + " " + (.components | join(","))' "$manifest")" \
    = "apiVersion,kind,namespace,resources,components flux-system $up/components/tenant" ] \
    || fail "$manifest: lists apps into flux-system with components/tenant, and nothing else"
  listed=$(yq '.resources[]' "$manifest")
  bad=$(grep -vxE "$up/apps/[a-z0-9]+/(ks|edge-[a-z0-9]+)\.yaml" <<<"$listed" || true)
  [ -z "$bad" ] || fail "$manifest: a tenant lists apps' templates: $bad"
  apps=$(grep -oE '/apps/[a-z0-9]+/ks\.yaml$' <<<"$listed" | cut -d/ -f3 || true)
  for edge in $(grep -oE '/apps/[a-z0-9]+/edge-' <<<"$listed" | cut -d/ -f3); do
    grep -qxF "$edge" <<<"$apps" || fail "$manifest: adds a host to $edge, which the tenant doesn't run"
  done
  prefixes=$(tr a-z A-Z <<<"$apps" | paste -sd'|')
  # Its only inline values: its ID, and sizes of the apps it runs.
  bad=$(yq '.spec.postBuild.substitute | keys | .[]' "$tenant/tenant.yaml" | grep -vxE "TENANT|($prefixes)_[A-Z0-9_]+" \
    || true)
  [ -z "$bad" ] || fail "$tenant/tenant.yaml: sets values for none of its apps: $bad"
done
dup=$(for tenant in kubernetes/clusters/*/tenants/*/; do basename "$tenant"; done | sort | uniq -d)
[ -z "$dup" ] || fail "a tenant lives in one cluster, its home: $dup"

: >"$work/tested"
for dir in kubernetes/clusters/*/; do
  dir=${dir%/}
  cluster=$(basename "$dir")
  w=$work/$cluster
  rendered=$out/$cluster
  mkdir -p "$w" "$rendered"
  : >"$w/paths"

  yq -n ".apiVersion = \"kustomize.toolkit.fluxcd.io/v1\" | .kind = \"Kustomization\"
    | .metadata = {\"name\": \"cluster\", \"namespace\": \"flux-system\"} | .spec.path = \"./$dir\"" >"$w/root.yaml"
  flux build kustomization cluster --path "$dir" --kustomization-file "$w/root.yaml" --dry-run >"$rendered/cluster.yaml"
  testing=$(yq ea '[select(.kind == "ConfigMap" and .metadata.name == "cluster-settings")]
    | .[0].data.TEST_CLUSTER // ""' "$rendered/cluster.yaml")
  [ "$testing" = true ] || [ "$testing" = false ] \
    || fail "$cluster: cluster-settings says whether its tenants are stand-ins, TEST_CLUSTER \"true\" or \"false\""

  # Breadth first: the cluster's Kustomizations, then those they create, as long as they come from this repository.
  yq ea "[select($fluxks and .spec.sourceRef.name == \"suveraen\") | .metadata.name] | .[]" "$rendered/cluster.yaml" \
    | sed 's/^/cluster /' >"$w/queue"
  while [ -s "$w/queue" ]; do
    read -r parent name <"$w/queue"
    sed -i 1d "$w/queue"
    [[ $name != *'$'* ]] \
      || fail "$cluster/$parent creates a Kustomization named $name: templates are listed only by tenants"
    [ ! -e "$rendered/$name.yaml" ] || fail "$cluster: two Kustomizations are named $name"
    yq ea "select($fluxks and .metadata.name == \"$name\")" "$rendered/$parent.yaml" >"$w/$name.ks.yaml"
    # Flux reads substituteFrom in order, then the inline values. A value must come from exactly one of them, so no
    # source silently shadows another.
    echo '{}' >"$w/$name.vars.yaml"
    sources=$(yq '.spec.postBuild.substituteFrom // [] | keys | .[]' "$w/$name.ks.yaml")
    for i in $sources; do
      kind=$(yq ".spec.postBuild.substituteFrom[$i].kind" "$w/$name.ks.yaml")
      ref=$(yq ".spec.postBuild.substituteFrom[$i].name" "$w/$name.ks.yaml")
      optional=$(yq ".spec.postBuild.substituteFrom[$i].optional // false" "$w/$name.ks.yaml")
      yq ea "[select(.kind == \"$kind\" and .metadata.name == \"$ref\" and .metadata.namespace == \"flux-system\")]
        | .[0] // {}" "$rendered/cluster.yaml" >"$w/src.yaml"
      if [ "$(yq 'length' "$w/src.yaml")" = 0 ]; then
        [ "$optional" = true ] \
          || fail "$cluster/$name: substituteFrom names $kind/$ref, which the cluster doesn't define"
        continue
      fi
      # Names are readable even when values are encrypted; flux build masks a Secret's as **SOPS** and drops its sops
      # key. Each stand-in differs per source and key.
      standin="(\"$ref-\" + key | downcase | sub(\"_\", \"-\"))"
      if [ "$(yq 'has("sops")' "$w/src.yaml")" = true ]; then
        yq "(.stringData // .data // {}) | with(.[]; . = $standin)" "$w/src.yaml" >"$w/src.vars.yaml"
      elif [ "$kind" = ConfigMap ]; then
        yq '.data // {}' "$w/src.yaml" >"$w/src.vars.yaml"
      else
        yq "(.stringData // {}) * ((.data // {}) | with(.[] | select(. != \"**SOPS**\"); . |= @base64d))
          | with(.[] | select(. == \"**SOPS**\"); . = $standin)" "$w/src.yaml" >"$w/src.vars.yaml"
      fi
      both=$(yq ea 'select(fileIndex == 0) as $a | select(fileIndex == 1) | keys | .[]
        | select(. as $k | $a | has($k))' \
        "$w/$name.vars.yaml" "$w/src.vars.yaml")
      [ -z "$both" ] || fail "$cluster/$name: $both comes from more than one of its sources"
      yq ea '. as $i ireduce ({}; . * $i)' "$w/$name.vars.yaml" "$w/src.vars.yaml" >"$w/merged.yaml"
      mv "$w/merged.yaml" "$w/$name.vars.yaml"
    done
    both=$(yq ".spec.postBuild.substitute // {} | keys | .[]
      | select(. as \$k | load(\"$w/$name.vars.yaml\") | has(\$k))" \
      "$w/$name.ks.yaml")
    [ -z "$both" ] || fail "$cluster/$name: $both is set inline and by one of its sources"
    yq ".spec.postBuild.substitute = (load(\"$w/$name.vars.yaml\") * (.spec.postBuild.substitute // {}))
      | del(.spec.postBuild.substituteFrom)" "$w/$name.ks.yaml" >"$w/$name.build.yaml"
    path=$(yq '.spec.path' "$w/$name.ks.yaml")
    flux build kustomization "$name" --path "$path" --kustomization-file "$w/$name.build.yaml" \
      --dry-run --strict-substitute >"$rendered/$name.yaml" || fail "$cluster/$name doesn't render"
    echo "$name $path" >>"$w/paths"
    yq ea "[select($fluxks and .spec.sourceRef.name == \"suveraen\") | .metadata.name] | .[]" "$rendered/$name.yaml" \
      | sed "s/^/$name /" >>"$w/queue"
  done

  # Every Flux Kustomization acts as Flux's own account, in flux-system, and only the root (Nix's) decrypts.
  bad=$(yq ea "[select($fluxks) | select(.spec.serviceAccountName != \"kustomize-controller\"
    or .metadata.namespace != \"flux-system\" or (.spec.sourceRef | has(\"namespace\")) or (.spec | has(\"decryption\"))
    or ((.spec.dependsOn // []) | any_c(has(\"namespace\")))) | .metadata.name] | .[]" "$rendered"/*.yaml)
  [ -z "$bad" ] || fail "$cluster: Kustomizations that don't follow the lockdown: $bad"
  bad=$(yq ea "[select($fluxks) | .metadata.name as \$n | (.spec.postBuild.substitute // {}) | to_entries | .[]
    | select((.value | tag) != \"!!str\") | \$n + \"/\" + .key] | .[]" "$rendered"/*.yaml)
  [ -z "$bad" ] || fail "$cluster: Flux takes only strings as values to substitute: $bad"
  # Nix names the root Kustomization "cluster".
  known=$(printf 'cluster\n'; yq ea "[select($fluxks) | .metadata.name] | .[]" "$rendered"/*.yaml)
  dup=$(sort <<<"$known" | uniq -d)
  [ -z "$dup" ] || fail "$cluster: two Kustomizations share a name: $dup"
  deps=$(yq ea "[select($fluxks) | .spec.dependsOn[]?.name] | .[]" "$rendered"/*.yaml | sort -u)
  for dep in $deps; do
    grep -qxF "$dep" <<<"$known" || fail "$cluster: nothing is named $dep, which a Kustomization depends on"
  done
  dup=$(yq ea '[select(.kind == "Namespace") | .metadata.name] | .[]' "$rendered"/*.yaml | sort | uniq -d)
  [ -z "$dup" ] || fail "$cluster: two Kustomizations make the same namespace: $dup"
  platform=$(yq ea "[select($fluxks) | select(.metadata.labels.\"suveraen/tenant\" == null) | .metadata.name] | .[]" \
    "$rendered/cluster.yaml")
  bad=$(grep -E "$tenantlike" <<<"$platform" || true)
  [ -z "$bad" ] || fail "$cluster: platform Kustomizations can't be named like a tenant's app: $bad"

  while read -r name path; do
    file=$rendered/$name.yaml
    t=$(yq ".metadata.labels.\"suveraen/tenant\" // \"\"" "$w/$name.ks.yaml")
    export name t
    [ "$testing" = false ] || [ -z "$t" ] || echo "$cluster $name" >>"$work/tested"
    case $path in
      ./kubernetes/platform/*)
        [ -z "$t" ] || fail "$cluster/$name: tenants run apps, not the platform"
        # Operator charts install cluster-wide objects: they run as helm-controller, from flux-system.
        bad=$(yq ea '[select(.kind == "HelmRelease") | select(.metadata.namespace != "flux-system"
          or .spec.serviceAccountName != "helm-controller") | .metadata.name] | .[]' "$file")
        [ -z "$bad" ] || fail "$cluster/$name: platform HelmReleases must run as helm-controller from flux-system: $bad"
        bad=$(yq ea '[select(.kind == "Gateway" or .kind == "ListenerSet" or .kind == "ReferenceGrant"
          or .kind == "Issuer" or .kind == "HTTPRoute" or .kind == "GRPCRoute" or .kind == "TLSRoute")
          | .kind + "/" + .metadata.name] | .[]' "$file")
        [ -z "$bad" ] || fail "$cluster/$name: hosts come only from tenants' edges: $bad"
        bad=$(yq ea '[select(.kind == "Namespace") | .metadata.name] | .[]' "$file" | grep -E "$tenantlike" || true)
        [ -z "$bad" ] || fail "$cluster/$name: platform namespaces can't be named like a tenant's app: $bad"
        ;;
      "./$dir/tenants/$t/apps")
        [ "$name" = "tenant-$t" ] || fail "$cluster/$name: a tenant's Kustomization is tenant-<id>"
        bad=$(yq ea "[select(.kind != null and ($fluxks | not)) | .kind + \"/\" + .metadata.name] | .[]" "$file")
        [ -z "$bad" ] || fail "$cluster/$name: a tenant lists only its apps' Kustomizations: $bad"
        children=$(yq ea "[select($fluxks) | .metadata.name] | .[]" "$file")
        for child in $children; do
          export child
          yq ea -e "select($fluxks and .metadata.name == strenv(child))"' | ((.metadata.name
            | test("^" + strenv(t) + "-[a-z0-9]+(-edge-[a-z0-9]+)?$"))
            and .metadata.labels."suveraen/tenant" == strenv(t)
            and .spec.commonMetadata.labels."suveraen/tenant" == strenv(t)
            and .spec.postBuild.substitute.TENANT == strenv(t)
            and ([.spec.postBuild.substituteFrom[] | .kind + "/" + .name + "/" + (.optional // false | tostring)]
              | join(",")) == ("ConfigMap/cluster-settings/false,Secret/tenant-" + strenv(t) + "/false"))' \
            "$file" >/dev/null \
            || fail "$cluster/$name: $child isn't one of tenant $t's apps, labelled with it and substituting from" \
              "its sources only"
          deps=$(yq ea "select($fluxks and .metadata.name == strenv(child)) | .spec.dependsOn[]?.name" "$file")
          for dep in $deps; do
            [[ $dep == "$t-"* ]] || grep -qxF "$dep" <<<"$platform" \
              || fail "$cluster/$name: $child depends on $dep, which is neither the platform nor tenant $t's"
          done
        done
        ;;
      ./kubernetes/apps/*/app)
        app=$(basename "$(dirname "$path")")
        [ -n "$t" ] && [ "$name" = "$t-$app" ] || fail "$cluster/$name: apps run only as a tenant's <tenant>-<app>"
        bad=$(yq ea '[select(.kind == "HelmRelease") | select(.metadata.namespace == "flux-system"
          or .spec.serviceAccountName != "flux-deployer" or .spec.install.crds != "Skip" or .spec.upgrade.crds != "Skip"
          or (.spec | has("targetNamespace") or has("storageNamespace"))) | .metadata.name] | .[]' "$file")
        [ -z "$bad" ] || fail "$cluster/$name: app HelmReleases must run as flux-deployer in the app's namespace: $bad"
        bad=$(yq ea '[select(.kind != null and .kind != "Namespace" and .metadata.namespace != strenv(name))
          | .kind + "/" + .metadata.name] | .[]' "$file")
        [ -z "$bad" ] || fail "$cluster/$name: apps create only objects in their own namespace: $bad"
        yq ea -e '[select(.kind == "Namespace")] | (length == 1 and .[0].metadata.name == strenv(name)
          and .[0].metadata.labels."suveraen/tier" == "app" and .[0].metadata.labels."suveraen/tenant" == strenv(t))' \
          "$file" >/dev/null \
          || fail "$cluster/$name: an app's namespace is $name, labelled suveraen/tier=app and suveraen/tenant=$t"
        bad=$(yq ea '[select(.kind == "RoleBinding") | .metadata.namespace as $ns | select(
          (.roleRef.kind == "ClusterRole" and .roleRef.name != "flux-app")
          or ((.subjects // []) | any_c(.kind != "ServiceAccount" or ((.namespace // "") != "" and .namespace != $ns))))
          | .metadata.name] | .[]' "$file")
        [ -z "$bad" ] || fail "$cluster/$name: app role bindings may only give flux-app or the app's own roles to its" \
          "own accounts: $bad"
        bad=$(yq ea '[select(.kind == "Gateway" or .kind == "ListenerSet" or .kind == "ReferenceGrant"
          or .kind == "Certificate" or .kind == "Issuer") | .kind + "/" + .metadata.name] | .[]' "$file")
        [ -z "$bad" ] || fail "$cluster/$name: an app's hosts and certificates come from its edges: $bad"
        yq ea -e '[select(.kind == "NetworkPolicy" and .metadata.name == "default-deny")] | (length == 1
          and (.[0].spec.podSelector | length) == 0 and (.[0].spec.policyTypes | sort | join(",")) == "Egress,Ingress"
          and (.[0].spec | (has("ingress") or has("egress")) | not))' "$file" >/dev/null \
          || fail "$cluster/$name: an app's namespace is closed in both directions by default"
        yq ea -e '[select(.kind == "ResourceQuota")] | (length == 1 and .[0].metadata.name == "app"
          and (.[0].spec.hard | keys | sort | join(",")) == strenv(hard)
          and .[0].spec.hard."services.loadbalancers" == "0" and .[0].spec.hard."services.nodeports" == "0")' \
          "$file" >/dev/null \
          || fail "$cluster/$name: an app's namespace has one ResourceQuota, app, on ${hard//,/, }, and publishes nothing"
        [ "$(yq ea '[select(.kind == "LimitRange")] | (length == 1 and .[0].metadata.name == "defaults"
          and ([.[0].spec.limits[] | select(.type == "Container")] | length) == 1)' "$file")" = true ] \
          || fail "$cluster/$name: an app's namespace has one LimitRange, defaults, with defaults for containers"
        # Containers a chart leaves without requests or limits get the defaults, which the quota must allow.
        for pair in default.memory:limits.memory default.ephemeral-storage:limits.ephemeral-storage \
          defaultRequest.cpu:requests.cpu defaultRequest.memory:requests.memory \
          defaultRequest.ephemeral-storage:requests.ephemeral-storage; do
          field=${pair%%:*}
          limit=$(yq ea "[select(.kind == \"LimitRange\") | .spec.limits[] | select(.type == \"Container\")]
            | .[0].${field%%.*}.\"${field#*.}\" // \"\"" "$file")
          quota=$(yq ea "[select(.kind == \"ResourceQuota\")] | .[0].spec.hard.\"${pair#*:}\"" "$file")
          [ -n "$limit" ] || fail "$cluster/$name: the LimitRange sets $field for containers, which the quota needs"
          [ "$(quantity "$limit")" -le "$(quantity "$quota")" ] \
            || fail "$cluster/$name: the LimitRange's $field, $limit, is above the quota's ${pair#*:}, $quota"
        done
        ;;
      ./kubernetes/edge/app | ./kubernetes/edge/identity | ./kubernetes/edge/apex)
        [[ $name =~ ^$t-([a-z0-9]+)-edge-([a-z0-9]+)$ ]] && [ -n "$t" ] \
          || fail "$cluster/$name: a host is <tenant>-<app>-edge-<key>, one of its tenant's"
        app=${BASH_REMATCH[1]}
        key=${BASH_REMATCH[2]}
        base=$t-$app-$key
        export app base key
        grep -qxF "$t-$app" <<<"$known" || fail "$cluster/$name: a host belongs to an app its tenant runs, $t-$app"
        case ${path##*/} in
          app) host='.HOST + "." + .TENANT_APP_DOMAIN' ;;
          identity) host='.HOST + "." + .TENANT_DOMAIN' ;;
          apex) host='.TENANT_DOMAIN' ;;
        esac
        host=$(yq ".spec.postBuild.substitute | $host" "$w/$name.build.yaml")
        export host
        objects="Certificate/gateway/$base/$t,Gateway/gateway/$base/$t,HTTPRoute/$t-$app/$key/$t"
        objects+=",NetworkPolicy/$t-$app/from-gateway-$key/$t"
        [ "$(yq ea '[select(.kind != null) | .kind + "/" + .metadata.namespace + "/" + .metadata.name + "/"
          + .metadata.labels."suveraen/tenant"] | sort | join(",")' "$file")" = "$objects" ] \
          || fail "$cluster/$name: a host is Gateway and Certificate $base in gateway, and HTTPRoute $key and" \
            "NetworkPolicy from-gateway-$key in $t-$app, all labelled with tenant $t"
        yq ea -e '[select(.kind != null)] | (.[] | select(.kind == "Gateway")) as $g
          | (.[] | select(.kind == "Certificate")) as $c | $g.spec.listeners as $l
          | (($g.spec | keys | sort | join(",")) == "gatewayClassName,listeners"
          and $g.spec.gatewayClassName == "traefik"
          and ($l | length) == 1 and $l[0].name == "https" and $l[0].protocol == "HTTPS" and $l[0].port == 8443
          and $l[0].hostname == strenv(host) and $l[0].tls.mode == "Terminate"
          and ($l[0].tls.certificateRefs | length) == 1 and $l[0].tls.certificateRefs[0].name == (strenv(base) + "-tls")
          and ($l[0].tls.certificateRefs[0] | keys | join(",")) == "name"
          and ([$l[0].allowedRoutes.kinds[].kind] | join(",")) == "HTTPRoute"
          and $l[0].allowedRoutes.namespaces.from == "Selector"
          and ($l[0].allowedRoutes.namespaces.selector | keys | join(",")) == "matchLabels"
          and ($l[0].allowedRoutes.namespaces.selector.matchLabels | to_entries | length) == 1
          and $l[0].allowedRoutes.namespaces.selector.matchLabels."kubernetes.io/metadata.name" == (strenv(t) + "-"
            + strenv(app))
          and ($c.spec | keys | sort | join(",")) == "dnsNames,issuerRef,privateKey,secretName,secretTemplate"
          and $c.spec.secretName == (strenv(base) + "-tls")
          and ($c.spec.secretTemplate | keys | join(",")) == "labels"
          and ($c.spec.secretTemplate.labels | to_entries | length) == 1
          and $c.spec.secretTemplate.labels."suveraen/tenant" == strenv(t)
          and ($c.spec.dnsNames | join(",")) == strenv(host)
          and $c.spec.issuerRef.kind == "ClusterIssuer" and $c.spec.issuerRef.name == "public")' "$file" >/dev/null \
          || fail "$cluster/$name: a host's listener names $host alone and admits routes from $t-$app only, and its" \
            "certificate names $host alone, from the public issuer, into a Secret labelled with tenant $t"
        ;;
      *) fail "$cluster/$name: Kustomizations apply kubernetes/platform, a tenant, an app or a host, not $path" ;;
    esac
    case $path in
      ./kubernetes/apps/* | ./kubernetes/edge/*)
        # A rule without peers, or with an empty one, reaches every pod and address there is, both ways.
        bad=$(yq ea '[select(.kind == "NetworkPolicy")
          | select([((.spec.ingress // [])[] | (.from // [])), ((.spec.egress // [])[] | (.to // []))]
            | any_c(length == 0 or any_c((keys | length) == 0))) | .metadata.name] | .[]' "$file")
        [ -z "$bad" ] || fail "$cluster/$name: a network policy rule without peers reaches everything: $bad"
        # Other namespaces are reached only when named: a platform piece, or the same tenant's apps.
        bad=$(yq ea '[select(.kind == "NetworkPolicy") | .metadata.name as $np
          | [.spec.ingress[]?.from[]?, .spec.egress[]?.to[]?] | .[]
          | {"np": $np, "ipblock": has("ipBlock"), "selector": has("namespaceSelector"),
            "expressions": ((.namespaceSelector // {}) | has("matchExpressions")),
            "labels": ((.namespaceSelector.matchLabels // {}) | to_entries | length),
            "name": (.namespaceSelector.matchLabels."kubernetes.io/metadata.name" // ""),
            "tenant": (.namespaceSelector.matchLabels."suveraen/tenant" // "")}]
          | map(select(.ipblock or (.selector and (.expressions or (.tenant != strenv(t) and (.labels != 1
            or (.name != "kube-system" and .name != "gateway" and (.name | test("^" + strenv(t) + "-") | not))))))))
          | map(.np) | unique | .[]' "$file")
        [ -z "$bad" ] || fail "$cluster/$name: network policies reach only named platform namespaces and tenant $t's" \
          "own: $bad"
        ;;
    esac
    bad=$(yq ea '[select(.kind == "Namespace")
      | select(.metadata.labels // {} | keys | any_c(test("^pod-security.kubernetes.io/"))) | .metadata.name] | .[]' \
      "$file")
    [ -z "$bad" ] || fail "$cluster/$name: namespaces keep the cluster's restricted Pod Security default: $bad"
    bad=$(yq ea '[select((.kind == "OCIRepository" and .spec.ref.digest == null)
      or (.kind == "GitRepository" and .spec.ref.commit == null)) | .metadata.name] | .[]' "$file")
    [ -z "$bad" ] || fail "$cluster/$name: sources must be pinned to a digest or a commit: $bad"
    if [ "$name" != gateway ]; then
      bad=$(yq ea '[select(.kind == "Namespace" and .metadata.labels."suveraen/publish" == "true") | .metadata.name]
        | .[]' "$file")
      [ -z "$bad" ] || fail "$cluster/$name: only the gateway may publish ports: $bad"
    fi
  done <"$w/paths"

  # Each name has one listener, and every route asks a listener that admits its namespace for exactly its name.
  yq ea '[select(.kind == "Gateway") | .metadata.name + " " + .metadata.labels."suveraen/tenant" + " "
    + .spec.listeners[0].hostname + " "
    + .spec.listeners[0].allowedRoutes.namespaces.selector.matchLabels."kubernetes.io/metadata.name"] | .[]' \
    "$rendered"/*.yaml >"$w/listeners"
  dup=$(cut -d' ' -f3 "$w/listeners" | sort | uniq -d)
  [ -z "$dup" ] || fail "$cluster: two listeners claim the same host: $dup"
  bad=$(yq ea '[select(.kind == "HTTPRoute" and ((.spec.parentRefs // []) | length) == 0) | .metadata.name] | .[]' \
    "$rendered"/*.yaml)
  [ -z "$bad" ] || fail "$cluster: routes attach to a host's listener: $bad"
  yq ea '[select(.kind == "HTTPRoute") | .metadata.namespace + " " + .metadata.name + " "
    + ((.spec.hostnames // []) | join(",")) as $route | .spec.parentRefs[]
    | $route + " " + (.namespace // "") + "/" + (.sectionName // "") + "/" + .name] | .[]' \
    "$rendered"/*.yaml >"$w/routes"
  while read -r ns route hosts parent; do
    [[ $parent == gateway/https/* ]] || fail "$cluster: route $ns/$route attaches to $parent, not a host's listener"
    grep -qxF "${parent#gateway/https/} ${ns:0:5} $hosts $ns" "$w/listeners" \
      || fail "$cluster: route $ns/$route asks ${parent#gateway/https/} for $hosts, which isn't its listener's host" \
        "for routes from $ns"
  done <"$w/routes"
  # The hostnames policy refuses every host without the map; where it is readable, its owners must match too.
  yq ea -e '[select(.kind == "ConfigMap" and .metadata.name == "hostnames" and .metadata.namespace == "flux-system")]
    | length == 1' "$rendered/cluster.yaml" >/dev/null \
    || fail "$cluster: the cluster has no hostname map, ConfigMap hostnames"
  yq ea '[select(.kind == "ConfigMap" and .metadata.name == "hostnames")] | .[0]' "$rendered/cluster.yaml" \
    >"$w/hostnames.yaml"
  if [ "$(yq 'has("sops")' "$w/hostnames.yaml")" = false ]; then
    [ "$testing" = true ] || fail "$cluster: the hostname map links domains to tenants, so it is encrypted"
    bad=$(yq '.data // {} | to_entries | .[] | select(.value | test("^[a-z][a-z0-9]{4}(-[a-z][a-z0-9]{1,15})?$") | not)
      | .key' "$w/hostnames.yaml")
    [ -z "$bad" ] || fail "$cluster: the hostname map gives each name to a tenant or one of its namespaces: $bad"
    domains=$(yq '.data // {} | keys | .[]' "$w/hostnames.yaml")
    while read -r _ owner host admitted; do
      best=
      for k in $domains; do
        if [[ $host == "$k" || $host == *".$k" ]] && [ ${#k} -gt ${#best} ]; then best=$k; fi
      done
      value=
      [ -z "$best" ] || value=$(yq ".data.\"$best\"" "$w/hostnames.yaml")
      [ "$value" = "$owner" ] || [ "$value" = "$admitted" ] \
        || fail "$cluster: $admitted serves $host, but the hostname map gives it to ${value:-nobody}"
    done <"$w/listeners"
  fi
  if [ "$testing" = false ]; then
    # A tenant's secret holds its domains and keys, which tie it to a customer or a person.
    bad=$(yq ea '[select(.kind == "Secret" and (.metadata.name | test("^tenant-")))
      | select((.stringData // {}) * (.data // {}) | to_entries | any_c(.value != "**SOPS**")) | .metadata.name]
      | .[]' \
      "$rendered/cluster.yaml")
    [ -z "$bad" ] || fail "$cluster: tenant secrets are encrypted in every value: $bad"
  fi

  yq ea '[select(.kind == "ConfigMap" and .metadata.name == "cluster-settings")] | .[0].data // {} | keys | .[]' \
    "$rendered/cluster.yaml" >"$w/keys"
  yq ea '[select(.kind == "Secret" and .metadata.name == "cluster-secrets")]
    | (.[0].stringData // .[0].data // {}) | keys | .[]' "$rendered/cluster.yaml" >>"$w/keys"
done

# Every cluster sets the same settings and secrets, so none is forgotten in one of them.
[ "$(for keys in "$work"/*/keys; do sort "$keys" | sha256sum; done | sort -u | wc -l)" = 1 ] \
  || fail "the clusters don't set the same settings and secrets"
# A test cluster's tenants run every app and every host an app offers, at least two of them side by side.
grep -oE '^[^ ]+ tenant-' "$work/tested" | sort | uniq -c | awk '$1 >= 2 { found = 1 } END { exit !found }' \
  || fail "a test cluster runs at least two tenants, so their separation is tested"
for file in kubernetes/apps/*/ks.yaml kubernetes/apps/*/edge-*.yaml; do
  [ -e "$file" ] || continue
  for template in $(yq ea '[.metadata.name | sub("^[$][{]TENANT[}]-", "")] | .[]' "$file"); do
    grep -qE " [a-z][a-z0-9]{4}-$template$" "$work/tested" || fail "$file: no test cluster's tenant runs $template"
  done
done
