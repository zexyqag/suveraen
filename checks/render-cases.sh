# Breaks copies of kubernetes/ in ways render.sh must refuse, and checks that it does, each for the intended reason.
# Some variants must still render: encrypted values, a cluster that isn't a test one, a test cluster by another name.
# Usage: render-cases.sh <render.sh> <kubernetes directory> <shard> <shards>: runs every <shards>th case, from the
# <shard>th on, so that the shards share the cases between them.
set -euo pipefail
render=$1
src=$2
shard=$3
shards=$4
cases=$(mktemp -d)
count=0
jobs=${NIX_BUILD_CORES:-1}
[ "$jobs" -gt 0 ] || jobs=$(nproc)
# Each case has a core to itself, and yq and flux start thousands of times for milliseconds each: threads to spread
# over more cores only cost them.
export GOMAXPROCS=1

# Runs a case in the background: a copy of kubernetes/ changed by a shell snippet, then render.sh on it. The snippet
# runs in a shell of its own, as a condition would turn off errexit for every step but the last.
run() {
  local id=$1 expect=$2 change=$3 dir=$cases/$1
  count=$((count + 1))
  [ $(((count - 1) % shards + 1)) = "$shard" ] || return 0
  mkdir -p "$dir"
  cp -r --no-preserve=mode "$src" "$dir/kubernetes"
  while [ "$(jobs -rp | wc -l)" -ge "$jobs" ]; do wait -n || true; done
  (
    cd "$dir/kubernetes"
    if ! bash -euo pipefail -c "$change" >"$dir/log" 2>&1; then
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
encsecret() { # tenant or cluster directory
  mv "$1/secrets.yaml" "$1/secrets.sops.yaml"
  sed -i 's|./secrets.yaml|./secrets.sops.yaml|' "$1/kustomization.yaml"
  yq -i ".stringData[] = \"$encrypted\"" "$1/secrets.sops.yaml"
  append "$1/secrets.sops.yaml" "$sops"
}
encmap() { # cluster directory: its hostname map and its DNS's names for identity hosts
  for map in "$1/hostnames.yaml" "$1/coredns.yaml"; do
    yq -i ".data[] = \"$encrypted\"" "$map"
    append "$map" "$sops"
  done
}
# A second cluster, not a test one, whose only tenant is shaped like alpha; its CAs are trusted publicly.
prod() { # tenant ID
  mkdir -p clusters/prod/tenants
  cp clusters/test/settings.yaml clusters/test/secrets.yaml clusters/test/hostnames.yaml clusters/test/coredns.yaml \
    clusters/prod/
  yq -i '.data.TEST_CLUSTER = "false" | .data.ACME_CA_BUNDLE = "" | .data.BACKUP_1_ENDPOINT = "https://s3.one.test"
    | .data.BACKUP_2_ENDPOINT = "https://s3.two.test"' clusters/prod/settings.yaml
  sed "s|./tenants/alpha|./tenants/$1|; /tenants\/bravo/d" clusters/test/kustomization.yaml \
    >clusters/prod/kustomization.yaml
  cp -r $T/alpha "clusters/prod/tenants/$1"
  sed -i "s/alpha/$1/g; s|clusters/test|clusters/prod|" "clusters/prod/tenants/$1"/*.yaml
}
ids() { # tenant, then keys: a Kanidm ID of its own for each, in the tenant's Secret
  local t=$1 key
  shift
  for key; do
    append "$T/$t/secrets.yaml" "  $key: $(printf %s "$t/$key" | sha256sum \
      | sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12}).*/\1-\2-\3-\4-\5/')\n"
  done
}
other() { # a second app like hello, which bravo also runs, with IDs of its own in Kanidm
  cp -r apps/hello apps/other
  rm apps/other/edge-apex.yaml
  sed -i 's/hello/other/g; s/HELLO/OTHER/g' apps/other/ks.yaml apps/other/*/*.yaml
  ids bravo OTHER_SSO_ID OTHER_USERS_ID OTHER_OIDC_ID
  yq -i '.spec.values.persistence.migrations.sources += [{"configMap": {"name": "sso-other", "optional": true}}]' \
    apps/kanidm/app/helmrelease.yaml
  sed -i 's|  - ../../../../../apps/hello/ks.yaml|&\n  - ../../../../../apps/other/ks.yaml|' \
    $T/bravo/apps/kustomization.yaml
  append $T/bravo/secrets.yaml '  OTHER_DB_PASSWORD: x\n  OTHER_RESTIC_PASSWORD: x\n'
  for n in 1 2; do
    append $T/bravo/secrets.yaml "  OTHER_BACKUP_${n}_ACCESS_KEY_ID: x\n  OTHER_BACKUP_${n}_SECRET_ACCESS_KEY: x\n"
  done
}
knob() { yq -i ".spec.postBuild.substitute.$1 = \"$2\"" "$T/bravo/tenant.yaml"; }
export -f append np encsecret encmap prod ids other knob
export T sops encrypted
keymap='---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: key\ndata:\n  KEY: '

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
refuses other-app-reads-key "kubernetes/apps/other: an app reads only its own keys, not HELLO_API_KEY" \
  "other; append $T/bravo/secrets.yaml '  HELLO_API_KEY: x\n'
   sed -i 's/PODINFO_UI_MESSAGE: .*/PODINFO_UI_MESSAGE: \${HELLO_API_KEY}/' apps/other/app/configmap.yaml"
refuses other-app-includes-key "bravo-other reads HELLO_API_KEY: an app reads only its own keys" \
  "other; append $T/bravo/secrets.yaml '  HELLO_API_KEY: x\n'
   append apps/hello/app/key.yaml '$keymap\${HELLO_API_KEY}\n'
   append apps/other/app/kustomization.yaml '  - ../../hello/app/key.yaml\n'"
refuses edge-reads-key "so they read no app's own keys: HELLO_API_KEY" \
  "sed -i 's/^  name: from-gateway-\${EDGE}\$/&-\${HELLO_API_KEY:=x}/' edge/base/networkpolicy.yaml"
refuses edge-includes-key "bravo-hello-edge-hello reads HELLO_API_KEY: an app reads only its own keys, and a host" \
  "append $T/bravo/secrets.yaml '  HELLO_API_KEY: x\n'
   append apps/hello/app/key.yaml '$keymap\${HELLO_API_KEY:=none}\n'
   append edge/base/kustomization.yaml '  - ../../apps/hello/app/key.yaml\n'"
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
  "rm -r $T/bravo; sed -i '/tenants\/bravo/d' clusters/test/kustomization.yaml
   sed -i '/bravo-kanidm/d' clusters/test/coredns.yaml"
refuses no-test-marker "cluster-settings says whether its tenants are stand-ins" \
  "yq -i 'del(.data.TEST_CLUSTER)' clusters/test/settings.yaml"
refuses marked-real "test: the hostname map links domains to tenants, so it is encrypted" \
  "sed -i 's/TEST_CLUSTER: \"true\"/TEST_CLUSTER: \"false\"/' clusters/test/settings.yaml"
real="prod delta; encsecret clusters/prod/tenants/delta; encmap clusters/prod; encsecret clusters/prod"
refuses real-cluster-plain-map "prod: the hostname map links domains to tenants, so it is encrypted" \
  "prod delta; encsecret clusters/prod/tenants/delta; encsecret clusters/prod"
refuses real-cluster-plain-secret "prod: tenant secrets are encrypted in every value: tenant-delta" \
  "prod delta; encmap clusters/prod; encsecret clusters/prod"
refuses real-cluster-plain-cluster-secrets \
  "prod: the cluster's secrets, its CA accounts, are encrypted in every value" \
  "prod delta; encsecret clusters/prod/tenants/delta; encmap clusters/prod"
untrusted="prod: every ClusterIssuer is an ACME CA the public trust store vouches for"
refuses real-cluster-test-ca "$untrusted: public standby" \
  "$real; yq -i '.data.ACME_CA_BUNDLE = \"eA==\"' clusters/prod/settings.yaml"
refuses real-cluster-skip-verify "$untrusted: standby" \
  "$real; yq -i '.spec.acme.skipTLSVerify = true' platform/issuer/standby/app/standby.yaml"
refuses real-cluster-self-signed "$untrusted: public" \
  "$real; yq -i '.spec = {\"selfSigned\": {}}' platform/issuer/public/app/public.yaml"
refuses real-cluster-other-issuer "$untrusted: x" \
  "$real; append platform/issuer/public/app/public.yaml '---\napiVersion: cert-manager.io/v1\nkind: ClusterIssuer
metadata:\n  name: x\nspec:\n  selfSigned: {}\n'"
refuses no-standby-issuer "test: the cluster has one ClusterIssuer public, which every host's certificate names" \
  "sed -i '/issuer\\/standby\\/ks.yaml/d' clusters/test/kustomization.yaml"
refuses no-public-issuer "test: the cluster has one ClusterIssuer public" \
  "yq -i '.metadata.name = \"primary\"' platform/issuer/public/app/public.yaml"
refuses no-cluster-secrets "substituteFrom names Secret/cluster-secrets, which the cluster doesn't define" \
  "sed -i '/secrets.yaml/d' clusters/test/kustomization.yaml"
refuses settings-differ "the clusters don't set the same settings and secrets" \
  "$real; append clusters/prod/settings.yaml '  EXTRA: x\n'"

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
  "sed -i 's/^  org.test: bravo$/  org.test: alpha/' clusters/test/hostnames.yaml"
refuses map-missing-domain "bravo-hello serves hello.org.test, but the hostname map gives it to nobody" \
  "sed -i '/^  org.test: bravo$/d' clusters/test/hostnames.yaml"
refuses map-carve-out "bravo-hello serves hello.org.test, but the hostname map gives it to alpha" \
  "append clusters/test/hostnames.yaml '  hello.org.test: alpha\n'"
refuses map-suffix "bravo-hello serves hello.org.test, but the hostname map gives it to nobody" \
  "sed -i 's/^  org.test: bravo$/  rg.test: bravo/' clusters/test/hostnames.yaml"
refuses map-other-namespace "alpha-hello serves one.test, but the hostname map gives it to alpha-other" \
  "sed -i 's/one.test: alpha-hello/one.test: alpha-other/' clusters/test/hostnames.yaml"
refuses map-bad-value "the hostname map gives each name to a tenant or one of its namespaces: org.test" \
  "sed -i 's/^  org.test: bravo$/  org.test: Bravo/' clusters/test/hostnames.yaml"
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
refuses app-route-edge-name "two Kustomizations apply the same object: HTTPRoute/alpha-hello/hello" \
  "append apps/hello/app/configmap.yaml '---\napiVersion: gateway.networking.k8s.io/v1\nkind: HTTPRoute\nmetadata:
  name: hello\nspec:\n  parentRefs:\n    - name: \${TENANT}-hello-hello\n      namespace: gateway
      sectionName: https\n  hostnames:\n    - hello.\${TENANT_APP_DOMAIN}\n'"
inapp="in its own namespace:"
refuses gateway-in-app "$inapp Gateway.gateway.networking.k8s.io/x" \
  "append apps/hello/app/configmap.yaml '---\napiVersion: gateway.networking.k8s.io/v1\nkind: Gateway\nmetadata:
  name: x\nspec:\n  gatewayClassName: traefik\n  listeners: []\n'"
refuses cluster-issuer-in-app "$inapp ClusterIssuer.cert-manager.io/x" \
  "append apps/hello/app/configmap.yaml '---\napiVersion: cert-manager.io/v1\nkind: ClusterIssuer\nmetadata:
  name: x\nspec:\n  selfSigned: {}\n'"
refuses certificate-request-in-app "$inapp CertificateRequest.cert-manager.io/x" \
  "append apps/hello/app/configmap.yaml '---\napiVersion: cert-manager.io/v1\nkind: CertificateRequest\nmetadata:
  name: x\nspec:\n  request: eA==\n  issuerRef: {kind: ClusterIssuer, name: public}\n'"
refuses policy-binding-in-app "$inapp ValidatingAdmissionPolicyBinding.admissionregistration.k8s.io/x" \
  "append apps/hello/app/configmap.yaml '---\napiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding\nmetadata:\n  name: x\nspec:\n  policyName: x\n  validationActions: [Audit]\n'"
refuses gateway-in-platform "hosts come only from tenants' edges" \
  "append platform/reloader/app/kustomization.yaml '  - ./gw.yaml\n'
   append platform/reloader/app/gw.yaml '---\napiVersion: gateway.networking.k8s.io/v1\nkind: Gateway\nmetadata:
  name: x\n  namespace: reloader\nspec:\n  gatewayClassName: traefik\n  listeners: []\n'"
refuses platform-tenantlike-ns "platform namespaces can't be named like a tenant's app" \
  "sed -i 's/NAMESPACE: reloader/NAMESPACE: relod-er/' platform/reloader/ks.yaml"
refuses platform-tenantlike-digit "platform namespaces can't be named like a tenant's app" \
  "sed -i 's/NAMESPACE: reloader/NAMESPACE: relod-9x/' platform/reloader/ks.yaml"

# The gateway.
G=platform/gateway/app/helmrelease.yaml
refuses gateway-crd-provider "the gateway takes routes from the Gateway API alone" \
  "yq -i '.spec.values.providers.kubernetesCRD.enabled = true' $G"
everynode="the gateway runs on every node, a DaemonSet that its Service hands the clients reaching that node"
refuses gateway-cluster-policy "$everynode" "yq -i '.spec.values.service.spec.externalTrafficPolicy = \"Cluster\"' $G"
refuses gateway-deployment "$everynode" "yq -i '.spec.values.deployment.kind = \"Deployment\"' $G"
refuses gateway-host-port "$everynode" "yq -i '.spec.values.ports.websecure.hostPort = 443' $G"
logs="the gateway keeps no access log and logs warnings and errors alone"
refuses gateway-access-log "$logs" "yq -i '.spec.values.accessLog.enabled = true' $G"
refuses gateway-log-info "$logs" "yq -i '.spec.values.log.level = \"INFO\"' $G"
chain="on every route the gateway limits each client by its own address, then gives apps its pseudonym"
refuses gateway-middlewares-swapped "$chain" \
  "yq -i '.spec.values.ports.websecure.http.middlewares = [\"pseudonym@file\", \"ratelimit@file\"]' $G"
refuses gateway-no-pseudonym "$chain" "yq -i 'del(.spec.values.ports.websecure.http.middlewares[1])' $G"
trusts="the gateway trusts no address a client names, and takes no arguments of its own for its logs, entry points,"
refuses gateway-trusted-ips "$trusts providers or plugins: ports.websecure" \
  "yq -i '.spec.values.ports.websecure.forwardedHeaders.trustedIPs = [\"10.42.0.0/16\"]' $G"
refuses gateway-log-argument "$trusts providers or plugins: --accesslog=true" \
  "yq -i '.spec.values.additionalArguments = [\"--accesslog=true\"]' $G"
refuses gateway-remote-plugin "the gateway runs no plugin from elsewhere" \
  "yq -i '.spec.values.experimental.plugins.x = {\"moduleName\": \"github.com/example/x\", \"version\": \"v1.0.0\"}' $G"
refuses gateway-plugin-edited "the gateway's pods are annotated suveraen/pseudonym" \
  "echo '// edited' >>platform/gateway/app/pseudonym/pseudonym.go"
refuses gateway-plugin-substituted "ConfigMap gateway/pseudonym holds" \
  "yq -i 'del(.configMapGenerator[0].options.annotations)' platform/gateway/app/kustomization.yaml"
refuses gateway-pseudonym-in-pods "GATEWAY_PSEUDONYM_V4 overlaps POD_CIDR_V4" \
  "yq -i '.data.GATEWAY_PSEUDONYM_V4 = \"10.0.0.0/8\"' clusters/test/settings.yaml"
refuses gateway-pseudonym-64 "and its period whole hours: GATEWAY_PSEUDONYM_V6" \
  "yq -i '.data.GATEWAY_PSEUDONYM_V6 = \"3fff::/64\"' clusters/test/settings.yaml"
refuses passthrough-label "only an app that terminates TLS itself holds a public certificate of its own" \
  "yq -i '.metadata.labels.\"suveraen/passthrough\" = \"true\"' components/app/namespace.yaml"

# Hosts passed through to an app that terminates TLS itself.
E=edge/passthrough
alone="a host passed through has one listener, for TLS to idm.one.test alone"
refuses passthrough-https "$alone" "sed -i 's/      protocol: TLS/      protocol: HTTPS/' $E/gateway.yaml"
refuses passthrough-terminate "$alone" \
  "yq -i '.spec.listeners[0].tls = {\"mode\": \"Terminate\", \"certificateRefs\": [{\"name\": \"tls\"}]}' $E/gateway.yaml"
refuses passthrough-httproute "$alone" "sed -i 's/          - kind: TLSRoute/          - kind: HTTPRoute/' $E/gateway.yaml"
refuses passthrough-certificate "a host passed through is Gateway alpha-kanidm-idm in gateway, and TLSRoute idm" \
  "cp edge/base/certificate.yaml $E/; append $E/kustomization.yaml '  - ./certificate.yaml\n'"
refuses passthrough-for-hello "kubernetes/apps/hello/ks.yaml: a host is \${TENANT}-hello-edge-<EDGE>" \
  "yq -i '(select(documentIndex == 1) | .spec.path) = \"./kubernetes/edge/passthrough\"
   | (select(documentIndex == 1) | .spec.dependsOn) |= map(select(.name != \"issuer\"))' apps/hello/ks.yaml"
refuses tlsroute-other-listener "route alpha-kanidm/idm asks bravo-kanidm-idm for idm.one.test" \
  "sed -i 's/    - name: \${TENANT}-\${APP}-\${EDGE}/    - name: bravo-kanidm-idm/' $E/tlsroute.yaml"
refuses tlsroute-other-host ",evil.one.test, which isn't its listener's host" \
  "sed -i 's/    - \${HOST}.\${TENANT_DOMAIN}\$/&\n    - evil.one.test/' $E/tlsroute.yaml"
refuses tlsroute-terminating-listener "route alpha-kanidm/idm attaches to gateway/https/alpha-kanidm-idm" \
  "sed -i 's/      sectionName: tls/      sectionName: https/' $E/tlsroute.yaml"
own="an app that terminates TLS itself holds one certificate, tls, for the host passed through to it"
refuses passthrough-other-host "$own, login.one.test" \
  "yq -i '(select(documentIndex == 1) | .spec.postBuild.substitute.HOST) = \"login\"' apps/kanidm/ks.yaml"
refuses passthrough-no-certificate "$own" "sed -i '/certificate.yaml/d' components/passthrough/kustomization.yaml"
refuses passthrough-label-value "an app that terminates TLS itself is labelled suveraen/passthrough" \
  "sed -i 's|suveraen/passthrough: \"true\"|suveraen/passthrough: \"yes\"|' components/passthrough/kustomization.yaml"
refuses certificate-in-app "in its own namespace: Certificate.cert-manager.io/x" \
  "append apps/hello/app/configmap.yaml '---\napiVersion: cert-manager.io/v1\nkind: Certificate\nmetadata:\n  name: x
spec:\n  secretName: x\n  dnsNames: [hello.example.test]\n  issuerRef: {kind: ClusterIssuer, name: public}\n'"

# Tenants' Kanidm, and the apps that sign in through it.
S=apps/hello/sso/configmap.yaml
M=apps/kanidm/app/migrations.yaml
I=apps/kanidm/app/helmrelease.yaml
refuses kanidm-image-version "Kanidm runs docker.io/kanidm/server at the version of the Kanidm client the platform" \
  "sed -i 's|tag: 1.11.2@|tag: 1.11.1@|' $I"
config="Kanidm serves the host passed through to it, as its domain and origin"
refuses kanidm-address-info "$config" \
  "sed -i 's|    thread_count = 2|&\n    http_client_address_info.x-forward-for = [\"10.42.0.0/16\"]|' apps/kanidm/app/configmap.yaml"
refuses kanidm-domain "$config" \
  "sed -i 's|    domain = \"\${HOST}.\${TENANT_DOMAIN}\"|    domain = \"\${TENANT_DOMAIN}\"|' apps/kanidm/app/configmap.yaml"
refuses kanidm-migrations-elsewhere "$config" \
  "yq -i '.spec.values.persistence.migrations.globalMounts[0].path = \"/etc/migrations\"' $I"
refuses kanidm-configmaps-quota "the quota's count/configmaps, 3, holds every ConfigMap made in the namespace" \
  "sed -i 's/QUOTA_CONFIGMAPS: \"12\"/QUOTA_CONFIGMAPS: \"3\"/' apps/kanidm/ks.yaml"
refuses sso-other-dependency "an app's sign-in is \${TENANT}-hello-sso from ./kubernetes/apps/hello/sso" \
  "yq -i '(select(documentIndex == 3) | .spec.dependsOn) += [{\"name\": \"\${TENANT}-postgres\"}]' apps/hello/ks.yaml"
refuses sso-elsewhere "an app's sign-in is ConfigMap sso-hello and NetworkPolicy from-hello in alpha-kanidm" \
  "sed -i 's/  namespace: \${TENANT}-kanidm/  namespace: \${TENANT}-hello/' $S"
refuses sso-opens-other-port "an app's sign-in opens Kanidm's port to alpha-hello alone" \
  "sed -i 's/port: 8443/port: 22/' components/sso/networkpolicy.yaml"
refuses sso-not-in-sources "Kanidm reads kanidm-migrations and the sso-<app> of every app with a sign-in" \
  "other; yq -i 'del(.spec.values.persistence.migrations.sources[2])' $I"
refuses sso-without-client "an app that signs in through Kanidm reaches it by components/sso-client" \
  "sed -i '/components\/sso-client/d' apps/hello/ks.yaml"
refuses sso-not-awaited "an app waits for its sign-in, alpha-hello-sso" \
  "yq -i '(select(documentIndex == 0) | .spec.dependsOn) |= map(select(.name != \"\${TENANT}-hello-sso\"))' \
   apps/hello/ks.yaml"
refuses sso-client-without-sign-in "only an app that signs in through Kanidm, with alpha-postgres-sso, reaches it" \
  "sed -i 's|^    - ../../../components/app\$|&\n    - ../../../components/sso-client|' apps/postgres/ks.yaml"
placeholder="an app with a confidential client holds Secret sso, which Flux makes once with client-secret pending alone"
refuses sso-secret-value "$placeholder" "sed -i 's/client-secret: pending/client-secret: x/' components/sso-secret/secret.yaml"
refuses sso-secret-applied "$placeholder" "yq -i 'del(.metadata.annotations)' components/sso-secret/secret.yaml"
refuses sso-public-with-secret "$placeholder" "sed -i 's/oauth2_resource_server_basic/oauth2_resource_server_public/' $S"
refuses sso-confidential-without-secret "$placeholder" "sed -i '/components\/sso-secret/d' apps/hello/ks.yaml"
refuses sso-flag-unknown "sso-hello carries no annotation but" \
  "yq -i '.metadata.annotations.\"suveraen/consent\" = \"true\"' $S"
refuses sso-flag-public "suveraen/localhost-redirects is for a public client" \
  "yq -i '.metadata.annotations.\"suveraen/localhost-redirects\" = \"true\"' $S"
refuses migration-file-name "sso-hello/60-hello.json: an app adds one file, 50-hello.json" \
  "sed -i 's/  50-hello.json: |/  60-hello.json: |/' $S"
refuses migration-not-json "sso-hello/50-hello.json: not JSON" "sed -i 's/\"assertions\": \[/\"assertions\": [,/' $S"
refuses migration-person "never people, accounts of another kind or classes Kanidm sets itself: eve-x" \
  "ids alpha HELLO_EVE_ID; ids bravo HELLO_EVE_ID
   sed -i 's|      \"assertions\": \[|&\n        { \"state\": \"present\", \"id\": \"\${HELLO_EVE_ID}\", \
\"class\": [\"account\", \"person\"], \"name\": \"eve-x\", \"displayname\": \"Eve\" },|' $S"
refuses migration-object-class "classes Kanidm sets itself: hello-users" \
  "sed -i 's|\"class\": \[\"group\"\],|\"class\": [\"group\", \"object\"],|' $S"
uuids="IDs are UUIDs in lowercase from 00000000-0000-0000-0001-000000000000 on, not"
refuses migration-builtin "$uuids 00000000-" \
  "sed -i 's/HELLO_USERS_ID: .*/HELLO_USERS_ID: 00000000-0000-0000-0000-000000000035/' $T/alpha/secrets.yaml"
refuses migration-id-uppercase "$uuids DB77698C-" \
  "sed -i 's/HELLO_USERS_ID: .*/HELLO_USERS_ID: DB77698C-7809-482B-BB76-4537C5FC2B83/' $T/alpha/secrets.yaml"
refuses migration-same-id "ID b9573391-723b-42d6-aaa9-2b674ebb1078 is also kanidm-migrations/10-groups.json" \
  "sed -i 's/HELLO_USERS_ID: .*/HELLO_USERS_ID: b9573391-723b-42d6-aaa9-2b674ebb1078/' $T/alpha/secrets.yaml"
refuses migration-id-twice "ID db77698c-7809-482b-bb76-4537c5fc2b83 is also test/alpha sso-hello/50-hello.json#1" \
  "sed -i 's/HELLO_OIDC_ID: .*/HELLO_OIDC_ID: db77698c-7809-482b-bb76-4537c5fc2b83/' $T/alpha/secrets.yaml"
refuses migration-id-shared "ID db77698c-7809-482b-bb76-4537c5fc2b83 is also test/alpha sso-hello/50-hello.json#1" \
  "sed -i 's/HELLO_USERS_ID: .*/HELLO_USERS_ID: db77698c-7809-482b-bb76-4537c5fc2b83/' $T/bravo/secrets.yaml"
refuses migration-id-missing "test/bravo-hello-sso doesn't render" "sed -i '/HELLO_USERS_ID/d' $T/bravo/secrets.yaml"
secret="an ID past the founding file comes from the tenant's Secret, as"
refuses migration-literal-id "$secret \${HELLO_<NAME>_ID} alone, without a default, so no one in the tenant knows it" \
  "sed -i 's/\${HELLO_USERS_ID}/db77698c-7809-482b-bb76-4537c5fc2b83/' $S"
refuses migration-id-default "Kanidm makes its entry: sso-hello/50-hello.json: \${HELLO_USERS_ID:=db77698c-" \
  "sed -i 's/\${HELLO_USERS_ID}/\${HELLO_USERS_ID:=db77698c-7809-482b-bb76-4537c5fc2b83}/' $S"
refuses migration-id-default-named "Kanidm makes its entry: sso-\${APP}/50-hello.json: \${HELLO_USERS_ID:=db77698c-" \
  "sed -i 's/name: sso-hello/name: sso-\${APP}/' $S
   sed -i 's/\${HELLO_USERS_ID}/\${HELLO_USERS_ID:=db77698c-7809-482b-bb76-4537c5fc2b83}/' $S"
refuses migration-platform-map-named "./kubernetes/apps/kanidm/app holds its migrations in one ConfigMap" \
  "sed -i 's/name: kanidm-migrations/name: \${APP}-migrations/' $M"
refuses migration-name-without-dash "every name but members holds a -, which no login suveraen-idm admin makes does:" \
  "sed -i 's/\"hello-users\"/\"hellousers\"/g' $S"
refuses migration-other-app-group "an app names its groups hello-<name>" "sed -i 's/\"hello-users\"/\"other-users\"/g' $S"
refuses migration-group-unmanaged "tenant-admins manage the members of every group but the admin groups, as a list in" \
  "sed -i '/\"entry_managed_by\": \\[\"tenant-admins\"\\]/d; s/\"name\": \"hello-users\",/\"name\": \"hello-users\"/' $S"
refuses migration-members-managed-elsewhere "tenant-admins manage the members of every group but the admin groups, as a list in Kanidm 1.11: members" \
  "sed -i '0,/\"entry_managed_by\": \\[\"tenant-admins\"\\]/s//\"entry_managed_by\": [\"idm_admins\"]/' $M"
refuses migration-member "groups get their members from admins, not from files: hello-users" \
  "sed -i 's|          \"name\": \"hello-users\"|&,\n          \"member\": [\"admin\"]|' $S"
refuses migration-client-name "an app has one OAuth2 client, hello-oidc" "sed -i 's/\"hello-oidc\"/\"hello-web\"/' $S"
refuses migration-client-displayname "a client has a display name: hello-oidc" \
  "sed -i '/\"displayname\": \"hello\",/d' $S"
refuses migration-legacy-crypto "hello-oidc sets ['oauth2_jwt_legacy_crypto_enable']" \
  "sed -i 's|          \"displayname\": \"hello\",|&\n          \"oauth2_jwt_legacy_crypto_enable\": true,|' $S"
refuses migration-foreign-redirect "a client sends members only to https on its own app hosts, not https://evil." \
  "sed -i 's|https://hello[.]|https://evil.|' $S"
refuses migration-other-scope-group "a client maps members or its own app groups alone" \
  "sed -i 's/{ \"group\": \"hello-users\", \"scopes\"/{ \"group\": \"tenant-admins\", \"scopes\"/' $S"
refuses migration-app-removes "only the platform files remove entries" \
  "sed -i '0,/\"state\": \"present\"/s//\"state\": \"absent\"/' $S"
removed() { # a file of removals in the platform's migrations, from JSON on stdin
  cat >removed.json
  yq -i '.data."90-removed.json" = load_str("removed.json")' apps/kanidm/app/migrations.yaml
  rm removed.json
}
export -f removed
refuses migration-removed-returns "a removed entry never comes back, as Kanidm refuses its ID for good: b11099d7-" \
  "for t in alpha bravo; do
     ids \$t KANIDM_REMOVED_ID
     append $T/\$t/secrets.yaml \"  KANIDM_OLD_ID: \$(yq .stringData.HELLO_OIDC_ID $T/\$t/secrets.yaml)\n\"
   done
   echo '{\"id\": \"\${KANIDM_REMOVED_ID}\",
   \"assertions\": [{\"state\": \"absent\", \"id\": \"\${KANIDM_OLD_ID}\"}]}' | removed"
refuses migration-empty "a migration has an id and assertions, at least one" \
  "ids alpha KANIDM_REMOVED_ID; ids bravo KANIDM_REMOVED_ID
   echo '{\"id\": \"\${KANIDM_REMOVED_ID}\", \"assertions\": []}' | removed"
refuses migration-platform-literal-id "$secret \${KANIDM_<NAME>_ID} alone" \
  "ids alpha KANIDM_RETIRED_ID; ids bravo KANIDM_RETIRED_ID
   echo '{\"id\": \"e0000000-0000-4000-8000-000000000090\",
   \"assertions\": [{\"state\": \"absent\", \"id\": \"\${KANIDM_RETIRED_ID}\"}]}' | removed"
refuses migration-admins-by-name "as a list in Kanidm 1.11: tenant-admins" \
  "sed -i 's/\"entry_managed_by\": \[\"tenant-admins\"\]/\"entry_managed_by\": \"tenant-admins\"/' $M"
refuses migration-platform-admins-own "idm_admins manages platform-admins, and tenant-admins their own" \
  "sed -i 's/\"entry_managed_by\": \[\"idm_admins\"\]/\"entry_managed_by\": [\"platform-admins\"]/' $M"
refuses migration-policy-typo "platform-admins sets ['auth_session_expiry']" \
  "sed -i '0,/\"authsession_expiry\"/s//\"auth_session_expiry\"/' $M"
refuses migration-admins-any-passkey "platform-admins sign in with passkeys of an approved make and model alone" \
  "sed -i 's/\"credential_type_minimum\": \"attested_passkey\"/\"credential_type_minimum\": \"passkey\"/' $M"
dns="the cluster's DNS answers each tenant's identity host with its Kanidm's Service, one line each"
refuses coredns-line-missing "$dns" "sed -i '/bravo-kanidm/d' clusters/test/coredns.yaml"
refuses coredns-line-extra "$dns" \
  "append clusters/test/coredns.yaml '    rewrite name exact hello.org.test kanidm.bravo-kanidm.svc.cluster.local\n'"
refuses coredns-other-tenant "$dns" \
  "sed -i 's/idm.one.test kanidm.alpha-kanidm/idm.one.test kanidm.bravo-kanidm/' clusters/test/coredns.yaml"
refuses coredns-absent "which the cluster's DNS answers from ConfigMap coredns-custom in kube-system" \
  "sed -i '/coredns.yaml/d' clusters/test/kustomization.yaml"
refuses cluster-dir-elsewhere "a cluster directory adds objects to flux-system alone" \
  "append clusters/test/coredns.yaml '---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: x\n  namespace: kube-system\n'"
refuses map-idm-by-tenant "the hostname map gives idm.org.test, passed through to bravo-kanidm, to that namespace by" \
  "sed -i '/idm.org.test: bravo-kanidm/d' clusters/test/hostnames.yaml"
refuses real-cluster-plain-coredns "prod: the cluster's DNS names its tenants' identity hosts, so coredns-custom is" \
  "prod delta; encsecret clusters/prod/tenants/delta; encsecret clusters/prod
   yq -i '.data[] = \"$encrypted\"' clusters/prod/hostnames.yaml; append clusters/prod/hostnames.yaml \"$sops\""

# Quotas.
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
refuses np-edge-ports-only "a network policy rule without peers reaches everything: from-gateway-" \
  "yq -i 'del(.spec.ingress[0].from)' edge/base/networkpolicy.yaml"

# Sources.
refuses helmrepository-source "sources must be pinned to a digest or a commit: HelmRepository/reloader" \
  "append platform/reloader/app/ocirepository.yaml '---\napiVersion: source.toolkit.fluxcd.io/v1\nkind: HelmRepository
metadata:\n  name: reloader\n  namespace: flux-system\nspec:\n  interval: 12h
  url: https://stakater.github.io/stakater-charts\n'"
refuses oci-tag-only "sources must be pinned to a digest or a commit: OCIRepository/reloader" \
  "yq -i 'del(.spec.ref.digest)' platform/reloader/app/ocirepository.yaml"

# Pod Security.
privileged="only rook-ceph, where Ceph runs, is privileged"
refuses privileged-other-namespace "$privileged: reloader" \
  "sed -i 's|    - ../../../components/platform\$|&\n    - ../../../components/privileged|' platform/reloader/ks.yaml"
refuses tenant-namespace-privileged "$privileged: alpha-hello" \
  "sed -i 's|    - ../../../components/app\$|&\n    - ../../../components/privileged|' apps/hello/ks.yaml"

# Ceph.
pools="every Ceph pool keeps 3 copies, needs 2 to write"
P=platform/ceph/app
refuses pool-size-two "$pools" "yq -i '.spec.replicated.size = 2' $P/pools.yaml"
refuses pool-unsafe-replica "$pools" \
  "yq -i '(select(.metadata.name == \"block\") | .spec.replicated.requireSafeReplicaSize) = false' $P/pools.yaml"
refuses pool-min-size-one "$pools" "yq -i '.spec.dataPool.parameters.min_size = \"1\"' $P/objectstore.yaml"
refuses pool-erasure-coded "$pools" \
  "yq -i '.spec.dataPool.erasureCoded = {\"dataChunks\": 2, \"codingChunks\": 1}' $P/objectstore.yaml"
refuses pool-crush-rule-fixed "$pools" "yq -i 'del(.spec.metadataPool.enableCrushUpdates)' $P/objectstore.yaml"
refuses pool-rack "$pools" "yq -i '.spec.failureDomain = \"rack\"' $P/pools.yaml"
refuses pools-mixed-failure-domain "every Ceph pool has the same failure domain" \
  "yq -i '(select(.metadata.name == \"block\") | .spec.failureDomain) = \"host\"' $P/pools.yaml"
capped="each Ceph pool that holds data stops at a whole quota of bytes above zero"
refuses block-quota-missing "$capped: CephBlockPool/block" \
  "yq -i '(select(.metadata.name == \"block\") | .spec) |= del(.quotas)' $P/pools.yaml"
refuses objects-quota-missing "$capped: CephObjectStore/objects/data" \
  "yq -i 'del(.spec.dataPool.quotas)' $P/objectstore.yaml"
refuses quota-not-whole "$capped: CephBlockPool/block" \
  "yq -i '.data.CEPH_BLOCK_QUOTA = \"1.5Ti\"' clusters/test/settings.yaml"
refuses quota-zero "$capped: CephBlockPool/block" "yq -i '.data.CEPH_BLOCK_QUOTA = \"0Gi\"' clusters/test/settings.yaml"
uncapped="and its own pools, the manager's and the object store's metadata, have none"
refuses quota-on-metadata-pool "$uncapped: CephObjectStore/objects/metadata" \
  "yq -i '.spec.metadataPool.quotas.maxSize = \"1Gi\"' $P/objectstore.yaml"
refuses quota-max-bytes "$uncapped: CephBlockPool/block" \
  "yq -i '(select(.metadata.name == \"block\") | .spec.quotas.maxBytes) = 1073741824' $P/pools.yaml"
refuses buckets-over-objects-quota "the object store's quota covers every tenant's bucket, each with a whole size: 2Gi" \
  "knob POSTGRES_BUCKET_SIZE 3G"
refuses quota-warning-missing "Ceph warns before a pool's quota stops its writes" \
  "yq -i 'del(.spec.cephConfig.mgr.mon_pool_quota_warn_threshold)' $P/cluster.yaml"
cc="the CephCluster keeps its state in /var/lib/rook"
refuses osd-unencrypted "$cc" "yq -i '.spec.storage.config.encryptedDevice = \"false\"' $P/cluster.yaml"
refuses osd-device-unencrypted "$cc" \
  "yq -i '.spec.storage.devices[0].config.encryptedDevice = \"false\"' $P/cluster.yaml"
refuses osd-db-mismatch "$cc" \
  "yq -i '.spec.storage.devices[1].config.metadataDevice = \"/dev/disk/by-osd/osd2-db\"' $P/cluster.yaml"
refuses osd-missing-slot "$cc" "yq -i 'del(.spec.storage.devices[5])' $P/cluster.yaml"
refuses osd-partlabel-db "$cc" \
  "sed -i 's|metadataDevice: /dev/disk/by-osd/osd0-db|metadataDevice: /dev/disk/by-partlabel/osd0-db|' $P/cluster.yaml"
refuses osd-all-devices "$cc" "yq -i '.spec.storage.useAllDevices = true' $P/cluster.yaml"
refuses osd-device-filter "$cc" "yq -i '.spec.storage.deviceFilter = \"^sd\"' $P/cluster.yaml"
refuses msgr1-allowed "$cc" "yq -i '.spec.network.connections.requireMsgr2 = false' $P/cluster.yaml"
refuses host-network-plain "$cc" "yq -i '.spec.network.provider = \"host\"' $P/cluster.yaml"
refuses one-monitor "$cc" "yq -i '.spec.mon.count = 1' $P/cluster.yaml"
refuses mons-share-node-with-host-domain "$cc" \
  "yq -i '.data.CEPH_FAILURE_DOMAIN = \"host\"' clusters/test/settings.yaml"
refuses osd-memory-burstable "$cc" "yq -i '.spec.resources.osd.requests.memory = \"512Mi\"' $P/cluster.yaml"
refuses mon-priority "$cc" "yq -i '.spec.priorityClassNames.mon = \"platform\"' $P/cluster.yaml"
refuses osd-priority-default "$cc" "yq -i 'del(.spec.priorityClassNames.osd)' $P/cluster.yaml"
refuses ceph-unsupported "$cc" "yq -i '.spec.cephVersion.allowUnsupported = true' $P/cluster.yaml"
refuses pg-threshold-default "Ceph's autoscaler acts on every change it recommends" \
  "yq -i 'del(.spec.cephConfig.mgr.\"mgr/pg_autoscaler/threshold\")' $P/cluster.yaml"
refuses ceph-prunable "Ceph's objects are never pruned: CephCluster/rook-ceph" \
  "yq -i 'del(.metadata.annotations)' $P/cluster.yaml"
refuses second-ceph-cluster "one CephCluster, rook-ceph/rook-ceph" \
  "yq '.metadata.name = \"other\"' $P/cluster.yaml >$P/other.yaml && append $P/kustomization.yaml '  - ./other.yaml\n'"
classes="storage classes are Ceph's, volumes go with their claims and buckets stay, and none is the default"
refuses storageclass-default "$classes: ceph-block" \
  "yq -i '(select(.metadata.name == \"ceph-block\")
   | .metadata.annotations.\"storageclass.kubernetes.io/is-default-class\") = \"true\"' $P/storageclasses.yaml"
refuses ceph-block-retain "$classes: ceph-block" \
  "yq -i '(select(.metadata.name == \"ceph-block\") | .reclaimPolicy) = \"Retain\"' $P/storageclasses.yaml"
refuses ceph-bucket-delete "$classes: ceph-bucket" \
  "yq -i '(select(.metadata.name == \"ceph-bucket\") | .reclaimPolicy) = \"Delete\"' $P/storageclasses.yaml"
refuses storageclass-local-path "$classes: local" \
  "append $P/storageclasses.yaml '---\napiVersion: storage.k8s.io/v1\nkind: StorageClass\nmetadata:\n  name: local
provisioner: rancher.io/local-path\nreclaimPolicy: Retain\n'"
csi="each CSI driver names the accounts its plugins run as, and each exists, bound to a ClusterRole and to a Role"
D=rook-ceph.rbd.csi.ceph.com
A=rook-ceph-rbd-csi-ceph-com
refuses csi-default-account "$csi in its namespace: $D:rook-ceph/-" \
  "yq -i 'del(.spec.controllerPlugin.serviceAccountName)' $P/csi.yaml"
refuses csi-account-missing "$csi in its namespace: $D:rook-ceph/$A-nodeplugin-sa" \
  "yq -i 'select(.kind != \"ServiceAccount\" or .metadata.name != \"$A-nodeplugin-sa\")' $P/csi-accounts.yaml"
refuses csi-account-unbound "$csi in its namespace: $D:rook-ceph/$A-ctrlplugin-sa" \
  "yq -i 'select(.kind != \"ClusterRoleBinding\" or .metadata.name != \"$A-ctrlplugin-crb\")' $P/csi-accounts.yaml"
refuses csi-role-missing "$csi in its namespace: $D:rook-ceph/$A-nodeplugin-sa" \
  "yq -i 'select(.kind != \"Role\" or .metadata.name != \"$A-nodeplugin-r\")' $P/csi-accounts.yaml"
refuses csi-role-elsewhere "$csi in its namespace: $D:rook-ceph/$A-ctrlplugin-sa" \
  "yq -i '(select(.kind == \"RoleBinding\" or .kind == \"Role\") | select(.metadata.name | test(\"ctrlplugin\"))
   | .metadata.namespace) = \"reloader\"' $P/csi-accounts.yaml"
nodeplugin="each CSI driver's node plugin runs at system-node-critical, which a shutdown stops last"
refuses nodeplugin-default-priority "$nodeplugin: $D" \
  "yq -i '(select(.kind == \"OperatorConfig\") | .spec.driverSpecDefaults.nodePlugin.priorityClassName)
   = \"platform\"' $P/csi.yaml"
refuses nodeplugin-driver-priority "$nodeplugin: $D" \
  "yq -i '(select(.kind == \"Driver\") | .spec.nodePlugin.priorityClassName) = \"platform\"' $P/csi.yaml"
barrier="unmap-barrier in rook-ceph, which holds a shutdown until no volume is mapped, runs the CSI node plugin's image"
refuses barrier-image-stale "$barrier, already on every node that maps volumes, quay.io/cephcsi/cephcsi:v3.18.2@" \
  "sed -i 's/tag: v3.18.1@sha256:/tag: v3.18.2@sha256:/' platform/rook-ceph/app/helmrelease.yaml"
refuses barrier-missing "$barrier" "sed -i '/unmap-barrier.yaml/d' $P/kustomization.yaml"
refuses rook-ceph-partial-labels "$privileged: rook-ceph" \
  "sed -i '/audit: privileged/d' components/privileged/kustomization.yaml"
refuses rook-ceph-baseline "$privileged: rook-ceph" \
  "sed -i 's/warn: privileged/warn: baseline/' components/privileged/kustomization.yaml"

# Databases' platform.
signs="only cloudnative-pg signs certificates for its own names"
refuses private-ca-elsewhere "$signs: reloader" \
  "sed -i 's|    - ../../../components/platform\$|&\n    - ../../../components/private-ca|' platform/reloader/ks.yaml"
refuses private-ca-tenant "$signs: alpha-hello" \
  "sed -i 's|    - ../../../components/app\$|&\n    - ../../../components/private-ca|' apps/hello/ks.yaml"
refuses catalog-image-tag "images are pinned by digest: ghcr.io/cloudnative-pg/postgresql:18" \
  "sed -i 's/@sha256:[0-9a-f]*\$//' platform/pg-catalog/app/catalog.yaml"
refuses ceph-image-tag "images are pinned by digest: quay.io/ceph/ceph:v20.2.4" \
  "sed -i 's/@sha256:[0-9a-f]*\$//' platform/ceph/app/cluster.yaml"
refuses chart-image-tag "images are pinned by digest: v3.18.1" \
  "sed -i 's/tag: v3.18.1@sha256:[0-9a-f]*\$/tag: v3.18.1/' platform/rook-ceph/app/helmrelease.yaml"
refuses chart-image-number "images are pinned by digest: 0.16" \
  "sed -i '0,/tag: 0.16.0@sha256:[0-9a-f]*\$/s//tag: 0.16/' platform/volsync/app/helmrelease.yaml"
refuses cronjob-image-tag "images are pinned by digest: busybox:1" \
  "append platform/reloader/app/helmrelease.yaml '---\napiVersion: batch/v1\nkind: CronJob\nmetadata:\n  name: x
  namespace: reloader\nspec:\n  schedule: \"0 0 * * *\"\n  jobTemplate:\n    spec:\n      template:\n        spec:
          restartPolicy: Never\n          containers:\n            - name: x\n              image: busybox:1\n'"

# Tenants' databases.
C=apps/postgres/cluster/cluster.yaml
pg="a tenant's PostgreSQL is never pruned, has no superuser access"
role="an app's role logs in with its Secret and nothing more"
refuses attachment-without-postgres "nothing is named bravo-postgres-cluster" \
  "sed -i '/apps\/postgres\/ks.yaml/d' $T/bravo/apps/kustomization.yaml
   sed -i '/POSTGRES_/d' $T/bravo/secrets.yaml $T/bravo/tenant.yaml"
refuses attachment-other-dependency "an app's database is \${TENANT}-hello-db" \
  "yq -i '(select(documentIndex == 2) | .spec.dependsOn) += [{\"name\": \"\${TENANT}-postgres\"}]' apps/hello/ks.yaml"
refuses attachment-other-key "kubernetes/apps/other: an app reads only its own keys, not HELLO_DB_PASSWORD" \
  "other; sed -i 's/OTHER_DB_PASSWORD/HELLO_DB_PASSWORD/' apps/other/db/secret.yaml"
refuses role-superuser "$role" "yq -i '(select(.kind == \"DatabaseRole\") | .spec.superuser) = true' components/db/database.yaml"
refuses role-createrole "$role" \
  "yq -i '(select(.kind == \"DatabaseRole\") | .spec.createrole) = true' components/db/database.yaml"
refuses role-in-other-role "$role" \
  "yq -i '(select(.kind == \"DatabaseRole\") | .spec.inRoles) = [\"pg_read_all_data\"]' components/db/database.yaml"
refuses database-other-owner "$role" \
  "yq -i '(select(.kind == \"Database\") | .spec.owner) = \"app\"' components/db/database.yaml"
refuses database-reached-elsewhere "$role" "sed -i 's/name: \${TENANT}-\${APP}\$/name: \${TENANT}-x/' components/db/database.yaml"
refuses db-secret-opaque "$role" "yq -i '.type = \"Opaque\"' apps/hello/db/secret.yaml"
refuses superuser-access "$pg" "yq -i '.spec.enableSuperuserAccess = true' $C"
refuses pg-hba-open "$pg" "yq -i '.spec.postgresql.pg_hba = [\"host all all all scram-sha-256\"]' $C"
refuses pg-ident-other "pg_ident local postgres all;local nobody postgres" \
  "yq -i '.spec.postgresql.pg_ident += [\"local nobody postgres\"]' $C"
refuses cluster-image-name "$pg" "yq -i '.spec.imageName = \"ghcr.io/cloudnative-pg/postgresql:18\"' $C"
refuses cluster-prunable "$pg" "yq -i 'del(.metadata.annotations)' $C"
refuses cluster-local-storage "$pg" "yq -i '.spec.storage.storageClass = \"local-path\"' $C"
refuses server-name-fixed "$pg" "knob POSTGRES_GENERATION g2; sed -i 's/postgres-\${GENERATION}\$/postgres-g1/' $C"
refuses generation-format "generations are g<number>: gen2" "knob POSTGRES_GENERATION gen2"
refuses postgres-quota-small "bravo-postgres's quota, 1Gi, can't hold 1 instances of 1Gi" \
  "knob POSTGRES_QUOTA_MEMORY 1Gi; knob POSTGRES_MEMORY 1Gi"
refuses postgres-quota-three "can't hold 3 instances of 512Mi" "yq -i '.data.PG_INSTANCES = \"3\"' clusters/test/settings.yaml
  knob POSTGRES_QUOTA_MEMORY 2Gi"
refuses postgres-quota-no-check "bravo-postgres's quota, 1100Mi, can't hold 1 instances of 512Mi" \
  "knob POSTGRES_QUOTA_MEMORY 1100Mi"
refuses postgres-jobs-quota "the quota's count/jobs.batch, 8, holds every CronJob's running and kept Jobs" \
  "sed -i 's/QUOTA_JOBS: \"12\"/QUOTA_JOBS: \"8\"/' apps/postgres/ks.yaml"
refuses recovery-same-generation "recovers from an earlier generation than its own, g1" \
  "knob POSTGRES_BOOTSTRAP recovery"
refuses bucket-other-tenant "a tenant's bucket is bravo-postgres" \
  "sed -i 's/bucketName: \${TENANT}-postgres/bucketName: alpha-postgres/' apps/postgres/app/objectbucketclaim.yaml"
refuses barman-offsite "a tenant's bucket is alpha-postgres" \
  "yq -i '.spec.configuration.endpointURL = \"https://s3.example.test\"' apps/postgres/app/objectstore.yaml"
refuses bucket-in-other-app "an app creates only" \
  "append apps/hello/app/configmap.yaml '---\napiVersion: objectbucket.io/v1alpha1\nkind: ObjectBucketClaim
metadata:\n  name: x\nspec:\n  bucketName: x\n  storageClassName: ceph-bucket\n'"
refuses namespace-without-app "labelled suveraen/tier=app, suveraen/tenant=alpha and suveraen/app=" \
  "sed -i '/suveraen\/app: /d' components/app/namespace.yaml"

# Off-site copies.
internet="the network policy internet opens web ports to all but the cluster's own pods, Services and nodes"
refuses internet-other-port "$internet" "sed -i 's/port: 443/port: 22/' components/internet/networkpolicy.yaml"
refuses internet-link-local "$internet" "sed -i '/169.254.0.0/d' components/internet/networkpolicy.yaml"
refuses internet-own-pods "$internet" "sed -i '/POD_CIDR_V6/d' components/internet/networkpolicy.yaml"
refuses internet-for-all "$internet" "yq -i '.spec.podSelector = {}' components/internet/networkpolicy.yaml"
api="the network policy api-server opens the API server on the nodes to CloudNativePG's pods"
refuses api-server-other-port "$api" "sed -i 's/port: 6443/port: 10250/' apps/postgres/app/networkpolicies.yaml"
refuses api-server-all-pods "$api" \
  "yq -i '(select(.metadata.name == \"api-server\") | .spec.podSelector) = {}' apps/postgres/app/networkpolicies.yaml"
refuses api-server-in-app "$api, in a tenant's PostgreSQL alone" \
  "yq 'select(.metadata.name == \"api-server\")' apps/postgres/app/networkpolicies.yaml >apps/hello/app/api.yaml
  append apps/hello/app/kustomization.yaml '  - ./api.yaml\n'"
refuses pod-range-other "test: cluster-settings sets POD_CIDR_V4 to 10.42.0.0/16" \
  "yq -i '.data.POD_CIDR_V4 = \"10.44.0.0/16\"' clusters/test/settings.yaml"
refuses offsite-one-provider "the two providers' endpoints differ" \
  "yq -i '.data.BACKUP_2_ENDPOINT = .data.BACKUP_1_ENDPOINT' clusters/test/settings.yaml"
refuses offsite-plain-http "prod: the providers' endpoints are https" \
  "$real; yq -i '.data.BACKUP_2_ENDPOINT = \"http://s3.two.test\"' clusters/prod/settings.yaml"
checks="runs offsite's pod to check provider"
refuses check-weekly "offsite-check-1 $checks 1 alone" "knob POSTGRES_OFFSITE_CHECK_SCHEDULE_1 '41 1 * * 0'"
K=apps/postgres/check/kustomization.yaml
refuses postgres-check-other-pod "offsite-check-1 $checks 1 alone" \
  "yq -i '.patches += [{\"target\": {\"kind\": \"CronJob\", \"name\": \"offsite-check-1\"},
   \"patch\": \"- op: remove\n  path: /spec/jobTemplate/spec/template/metadata/labels\"}]' $K"
refuses postgres-check-other-args "offsite-check-2 $checks 2 alone" "sed -i 's/args: \[check, \"2\"\]/args: [push]/' $K"
cycle="the checks read every copy back within 1 to 14 days"
refuses check-cycle-zero "$cycle" "knob POSTGRES_OFFSITE_CHECK_CYCLE 0d"
refuses check-cycle-long "$cycle" "knob POSTGRES_OFFSITE_CHECK_CYCLE 15d"
refuses check-cycle-over-lock "$cycle" "knob POSTGRES_OFFSITE_LOCK 10d"
V=apps/hello/app/volsync.yaml
volsync="an app's volume is copied by components/volsync alone, as a user that isn't root"
refuses volsync-other-prefix "copies of hello's volume go to s3:http://s3-1.test/test-" \
  "sed -i 's|volsync/\${APP}|volsync/other|' $V"
refuses volsync-other-bucket "copies of hello's volume go to s3:http://s3-2.test/test-bravo/volsync/hello" \
  "sed -i 's|\${BACKUP_2_BUCKET_PREFIX}\${TENANT}|\${BACKUP_2_BUCKET_PREFIX}alpha|' $V"
refuses volsync-other-key "kubernetes/apps/hello: an app reads only its own keys, not POSTGRES_BACKUP_1_ACCESS_KEY_ID" \
  "sed -i 's/HELLO_BACKUP_1_ACCESS_KEY_ID/POSTGRES_BACKUP_1_ACCESS_KEY_ID/' $V"
refuses volsync-root-mover "$volsync" "sed -i 's/runAsNonRoot: true/runAsNonRoot: false/' components/volsync/kustomization.yaml"
refuses volsync-other-source "$volsync" \
  "yq -i '(select(.kind == \"ReplicationSource\") | .spec.sourcePVC) = \"other\"' components/volsync/volume.yaml"
refuses volsync-restore-elsewhere "$volsync" "knob HELLO_DATA_RESTORE_FROM volsync-1"
refuses volsync-restore-keeps-files "$volsync" \
  "yq -i '(select(.kind == \"ReplicationDestination\") | .spec.restic.enableFileDeletion) = false' \
  components/volsync/volume.yaml"
refuses volume-unlabelled "an app's volumes say how they are backed up (suveraen/backup) and are never pruned: data" \
  "yq -i '(select(.kind == \"PersistentVolumeClaim\") | .metadata.labels) = {}' components/volsync/volume.yaml"
refuses volume-prunable "an app's volumes say how they are backed up (suveraen/backup) and are never pruned: data" \
  "yq -i '(select(.kind == \"PersistentVolumeClaim\") | .metadata.annotations) = {}' components/volsync/volume.yaml"
refuses volsync-privileged "VolSync's movers run as the app's user, never privileged" \
  "yq -i '.metadata.annotations.\"volsync.backube/privileged-movers\" = \"true\"' components/app/namespace.yaml"
copies="checks the copies at provider"
refuses volsync-check-locks "an app's copies are checked without restic's lock" \
  "sed -i 's/ --no-lock//' components/volsync/kustomization.yaml"
refuses volsync-check-configmap "offsite-check-1 $copies 1 alone" \
  "yq -i '(select(.metadata.name == \"offsite-check-1\") | .spec.jobTemplate.spec.template.spec.volumes)
   = [{\"name\": \"scripts\", \"configMap\": {\"name\": \"x\"}}]' components/volsync/check.yaml"
refuses volsync-check-other-image "offsite-check-1 $copies 1 alone" \
  "sed -i 's|image: quay.io/backube/volsync:.*|image: quay.io/backube/volsync:0.15.0@sha256:$(printf %064d 0)|' \
  components/volsync/kustomization.yaml"
refuses volsync-check-other-secret "offsite-check-2 $copies 2 alone" \
  "yq -i '(select(.metadata.name == \"offsite-check-2\") | .spec.jobTemplate.spec.template.spec.containers[0]
   | .envFrom[0].secretRef.name) = \"offsite-1\"' components/volsync/check.yaml"
refuses volsync-check-cycle-long "offsite-check-1 $copies 1 alone" "knob HELLO_DATA_CHECK_CYCLE 15d"
refuses volsync-check-missing "and it has no others: offsite-check-1" \
  "yq -i 'select(.metadata.name != \"offsite-check-2\")' components/volsync/check.yaml"
cronjob='---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: x
spec:
  schedule: 0 0 * * *
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: x
              image: busybox:1
'
refuses app-other-cronjob "and it has no others: offsite-check-1,offsite-check-2,x" \
  "append apps/hello/app/configmap.yaml '$cronjob'"
refuses cronjob-without-copies "an app's CronJobs only check its copies: x" \
  "sed -i '/components\/volsync/d' apps/hello/ks.yaml; append apps/hello/app/configmap.yaml '$cronjob'"
refuses hello-jobs-quota "the quota's count/jobs.batch, 6, holds every CronJob's running and kept Jobs" \
  "sed -i 's/QUOTA_JOBS: \"7\"/QUOTA_JOBS: \"6\"/' apps/hello/ks.yaml"
age="backups say how old they may get, in minutes, hours or days (suveraen/max-age)"
refuses max-age-number "Flux takes only strings as values to substitute: bravo-postgres/OFFSITE_MAX_AGE" \
  "knob POSTGRES_OFFSITE_MAX_AGE 90"
refuses max-age-weeks "bravo-postgres: $age: ObjectStore/postgres" "knob POSTGRES_BASE_MAX_AGE 2w"
refuses max-age-missing "$age: ReplicationSource/data-2" \
  "yq -i '(select(.metadata.name == \"data-2\") | .metadata) |= del(.annotations)' components/volsync/volume.yaml"

# A tenant's mesh.
N=apps/netbird/app/configmap.yaml
H=apps/netbird/app/helmrelease.yaml
refuses mesh-default-policy "management.json DisableDefaultPolicy" \
  "sed -i 's/\"DisableDefaultPolicy\": true/\"DisableDefaultPolicy\": false/' $N"
refuses mesh-embedded-idp "management.json EmbeddedIdP" \
  "sed -i 's/^      \"DisableDefaultPolicy\": true$/      \"EmbeddedIdP\": { \"Enabled\": true },\n&/' $N"
refuses mesh-scopes "management.json Scope" "sed -i 's/\"Scope\": \"openid\"/\"Scope\": \"openid profile email\"/' $N"
refuses mesh-silent-sign-in "management.json DisablePromptLogin" \
  "sed -i 's/\"UseIDToken\": false/\"UseIDToken\": false,\n          \"DisablePromptLogin\": true/' $N"
refuses mesh-template-unset "management.json {{ .NB_STORE_KEYS }} not from Secret netbird" \
  "sed -i 's/{{ .NB_STORE_KEY }}/{{ .NB_STORE_KEYS }}/' $N"
refuses mesh-proxy-service "nginx.conf location /management.ProxyService/" \
  "sed -i 's|^        location /api/ {\$|        location /management.ProxyService/ {\n          grpc_pass \
grpc://netbird-management:8081;\n        }\n&|' $N"
refuses mesh-setup-open "nginx.conf = /api/setup not refused" "sed -i '/location = \\/api\\/setup/d' $N"
refuses mesh-setup-prefix "nginx.conf location /api/setup;" "sed -i 's|location = /api/setup|location /api/setup|' $N"
refuses mesh-daemonized "nginx.conf without daemon off" "sed -i '/^    daemon off;\$/d' $N"
refuses mesh-no-error-page "nginx.conf without error_page 404 /404.html" "sed -i '/error_page 404/d' $N"
refuses mesh-forwarded "nginx.conf /relay keeps X-Real-IP" "sed -i '0,/proxy_set_header X-Real-IP \"\";/{//d}' $N"
refuses mesh-geolocation "management env NB_DISABLE_GEOLOCATION" \
  "yq -i '.spec.values.controllers.management.containers.management.env.NB_DISABLE_GEOLOCATION = \"false\"' $H"
refuses mesh-events "management env NB_EVENT_ACTIVITY_LOG_ENABLED" \
  "yq -i '.spec.values.controllers.management.containers.management.env.NB_EVENT_ACTIVITY_LOG_ENABLED = \"true\"' $H"
refuses mesh-relay-info "relay log level ['info']" "sed -i 's/--log-level=warn/--log-level=info/' $H"
refuses mesh-management-debug "management log level ['debug']" \
  "sed -i 's/^              - --log-level=info\$/              - --log-level=debug/' $H"
refuses mesh-phone-home "management hostAliases" \
  "yq -i 'del(.spec.values.controllers.management.pod.hostAliases[0].hostnames[0])' $H"
refuses mesh-image-version "signal image ghcr.io/netbirdio/signal:0.81.5@" \
  "sed -i '0,/tag: 0.82.0@/s//tag: 0.81.5@/' $H"
refuses mesh-management-root "management runAsUser and runAsGroup" \
  "yq -i 'del(.spec.values.controllers.management.containers.management.securityContext.runAsUser)' $H"
refuses mesh-rollback "an upgrade that fails is rolled back" \
  "yq -i '.spec.upgrade.remediation.strategy = \"rollback\"' $H"
refuses mesh-ephemeral-quota "the quota holds every pod the app's charts run at once" \
  "yq -i '.spec.postBuild.substitute.NETBIRD_QUOTA_EPHEMERAL_STORAGE = \"512Mi\"' $T/alpha/tenant.yaml"
refuses mesh-internet "network policies ['default-deny', 'dns', 'internet'," \
  "sed -i 's|^    - ../../../components/passthrough-app\$|&\n    - ../../../components/internet|' apps/netbird/ks.yaml"
refuses mesh-edge-reaches-backends "to-kanidm for more than management" "yq -i 'del(.patches)' apps/netbird/app/kustomization.yaml"
refuses mesh-extra-container "controllers {" \
  "yq -i '.spec.values.controllers.management.initContainers.x = .spec.values.controllers.netbird.initContainers[\"web-env\"]' $H"
refuses mesh-rolling-update "management is not one pod that goes before the next starts" \
  "yq -i '.spec.values.controllers.management.strategy = \"RollingUpdate\"
   | .spec.values.controllers.management.rollingUpdate.surge = 0' $H"
refuses mesh-env-from "management envFrom" \
  "yq -i '.spec.values.controllers.management.containers.management.envFrom = [{\"secretRef\": {\"name\": \"netbird\"}}]' $H"
refuses mesh-metrics "management without --disable-anonymous-metrics" "sed -i '/--disable-anonymous-metrics/d' $H"
refuses mesh-relay-exposed "relay exposed elsewhere" \
  "sed -i 's|--exposed-address=rels://\${HOST}.\${TENANT_APP_DOMAIN}:443|--exposed-address=rels://relay.example.test:443|' $H"
refuses mesh-oidc-elsewhere "management.json OIDCConfigEndpoint" \
  "sed -i 's|https://idm.\${TENANT_DOMAIN}/oauth2/openid/netbird-oidc/.well-known|https://idm.example.test/oauth2/openid/netbird-oidc/.well-known|' $N"
refuses mesh-client-secret "management.json ClientSecret" \
  "sed -i 's/\"ClientID\": \"netbird-oidc\",/&\n          \"ClientSecret\": \"x\",/' $N"
refuses mesh-redirect-elsewhere "management.json RedirectURLs" \
  "sed -i 's|\"http://localhost:54000/\"\]|\"http://localhost:54000/\", \"https://example.test/\"]|' $N"
refuses mesh-idp-manager "management.json ManagerType" "sed -i 's/\"ManagerType\": \"none\"/\"ManagerType\": \"keycloak\"/' $N"
refuses mesh-device-flow "management.json DeviceAuthorizationFlow" \
  "sed -i 's/\"Provider\": \"none\"/\"Provider\": \"hosted\"/' $N"
refuses mesh-trusted-peers "management.json TrustedPeers" \
  "sed -i 's|\"TrustedPeers\": \[\"192.0.2.0/32\"\]|\"TrustedPeers\": []|' $N"
refuses mesh-signal-elsewhere "management.json Signal" \
  "sed -i 's|\"URI\": \"\${HOST}.\${TENANT_APP_DOMAIN}:443\"|\"URI\": \"signal.example.test:443\"|' $N"
refuses mesh-relay-elsewhere "management.json Relay" \
  "sed -i 's|\"rels://\${HOST}.\${TENANT_APP_DOMAIN}:443\"|\"rels://relay.example.test:443\"|' $N"
refuses mesh-stun-elsewhere "management.json Stuns" \
  "sed -i 's|stun:\${HOST}.\${TENANT_APP_DOMAIN}:\${STUN_PORT}|stun:stun.example.test:3478|' $N"
refuses mesh-access-log "nginx.conf logs access" "sed -i 's|^      access_log off;\$|      access_log /dev/stdout;|' $N"
refuses mesh-csp-host "nginx.conf CSP names ['https://cdn.example.test'," \
  "sed -i \"s|connect-src 'self' |connect-src 'self' https://cdn.example.test |\" $N"
refuses mesh-dashboard-proxied "nginx.conf / is not the dashboard alone" \
  "sed -i 's|^          root /web;\$|          proxy_pass http://example.test;|' $N"
refuses mesh-api-elsewhere "nginx.conf /api/ not routed to http://netbird-management:8081 alone" \
  "sed -i 's|^          proxy_pass http://netbird-management:8081;\$|          proxy_pass http://example.test;|' $N"
refuses passthrough-app-for-hello "kubernetes/apps/hello/ks.yaml: a host is \${TENANT}-hello-edge-<EDGE>" \
  "yq -i '(select(documentIndex == 1) | .spec.path) = \"./kubernetes/edge/passthrough-app\"
   | (select(documentIndex == 1) | .spec.dependsOn) |= map(select(.name != \"issuer\"))' apps/hello/ks.yaml"
refuses real-cluster-public-ca "prod: the public issuer's certificates chain to roots the images hold" \
  "$real; yq -i '.data.PUBLIC_CA_BUNDLE = \"eA==\"' clusters/prod/settings.yaml"
refuses mesh-group-session "netbird-users sets ['authsession_expiry']" \
  "sed -i 's/^          \"credential_type_minimum\": \"passkey\",\$/&\n          \"authsession_expiry\": 3600,/' \
  apps/netbird/sso/configmap.yaml"
refuses mesh-group-any-credential "an app group that is an account policy has its members enrol passkeys alone" \
  "sed -i 's/\"credential_type_minimum\": \"passkey\"/\"credential_type_minimum\": \"any\"/' \
  apps/netbird/sso/configmap.yaml"
refuses mesh-group-unmanaged "as a list in Kanidm 1.11: netbird-users" \
  "sed -i '/\"entry_managed_by\": \[\"tenant-admins\"\]\$/d; s/\"credential_type_minimum\": \"passkey\",/\"credential_type_minimum\": \"passkey\"/' \
  apps/netbird/sso/configmap.yaml"
refuses mesh-scrub-image "scrub image ghcr.io/cloudnative-pg/postgresql:18.6-202610190957-standard-trixie@" \
  "sed -i 's/minimal-trixie@sha256:/standard-trixie@sha256:/' $H"
refuses mesh-scrub-columns "scrub.sql blanks [{" "sed -i 's/, \"meta_certificates\": \[\]//' $N"
refuses mesh-scrub-password-argv "scrub puts PGPASSWORD in its command line" \
  "sed -i 's/ON_ERROR_STOP=1 -f - &\$/ON_ERROR_STOP=1 -d \"password=\$PGPASSWORD\" -f - \&/' $H"

# Variants that must still render.
renders encrypted "encsecret $T/bravo; encmap clusters/test"
renders encrypted-tenants "encsecret $T/alpha; encsecret $T/bravo; encmap clusters/test"
renders own-app-key "append $T/bravo/secrets.yaml '  HELLO_API_KEY: x\n'
  sed -i 's/PODINFO_UI_MESSAGE: .*/PODINFO_UI_MESSAGE: \${HELLO_API_KEY:=none}/' apps/hello/app/configmap.yaml"
renders two-apps "other"
renders sso-public "sed -i 's/oauth2_resource_server_basic/oauth2_resource_server_public/' $S
  yq -i '.metadata.annotations.\"suveraen/localhost-redirects\" = \"true\"' $S
  sed -i '/components\/sso-secret/d' apps/hello/ks.yaml"
renders sso-without-pkce "yq -i '.metadata.annotations.\"suveraen/disable-pkce\" = \"true\"' $S"
renders migration-removed "ids alpha KANIDM_REMOVED_ID KANIDM_RETIRED_ID; ids bravo KANIDM_REMOVED_ID KANIDM_RETIRED_ID
  echo '{\"id\": \"\${KANIDM_REMOVED_ID}\",
  \"assertions\": [{\"state\": \"absent\", \"id\": \"\${KANIDM_RETIRED_ID}\"}]}' | removed"
renders real-cluster "$real"
renders recovery "knob POSTGRES_GENERATION g2; knob POSTGRES_BOOTSTRAP recovery"
renders recovery-offsite "knob POSTGRES_GENERATION g2; knob POSTGRES_BOOTSTRAP recovery; knob POSTGRES_RESTORE_FROM offsite-2"
renders volume-restore-offsite-2 "knob HELLO_DATA_RESTORE again; knob HELLO_DATA_RESTORE_FROM offsite-2"
renders volume-copied-daily "knob HELLO_DATA_SCHEDULE_1 '17 3 * * *'; knob HELLO_DATA_SCHEDULE_2 '47 3 * * *'
  knob HELLO_DATA_MAX_AGE 26h"
renders failure-domain-host "yq -i '.data.CEPH_FAILURE_DOMAIN = \"host\" | .data.CEPH_DAEMONS_SHARE_NODE = \"false\"
  | .data.CEPH_MGR_COUNT = \"2\" | .data.CEPH_RGW_INSTANCES = \"2\" | .data.PG_INSTANCES = \"3\"' clusters/test/settings.yaml"
renders failover "sed -i 's|issuer/public/ks.yaml|issuer/failover/ks.yaml|' clusters/test/kustomization.yaml"
renders real-cluster-failover \
  "$real; sed -i 's|issuer/public/ks.yaml|issuer/failover/ks.yaml|' clusters/prod/kustomization.yaml"
renders test-cluster-renamed \
  "mv clusters/test clusters/ci; sed -i 's|clusters/test|clusters/ci|' clusters/ci/tenants/*/tenant.yaml"
renders identity-host \
  "sed 's/apex/www/g; s|edge/www|edge/identity|; s/      EDGE: www/      EDGE: www\n      HOST: www/' \
  apps/hello/edge-apex.yaml >apps/hello/edge-www.yaml
  sed -i 's|  - ../../../../../apps/hello/edge-apex.yaml|&\n  - ../../../../../apps/hello/edge-www.yaml|' \
  $T/alpha/apps/kustomization.yaml"
renders two-hosts-in-template "yq ea 'select(documentIndex == 1)' apps/hello/ks.yaml \
  | sed 's/edge-hello/edge-www/; s/EDGE: hello/EDGE: www/; s/HOST: hello/HOST: www/' >www.yaml
  { cat apps/hello/ks.yaml; echo ---; cat www.yaml; } >ks.yaml; mv ks.yaml apps/hello/ks.yaml; rm www.yaml"

wait
# A case whose runner died before it judged the case, for want of disk say, fails too.
for dir in "$cases"/*/; do
  [ -e "$dir/result" ] || echo "NO RESULT   $(basename "$dir")" >"$dir/result"
done
cat "$cases"/*/result
! grep -qv '^ok ' "$cases"/*/result
