# Renders every Flux Kustomization of every cluster under kubernetes/clusters the way Flux would, offline, also those
# other Kustomizations create: the cluster's, each tenant's, then the tenant's apps and hosts. Each gets the values
# its own sources hold, a stand-in for each encrypted one, and strict substitution. Then checks the rules Flux itself
# wouldn't catch, on what was rendered rather than on what a file says.
# Usage: CLUSTER_RANGES=<the servers' ranges> KANIDM_VERSION=<the Kanidm client's version> \
#   render.sh <kubernetes directory> <output directory>
set -euo pipefail
: "${CLUSTER_RANGES:?the ranges the servers give k3s (nixos/cluster.nix), as <setting>=<range> words}"
: "${KANIDM_VERSION:?the version of the Kanidm client the platform builds, which the Kanidm server must match}"
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
# One minute of one hour, every day.
daily='^[0-5]?[0-9] ([01]?[0-9]|2[0-3]) [*] [*] [*]$'
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
# Copies of an app's volume and their checks (components/volsync).
appkinds+=',ReplicationSource.volsync.backube,ReplicationDestination.volsync.backube,CronJob.batch'
# The tenant's PostgreSQL also claims its bucket, tells Barman where to archive and fetches a copy back.
pgkinds=',ObjectBucketClaim.objectbucket.io,ObjectStore.barmancloud.cnpg.io,Job.batch'
export quotas hard appkinds
privileged=pod-security.kubernetes.io/audit=privileged,pod-security.kubernetes.io/enforce=privileged
privileged+=,pod-security.kubernetes.io/warn=privileged
# Apps that terminate their users' TLS themselves, behind a listener that passes it through (edge/passthrough), which
# skips the gateway's limits and pseudonyms, as it reads no request: an identity server, which must see its users'
# passwords and passkeys where nothing else does.
passthroughapps=kanidm
# Traefik's options that could log or trust clients' addresses, or bypass the gateway's own settings for them.
options='(?i)^--?(accesslog|log|entrypoints|forwardedheaders|proxyprotocol|experimental|providers)([.=]|$)'
export options
# Prints each of the gateway's settings in cluster-settings (JSON on stdin) that the plugin or Traefik won't take.
gatewaysettings='
import ipaddress, json, re, sys
s = json.load(sys.stdin)
for v, longest in (4, 8), (6, 48):
    key = f"GATEWAY_PSEUDONYM_V{v}"
    try:
        net = ipaddress.ip_network(s.get(key, ""))
    except ValueError:
        net = None
    if net is None or net.version != v or net.prefixlen > longest:
        print(key)
        continue
    for kind in "POD", "SERVICE", "NODE":
        try:
            if net.overlaps(ipaddress.ip_network(s.get(f"{kind}_CIDR_V{v}", ""), strict=False)):
                print(f"{key} overlaps {kind}_CIDR_V{v}")
        except ValueError:
            print(f"{kind}_CIDR_V{v}")
for key, form in ("GATEWAY_RATE_AVERAGE", "[1-9][0-9]*"), ("GATEWAY_RATE_BURST", "[1-9][0-9]*"), \
        ("GATEWAY_PSEUDONYM_PERIOD", "[1-9][0-9]*h"):
    if not re.fullmatch(form, s.get(key, "")):
        print(key)
'
# Fails unless the one ConfigMap (a JSON list on stdin) holds the plugin's files in the directory given, byte for
# byte, and Flux substitutes nothing in them.
sameplugin='
import json, os, sys
maps = json.load(sys.stdin)
files = [".traefik.yml", "pseudonym.go"]
assert len(maps) == 1 and "binaryData" not in maps[0], maps
assert maps[0]["metadata"].get("annotations", {}).get("kustomize.toolkit.fluxcd.io/substitute") == "disabled"
data = maps[0].get("data", {})
assert sorted(data) == files, sorted(data)
for f in files:
    with open(os.path.join(sys.argv[1], f), "rb") as source:
        assert data[f].encode() == source.read(), f
'
# Prints the settings of Kanidm's server.toml that are wrong for the host given, from the rendered app (a JSON list on
# stdin).
kanidmconfig='
import json, sys, tomllib
docs = [d for d in json.load(sys.stdin) if isinstance(d, dict)]
host = sys.argv[1]
config = [d for d in docs if d.get("kind") == "ConfigMap" and d["metadata"]["name"] == "kanidm"]
release = [d for d in docs if d.get("kind") == "HelmRelease"]
c = tomllib.loads(config[0].get("data", {}).get("server.toml", "")) if len(config) == 1 else {}
mounts = release[0]["spec"]["values"]["persistence"]["migrations"].get("globalMounts", []) if release else []
bad = [k for k in ("ldapbindaddress", "http_client_address_info", "ldap_client_address_info", "replication",
                   "log_level", "otel_grpc_endpoint") if k in c]
bad += [k for k, v in (("domain", host), ("origin", "https://" + host)) if c.get(k) != v]
if [m.get("path") for m in mounts] != [c.get("migration_path")]:
    bad.append("migration_path")
print(" ".join(bad))
'
# One line of JSON for each source of a tenant's Kanidm migrations: its ConfigMap, and for an app the hosts its
# listeners name and its Secret sso, in files named by the arguments after the cluster, tenant, source and app.
migrationsource='
import json, sys
cluster, tenant, source, app, configmap, hosts, secrets = sys.argv[1:]
cm = json.load(open(configmap))
print(json.dumps({"cluster": cluster, "tenant": tenant, "source": source, "app": app, "files": cm.get("data") or {},
                  "annotations": (cm.get("metadata") or {}).get("annotations") or {},
                  "hosts": json.load(open(hosts)), "secrets": json.load(open(secrets))}))
'
# Prints each ID of the migrations in a ConfigMap as Flux builds it before it substitutes anything (JSON on stdin) that
# isn't ${<APP>_<NAME>_ID} alone, for the app's prefix given, but in the founding file, which a tenant's Kanidm applies
# as it first starts, before it takes a sign-in, after "bad "; and after "key " each key the others take. A tenant
# admin may make a person with any ID, so every other ID comes from the tenant's Secret, which no one there reads, and
# has no default, which would be the same in every tenant.
sourceids='
import json, re, sys
cm, prefix = json.load(sys.stdin), sys.argv[1]
key = re.compile(r"[$][{](" + prefix + r"_[A-Z0-9_]+_ID)[}]")
for name, text in sorted((cm.get("data") or {}).items()):
    where = cm["metadata"]["name"] + "/" + name
    if where == "kanidm-migrations/10-groups.json":
        continue
    try:
        m = json.loads(text)
    except ValueError:
        continue
    if not isinstance(m, dict):
        continue
    assertions = m.get("assertions") if isinstance(m.get("assertions"), list) else []
    for a in [m] + [a for a in assertions if isinstance(a, dict)]:
        i = a.get("id")
        k = key.fullmatch(i) if isinstance(i, str) else None
        print(f"key {k.group(1)}" if k else f"bad {where}: {i}")
'
# Prints what is wrong with the migrations every tenant's Kanidm applies (JSON lines from migrationsource on stdin).
# Kanidm applies each file in its own transaction and only logs what fails, so render refuses what it would skip.
migrations='
import json, re, sys
from urllib.parse import urlsplit
uuid = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
# Kanidm makes its builtin entries below this, out of reach of migrations, which skip them without a word.
dynamic = "00000000-0000-0000-0001-000000000000"
basic = ["account", "oauth2_resource_server", "oauth2_resource_server_basic"]
public = ["account", "oauth2_resource_server", "oauth2_resource_server_public"]
clientkeys = {"state", "id", "class", "name", "displayname", "description", "oauth2_rs_origin",
              "oauth2_rs_origin_landing", "oauth2_rs_scope_map", "oauth2_rs_sup_scope_map", "oauth2_rs_claim_map",
              "oauth2_prefer_short_username", "oauth2_consent_prompt_enable"}
policykeys = {"credential_type_minimum", "authsession_expiry", "privilege_expiry", "entry_managed_by"}
# Nested in idm_admins, a group takes members only from its manager, so idm_admins manages platform-admins. tenant-admins
# manage every other group the files declare, which lets them change its members alone, never rename or delete it.
managers = {"platform-admins": ["idm_admins"], "tenant-admins": ["tenant-admins"]}
# What no migration can set on a client: a confidential one that sends no PKCE, a public one that redirects to the
# device it runs on.
flags = {"suveraen/disable-pkce": basic, "suveraen/localhost-redirects": public}
kinds = {"suveraen/disable-pkce": "confidential", "suveraen/localhost-redirects": "public"}
placeholder = {"annotations": {"kustomize.toolkit.fluxcd.io/ssa": "IfNotPresent"},
               "stringData": {"client-secret": "pending"}}
problems, ids, names, present, absent = [], {}, {}, set(), {}

def bad(where, what):
    if f"{where}: {what}" not in problems:
        problems.append(f"{where}: {what}")

def claim(table, key, owner, where, what):
    if table.setdefault(key, owner) != owner:
        bad(where, f"{what} {key} is also {table[key]}")

def url(where, value, hosts):
    parts = urlsplit(value) if isinstance(value, str) else None
    if parts is None or parts.scheme != "https" or parts.hostname not in {h.lower() for h in hosts} or parts.port \
            or parts.username:
        bad(where, f"a client sends members only to https on its own app hosts, not {value}")

for line in sys.stdin:
    s = json.loads(line)
    app, source, tenant = s["app"], s["source"], s["cluster"] + "/" + s["tenant"]
    # A file names, besides its own entries, only members and tenant-admins, which every tenant holds from the start,
    # and the builtin idm_admins: Kanidm looks a name up among its entries before those of the file, so a name the
    # platform holds nowhere yet could be held by a person a tenant admin made, who would then manage the group or get
    # the scopes of the client.
    groups = {"members"} if source != "kanidm-migrations" else set()
    clients = []
    for key, text in sorted(s["files"].items()):
        where = f"{tenant} {source}/{key}"
        own = f"{source}/{key}"
        if source == "kanidm-migrations":
            if not re.fullmatch(r"[0-9]{2}-[a-z0-9-]+[.]json", key):
                bad(where, "files are named NN-<name>.json")
        elif key != f"50-{app}.json":
            bad(where, f"an app adds one file, 50-{app}.json")
        try:
            m = json.loads(text)
        except ValueError as e:
            bad(where, f"not JSON: {e}")
            continue
        if not isinstance(m, dict) or sorted(m) != ["assertions", "id"] or not isinstance(m["assertions"], list) \
                or not m["assertions"] or not all(isinstance(a, dict) for a in m["assertions"]):
            bad(where, "a migration has an id and assertions, at least one, as Kanidm refuses an empty one")
            continue
        # The IDs of the founding file are the same in every tenant, all others differ from tenant to tenant.
        founding = source == "kanidm-migrations" and key == "10-groups.json"
        for n, a in enumerate([m] + m["assertions"]):
            i = a.get("id")
            if not isinstance(i, str) or not uuid.fullmatch(i) or i < dynamic:
                bad(where, f"IDs are UUIDs in lowercase from {dynamic} on, not {i}")
            else:
                claim(ids, i, f"{own}#{n}" if founding else f"{tenant} {own}#{n}", where, "ID")
        states = {a.get("state") for a in m["assertions"]}
        if "absent" in states:
            if source != "kanidm-migrations" or states != {"absent"}:
                bad(where, "only the platform files remove entries, in files of removals alone")
            for a in m["assertions"]:
                if sorted(a) != ["id", "state"]:
                    bad(where, "a removal names an ID alone")
                absent.setdefault((tenant, a.get("id")), where)
            continue
        if states != {"present"}:
            bad(where, f"an assertion is present or absent, not {sorted(map(str, states))}")
            continue
        for a in m["assertions"]:
            name, classes = a.get("name"), a.get("class")
            classes = sorted(classes) if isinstance(classes, list) else classes
            present.add((tenant, a.get("id")))
            if not isinstance(name, str) or not re.fullmatch(r"[a-z][a-z0-9]*(-[a-z0-9]+)+", name) \
                    and not (name == "members" and source == "kanidm-migrations"):
                bad(where, f"every name but members holds a -, which no login suveraen-idm admin makes does: {name}")
            else:
                claim(names.setdefault(tenant, {}), name, own + "#" + str(a.get("id")), where, "name")
            if "member" in a:
                bad(where, f"groups get their members from admins, not from files: {name}")
            if classes == ["group"]:
                extra = set(a) - {"state", "id", "class", "name", "description", "entry_managed_by"}
                if a.get("entry_managed_by") != ["tenant-admins"]:
                    bad(where, f"tenant-admins manage the members of every group but the admin groups, as a list in"
                        f" Kanidm 1.11: {name}")
                groups.add(name)
            elif classes == ["account_policy", "group"] and source == "kanidm-migrations":
                extra = set(a) - {"state", "id", "class", "name", "description"} - policykeys
                if a.get("entry_managed_by") != managers.get(name):
                    bad(where, f"idm_admins manages platform-admins, and tenant-admins their own, as a list in Kanidm"
                        f" 1.11: {name}")
                groups.add(name)
            elif classes in (sorted(basic), sorted(public)) and source != "kanidm-migrations":
                extra = set(a) - clientkeys
                # Kanidm holds every account to one, and fails the whole file without it.
                if not isinstance(a.get("displayname"), str) or not a["displayname"].strip():
                    bad(where, f"a client has a display name: {name}")
                if classes == sorted(public) and "oauth2_consent_prompt_enable" in a:
                    extra.add("oauth2_consent_prompt_enable")
                clients.append((where, a))
            else:
                bad(where, f"the platform declares groups, and an app groups and an OAuth2 client, never people,"
                    f" accounts of another kind or classes Kanidm sets itself: {name} {classes}")
                continue
            if extra:
                bad(where, f"{name} sets {sorted(extra)}, which no migration of its kind sets here")
        if source == "kanidm-migrations" and key == "10-groups.json":
            declared = {a.get("name"): a for a in m["assertions"]}
            if sorted(declared) != ["members", "platform-admins", "tenant-admins"]:
                bad(where, "the platform groups are members, platform-admins and tenant-admins")
            p, t = declared.get("platform-admins", {}), declared.get("tenant-admins", {})
            def within(a, most):
                e = a.get("privilege_expiry")
                return isinstance(e, int) and 0 < e <= most and isinstance(a.get("authsession_expiry"), int)
            if p.get("credential_type_minimum") != "attested_passkey" or not within(p, 300):
                bad(where, "platform-admins sign in with passkeys of an approved make and model alone, and are asked"
                    " again within 5 minutes before an admin action")
            if t.get("credential_type_minimum") not in ("passkey", "attested_passkey") or not within(t, 600):
                bad(where, "tenant-admins sign in with passkeys alone, and are asked again within 10 minutes before an"
                    " admin action")
    if source == "kanidm-migrations":
        if "10-groups.json" not in s["files"]:
            bad(f"{tenant} {source}", "the platform groups are in 10-groups.json")
        continue
    where = f"{tenant} {source}"
    if [a.get("name") for _, a in clients] != [f"{app}-oidc"]:
        bad(where, f"an app has one OAuth2 client, {app}-oidc")
    if any(not n.startswith(f"{app}-") or n == f"{app}-oidc" for n in groups - {"members"}):
        bad(where, f"an app names its groups {app}-<name>")
    secret = None
    for here, a in clients:
        kind = basic if sorted(a["class"]) == sorted(basic) else public
        origins = a.get("oauth2_rs_origin")
        if not isinstance(origins, list) or not origins:
            bad(here, "a client names the addresses it may send members back to")
            origins = []
        for value in origins + [a.get("oauth2_rs_origin_landing")]:
            url(here, value, s["hosts"])
        for field in "oauth2_rs_scope_map", "oauth2_rs_sup_scope_map", "oauth2_rs_claim_map":
            entries = a.get(field, [])
            if not isinstance(entries, list) or field == "oauth2_rs_scope_map" and not entries:
                bad(here, f"{field} is a list, and a client maps at least one group to its scopes")
                continue
            for e in entries:
                if not isinstance(e, dict) or e.get("group") not in groups:
                    bad(here, f"a client maps members or its own app groups alone: {e}")
        for flag, value in s["annotations"].items():
            if flag not in flags or value != "true":
                bad(where, f"sso-{app} carries no annotation but {sorted(flags)}, set to true: {flag}")
            elif flags[flag] != kind:
                bad(where, f"{flag} is for a {kinds[flag]} client")
        secret = kind == basic
    shape = [{k: v for k, v in x.items() if k in ("apiVersion", "kind", "type", "data", "stringData", "immutable")}
             | {"annotations": (x.get("metadata") or {}).get("annotations") or {}} for x in s["secrets"]]
    want = [{"apiVersion": "v1", "kind": "Secret"} | placeholder] if secret else []
    if secret is not None and shape != want:
        bad(where, f"an app with a confidential client holds Secret sso, which Flux makes once with client-secret"
            f" pending alone (components/sso-secret), and one with a public client none: {shape}")

for (tenant, i), where in absent.items():
    if (tenant, i) in present:
        bad(where, f"a removed entry never comes back, as Kanidm refuses its ID for good: {i}")
print("\n".join(problems))
'

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
  passthrough=$(grep -qxF "$app" <<<"${passthroughapps// /$'\n'}" && echo true || echo false)
  export app passthrough
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
      # An app's groups and OAuth2 client in its tenant's Kanidm, once that runs.
      if [ "$part" = "\${TENANT}-$app-sso" ]; then
        yq ea -e "select(documentIndex == $i)"' | ((.metadata | keys | join(",")) == "name"
          and (.spec | keys | sort | join(",")) == "dependsOn,path,postBuild"
          and .spec.path == ("./kubernetes/apps/" + strenv(app) + "/sso")
          and ([.spec.dependsOn[].name] | join(",")) == "${TENANT}-kanidm"
          and (.spec.postBuild | keys | join(",")) == "substitute"
          and (.spec.postBuild.substitute | keys | join(",")) == "APP" and .spec.postBuild.substitute.APP == strenv(app))' \
          "$file" >/dev/null || fail "$file: an app's sign-in is \${TENANT}-$app-sso from ./kubernetes/apps/$app/sso," \
            "after \${TENANT}-kanidm alone, with APP $app"
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
      # A host passed through holds no certificate, so it needs no issuer.
      yq ea -e "select(documentIndex == $i)"' | ((.metadata | keys | join(",")) == "name"
        and (.spec | keys | sort | join(",")) == "dependsOn,path,postBuild"
        and (.spec.path | test("^[.]/kubernetes/edge/(app|identity|apex|passthrough)$"))
        and (.spec.path != "./kubernetes/edge/passthrough" or strenv(passthrough) == "true")
        and ((([.spec.dependsOn[].name] | sort | join(",")) == (["${TENANT}-" + strenv(app), "gateway", "issuer"]
          | sort | join(",")) and .spec.path != "./kubernetes/edge/passthrough")
          or (([.spec.dependsOn[].name] | sort | join(",")) == (["${TENANT}-" + strenv(app), "gateway"]
          | sort | join(",")) and .spec.path == "./kubernetes/edge/passthrough"))
        and (.spec.postBuild | keys | join(",")) == "substitute"
        and .spec.postBuild.substitute.APP == strenv(app)
        and (.spec.postBuild.substitute.EDGE | test("^[a-z][a-z0-9]{1,15}$"))
        and .metadata.name == ("${TENANT}-" + strenv(app) + "-edge-" + .spec.postBuild.substitute.EDGE)
        and (.spec.postBuild.substitute | has("ROUTE_PORT"))
        and (.spec.postBuild.substitute | has("HOST")) == (.spec.path != "./kubernetes/edge/apex")
        and ([.spec.postBuild.substitute | keys | .[]
          | select(test("^(APP|EDGE|HOST|ROUTE_PORT|ROUTE_SERVICE|ROUTE_TARGET_PORT)$") | not)] | length) == 0)' \
        "$file" >/dev/null || fail "$file: a host is \${TENANT}-$app-edge-<EDGE> from ./kubernetes/edge/<zone>," \
          "after the app, the gateway and the issuer, or passed through, for an app that terminates TLS itself, after" \
          "the app and the gateway, with APP $app, EDGE, ROUTE_PORT, and HOST unless it is the apex"
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
: >"$work/migrations.jsonl"
mkdir "$work/sources"
# Checks a Kustomization's migrations in its ConfigMap as Flux builds them before it substitutes anything (sourceids),
# once for each path, which every tenant builds alike, and writes the keys they take IDs from to $w/<name>.idkeys. The
# yq condition given finds the ConfigMap as the check once substituted does, so a name that takes a value is no way
# around it.
source_ids() { # Kustomization, path, condition, app
  local name=$1 path=$2 condition=$3 knob maps found bad
  knob=$(tr a-z A-Z <<<"$4")
  found=$work/sources/${path//\//_}
  if [ ! -e "$found" ]; then
    yq 'del(.spec.postBuild)' "$w/$name.ks.yaml" >"$w/$name.source.yaml"
    flux build kustomization "$name" --path "$path" --kustomization-file "$w/$name.source.yaml" --dry-run \
      >"$w/$name.source" || fail "$cluster/$name doesn't build"
    maps=$(yq ea -o=json -I=0 "[select(.kind == \"ConfigMap\" and $condition)]" "$w/$name.source")
    [ "$(yq 'length' <<<"$maps")" = 1 ] \
      || fail "$path holds its migrations in one ConfigMap, also as Flux builds it before it substitutes anything"
    yq -o=json -I=0 '.[0]' <<<"$maps" | python3 -I -c "$sourceids" "$knob" >"$found"
    bad=$(sed -n 's/^bad //p' "$found" | paste -sd';' -)
    [ -z "$bad" ] || fail "$path: an ID past the founding file comes from the tenant's Secret, as" \
      "\${${knob}_<NAME>_ID} alone, without a default, so no one in the tenant knows it before Kanidm makes its entry:" \
      "${bad//;/; }"
  fi
  sed -n 's/^key //p' "$found" >"$w/$name.idkeys"
}
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
    path=$(yq '.spec.path' "$w/$name.ks.yaml")
    case $path in
      ./kubernetes/apps/kanidm/app) source_ids "$name" "$path" '.metadata.name == "kanidm-migrations"' kanidm ;;
      ./kubernetes/apps/*/sso) source_ids "$name" "$path" true "$(basename "$(dirname "$path")")" ;;
      *) : >"$w/$name.idkeys" ;;
    esac
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
      # key. Each stand-in differs per source and key, and is base64, as it may land in a Secret's data, but a UUID for
      # a key the Kustomization's migrations take an ID from.
      yq "(.stringData // {}) * (.data // {})
        | with(.[]; . = (\"$ref-\" + key | downcase | sub(\"_\", \"-\") | @base64))" "$w/src.yaml" >"$w/standins.yaml"
      for key in $(yq 'keys | .[]' "$w/standins.yaml" | grep -xFf "$w/$name.idkeys" || true); do
        id=$(printf '%s/%s' "$ref" "$key" | sha256sum | sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12}).*/\1-\2-\3-\4-\5/')
        yq -i ".[\"$key\"] = \"$id\"" "$w/standins.yaml"
      done
      standin="load(\"$w/standins.yaml\")[key]"
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
            | test("^" + strenv(t) + "-[a-z0-9]+(-edge-[a-z0-9]+|-db|-cluster|-sso)?$"))
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
        passthrough=$(grep -qxF "$app" <<<"${passthroughapps// /$'\n'}" && echo true || echo false)
        # Its own key and certificate (components/passthrough).
        [ "$passthrough" = false ] || kinds+=,Certificate.cert-manager.io
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
        cronjobs=$(yq ea '[select(.kind == "CronJob") | .metadata.name] | sort | join(",")' "$file")
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
          # Each provider's copies are checked daily by restic from VolSync's own image, with the script in the
          # CronJob's spec and nothing else, as a user that isn't root, without a lock.
          [ "$cronjobs" = offsite-check-1,offsite-check-2 ] \
            || fail "$cluster/$name: an app's copies are checked by the CronJobs offsite-check-1 and offsite-check-2," \
              "and it has no others: $cronjobs"
          yq ea -e '[select(.kind == "CronJob") | .spec.jobTemplate.spec.template.spec.containers[0].command // []
            | .[2] // "" | test("restic check --no-lock ")] | all' "$file" >/dev/null \
            || fail "$cluster/$name: an app's copies are checked without restic's lock"
          restic=$(yq ea '[select(.kind == "HelmRelease" and .metadata.name == "volsync")] | .[0].spec.values.restic
            | .repository + ":" + .tag' "$rendered"/*.yaml)
          for n in 1 2; do
            check="select(.kind == \"CronJob\" and .metadata.name == \"offsite-check-$n\")"
            yq ea "$check | .spec as \$s | \$s.jobTemplate.spec.template as \$t | \$t.spec.containers[0] as \$c | [
              \"policy \" + \$s.concurrencyPolicy,
              \"history \" + (\$s.successfulJobsHistoryLimit | tostring) + \"/\"
                + (\$s.failedJobsHistoryLimit | tostring),
              \"retries \" + (\$s.jobTemplate.spec.backoffLimit | tostring),
              \"deadline \" + ((\$s.jobTemplate.spec.activeDeadlineSeconds // 0) > 0 | tostring),
              \"labels \" + (\$t.metadata.labels // {} | to_entries | map(.key + \"=\" + .value) | join(\",\")),
              \"token \" + (\$t.spec.automountServiceAccountToken | tostring),
              \"user \" + (\$t.spec.securityContext.runAsNonRoot | tostring),
              \"containers \" + (\$t.spec.containers | length | tostring) + \"/\"
                + (\$t.spec.initContainers // [] | length | tostring),
              \"image \" + \$c.image,
              \"command \" + (\$c.command // [] | .[0:2] + [length | tostring] | join(\" \")) + \"/\"
                + (\$c.args // [] | join(\" \")),
              \"env \" + ([\$c.envFrom[] | (keys | join(\",\")) + \"=\" + (.secretRef.name // \"-\")] | join(\";\")),
              \"volumes \" + ([\$t.spec.volumes[] | (keys | map(select(. != \"name\")) | join(\",\")) + \"=\"
                + (.configMap.name // \"-\")] | sort | join(\";\"))] | .[]" "$file" >"$w/$name.check-$n"
            printf '%s\n' "policy Forbid" "history 0/1" "retries 1" "deadline true" "labels suveraen/egress=internet" \
              "token false" "user true" "containers 1/0" "image $restic" "command bash -c 3/" \
              "env secretRef=offsite-$n" "volumes emptyDir=-" >"$w/$name.check-$n.want"
            bad=$(diff "$w/$name.check-$n.want" "$w/$name.check-$n" | sed -n 's/^> //p' | paste -sd';' || true)
            schedule=$(yq ea "$check | .spec.schedule" "$file")
            cycle=$(yq ea "$check | [.spec.jobTemplate.spec.template.spec.containers[0].env[]
              | select(.name == \"CYCLE\") | .value] | join(\",\")" "$file")
            cmp -s "$w/$name.check-$n.want" "$w/$name.check-$n" && [[ $schedule =~ $daily ]] \
              && [[ $cycle =~ ^[1-9][0-9]*d$ ]] && [ "${cycle%d}" -le 14 ] \
              || fail "$cluster/$name: offsite-check-$n checks the copies at provider $n alone, once a day at a set" \
                "time and all of them within 1 to 14 days, with VolSync's restic and its spec's script alone, as a" \
                "user that isn't root and without the account's token, never twice at once, keeping no Job that" \
                "passed and the last that failed, which it retried once, and stopping it after a while: $bad"
          done
        elif [ "$app" != postgres ] && [ -n "$cronjobs" ]; then
          fail "$cluster/$name: an app's CronJobs only check its copies: $cronjobs"
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
          # Each provider's copy is checked once a day by the CronJob offsite's own pod, which a check that fails runs
          # once more, for a while at most, and keeps.
          [ "$(yq ea '[select(.kind == "CronJob") | .metadata.name] | sort | join(",")' "$file")" \
            = offsite,offsite-check-1,offsite-check-2 ] \
            || fail "$cluster/$name: a tenant's PostgreSQL has the CronJobs offsite, offsite-check-1 and" \
              "offsite-check-2"
          pod='.spec.jobTemplate.spec.template | del(.spec.containers[0].args) | sort_keys(..)'
          offsite=$(yq ea -o=json -I=0 "select(.kind == \"CronJob\" and .metadata.name == \"offsite\") | $pod" "$file")
          for n in 1 2; do
            check="select(.kind == \"CronJob\" and .metadata.name == \"offsite-check-$n\")"
            yq ea -o=json -I=0 "$check | $pod" "$file" >"$w/$name.check"
            yq ea "$check | .spec | [(.jobTemplate.spec.template.spec.containers[0].args | join(\" \")),
              .concurrencyPolicy, .successfulJobsHistoryLimit, .failedJobsHistoryLimit, .jobTemplate.spec.backoffLimit,
              (.jobTemplate.spec.activeDeadlineSeconds // 0 > 0)] | join(\",\")" "$file" >>"$w/$name.check"
            schedule=$(yq ea "$check | .spec.schedule" "$file")
            [ "$(cat "$w/$name.check")" = "$offsite"$'\n'"check $n,Forbid,0,1,1,true" ] && [[ $schedule =~ $daily ]] \
              || fail "$cluster/$name: offsite-check-$n runs offsite's pod to check provider $n alone, once a day" \
                "at a set time, never twice at once, keeps no Job that passed and the last that failed, which it" \
                "retried once, and stops it after a while"
          done
          # A copy changed at a provider is found within a cycle and the three days a check may go without passing,
          # while the provider still keeps what it replaced.
          read -r cycle lock <<<"$(yq ea '[select(.kind == "ConfigMap" and .metadata.name == "offsite")] | .[0].data
            | (.CHECK_CYCLE // "-") + " " + (.LOCK // "-")' "$file")"
          [[ $cycle =~ ^[1-9][0-9]*d$ && $lock =~ ^[1-9][0-9]*d$ ]] && [ "${cycle%d}" -le 14 ] \
            && [ $((${cycle%d} + 3)) -lt "${lock%d}" ] \
            || fail "$cluster/$name: the checks read every copy back within 1 to 14 days, and that and three days" \
              "more are less than the days a copy stays locked: $cycle, $lock"
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
        # Every Job the namespace may hold at once: each CronJob's running one and those it keeps, the others, a mover
        # for each of VolSync's copies and restores, and the one CloudNativePG runs to make an instance.
        need=$({
          yq ea '[select(.metadata.namespace == strenv(name)) | select(.kind == "CronJob")
            | (.spec.successfulJobsHistoryLimit // 3) + (.spec.failedJobsHistoryLimit // 1) + 1] | .[]' \
            "$rendered"/*.yaml
          yq ea '[select(.metadata.namespace == strenv(name)) | select(.kind == "Job" or .kind == "ReplicationSource"
            or .kind == "ReplicationDestination" or (.kind == "Cluster" and .apiVersion == "postgresql.cnpg.io/v1"))]
            | length' "$rendered"/*.yaml
        } | awk '{ n += $1 } END { print n }')
        quota=$(yq ea '[select(.kind == "ResourceQuota")] | .[0].spec.hard."count/jobs.batch"' "$file")
        [[ $quota =~ ^[0-9]+$ ]] && [ "$need" -le "$quota" ] \
          || fail "$cluster/$name: the quota's count/jobs.batch, $quota, holds every CronJob's running and kept Jobs," \
            "the other Jobs, VolSync's movers and CloudNativePG's: $need"
        # Every ConfigMap made in the namespace, other Kustomizations' too, and the cluster's CA, kube-root-ca.crt.
        need=$(($(yq ea '[select(.kind == "ConfigMap" and .metadata.namespace == strenv(name))] | length' \
          "$rendered"/*.yaml) + 1))
        quota=$(yq ea '[select(.kind == "ResourceQuota")] | .[0].spec.hard."count/configmaps"' "$file")
        [[ $quota =~ ^[0-9]+$ ]] && [ "$need" -le "$quota" ] \
          || fail "$cluster/$name: the quota's count/configmaps, $quota, holds every ConfigMap made in the namespace" \
            "and the cluster's CA: $need"
        # An app signs in through its tenant's Kanidm only with its attachment, which it waits for, and reaches Kanidm
        # by components/sso-client alone.
        if grep -qxF "$t-$app-sso" <<<"$known"; then
          want='{"egress":[{"ports":[{"port":8443}],"to":[{"namespaceSelector":{"matchLabels":'
          want+='{"kubernetes.io/metadata.name":"'$t'-kanidm"}},"podSelector":{"matchLabels":'
          want+='{"app.kubernetes.io/controller":"kanidm"}}}]}],"podSelector":{},"policyTypes":["Egress"]}'
          [ "$(yq ea -o=json -I=0 '[select(.kind == "NetworkPolicy" and .metadata.name == "to-kanidm")
            | .spec | sort_keys(..)] | .[]' "$file")" = "$want" ] \
            || fail "$cluster/$name: an app that signs in through Kanidm reaches it by components/sso-client"
          yq ea -e "select($fluxks and .metadata.name == \"$t-$app\") | .spec.dependsOn
            | any_c(.name == \"$t-$app-sso\")" "$rendered/tenant-$t.yaml" >/dev/null \
            || fail "$cluster/$name: an app waits for its sign-in, $t-$app-sso"
        else
          bad=$(yq ea '[select((.kind == "NetworkPolicy" and .metadata.name == "to-kanidm")
            or (.kind == "Secret" and .metadata.name == "sso")) | .kind + "/" + .metadata.name] | .[]' "$file")
          [ -z "$bad" ] || fail "$cluster/$name: only an app that signs in through Kanidm, with $t-$app-sso, reaches" \
            "it or holds Secret sso: $bad"
        fi
        if [ "$passthrough" = true ]; then
          passhost=$(grep -E "^$t-$app-edge-[a-z0-9]+ ./kubernetes/edge/passthrough$" "$w/paths" \
            | while read -r edge _; do
              yq '.spec.postBuild.substitute | .HOST + "." + .TENANT_DOMAIN' "$w/$edge.build.yaml"
            done)
          [ "$(wc -w <<<"$passhost")" = 1 ] \
            || fail "$cluster/$name: an app that terminates TLS itself has one host passed through to it:" $passhost
          export passhost
          yq ea -e '[select(.kind == "Certificate")] | (length == 1 and .[0].metadata.name == "tls"
            and (.[0].spec | keys | sort | join(",")) == "dnsNames,issuerRef,privateKey,secretName,secretTemplate"
            and .[0].spec.secretName == "tls" and (.[0].spec.secretTemplate | keys | join(",")) == "labels"
            and (.[0].spec.secretTemplate.labels | to_entries | length) == 1
            and .[0].spec.secretTemplate.labels."suveraen/tenant" == strenv(t)
            and (.[0].spec.dnsNames | join(",")) == strenv(passhost)
            and (.[0].spec.issuerRef | keys | sort | join(",")) == "kind,name"
            and .[0].spec.issuerRef.kind == "ClusterIssuer" and .[0].spec.issuerRef.name == "public"
            and .[0].spec.privateKey.algorithm == "ECDSA" and .[0].spec.privateKey.size == 256
            and .[0].spec.privateKey.rotationPolicy == "Always")' "$file" >/dev/null \
            || fail "$cluster/$name: an app that terminates TLS itself holds one certificate, tls, for the host" \
              "passed through to it, $passhost, alone, from the public issuer, with a new ECDSA key each time, into" \
              "Secret tls labelled with tenant $t (components/passthrough)"
          yq ea -e '[select(.kind == "Namespace")] | .[0].metadata.labels."suveraen/passthrough" == "true"' "$file" \
            >/dev/null || fail "$cluster/$name: an app that terminates TLS itself is labelled suveraen/passthrough"
        fi
        if [ "$app" = kanidm ]; then
          # Kanidm asks for a client of the server's own version.
          image=$(yq ea '[select(.kind == "HelmRelease") | .spec.values.controllers.kanidm.containers.app.image
            | .repository + ":" + .tag] | join(" ")' "$file")
          [[ $image =~ ^docker[.]io/kanidm/server:${KANIDM_VERSION//./[.]}@sha256:[0-9a-f]{64}$ ]] \
            || fail "$cluster/$name: Kanidm runs docker.io/kanidm/server at the version of the Kanidm client the" \
              "platform builds, $KANIDM_VERSION: $image"
          # The platform's migrations and those of every app that may sign in to it, as a tenant runs it.
          want=$(for dir in kubernetes/apps/*/sso/; do
            [ ! -d "$dir" ] || printf ',{"configMap":{"name":"sso-%s","optional":true}}' "$(basename "${dir%/sso/}")"
          done)
          want='["projected",[{"configMap":{"name":"kanidm-migrations"}}'$want']]'
          yq ea -o=json -I=0 '[select(.kind == "HelmRelease")] | .[0].spec.values.persistence.migrations
            | [.type, (.sources | sort_keys(..))]' "$file" >"$w/$name.sources"
          [ "$(cat "$w/$name.sources")" = "$want" ] \
            || fail "$cluster/$name: Kanidm reads kanidm-migrations and the sso-<app> of every app with a sign-in," \
              "as it has one, from one projected volume: $(cat "$w/$name.sources")"
          bad=$(yq ea -o=json -I=0 '[.]' "$file" | python3 -I -c "$kanidmconfig" "$passhost")
          [ -z "$bad" ] || fail "$cluster/$name: Kanidm serves the host passed through to it, as its domain and" \
            "origin, reads its migrations where they are mounted, trusts no address a client names, speaks no LDAP," \
            "replicates nothing, sends nothing out, and logs nothing below info: $bad"
          python3 -I -c "$migrationsource" "$cluster" "$t" kanidm-migrations kanidm \
            <(yq ea -o=json -I=0 '[select(.kind == "ConfigMap" and .metadata.name == "kanidm-migrations")] | .[0]' \
              "$file") <(echo '[]') <(echo '[]') >>"$work/migrations.jsonl"
        fi
        ;;
      ./kubernetes/apps/*/sso)
        app=$(basename "$(dirname "$path")")
        [ -n "$t" ] && [ "$name" = "$t-$app-sso" ] || fail "$cluster/$name: an app's sign-in is <tenant>-<app>-sso"
        objects="ConfigMap/$t-kanidm/sso-$app/$t,NetworkPolicy/$t-kanidm/from-$app/$t"
        [ "$(yq ea '[select(.kind != null) | .kind + "/" + .metadata.namespace + "/" + .metadata.name + "/"
          + .metadata.labels."suveraen/tenant"] | sort | join(",")' "$file")" = "$objects" ] \
          || fail "$cluster/$name: an app's sign-in is ConfigMap sso-$app and NetworkPolicy from-$app in $t-kanidm," \
            "labelled with tenant $t"
        want='{"ingress":[{"from":[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"'$t-$app'"}}}],'
        want+='"ports":[{"port":8443}]}],"podSelector":{"matchLabels":{"app.kubernetes.io/controller":"kanidm"}},'
        want+='"policyTypes":["Ingress"]}'
        [ "$(yq ea -o=json -I=0 '[select(.kind == "NetworkPolicy") | .spec | sort_keys(..)] | .[]' "$file")" \
          = "$want" ] || fail "$cluster/$name: an app's sign-in opens Kanidm's port to $t-$app alone"
        python3 -I -c "$migrationsource" "$cluster" "$t" "sso-$app" "$app" \
          <(yq ea -o=json -I=0 '[select(.kind == "ConfigMap")] | .[0]' "$file") \
          <(yq ea -o=json -I=0 "[select(.kind == \"Gateway\") | .spec.listeners[] | select(.allowedRoutes.namespaces
            .selector.matchLabels.\"kubernetes.io/metadata.name\" == \"$t-$app\") | .hostname]" "$rendered"/*.yaml) \
          <(yq ea -o=json -I=0 '[select(.kind == "Secret" and .metadata.name == "sso")]' "$rendered/$t-$app.yaml") \
          >>"$work/migrations.jsonl"
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
        # Its namespace's quota holds every instance with its Barman sidecar, a job copying the bucket and one checking
        # a copy.
        app=$rendered/$t-postgres.yaml
        instances=$(yq ea '[select(.kind == "Cluster")] | .[0].spec.instances' "$file")
        memory=$(yq ea '[select(.kind == "Cluster")] | .[0].spec.resources.limits.memory' "$file")
        sidecar=$(yq ea '[select(.kind == "ObjectStore")]
          | .[0].spec.instanceSidecarConfiguration.resources.limits.memory' "$app")
        limit='.spec.jobTemplate.spec.template.spec.containers[0].resources.limits.memory'
        job=$(yq ea "[select(.kind == \"CronJob\" and .metadata.name == \"offsite\")] | .[0] | $limit" "$app")
        check=$(yq ea "[select(.kind == \"CronJob\" and .metadata.name == \"offsite-check-1\")] | .[0] | $limit" "$app")
        quota=$(yq ea '[select(.kind == "ResourceQuota")] | .[0].spec.hard."limits.memory"' "$app")
        need=$((instances * ($(quantity "$memory") + $(quantity "$sidecar")) + $(quantity "$job")
          + $(quantity "$check")))
        [ "$need" -le "$(quantity "$quota")" ] \
          || fail "$cluster/$name: $t-postgres's quota, $quota, can't hold $instances instances of $memory, each with a" \
            "$sidecar sidecar, a $job job copying the bucket and a $check one checking a copy"
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
      ./kubernetes/edge/app | ./kubernetes/edge/identity | ./kubernetes/edge/apex | ./kubernetes/edge/passthrough)
        [[ $name =~ ^$t-([a-z0-9]+)-edge-([a-z0-9]+)$ ]] && [ -n "$t" ] \
          || fail "$cluster/$name: a host is <tenant>-<app>-edge-<key>, one of its tenant's"
        app=${BASH_REMATCH[1]}
        key=${BASH_REMATCH[2]}
        base=$t-$app-$key
        export app base
        grep -qxF "$t-$app" <<<"$known" || fail "$cluster/$name: a host belongs to an app its tenant runs, $t-$app"
        case ${path##*/} in
          app) host='.HOST + "." + .TENANT_APP_DOMAIN' ;;
          identity | passthrough) host='.HOST + "." + .TENANT_DOMAIN' ;;
          apex) host='.TENANT_DOMAIN' ;;
        esac
        host=$(yq ".spec.postBuild.substitute | $host" "$w/$name.build.yaml")
        export host
        if [ "${path##*/}" = passthrough ]; then
          grep -qxF "$app" <<<"${passthroughapps// /$'\n'}" \
            || fail "$cluster/$name: only an app that terminates TLS itself is passed through, not $app"
          objects="Gateway/gateway/$base/$t,NetworkPolicy/$t-$app/from-gateway-$key/$t,TLSRoute/$t-$app/$key/$t"
          [ "$(yq ea '[select(.kind != null) | .kind + "/" + .metadata.namespace + "/" + .metadata.name + "/"
            + .metadata.labels."suveraen/tenant"] | sort | join(",")' "$file")" = "$objects" ] \
            || fail "$cluster/$name: a host passed through is Gateway $base in gateway, and TLSRoute $key and" \
              "NetworkPolicy from-gateway-$key in $t-$app, all labelled with tenant $t"
          yq ea -e '[select(.kind == "Gateway")] | .[0] as $g | $g.spec.listeners as $l
            | (($g.spec | keys | sort | join(",")) == "gatewayClassName,listeners"
            and $g.spec.gatewayClassName == "traefik"
            and ($l | length) == 1 and $l[0].name == "tls" and $l[0].protocol == "TLS" and $l[0].port == 8443
            and $l[0].hostname == strenv(host) and ($l[0].tls | keys | join(",")) == "mode"
            and $l[0].tls.mode == "Passthrough"
            and ([$l[0].allowedRoutes.kinds[].kind] | join(",")) == "TLSRoute"
            and $l[0].allowedRoutes.namespaces.from == "Selector"
            and ($l[0].allowedRoutes.namespaces.selector | keys | join(",")) == "matchLabels"
            and ($l[0].allowedRoutes.namespaces.selector.matchLabels | to_entries | length) == 1
            and $l[0].allowedRoutes.namespaces.selector.matchLabels."kubernetes.io/metadata.name" == (strenv(t) + "-"
              + strenv(app)))' "$file" >/dev/null \
            || fail "$cluster/$name: a host passed through has one listener, for TLS to $host alone, which passes it" \
              "through, holds no certificate, and admits TLS routes from $t-$app only"
        else
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
            and ($l[0].tls.certificateRefs | length) == 1
            and $l[0].tls.certificateRefs[0].name == (strenv(base) + "-tls")
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
        fi
        ;;
      *) fail "$cluster/$name: Kustomizations apply kubernetes/platform, a tenant, an app or a host, not $path" ;;
    esac
    case $path in
      ./kubernetes/apps/* | ./kubernetes/edge/*)
        # Backups say how old they may get, which the servers hold them to.
        bad=$(yq ea '[select((.kind == "Cluster" and .apiVersion == "postgresql.cnpg.io/v1") or .kind == "ObjectStore"
          or .kind == "ReplicationSource" or .kind == "CronJob")
          | select(.metadata.annotations."suveraen/max-age" // "" | tostring | test("^[1-9][0-9]*[mhd]$") | not)
          | .kind + "/" + .metadata.name] | .[]' "$file")
        [ -z "$bad" ] || fail "$cluster/$name: backups say how old they may get, in minutes, hours or days" \
          "(suveraen/max-age): $bad"
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
    # Only an app that terminates TLS itself holds a public certificate of its own, as the gateway logs the clients of
    # a route that passes TLS through by their own addresses (platform/gateway).
    bad=$(yq ea '[select(.kind == "Namespace" and .metadata.labels."suveraen/passthrough" != null) | .metadata.name
      + " " + .metadata.labels."suveraen/passthrough"] | .[]' "$file" | while read -r ns value; do
        [[ $ns == "$name" && $value == true && " $passthroughapps " == *" ${ns#"$t"-} "* ]] || echo "$ns"
      done)
    [ -z "$bad" ] || fail "$cluster/$name: only an app that terminates TLS itself holds a public certificate of its" \
      "own (suveraen/passthrough): $bad"
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

  # Each listener: its Gateway, tenant, host, the namespace it takes routes from, and its name, tls for one that passes
  # TLS through.
  yq ea '[select(.kind == "Gateway") | .metadata.name + " " + .metadata.labels."suveraen/tenant" + " "
    + .spec.listeners[0].hostname + " "
    + .spec.listeners[0].allowedRoutes.namespaces.selector.matchLabels."kubernetes.io/metadata.name" + " "
    + .spec.listeners[0].name] | .[]' "$rendered"/*.yaml >"$w/listeners"
  dup=$(cut -d' ' -f3 "$w/listeners" | sort | uniq -d)
  [ -z "$dup" ] || fail "$cluster: two listeners claim the same host: $dup"
  bad=$(yq ea '[select((.kind == "HTTPRoute" or .kind == "TLSRoute") and ((.spec.parentRefs // []) | length) == 0)
    | .metadata.name] | .[]' "$rendered"/*.yaml)
  [ -z "$bad" ] || fail "$cluster: routes attach to a host's listener: $bad"
  yq ea '[select(.kind == "HTTPRoute" or .kind == "TLSRoute") | .metadata.namespace + " " + .metadata.name + " "
    + ((.spec.hostnames // []) | join(",")) + " " + .kind as $route | .spec.parentRefs[]
    | $route + " " + (.namespace // "") + "/" + (.sectionName // "") + "/" + .name] | .[]' \
    "$rendered"/*.yaml >"$w/routes"
  while read -r ns route hosts kind parent; do
    section=https
    [ "$kind" = HTTPRoute ] || section=tls
    [[ $parent == gateway/$section/* ]] || fail "$cluster: route $ns/$route attaches to $parent, not a host's listener"
    grep -qxF "${parent#gateway/"$section"/} ${ns:0:5} $hosts $ns $section" "$w/listeners" \
      || fail "$cluster: route $ns/$route asks ${parent#gateway/"$section"/} for $hosts, which isn't its listener's" \
        "host for routes from $ns"
  done <"$w/routes"
  # Apps see a pseudonym in place of each client's address (platform/gateway). Traefik gets each client's own address
  # on the node it reached, takes routes from the Gateway API alone and trusts no address a client names; on every
  # route it limits each client by its own address, then replaces it with the plugin as it is here; and it logs no
  # client.
  yq ea -o=json -I=0 '[select(.kind == "ConfigMap" and .metadata.name == "cluster-settings")] | .[0].data // {}' \
    "$rendered/cluster.yaml" >"$w/settings.json"
  bad=$(python3 -I -c "$gatewaysettings" <"$w/settings.json" | paste -sd' ')
  [ -z "$bad" ] || fail "$cluster: GATEWAY_PSEUDONYM_V4 and GATEWAY_PSEUDONYM_V6 are ranges of their family no longer" \
    "than /8 and /48, apart from the cluster's pods, Services and nodes; the gateway's rates are whole numbers above" \
    "zero, and its period whole hours: $bad"
  [ "$(yq ea '[select(.kind == "HelmRelease" and .metadata.name == "traefik")] | length' "$rendered"/*.yaml)" = 1 ] \
    || fail "$cluster: the gateway is one HelmRelease, traefik"
  traefik='[select(.kind == "HelmRelease" and .metadata.name == "traefik")] | .[0].spec.values'
  [ "$(yq ea "$traefik | (.providers.kubernetesCRD.enabled | tostring) + \" \"
    + (.providers.kubernetesIngress.enabled | tostring)" "$rendered"/*.yaml)" = "false false" ] \
    || fail "$cluster: the gateway takes routes from the Gateway API alone, not from Traefik's own kinds or Ingresses"
  [ "$(yq ea "$traefik | (.deployment.kind // \"Deployment\") + \" \" + (.service.spec.externalTrafficPolicy // \"Cluster\")
    + \" \" + (.hostNetwork // false | tostring) + \" \" + ([.ports // {} | .[] | select(has(\"hostPort\"))] | length
    | tostring)" "$rendered"/*.yaml)" = "DaemonSet Local false 0" ] \
    || fail "$cluster: the gateway runs on every node, a DaemonSet that its Service hands the clients reaching that node" \
      "with their own addresses (externalTrafficPolicy Local), and on none of the host's ports"
  bad=$(yq ea "$traefik | [(.ports // {} | to_entries | .[]
      | select(.value | has(\"forwardedHeaders\") or has(\"proxyProtocol\")) | \"ports.\" + .key),
    (.additionalArguments // [] | .[] | select(test(strenv(options))))] | .[]" "$rendered"/*.yaml | paste -sd' ')
  [ -z "$bad" ] || fail "$cluster: the gateway trusts no address a client names, and takes no arguments of its own for" \
    "its logs, entry points, providers or plugins: $bad"
  read -r average burst v4 v6 period <<<"$(yq -p=json -oy '[.GATEWAY_RATE_AVERAGE, .GATEWAY_RATE_BURST,
    .GATEWAY_PSEUDONYM_V4, .GATEWAY_PSEUDONYM_V6, .GATEWAY_PSEUDONYM_PERIOD] | join(" ")' "$w/settings.json")"
  want='[["ratelimit@file","pseudonym@file"],"delete","delete",{"content":{"http":{"middlewares":{"pseudonym":{"plugin":'
  want+='{"pseudonym":{"ipv4":"'$v4'","ipv6":"'$v6'","period":"'$period'"}}},"ratelimit":{"rateLimit":{"average":'
  want+=$average',"burst":'$burst',"period":"1s","sourceCriterion":{"ipStrategy":{"ipv6Subnet":64}}}}}}},"enabled":true}]'
  [ "$(yq ea -o=json -I=0 "$traefik | [.ports.websecure.http.middlewares, .ports.web.http.aliasHeadersStrategy,
    .ports.websecure.http.aliasHeadersStrategy, (.providers.file | sort_keys(..))]" "$rendered"/*.yaml)" = "$want" ] \
    || fail "$cluster: on every route the gateway limits each client by its own address, then gives apps its" \
      "pseudonym (ratelimit@file, pseudonym@file, from the file provider alone, with the cluster's GATEWAY_* settings)," \
      "and it deletes headers that alias another's name on both entry points"
  [[ $(yq ea "$traefik | (.accessLog.enabled // false | tostring) + \" \" + (.log.level // \"INFO\")" \
    "$rendered"/*.yaml) =~ ^false\ (WARN|ERROR)$ ]] \
    || fail "$cluster: the gateway keeps no access log and logs warnings and errors alone, as its other lines name" \
      "clients' addresses"
  want='[0,true,{"pseudonym":{"moduleName":"suveraen/pseudonym","mountPath":"/plugins-local/src/suveraen/pseudonym",'
  want+='"type":"localPath","volumeName":"pseudonym"}},[{"configMap":{"name":"pseudonym"},"name":"pseudonym"}]]'
  [ "$(yq ea -o=json -I=0 "$traefik | [(.experimental.plugins // {} | length), .experimental.abortOnPluginFailure,
    (.experimental.localPlugins | sort_keys(..)),
    [.deployment.additionalVolumes[]? | select(.name == \"pseudonym\") | sort_keys(..)]]" "$rendered"/*.yaml)" \
    = "$want" ] \
    || fail "$cluster: the gateway runs no plugin from elsewhere, and doesn't start without the pseudonym from" \
      "ConfigMap pseudonym"
  plugin=kubernetes/platform/gateway/app/pseudonym
  yq ea -o=json -I=0 '[select(.kind == "ConfigMap" and .metadata.namespace == "gateway"
    and .metadata.name == "pseudonym")]' "$rendered"/*.yaml | python3 -I -c "$sameplugin" "$plugin" \
    || fail "$cluster: ConfigMap gateway/pseudonym holds $plugin/.traefik.yml and pseudonym.go as they are," \
      "unsubstituted"
  hash=$(cat "$plugin/.traefik.yml" "$plugin/pseudonym.go" | sha256sum | cut -d' ' -f1)
  [ "$(yq ea "$traefik | .deployment.podAnnotations.\"suveraen/pseudonym\" // \"\"" "$rendered"/*.yaml)" = "$hash" ] \
    || fail "$cluster: the gateway's pods are annotated suveraen/pseudonym: \"$hash\", the sha256 of the plugin's" \
      ".traefik.yml and pseudonym.go, so a changed plugin restarts them"
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
    while read -r _ owner host admitted _; do
      best=
      for k in $domains; do
        if [[ $host == "$k" || $host == *".$k" ]] && [ ${#k} -gt ${#best} ]; then best=$k; fi
      done
      value=
      [ -z "$best" ] || value=$(yq ".data.\"$best\"" "$w/hostnames.yaml")
      [ "$value" = "$owner" ] || [ "$value" = "$admitted" ] \
        || fail "$cluster: $admitted serves $host, but the hostname map gives it to ${value:-nobody}"
    done <"$w/listeners"
    # A host passed through to an app is that namespace's by an entry of its own, which no other of its tenant's
    # namespaces can take.
    while read -r _ _ host admitted section; do
      [ "$section" != tls ] || [ "$(yq ".data.\"$host\" // \"\"" "$w/hostnames.yaml")" = "$admitted" ] \
        || fail "$cluster: the hostname map gives $host, passed through to $admitted, to that namespace by an entry" \
          "of its own"
    done <"$w/listeners"
  fi
  # A cluster directory adds only what Flux runs with, and the names the cluster's DNS answers for its tenants' Kanidm.
  bad=$(yq ea '[select(.kind != null and .metadata.namespace != "flux-system") | .kind + "/"
    + (.metadata.namespace // "") + "/" + .metadata.name] | .[]' "$rendered/cluster.yaml" \
    | grep -vxF ConfigMap/kube-system/coredns-custom || true)
  [ -z "$bad" ] || fail "$cluster: a cluster directory adds objects to flux-system alone, and the cluster DNS's names" \
    "for its tenants' Kanidm (coredns-custom in kube-system): $bad"
  # Apps reach their tenant's Kanidm at its public name, which the cluster's DNS answers with Kanidm's Service. k3s
  # reads the *.override keys of coredns-custom into CoreDNS.
  yq ea '[select(.kind == "ConfigMap" and .metadata.namespace == "kube-system" and .metadata.name == "coredns-custom")]
    | .[0] // {}' "$rendered/cluster.yaml" >"$w/coredns.yaml"
  want=$(while read -r _ _ host admitted section; do
    [ "$section" = tls ] && [[ $admitted == *-kanidm ]] || continue
    echo "rewrite name exact $host kanidm.$admitted.svc.cluster.local"
  done <"$w/listeners" | sort)
  if [ "$(yq 'length' "$w/coredns.yaml")" = 0 ]; then
    [ -z "$want" ] || fail "$cluster: apps reach their tenant's Kanidm at its public name, which the cluster's DNS" \
      "answers from ConfigMap coredns-custom in kube-system"
  elif [ "$(yq 'has("sops")' "$w/coredns.yaml")" = false ]; then
    [ "$testing" = true ] || fail "$cluster: the cluster's DNS names its tenants' identity hosts, so coredns-custom" \
      "is encrypted"
    have=$(yq '.data // {} | keys | join(",")' "$w/coredns.yaml")
    [ "$have" = identity.override ] && [ "$(yq '.data."identity.override"' "$w/coredns.yaml" | sed '/^$/d' | sort)" \
      = "$want" ] || fail "$cluster: the cluster's DNS answers each tenant's identity host with its Kanidm's Service," \
        "one line each in coredns-custom's identity.override, and nothing else:" $want
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
  # The pools that hold data stop at a byte quota before the OSDs fill; Ceph's own pools have none, as a full one would
  # stop the whole object store or the manager.
  quota='((Q.quotas // {}) | to_entries | map(.key + "=" + (.value | tostring)) | join(","))'
  # Each line: the pool, whether it holds data, whether it is one of Ceph's own, and its quotas.
  {
    yq ea "[select(.kind == \"CephBlockPool\") | \"CephBlockPool/\" + .metadata.name + \" \"
      + (.spec.parameters.bulk == \"true\" | tostring) + \" \" + ((.spec.name // \"\") | test(\"^[.]\") | tostring)
      + \" \" + ${quota//Q/.spec}] | .[]" "$rendered"/*.yaml
    for part in metadata:false:true data:true:false; do
      IFS=: read -r p data own <<<"$part"
      yq ea "[select(.kind == \"CephObjectStore\") | \"CephObjectStore/\" + .metadata.name + \"/$p $data $own \"
        + ${quota//Q/.spec.${p}Pool}] | .[]" "$rendered"/*.yaml
    done
  } >"$w/quotas"
  bad=$(awk '$4 ~ /(^|,)max(Bytes|Objects)=/ || ($3 == "true" && $4 != "") { print $1 }' "$w/quotas" | paste -sd' ')
  [ -z "$bad" ] || fail "$cluster: Ceph's pools have quotas in bytes alone, maxSize, and its own pools, the manager's" \
    "and the object store's metadata, have none: $bad"
  bad=$(while read -r name data _ quota; do
    [ "$data" != true ] || { [[ $quota =~ ^maxSize=(.+)$ ]] && n=$(quantity "${BASH_REMATCH[1]}" 2>/dev/null) \
      && [ "$n" -gt 0 ]; } || echo "$name"
  done <"$w/quotas" | paste -sd' ')
  [ -z "$bad" ] || fail "$cluster: each Ceph pool that holds data stops at a whole quota of bytes above zero: $bad"
  # A tenant meets its own bucket's limit before the object store's quota stops every tenant's archiving.
  objects=$(yq ea '[select(.kind == "CephObjectStore")] | .[0].spec.dataPool.quotas.maxSize' "$rendered"/*.yaml)
  sizes=$(yq ea '[select(.kind == "ObjectBucketClaim") | .spec.additionalConfig.maxSize // "-"] | .[]' \
    "$rendered"/*.yaml | paste -sd' ')
  total=0
  for size in $sizes; do
    n=$(quantity "$size" 2>/dev/null) || { total=; break; }
    total=$((total + n))
  done
  [ -n "$total" ] && [ "$total" -le "$(quantity "$objects")" ] \
    || fail "$cluster: the object store's quota covers every tenant's bucket, each with a whole size: $objects for" \
      "$sizes"
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
    "priorities " + (.priorityClassNames.all // "-") + " mon=" + (.priorityClassNames.mon // "-") + " osd="
      + (.priorityClassNames.osd // "-"),
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
    "mgrsShareNode $share" "requireMsgr2 true" "network encrypted" "osdMemoryGuaranteed true" \
    "priorities platform mon=system-node-critical osd=system-node-critical" "useAllNodes true" "nodes false" \
    "useAllDevices false" "filters false/false" "config encryptedDevice=true" "devices ${devices% }" \
    >"$w/cephcluster.want"
  bad=$(diff "$w/cephcluster.want" "$w/cephcluster" | sed -n 's/^> //p' | paste -sd';' || true)
  [ -z "$bad" ] || fail "$cluster: the CephCluster keeps its state in /var/lib/rook, runs a supported Ceph with three" \
    "monitors, lets daemons share a node only while copies spread over OSDs, speaks msgr2 alone, encrypted when on" \
    "the hosts' network, guarantees its OSDs their memory, runs its monitors and OSDs at system-node-critical, which" \
    "a shutdown stops last, and the rest at the platform's priority, and takes encrypted OSDs from every node on" \
    "slots from osd0 on, each with its DB on its own volume: $bad"
  # Placement groups follow the OSDs and pools, not the order the pools came in.
  [ "$(yq ea '[select(.kind == "CephCluster")] | .[0].spec.cephConfig.mgr."mgr/pg_autoscaler/threshold"
    | select(tag == "!!str")' "$rendered"/*.yaml)" = 1.0 ] \
    || fail "$cluster: Ceph's autoscaler acts on every change it recommends"
  read -r warn crit <<<"$(yq ea '[select(.kind == "CephCluster")] | .[0].spec.cephConfig.mgr
    | (.mon_pool_quota_warn_threshold // "-") + " " + (.mon_pool_quota_crit_threshold // "-")' "$rendered"/*.yaml)"
  [[ $warn =~ ^[1-9][0-9]?$ && $crit =~ ^[1-9][0-9]?$ ]] && [ "$warn" -lt "$crit" ] \
    || fail "$cluster: Ceph warns before a pool's quota stops its writes, at a whole percentage of it, and calls it an" \
      "error at a higher one below 100: $warn, $crit"
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
  bad=$(yq ea '([select(.apiVersion == "csi.ceph.io/v1" and .kind == "OperatorConfig")]
    | .[0].spec.driverSpecDefaults.nodePlugin.priorityClassName // "") as $default
    | [select(.apiVersion == "csi.ceph.io/v1" and .kind == "Driver")
      | select((.spec.nodePlugin.priorityClassName // $default) != "system-node-critical") | .metadata.name] | .[]' \
    "$rendered"/*.yaml | paste -sd' ')
  [ -z "$bad" ] || fail "$cluster: each CSI driver's node plugin runs at system-node-critical, which a shutdown stops" \
    "last: $bad"
  cephcsi=$(yq ea '[select(.kind == "HelmRelease" and .metadata.name == "rook-ceph")] | .[0].spec.values.csi.cephcsi
    | .repository + ":" + .tag' "$rendered"/*.yaml)
  barrier=$(yq ea '[select(.kind == "DaemonSet" and .metadata.namespace == "rook-ceph"
    and .metadata.name == "unmap-barrier") | .spec.template.spec.containers[].image] | join(" ")' "$rendered"/*.yaml)
  [ "$barrier" = "$cephcsi" ] || fail "$cluster: the DaemonSet unmap-barrier in rook-ceph, which holds a shutdown" \
    "until no volume is mapped, runs the CSI node plugin's image, already on every node that maps volumes," \
    "$cephcsi: $barrier"
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

bad=$(python3 -I -c "$migrations" <"$work/migrations.jsonl")
[ -z "$bad" ] || fail "Kanidm's migrations: $bad"
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
