# Each tenant's mesh (kubernetes/apps/netbird), from a server: in the tenant's PostgreSQL, where management keeps the
# mesh, as the mesh's own role (tenant-apps.sh); and through the API server. It holds no credential. mesh.nix sets
# query, what the check reads of a mesh (mesh.sql); idm, suveraen-idm (idm.nix), which asks each tenant's Kanidm after
# its people; and scrubbed and kept, the columns of peers the scrub blanks and keeps, as JSON.

usage() {
  cat >&2 <<'EOF'
usage: suveraen-mesh check
       suveraen-mesh sql TENANT
       suveraen-mesh after-restore TENANT
EOF
  exit 2
}

# SQL from stdin in a tenant's mesh database, in a session that starts read-only, with the columns of peers as
# variables.
sql() {
  app_sql "$1" netbird -v "scrubbed=$scrubbed" -v "kept=$kept"
}

# What the servers' checks judge (host-checks.nix), with no credential: the cluster's STUN port where a tenant runs a
# mesh, and for each such tenant what mesh.sql reads, and how Kanidm answers for each of its people who isn't blocked,
# whose NetBird ID is their Kanidm ID. A tenant whose mesh can't be read is unchecked.
check() {
  local list t mesh why people port
  list=$(tenants netbird) || exit 1
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
  local t=$1 labels
  labels=$(kubectl --request-timeout=30s get namespace "$t-netbird" -o json |
    jq -r '.metadata.labels | "\(.["suveraen/tenant"] // "") \(.["suveraen/app"] // "")"')
  if [ "$labels" != "$t netbird" ]; then
    echo "suveraen-mesh: $t runs no mesh in $t-netbird." >&2
    exit 1
  fi
  app_sql "$t" netbird --write -F ' ' <<<'UPDATE accounts
      SET network_serial = network_serial + 1000000 RETURNING id, old.network_serial, new.network_serial;' |
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
    [ $# = 1 ] && [[ $1 =~ $tenant_id ]] || usage
    sql "$1"
    ;;
  after-restore)
    [ $# = 1 ] && [[ $1 =~ $tenant_id ]] || usage
    after_restore "$1"
    ;;
  *)
    usage
    ;;
esac
