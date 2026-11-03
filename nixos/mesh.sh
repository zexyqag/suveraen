# Each tenant's mesh (kubernetes/apps/netbird), from a server: by exec into the tenant's PostgreSQL primary, where
# management keeps the mesh, signed in as the mesh's own role, since the superuser would run whatever that role
# planted there with every right (apps/postgres); and through the API server. It holds no credential.

usage() {
  cat >&2 <<'EOF'
usage: suveraen-mesh after-restore TENANT
EOF
  exit 2
}

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# A device takes no network map older than the one it holds, which a restore takes the database back behind: it would
# keep its map and pass over every change until the serial caught up with its own. Each change raises the serial by
# one, so a million more is past any a restore loses. Each account's serial as the update found and left it, then
# management starts again on the restored state.
after_restore() {
  local t=$1 labels primary
  labels=$(kubectl --request-timeout=30s get namespace "$t-netbird" -o json |
    jq -r '.metadata.labels | "\(.["suveraen/tenant"] // "") \(.["suveraen/app"] // "")"')
  if [ "$labels" != "$t netbird" ]; then
    echo "suveraen-mesh: $t runs no mesh in $t-netbird." >&2
    exit 1
  fi
  primary=$(kubectl --request-timeout=30s -n "$t-postgres" get pods \
    -l cnpg.io/cluster=postgres,cnpg.io/instanceRole=primary -o jsonpath='{.items[*].metadata.name}')
  if ! [[ $primary =~ ^[a-z0-9-]+$ ]]; then
    echo "suveraen-mesh: $t-postgres has no one primary to write to: ${primary:-none}" >&2
    exit 1
  fi
  kubectl --request-timeout=60s -n "$t-postgres" exec "$primary" -c postgres -- \
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
  after-restore)
    [ $# = 1 ] && [[ $1 =~ ^[a-z][a-z0-9]{4}$ ]] || usage
    after_restore "$1"
    ;;
  *)
    usage
    ;;
esac
