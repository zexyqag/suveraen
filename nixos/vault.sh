# Each tenant's password vault (kubernetes/apps/vaultwarden), from a server. Its accounts are read in the tenant's
# PostgreSQL as the vault's own role (tenant-apps.sh); what only Vaultwarden does to an account, such as unregister its
# phones at the relay and remove its files, a second Vaultwarden does in the vault's pod for the length of one command
# (side_start). vault.nix sets idm, suveraen-idm (idm.nix), which asks each tenant's Kanidm after its people.

usage() {
  cat >&2 <<'EOF'
usage: suveraen-vault check
       suveraen-vault users TENANT
       suveraen-vault offboard TENANT ID
       suveraen-vault erase TENANT ID
       suveraen-vault relink TENANT PERSON NEW-PERSON
EOF
  exit 2
}

run=/run/suveraen-vault
uuid='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

fail() {
  echo "suveraen-vault: $*" >&2
  exit 1
}

# SQL from stdin in a tenant's vault database, with the rest as app_sql's arguments.
sql() {
  local t=$1
  shift
  app_sql "$t" vaultwarden "$@"
}

# The issuer a tenant's vault knows its Kanidm by, under which an account's link names its person: {issuer}/{ID}.
issuer() {
  local found
  found=$(kubectl --request-timeout=30s -n "$1-vaultwarden" get statefulset vaultwarden -o json | jq -r '
    [.spec.template.spec.containers[]? | select(.name == "app") | .env[]? | select(.name == "SSO_AUTHORITY")
      | .value] | if length == 1 then .[0] else "" end') || return 1
  if ! [[ $found =~ ^https://[a-z0-9.-]+/[a-z0-9/_-]+$ ]]; then
    echo "suveraen-vault: StatefulSet vaultwarden in $1-vaultwarden names no single issuer" >&2
    return 1
  fi
  echo "$found"
}

# Each of a tenant's accounts by its ID, with the person of the tenant's Kanidm its link names, or null for none,
# whether it is enabled, and how many devices hold a session of it, as a JSON list.
accounts() {
  local issuer
  issuer=$(issuer "$1") || return 1
  sql "$1" <<'EOF' | jq -c --arg issuer "$issuer/" --arg uuid "$uuid" \
    'map(.person = ((.link // "" | select(startswith($issuer)) | ltrimstr($issuer) | select(test($uuid))) // null)
      | del(.link))'
select coalesce(json_agg(json_build_object('id', u.uuid, 'link', s.identifier, 'enabled', u.enabled,
    'devices', (select count(*) from devices d where d.user_uuid = u.uuid)) order by u.uuid), '[]')
  from users u left join sso_users s on s.user_uuid = u.uuid;
EOF
}

# What the servers' checks judge (host-checks/vault.jq), with no credential: each tenant's accounts, and how its Kanidm
# answers for their people. A tenant whose accounts can't be read is unchecked.
check() {
  local list t accounts why people
  list=$(tenants vaultwarden) || exit 1
  for t in $list; do
    if ! accounts=$(accounts "$t" 2>&1) || ! jq -e 'type == "array"' <<<"$accounts" >/dev/null 2>&1; then
      # psql says what went wrong first, and then where.
      why=$(grep -m 1 . <<<"$accounts" || true)
      jq -nc --arg tenant "$t" --arg why "${why:-the query printed nothing}" '{$tenant, unchecked: $why}'
      continue
    fi
    # shellcheck disable=SC2046 # one UUID each
    people=$("$idm" accounts "$t" $(jq -r '[.[].person // empty] | unique[]' <<<"$accounts") 2>/dev/null) || people=null
    jq -c --arg tenant "$t" --slurpfile people <(printf '%s' "$people") '{$tenant, accounts: ., people: $people[0]}' \
      <<<"$accounts"
  done | jq -sc '{tenants: .}'
}

# A tenant's accounts, one a line: its ID, its person's, whether it is enabled, how many devices hold a session of it,
# and how Kanidm answers for its person.
users() {
  local accounts people
  accounts=$(accounts "$1") || exit 1
  # shellcheck disable=SC2046 # one UUID each
  people=$("$idm" accounts "$1" $(jq -r '[.[].person // empty] | unique[]' <<<"$accounts")) || exit 1
  jq -r --argjson people "$people" '["ACCOUNT", "PERSON", "VAULT", "DEVICES", "KANIDM"],
    (.[] | [.id, .person // "-", (if .enabled then "enabled" else "disabled" end), .devices,
      (if .person == null then "-" else $people[.person] end)])
    | @tsv' <<<"$accounts"
}

# The account of a tenant's that an ID names, its own or its person's, as JSON.
account() {
  local found
  found=$(accounts "$1") || exit 1
  found=$(jq -c --arg id "$2" 'first(.[] | select(.id == $id or .person == $id)) // empty' <<<"$found")
  [ -n "$found" ] || fail "$1 has no account of $2."
  echo "$found"
}

# Kanidm has to have let an account's person go before anything here closes the account, so that a wrong ID locks no
# member out. One linked to no person of the tenant's Kanidm, as its link is under another issuer or none, has no one to
# ask after, so only once it is disabled.
left() {
  local person state
  person=$(jq -r '.person // empty' <<<"$2")
  if [ -z "$person" ]; then
    jq -e '.enabled | not' <<<"$2" >/dev/null ||
      fail "account $(jq -r .id <<<"$2") links to no person of $1's Kanidm to tell whether it was let go."
    return 0
  fi
  state=$("$idm" accounts "$1" "$person" | jq -r --arg person "$person" '.[$person]')
  case $state in
    expired | gone) ;;
    *) fail "$person is $state at $1's Kanidm, where they have to be expired first." ;;
  esac
}

# A command in the vault's container, as its own user.
in_pod() {
  kubectl --request-timeout=60s -n "$ns" exec -i vaultwarden-0 -c app -- "$@"
}

# A second Vaultwarden in the vault's pod beside the release's, on the pod's loopback alone, with no jobs of its own and
# with the admin pages, which the release's never serves, under a token of this run's. The token reaches it on stdin,
# so no command line holds it, nor the API server's audit log, and so does the admin session's cookie, to curl in the
# pod, with each call. It runs while its stdin stays open, ten minutes at most, and then its shell stops it by its own
# ID and waits for it to end.
side=
side_start() {
  token=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
  trap side_stop EXIT
  # shellcheck disable=SC2016 # the pod's shell expands them
  exec {side}> >(exec kubectl -n "$ns" exec -i vaultwarden-0 -c app -- sh -c 'read -r token || exit 1
    ADMIN_TOKEN=$token ROCKET_ADDRESS=127.0.0.1 ROCKET_PORT=8181 JOB_POLL_INTERVAL_MS=0 /vaultwarden &
    pid=$!
    read -r -t 600 stop
    kill "$pid"
    wait "$pid"' >"$run/side.log" 2>&1)
  sidepid=$!
  printf '%s\n' "$token" >&"$side"
  for _ in $(seq 60); do
    if in_pod curl -fsS -o /dev/null http://127.0.0.1:8181/alive </dev/null 2>/dev/null; then
      cookie=$(printf 'data-urlencode = "token=%s"\n' "$token" |
        in_pod curl -sS -K - -o /dev/null -D - http://127.0.0.1:8181/admin |
        sed -n 's/^set-cookie: *\(VW_ADMIN=[^;]*\);.*$/\1/Ip')
      [ -n "$cookie" ] || fail "the second Vaultwarden in $ns took no admin sign-in."
      return 0
    fi
    kill -0 "$sidepid" 2>/dev/null || break
    sleep 1
  done
  cat "$run/side.log" >&2
  fail "the second Vaultwarden in $ns didn't start."
}

# Its stdin closed, the second Vaultwarden ends, then its shell, then kubectl; and nothing of it may be left in the pod
# but the release's, its ID 1. The image's pgrep, busybox's, matches the name a process was started by, /vaultwarden.
side_stop() {
  local found
  [ -n "$side" ] || return 0
  exec {side}>&-
  side=
  timeout 60 tail --pid="$sidepid" -f /dev/null || kill "$sidepid" 2>/dev/null || true
  found=$(in_pod pgrep -x /vaultwarden </dev/null) || found=
  [ "$found" = 1 ] || fail "a second Vaultwarden is still in $ns: ${found//$'\n'/ }"
}

# An account's admin page at the second Vaultwarden, from the pod: a POST, which takes no body.
admin() {
  local code
  code=$(printf 'header = "Cookie: %s"\n' "$cookie" |
    in_pod curl -sS -K - -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      "http://127.0.0.1:8181/admin/users/$1/$2") || code=
  [ "$code" = 200 ] || fail "$2 of account $1 answered ${code:-nothing}."
}

# offboard or erase. Both first ask the relay to forget the account's phones, end its devices' sessions and give it a
# new security stamp, which ends the access tokens any device still holds (deauth); offboard then disables it, which
# stops its API key and its sign-ins, and its Sends, which anyone with a link could still open, and erase deletes it
# with its vault, its Sends and its files. Vaultwarden only logs a call to the relay that failed, and leaves no device
# to ask again for, so the run first finds the proxy up and in the end names the phones the relay may still know. Its
# ID is kept for the deletion record: a run after a restore finds the account by it, once Kanidm has let its person go
# again.
close() {
  local verb=$1 t=$2 found id person phones up sends
  ns="$t-vaultwarden"
  found=$(account "$t" "$3")
  left "$t" "$found"
  id=$(jq -r .id <<<"$found")
  person=$(jq -r '.person // "no person of its Kanidm"' <<<"$found")
  phones=$(sql "$t" -v "id=$id" <<<"select push_uuid from devices
    where user_uuid = :'id' and push_token is not null and push_uuid is not null order by push_uuid;") || exit 1
  if [ -n "$phones" ]; then
    up=$(kubectl --request-timeout=30s -n "$ns" get deployment egress -o jsonpath='{.status.availableReplicas}') || up=
    [ "${up:-0}" -ge 1 ] || fail "the proxy in $ns, through which the relay forgets account $id's phones, isn't up."
  fi
  side_start
  admin "$id" deauth
  if [ "$verb" = offboard ]; then
    admin "$id" disable
    # Once no session of the account is left to open them again, and before anything else that could fail.
    sql "$t" --write -v "id=$id" <<<"update sends set disabled = true where user_uuid = :'id';" >/dev/null
  else
    admin "$id" delete
  fi
  side_stop
  found=$(accounts "$t" | jq -c --arg id "$id" 'map(select(.id == $id))')
  if [ "$verb" = offboard ]; then
    sends=$(sql "$t" -v "id=$id" <<<"select count(*) from sends where user_uuid = :'id' and not disabled;") || exit 1
    jq -e --argjson sends "$sends" 'length == 1 and (.[0].enabled | not) and .[0].devices == 0 and $sends == 0' \
      <<<"$found" >/dev/null || fail "account $id is open still: $found, with $sends of its Sends"
    echo "$t: account $id, of $person, offboarded; keep its ID for the deletion record"
  else
    [ "$found" = '[]' ] || fail "account $id is still there: $found"
    echo "$t: account $id, of $person, erased; keep its ID for the deletion record"
  fi
  if grep 'Unable to unregister devices' "$run/side.log" >&2; then
    fail "the relay may still know account $id's phones by ${phones//$'\n'/, }."
  fi
}

# The account of a person Kanidm lost now links to the person it made for them again, under a new ID, as only SQL can:
# the vault matches no account by mail, which a new person given an old one's could take. The old person has to be gone
# or expired, the new one not, and no account may link to them yet.
relink() {
  local t=$1 old=$2 new=$3 issuer accounts id states updated
  issuer=$(issuer "$t") || exit 1
  accounts=$(accounts "$t") || exit 1
  id=$(jq -r --arg person "$old" 'first(.[] | select(.person == $person) | .id) // empty' <<<"$accounts")
  [ -n "$id" ] || fail "$t has no account of $old."
  if jq -e --arg person "$new" 'any(.[]; .person == $person)' <<<"$accounts" >/dev/null; then
    fail "an account of $new is in $t's vault already."
  fi
  states=$("$idm" accounts "$t" "$old" "$new")
  if ! jq -e --arg old "$old" --arg new "$new" \
    '(.[$old] | IN("expired", "gone")) and (.[$new] | IN("enabled", "unusable"))' <<<"$states" >/dev/null; then
    fail "at $t's Kanidm $old has to be gone or expired, and $new not: $states"
  fi
  updated=$(sql "$t" --write -v "old=$issuer/$old" -v "new=$issuer/$new" \
    <<<"update sso_users set identifier = :'new' where identifier = :'old' returning user_uuid;")
  [ "$updated" = "$id" ] || fail "account $id was not relinked: ${updated:-no row}"
  echo "$t: account $id now links to $new"
}

valid_tenant() {
  [[ $1 =~ $tenant_id ]] || usage
}

valid_id() {
  [[ $1 =~ $uuid ]] || usage
}

# One run that changes a vault at a time, which the second Vaultwarden's port alone would hold to: a second would find
# the first's.
lock() {
  umask 077
  install -d -m 0700 "$run"
  exec 9>"$run/lock"
  flock -n 9 || fail "another run holds the lock."
}

[ $# != 0 ] || usage
command=$1
shift
case $command in
  check)
    [ $# = 0 ] || usage
    check
    ;;
  users)
    [ $# = 1 ] || usage
    valid_tenant "$1"
    users "$1"
    ;;
  offboard | erase)
    [ $# = 2 ] || usage
    valid_tenant "$1"
    valid_id "$2"
    lock
    close "$command" "$1" "$2"
    ;;
  relink)
    [ $# = 3 ] || usage
    valid_tenant "$1"
    valid_id "$2"
    valid_id "$3"
    lock
    relink "$1" "$2" "$3"
    ;;
  *)
    usage
    ;;
esac
