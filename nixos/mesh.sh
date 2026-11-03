# Each tenant's mesh (kubernetes/apps/netbird), from a server: by exec into the tenant's PostgreSQL primary, where
# management keeps the mesh, signed in as the mesh's own role, since the superuser would run whatever that role
# planted there with every right (apps/postgres); and through the API server. It holds no credential. mesh.nix sets
# query, what the check reads of a mesh (mesh.sql), and idm, suveraen-idm (idm.nix), which asks each tenant's Kanidm
# after its people.

usage() {
  cat >&2 <<'EOF'
usage: suveraen-mesh check
       suveraen-mesh sql TENANT
       suveraen-mesh after-restore TENANT
EOF
  exit 2
}

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Every tenant that runs a mesh, from its namespace.
tenants() {
  kubectl --request-timeout=30s get namespaces -l suveraen/app=netbird -o json | jq -r '.items[]
    | (.metadata.labels["suveraen/tenant"] // "") as $t
    | select(($t | test("^[a-z][a-z0-9]{4}$")) and .metadata.name == "\($t)-netbird") | $t'
}

# The one primary of a tenant's PostgreSQL, which holds its mesh's database.
primary() {
  local name
  name=$(kubectl --request-timeout=30s -n "$1-postgres" get pods \
    -l cnpg.io/cluster=postgres,cnpg.io/instanceRole=primary -o jsonpath='{.items[*].metadata.name}') || return 1
  if ! [[ $name =~ ^[a-z0-9-]+$ ]]; then
    echo "suveraen-mesh: $1-postgres has no one primary: ${name:-none}" >&2
    return 1
  fi
  echo "$name"
}

# SQL from stdin in a tenant's mesh database, in a session that starts read-only. A SET in one -c string comes too late:
# psql sends the string as one message, which PostgreSQL runs as one transaction begun before the SET applies.
sql() {
  local name
  name=$(primary "$1") || return 1
  kubectl --request-timeout=60s -n "$1-postgres" exec -i "$name" -c postgres -- \
    env PGOPTIONS='-c default_transaction_read_only=on' psql -X -q -At -v ON_ERROR_STOP=1 -U netbird -d netbird -f -
}

# What the servers' checks judge (host-checks.nix), with no credential: the cluster's STUN port where a tenant runs a
# mesh, and for each such tenant what mesh.sql reads, and how Kanidm answers for each of its people who isn't blocked,
# whose NetBird ID is their Kanidm ID. A tenant whose mesh can't be read is unchecked.
check() {
  local list t mesh why people port
  list=$(tenants) || exit 1
  port=null
  if [ -n "$list" ]; then
    port=$(kubectl --request-timeout=30s -n flux-system get configmap cluster-settings -o json |
      jq -c '.data.STUN_PORT // null') || exit 1
  fi
  for t in $list; do
    if ! mesh=$(sql "$t" <"$query" 2>&1) || ! jq -e 'type == "object"' <<<"$mesh" >/dev/null 2>&1; then
      # psql says what went wrong first, and then where.
      why=$(grep -m 1 . <<<"$mesh" || true)
      jq -nc --arg tenant "$t" --arg why "${why:-the query printed nothing}" '{$tenant, unchecked: $why}'
      continue
    fi
    # shellcheck disable=SC2046 # one UUID each
    people=$("$idm" accounts "$t" $(jq -r '.users[] | select(.blocked or .service | not) | .id
      | select(test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))' <<<"$mesh") 2>/dev/null) ||
      people=null
    jq -c --arg tenant "$t" --slurpfile people <(printf '%s' "$people") '{$tenant, mesh: ., people: $people[0]}' \
      <<<"$mesh"
  done | jq -sc --argjson port "$port" '{stunPort: $port, tenants: .}'
}

# A device takes no network map older than the one it holds, which a restore takes the database back behind: it would
# keep its map and pass over every change until the serial caught up with its own. Each change raises the serial by
# one, so a million more is past any a restore loses. Each account's serial as the update found and left it, then
# management starts again on the restored state.
after_restore() {
  local t=$1 labels name
  labels=$(kubectl --request-timeout=30s get namespace "$t-netbird" -o json |
    jq -r '.metadata.labels | "\(.["suveraen/tenant"] // "") \(.["suveraen/app"] // "")"')
  if [ "$labels" != "$t netbird" ]; then
    echo "suveraen-mesh: $t runs no mesh in $t-netbird." >&2
    exit 1
  fi
  name=$(primary "$t") || exit 1
  kubectl --request-timeout=60s -n "$t-postgres" exec "$name" -c postgres -- \
    psql -X -q -At -F ' ' -v ON_ERROR_STOP=1 -U netbird -d netbird -c 'UPDATE accounts
      SET network_serial = network_serial + 1000000 RETURNING id, old.network_serial, new.network_serial' </dev/null |
    while read -r account was now; do
      echo "$t: raised the network serial of account $account from $was to $now"
    done
  kubectl --request-timeout=30s -n "$t-netbird" rollout restart deployment netbird-management >/dev/null
  kubectl -n "$t-netbird" rollout status deployment netbird-management --timeout=15m >/dev/null
  echo "$t: management started again"
}

[ $# != 0 ] || usage
command=$1
shift
case $command in
  check)
    [ $# = 0 ] || usage
    check
    ;;
  sql)
    [ $# = 1 ] && [[ $1 =~ ^[a-z][a-z0-9]{4}$ ]] || usage
    sql "$1"
    ;;
  after-restore)
    [ $# = 1 ] && [[ $1 =~ ^[a-z][a-z0-9]{4}$ ]] || usage
    after_restore "$1"
    ;;
  *)
    usage
    ;;
esac
