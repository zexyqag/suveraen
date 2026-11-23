# What the servers' tools that read a tenant's app share, each by the app's name, which names its namespace,
# <tenant>-<app>, its database and its role: the tenants that run it, and SQL in its database. Each tool's module puts
# it before the tool's own script.

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
tenant_id='^[a-z][a-z0-9]{4}$'

# tenants APP: every tenant that runs APP, from its namespace.
tenants() {
  kubectl --request-timeout=30s get namespaces -l "suveraen/app=$1" -o json |
    jq -r --arg app "$1" --arg id "$tenant_id" '.items[] | (.metadata.labels["suveraen/tenant"] // "") as $t
      | select(($t | test($id)) and .metadata.name == "\($t)-\($app)") | $t'
}

# The one primary of a tenant's PostgreSQL.
primary() {
  local name
  name=$(kubectl --request-timeout=30s -n "$1-postgres" get pods \
    -l cnpg.io/cluster=postgres,cnpg.io/instanceRole=primary -o jsonpath='{.items[*].metadata.name}') || return 1
  if ! [[ $name =~ ^[a-z0-9-]+$ ]]; then
    echo "${0##*/}: $1-postgres has no one primary: ${name:-none}" >&2
    return 1
  fi
  echo "$name"
}

# app_sql TENANT APP [--write] [PSQL-ARGUMENTS...]: SQL from stdin in APP's database in the tenant's PostgreSQL, by exec
# into its primary, signed in as APP's own role, since the superuser would run whatever that role planted there with
# every right (apps/postgres); in a session that starts read-only but with --write. A SET in one -c string comes too
# late: psql sends the string as one message, which PostgreSQL runs as one transaction begun before the SET applies.
app_sql() {
  local t=$1 app=$2 name options='-c default_transaction_read_only=on'
  shift 2
  if [ "${1:-}" = --write ]; then
    options=
    shift
  fi
  name=$(primary "$t") || return 1
  kubectl --request-timeout=60s -n "$t-postgres" exec -i "$name" -c postgres -- \
    env PGOPTIONS="$options" psql -X -q -At -v ON_ERROR_STOP=1 "$@" -U "$app" -d "$app" -f -
}
