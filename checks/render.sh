# Renders every Flux Kustomization of every cluster under kubernetes/clusters the way Flux would, offline, also those
# other Kustomizations create: the cluster's, each tenant's, then the tenant's apps and hosts. Each gets the values
# its own sources hold, a stand-in for each encrypted one, and strict substitution. Then checks the rules Flux itself
# wouldn't catch, on what was rendered rather than on what a file says.
# Usage: CLUSTER_RANGES=<the servers' ranges> KANIDM_VERSION=<the Kanidm client's version> \
#   NETBIRD_PINS=<checks/netbird.nix as JSON> NETBIRD_PEER_COLUMNS=<the servers' suveraen.mesh.peerColumns as JSON> \
#   render.sh <kubernetes directory> <output directory>
set -euo pipefail
: "${CLUSTER_RANGES:?the ranges the servers give k3s (nixos/cluster.nix), as <setting>=<range> words}"
: "${KANIDM_VERSION:?the version of the Kanidm client the platform builds, which the Kanidm server must match}"
: "${NETBIRD_PINS:?the NetBird release and images checks/netbird.nix pins, as JSON}"
: "${NETBIRD_PEER_COLUMNS:?the columns of peers the scrub blanks and keeps, as nixos/mesh.nix names them, as JSON}"
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
appkinds+=',HelmRelease.helm.toolkit.fluxcd.io,HTTPRoute.gateway.networking.k8s.io'
# Copies of an app's volume and their checks (components/volsync).
appkinds+=',ReplicationSource.volsync.backube,ReplicationDestination.volsync.backube,CronJob.batch'
# The tenant's PostgreSQL also claims its bucket, tells Barman where to archive and fetches a copy back.
pgkinds=',ObjectBucketClaim.objectbucket.io,ObjectStore.barmancloud.cnpg.io,Job.batch'
export quotas hard appkinds
privileged=pod-security.kubernetes.io/audit=privileged,pod-security.kubernetes.io/enforce=privileged
privileged+=,pod-security.kubernetes.io/warn=privileged
# All Rook may change of what its chart renders (platform/rook-ceph): the CSI operator's network policy, whose one
# egress rule names no peer, keeps its ingress alone. A patch is held by its operations, not by how they are written.
rookpatch='[{"kustomize":{"patches":[{"patch":[{"op":"remove","path":"/spec/egress"},{"op":"replace",'
rookpatch+='"path":"/spec/policyTypes","value":["Ingress"]}],"target":{"group":"networking.k8s.io",'
rookpatch+='"kind":"NetworkPolicy","name":"ceph-csi-ceph-csi-controller-manager"}}]}}]'
export rookpatch
# Apps that terminate their users' TLS themselves, behind a listener that passes it through (edge/passthrough, or
# edge/passthrough-app for a host on the tenant's app domain), which skips the gateway's limits and pseudonyms, as it
# reads no request: an identity server, which must see its users' passwords and passkeys where nothing else does, and
# a mesh's control plane, whose streams and relayed connections outlive any request timeout.
passthroughapps='kanidm netbird'
# Traefik's options that could log, measure or trace clients, or trust their addresses, or bypass the gateway's own
# settings for them.
options='(?i)^--?(accesslog|log|metrics|tracing|entrypoints|forwardedheaders|proxyprotocol|experimental|providers)([.=]|$)'
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
# Prints the settings of Kanidm's server.toml that are wrong for the host given, and what else could set any, from the
# rendered app (a JSON list on stdin).
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
# Kanidm takes each setting from its environment too, as KANIDM_<SETTING>, and OpenTelemetry where to send to as
# OTEL_*: it runs the command its image gives, with no environment but where server.toml is mounted.
values = release[0]["spec"]["values"] if release else {}
toml = [m.get("path", "").rstrip("/") + "/server.toml" for p in (values.get("persistence") or {}).values()
        if p.get("type") == "configMap" and p.get("name") == "kanidm" for m in p.get("globalMounts") or []
        if not m.get("subPath")]
for name, ctl in (values.get("controllers") or {}).items():
    containers = {f"{name}/{n}": x for g in ("initContainers", "containers") for n, x in (ctl.get(g) or {}).items()}
    containers[f"{name}/defaultContainerOptions"] = ctl.get("defaultContainerOptions") or {}
    for n, x in containers.items():
        e = x.get("env") or {}
        if isinstance(e, list):
            e = {v.get("name"): {k: w for k, w in v.items() if k != "name"} for v in e}
        e = {k: v["value"] if isinstance(v, dict) and list(v) == ["value"] else v for k, v in e.items()}
        want = {"KANIDM_CONFIG": toml[0] if len(toml) == 1 else None} if n == "kanidm/app" else {}
        bad += [f"{n}:env:{k}" for k in sorted(set(map(str, e)) | set(want)) if e.get(k) != want.get(k)]
        bad += [f"{n}:{k}" for k in ("envFrom", "command", "args") if x.get(k)]
print(" ".join(bad))
'
# Prints what the pods of an app's charts, all app-template's, and of its own Deployments (components/egress) need at
# their most beyond its namespace's quota, from the rendered app (a JSON list on stdin): each controller's and
# Deployment's pods, with the one more a rolling update starts, at their requests and limits, the LimitRange's
# defaults for what a container leaves out, each init container against the others together, and one more pod at
# the defaults, such as one that only asks the app something.
quotafit='
import json, math, re, sys
docs = [d for d in json.load(sys.stdin) if isinstance(d, dict)]
keys = ["requests.cpu", "requests.memory", "limits.memory", "requests.ephemeral-storage", "limits.ephemeral-storage"]
units = {"m": 1, "": 1000, "k": 1000**2, "M": 1000**3, "G": 1000**4, "T": 1000**5, "Ki": 1000 * 1024,
         "Mi": 1000 * 1024**2, "Gi": 1000 * 1024**3, "Ti": 1000 * 1024**4}

def quantity(q):
    m = re.fullmatch(r"([0-9]+)(m|k|M|G|T|Ki|Mi|Gi|Ti)?", str(q))
    if not m:
        raise SystemExit(f"{q} is not a whole quantity")
    return int(m.group(1)) * units[m.group(2) or ""]

defaults = [l for d in docs if d.get("kind") == "LimitRange" for l in d["spec"]["limits"]
            if l.get("type") == "Container"]
quota = [d for d in docs if d.get("kind") == "ResourceQuota"][0]["spec"]["hard"]

# What a container asks for and may use once the API server has taken its limits for requests it left out, and the
# LimitRange has given it its defaults.
def container(r):
    out = {}
    for key in keys:
        kind, name = key.split(".", 1)
        given = (r.get(kind) or {}).get(name)
        if given is None and kind == "requests":
            given = (r.get("limits") or {}).get(name)
        if given is None:
            given = (defaults[0].get("default" if kind == "limits" else "defaultRequest") or {}).get(name, 0)
        out[key] = quantity(given)
    return out

# The resources of a container of a controller, with the defaults the chart gives its containers.
def resources(ctl, c, init):
    r = c.get("resources") or {}
    options = (ctl.get("defaultContainerOptions") or {}).get("resources") or {}
    if init and ctl.get("applyDefaultContainerOptionsToInitContainers", True) is not True:
        return r
    if ctl.get("defaultContainerOptionsStrategy", "overwrite") == "merge":
        return {k: {**(options.get(k) or {}), **(r.get(k) or {})} for k in set(options) | set(r)}
    return r or options

def enabled(ctl, group):
    return [c for c in (ctl.get(group) or {}).values() if c.get("enabled", True) is not False]

def surged(count, surge):
    surge = str(surge)
    return count + (math.ceil(count * int(surge[:-1]) / 100) if surge.endswith("%") else int(surge))

need, pods = container({}), 1

def run(count, running, once):
    global pods
    pods += count
    for k in keys:
        need[k] += count * max([sum(r[k] for r in running)] + [r[k] for r in once])

for release in docs:
    if release.get("kind") != "HelmRelease":
        continue
    for ctl in ((release["spec"].get("values") or {}).get("controllers") or {}).values():
        if ctl.get("enabled", True) is False:
            continue
        inits = enabled(ctl, "initContainers")
        running = [container(resources(ctl, c, False)) for c in enabled(ctl, "containers")]
        running += [container(resources(ctl, c, True)) for c in inits if c.get("restartPolicy") == "Always"]
        once = [container(resources(ctl, c, True)) for c in inits if c.get("restartPolicy") != "Always"]
        replicas = ctl.get("replicas", 1)
        count = 1 if replicas is None else int(replicas)
        if ctl.get("type", "deployment") == "deployment" and ctl.get("strategy", "Recreate") == "RollingUpdate":
            rolling = ctl.get("rollingUpdate") or {}
            count = surged(count, rolling.get("maxSurge", rolling.get("surge", "25%")))
        run(count, running, once)
for deployment in docs:
    if deployment.get("kind") != "Deployment":
        continue
    spec = deployment["spec"]["template"]["spec"]
    inits = spec.get("initContainers") or []
    running = [container(c.get("resources") or {}) for c in spec["containers"]]
    running += [container(c.get("resources") or {}) for c in inits if c.get("restartPolicy") == "Always"]
    once = [container(c.get("resources") or {}) for c in inits if c.get("restartPolicy") != "Always"]
    count = int(deployment["spec"].get("replicas", 1))
    strategy = deployment["spec"].get("strategy") or {}
    if strategy.get("type", "RollingUpdate") == "RollingUpdate":
        count = surged(count, (strategy.get("rollingUpdate") or {}).get("maxSurge", "25%"))
    run(count, running, once)

def shown(key, n):
    return f"{n}m" if key.endswith("cpu") else f"{n / 1000 / 1024**2:g}Mi"

bad = [f"{k} {shown(k, need[k])} of {quota[k]}" for k in keys if need[k] > quantity(quota[k])]
bad += [f"pods {pods} of " + quota["pods"]] if pods > int(quota["pods"]) else []
print(", ".join(bad))
'
# Prints what is wrong with the hosts an app's proxy may tunnel to (components/egress), EGRESS_HOSTS as its template
# gives it, then the domains its tenant's and the cluster's hosts are on: 1 to 8 names as <name>:443, none twice, none
# an address, a wildcard, a name of the cluster's own or one on those domains.
egresshosts='
import json, re, sys
given, domains = sys.argv[1], [d for d in sys.argv[2:] if d] + ["svc", "local"]
label = "[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
form = re.compile(rf"((?:{label}[.])+[a-z](?:[a-z0-9-]{{0,61}}[a-z0-9])?):443")
try:
    hosts = json.loads(given)
except ValueError:
    hosts = None
if not isinstance(hosts, list) or not 1 <= len(hosts) <= 8:
    print(given or "none")
    raise SystemExit
bad = []
for h in hosts:
    m = form.fullmatch(h) if isinstance(h, str) else None
    name = m.group(1) if m else ""
    if not m or len(name) > 253 or hosts.count(h) > 1 or any(name == d or name.endswith("." + d) for d in domains):
        bad.append(json.dumps(h))
print(" ".join(dict.fromkeys(bad)))
'
# What is wrong with a tenant's mesh (apps/netbird) as rendered, a JSON list on stdin, for its host, its tenant's Kanidm,
# the servers' STUN port, its tenant's PostgreSQL image and the tenant given: its two controllers and their images,
# users, arguments and environment, and who reaches the tenant's PostgreSQL and Kanidm; management.json, which
# management fills in from its environment; nginx.conf, which routes five paths alone; and scrub.sql, which blanks what
# the servers' check knows a device reports beyond the mesh's needs.
netbirdconfig='
import json, os, re, sys
docs = [d for d in json.load(sys.stdin) if isinstance(d, dict)]
host, idm, stun, postgres, tenant = sys.argv[1:]
pins = json.loads(os.environ["NETBIRD_PINS"])
columns = json.loads(os.environ["NETBIRD_PEER_COLUMNS"])
bad = []

def server(name):
    return "ghcr.io/netbirdio/" + name + ":" + pins["version"] + "@" + pins["digests"][name]

dashboard = "docker.io/netbirdio/dashboard:" + pins["dashboard"]["tag"] + "@" + pins["dashboard"]["digest"]
images = {"web-env": dashboard, "web": dashboard, "signal": server("signal"), "relay": server("relay"),
          "management": server("management"), "scrub": postgres}

def one(kind, name):
    found = [d for d in docs if d.get("kind") == kind and d["metadata"]["name"] == name]
    return found[0] if len(found) == 1 else {}

release = one("HelmRelease", "netbird").get("spec") or {}
controllers = (release.get("values") or {}).get("controllers") or {}
shape = {name: (sorted(c.get("initContainers") or {}), sorted(c.get("containers") or {}))
         for name, c in controllers.items()}
if shape != {"netbird": (["web-env"], ["relay", "signal", "web"]), "management": ([], ["management", "scrub"])}:
    bad.append(f"controllers {shape}")
containers = {}
for name, c in controllers.items():
    if c.get("type", "deployment") != "deployment" or c.get("strategy") != "Recreate" or c.get("replicas", 1) != 1 \
            or c.get("enabled", True) is not True:
        bad.append(f"{name} is not one pod that goes before the next starts")
    for group in "initContainers", "containers":
        containers.update(c.get(group) or {})

def env(c):
    e = c.get("env") or {}
    if isinstance(e, list):
        e = {x.get("name"): {k: v for k, v in x.items() if k != "name"} for x in e}
    return {k: v["value"] if isinstance(v, dict) and list(v) == ["value"] else v for k, v in e.items()}

def secret(key):
    return {"valueFrom": {"secretKeyRef": {"name": "netbird", "key": key}}}

envs = {
    "web-env": {"AUTH_AUTHORITY": f"https://{idm}/oauth2/openid/netbird-oidc", "AUTH_CLIENT_ID": "netbird-oidc",
                "AUTH_AUDIENCE": "netbird-oidc", "AUTH_SUPPORTED_SCOPES": "openid", "AUTH_REDIRECT_URI": "/nb-auth",
                "AUTH_SILENT_REDIRECT_URI": "/nb-silent-auth", "USE_AUTH0": "false",
                "NETBIRD_MGMT_API_ENDPOINT": f"https://{host}", "NETBIRD_MGMT_GRPC_API_ENDPOINT": f"https://{host}",
                "NETBIRD_TOKEN_SOURCE": "accessToken"},
    "web": {}, "signal": {},
    "relay": {"NB_AUTH_SECRET": secret("relay-secret")},
    "management": {"NB_DISABLE_GEOLOCATION": "true", "NB_EVENT_ACTIVITY_LOG_ENABLED": "false",
                   "SSL_CERT_DIR": "/etc/ssl/certs:/etc/netbird-roots",
                   "NB_STORE_ENGINE_POSTGRES_DSN": secret("store-dsn"), "NB_STORE_KEY": secret("store-key"),
                   "NB_RELAY_SECRET": secret("relay-secret")},
    "scrub": {"PGHOST": f"postgres-rw.{tenant}-postgres.svc", "PGPORT": "5432", "PGDATABASE": "netbird",
              "PGUSER": "netbird", "PGSSLMODE": "require", "PGPASSWORD": secret("db-password")},
}
levels = {"signal": ["info", "warn", "error"], "relay": ["warn", "error"], "management": ["info", "warn", "error"]}
for name, c in containers.items():
    image = c.get("image") or {}
    ref = image.get("repository", "") + (":" + image["tag"] if image.get("tag") else "") \
        + ("@" + image["digest"] if image.get("digest") else "")
    if ref != images.get(name):
        bad.append(f"{name} image {ref}")
    have, want = env(c), envs.get(name, {})
    bad += [f"{name} env {k}" for k in sorted(set(have) | set(want)) if have.get(k) != want.get(k)]
    if c.get("envFrom"):
        bad.append(f"{name} envFrom")
    # Any process on the node may read a command line.
    line = " ".join(str(a) for a in (c.get("command") or []) + (c.get("args") or []))
    bad += [f"{name} puts {k} in its command line" for k, v in sorted(have.items())
            if isinstance(v, dict) and "valueFrom" in v and re.search(rf"[$]([{{(]{k}[)}}]|{k}\b)", line)]
    args = c.get("args") or []
    if name in levels:
        given = [a.split("=", 1)[1] for a in args if str(a).startswith("--log-level=")]
        given += [args[i + 1] for i, a in enumerate(args[:-1]) if a == "--log-level"]
        if len(given) != 1 or given[0] not in levels[name]:
            bad.append(f"{name} log level {given}")
        context = c.get("securityContext") or {}
        if context.get("runAsUser") != 65532 or context.get("runAsGroup") != 65532:
            bad.append(f"{name} runAsUser and runAsGroup")
missing = {"--disable-anonymous-metrics", "--disable-legacy-port"}
missing -= set((containers.get("management") or {}).get("args") or [])
bad += [f"management without {a}" for a in sorted(missing)]
if f"--exposed-address=rels://{host}:443" not in ((containers.get("relay") or {}).get("args") or []):
    bad.append("relay exposed elsewhere")
aliases = ((controllers.get("management") or {}).get("pod") or {}).get("hostAliases")
if not isinstance(aliases, list) or [(a.get("ip"), sorted(a.get("hostnames") or [])) for a in aliases] \
        != [("127.0.0.1", ["api.github.com", "metrics.netbird.io", "pkgs.netbird.io"])]:
    bad.append("management hostAliases")
policies = sorted(d["metadata"]["name"] for d in docs if d.get("kind") == "NetworkPolicy")
if policies != ["default-deny", "dns", "internet", "same-namespace", "to-kanidm", "to-postgres"]:
    bad.append(f"network policies {policies}")
# The edge pod faces the internet, and needs neither.
for name in "to-kanidm", "to-postgres":
    if (one("NetworkPolicy", name).get("spec") or {}).get("podSelector") \
            != {"matchLabels": {"app.kubernetes.io/controller": "management"}}:
        bad.append(f"{name} for more than management")

data = one("ConfigMap", "netbird").get("data") or {}
text = data.get("management.json", "")
# Management fills these in from its environment, where nothing but Secret netbird may give a value.
secrets = {k for k, v in env(containers.get("management") or {}).items()
           if isinstance(v, dict) and list(v) == ["valueFrom"] and list(v["valueFrom"]) == ["secretKeyRef"]
           and v["valueFrom"]["secretKeyRef"].get("name") == "netbird"
           and v["valueFrom"]["secretKeyRef"].get("optional", False) is False}
for t in re.findall(r"[{][{].*?[}][}]", text, re.S):
    m = re.fullmatch(r"[{][{] [.](NB_[A-Z0-9_]+) [}][}]", t)
    if not m or m.group(1) not in secrets:
        bad.append(f"management.json {t} not from Secret netbird")
try:
    j = json.loads(text)
except ValueError as e:
    j = {}
    bad.append(f"management.json: {e}")
http = j.get("HttpConfig") or {}
pkce = (j.get("PKCEAuthorizationFlow") or {}).get("ProviderConfig") or {}
template = re.compile(r"[{][{] [.]NB_[A-Z0-9_]+ [}][}]")
for what, ok in [
    ("DisableDefaultPolicy", j.get("DisableDefaultPolicy") is True),
    ("EmbeddedIdP", "EmbeddedIdP" not in j),
    ("ManagerType", (j.get("IdpManagerConfig") or {}).get("ManagerType") == "none"),
    ("DeviceAuthorizationFlow", (j.get("DeviceAuthorizationFlow") or {}).get("Provider") == "none"),
    ("OIDCConfigEndpoint", http.get("OIDCConfigEndpoint")
        == f"https://{idm}/oauth2/openid/netbird-oidc/.well-known/openid-configuration"),
    ("AuthAudience", http.get("AuthAudience") == "netbird-oidc"),
    ("ClientID", pkce.get("ClientID") == "netbird-oidc" and pkce.get("Audience") == "netbird-oidc"),
    ("Scope", pkce.get("Scope") == "openid"),
    ("ClientSecret", "ClientSecret" not in text),
    # Every device sign-in asks Kanidm for a fresh one.
    ("DisablePromptLogin", "DisablePromptLogin" not in pkce),
    ("RedirectURLs", pkce.get("RedirectURLs") == ["http://localhost:53000/", "http://localhost:54000/"]),
    ("UseIDToken", pkce.get("UseIDToken") is False),
    # An address nothing connects from: none at all would trust what every client says of its address.
    ("TrustedPeers", (j.get("ReverseProxy") or {}).get("TrustedPeers") == ["192.0.2.0/32"]),
    ("Signal", j.get("Signal") == {"Proto": "https", "URI": f"{host}:443"}),
    ("Relay", (j.get("Relay") or {}).get("Addresses") == [f"rels://{host}:443"]
        and template.fullmatch(str((j.get("Relay") or {}).get("Secret")))),
    ("Stuns", j.get("Stuns") == [{"Proto": "udp", "URI": f"stun:{host}:{stun}"}]),
    ("StoreConfig", (j.get("StoreConfig") or {}).get("Engine") == "postgres"),
    ("DataStoreEncryptionKey", template.fullmatch(str(j.get("DataStoreEncryptionKey")))),
]:
    if not ok:
        bad.append(f"management.json {what}")

# nginx.conf as directives: a name, its arguments and, for a block, what it holds.
def parse(text):
    tokens = re.findall(r"\"((?:[^\"\\]|\\.)*)\"|(#[^\n]*)|([{};])|([^\s{};\"#]+)", text)
    stack = [[]]
    words = []
    for quoted, comment, mark, word in tokens:
        if comment:
            continue
        if mark == ";":
            stack[-1].append((words[0], words[1:], None))
            words = []
        elif mark == "{":
            block = []
            stack[-1].append((words[0], words[1:], block))
            stack.append(block)
            words = []
        elif mark == "}":
            stack.pop()
        else:
            words.append(word or quoted)
    return stack[0]

def find(block, name):
    return [d for d in block or [] if d[0] == name]

def walk(block):
    for d in block or []:
        yield d
        yield from walk(d[2])

conf = parse(data.get("nginx.conf", ""))
if ("daemon", ["off"], None) not in conf:
    bad.append("nginx.conf without daemon off")
logs = [d[1] for d in walk(conf) if d[0] == "access_log"]
https = find(conf, "http")
if not logs or any(a != ["off"] for a in logs) or ("access_log", ["off"], None) not in (https[0][2] if https else []):
    bad.append("nginx.conf logs access")
servers = [d for h in https for d in find(h[2], "server")]
server_block = servers[0][2] if len(servers) == 1 and len(https) == 1 else []
if not server_block:
    bad.append("nginx.conf has no one server")
if find(server_block, "error_page") != [("error_page", ["404", "/404.html"], None)]:
    bad.append("nginx.conf without error_page 404 /404.html")
upstreams = {"/relay": ("proxy_pass", "http://127.0.0.1:8082"),
             "/signalexchange.SignalExchange/": ("grpc_pass", "grpc://127.0.0.1:10000"),
             "/management.ManagementService/": ("grpc_pass", "grpc://netbird-management:8081"),
             "/api/": ("proxy_pass", "http://netbird-management:8081")}
refused = ["= /api/setup", "/api/users/invites/", "/api/reverse-proxy/"]
seen = []
for _, args, body in find(server_block, "location"):
    where = " ".join(args)
    seen.append(where)
    passes = [(d[0], d[1]) for d in walk(body) if d[0] in ("proxy_pass", "grpc_pass")]
    if find(body, "location"):
        bad.append(f"nginx.conf location {where} holds others")
    if where in upstreams:
        if passes != [(upstreams[where][0], [upstreams[where][1]])]:
            bad.append(f"nginx.conf {where} not routed to {upstreams[where][1]} alone")
        header = "proxy_set_header" if upstreams[where][0] == "proxy_pass" else "grpc_set_header"
        for name in "X-Forwarded-For", "X-Real-IP", "Forwarded":
            if (header, [name, ""], None) not in body:
                bad.append(f"nginx.conf {where} keeps {name}")
    elif where in refused:
        if body != [("return", ["404"], None)]:
            bad.append(f"nginx.conf {where} not refused")
    elif where == "/":
        if passes or find(body, "root") != [("root", ["/web"], None)]:
            bad.append("nginx.conf / is not the dashboard alone")
        csp = [d[1][1] for d in find(body, "add_header") if d[1][:1] == ["Content-Security-Policy"] and len(d[1]) > 1]
        named = {w for p in csp for w in re.split(r"[\s;]+", p) if "." in w or "://" in w}
        if len(csp) != 1 or named - {f"https://{idm}", f"https://{host}", f"wss://{host}"}:
            bad.append(f"nginx.conf CSP names {sorted(named)}")
    else:
        bad.append(f"nginx.conf location {where}")
bad += [f"nginx.conf {where} not refused" for where in refused if where not in seen]
bad += [f"nginx.conf {where} not routed" for where in list(upstreams) + ["/"] if where not in seen]

blanked = []
for literal in re.findall(r"\x27([{].*?[}])\x27::jsonb", data.get("scrub.sql", ""), re.S):
    try:
        blanked.append(json.loads(literal))
    except ValueError:
        blanked.append(literal)
if blanked != [columns["scrubbed"]]:
    bad.append(f"scrub.sql blanks {blanked}")
print("; ".join(bad))
'
# Prints where a value a Kustomization took from a Secret (JSON lines in the file given, with its directory of what
# its migrations take IDs from) lands outside a Secret, the standby CA's external account ID and its migrations' IDs,
# in what it rendered (JSON lines on stdin). Anything else may be read by more than those who may read Secrets: the
# servers' checks list the Flux objects whose values these are. A tenant's domains name its hosts, which its Gateways
# and certificates hold as well. A value shorter than 8 characters could be part of anything, and isn't followed: only
# a test cluster's values are, as every other's are encrypted, which render gives stand-ins far longer.
secretsonly='
import json, sys
taken = {}
for line in open(sys.argv[1]):
    s = json.loads(line)
    for key, value in (s["values"] or {}).items():
        if key not in ("TENANT_DOMAIN", "TENANT_APP_DOMAIN") and len(str(value)) >= 8:
            taken.setdefault(s["name"], []).append((key, s["source"], str(value)))


def strings(node, path=()):
    if isinstance(node, dict):
        for k, v in node.items():
            yield from strings(v, path + (str(k),))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from strings(v, path + (str(i),))
    elif isinstance(node, str):
        yield path, node


bad = set()
for line in sys.stdin:
    r = json.loads(line)
    name = r["name"]
    if name not in taken:
        continue
    with open(f"{sys.argv[2]}/{name}.idkeys") as f:
        ids = set(f.read().split())
    for d in r["docs"]:
        kind = d.get("kind") if isinstance(d, dict) else None
        if kind in (None, "Secret"):
            continue
        where = "{}/{}".format(kind, (d.get("metadata") or {}).get("name"))
        for path, text in strings(d):
            for key, source, value in taken[name]:
                if value in text and not (
                    kind == "ClusterIssuer" and path == ("spec", "acme", "externalAccountBinding", "keyID")
                    or kind == "ConfigMap" and key in ids
                ):
                    bad.add(f"{name} puts {key} from {source} in {where}")
print("; ".join(sorted(bad)))
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
# The platform's files that are the same in every tenant, with their IDs written in them (apps/kanidm/app).
founding="10-members.json 10-platform-admins.json 10-tenant-admins.json 20-groups.json"
# Prints each ID of the migrations in a ConfigMap as Flux builds it before it substitutes anything (JSON on stdin) that
# isn't ${<APP>_<NAME>_ID} alone, for the app's prefix given, but in the founding files given, which a tenant's Kanidm
# applies as it first starts, before it takes a sign-in, after "bad "; after "founding " each of those that takes
# anything from its tenant; after "make " each file that makes an entry from anything but its entry's ID and its own,
# ${<APP>_<NAME>_CREATE_ID}; after "entry " each entry named by such a file's ID; and after "key " each key the others
# take. A tenant admin may make a person with any ID, so every other ID comes from the tenant's Secret, which no one
# there reads, and has no default, which would be the same in every tenant.
sourceids='
import json, re, sys
cm, prefix, founding = json.load(sys.stdin), sys.argv[1], sys.argv[2].split()
key = re.compile(r"[$][{](" + prefix + r"_[A-Z0-9_]+_ID)[}]")
for name, text in sorted((cm.get("data") or {}).items()):
    where = cm["metadata"]["name"] + "/" + name
    if cm["metadata"]["name"] == "kanidm-migrations" and name in founding:
        if "$" in text:
            print(f"founding {where}")
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
        if a is not m and k and k.group(1).endswith("_CREATE_ID"):
            print(f"entry {where}: {i}")
    # A file that makes an entry never changes, so its bytes hang on its two IDs alone: its own, named for the entry.
    if len(assertions) == 1 and isinstance(assertions[0], dict) and "class" in assertions[0]:
        made = key.fullmatch(str(assertions[0].get("id")))
        fid = m.get("id")
        if made and fid != "${" + made.group(1)[:-3] + "_CREATE_ID}":
            print(f"make {where}: {made.group(1)[:-3]}_CREATE_ID, not {fid}")
        if text.count("$") != 2:
            print(f"make {where}: nothing but its IDs from the Secret")
'
# Prints what is wrong with the migrations every tenant's Kanidm applies (JSON lines from migrationsource on stdin),
# given the platform's founding files. Kanidm applies each file in its own transaction and only logs what fails, so
# render refuses what it would skip.
migrations='
import json, re, sys
from urllib.parse import urlsplit
uuid = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
# Kanidm makes its builtin entries below this, out of reach of migrations, which skip them without a word.
dynamic = "00000000-0000-0000-0001-000000000000"
basic = ["account", "oauth2_resource_server", "oauth2_resource_server_basic"]
public = ["account", "oauth2_resource_server", "oauth2_resource_server_public"]
founding = set(sys.argv[1].split())
# Kanidm makes an account only with a display name and a client only with a page to land on, both of which the file
# that changes it then sets: until then, a name and an address no one can reach.
pending = "https://pending.invalid/"
# What a file that changes an entry states, every key of its kind and nothing more: Kanidm leaves alone what such a
# file leaves out, so a value dropped from it would stay in every tenant that held it.
owned = {
    "group": {"entry_managed_by"},
    "app policy": {"entry_managed_by", "credential_type_minimum"},
    "policy": {"entry_managed_by", "credential_type_minimum", "authsession_expiry", "privilege_expiry"},
    "basic": {"displayname", "oauth2_rs_origin", "oauth2_rs_origin_landing", "oauth2_rs_scope_map"},
}
owned["public"] = owned["basic"]
# Nested in idm_admins, a group takes members only from its manager, so idm_admins manages platform-admins. tenant-admins
# manage every other group the files declare, which lets them change its members alone, never rename or delete it.
managers = {"platform-admins": "idm_admins"}
# What no migration can set on a client: a confidential one that sends no PKCE, a public one that redirects to the
# device it runs on.
flags = {"suveraen/disable-pkce": "basic", "suveraen/localhost-redirects": "public"}
kinds = {"basic": "confidential", "public": "public"}
placeholder = {"annotations": {"kustomize.toolkit.fluxcd.io/ssa": "IfNotPresent"},
               "stringData": {"client-secret": "pending"}}
problems, ids, names, changed, made, removed = [], {}, {}, {}, set(), {}

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

def kind_of(classes, platform):
    if classes == ["group"]:
        return "group"
    if classes == ["account_policy", "group"]:
        return "policy" if platform else "app policy"
    if classes in (basic, public) and not platform:
        return "basic" if classes == basic else "public"
    return None

def floor(where, name, kind, value):
    # Kanidm holds a person to the strictest policy of all their groups, so the group of an app only tightens what its
    # members may enrol.
    if kind == "app policy" and value != "passkey":
        bad(where, f"an app group that is an account policy has its members enrol passkeys alone: {name}")
    if name == "platform-admins" and value != "attested_passkey":
        bad(where, "platform-admins sign in with passkeys of an approved make and model alone")
    elif kind == "policy" and value not in ("passkey", "attested_passkey"):
        bad(where, f"{name} sign in with passkeys alone")

for line in sys.stdin:
    s = json.loads(line)
    app, source, tenant = s["app"], s["source"], s["cluster"] + "/" + s["tenant"]
    platform = source == "kanidm-migrations"
    # Kanidm applies the files of every source in the order of their names, so removals come before the files that
    # make entries and those before the files that change them, and no two sources hold a file of the same name.
    who, remover, changer = ("the platform", "04-<name>.json", "20-<name>.json") if platform \
        else ("an app", f"05-{app}.json", f"50-{app}.json")
    creates, changes = {}, {}
    for key, text in sorted(s["files"].items()):
        where, own = f"{tenant} {source}/{key}", f"{source}/{key}"
        try:
            m = json.loads(text)
        except ValueError as e:
            bad(where, f"not JSON: {e}")
            continue
        if not isinstance(m, dict) or sorted(m) != ["assertions", "id"] or not isinstance(m["assertions"], list) \
                or not m["assertions"] or not all(isinstance(a, dict) for a in m["assertions"]):
            bad(where, "a migration has an id and assertions, at least one, as Kanidm refuses an empty one")
            continue
        # The IDs of the founding files are the same in every tenant, all others differ from tenant to tenant. Kanidm
        # records each file under an ID of its own, so no ID names two things, but the entry one file makes and one
        # changes.
        first = platform and key in founding
        for n, a in enumerate([m] + m["assertions"]):
            i = a.get("id")
            if not isinstance(i, str) or not uuid.fullmatch(i) or i < dynamic:
                bad(where, f"IDs are UUIDs in lowercase from {dynamic} on, not {i}")
            elif n == 0 or "class" in a or a.get("state") == "absent":
                claim(ids, i, f"{own}#{n}" if first else f"{tenant} {own}#{n}", where, "ID")
        with_class = ["class" in a for a in m["assertions"]]
        if any(with_class) and (not all(with_class) or len(with_class) != 1):
            bad(where, "a file makes one entry, with its classes, or changes or removes entries without them")
            continue
        if all(with_class):
            # Kanidm applies a file again whenever its bytes change, and refuses classes for an entry it holds, so
            # a file that makes an entry holds nothing that could change, laid out one way alone.
            a = m["assertions"][0]
            name, classes = a.get("name"), a.get("class")
            classes = sorted(classes) if isinstance(classes, list) else classes
            kind = kind_of(classes, platform)
            if kind is None:
                bad(where, f"the platform makes groups, and an app groups and an OAuth2 client, never people,"
                    f" accounts of another kind or classes Kanidm sets itself: {name} {classes}")
                continue
            if not isinstance(name, str) or not re.fullmatch(r"[a-z][a-z0-9]*(-[a-z0-9]+)+", name) \
                    and not (name == "members" and platform):
                bad(where, f"every name but members holds a -, which no login suveraen-idm admin makes does: {name}")
                continue
            claim(names.setdefault(tenant, {}), name, own, where, "name")
            want = {"state": "present", "id": a.get("id"), "class": classes, "name": name}
            if kind in ("policy", "app policy"):
                # Kanidm holds a person to the kind of credential their groups ask for only as one is enrolled, so a
                # group asks for it as it is made: the least its kind takes, which the file that changes it may raise.
                want["credential_type_minimum"] = "attested_passkey" if name == "platform-admins" else "passkey"
            if kind in ("basic", "public"):
                want |= {"displayname": name, "oauth2_rs_origin_landing": pending}
            canonical = json.dumps({"id": m["id"], "assertions": [want]}, separators=(",", ":")) + "\n"
            if key != f"10-{name}.json" or text != canonical:
                bad(where, f"the file that makes an entry never changes, as Kanidm denies it once applied, and is"
                    f" 10-{name}.json: {canonical.strip()}")
            made.add((tenant, a["id"]))
            creates[a["id"]] = (where, kind, a)
            continue
        states = {a.get("state") for a in m["assertions"]}
        if not states <= {"present", "absent"}:
            bad(where, f"an assertion is present or absent, not {sorted(map(str, states))}")
            continue
        if "absent" in states and (states != {"absent"} or not (re.fullmatch(r"04-[a-z0-9-]+[.]json", key)
                                                                if platform else key == remover)):
            bad(where, f"{who} removes its entries in {remover}, which holds removals alone, as Kanidm applies it"
                f" before the files that make entries")
        if "present" in states and not (re.fullmatch(r"20-[a-z0-9-]+[.]json", key) if platform else key == changer):
            bad(where, f"{who} changes its entries in {changer}")
        for n, a in enumerate(m["assertions"], 1):
            i = a.get("id")
            if a["state"] == "absent":
                if sorted(a) != ["id", "state"]:
                    bad(where, "a removal names an ID alone")
                removed.setdefault((tenant, i), where)
            else:
                claim(changed.setdefault(tenant, {}), i, f"{tenant} {own}#{n}", where, "the change of")
                changes[i] = (where, a)
    # Each entry as Kanidm holds it once both its files have applied.
    entries = []
    for i, (where, kind, a) in creates.items():
        name = a["name"]
        if i not in changes:
            bad(where, f"{name} is changed in {changer}, which states all it holds past its name")
            continue
        here, c = changes.pop(i)
        if "name" in c:
            bad(here, f"an entry takes its name from the file that makes it alone, so a change that reaches another"
                f" by a wrong ID renames none: {name}")
        keys = set(c) - {"state", "id", "name"}
        nulls = sorted(k for k in keys if c[k] is None)
        if keys != owned[kind] or nulls:
            bad(here, f"{name} states each of {sorted(owned[kind])}, none null, and nothing more:"
                f" {sorted(keys ^ owned[kind]) + nulls}")
        entries.append((here, kind, a | c))
    for i, (here, _) in changes.items():
        bad(here, f"a file changes the entries its own source makes, with its own file of classes: {i}")
    # A file names, besides its own entries, only members and tenant-admins, which every tenant holds from the start,
    # and the builtin idm_admins: Kanidm looks a name up among its entries before those of the file, so a name the
    # platform holds nowhere yet could be held by a person a tenant admin made, who would then manage the group or get
    # the scopes of the client.
    groups = set() if platform else {"members"}
    clients = []
    for here, kind, e in entries:
        name = e["name"]
        if "member" in e:
            bad(here, f"groups get their members from admins, not from files: {name}")
        if kind in ("group", "policy", "app policy"):
            manager = e.get("entry_managed_by")
            if manager != managers.get(name, "tenant-admins"):
                bad(here, f"idm_admins manages platform-admins, and tenant-admins every other group: {name}, not"
                    f" {json.dumps(manager)}")
            groups.add(name)
        if kind in ("policy", "app policy"):
            floor(here, name, kind, e.get("credential_type_minimum"))
        expiries = [e.get("authsession_expiry"), e.get("privilege_expiry")]
        if kind == "policy" and not all(type(v) is int and v > 0 for v in expiries):
            bad(here, f"{name} keeps a session and its admin actions for a whole number of seconds each, above 0")
        if kind in ("basic", "public"):
            # Kanidm holds every account to one, and fails the whole file without it.
            if not isinstance(e.get("displayname"), str) or not e["displayname"].strip():
                bad(here, f"a client has a display name: {name}")
            clients.append((here, kind, e))
    if platform:
        declared = {e["name"]: e for _, _, e in entries}
        where = f"{tenant} {source}"
        if not founding <= set(s["files"]) or not {"members", "platform-admins", "tenant-admins"} <= set(declared):
            bad(where, f"the platform groups are members, platform-admins and tenant-admins, in {sorted(founding)}")
        def within(a, most):
            e = a.get("privilege_expiry")
            return type(e) is int and 0 < e <= most
        if not within(declared.get("platform-admins", {}), 300):
            bad(where, "platform-admins are asked again within 5 minutes before an admin action")
        if not within(declared.get("tenant-admins", {}), 600):
            bad(where, "tenant-admins are asked again within 10 minutes before an admin action")
        continue
    where = f"{tenant} {source}"
    if [e["name"] for _, _, e in clients] != [f"{app}-oidc"]:
        bad(where, f"an app has one OAuth2 client, {app}-oidc")
    if any(not n.startswith(f"{app}-") or n == f"{app}-oidc" for n in groups - {"members"}):
        bad(where, f"an app names its groups {app}-<name>")
    secret = None
    for here, kind, e in clients:
        origins = e.get("oauth2_rs_origin")
        if not isinstance(origins, list) or not origins:
            bad(here, "a client names the addresses it may send members back to")
            origins = []
        for value in origins + [e.get("oauth2_rs_origin_landing")]:
            url(here, value, s["hosts"])
        values = e.get("oauth2_rs_scope_map")
        if not isinstance(values, list) or not values:
            bad(here, "a client maps at least one group to its scopes, in a list")
            values = []
        for v in values:
            if not isinstance(v, dict) or v.get("group") not in groups:
                bad(here, f"a client maps members or its own app groups alone: {v}")
        for flag, value in s["annotations"].items():
            if flag not in flags or value != "true":
                bad(where, f"sso-{app} carries no annotation but {sorted(flags)}, set to true: {flag}")
            elif flags[flag] != kind:
                bad(where, f"{flag} is for a {kinds[flags[flag]]} client")
        secret = kind == "basic"
    shape = [{k: v for k, v in x.items() if k in ("apiVersion", "kind", "type", "data", "stringData", "immutable")}
             | {"annotations": (x.get("metadata") or {}).get("annotations") or {}} for x in s["secrets"]]
    want = [{"apiVersion": "v1", "kind": "Secret"} | placeholder] if secret else []
    if secret is not None and shape != want:
        bad(where, f"an app with a confidential client holds Secret sso, which Flux makes once with client-secret"
            f" pending alone (components/sso-secret), and one with a public client none: {shape}")

for (tenant, i), where in removed.items():
    if (tenant, i) in made:
        bad(where, f"a removed entry is made by no file, as Kanidm would make it again once it forgets the ID: {i}")
    if i in changed.get(tenant, {}):
        bad(where, f"a removed entry is changed by no file, as Kanidm fails the file that changes it: {i}")
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
      yq ea -e "select(documentIndex == $i)"' | (.spec.path | test("^[.]/kubernetes/edge/passthrough(-app)?$"))
        as $through | ((.metadata | keys | join(",")) == "name"
        and (.spec | keys | sort | join(",")) == "dependsOn,path,postBuild"
        and (.spec.path | test("^[.]/kubernetes/edge/(app|identity|apex|passthrough|passthrough-app)$"))
        and ($through == false or strenv(passthrough) == "true")
        and ((([.spec.dependsOn[].name] | sort | join(",")) == (["${TENANT}-" + strenv(app), "gateway", "issuer"]
          | sort | join(",")) and $through == false)
          or (([.spec.dependsOn[].name] | sort | join(",")) == (["${TENANT}-" + strenv(app), "gateway"]
          | sort | join(",")) and $through))
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
  # A knob has one default wherever the app's templates read it, so a tenant that sets none gets one value.
  bad=$(grep -ohE '[$][{][A-Z0-9_]+:=[^}$]+[}]' $(find "$dir" -maxdepth 1 \( -name ks.yaml -o -name 'edge-*.yaml' \)) \
    | sort -u | sed -E 's/^[$][{]([A-Z0-9_]+):=.*/\1/' | sort | uniq -d | paste -sd' ' || true)
  [ -z "$bad" ] || fail "$dir: a knob has one default in all of its app's templates: $bad"
  # An app that names its own host, HOST, is served at it.
  host=$(yq 'select(documentIndex == 0) | .spec.postBuild.substitute.HOST // ""' "$dir/ks.yaml")
  if [ -n "$host" ]; then
    hosts=$(yq ea '[select(.spec.path // "" | test("^[.]/kubernetes/edge/")) | .spec.postBuild.substitute.HOST // ""]
      | .[]' $(find "$dir" -maxdepth 1 \( -name ks.yaml -o -name 'edge-*.yaml' \) | sort))
    grep -qxF -- "$host" <<<"$hosts" || fail "$dir/ks.yaml: an app's HOST is the HOST of one of its edges: $host"
  fi
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
    yq -o=json -I=0 '.[0]' <<<"$maps" | python3 -I -c "$sourceids" "$knob" "$founding" >"$found"
    bad=$(sed -n 's/^founding //p' "$found" | paste -sd' ' -)
    [ -z "$bad" ] || fail "$path: the founding files are the same in every tenant, and take nothing from it: $bad"
    bad=$(sed -n 's/^bad //p' "$found" | paste -sd';' -)
    [ -z "$bad" ] || fail "$path: an ID past the founding files comes from the tenant's Secret, as" \
      "\${${knob}_<NAME>_ID} alone, without a default, so no one in the tenant knows it before Kanidm makes its entry:" \
      "${bad//;/; }"
    bad=$(sed -n 's/^make //p' "$found" | paste -sd';' -)
    [ -z "$bad" ] || fail "$path: a file that makes an entry never changes, so it takes nothing from the tenant's" \
      "Secret but the entry's ID and its own, \${${knob}_<NAME>_CREATE_ID} for \${${knob}_<NAME>_ID}: ${bad//;/; }"
    bad=$(sed -n 's/^entry //p' "$found" | paste -sd';' -)
    [ -z "$bad" ] || fail "$path: an entry's ID is never that of the file that makes it, \${${knob}_<NAME>_CREATE_ID}," \
      "which Kanidm keeps for good as its record of the file, and fails a file that removes it: ${bad//;/; }"
  fi
  sed -n 's/^key //p' "$found" >"$w/$name.idkeys"
}
# The hosts passed through to a tenant's app, from its edges as rendered: on the tenant's own domain (edge/passthrough),
# or on its app domain (edge/passthrough-app).
passed() { # tenant, app
  local edge path domain
  grep -E "^$1-$2-edge-[a-z0-9]+ ./kubernetes/edge/passthrough(-app)?$" "$w/paths" | while read -r edge path; do
    domain=TENANT_APP_DOMAIN
    [ "$path" != ./kubernetes/edge/passthrough ] || domain=TENANT_DOMAIN
    yq ".spec.postBuild.substitute | .HOST + \".\" + .$domain" "$w/$edge.build.yaml"
  done
}
# What the record of the chart a platform release installs pins at a values path, as <image>:<tag>@<digest>, or none.
pinned() { # release, values path
  local chart tree
  chart=$(release=$1 yq ea '[select(.kind == "HelmRelease" and .metadata.namespace == "flux-system"
    and .metadata.name == strenv(release))] | .[0].spec.chartRef.name // ""' "$rendered"/*.yaml)
  tree=$(chart=$chart yq ea '[select(.kind == "HelmChart" and .metadata.namespace == "flux-system"
    and .metadata.name == strenv(chart))] | .[0].spec.chart // ""' "$rendered"/*.yaml)
  jq -r --arg path "$2" 'first(.images[]? | select(any(.values[]; . == $path)) | .image + ":" + .tag + "@" + .digest)
    // "none"' "$tree.json" 2>/dev/null || echo none
}
# A value the Kustomization being checked substitutes, or none.
v() { yq ".$1 // \"\"" "$w/$name.vars.yaml"; }
# The Kustomizations a render creates, each after the one that rendered it, to render in turn. Flux applies nothing but
# the release, which the servers give it as GitRepository suveraen.
spawned() { # parent, its render
  local bad
  bad=$(yq ea "[select($fluxks) | select(.spec.sourceRef.kind != \"GitRepository\"
    or .spec.sourceRef.name != \"suveraen\") | .metadata.name] | .[]" "$2" | paste -sd' ')
  [ -z "$bad" ] || fail "$cluster/$1: Kustomizations apply the release alone, from GitRepository suveraen: $bad"
  yq ea "[select($fluxks) | .metadata.name] | .[]" "$2" | sed "s/^/$1 /"
}
for dir in kubernetes/clusters/*/; do
  dir=${dir%/}
  cluster=$(basename "$dir")
  w=$work/$cluster
  rendered=$out/$cluster
  mkdir -p "$w" "$rendered"
  : >"$w/paths"
  : >"$w/secret-values"

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

  spawned cluster "$rendered/cluster.yaml" >"$w/queue"
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
      [ "$kind" != Secret ] || yq -o=json -I=0 "{\"name\": \"$name\", \"source\": \"$ref\", \"values\": .}" \
        "$w/src.vars.yaml" >>"$w/secret-values"
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
    # Flux substitutes nothing for a Kustomization without postBuild.
    yq "with(select(.spec | has(\"postBuild\"));
      .spec.postBuild.substitute = (load(\"$w/$name.vars.yaml\") * (.spec.postBuild.substitute // {}))
      | del(.spec.postBuild.substituteFrom))" "$w/$name.ks.yaml" >"$w/$name.build.yaml"
    flux build kustomization "$name" --path "$path" --kustomization-file "$w/$name.build.yaml" \
      --dry-run --strict-substitute >"$rendered/$name.yaml" || fail "$cluster/$name doesn't render"
    # No rule reads a CRD's schema, a megabyte of Gateway API's that every rule over all renders would read again.
    ! grep -q '^kind: CustomResourceDefinition$' "$rendered/$name.yaml" \
      || yq -i 'del(select(.kind == "CustomResourceDefinition") | .spec.versions[].schema)' "$rendered/$name.yaml"
    bad=$(grep -oE 'render-guard-[A-Z0-9_]+' "$rendered/$name.yaml" | sort -u | sed 's/^render-guard-//' \
      | paste -sd' ' || true)
    [ -z "$bad" ] || fail "$cluster/$name reads $bad: an app reads only its own keys, and a host none"
    echo "$name $path" >>"$w/paths"
    spawned "$name" "$rendered/$name.yaml" >>"$w/queue"
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
  # Flux reads nothing but the release, which the servers give it as GitRepository suveraen, and the charts the
  # platform builds from it.
  bad=$(yq ea '[select(.apiVersion // "" | test("^source[.]toolkit[.]fluxcd[.]io/")) | select(.kind != "HelmChart")
    | .kind + "/" + (.metadata.namespace // "") + "/" + .metadata.name] | .[]' "$rendered"/*.yaml | paste -sd' ')
  [ -z "$bad" ] || fail "$cluster: the release names no Flux source but the HelmCharts the platform builds from it:" \
    "$bad"
  bad=$(yq ea '[select(.kind == "HelmRelease" and (.spec | has("chart")))
    | .metadata.namespace + "/" + .metadata.name] | .[]' "$rendered"/*.yaml | paste -sd' ')
  [ -z "$bad" ] || fail "$cluster: a HelmRelease takes its chart from a HelmChart by chartRef, never from a template" \
    "of its own: $bad"
  platformfiles=()
  otherfiles=("$rendered/cluster.yaml")
  while read -r name path; do
    case $path in
      ./kubernetes/platform/*) platformfiles+=("$rendered/$name.yaml") ;;
      *) otherfiles+=("$rendered/$name.yaml") ;;
    esac
  done <"$w/paths"
  bad=$(yq ea '[select(.kind == "HelmChart") | .metadata.namespace + "/" + .metadata.name] | .[]' "${otherfiles[@]}" \
    | paste -sd' ')
  [ -z "$bad" ] || fail "$cluster: HelmCharts come from the platform alone: $bad"
  bad=$(yq ea "[select($fluxks and (.spec.path // \"\" | test(\"/vendor(/|\$)\"))) | .metadata.name] | .[]" \
    "${otherfiles[@]}" | paste -sd' ')
  [ -z "$bad" ] || fail "$cluster: a tree a piece vendors is applied from that piece's own render alone: $bad"
  # The charts the platform builds in flux-system, which apps may name: each HelmChart's name and the chart its tree
  # holds.
  : >"$w/charts"
  [ ${#platformfiles[@]} = 0 ] || yq ea '[select(.kind == "HelmChart" and .metadata.namespace == "flux-system")
    | .metadata.name + " " + (.spec.chart // "")] | .[]' "${platformfiles[@]}" | while read -r chart tree; do
    echo "$chart $(yq '.name // "-"' "$tree/Chart.yaml" 2>/dev/null || echo -)"
  done >"$w/charts"

  while read -r name path; do
    file=$rendered/$name.yaml
    t=$(yq ".metadata.labels.\"suveraen/tenant\" // \"\"" "$w/$name.ks.yaml")
    export name t
    [ "$testing" = false ] || [ -z "$t" ] || echo "$cluster $name" >>"$work/tested"
    case $path in
      ./kubernetes/platform/*)
        [ -z "$t" ] || fail "$cluster/$name: tenants run apps, not the platform"
        piece=${path#./kubernetes/platform/}
        piece=${piece%%/*}
        export piece
        # A piece's charts are the trees it vendors, as they are, at the version their records give.
        bad=$(yq ea '[select(.kind == "HelmChart") | select(.metadata.namespace != "flux-system"
          or ([.spec | keys | .[] | select(test("^(chart|interval|reconcileStrategy|sourceRef)$") | not)] | length) > 0
          or (.spec.sourceRef | keys | sort | join(",")) != "kind,name"
          or .spec.sourceRef.kind != "GitRepository" or .spec.sourceRef.name != "suveraen"
          or (.spec.reconcileStrategy // "ChartVersion") != "ChartVersion"
          or ((.spec.chart // "") | test("^[.]/kubernetes/platform/" + strenv(piece) + "/vendor/[^/]+$") | not))
          | .metadata.name] | .[]' "$file")
        bad+=$(yq ea '[select(.kind == "HelmChart") | .metadata.name + " " + (.spec.chart // "")] | .[]' "$file" \
          | while read -r chart tree; do
            [ -f "$tree.json" ] && [ -f "$tree/Chart.yaml" ] || echo " $chart"
          done)
        [ -z "$bad" ] || fail "$cluster/$name: a piece's charts are HelmCharts in flux-system, built from" \
          "GitRepository suveraen by their own version and values, each from a tree the piece vendors with its" \
          "record, ./kubernetes/platform/$piece/vendor/<name>: "$bad
        # Upstream's manifests are applied as they are vendored: Flux substitutes, patches or moves nothing in them.
        bad=$(yq ea "[select($fluxks and (.spec.path // \"\" | test(\"/vendor(/|\$)\"))) | select((.spec.path
          | test(\"^[.]/kubernetes/platform/\" + strenv(piece) + \"/vendor/[^/]+$\") | not)
          or (.spec | has(\"postBuild\") or has(\"patches\") or has(\"images\") or has(\"components\")
            or has(\"targetNamespace\") or has(\"namePrefix\") or has(\"nameSuffix\") or has(\"commonMetadata\")))
          | .metadata.name] | .[]" "$file")
        bad+=$(yq ea "[select($fluxks and (.spec.path // \"\" | test(\"/vendor(/|\$)\")))
          | .metadata.name + \" \" + .spec.path] | .[]" "$file" | while read -r ks tree; do
          [ -f "$tree.json" ] || echo " $ks"
        done)
        [ -z "$bad" ] || fail "$cluster/$name: a Kustomization applies a tree its piece vendors with its record," \
          "./kubernetes/platform/$piece/vendor/<name>, as it is, with no postBuild, patches, images, components," \
          "targetNamespace, namePrefix, nameSuffix or commonMetadata: "$bad
        # Operator charts install cluster-wide objects: they run as helm-controller, from flux-system, with a chart
        # their own piece builds.
        bad=$(yq ea '[select(.kind == "HelmRelease") | select(.metadata.namespace != "flux-system"
          or .spec.serviceAccountName != "helm-controller") | .metadata.name] | .[]' "$file")
        [ -z "$bad" ] || fail "$cluster/$name: platform HelmReleases must run as helm-controller from flux-system: $bad"
        own=$(yq ea '[select(.kind == "HelmChart" and .metadata.namespace == "flux-system") | .metadata.name] | .[]' \
          "$file")
        bad=$(yq ea '[select(.kind == "HelmRelease") | .metadata.name + " " + (.spec.chartRef.kind // "-") + " "
          + (.spec.chartRef.namespace // "flux-system") + " " + (.spec.chartRef.name // "-")] | .[]' "$file" \
          | while read -r release kind ns chart; do
            [ "$kind $ns" = "HelmChart flux-system" ] && grep -qxF "$chart" <<<"$own" || echo "$release"
          done)
        [ -z "$bad" ] || fail "$cluster/$name: a platform HelmRelease takes its chart from a HelmChart its own piece" \
          "builds: $bad"
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
        # Its proxy to the hosts its template lists.
        egress=false
        for component in $(yq '.spec.components[]?' "$w/$name.ks.yaml"); do
          [ "$(realpath -m --relative-to=. "$path/$component")" != kubernetes/components/egress ] || egress=true
        done
        [ "$egress" = false ] || kinds+=,Deployment.apps
        export kinds
        bad=$(yq ea '[select(.kind == "HelmRelease") | select(.metadata.namespace == "flux-system"
          or .spec.serviceAccountName != "flux-deployer" or .spec.install.crds != "Skip" or .spec.upgrade.crds != "Skip"
          or (.spec | has("targetNamespace") or has("storageNamespace"))) | .metadata.name] | .[]' "$file")
        [ -z "$bad" ] || fail "$cluster/$name: app HelmReleases must run as flux-deployer in the app's namespace: $bad"
        built=$(cut -d' ' -f1 "$w/charts")
        bad=$(yq ea '[select(.kind == "HelmRelease") | .metadata.name + " "
          + (.spec.chartRef // {} | keys | sort | join(",") | sub("^$", "-")) + " " + (.spec.chartRef.kind // "-") + " "
          + (.spec.chartRef.namespace // "-") + " " + (.spec.chartRef.name // "-")] | .[]' "$file" \
          | while read -r release fields kind ns chart; do
            [ "$fields $kind $ns" = "kind,name,namespace HelmChart flux-system" ] && grep -qxF "$chart" <<<"$built" \
              || echo "$release"
          done)
        [ -z "$bad" ] || fail "$cluster/$name: an app's HelmReleases take their chart from a HelmChart the platform" \
          "builds in flux-system: $bad"
        # quota-fit reads app-template's values alone.
        bad=$(yq ea '[select(.kind == "HelmRelease") | .metadata.name + " " + .spec.chartRef.name] | .[]' "$file" \
          | while read -r release chart; do grep -qxF "$chart app-template" "$w/charts" || echo "$release"; done)
        [ -z "$bad" ] || fail "$cluster/$name: an app's charts are app-template's, the only one quota-fit can judge:" \
          $bad
        bad=$(yq ea '[select(.kind != null)
          | ((.kind + "." + (.apiVersion | sub("/?[^/]*$", ""))) | sub("[.]$", "")) as $k
          | select(((strenv(kinds) | split(",")) | any_c(. == $k) | not)
            or ($k != "Namespace" and .metadata.namespace != strenv(name)))
          | $k + "/" + .metadata.name] | .[]' "$file")
        [ -z "$bad" ] || fail "$cluster/$name: an app creates only ${kinds//,/, }; in its own namespace: $bad"
        if [ "$egress" = true ]; then
          # Built again from the component alone, with the same values, the proxy runs the same: nothing of the app's
          # own changes it, nor adds a Deployment beside it.
          ref=$cluster/$name.egress
          mkdir -p "$ref"
          printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\n' >"$ref/kustomization.yaml"
          export ref
          yq '.spec.path = "./" + strenv(ref) | .spec.components = ["../../kubernetes/components/egress"]' \
            "$w/$name.build.yaml" >"$ref.yaml"
          flux build kustomization "$name" --path "./$ref" --kustomization-file "$ref.yaml" --dry-run \
            --strict-substitute >"$ref.out" || fail "$cluster/$name: components/egress doesn't build alone"
          deployments='[select(.kind == "Deployment") | {"name": .metadata.name, "spec": .spec} | sort_keys(..)]'
          [ "$(yq ea -o=json -I=0 "$deployments" "$file")" = "$(yq ea -o=json -I=0 "$deployments" "$ref.out")" ] \
            || fail "$cluster/$name: an app's one Deployment is egress, as components/egress makes it from the app's" \
              "EGRESS_HOSTS"
          hosts=$(yq '.spec.postBuild.substitute.EGRESS_HOSTS // ""' "$w/$name.ks.yaml")
          domains=$(yq '.TENANT_DOMAIN // "", .TENANT_APP_DOMAIN // ""' "$w/$name.vars.yaml"
            yq ea '[select(.kind == "ConfigMap" and .metadata.namespace == "flux-system"
              and .metadata.name == "hostnames")] | .[0].data // {} | keys | .[]' "$rendered/cluster.yaml")
          bad=$(python3 -I -c "$egresshosts" "$hosts" $domains)
          [ -z "$bad" ] || fail "$cluster/$name: an app's proxy tunnels to the 1 to 8 hosts its template lists in" \
            "EGRESS_HOSTS, a JSON list of distinct <name>:443, none an address, a wildcard, a name of the cluster's own" \
            "or one on a domain of the tenant's or the hostname map's: $bad"
        fi
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
          restic=$(pinned volsync restic.tag)
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
        bad=$(yq ea -o=json -I=0 '[.]' "$file" | python3 -I -c "$quotafit")
        [ -z "$bad" ] || fail "$cluster/$name: the quota holds every pod the app's charts and Deployments run at once," \
          "at their requests and limits or the LimitRange's defaults, with the one more a rolling update starts, and" \
          "one more pod at the defaults: $bad"
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
        # by components/sso-client alone, from those of its pods it chooses.
        if grep -qxF "$t-$app-sso" <<<"$known"; then
          want='{"egress":[{"ports":[{"port":8443}],"to":[{"namespaceSelector":{"matchLabels":'
          want+='{"kubernetes.io/metadata.name":"'$t'-kanidm"}},"podSelector":{"matchLabels":'
          want+='{"app.kubernetes.io/controller":"kanidm"}}}]}],"policyTypes":["Egress"]}'
          [ "$(yq ea -o=json -I=0 '[select(.kind == "NetworkPolicy" and .metadata.name == "to-kanidm")
            | .spec | del(.podSelector) | sort_keys(..)] | .[]' "$file")" = "$want" ] \
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
          passhost=$(passed "$t" "$app")
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
              "Secret tls labelled with tenant $t (components/passthrough, components/passthrough-app)"
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
            "origin, takes its settings from the server.toml it mounts alone and its migrations from where they are" \
            "mounted, trusts no address a client names, speaks no LDAP, replicates nothing, sends nothing out, and" \
            "logs nothing below info: $bad"
          python3 -I -c "$migrationsource" "$cluster" "$t" kanidm-migrations kanidm \
            <(yq ea -o=json -I=0 '[select(.kind == "ConfigMap" and .metadata.name == "kanidm-migrations")] | .[0]' \
              "$file") <(echo '[]') <(echo '[]') >>"$work/migrations.jsonl"
        fi
        if [ "$app" = netbird ]; then
          # One host: Kanidm's own rules hold it to one, and the mesh's sign-in waits for Kanidm.
          idm=$(passed "$t" kanidm)
          stun=$(yq '.STUN_PORT // ""' "$w/$name.vars.yaml")
          postgres=$(yq ea "[select(.kind == \"Cluster\" and .apiVersion == \"postgresql.cnpg.io/v1\"
            and .metadata.namespace == \"$t-postgres\") | .spec.imageCatalogRef.major] as \$major
            | [select(.kind == \"ClusterImageCatalog\" and .metadata.name == \"postgresql\") | .spec.images[]
            | select(.major == \$major[0]) | .image] | .[0] // \"\"" "$rendered"/*.yaml)
          bad=$(yq ea -o=json -I=0 '[.]' "$file" |
            python3 -I -c "$netbirdconfig" "$passhost" "$idm" "$stun" "$postgres" "$t")
          [ -z "$bad" ] || fail "$cluster/$name: a tenant's mesh runs the images checks/netbird.nix pins, in two" \
            "controllers whose pods go before new ones start, as users of their own, logging little, calling nowhere" \
            "and reaching the tenant's PostgreSQL and Kanidm from management alone," \
            "with no NetBird settings in its environment but its own; management keeps no default policy, IdP or" \
            "devices' setup of its own, signs in only with its own Kanidm, by scope openid and on the devices' own" \
            "ports, asking afresh each time, takes every secret from Secret netbird and names its own host alone;" \
            "nginx stays in the foreground, routes five paths alone, refuses three, renders the dashboard's pages," \
            "clears what clients say of their addresses and logs no access; the scrub runs its tenant's PostgreSQL" \
            "image, signs in as management does with no secret in its command line, and blanks what the servers'" \
            "check knows a device reports beyond the mesh's needs: $bad"
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
          "pg_ident " + (.spec.postgresql.pg_ident // [] | join(";")),
          "archive " + ([.spec.plugins[] | .name + ":" + (.isWALArchiver // false | tostring) + ":"
            + (.parameters | to_entries | map(.key + "=" + .value) | join("+"))] | join(";")),
          "bootstrap " + ((.spec.bootstrap // {}) | keys | join(",")) + ":" + (.spec.bootstrap.recovery.source // "")
            + ":" + ([.spec.externalClusters[]? | select(.name == "origin") | .plugin.parameters.serverName]
            | join(","))] | .[]' "$file" | sed 's/^bootstrap initdb::$/bootstrap initdb/' >"$w/$name.pg"
        printf '%s\n' "prune disabled" "superuser false" "image false/ClusterImageCatalog/postgresql" \
          "storage ceph-block/false/postgres" "pg_hba hostssl sameuser all all scram-sha-256;host all all all reject" \
          "pg_ident local postgres all" \
          "archive barman-cloud.cloudnative-pg.io:true:barmanObjectName=postgres+serverName=postgres-$generation" \
          "bootstrap $from" >"$w/$name.pg.want"
        bad=$(diff "$w/$name.pg.want" "$w/$name.pg" | sed -n 's/^> //p' | paste -sd';' || true)
        [ -z "$bad" ] || fail "$cluster/$name: a tenant's PostgreSQL is never pruned, has no superuser access, takes" \
          "its image from the catalog and its volume from ceph-block, labelled as Barman's to back up, lets each role" \
          "reach its own database alone over TLS, and what runs in an instance as its own user sign in as any role, and" \
          "archives with Barman to postgres-$generation: $bad"
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
      ./kubernetes/edge/app | ./kubernetes/edge/identity | ./kubernetes/edge/apex | ./kubernetes/edge/passthrough \
        | ./kubernetes/edge/passthrough-app)
        [[ $name =~ ^$t-([a-z0-9]+)-edge-([a-z0-9]+)$ ]] && [ -n "$t" ] \
          || fail "$cluster/$name: a host is <tenant>-<app>-edge-<key>, one of its tenant's"
        app=${BASH_REMATCH[1]}
        key=${BASH_REMATCH[2]}
        base=$t-$app-$key
        export app base
        grep -qxF "$t-$app" <<<"$known" || fail "$cluster/$name: a host belongs to an app its tenant runs, $t-$app"
        case ${path##*/} in
          app | passthrough-app) host='.HOST + "." + .TENANT_APP_DOMAIN' ;;
          identity | passthrough) host='.HOST + "." + .TENANT_DOMAIN' ;;
          apex) host='.TENANT_DOMAIN' ;;
        esac
        host=$(yq ".spec.postBuild.substitute | $host" "$w/$name.build.yaml")
        export host
        if [[ ${path##*/} == passthrough* ]]; then
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
    # The way to the internet is components/internet's policy, in every Kustomization that takes it, for what the
    # cluster's own ranges leave out.
    internet=$(yq ea -o=json -I=0 '[select(.kind == "NetworkPolicy" and .metadata.name == "internet")
      | .spec | sort_keys(..)] | .[]' "$file")
    if [ -n "$internet" ]; then
      want='{"egress":[{"ports":[{"port":80,"protocol":"TCP"},{"port":443,"protocol":"TCP"}],"to":[{"ipBlock":'
      want+='{"cidr":"0.0.0.0/0","except":["'$(v POD_CIDR_V4)'","'$(v SERVICE_CIDR_V4)'","'$(v NODE_CIDR_V4)'",'
      want+='"169.254.0.0/16"]}},{"ipBlock":{"cidr":"::/0","except":["'$(v POD_CIDR_V6)'","'$(v SERVICE_CIDR_V6)'","'
      want+=$(v NODE_CIDR_V6)'","fe80::/10"]}}]}],"podSelector":{"matchLabels":{"suveraen/egress":"internet"}},'
      want+='"policyTypes":["Egress"]}'
      bad=$(grep -vxF "$want" <<<"$internet" || true)
      [ -z "$bad" ] || fail "$cluster/$name: the network policy internet opens web ports to all but the cluster's own" \
        "pods, Services and nodes, for pods labelled suveraen/egress=internet: $bad"
    fi
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
    # What render holds a chart to, it reads in the values here: none may come from elsewhere, nor what the chart
    # renders be patched, but for the platform's VolSync, whose controller gets the platform's priority so, and Rook's,
    # without which the cluster would refuse what it renders.
    bad=$(yq ea '[select(.kind == "HelmRelease") | (.metadata.namespace + "/" + .metadata.name) as $release
      | select((.spec | has("valuesFrom"))
        or ($release == "flux-system/rook-ceph" and (.spec.postRenderers
          | (.[].kustomize.patches[]? | select(has("patch")) | .patch) |= from_yaml | sort_keys(..) | @json)
          != strenv(rookpatch))
        or ((.spec | has("postRenderers")) and $release != "flux-system/volsync" and $release != "flux-system/rook-ceph"))
      | .metadata.name] | .[]' "$file")
    [ -z "$bad" ] || fail "$cluster/$name: a HelmRelease takes its values from itself alone, and only VolSync's and" \
      "Rook's change what their charts render, Rook's always, to leave the CSI operator's network policy its ingress" \
      "alone: $bad"
    # Images in what is rendered here, containers' and volumes', the PostgreSQL images clusters take from catalogs,
    # Ceph's, and the tags and images charts are given.
    bad=$({
      yq ea '[select(.kind == "ClusterImageCatalog" or .kind == "ImageCatalog") | .spec.images[].image] | .[]' "$file"
      yq ea '[.spec.template.spec // .spec.jobTemplate.spec.template.spec // {}
        | ((((.containers // []) + (.initContainers // []))[] | .image),
          ((.volumes // [])[] | select(has("image")) | .image.reference // "-"))] | .[]' "$file"
      yq ea '[select(.kind == "CephCluster") | .spec.cephVersion.image] | .[]' "$file"
      yq ea '[select(.kind == "HelmRelease") | .spec.values // {} | .. | select(tag == "!!map" and has("tag")) | .tag
        | tostring] | .[]' "$file"
      yq ea '[select(.kind == "HelmRelease") | .spec.values // {} | .. | select(tag == "!!map" and has("image"))
        | .image | select(tag == "!!str")] | .[]' "$file"
    } | grep -vE '@sha256:[0-9a-f]{64}$' | sort -u | paste -sd' ' || true)
    [ -z "$bad" ] || fail "$cluster/$name: images are pinned by digest: $bad"
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
  # client and sends no telemetry out.
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
    "its logs, metrics, traces, entry points, providers or plugins: $bad"
  # Spans carry clients' addresses and paths, labels the headers of requests or the routes of tenants, and OTLP and
  # the push exporters send what they measure out.
  bad=$(yq ea "$traefik | [(keys | .[] | select(. == \"tracing\")),
    (.metrics // {} | keys | .[] | select(. == \"otlp\" or . == \"datadog\" or . == \"influxdb2\" or . == \"statsd\")
      | \"metrics.\" + .),
    (.metrics.prometheus // {} | to_entries | .[]
      | select(.key == \"headerLabels\" or (.key == \"addRoutersLabels\" and (.value | tostring) == \"true\"))
      | \"metrics.prometheus.\" + .key),
    (.log // {} | keys | .[] | select(. == \"otlp\") | \"log.\" + .),
    (.experimental // {} | keys | .[] | select(. == \"otlpLogs\") | \"experimental.\" + .)] | .[]" "$rendered"/*.yaml \
    | paste -sd' ')
  [ -z "$bad" ] || fail "$cluster: the gateway traces nothing, sends no metrics or logs out, and labels its metrics with" \
    "no header or router: $bad"
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
  bad=$(yq ea "[select(.kind != null) | select(.metadata.namespace != \"flux-system\" or (($fluxks
    or .apiVersion == \"v1\" and (.kind == \"ConfigMap\" or .kind == \"Secret\")) | not)) | .kind + \"/\"
    + (.metadata.namespace // \"\") + \"/\" + .metadata.name] | .[]" "$rendered/cluster.yaml" \
    | grep -vxF ConfigMap/kube-system/coredns-custom || true)
  [ -z "$bad" ] || fail "$cluster: a cluster directory adds Kustomizations, ConfigMaps and Secrets to flux-system" \
    "alone, and the cluster DNS's names for its tenants' Kanidm (coredns-custom in kube-system): $bad"
  # pinned-images and Pod Security leave kube-system to k3s's own pods.
  bad=$(yq ea '[select(.kind != null) | select(.metadata.namespace == "kube-system" or .kind == "HelmRelease"
    and ((.spec.targetNamespace // "") == "kube-system" or (.spec.storageNamespace // "") == "kube-system"))
    | .kind + "/" + (.metadata.namespace // "") + "/" + .metadata.name] | .[]' "$rendered"/*.yaml \
    | grep -vxF ConfigMap/kube-system/coredns-custom | paste -sd' ' || true)
  [ -z "$bad" ] || fail "$cluster: kube-system is k3s's own, where the release puts nothing but the cluster DNS's" \
    "names, and installs no chart: $bad"
  # The servers give flux-system its network policies, which one of the release's would add to, as would one in a
  # chart, which render can't see. A chart installed elsewhere may still name flux-system for what it renders.
  bad=$(yq ea '[select((.kind == "NetworkPolicy" and .metadata.namespace == "flux-system") or (.kind == "HelmRelease"
    and (.spec.targetNamespace // .metadata.namespace) == "flux-system"))
    | .kind + "/" + .metadata.namespace + "/" + .metadata.name] | .[]' "$rendered"/*.yaml | paste -sd' ')
  [ -z "$bad" ] || fail "$cluster: flux-system's network policies are the servers' alone, so the release makes none" \
    "there and installs no chart there: $bad"
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
  # RGW serves every API it has unless told which. Rook passes the gateway's own flags after its own, so one there
  # would name them again, however Ceph's option is spelt.
  bad=$(yq ea '[select(.kind == "CephObjectStore")
    | select(((.spec.protocols.enableAPIs // []) | sort | join(",")) != "admin,s3"
      or ((.spec.gateway.rgwCommandFlags // {}) | keys | any_c(downcase | sub("[ -]", "_") == "rgw_enable_apis")))
    | .metadata.name] | .[]' "$rendered"/*.yaml)
  [ -z "$bad" ] || fail "$cluster: the object store serves S3 and Rook's admin API alone: $bad"
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
  cephcsi=$(pinned rook-ceph csi.cephcsi.tag)
  barrier=$(yq ea '[select(.kind == "DaemonSet" and .metadata.namespace == "rook-ceph"
    and .metadata.name == "unmap-barrier") | .spec.template.spec.containers[].image] | join(" ")' "$rendered"/*.yaml)
  [ "$barrier" = "$cephcsi" ] || fail "$cluster: the DaemonSet unmap-barrier in rook-ceph, which holds a shutdown" \
    "until no volume is mapped, runs the CSI node plugin's image, already on every node that maps volumes," \
    "$cephcsi: $barrier"
  # An image a chart's record pins moves with the chart: a release that set anything under it would hold it as it was,
  # and one that set anything but a map above it would take the pin away.
  releases=$(yq ea -o=json -I=0 '[select(.kind == "HelmRelease" and .spec.chartRef.kind == "HelmChart"
    and (.spec.chartRef.namespace // .metadata.namespace) == "flux-system") | {"chart": .spec.chartRef.name,
    "name": .metadata.namespace + "/" + .metadata.name, "values": (.spec.values // {})}]' "$rendered"/*.yaml)
  bad=$(yq ea '[select(.kind == "HelmChart" and .metadata.namespace == "flux-system") | .metadata.name + " "
    + (.spec.chart // "")] | .[]' "$rendered"/*.yaml | while read -r chart tree; do
      jq -e .images "$tree.json" >/dev/null 2>&1 || continue
      jq -r --arg chart "$chart" --slurpfile record "$tree.json" '[$record[0].images[].values[] | split(".") | .[:-1]]
        as $pinned | .[] | select(.chart == $chart) | .name as $release | .values as $values | [$values | paths] as $set
        | $pinned[] as $at | select(any($set[]; . as $p | $p[:($at | length)] == $at or (($p | length) < ($at | length)
          and $at[:($p | length)] == $p and ($values | getpath($p) | type) != "object")))
        | "\($release) (\($at | join(".")))"' <<<"$releases"
    done | sort -u | paste -sd' ')
  [ -z "$bad" ] || fail "$cluster: a HelmRelease sets nothing under an image its chart's record pins, nor anything" \
    "but a map above one: $bad"
  # helm-controller tries a failed install again as an upgrade, after which a rollback finds nothing to go back to and
  # an uninstall leaves a release it won't install again: either stops until a person acts. Never rolled back, an app
  # also never runs an old release on a database the new one has migrated.
  bad=$(yq ea '[select(.kind == "HelmRelease" and (.spec.install.strategy.name != "RetryOnFailure"
    or .spec.upgrade.strategy.name != "RetryOnFailure" or .spec.install.remediation != null
    or .spec.upgrade.remediation != null)) | .metadata.namespace + "/" + .metadata.name] | .[]' "$rendered"/*.yaml \
    | paste -sd' ')
  [ -z "$bad" ] || fail "$cluster: a HelmRelease tries a failed install or upgrade again until it succeeds, never" \
    "rolling it back or uninstalling it (components/retry): $bad"
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
    bundle=$(yq ea '[select(.kind == "ConfigMap" and .metadata.name == "cluster-settings")] | .[0].data.PUBLIC_CA_BUNDLE
      // ""' "$rendered/cluster.yaml")
    [ "$bundle" = Cg== ] || fail "$cluster: the public issuer's certificates chain to roots the images hold, so" \
      "PUBLIC_CA_BUNDLE is one empty line, Cg=="
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

# Every tree the release vendors is built as a chart or applied in some cluster, and every chart built is installed.
used=$(yq ea "[(select(.kind == \"HelmChart\") | .spec.chart), (select($fluxks) | .spec.path)] | .[]" "$out"/*/*.yaml)
bad=$(for record in kubernetes/platform/*/vendor/*.json; do
  [ ! -e "$record" ] || grep -qxF "./${record%.json}" <<<"$used" || echo "./${record%.json}"
done | paste -sd' ')
[ -z "$bad" ] || fail "every tree the release vendors is a HelmChart's chart or a Kustomization's path in some cluster:" \
  "$bad"
bad=$(comm -23 <(yq ea '[select(.kind == "HelmChart") | .metadata.namespace + "/" + .metadata.name] | .[]' \
  "$out"/*/*.yaml | sort -u) <(yq ea '[select(.kind == "HelmRelease" and .spec.chartRef.kind == "HelmChart")
  | (.spec.chartRef.namespace // .metadata.namespace) + "/" + .spec.chartRef.name] | .[]' "$out"/*/*.yaml | sort -u) \
  | paste -sd' ')
[ -z "$bad" ] || fail "every HelmChart is the chart of a HelmRelease in some cluster: $bad"

bad=$(python3 -I -c "$migrations" "$founding" <"$work/migrations.jsonl")
[ -z "$bad" ] || fail "Kanidm's migrations: $bad"
# Once the migrations are known to say which IDs they take.
for dir in kubernetes/clusters/*/; do
  cluster=$(basename "$dir")
  bad=$(for file in "$out/$cluster"/*.yaml; do
    yq ea -o=json -I=0 "[.] as \$docs | {\"name\": \"$(basename "$file" .yaml)\", \"docs\": \$docs}" "$file"
  done | python3 -I -c "$secretsonly" "$work/$cluster/secret-values" "$work/$cluster")
  [ -z "$bad" ] || fail "$cluster: what a Secret gives lands only in Secrets, the standby CA's external account ID" \
    "and Kanidm's IDs: $bad"
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
