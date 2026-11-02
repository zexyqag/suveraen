# Each tenant's Kanidm, from a server: by exec into its pod (kubernetes/apps/kanidm) and at its public name. It keeps
# no credential. What needs one recovers idm_admin with a new password that lives in this process alone, and every run
# disables idm_admin, admin and anonymous as it starts, as it finishes with a tenant, and as it ends. idm.nix sets
# run, the directory it works in; cacert, the CA Kanidm's certificates come from, or none for the system's; gateway,
# this server's address, where its gateway passes each identity host through to its Kanidm; and logscan, the filter
# for Kanidm's log (idm-migrations.jq).

usage() {
  cat >&2 <<'EOF'
usage: suveraen-idm admin TENANT platform|tenant LOGIN DISPLAY-NAME [ATTESTATION-CA-LIST]
       suveraen-idm sync [TENANT]
       suveraen-idm rotate TENANT CLIENT
       suveraen-idm rotate --all TENANT
       suveraen-idm check
EOF
  exit 2
}

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
# The caller's own client settings could point it elsewhere, or at certificates it shouldn't trust, and a proxy would
# look the identity hosts up itself.
unset "${!KANIDM_@}" http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
cacerts=()
if [ -n "$cacert" ]; then
  cacerts=(--cacert "$cacert")
  export KANIDM_CA_PATH=$cacert
fi
# An identity host is on its tenant's own domain, whose DNS an organisation may run itself, and point at a host of its
# own that takes idm_admin's password and relays it. So no name of Kanidm's is ever looked up: each is reached at this
# server's gateway, which passes it through by name to that tenant's Kanidm alone.
at=$gateway
[[ $at != *:* ]] || at="[$at]"
umask 077
install -d -m 0700 "$run"
exec 9>"$run/lock"
# Not in a home, which a sign-in replaces with one of its own.
export KUBECACHEDIR=$run/kube

# What Kanidm makes for basic secrets and recovered passwords alike.
pattern='^[a-hjkp-z0-9]{48}$'
# PKCE wants 43 characters or more; any do, as the probe's code is never valid, which Kanidm checks after the secret.
verifier=suveraenidmprobe0123456789abcdefghjkpqrstuvwxyz
failed=
fail() {
  echo "suveraen-idm: $*" >&2
  failed=1
}

# web ORIGIN PATH [CURL-ARGS...]: a request to a tenant's Kanidm, at the gateway here.
web() {
  local origin=$1 path=$2
  shift 2
  curl -q -sS --proto =https --connect-timeout 5 --max-time 15 "${cacerts[@]}" --resolve "${origin#https://}:443:$at" \
    "$@" "$origin$path"
}

# The client finds a host through the system's name service alone, so it runs in a mount namespace of its own, whose
# hosts file names the identity host it signed in to at the gateway here (pin), and whose name service reads nothing
# else. Without a terminal it fails where it would ask.
cli() {
  # shellcheck disable=SC2016 # the inner shell expands them
  unshare --mount -- "$BASH" -c 'mount --bind "$1" /etc/hosts && mount --bind "$2" /etc/nsswitch.conf &&
    { [ ! -d /run/nscd ] || mount -t tmpfs none /run/nscd; } && shift 2 && exec kanidm "$@"' \
    cli "$run/hosts" "$run/nsswitch.conf" "$@" </dev/null
}

pin() {
  printf '%s %s\n' "$gateway" "${1#https://}" >"$run/hosts"
  echo 'hosts: files' >"$run/nsswitch.conf"
}

# kanidmd in a tenant's Kanidm pod, which finds the server's admin socket through its settings.
in_pod() {
  kubectl --request-timeout=60s -n "$1-kanidm" exec kanidm-0 -c app -- /sbin/kanidmd "${@:2}" </dev/null
}

# Every tenant that runs Kanidm, from its namespace.
tenants() {
  kubectl --request-timeout=30s get namespaces -l suveraen/app=kanidm -o json | jq -r '.items[]
    | (.metadata.labels["suveraen/tenant"] // "") as $t
    | select(($t | test("^[a-z][a-z0-9]{4}$")) and .metadata.name == "\($t)-kanidm") | $t'
}

# A tenant's Kanidm at its public name, from its settings, where render holds it to the host alone.
origin() {
  local toml url
  toml=$(kubectl --request-timeout=30s -n "$1-kanidm" get configmap kanidm -o jsonpath='{.data.server\.toml}') ||
    return 1
  url=$(sed -nE 's#^origin = "(https://[a-z0-9.-]+)"$#\1#p' <<<"$toml")
  [[ $url =~ ^https://[a-z0-9.-]+$ ]] || return 1
  echo "$url"
}

# One line for each client in the tenant's attachments, sso-<app> (components/sso), with tabs between its app, name,
# kind, the redirect the probe names, the flags it asks for, those last applied, and what is wrong with it, "-" for
# none. They come from the tenant's Kanidm namespace, so none names another tenant's app.
clients() {
  kubectl --request-timeout=30s -n "$1-kanidm" get configmaps -o json | jq -r '.items[]
    | select(.metadata.name | test("^sso-[a-z][a-z0-9]*$"))
    | (.metadata.name | ltrimstr("sso-")) as $app
    | (.metadata.annotations // {}) as $a
    | "\($app)-oidc" as $name
    | [.data["50-\($app).json"] // "null" | fromjson? | .assertions[]? | select(.state == "present" and .name == $name)]
      as $found
    | ($found[0].class // []) as $class
    | [("basic", "public") as $k | select($class | index("oauth2_resource_server_\($k)")) | $k] as $kinds
    | ($found[0].oauth2_rs_origin // [] | first // null | if type == "string" then . else "" end) as $redirect
    | [("disable-pkce", "localhost-redirects") as $f | select($a | has("suveraen/\($f)")) | $f] as $set
    | [$set[] | select($a["suveraen/\(.)"] == "true")] as $flags
    | [$app, $name, ($kinds[0] // ""), $redirect,
       (if $flags == [] then "none" else $flags | join(",") end),
       ($a["suveraen/flags-applied"] // ""),
       (if ($found | length) != 1 then "no single client \($name)"
        elif ($kinds | length) != 1 then "\($name) is not either confidential or public"
        elif ($redirect | test("^https://[a-z0-9.-]+(:[0-9]{1,5})?/[!-~]*$") | not) then "\($name) has no redirect"
        elif $flags != $set then "a flag is set to something but true"
        elif $kinds[0] == "basic" and ($flags | index("localhost-redirects")) then
          "redirects to the device are for a public client"
        elif $kinds[0] == "public" and ($flags | index("disable-pkce")) then "a public client keeps PKCE"
        else "" end)]
    | map(if . == "" then "-" end) | @tsv'
}

# Whether an app's namespace is there, and the tenant's.
app_namespace() {
  local json
  json=$(kubectl --request-timeout=30s get namespace "$1-$2" --ignore-not-found -o json) &&
    [ -n "$json" ] && [ "$(jq -r '.metadata.labels["suveraen/tenant"] // ""' <<<"$json")" = "$1" ]
}

# What Secret sso in an app's namespace holds: sets found to secret (and value to it), placeholder, invalid or
# missing. The app's namespace writes it, so anything but Flux's placeholder or a secret as Kanidm makes them is
# never passed on.
read_secret() {
  local json b64
  value=
  json=$(kubectl --request-timeout=30s -n "$1" get secret sso --ignore-not-found -o json) || return 1
  if [ -z "$json" ]; then
    found=missing
    return 0
  fi
  b64=$(jq -r '.data["client-secret"] // ""' <<<"$json")
  if [ "$b64" = cGVuZGluZw== ]; then
    found=placeholder
  elif [[ $b64 =~ ^[A-Za-z0-9+/]{64}$ ]] && value=$(base64 -d <<<"$b64") && [[ $value =~ $pattern ]]; then
    found=secret
  else
    found=invalid
    value=
  fi
}

# Kanidm's answer to a token request from a confidential client, with the secret on stdin and the rest fixed: it
# checks the secret before the code, so a right one gets 400 for the junk code, a wrong one 401.
probe() {
  local code
  code=$(web "$1" /oauth2/token -o /dev/null -w '%{http_code}' -d grant_type=authorization_code -d code=probe \
    --data-urlencode "redirect_uri=$3" -d "code_verifier=$verifier" --data-urlencode "client_id=$2" \
    --data-urlencode client_secret@- 2>/dev/null) || true
  echo "${code:-000}"
}

# How Kanidm answers the first step of a sign-in as an account: expired once disabled, enabled when it offers a way
# in, unusable when it can't (no credential yet), unknown without an answer.
account() {
  local state
  state=$(web "$1" /v1/auth -H 'Content-Type: application/json' -d "{\"step\": {\"init\": \"$2\"}}" 2>/dev/null |
    jq -r 'if .state.denied? == "account expired" then "expired"
      elif (.state | type) == "object" and (.state | has("choose") or has("continue") or has("success")) then "enabled"
      elif (.state.denied? | type) == "string" then "unusable"
      else "unknown" end' 2>/dev/null) || true
  echo "${state:-unknown}"
}

# kanidmd exits 0 whatever happened, so an account counts as disabled once Kanidm takes it for expired.
disable() {
  local name left=()
  for name in idm_admin admin anonymous; do
    in_pod "$1" disable-account "$name" >/dev/null 2>&1 || true
    [ "$(account "$2" "$name")" = expired ] || left+=("$name")
  done
  if [ ${#left[@]} != 0 ]; then
    fail "$1: ${left[*]} not disabled; run suveraen-idm sync $1 again."
    return 1
  fi
}

# The tenants whose idm_admin this run recovered and hasn't disabled again, with their origins, and the homes it
# signed in with.
declare -A recovered=()
homes=()
finish() {
  local t
  for t in "${!recovered[@]}"; do
    disable "$t" "${recovered[$t]}" || true
  done
  rm -rf "${homes[@]}"
}

# Takes the lock, at once with now or else within 5 minutes, and only then clears the homes a run that was killed
# left and cleans up after this one as it ends: a run that never held it leaves the one that does alone.
lock() {
  if [ "${1:-}" = now ]; then
    flock -n 9 || return 1
  elif ! flock -w 300 9; then
    echo "suveraen-idm: another run holds the lock." >&2
    exit 1
  fi
  rm -rf "$run"/home.*
  trap finish EXIT
}

# Recovers idm_admin with a new password, which stays in this process, and signs the client in with it, with its
# session in a home of its own on tmpfs.
sign_in() {
  local out password
  recovered[$1]=$2
  echo "$1: recovering idm_admin"
  out=$(in_pod "$1" scripting recover-account idm_admin) || true
  password=$(jq -r 'select(.status == "ok") | .output' <<<"$out" 2>/dev/null) || true
  if ! [[ $password =~ $pattern ]]; then
    fail "$1: idm_admin could not be recovered: $(jq -r '.message // empty' <<<"$out" 2>/dev/null || true)"
    return 1
  fi
  HOME=$(mktemp -d "$run/home.XXXXXX") || return 1
  homes+=("$HOME")
  export HOME KANIDM_URL=$2 KANIDM_NAME=idm_admin
  pin "$2"
  if ! KANIDM_PASSWORD=$password cli login >/dev/null; then
    fail "$1: idm_admin could not sign in."
    return 1
  fi
}

sign_out() {
  disable "$1" "$2" || return 1
  unset "recovered[$1]"
  rm -rf "$HOME"
  echo "$1: idm_admin, admin and anonymous disabled"
}

# Marks on a client's attachment the flags it has in Kanidm, which reads no annotation.
mark() {
  kubectl --request-timeout=30s -n "$1-kanidm" annotate configmap "sso-$2" --overwrite --field-manager=suveraen-idm \
    "suveraen/flags-applied=$3" >/dev/null
}

# As idm_admin: sets a client's flags in Kanidm, and copies a confidential one's secret, a new one with reset, into
# its app's Secret sso, which then has to pass the probe.
repair() {
  local tenant=$1 origin=$2 app=$3 client=$4 kind=$5 redirect=$6 flags=$7 how=$8 secret code
  if [ "$kind" = basic ]; then
    if ! app_namespace "$tenant" "$app"; then
      fail "$tenant: $client: no namespace $tenant-$app of the tenant's."
      return 1
    fi
    if [ "$how" = reset ] && ! cli system oauth2 reset-basic-secret "$client" >/dev/null; then
      fail "$tenant: $client: Kanidm made no new secret."
      return 1
    fi
    if [[ ,$flags, == *,disable-pkce,* ]]; then
      set -- warning-insecure-client-disable-pkce
    else
      set -- enable-pkce
    fi
  elif [[ ,$flags, == *,localhost-redirects,* ]]; then
    set -- enable-localhost-redirects
  else
    set -- disable-localhost-redirects
  fi
  if ! cli system oauth2 "$1" "$client" >/dev/null; then
    fail "$tenant: $client: Kanidm took no $1."
    return 1
  fi
  if [ "$kind" = basic ]; then
    secret=$(cli system oauth2 show-basic-secret "$client") || secret=
    if ! [[ $secret =~ $pattern ]]; then
      fail "$tenant: $client: Kanidm shows no secret."
      return 1
    fi
    if ! printf '%s' "$secret" | jq -Rsc '{data: {"client-secret": @base64}}' |
      kubectl --request-timeout=30s -n "$tenant-$app" patch secret sso --type merge --field-manager=suveraen-idm \
        --patch-file /dev/stdin >/dev/null; then
      fail "$tenant: $client: Secret sso in $tenant-$app could not be written."
      return 1
    fi
    code=$(printf '%s' "$secret" | probe "$origin" "$client" "$redirect")
    if [ "$code" != 400 ]; then
      fail "$tenant: $client: Kanidm answers $code for the secret copied into $tenant-$app/sso."
      return 1
    fi
    echo "$tenant: $client: $([ "$how" = reset ] && echo "a new secret" || echo "its secret") in $tenant-$app/sso"
  fi
  if ! mark "$tenant" "$app" "$flags"; then
    fail "$tenant: $client: sso-$app could not be marked."
    return 1
  fi
  echo "$tenant: $client: flags $flags"
}

# Brings a tenant's clients in line with Kanidm: sync copies what is wrong; rotate gives one confidential client a new
# secret, and rotate-all every confidential client one and every client its flags again. idm_admin is recovered only
# when something needs it.
tenant() {
  local t=$1 mode=$2 only=${3:-} origin list app client kind redirect flags applied error why code how todo=() each
  if ! origin=$(origin "$t"); then
    fail "$t: ConfigMap kanidm in $t-kanidm names no single origin."
    return 1
  fi
  disable "$t" "$origin" || return 1
  if ! list=$(clients "$t"); then
    fail "$t: its attachments could not be read."
    return 1
  fi
  while IFS=$'\t' read -r app client kind redirect flags applied error; do
    [ -n "$app" ] || continue
    if [ "$error" != - ]; then
      fail "$t: sso-$app: $error"
      continue
    fi
    each="$app"$'\t'"$client"$'\t'"$kind"$'\t'"$redirect"$'\t'"$flags"
    case $mode in
      rotate)
        if [ "$client" = "$only" ]; then
          if [ "$kind" != basic ]; then
            fail "$t: $client is a public client, without a secret."
            return 1
          fi
          todo+=("$each")
        fi
        continue
        ;;
      rotate-all)
        todo+=("$each")
        continue
        ;;
    esac
    why=
    if [ "$kind" = basic ]; then
      if ! app_namespace "$t" "$app"; then
        fail "$t: $client: no namespace $t-$app of the tenant's."
        continue
      fi
      if ! read_secret "$t-$app"; then
        fail "$t: $client: Secret sso in $t-$app could not be read."
        continue
      fi
      case $found in
        missing)
          fail "$t: $client: $t-$app has no Secret sso yet, which Flux makes."
          continue
          ;;
        placeholder) why="still the placeholder" ;;
        invalid) why="holds no secret Kanidm makes" ;;
        secret)
          code=$(printf '%s' "$value" | probe "$origin" "$client" "$redirect")
          value=
          case $code in
            400) ;;
            401) why="wrong for Kanidm" ;;
            *)
              fail "$t: $client: Kanidm answers $code to the probe."
              continue
              ;;
          esac
          ;;
      esac
    fi
    if [ -z "$why" ] && [ "$applied" = - ] && [ "$flags" = none ]; then
      # A new client has Kanidm's defaults, which are no flags.
      if ! mark "$t" "$app" none; then
        fail "$t: $client: sso-$app could not be marked."
        continue
      fi
      applied=none
    fi
    if [ -z "$why" ] && [ "$applied" = "$flags" ]; then
      echo "$t: $client: in line"
      continue
    fi
    echo "$t: $client: ${why:-flags $flags not applied}"
    todo+=("$each")
  done <<<"$list"
  if [ "$mode" = rotate ] && [ ${#todo[@]} = 0 ]; then
    fail "$t: no client $only."
    return 1
  fi
  if [ ${#todo[@]} = 0 ]; then
    return 0
  fi
  sign_in "$t" "$origin" || return 1
  how=reset
  [ "$mode" != sync ] || how=copy
  for each in "${todo[@]}"; do
    IFS=$'\t' read -r app client kind redirect flags <<<"$each"
    repair "$t" "$origin" "$app" "$client" "$kind" "$redirect" "$flags" "$how" || true
  done
  sign_out "$t" "$origin"
}

# What the servers' checks judge (host-checks.nix), with no credential: for each tenant, how Kanidm answers for its
# admin accounts, when its container started and what went wrong as it ran its migrations then, null once its log no
# longer reaches back to that, and for each client whether its app's copy of the secret passes the probe and its flags
# are applied. A tenant whose Kanidm can't be looked at is unchecked, and anything without an answer unknown.
unchecked() {
  jq -nc --arg tenant "$1" --arg why "$2" '{$tenant, unchecked: $why}'
}

check() {
  local list t origin attached app client kind redirect flags applied error state applied_all accounts started migrations
  local clients
  list=$(tenants) || exit 1
  for t in $list; do
    if ! origin=$(origin "$t"); then
      unchecked "$t" "ConfigMap kanidm in $t-kanidm names no single origin"
      continue
    fi
    if ! attached=$(clients "$t" 2>/dev/null); then
      unchecked "$t" "its attachments could not be read"
      continue
    fi
    accounts=$(for name in idm_admin admin anonymous; do
      jq -nc --arg name "$name" --arg state "$(account "$origin" "$name")" '{($name): $state}'
    done | jq -sc add)
    started=$(kubectl --request-timeout=30s -n "$t-kanidm" get pod kanidm-0 -o json 2>/dev/null | jq -r '
      .status.containerStatuses[]? | select(.name == "app") | .state.running.startedAt // empty
      | select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))') || started=
    # Only its start counts, where Kanidm runs its migrations and starts its web server within a few kilobytes; the rest
    # may be all a client had it log.
    migrations=$(kubectl --request-timeout=60s -n "$t-kanidm" logs kanidm-0 -c app --timestamps \
      --limit-bytes=1048576 2>/dev/null | jq -Rsc --arg started "$started" -f "$logscan") || migrations=null
    clients=$(while IFS=$'\t' read -r app client kind redirect flags applied error; do
      [ -n "$app" ] || continue
      if [ "$error" != - ]; then
        state=unusable
      elif [ "$kind" != basic ]; then
        state=-
      elif ! app_namespace "$t" "$app" || ! read_secret "$t-$app"; then
        state=unknown
      elif [ "$found" = secret ]; then
        case $(printf '%s' "$value" | probe "$origin" "$client" "$redirect") in
          400) state=right ;;
          401) state=wrong ;;
          *) state=unknown ;;
        esac
        value=
      else
        state=$found
      fi
      # A new client has Kanidm's defaults, which are no flags.
      applied_all=false
      if [ "$error" = - ] && { [ "$applied" = "$flags" ] || { [ "$applied" = - ] && [ "$flags" = none ]; }; }; then
        applied_all=true
      fi
      jq -nc --arg client "$client" --arg app "$app" --arg kind "$kind" --arg secret "$state" \
        --argjson flags "$applied_all" '{$client, $app, $kind, $secret, $flags}'
    done <<<"$attached" | jq -sc .)
    jq -nc --arg tenant "$t" --argjson accounts "$accounts" --arg started "$started" \
      --argjson migrations "$migrations" --argjson clients "$clients" \
      '{$tenant, $accounts, started: ($started | select(. != "") // null), $migrations, $clients}'
  done | jq -sc '{tenants: .}'
}

# Kanidm's own groups through which tenant-admins make people, and change people and groups outside the admin groups.
delegated=(idm_people_on_boarding idm_service_desk idm_group_admins)

valid_tenant() {
  [[ $1 =~ ^[a-z][a-z0-9]{4}$ ]] || usage
}

[ $# != 0 ] || usage
command=$1
shift
case $command in
  check)
    [ $# = 0 ] || usage
    # A run that holds the lock may be halfway through a change.
    if ! lock now; then
      echo '{"busy": true}'
      exit 0
    fi
    check
    ;;
  sync)
    [ $# -le 1 ] || usage
    if [ $# = 1 ]; then
      valid_tenant "$1"
      lock
      list=$1
    else
      lock
      list=$(tenants)
    fi
    for t in $list; do
      tenant "$t" sync || true
    done
    ;;
  rotate)
    [ $# = 2 ] || usage
    if [ "$1" = --all ]; then
      valid_tenant "$2"
      lock
      tenant "$2" rotate-all || true
    else
      valid_tenant "$1"
      [[ $2 =~ ^[a-z][a-z0-9]*-oidc$ ]] || usage
      lock
      tenant "$1" rotate "$2" || true
    fi
    ;;
  admin)
    [ $# = 4 ] || [ $# = 5 ] || usage
    t=$1 role=$2 login=$3 name=$4 cas=${5:-}
    valid_tenant "$t"
    if ! [[ $login =~ ^[a-z][a-z0-9_]{1,19}$ ]] || [ -z "$name" ] || [[ $name =~ [[:cntrl:]] ]]; then
      usage
    fi
    case $role in
      platform | tenant) group="$role-admins" ;;
      *) usage ;;
    esac
    if [ -n "$cas" ] && { [ "$role" != platform ] || ! jq -e . "$cas" >/dev/null; }; then
      echo "suveraen-idm: an attestation CA list is a JSON file, for platform admins." >&2
      exit 2
    fi
    lock
    if ! origin=$(origin "$t"); then
      fail "$t: ConfigMap kanidm in $t-kanidm names no single origin."
      exit 1
    fi
    disable "$t" "$origin"
    sign_in "$t" "$origin"
    # Without the makes and models it trusts, Kanidm lets no platform admin enrol anything.
    if [ "$role" = platform ] && [ -z "$cas" ] &&
      ! cli -o json group get platform-admins | jq -e '.attrs | has("webauthn_attestation_ca_list")' >/dev/null; then
      fail "$t: platform-admins has no attestation CA list yet, without which no one can enrol: give one."
      exit 1
    fi
    # Kanidm holds a person to the kind of credential their groups ask for only as one is enrolled, never as they sign
    # in, and a tenant admin may have given anyone outside the admin groups a password, or a reset link that still
    # works once they join one. So the person is new, or in the group already and without a credential it refuses.
    person=$(cli -o json person get "$login" 2>/dev/null) || person=
    if jq -e .attrs <<<"$person" >/dev/null 2>&1; then
      if ! jq -e --arg g "$group@" '.attrs.directmemberof // [] | any(startswith($g))' <<<"$person" >/dev/null; then
        fail "$t: $login is a person outside $group already, whose credentials no one vouches for; choose another."
        exit 1
      fi
      held=$(jq -r --arg role "$role" '.attrs | [("primary_credential", if $role == "platform" then "passkeys"
        else empty end) as $k | select(has($k)) | $k] | join(", ")' <<<"$person")
      if [ -n "$held" ]; then
        fail "$t: $login holds $held, which Kanidm still takes as they sign in though $group refuses it."
        exit 1
      fi
    else
      person=
    fi
    # tenant-admins leaves Kanidm's own groups while the person joins: then no tenant admin can give anyone a
    # credential that would still work once they are an admin, and idm_admin may change its members, which in those
    # groups its own members alone may. A run that stops before it is back leaves tenant admins with fewer rights until
    # the next. platform-admins stays in idm_admins, which manages it.
    for g in "${delegated[@]}"; do
      cli group remove-members "$g" tenant-admins >/dev/null
    done
    if [ -z "$person" ]; then
      cli person create "$login" "$name" >/dev/null
    fi
    cli group add-members "$group" "$login" >/dev/null
    # Kanidm's own groups, which no migration reaches. People neither rename themselves nor set their mail, which apps
    # take as verified; tenant admins may let them in their own tenant, until this runs again. Tenant admins make
    # people, reset the credentials and validity of those outside the admin groups, and manage the groups no admin
    # group holds; platform admins all of it.
    cli group purge-members idm_people_self_name_write >/dev/null
    cli group purge-members idm_people_self_mail_write >/dev/null
    for g in "${delegated[@]}"; do
      cli group add-members "$g" tenant-admins >/dev/null
    done
    cli group add-members idm_admins platform-admins >/dev/null
    if [ -n "$cas" ]; then
      cli group account-policy webauthn-attestation-ca-list platform-admins "$cas" >/dev/null
    fi
    # The client says when it made no link, but exits 0 all the same.
    link=$(cli person credential create-reset-token "$login" --ttl 3600)
    printf '%s\n' "$link"
    if [[ $link != *"This link: $origin/ui/reset?token="* ]]; then
      fail "$t: Kanidm made no link for $login."
    fi
    sign_out "$t" "$origin"
    ;;
  *)
    usage
    ;;
esac
[ -z "$failed" ]
