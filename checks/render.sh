# Renders every Flux Kustomization of every cluster under kubernetes/clusters the way Flux would, offline, also those
# other Kustomizations create: the cluster's, each tenant's, then the tenant's apps and hosts. Each gets the values
# its own sources hold, a stand-in for each encrypted one, and strict substitution. Then checks the rules Flux itself
# wouldn't catch, on what was rendered rather than on what a file says.
# Usage: CLUSTER_RANGES=<the servers' ranges> render.sh <kubernetes directory> <output directory>
set -euo pipefail
: "${CLUSTER_RANGES:?the ranges the servers give k3s (nixos/cluster.nix), as <setting>=<range> words}"
out=$(realpath -m "$2")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
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
quotas='QUOTA_CONFIGMAPS,QUOTA_CPU,QUOTA_EPHEMERAL_STORAGE,QUOTA_JOBS,QUOTA_MEMORY,QUOTA_PODS,QUOTA_SECRETS'
quotas+=',QUOTA_SERVICES,QUOTA_STORAGE,QUOTA_VOLUMES'
hard='count/configmaps,count/jobs.batch,count/secrets,limits.ephemeral-storage,limits.memory'
hard+=',persistentvolumeclaims,pods,requests.cpu,requests.ephemeral-storage,requests.memory,requests.storage'
hard+=',services,services.loadbalancers,services.nodeports'
# kustomize gives the target namespace to every kind it doesn't know, cluster-wide ones too, so what an app may
# create is a list of namespaced kinds; certificates and issuers come only from edges and the platform.
appkinds='ConfigMap,Secret,Service,ServiceAccount,PersistentVolumeClaim,LimitRange,ResourceQuota,Namespace'
appkinds+=',Role.rbac.authorization.k8s.io,RoleBinding.rbac.authorization.k8s.io,NetworkPolicy.networking.k8s.io'
appkinds+=',OCIRepository.source.toolkit.fluxcd.io,HelmRelease.helm.toolkit.fluxcd.io'
appkinds+=',HTTPRoute.gateway.networking.k8s.io'
# Copies of an app's volume (components/volsync).
appkinds+=',ReplicationSource.volsync.backube,ReplicationDestination.volsync.backube'
# The tenant's PostgreSQL also claims its bucket, tells Barman where to archive and copies the bucket off-site.
pgkinds=',ObjectBucketClaim.objectbucket.io,ObjectStore.barmancloud.cnpg.io,CronJob.batch,Job.batch'
export quotas hard appkinds
privileged=pod-security.kubernetes.io/audit=privileged,pod-security.kubernetes.io/enforce=privileged
privileged+=,pod-security.kubernetes.io/warn=privileged

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

# A tenant's Secret holds each of its apps' own keys, <APP>_*, for that app alone.
appnames=$(for dir in kubernetes/apps/*/; do basename "$dir"; done | tr a-z A-Z)
for dir in kubernetes/apps/*/; do
  dir=${dir%/}
  app=$(basename "$dir")
  [[ $app =~ $namere ]] || fail "$dir: app names are 2 to 16 lowercase letters and digits, starting with a letter"
  [ -f "$dir/ks.yaml" ] || fail "$dir: an app's template is ks.yaml"
  knob=$(tr a-z A-Z <<<"$app")_
  export app
  others=$(grep -vxF "${knob%_}" <<<"$appnames" | paste -sd'|' || true)
  bad=$([ -z "$others" ] || grep -rhoE "[$][{]($others)_[A-Z0-9_]*" "$dir" | cut -c3- | sort -u | paste -sd' ' || true)
  [ -z "$bad" ] || fail "$dir: an app reads only its own keys, not $bad"
  for file in "$dir"/ks.yaml "$dir"/edge-*.yaml; do
    [ -e "$file" ] || continue
    bad=$(grep -o '[$][{][^}]*[}]' "$file" | sort -u \
      | grep -vxE "[$][{]TENANT[}]|[$][{]$knob[A-Z0-9_]+:=[^}$]+[}]" || true)
    [ -z "$bad" ] || fail "$file: a template may use only \${TENANT} and \${$knob<NAME>:=<default>}: $bad"
    [ "$(yq ea "[$fluxks | not] | any" "$file")" = false ] || fail "$file holds only Flux Kustomizations"
    docs=$(yq ea '[.] | length' "$file")
    first=0
    if [ "$file" = "$dir/ks.yaml" ]; then
      first=1
      # Everything else comes from components/defaults and components/tenant.
      yq ea -e 'select(documentIndex == 0) | ((.metadata | keys | join(",")) == "name"
        and ([.spec | keys | .[] | select(test("^(path|targetNamespace|components|dependsOn|postBuild)$") | not)]
          | length) == 0
        and (.spec.postBuild | keys | join(",")) == "substitute"
        and .metadata.name == ("${TENANT}-" + strenv(app))
        and .spec.targetNamespace == .metadata.name and .spec.path == ("./kubernetes/apps/" + strenv(app) + "/app")
        and .spec.postBuild.substitute.APP == strenv(app)
        and ([.spec.postBuild.substitute | keys | .[] | select(test("^QUOTA_"))] | sort | join(","))
          == strenv(quotas))' \
        "$file" >/dev/null || fail "$file: the app is \${TENANT}-$app in its own namespace, from" \
          "./kubernetes/apps/$app/app, with APP $app and its quota: ${quotas//,/, }; it sets only its name, path," \
          "targetNamespace, components, dependsOn and values to substitute"
    else
      [ "$docs" = 1 ] || fail "$file holds one host"
    fi
    for ((i = first; i < docs; i++)); do
      part=$(yq ea "select(documentIndex == $i) | .metadata.name" "$file")
      # An app's database and role in its tenant's PostgreSQL, once that runs.
      if [ "$part" = "\${TENANT}-$app-db" ]; then
        yq ea -e "select(documentIndex == $i)"' | ((.metadata | keys | join(",")) == "name"
          and (.spec | keys | sort | join(",")) == "dependsOn,path,postBuild"
          and .spec.path == ("./kubernetes/apps/" + strenv(app) + "/db")
          and ([.spec.dependsOn[].name] | join(",")) == "${TENANT}-postgres-cluster"
          and (.spec.postBuild | keys | join(",")) == "substitute"
          and (.spec.postBuild.substitute | keys | join(",")) == "APP" and .spec.postBuild.substitute.APP == strenv(app))' \
          "$file" >/dev/null || fail "$file: an app's database is \${TENANT}-$app-db from ./kubernetes/apps/$app/db," \
            "after \${TENANT}-postgres-cluster alone, with APP $app"
        continue
      fi
      # The tenant's PostgreSQL cluster, after the namespace, bucket and object store it uses.
      if [ "$app" = postgres ] && [ "$part" = "\${TENANT}-postgres-cluster" ]; then
        yq ea -e "select(documentIndex == $i)"' | ((.metadata | keys | join(",")) == "name"
          and (.spec | keys | sort | join(",")) == "components,dependsOn,path,postBuild,targetNamespace"
          and .spec.path == "./kubernetes/apps/postgres/cluster" and .spec.targetNamespace == "${TENANT}-postgres"
          and (.spec.components | length) == 1 and (.spec.components[0] | test("^[.][.]/bootstrap/"))
          and ([.spec.dependsOn[].name] | sort | join(",")) == "${TENANT}-postgres,pg-catalog"
          and (.spec.postBuild | keys | join(",")) == "substitute" and .spec.postBuild.substitute.APP == "postgres")' \
          "$file" >/dev/null || fail "$file: the cluster is \${TENANT}-postgres-cluster in \${TENANT}-postgres, from" \
            "./kubernetes/apps/postgres/cluster with one bootstrap, after \${TENANT}-postgres and pg-catalog"
        continue
      fi
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

bad=$(grep -rhoE "[$][{]($(paste -sd'|' <<<"$appnames"))_[A-Z0-9_]*" kubernetes/components kubernetes/edge | cut -c3- \
  | sort -u | paste -sd' ' || true)
[ -z "$bad" ] || fail "components/ and edge/ serve every app, so they read no app's own keys: $bad"
! grep -rnE '^\s*-\s*[a-z]+://' kubernetes --include=kustomization.yaml \
  || fail "kustomize resources must be files in this repository (--no-remote-bases)"
# Values the shared components and hosts default, which only a template may set: a source that set them would quietly
# change every app or host it reaches, such as the port the gateway may reach.
defaults=$(grep -rhoE '[$][{][A-Z0-9_]+:?[-=]' kubernetes/components kubernetes/edge | sed -E 's/^..//; s/:?[-=]$//' \
  | sort -u)

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
  knobs=$(yq '.spec.postBuild.substitute | keys | .[]' "$tenant/tenant.yaml" | grep -vx TENANT || true)
  bad=$(grep -vxE "($prefixes)_[A-Z0-9_]+" <<<"$knobs" || true)
  [ -z "$bad" ] || fail "$tenant/tenant.yaml: sets values for none of its apps: $bad"
  templates=$(sed "s|^$up/|kubernetes/|" <<<"$listed")
  for key in $knobs; do
    grep -qF "\${$key:=" $templates \
      || fail "$tenant/tenant.yaml: $key changes nothing, as no template the tenant lists has \${$key:=<default>}"
  done
  # Its secret holds its domains and, later, its apps' own keys; anything else could reach every app it runs.
  keys=$(yq '(.stringData // {}) * (.data // {}) | keys | .[]' "$tenant/$secrets")
  for key in TENANT_DOMAIN TENANT_APP_DOMAIN; do
    grep -qxF "$key" <<<"$keys" || fail "$tenant/$secrets holds TENANT_DOMAIN and TENANT_APP_DOMAIN"
  done
  bad=$(grep -vxE "TENANT_DOMAIN|TENANT_APP_DOMAIN|($prefixes)_[A-Z0-9_]+" <<<"$keys" || true)
  [ -z "$bad" ] || fail "$tenant/$secrets holds only TENANT_DOMAIN, TENANT_APP_DOMAIN and <APP>_* keys of apps the" \
    "tenant runs: $bad"
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
  # Network policies leave the cluster's own ranges out by its settings, so they must be its servers'.
  for range in $CLUSTER_RANGES; do
    setting=$(yq ea "[select(.kind == \"ConfigMap\" and .metadata.name == \"cluster-settings\")]
      | .[0].data.${range%%=*} // \"\"" "$rendered/cluster.yaml")
    [ "$setting" = "${range#*=}" ] \
      || fail "$cluster: cluster-settings sets ${range%%=*} to ${range#*=}, as the servers give k3s (nixos/cluster.nix)"
  done

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
      yq ea "[select(.kind == \"$kind\" and .metadata.name == \"$ref\" and .metadata.namespace == \"flux-system\")]
        | .[0] // {}" "$rendered/cluster.yaml" >"$w/src.yaml"
      [ "$(yq 'length' "$w/src.yaml")" != 0 ] \
        || fail "$cluster/$name: substituteFrom names $kind/$ref, which the cluster doesn't define"
      # Names are readable even when values are encrypted; flux build masks a Secret's as **SOPS** and drops its sops
      # key. Each stand-in differs per source and key, and is base64, as it may land in a Secret's data.
      standin="(\"$ref-\" + key | downcase | sub(\"_\", \"-\") | @base64)"
      if [ "$(yq 'has("sops")' "$w/src.yaml")" = true ]; then
        yq "(.stringData // .data // {}) | with(.[]; . = $standin)" "$w/src.yaml" >"$w/src.vars.yaml"
      elif [ "$kind" = ConfigMap ]; then
        yq '.data // {}' "$w/src.yaml" >"$w/src.vars.yaml"
      else
        yq "(.stringData // {}) * ((.data // {}) | with(.[] | select(. != \"**SOPS**\"); . |= @base64d))
          | with(.[] | select(. == \"**SOPS**\"); . = $standin)" "$w/src.yaml" >"$w/src.vars.yaml"
      fi
      bad=$(yq 'keys | .[]' "$w/src.vars.yaml" | grep -xF "$defaults" || true)
      [ -z "$bad" ] || fail "$cluster/$name: $kind/$ref sets $bad, which only a template may set"
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
    path=$(yq '.spec.path' "$w/$name.ks.yaml")
    # A file from elsewhere in the repository can read a key too, so other apps' keys get a value to look for.
    case $path in
      ./kubernetes/apps/*/*) guarded=$(grep -vxF "$(basename "$(dirname "$path")" | tr a-z A-Z)" <<<"$appnames" \
        | paste -sd'|' || true) ;;
      ./kubernetes/edge/*) guarded=$(paste -sd'|' <<<"$appnames") ;;
      *) guarded= ;;
    esac
    export guarded
    [ -z "$guarded" ] || yq -i 'with(.[] | select(key | test("^(" + strenv(guarded) + ")_"));
      . = "render-guard-" + key)' "$w/$name.vars.yaml"
    yq ".spec.postBuild.substitute = (load(\"$w/$name.vars.yaml\") * (.spec.postBuild.substitute // {}))
      | del(.spec.postBuild.substituteFrom)" "$w/$name.ks.yaml" >"$w/$name.build.yaml"
    flux build kustomization "$name" --path "$path" --kustomization-file "$w/$name.build.yaml" \
      --dry-run --strict-substitute >"$rendered/$name.yaml" || fail "$cluster/$name doesn't render"
    bad=$(grep -oE 'render-guard-[A-Z0-9_]+' "$rendered/$name.yaml" | sort -u | sed 's/^render-guard-//' \
      | paste -sd' ' || true)
    [ -z "$bad" ] || fail "$cluster/$name reads $bad: an app reads only its own keys, and a host none"
    echo "$name $path" >>"$w/paths"
    yq ea "[select($fluxks and .spec.sourceRef.name == \"suveraen\") | .metadata.name] | .[]" "$rendered/$name.yaml" \
      | sed "s/^/$name /" >>"$w/queue"
  done

  bad=$(yq ea "[select($fluxks) | select(.spec.serviceAccountName != \"kustomize-controller\"
    or .metadata.namespace != \"flux-system\" or (.spec.sourceRef | has(\"namespace\")) or (.spec | has(\"decryption\"))
    or ((.spec.dependsOn // []) | any_c(has(\"namespace\")))) | .metadata.name] | .[]" "$rendered"/*.yaml)
  [ -z "$bad" ] || fail "$cluster: Kustomizations act as Flux's own account from flux-system, and only the root" \
    "decrypts: $bad"
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
  # Each would take the object back from the other on every reconcile.
  dup=$(yq ea '[select(.kind != null) | .kind + "/" + (.metadata.namespace // "") + "/" + .metadata.name] | .[]' \
    "$rendered"/*.yaml | sort | uniq -d | paste -sd' ')
  [ -z "$dup" ] || fail "$cluster: two Kustomizations apply the same object: $dup"
  platform=$(yq ea "[select($fluxks) | select(.metadata.labels.\"suveraen/tenant\" == null) | .metadata.name] | .[]" \
    "$rendered/cluster.yaml")
  bad=$(grep -E "$tenantlike" <<<"$platform" || true)
  [ -z "$bad" ] || fail "$cluster: platform Kustomizations can't be named like a tenant's app: $bad"
  expected=$(for tenant in "$dir"/tenants/*/; do
    [ ! -d "$tenant" ] || printf '%s/tenant-%s\n' Kustomization "$(basename "$tenant")" Secret "$(basename "$tenant")"
  done | sort)
  reserved=$(yq ea '[select(.metadata.namespace == "flux-system" and (.metadata.name | test("^tenant-")))
    | .kind + "/" + .metadata.name] | .[]' "$rendered"/*.yaml | sort)
  [ "$reserved" = "$expected" ] || fail "$cluster: tenant- names only a tenant's own Kustomization and Secret:" \
    $(comm -23 <(echo "$reserved") <(echo "$expected"))

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
            | test("^" + strenv(t) + "-[a-z0-9]+(-edge-[a-z0-9]+|-db|-cluster)?$"))
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
        kinds=$appkinds
        [ "$app" != postgres ] || kinds+=$pgkinds
        export kinds
        bad=$(yq ea '[select(.kind == "HelmRelease") | select(.metadata.namespace == "flux-system"
          or .spec.serviceAccountName != "flux-deployer" or .spec.install.crds != "Skip" or .spec.upgrade.crds != "Skip"
          or (.spec | has("targetNamespace") or has("storageNamespace"))) | .metadata.name] | .[]' "$file")
        [ -z "$bad" ] || fail "$cluster/$name: app HelmReleases must run as flux-deployer in the app's namespace: $bad"
        bad=$(yq ea '[select(.kind != null)
          | ((.kind + "." + (.apiVersion | sub("/?[^/]*$", ""))) | sub("[.]$", "")) as $k
          | select(((strenv(kinds) | split(",")) | any_c(. == $k) | not)
            or ($k != "Namespace" and .metadata.namespace != strenv(name)))
          | $k + "/" + .metadata.name] | .[]' "$file")
        [ -z "$bad" ] || fail "$cluster/$name: an app creates only ${kinds//,/, }; in its own namespace: $bad"
        yq ea -e '[select(.kind == "Namespace")] | (length == 1 and .[0].metadata.name == strenv(name)
          and .[0].metadata.labels."suveraen/tier" == "app" and .[0].metadata.labels."suveraen/tenant" == strenv(t)
          and .[0].metadata.labels."suveraen/app" == strenv(app))' "$file" >/dev/null \
          || fail "$cluster/$name: an app's namespace is $name, labelled suveraen/tier=app, suveraen/tenant=$t and" \
            "suveraen/app=$app"
        # An app's volume is copied as components/volsync has it, as the app's own user, into its own prefix at
        # both providers, and restored from either with the files deleted since gone.
        bad=$(yq ea '[select(.kind == "Namespace" and .metadata.annotations."volsync.backube/privileged-movers" != null)
          | .metadata.name] | .[]' "$file")
        [ -z "$bad" ] || fail "$cluster/$name: VolSync's movers run as the app's user, never privileged: $bad"
        copies=$(yq ea '[select(.kind == "ReplicationSource" or .kind == "ReplicationDestination") | .kind + " "
          + .metadata.name + " " + .spec.restic.repository + " " + (.spec.sourcePVC // "-") + " "
          + (.spec.restic.moverSecurityContext.runAsNonRoot // false | tostring) + " "
          + (.spec.restic.enableFileDeletion // false | tostring)] | sort | join(",")' "$file")
        if [ -n "$copies" ]; then
          sources="ReplicationSource data-1 offsite-1 data true false,ReplicationSource data-2 offsite-2 data true false"
          [[ $copies == "ReplicationDestination data offsite-"[12]" - true true,$sources" ]] \
            || fail "$cluster/$name: an app's volume is copied by components/volsync alone, as a user that isn't" \
              "root, and restored from offsite-1 or offsite-2 with deletions: $copies"
          vars=$w/$name.vars.yaml
          for n in 1 2; do
            repository="s3:$(yq ".BACKUP_${n}_ENDPOINT" "$vars")/$(yq ".BACKUP_${n}_BUCKET_PREFIX" "$vars")$t/volsync/$app"
            [ "$(yq ea "[select(.kind == \"Secret\" and .metadata.name == \"offsite-$n\")
              | .stringData.RESTIC_REPOSITORY // \"-\"] | join(\",\")" "$file")" = "$repository" ] \
              || fail "$cluster/$name: copies of $app's volume go to $repository, from Secret offsite-$n"
          done
        fi
        # Volumes the platform makes are copied off-site or made anew by it, and never pruned.
        bad=$(yq ea '[select(.kind == "PersistentVolumeClaim") | select(.metadata.labels."suveraen/backup" == null
          or .metadata.annotations."kustomize.toolkit.fluxcd.io/prune" != "disabled") | .metadata.name] | .[]' "$file")
        [ -z "$bad" ] || fail "$cluster/$name: an app's volumes say how they are backed up (suveraen/backup) and are" \
          "never pruned: $bad"
        if [ "$app" = postgres ]; then
          # The tenant's own bucket, kept when its claim goes, which Barman writes to in the cluster's object store only.
          [ "$(yq ea '[select(.kind == "ObjectBucketClaim") | .metadata.name + " " + .spec.bucketName + " "
            + .spec.storageClassName + " " + .metadata.annotations."kustomize.toolkit.fluxcd.io/prune"] | .[]' "$file"
            yq ea '[select(.kind == "ObjectStore") | .metadata.name + " " + .spec.configuration.destinationPath + " "
            + .spec.configuration.endpointURL + " " + .spec.configuration.s3Credentials.accessKeyId.name + " "
            + .spec.configuration.s3Credentials.secretAccessKey.name] | .[]' "$file")" = "bucket $t-postgres $(
              )ceph-bucket disabled
postgres s3://$t-postgres/ http://rook-ceph-rgw-objects.rook-ceph.svc bucket bucket" ] \
            || fail "$cluster/$name: a tenant's bucket is $t-postgres, claimed from ceph-bucket and never pruned, and" \
              "Barman archives there through the cluster's object store with its keys"
        fi
        bad=$(yq ea '[select(.kind == "RoleBinding") | .metadata.namespace as $ns | select(
          (.roleRef.kind == "ClusterRole" and .roleRef.name != "flux-app")
          or ((.subjects // []) | any_c(.kind != "ServiceAccount" or ((.namespace // "") != "" and .namespace != $ns))))
          | .metadata.name] | .[]' "$file")
        [ -z "$bad" ] || fail "$cluster/$name: app role bindings may only give flux-app or the app's own roles to its" \
          "own accounts: $bad"
        yq ea -e '[select(.kind == "NetworkPolicy" and .metadata.name == "default-deny")] | (length == 1
          and (.[0].spec.podSelector | length) == 0 and (.[0].spec.policyTypes | sort | join(",")) == "Egress,Ingress"
          and (.[0].spec | (has("ingress") or has("egress")) | not))' "$file" >/dev/null \
          || fail "$cluster/$name: an app's namespace is closed in both directions by default"
        yq ea -e '[select(.kind == "ResourceQuota")] | (length == 1 and .[0].metadata.name == "app"
          and (.[0].spec.hard | keys | sort | join(",")) == strenv(hard)
          and .[0].spec.hard."services.loadbalancers" == "0" and .[0].spec.hard."services.nodeports" == "0")' \
          "$file" >/dev/null \
          || fail "$cluster/$name: an app's namespace has one ResourceQuota, app, on ${hard//,/, }, and publishes" \
            "nothing"
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
      ./kubernetes/apps/postgres/cluster)
        [ -n "$t" ] && [ "$name" = "$t-postgres-cluster" ] \
          || fail "$cluster/$name: a tenant's PostgreSQL cluster is <tenant>-postgres-cluster"
        generation=$(yq '.spec.postBuild.substitute.GENERATION' "$w/$name.build.yaml")
        origin=$(yq '.spec.postBuild.substitute.ORIGIN' "$w/$name.build.yaml")
        [[ $generation =~ ^g[0-9]+$ && $origin =~ ^g[0-9]+$ ]] \
          || fail "$cluster/$name: generations are g<number>: $generation, $origin"
        objects="Cluster/$t-postgres/postgres/$t,ScheduledBackup/$t-postgres/postgres-$generation/$t"
        [ "$(yq ea '[select(.kind != null) | .kind + "/" + .metadata.namespace + "/" + .metadata.name + "/"
          + .metadata.labels."suveraen/tenant"] | sort | join(",")' "$file")" = "$objects" ] \
          || fail "$cluster/$name: a tenant's PostgreSQL is Cluster postgres and ScheduledBackup postgres-$generation" \
            "in $t-postgres, labelled with tenant $t"
        recovery=$(yq ea '[select(.kind == "Cluster") | .spec.bootstrap | has("recovery")] | .[0]' "$file")
        # A cluster archives under its own generation and recovers only from an earlier one.
        if [ "$recovery" = true ]; then
          [ "$origin" != "$generation" ] \
            || fail "$cluster/$name: a cluster recovers from an earlier generation than its own, $generation"
          from="recovery:origin:postgres-$origin"
        else
          from=initdb
        fi
        yq ea '[select(.kind == "Cluster")] | .[0] | [
          "prune " + (.metadata.annotations."kustomize.toolkit.fluxcd.io/prune" // "enabled"),
          "superuser " + (.spec.enableSuperuserAccess // false | tostring),
          "image " + (.spec | has("imageName") | tostring) + "/" + (.spec.imageCatalogRef.kind // "-") + "/"
            + (.spec.imageCatalogRef.name // "-"),
          "storage " + (.spec.storage.storageClass // "-") + "/" + (.spec | has("walStorage") | tostring) + "/"
            + (.spec.inheritedMetadata.labels."suveraen/backup" // "-"),
          "pg_hba " + (.spec.postgresql.pg_hba // [] | join(";")),
          "archive " + ([.spec.plugins[] | .name + ":" + (.isWALArchiver // false | tostring) + ":"
            + (.parameters | to_entries | map(.key + "=" + .value) | join("+"))] | join(";")),
          "bootstrap " + ((.spec.bootstrap // {}) | keys | join(",")) + ":" + (.spec.bootstrap.recovery.source // "")
            + ":" + ([.spec.externalClusters[]? | select(.name == "origin") | .plugin.parameters.serverName]
            | join(","))] | .[]' "$file" | sed 's/^bootstrap initdb::$/bootstrap initdb/' >"$w/$name.pg"
        printf '%s\n' "prune disabled" "superuser false" "image false/ClusterImageCatalog/postgresql" \
          "storage ceph-block/false/postgres" "pg_hba hostssl sameuser all all scram-sha-256;host all all all reject" \
          "archive barman-cloud.cloudnative-pg.io:true:barmanObjectName=postgres+serverName=postgres-$generation" \
          "bootstrap $from" >"$w/$name.pg.want"
        bad=$(diff "$w/$name.pg.want" "$w/$name.pg" | sed -n 's/^> //p' | paste -sd';' || true)
        [ -z "$bad" ] || fail "$cluster/$name: a tenant's PostgreSQL is never pruned, has no superuser access, takes" \
          "its image from the catalog and its volume from ceph-block, labelled as Barman's to back up, lets each role" \
          "reach its own database alone over TLS, and archives with Barman to postgres-$generation: $bad"
        # Its namespace's quota holds every instance with its Barman sidecar, and a job copying the bucket.
        app=$rendered/$t-postgres.yaml
        instances=$(yq ea '[select(.kind == "Cluster")] | .[0].spec.instances' "$file")
        memory=$(yq ea '[select(.kind == "Cluster")] | .[0].spec.resources.limits.memory' "$file")
        sidecar=$(yq ea '[select(.kind == "ObjectStore")]
          | .[0].spec.instanceSidecarConfiguration.resources.limits.memory' "$app")
        job=$(yq ea '[select(.kind == "CronJob")]
          | .[0].spec.jobTemplate.spec.template.spec.containers[0].resources.limits.memory' "$app")
        quota=$(yq ea '[select(.kind == "ResourceQuota")] | .[0].spec.hard."limits.memory"' "$app")
        need=$((instances * ($(quantity "$memory") + $(quantity "$sidecar")) + $(quantity "$job")))
        [ "$need" -le "$(quantity "$quota")" ] \
          || fail "$cluster/$name: $t-postgres's quota, $quota, can't hold $instances instances of $memory, each with a" \
            "$sidecar sidecar, and a $job job"
        ;;
      ./kubernetes/apps/*/db)
        app=$(basename "$(dirname "$path")")
        export app
        [ -n "$t" ] && [ "$name" = "$t-$app-db" ] || fail "$cluster/$name: an app's database is <tenant>-<app>-db"
        objects="Database/$t-postgres/$app/$t,DatabaseRole/$t-postgres/$app/$t"
        objects+=",NetworkPolicy/$t-postgres/from-$app/$t,Secret/$t-postgres/$app-db/$t"
        [ "$(yq ea '[select(.kind != null) | .kind + "/" + .metadata.namespace + "/" + .metadata.name + "/"
          + .metadata.labels."suveraen/tenant"] | sort | join(",")' "$file")" = "$objects" ] \
          || fail "$cluster/$name: an app's database is Database, DatabaseRole $app, NetworkPolicy from-$app and" \
            "Secret $app-db in $t-postgres, labelled with tenant $t"
        {
          yq ea '[select(.kind == "Database") | .spec | "Database " + (keys | sort | join(",")) + " " + .cluster.name
            + " " + .name + " " + .owner] | .[]' "$file"
          yq ea '[select(.kind == "DatabaseRole") | .spec | "DatabaseRole " + (keys | sort | join(",")) + " "
            + .cluster.name + " " + .name + " " + (.login | tostring) + " " + .passwordSecret.name] | .[]' "$file"
          yq ea '[select(.kind == "NetworkPolicy") | .spec | "NetworkPolicy " + (.podSelector.matchLabels | to_entries
            | map(.key + "=" + .value) | join(",")) + " " + (.policyTypes | join(",")) + " " + ([.ingress[]
            | ([.from[] | (keys | join(",")) + "=" + (.namespaceSelector.matchLabels | to_entries
              | map(.key + "=" + .value) | join(","))] | join(";")) + ":" + ([.ports[].port | tostring] | join(","))]
            | join("|"))] | .[]' "$file"
          yq ea '[select(.kind == "Secret") | "Secret " + .type + " " + .stringData.username] | .[]' "$file"
        } >"$w/$name.db"
        printf '%s\n' "Database cluster,databaseReclaimPolicy,name,owner postgres $app $app" \
          "DatabaseRole cluster,connectionLimit,databaseRoleReclaimPolicy,login,name,passwordSecret postgres $app true $app-db" \
          "NetworkPolicy cnpg.io/cluster=postgres Ingress namespaceSelector=kubernetes.io/metadata.name=$t-$app:5432" \
          "Secret kubernetes.io/basic-auth $app" >"$w/$name.db.want"
        bad=$(diff "$w/$name.db.want" "$w/$name.db" | sed -n 's/^> //p' | paste -sd';' || true)
        [ -z "$bad" ] || fail "$cluster/$name: an app's role logs in with its Secret and nothing more, owns its" \
          "database of the same name, and is reached from $t-$app alone: $bad"
        ;;
      ./kubernetes/edge/app | ./kubernetes/edge/identity | ./kubernetes/edge/apex)
        [[ $name =~ ^$t-([a-z0-9]+)-edge-([a-z0-9]+)$ ]] && [ -n "$t" ] \
          || fail "$cluster/$name: a host is <tenant>-<app>-edge-<key>, one of its tenant's"
        app=${BASH_REMATCH[1]}
        key=${BASH_REMATCH[2]}
        base=$t-$app-$key
        export app base
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
        # The way to the internet is components/internet alone, for what the cluster's own ranges leave out.
        vars=$w/$name.vars.yaml
        v() { yq ".$1 // \"\"" "$vars"; }
        want='{"egress":[{"ports":[{"port":80,"protocol":"TCP"},{"port":443,"protocol":"TCP"}],"to":[{"ipBlock":'
        want+='{"cidr":"0.0.0.0/0","except":["'$(v POD_CIDR_V4)'","'$(v SERVICE_CIDR_V4)'","'$(v NODE_CIDR_V4)'",'
        want+='"169.254.0.0/16"]}},{"ipBlock":{"cidr":"::/0","except":["'$(v POD_CIDR_V6)'","'$(v SERVICE_CIDR_V6)'","'
        want+=$(v NODE_CIDR_V6)'","fe80::/10"]}}]}],"podSelector":{"matchLabels":{"suveraen/egress":"internet"}},'
        want+='"policyTypes":["Egress"]}'
        bad=$(yq ea -o=json -I=0 '[select(.kind == "NetworkPolicy" and .metadata.name == "internet")
          | .spec | sort_keys(..)] | .[]' "$file" | grep -vxF "$want" || true)
        [ -z "$bad" ] || fail "$cluster/$name: the network policy internet opens web ports to all but the cluster's own" \
          "pods, Services and nodes, for pods labelled suveraen/egress=internet: $bad"
        # The way to the API server on the nodes, for CloudNativePG's pods alone.
        want='{"egress":[{"ports":[{"port":6443,"protocol":"TCP"}],"to":[{"ipBlock":{"cidr":"'$(v NODE_CIDR_V4)'"}},'
        want+='{"ipBlock":{"cidr":"'$(v NODE_CIDR_V6)'"}}]}],"podSelector":{"matchExpressions":[{"key":"cnpg.io/cluster",'
        want+='"operator":"Exists"}]},"policyTypes":["Egress"]}'
        [ "$path" = ./kubernetes/apps/postgres/app ] || want=none
        bad=$(yq ea -o=json -I=0 '[select(.kind == "NetworkPolicy" and .metadata.name == "api-server")
          | .spec | sort_keys(..)] | .[]' "$file" | grep -vxF "$want" || true)
        [ -z "$bad" ] || fail "$cluster/$name: the network policy api-server opens the API server on the nodes to" \
          "CloudNativePG's pods, in a tenant's PostgreSQL alone: $bad"
        bad=$(yq ea '[select(.kind == "NetworkPolicy" and .metadata.name != "internet" and .metadata.name != "api-server")
          | .metadata.name as $np
          | [.spec.ingress[]?.from[]?, .spec.egress[]?.to[]?] | .[]
          | {"np": $np, "ipblock": has("ipBlock"), "selector": has("namespaceSelector"),
            "expressions": ((.namespaceSelector // {}) | has("matchExpressions")),
            "labels": ((.namespaceSelector.matchLabels // {}) | to_entries | length),
            "name": (.namespaceSelector.matchLabels."kubernetes.io/metadata.name" // ""),
            "tenant": (.namespaceSelector.matchLabels."suveraen/tenant" // "")}]
          | map(select(.ipblock or (.selector and (.expressions or (.tenant != strenv(t) and (.labels != 1
            or (.name != "kube-system" and .name != "gateway" and .name != "cloudnative-pg" and .name != "rook-ceph"
              and (.name | test("^" + strenv(t) + "-") | not))))))))
          | map(.np) | unique | .[]' "$file")
        [ -z "$bad" ] || fail "$cluster/$name: network policies reach only named platform namespaces and tenant $t's" \
          "own: $bad"
        ;;
    esac
    # Ceph's namespace alone runs privileged pods, all three modes saying so.
    bad=$(yq ea '[select(.kind == "Namespace") | .metadata.name + " " + ((.metadata.labels // {}) | to_entries
      | map(select(.key | test("^pod-security.kubernetes.io/")) | .key + "=" + .value) | sort | join(","))] | .[]' \
      "$file" | awk -v ks="$name" -v ceph="$privileged" \
        '$2 != "" && ($1 != "rook-ceph" || ks != "rook-ceph" || $2 != ceph) { print $1 }')
    [ -z "$bad" ] || fail "$cluster/$name: namespaces keep the cluster's restricted Pod Security default; only" \
      "rook-ceph, where Ceph runs, is privileged: $bad"
    bad=$(yq ea '[select(.kind == "Namespace") | .metadata.name + " " + (.metadata.labels."suveraen/private-ca" // "-")]
      | .[]' "$file" | awk -v ks="$name" \
        '$2 != "-" && ($1 != "cloudnative-pg" || ks != "cloudnative-pg" || $2 != "true") { print $1 }')
    [ -z "$bad" ] || fail "$cluster/$name: only cloudnative-pg signs certificates for its own names: $bad"
    # Images in what is rendered here, the PostgreSQL images clusters take from catalogs, Ceph's, and the tags charts
    # are given.
    bad=$({
      yq ea '[select(.kind == "ClusterImageCatalog" or .kind == "ImageCatalog") | .spec.images[].image] | .[]' "$file"
      yq ea '[.spec.template.spec // .spec.jobTemplate.spec.template.spec // {}
        | ((.containers // []) + (.initContainers // []))[] | .image] | .[]' "$file"
      yq ea '[select(.kind == "CephCluster") | .spec.cephVersion.image] | .[]' "$file"
      yq ea '[select(.kind == "HelmRelease") | .spec.values // {} | .. | select(tag == "!!map" and has("tag")) | .tag
        | tostring] | .[]' "$file"
    } | grep -vE '@sha256:[0-9a-f]{64}$' | sort -u | paste -sd' ' || true)
    [ -z "$bad" ] || fail "$cluster/$name: images are pinned by digest: $bad"
    # Helm repositories and buckets serve whatever they hold at the time, with nothing to pin them by.
    bad=$(yq ea '[select((.kind == "OCIRepository" and .spec.ref.digest == null)
      or (.kind == "GitRepository" and .spec.ref.commit == null)
      or ((.apiVersion // "") | test("^source.toolkit.fluxcd.io/"))
        and (.kind == "HelmRepository" or .kind == "Bucket"))
      | .kind + "/" + .metadata.name] | .[]' "$file")
    [ -z "$bad" ] || fail "$cluster/$name: sources must be pinned to a digest or a commit: $bad"
    if [ "$name" != gateway ]; then
      bad=$(yq ea '[select(.kind == "Namespace" and .metadata.labels."suveraen/publish" == "true") | .metadata.name]
        | .[]' "$file")
      [ -z "$bad" ] || fail "$cluster/$name: only the gateway may publish ports: $bad"
    fi
  done <"$w/paths"
  # Flux would wait forever on a Kustomization that depends on itself, however indirectly.
  yq ea "[select($fluxks) | .metadata.name as \$n | .spec.dependsOn[]?.name | \$n + \" \" + .] | .[]" \
    "$rendered"/*.yaml >"$w/deps"
  bad=$(awk '$1 == $2 { print $1 }' "$w/deps")
  [ -z "$bad" ] || fail "$cluster: Kustomizations depend on themselves: $bad"
  tsort "$w/deps" >/dev/null 2>"$w/loop" \
    || fail "$cluster: Kustomizations depend on each other in a loop: $(grep -v 'input contains a loop' "$w/loop" \
      | sed 's/^tsort: //' | paste -sd' ')"

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
  # Ceph keeps three copies of everything, two needed to write, spread over the cluster's one failure domain: the OSD
  # while it is one server, the host from three. No erasure coding.
  pool='(P.failureDomain // "-") + " " + (P.replicated.size // 0 | tostring) + " "
    + (P.replicated.requireSafeReplicaSize // false | tostring) + " " + (P.parameters.min_size // "-") + " "
    + (P.enableCrushUpdates // false | tostring) + " " + (P | has("erasureCoded") | tostring)'
  {
    yq ea "[select(.kind == \"CephBlockPool\") | \"CephBlockPool/\" + .metadata.name + \" \"
      + ${pool//P/.spec}] | .[]" "$rendered"/*.yaml
    for part in metadata data; do
      yq ea "[select(.kind == \"CephObjectStore\") | \"CephObjectStore/\" + .metadata.name + \"/$part \"
        + ${pool//P/.spec.${part}Pool}] | .[]" "$rendered"/*.yaml
    done
  } >"$w/pools"
  bad=$(awk '$2 !~ /^(osd|host)$/ || $3 != 3 || $4 != "true" || $5 != "2" || $6 != "true" || $7 != "false" {
    print $1 }' "$w/pools" | paste -sd' ')
  [ -z "$bad" ] || fail "$cluster: every Ceph pool keeps 3 copies, needs 2 to write, lets Rook update its CRUSH rule" \
    "and spreads over the OSD or the host, without erasure coding: $bad"
  domain=$(cut -d' ' -f2 "$w/pools" | sort -u)
  [ "$(wc -l <<<"$domain")" = 1 ] || fail "$cluster: every Ceph pool has the same failure domain:" $domain
  ceph=$(yq ea '[select(.kind == "CephCluster")] | .[] | .metadata.namespace + "/" + .metadata.name' "$rendered"/*.yaml)
  [ "$ceph" = rook-ceph/rook-ceph ] || fail "$cluster: one CephCluster, rook-ceph/rook-ceph"
  # Daemons share a node only while copies spread over OSDs. The hosts name the disks (suveraen.storage.ceph); the
  # cluster lists the slots they may give it from osd0 on, each with its own DB volume.
  share=$([ "$domain" = osd ] && echo true || echo false)
  slots=$(yq ea '[select(.kind == "CephCluster") | .spec.storage.devices[]] | length' "$rendered"/*.yaml)
  devices=$(for ((n = 0; n < slots; n++)); do
    printf '/dev/disk/by-osd/osd%s:/dev/disk/by-osd/osd%s-db:hdd ' "$n" "$n"
  done)
  yq ea '[select(.kind == "CephCluster") | .spec] | .[0] | [
    "dataDirHostPath " + .dataDirHostPath,
    "allowUnsupported " + (.cephVersion.allowUnsupported // false | tostring),
    "mons " + (.mon.count | tostring),
    "monsShareNode " + (.mon.allowMultiplePerNode // false | tostring),
    "mgrsShareNode " + (.mgr.allowMultiplePerNode // false | tostring),
    "requireMsgr2 " + (.network.connections.requireMsgr2 // false | tostring),
    "network " + (.network.provider // "pods") + "/" + (.network.connections.encryption.enabled // false | tostring),
    "osdMemoryGuaranteed " + ((.resources.osd.requests.memory // "") == (.resources.osd.limits.memory // "-")
      | tostring),
    "useAllNodes " + (.storage.useAllNodes // false | tostring),
    "nodes " + (.storage | has("nodes") | tostring),
    "useAllDevices " + (.storage.useAllDevices // false | tostring),
    "filters " + (.storage | has("deviceFilter") | tostring) + "/" + (.storage | has("devicePathFilter") | tostring),
    "config " + (.storage.config | to_entries | map(.key + "=" + .value) | join(",")),
    "devices " + ([.storage.devices[] | .name + ":" + (.config.metadataDevice // "-") + ":"
      + (.config.deviceClass // "-") + (.config | keys | map(select(. != "metadataDevice" and . != "deviceClass"))
      | map("+" + .) | join(""))] | join(" "))] | .[]' "$rendered"/*.yaml \
    | sed 's|^network host/true$|network encrypted|; s|^network pods/.*$|network encrypted|' >"$w/cephcluster"
  printf '%s\n' "dataDirHostPath /var/lib/rook" "allowUnsupported false" "mons 3" "monsShareNode $share" \
    "mgrsShareNode $share" "requireMsgr2 true" "network encrypted" "osdMemoryGuaranteed true" "useAllNodes true" \
    "nodes false" "useAllDevices false" "filters false/false" "config encryptedDevice=true" "devices ${devices% }" \
    >"$w/cephcluster.want"
  bad=$(diff "$w/cephcluster.want" "$w/cephcluster" | sed -n 's/^> //p' | paste -sd';' || true)
  [ -z "$bad" ] || fail "$cluster: the CephCluster keeps its state in /var/lib/rook, runs a supported Ceph with three" \
    "monitors, lets daemons share a node only while copies spread over OSDs, speaks msgr2 alone, encrypted when on" \
    "the hosts' network, guarantees its OSDs their memory, and takes encrypted OSDs from every node on slots from" \
    "osd0 on, each with its DB on its own volume: $bad"
  # Placement groups follow the OSDs and pools, not the order the pools came in.
  [ "$(yq ea '[select(.kind == "CephCluster")] | .[0].spec.cephConfig.mgr."mgr/pg_autoscaler/threshold"
    | select(tag == "!!str")' "$rendered"/*.yaml)" = 1.0 ] \
    || fail "$cluster: Ceph's autoscaler acts on every change it recommends"
  # Dropping one from Git leaves it running: Rook would delete the cluster's data with it.
  bad=$(yq ea '[select(.kind == "CephCluster" or .kind == "CephBlockPool" or .kind == "CephObjectStore")
    | select(.metadata.annotations."kustomize.toolkit.fluxcd.io/prune" != "disabled") | .kind + "/" + .metadata.name]
    | .[]' "$rendered"/*.yaml)
  [ -z "$bad" ] || fail "$cluster: Ceph's objects are never pruned: $bad"
  # Volumes go with their claims, buckets stay, and a chart's claim without a class stays Pending.
  bad=$(yq ea '[select(.kind == "StorageClass") | .metadata.name + " " + .provisioner + " "
    + (.reclaimPolicy // "Delete") + " "
    + (.metadata.annotations."storageclass.kubernetes.io/is-default-class" // "false")] | .[]' "$rendered"/*.yaml \
    | awk '{ volume = $2 == "rook-ceph.rbd.csi.ceph.com" && $3 == "Delete" }
      { bucket = $2 == "rook-ceph.ceph.rook.io/bucket" && $3 == "Retain" }
      !(volume || bucket) || $4 != "false" { print $1 }' | paste -sd' ')
  [ -z "$bad" ] || fail "$cluster: storage classes are Ceph's, volumes go with their claims and buckets stay, and" \
    "none is the default: $bad"
  # The CSI operator runs a driver's plugins as the accounts it names, and creates neither them nor their rights.
  bad=$({
    yq ea '[select(.kind == "ClusterRole") | "role ClusterRole/" + .metadata.name] | .[]' "$rendered"/*.yaml
    yq ea '[select(.kind == "Role") | "role Role/" + .metadata.namespace + "/" + .metadata.name] | .[]' \
      "$rendered"/*.yaml
    yq ea '[select(.kind == "ServiceAccount") | "account " + .metadata.namespace + "/" + .metadata.name] | .[]' \
      "$rendered"/*.yaml
    yq ea '[select(.kind == "ClusterRoleBinding" or .kind == "RoleBinding") | .kind as $k
      | (.metadata.namespace // "-") as $ns | .roleRef as $r | .subjects[]? | select(.kind == "ServiceAccount")
      | "binding " + $k + " " + $ns + " " + $r.kind + " " + $r.name + " " + (.namespace // $ns) + "/" + .name] | .[]' \
      "$rendered"/*.yaml
    yq ea '[select(.apiVersion == "csi.ceph.io/v1" and .kind == "Driver") | .metadata.name as $d
      | .metadata.namespace as $ns | (.spec.controllerPlugin, .spec.nodePlugin)
      | "driver " + $d + " " + $ns + "/" + (.serviceAccountName // "-")] | .[]' "$rendered"/*.yaml
  } | awk '$1 == "role" { roles[$2] = 1 }
    $1 == "account" { accounts[$2] = 1 }
    $1 == "binding" {
      if (!((($4 == "Role") ? "Role/" $3 "/" $5 : "ClusterRole/" $5) in roles)) next
      if ($2 == "ClusterRoleBinding") cluster[$6] = 1
      else if (index($6, $3 "/") == 1) local[$6] = 1
    }
    $1 == "driver" && ($3 ~ /\/-$/ || !($3 in accounts && $3 in cluster && $3 in local)) { print $2 ":" $3 }' \
    | sort -u | paste -sd' ')
  [ -z "$bad" ] || fail "$cluster: each CSI driver names the accounts its plugins run as, and each exists, bound to a" \
    "ClusterRole and to a Role in its namespace: $bad"
  for issuer in public standby; do
    [ "$(yq ea "[select(.kind == \"ClusterIssuer\" and .metadata.name == \"$issuer\")] | length" "$rendered"/*.yaml)" \
      = 1 ] || fail "$cluster: the cluster has one ClusterIssuer public, which every host's certificate names, and" \
      "one standby"
  done
  if [ "$testing" = false ]; then
    # Hosts' certificates come from CAs that browsers trust, so no test or self-made CA is left in place.
    bad=$(yq ea '[select(.kind == "ClusterIssuer") | select((.spec | keys | join(",")) != "acme"
      or (.spec.acme.caBundle // "") != "" or .spec.acme.skipTLSVerify == true) | .metadata.name] | .[]' \
      "$rendered"/*.yaml | sort | paste -sd' ')
    [ -z "$bad" ] || fail "$cluster: every ClusterIssuer is an ACME CA the public trust store vouches for: $bad"
    bad=$(yq ea '[select(.kind == "Secret" and .metadata.name == "cluster-secrets")
      | select((.stringData // {}) * (.data // {}) | to_entries | any_c(.value != "**SOPS**")) | .metadata.name]
      | .[]' "$rendered/cluster.yaml")
    [ -z "$bad" ] || fail "$cluster: the cluster's secrets, its CA accounts, are encrypted in every value"
    # A tenant's secret holds its domains and keys, which tie it to a customer or a person.
    bad=$(yq ea '[select(.kind == "Secret" and (.metadata.name | test("^tenant-")))
      | select((.stringData // {}) * (.data // {}) | to_entries | any_c(.value != "**SOPS**")) | .metadata.name]
      | .[]' \
      "$rendered/cluster.yaml")
    [ -z "$bad" ] || fail "$cluster: tenant secrets are encrypted in every value: $bad"
  fi

  # Two copies off-site at two providers, which a real cluster reaches over TLS only.
  backups=$(yq ea '[select(.kind == "ConfigMap" and .metadata.name == "cluster-settings")] | .[0].data
    | (.BACKUP_1_ENDPOINT // "") + " " + (.BACKUP_2_ENDPOINT // "")' "$rendered/cluster.yaml")
  read -r one two <<<"$backups"
  [ -n "$two" ] && [ "$one" != "$two" ] || fail "$cluster: the two providers' endpoints differ: $backups"
  [ "$testing" = true ] || [[ $one == https://* && $two == https://* ]] \
    || fail "$cluster: the providers' endpoints are https: $backups"

  yq ea '[select(.kind == "ConfigMap" and .metadata.name == "cluster-settings")] | .[0].data // {} | keys | .[]' \
    "$rendered/cluster.yaml" >"$w/keys"
  yq ea '[select(.kind == "Secret" and .metadata.name == "cluster-secrets")]
    | (.[0].stringData // .[0].data // {}) | keys | .[]' "$rendered/cluster.yaml" >>"$w/keys"
done

# Every cluster sets the same settings and secrets, so none is forgotten in one of them.
[ "$(for keys in "$work"/*/keys; do sort "$keys" | sha256sum; done | sort -u | wc -l)" = 1 ] \
  || fail "the clusters don't set the same settings and secrets"
grep -oE '^[^ ]+ tenant-' "$work/tested" | sort | uniq -c | awk '$1 >= 2 { found = 1 } END { exit !found }' \
  || fail "a test cluster runs at least two tenants, so their separation is tested"
for file in kubernetes/apps/*/ks.yaml kubernetes/apps/*/edge-*.yaml; do
  [ -e "$file" ] || continue
  names=$(yq ea '[.metadata.name | sub("^[$][{]TENANT[}]-", "")] | .[]' "$file")
  for template in $names; do
    grep -qE " [a-z][a-z0-9]{4}-$template$" "$work/tested" || fail "$file: no test cluster's tenant runs $template"
  done
done
