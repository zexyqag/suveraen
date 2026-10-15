# Breaks copies of kubernetes/ in ways render.sh must refuse, and checks that it does, each for the intended reason.
# Some variants must still render: encrypted values, a cluster that isn't a test one, a test cluster by another name.
# Usage: render-cases.sh <render.sh> <kubernetes directory>
set -euo pipefail
render=$1
src=$2
cases=$(mktemp -d)
jobs=${NIX_BUILD_CORES:-1}
[ "$jobs" -gt 0 ] || jobs=$(nproc)

# Runs a case in the background: a copy of kubernetes/ changed by a shell snippet, then render.sh on it.
run() {
  local id=$1 expect=$2 change=$3 dir=$cases/$1
  mkdir -p "$dir"
  cp -r --no-preserve=mode "$src" "$dir/kubernetes"
  while [ "$(jobs -rp | wc -l)" -ge "$jobs" ]; do wait -n || true; done
  (
    cd "$dir/kubernetes"
    if ! (eval "$change") >"$dir/log" 2>&1; then
      echo "BROKEN      $id: the change itself failed: $(tail -1 "$dir/log")" >"$dir/result"
    elif bash "$render" "$dir/kubernetes" "$dir/out" >"$dir/log" 2>&1; then
      if [ -z "$expect" ]; then echo "ok          $id" >"$dir/result"; else echo "NOT REFUSED $id" >"$dir/result"; fi
    elif [ -n "$expect" ] && grep -qF -- "$expect" "$dir/log"; then
      echo "ok          $id" >"$dir/result"
    else
      echo "WRONG       $id: $(tail -1 "$dir/log")" >"$dir/result"
    fi
  ) &
}
refuses() { run "$1" "$2" "$3"; }
renders() { run "$1" "" "$2"; }

T=clusters/test/tenants
append() { printf -- "$2" >>"$1"; }
np() { # a NetworkPolicy added to every app namespace
  append components/app/networkpolicies.yaml "---\napiVersion: networking.k8s.io/v1\nkind: NetworkPolicy\nmetadata:
  name: x\nspec:\n  podSelector: {}\n  policyTypes: [Ingress, Egress]\n$1"
}
sops='sops:\n  age:\n    - recipient: age1example\n      enc: x\n  lastmodified: "2026-10-15T00:00:00Z"\n  mac: ENC[x]
  version: 3.10.2\n'
encrypted='ENC[AES256_GCM,data:x,type:str]'
encsecret() { # tenant directory
  mv "$1/secrets.yaml" "$1/secrets.sops.yaml"
  sed -i 's|./secrets.yaml|./secrets.sops.yaml|' "$1/kustomization.yaml"
  yq -i ".stringData[] = \"$encrypted\"" "$1/secrets.sops.yaml"
  append "$1/secrets.sops.yaml" "$sops"
}
encmap() { # cluster directory
  yq -i ".data[] = \"$encrypted\"" "$1/hostnames.yaml"
  append "$1/hostnames.yaml" "$sops"
}
# A second cluster, not a test one, whose only tenant is shaped like alpha.
prod() { # tenant ID
  mkdir -p clusters/prod/tenants
  cp clusters/test/settings.yaml clusters/test/hostnames.yaml clusters/prod/
  sed -i 's/TEST_CLUSTER: "true"/TEST_CLUSTER: "false"/' clusters/prod/settings.yaml
  sed "s|./tenants/alpha|./tenants/$1|; /tenants\/bravo/d" clusters/test/kustomization.yaml \
    >clusters/prod/kustomization.yaml
  cp -r $T/alpha "clusters/prod/tenants/$1"
  sed -i "s/alpha/$1/g; s|clusters/test|clusters/prod|" "clusters/prod/tenants/$1"/*.yaml
}

# Tenants and their sources.
refuses bad-tenant-id "tenant IDs are five lowercase letters" "mv $T/bravo $T/bravo1"
refuses tenant-name "Kustomization tenant-bravo, labelled with its tenant" \
  "sed -i 's/name: tenant-bravo/name: bravo/' $T/bravo/tenant.yaml"
refuses tenant-not-listed "isn't in its cluster" "sed -i '/tenants\/bravo/d' clusters/test/kustomization.yaml"
refuses tenant-secret-unlabelled "holds Secret tenant-bravo, labelled with its tenant" \
  "yq -i 'del(.metadata.labels)' $T/bravo/secrets.yaml"
refuses manifest-no-namespace "lists apps into flux-system with components/tenant" \
  "sed -i '/^namespace:/d' $T/alpha/apps/kustomization.yaml"
refuses manifest-extra-patch "lists apps into flux-system with components/tenant" \
  "append $T/alpha/apps/kustomization.yaml 'patches:\n  - path: x.yaml\n'"
refuses manifest-other-file "a tenant lists apps' templates" \
  "sed -i 's|apps/hello/ks.yaml|apps/hello/app/configmap.yaml|' $T/bravo/apps/kustomization.yaml"
refuses host-without-app "adds a host to hello, which the tenant doesn't run" \
  "sed -i 's|apps/hello/ks.yaml|apps/hello/edge-apex.yaml|' $T/bravo/apps/kustomization.yaml"
refuses knob-for-other-app "sets values for none of its apps" \
  "yq -i '.spec.postBuild.substitute.NEXTCLOUD_QUOTA_MEMORY = \"1Gi\"' $T/bravo/tenant.yaml"
refuses knob-typo "HELLO_QUOTA_MEMROY changes nothing" \
  "yq -i '.spec.postBuild.substitute.HELLO_QUOTA_MEMROY = \"512Mi\"' $T/bravo/tenant.yaml"
refuses knob-without-default "HELLO_QUOTA_PODS changes nothing" \
  "yq -i '.spec.postBuild.substitute.HELLO_QUOTA_PODS = \"8\"' $T/bravo/tenant.yaml"
only="holds only TENANT_DOMAIN, TENANT_APP_DOMAIN and <APP>_* keys of apps the tenant runs"
refuses secret-missing-key "holds TENANT_DOMAIN and TENANT_APP_DOMAIN" \
  "sed -i '/TENANT_APP_DOMAIN/d' $T/bravo/secrets.yaml"
refuses secret-sets-tenant "$only: TENANT" "append $T/bravo/secrets.yaml '  TENANT: alpha\n'"
refuses secret-extra-key "$only: SOMETHING_ELSE" "append $T/bravo/secrets.yaml '  SOMETHING_ELSE: x\n'"
refuses secret-other-app-key "$only: NEXTCLOUD_ADMIN_PASSWORD" \
  "append $T/bravo/secrets.yaml '  NEXTCLOUD_ADMIN_PASSWORD: x\n'"
refuses secret-overrides-route-port "$only: ROUTE_TARGET_PORT" \
  "append $T/bravo/secrets.yaml '  ROUTE_TARGET_PORT: \"22\"\n'"
refuses secret-and-setting "HELLO_GREETING comes from more than one of its sources" \
  "append $T/bravo/secrets.yaml '  HELLO_GREETING: x\n'; append clusters/test/settings.yaml '  HELLO_GREETING: x\n'"
refuses setting-and-inline "QUOTA_CPU is set inline and by one of its sources" \
  "append clusters/test/settings.yaml '  QUOTA_CPU: 1000m\n'"
refuses settings-override-route-port "cluster-settings sets ROUTE_TARGET_PORT, which only a template may set" \
  "append clusters/test/settings.yaml '  ROUTE_TARGET_PORT: \"22\"\n'"
refuses settings-override-route-service "cluster-settings sets ROUTE_SERVICE, which only a template may set" \
  "append clusters/test/settings.yaml '  ROUTE_SERVICE: other\n'"
refuses cluster-secrets-to-tenant "substituting from its sources only" \
  "sed -i 's/              name: tenant-\${TENANT}/&\n            - kind: Secret\n              name: cluster-secrets\n\
              optional: true/' components/tenant/kustomization.yaml"
refuses unlabelled-child "isn't one of tenant alpha's apps, labelled with it" \
  "sed -i 's|            suveraen/tenant: \${TENANT}|            suveraen/owner: \${TENANT}|' \
   components/tenant/kustomization.yaml"
refuses two-home-clusters "a tenant lives in one cluster, its home: alpha" \
  "prod alpha"
refuses one-test-tenant "a test cluster runs at least two tenants" \
  "rm -r $T/bravo; sed -i '/tenants\/bravo/d' clusters/test/kustomization.yaml"
refuses no-test-marker "cluster-settings says whether its tenants are stand-ins" \
  "yq -i 'del(.data.TEST_CLUSTER)' clusters/test/settings.yaml"
refuses marked-real "test: the hostname map links domains to tenants, so it is encrypted" \
  "sed -i 's/TEST_CLUSTER: \"true\"/TEST_CLUSTER: \"false\"/' clusters/test/settings.yaml"
refuses real-cluster-plain-map "prod: the hostname map links domains to tenants, so it is encrypted" \
  "prod delta; encsecret clusters/prod/tenants/delta"
refuses real-cluster-plain-secret "prod: tenant secrets are encrypted in every value: tenant-delta" \
  "prod delta; encmap clusters/prod"
refuses settings-differ "the clusters don't set the same settings and secrets" \
  "prod delta; encsecret clusters/prod/tenants/delta; encmap clusters/prod
   append clusters/prod/settings.yaml '  EXTRA: x\n'"

# Templates.
refuses template-variable "a template may use only" \
  "sed -i 's/      HOST: hello\$/      HOST: \${TENANT_APP_DOMAIN}/' apps/hello/ks.yaml"
refuses app-at-root "creates a Kustomization named \${TENANT}-hello" \
  "sed -i 's|  - ./tenants/alpha|  - ../../apps/hello/ks.yaml\n  - ./tenants/alpha|' clusters/test/kustomization.yaml"
refuses template-kubeconfig "it sets only its name, path, targetNamespace, components, dependsOn" \
  "yq -i '(select(documentIndex == 0) | .spec.kubeConfig.secretRef.name) = \"tenant-\${TENANT}\"' apps/hello/ks.yaml"
refuses template-deletion-policy "it sets only its name, path, targetNamespace, components, dependsOn" \
  "yq -i '(select(documentIndex == 0) | .spec.deletionPolicy) = \"Delete\"' apps/hello/ks.yaml"
refuses template-labels "it sets only its name, path, targetNamespace, components, dependsOn" \
  "yq -i '(select(documentIndex == 0) | .metadata.labels.x) = \"y\"' apps/hello/ks.yaml"
refuses template-defaults-field "it sets only its name, path, targetNamespace, components, dependsOn" \
  "yq -i '(select(documentIndex == 0) | .spec.wait) = false' apps/hello/ks.yaml"
refuses dep-loop "Kustomizations depend on each other in a loop" \
  "yq -i '(select(documentIndex == 0) | .spec.dependsOn) += [{\"name\": \"\${TENANT}-hello-edge-hello\"}]' \
   apps/hello/ks.yaml"
refuses dep-self "Kustomizations depend on themselves: alpha-hello" \
  "yq -i '(select(documentIndex == 0) | .spec.dependsOn) += [{\"name\": \"\${TENANT}-hello\"}]' apps/hello/ks.yaml"
refuses platform-named-like-tenant "tenant- names only a tenant's own Kustomization and Secret: Kustomization/tenant-" \
  "sed -i 's/  name: reloader\$/  name: tenant-zzzzz/' platform/reloader/ks.yaml"
refuses secret-named-like-tenant "tenant- names only a tenant's own Kustomization and Secret: Secret/tenant-zzzzz" \
  "sed -i 's/  - .\/settings.yaml/&\n  - .\/extra.yaml/' clusters/test/kustomization.yaml
   append clusters/test/extra.yaml 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: tenant-zzzzz\n'"
refuses cross-tenant-dep "depends on bravo-hello, which is neither the platform nor tenant alpha's" \
  "yq -i '(select(documentIndex == 0) | .spec.dependsOn) += [{\"name\": \"bravo-hello\"}]' apps/hello/ks.yaml"
refuses edge-without-app-dep "a host is \${TENANT}-hello-edge-<EDGE>" \
  "yq -i 'del(select(documentIndex == 1) | .spec.dependsOn[0])' apps/hello/ks.yaml"
refuses edge-suspended "a host is \${TENANT}-hello-edge-<EDGE>" \
  "yq -i '(select(documentIndex == 1) | .spec.suspend) = true' apps/hello/ks.yaml"
refuses edge-file-name "holds host top, so it is edge-top.yaml" \
  "sed -i 's/edge-apex/edge-top/; s/EDGE: apex/EDGE: top/' apps/hello/edge-apex.yaml"
refuses edge-untested "no test cluster's tenant runs hello-edge-www" \
  "sed 's/edge-apex/edge-www/; s/EDGE: apex/EDGE: www/' apps/hello/edge-apex.yaml >apps/hello/edge-www.yaml"
refuses zone-host "a host's listener names hello.example.test alone" \
  "sed -i 's/TENANT_APP_DOMAIN/TENANT_DOMAIN/' edge/app/kustomization.yaml"

# Hosts and the hostname map.
refuses same-host "two listeners claim the same host" \
  "sed -i 's/TENANT_APP_DOMAIN: org.test/TENANT_APP_DOMAIN: example.test/' $T/bravo/secrets.yaml
   append clusters/test/hostnames.yaml '  hello.example.test: bravo\n'"
refuses map-owner "bravo-hello serves hello.org.test, but the hostname map gives it to alpha" \
  "sed -i 's/org.test: bravo/org.test: alpha/' clusters/test/hostnames.yaml"
refuses map-missing-domain "bravo-hello serves hello.org.test, but the hostname map gives it to nobody" \
  "sed -i '/org.test: bravo/d' clusters/test/hostnames.yaml"
refuses map-carve-out "bravo-hello serves hello.org.test, but the hostname map gives it to alpha" \
  "append clusters/test/hostnames.yaml '  hello.org.test: alpha\n'"
refuses map-suffix "bravo-hello serves hello.org.test, but the hostname map gives it to nobody" \
  "sed -i 's/org.test: bravo/rg.test: bravo/' clusters/test/hostnames.yaml"
refuses map-other-namespace "alpha-hello serves one.test, but the hostname map gives it to alpha-other" \
  "sed -i 's/one.test: alpha-hello/one.test: alpha-other/' clusters/test/hostnames.yaml"
refuses map-bad-value "the hostname map gives each name to a tenant or one of its namespaces: org.test" \
  "sed -i 's/org.test: bravo/org.test: Bravo/' clusters/test/hostnames.yaml"
refuses map-absent "the cluster has no hostname map" "sed -i '/hostnames.yaml/d' clusters/test/kustomization.yaml"
refuses listener-from-all "a host's listener names hello.example.test alone" \
  "sed -i 's/          from: Selector/          from: All/' edge/base/gateway.yaml"
refuses listener-wildcard "a host's listener names hello.example.test alone" \
  "sed -i 's/        value: \${HOST}.\${TENANT_APP_DOMAIN}/        value: \"*.\${TENANT_APP_DOMAIN}\"/' \
   edge/app/kustomization.yaml"
refuses listener-other-namespace "a host's listener names hello.example.test alone and admits routes from alpha-hello" \
  "sed -i 's/metadata.name: \${TENANT}-\${APP}/metadata.name: \${TENANT}-other/' edge/base/gateway.yaml"
refuses cert-two-names "certificate names hello.example.test alone" \
  "yq -i '.spec.dnsNames += [\"idm.\${TENANT_DOMAIN}\"]' edge/base/certificate.yaml"
refuses cert-common-name "certificate names hello.example.test alone" \
  "yq -i '.spec.commonName = \"hello.org.test\"' edge/base/certificate.yaml"
refuses cert-unlabelled-secret "into a Secret labelled with tenant alpha" \
  "yq -i 'del(.spec.secretTemplate)' edge/base/certificate.yaml"
refuses route-other-parent "asks alpha-other for" \
  "sed -i 's/    - name: \${TENANT}-\${APP}-\${EDGE}/    - name: \${TENANT}-other/' edge/base/httproute.yaml"
refuses route-other-host ",evil.example.test, which isn't its listener's host" \
  "sed -i 's/    - _\$/&\n    - evil.example.test/' edge/base/httproute.yaml"
refuses app-route-other-app "route alpha-hello/x asks bravo-hello-hello for hello.org.test" \
  "append apps/hello/app/configmap.yaml '---\napiVersion: gateway.networking.k8s.io/v1\nkind: HTTPRoute\nmetadata:
  name: x\nspec:\n  parentRefs:\n    - {name: bravo-hello-hello, namespace: gateway, sectionName: https}
  hostnames: [hello.org.test]\n'"
refuses gateway-in-app "an app's hosts and certificates come from its edges" \
  "append apps/hello/app/configmap.yaml '---\napiVersion: gateway.networking.k8s.io/v1\nkind: Gateway\nmetadata:
  name: x\nspec:\n  gatewayClassName: traefik\n  listeners: []\n'"
refuses gateway-in-platform "hosts come only from tenants' edges" \
  "append platform/reloader/app/kustomization.yaml '  - ./gw.yaml\n'
   append platform/reloader/app/gw.yaml '---\napiVersion: gateway.networking.k8s.io/v1\nkind: Gateway\nmetadata:
  name: x\n  namespace: reloader\nspec:\n  gatewayClassName: traefik\n  listeners: []\n'"
refuses platform-tenantlike-ns "platform namespaces can't be named like a tenant's app" \
  "sed -i 's/NAMESPACE: reloader/NAMESPACE: relod-er/' platform/reloader/ks.yaml"
refuses platform-tenantlike-digit "platform namespaces can't be named like a tenant's app" \
  "sed -i 's/NAMESPACE: reloader/NAMESPACE: relod-9x/' platform/reloader/ks.yaml"

# Quotas.
knob() { yq -i ".spec.postBuild.substitute.$1 = \"$2\"" "$T/bravo/tenant.yaml"; }
refuses quota-below-memory-default "the LimitRange's default.memory, 128Mi, is above the quota's limits.memory, 64Mi" \
  "knob HELLO_QUOTA_MEMORY 64Mi"
refuses quota-below-ephemeral-default \
  "the LimitRange's default.ephemeral-storage, 256Mi, is above the quota's limits.ephemeral-storage, 128Mi" \
  "knob HELLO_QUOTA_EPHEMERAL_STORAGE 128Mi"
refuses quota-below-cpu-default "the LimitRange's defaultRequest.cpu, 10m, is above the quota's requests.cpu, 5m" \
  "knob HELLO_QUOTA_CPU 5m"
refuses knob-number "Flux takes only strings as values to substitute: bravo-hello/QUOTA_MEMORY" \
  "knob HELLO_QUOTA_MEMORY 512"
refuses quota-publishes "has one ResourceQuota, app" \
  "sed -i 's/services.loadbalancers: \"0\"/services.loadbalancers: \"1\"/' components/app/resourcequota.yaml"
refuses quota-no-object-counts "has one ResourceQuota, app" \
  "sed -i '/count\/secrets/d; /count\/configmaps/d' components/app/resourcequota.yaml"
refuses template-without-quota "with APP hello and its quota" \
  "yq -i 'del(select(documentIndex == 0) | .spec.postBuild.substitute.QUOTA_PODS)' apps/hello/ks.yaml"
refuses limitrange-without-default "the LimitRange sets default.ephemeral-storage for containers" \
  "yq -i 'del(.spec.limits[0].default.ephemeral-storage)' components/app/limitrange.yaml"

# Network policies.
refuses no-default-deny "closed in both directions by default" \
  "sed -i '0,/policyTypes: \[Ingress, Egress\]/s//policyTypes: [Ingress]/' components/app/networkpolicies.yaml"
refuses np-all-namespaces "network policies reach only named platform namespaces and tenant alpha's own: x" \
  "np '  egress:\n    - to:\n        - namespaceSelector: {}\n'"
refuses np-other-tenant "network policies reach only named platform namespaces and tenant alpha's own: x" \
  "np '  egress:\n    - to:\n        - namespaceSelector:\n            matchLabels:
              kubernetes.io/metadata.name: bravo-hello\n'"
refuses np-ipblock "network policies reach only named platform namespaces and tenant alpha's own: x" \
  "np '  egress:\n    - to:\n        - ipBlock:\n            cidr: 0.0.0.0/0\n'"
refuses np-egress-all "a network policy rule without peers reaches everything: x" "np '  egress:\n    - {}\n'"
refuses np-egress-ports-only "a network policy rule without peers reaches everything: x" \
  "np '  egress:\n    - ports:\n        - port: 443\n'"
refuses np-ingress-all "a network policy rule without peers reaches everything: x" "np '  ingress:\n    - {}\n'"
refuses np-ingress-ports-only "a network policy rule without peers reaches everything: x" \
  "np '  ingress:\n    - ports:\n        - port: 9898\n'"
refuses np-ingress-empty-from "a network policy rule without peers reaches everything: x" \
  "np '  ingress:\n    - from: []\n'"
refuses np-empty-peer "a network policy rule without peers reaches everything: x" \
  "np '  egress:\n    - to:\n        - {}\n'"
refuses np-edge-ports-only "a network policy rule without peers reaches everything: from-gateway-hello" \
  "yq -i 'del(.spec.ingress[0].from)' edge/base/networkpolicy.yaml"

# Variants that must still render.
renders encrypted "encsecret $T/bravo; encmap clusters/test"
renders own-app-key "append $T/bravo/secrets.yaml '  HELLO_API_KEY: x\n'"
renders real-cluster "prod delta; encsecret clusters/prod/tenants/delta; encmap clusters/prod"
renders test-cluster-renamed \
  "mv clusters/test clusters/ci; sed -i 's|clusters/test|clusters/ci|' clusters/ci/tenants/*/tenant.yaml"
renders identity-host \
  "sed 's/apex/idm/g; s|edge/idm|edge/identity|; s/      EDGE: idm/      EDGE: idm\n      HOST: idm/' \
  apps/hello/edge-apex.yaml >apps/hello/edge-idm.yaml
  sed -i 's|  - ../../../../../apps/hello/edge-apex.yaml|&\n  - ../../../../../apps/hello/edge-idm.yaml|' \
  $T/alpha/apps/kustomization.yaml"
renders two-hosts-in-template "yq ea 'select(documentIndex == 1)' apps/hello/ks.yaml \
  | sed 's/edge-hello/edge-www/; s/EDGE: hello/EDGE: www/; s/HOST: hello/HOST: www/' >www.yaml
  { cat apps/hello/ks.yaml; echo ---; cat www.yaml; } >ks.yaml; mv ks.yaml apps/hello/ks.yaml; rm www.yaml"

wait
cat "$cases"/*/result
! grep -qv '^ok ' "$cases"/*/result
