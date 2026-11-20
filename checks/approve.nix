# Runs the release command against a scratch repository: the first release, refusals for a wrong key, a forged
# or rewound main, a tag posing as main and an unsafe key change, terminal control codes stripped from the review,
# a key change done in two releases, the canary signed in only when confirmed, a file that makes a Kanidm entry
# refused once its text is other than main first held under its ID or for its entry, in any layout and from any
# directory of the clone, while added, moved, deleted and restored ones pass, the vendored charts a release changes
# with their versions, signers and sources, a moved one where it went and where it was, a tree or images file changed
# without its record flagged, the images their records pin that change with their tags, signers, values and guards, a
# note on when each part of a release that changes both nixos/ and kubernetes/ applies, and refusals while checks fail
# or can't be read.
{ pkgs, approve }:
pkgs.runCommand "approve-test"
  {
    nativeBuildInputs = [
      approve
      pkgs.git
      pkgs.openssh
      pkgs.python3
      pkgs.curl
    ];
  }
  ''
    export HOME=$PWD GIT_CONFIG_GLOBAL=$PWD/gitconfig
    git config --global user.name test
    git config --global user.email test@example.org
    git config --global init.defaultBranch main
    for key in owner new attacker; do ssh-keygen -q -t ed25519 -N "" -C $key -f $key; done
    keys=$PWD

    git init -q --bare remote.git
    git clone -q remote.git work
    cd work
    echo '{"nodes":{"root":{"inputs":{"nixpkgs":"nixpkgs"}},"nixpkgs":{"locked":{"rev":"0123abc","lastModified":1791662279}}},"root":"root","version":7}' > flake.lock
    git add . && git commit -qm start && git push -q origin main main:staging
    git config user.signingkey $keys/owner

    refused() {
      if echo release | approve "$@" > ../out 2>&1; then
        cat ../out
        echo "approve should have refused"
        exit 1
      fi
    }
    released() {
      git fetch -q origin
      [ "$(git rev-parse refs/remotes/origin/main^{tree})" = "$(git rev-parse refs/remotes/origin/staging^{tree})" ]
    }
    stage() {
      git checkout -q staging 2>/dev/null || git checkout -q -b staging origin/staging
      git pull -q origin staging
      eval "$1"
      git add -A && git commit -qm "$2" && git push -q origin staging
    }
    signers() { mkdir -p release && : > release/signers && for key in "$@"; do cut -d' ' -f1,2 $keys/$key.pub >> release/signers; done; }

    # Nothing to trust yet, and the first release must be asked for explicitly.
    stage "echo one > one" one
    refused --first-release
    stage "signers owner" signers
    refused
    echo release | approve --first-release
    released
    echo release | approve | grep -q "Nothing new"

    # A release signed with a key that isn't a signer.
    stage "echo two > two" two
    git config user.signingkey $keys/attacker
    refused
    ! released || exit 1
    git config user.signingkey $keys/owner

    # A main forged by someone who can push: their own key in its signers, a release-shaped commit signed with it.
    good=$(git rev-parse refs/remotes/origin/main)
    git checkout -q -B forged origin/staging
    signers owner attacker && echo evil > evil && git add -A && git commit -qm evil
    forged=$(git -c gpg.format=ssh -c user.signingkey=$keys/attacker commit-tree -S HEAD^{tree} -p "$good" -p HEAD -m Release)
    git push -q origin "$forged:refs/heads/main"
    refused
    grep -q "isn't a release signed by a signer" ../out
    git push -q -f origin "$good:refs/heads/main"

    # A tag named like the remote branch, pointing at the forged commit.
    git tag origin/main "$forged" && git push -q origin refs/tags/origin/main
    echo release | approve
    released
    [ "$(git rev-parse refs/remotes/origin/main^1)" = "$good" ]

    # Main rewound to before the first release, posing as a fresh repository.
    latest=$(git rev-parse refs/remotes/origin/main)
    git push -q -f origin "$(git rev-list --max-parents=0 HEAD | head -n1):refs/heads/main"
    refused
    refused --first-release
    git push -q -f origin "$latest:refs/heads/main"

    # Control codes in a commit subject never reach the terminal.
    stage "echo three > three" "$(printf 'three \033[8m hidden')"
    echo no | approve > ../out 2>&1 || true
    grep -q three ../out
    ! grep -q "$(printf '\033')" ../out || exit 1

    # Replacing the only key in one release is refused; adding the new key first, then removing the old one, works.
    stage "signers new" "replace owner"
    refused
    grep -q "isn't in the new" ../out
    stage "signers owner new" "add new"
    echo release | approve
    released
    stage "signers new" "remove owner"
    git config user.signingkey $keys/new
    echo release | approve
    released

    # The canary is signed into a release only when confirmed, and never changes what gets deployed.
    stage "echo five > five" five
    printf 'release\ntrue\n' | approve
    released
    git log -1 --format=%B refs/remotes/origin/main > ../message
    grep -q "^Canary, " ../message
    grep -q "pins nixpkgs 0123abc of 2026-" ../message
    stage "echo six > six" six
    echo release | approve
    released
    ! git log -1 --format=%B refs/remotes/origin/main | grep -q Canary || exit 1

    # A file that makes a Kanidm entry keeps the text main first held under its ID, in whatever layout; a release adds,
    # moves, deletes and restores such files instead.
    cat > ../sso.yaml <<'EOF'
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: sso-hello
    data:
      10-hello-oidc.json: |
        {"id":"''${HELLO_OIDC_CREATE_ID}","assertions":[{"state":"present","id":"''${HELLO_OIDC_ID}","class":["account","oauth2_resource_server","oauth2_resource_server_basic"],"name":"hello-oidc","displayname":"hello-oidc","oauth2_rs_origin_landing":"https://pending.invalid/"}]}
      10-hello-users.json: |
        {"id":"''${HELLO_USERS_CREATE_ID}","assertions":[{"state":"present","id":"''${HELLO_USERS_ID}","class":["group"],"name":"hello-users"}]}
      50-hello.json: |
        {
          "id": "''${HELLO_SSO_ID}",
          "assertions": [{ "state": "present", "id": "''${HELLO_USERS_ID}", "entry_managed_by": "tenant-admins" }]
        }
    EOF
    sso=kubernetes/apps/hello/sso/configmap.yaml
    # ../sso.yaml with hello-oidc's file for a client of the kind given, as a double-quoted scalar.
    quoted() {
      python3 -c '
    import json, sys
    lines = open(sys.argv[1]).read().split("\n")
    i = lines.index("  10-hello-oidc.json: |")
    text = lines[i + 1].strip().replace("_basic", "_" + sys.argv[2]) + "\n"
    print("\n".join(lines[:i] + ["  10-hello-oidc.json: " + json.dumps(text)] + lines[i + 2:]), end="")' ../sso.yaml "$1"
    }
    stage "mkdir -p kubernetes/apps/hello/sso && cp ../sso.yaml $sso" "hello makes its entries"
    echo release | approve
    released
    # From a directory of the clone, its paths are still the repository's.
    stage "sed 's/oauth2_resource_server_basic/oauth2_resource_server_public/' ../sso.yaml > $sso" "hello-oidc is public"
    if (cd kubernetes/apps && echo release | approve) > ../out 2>&1; then
      cat ../out
      echo "approve should have refused"
      exit 1
    fi
    grep -qx "  $sso: 10-hello-oidc.json" ../out
    ! grep -q 10-hello-users ../out || exit 1
    grep -q "refuses such a file at every start of every tenant that applied the old one" ../out
    stage "quoted public > $sso" "hello-oidc is public, quoted"
    refused
    grep -qx "  $sso: 10-hello-oidc.json" ../out
    stage "quoted basic > $sso" "hello-oidc quoted"
    echo release | approve
    released
    client=kubernetes/apps/hello/sso/client.yaml
    stage "{ sed -n 1,5p ../sso.yaml | sed s/sso-hello/hello-client/; grep -A1 10-hello-oidc.json ../sso.yaml; } > $client
      sed '/10-hello-oidc.json/,+1d' ../sso.yaml > $sso" "hello-oidc in a ConfigMap of its own"
    echo release | approve
    released
    stage "sed '/10-hello-oidc.json/,+1d; /10-hello-users.json/,+1d' ../sso.yaml > $sso" "hello-users goes"
    echo release | approve
    released
    stage "sed '/10-hello-oidc.json/,+1d; s/\"class\":\[\"group\"\],\"name\":\"hello-users\"/\
    \"class\":[\"account_policy\",\"group\"],\"name\":\"hello-users\",\"credential_type_minimum\":\"passkey\"/' \
      ../sso.yaml > $sso" "hello-users is back as an account policy"
    refused
    grep -qx "  $sso: 10-hello-users.json" ../out
    stage "sed '/10-hello-oidc.json/,+1d; s/HELLO_USERS_CREATE_ID/HELLO_GROUP_CREATE_ID/' ../sso.yaml > $sso" \
      "hello-users is back, made by another file"
    refused
    grep -qx "  $sso: 10-hello-users.json" ../out
    stage "sed '/10-hello-oidc.json/,+1d' ../sso.yaml > $sso" "hello-users is back"
    echo release | approve
    released

    # Each vendored chart that changes, by its record: its versions or tag, its signer and whether that or its source
    # changes, where one that moved went and where it was, and a tree that changes while its record doesn't.
    vendor=kubernetes/platform/demo/vendor
    # record <name> version|tag:<value> <values.yaml> <PGP key or none> [<source>] [<images>]
    record() {
      mkdir -p $vendor/$1 && echo "$3" > $vendor/$1/values.yaml
      if [ "$4" = none ]; then signer='"none"'; else signer="{\"pgp\": \"$4\"}"; fi
      echo "{\"source\": \"''${5:-oci://registry.example.org/demo/$1}\", \"''${2%%:*}\": \"''${2#*:}\"," \
        "\"signer\": $signer''${6:+, \"images\": [$6]}}" > $vendor/$1.json
    }
    stage "record chart version:1.0.0 one none && record crds tag:v1.0.0 one none" "charts"
    echo release | approve > ../out
    released
    grep -qx "  $vendor/chart: new at 1.0.0, unsigned" ../out
    grep -qx "  $vendor/crds: new at v1.0.0, unsigned" ../out
    other=kubernetes/platform/other/vendor
    stage "mkdir -p $other && git mv $vendor/crds $vendor/crds.json $other/" "crds moved"
    echo release | approve > ../out
    released
    grep -qx "  $vendor/crds: removed" ../out
    grep -qx "  $other/crds: new at v1.0.0, unsigned" ../out
    stage "git mv $other/crds $other/crds.json $vendor/" "crds back"
    echo release | approve
    released
    stage "record chart version:1.1.0 two 0123ABCD && rm -r $vendor/crds $vendor/crds.json" "chart signed, crds gone"
    echo release | approve > ../out
    released
    grep -qx "  $vendor/chart: 1.0.0 to 1.1.0, PGP key 0123ABCD, signer changes" ../out
    grep -qx "  $vendor/crds: removed" ../out
    stage "record chart version:1.1.0 two 0123ABCD oci://elsewhere.example.org/chart" "chart elsewhere"
    echo release | approve > ../out
    released
    grep -qx "  $vendor/chart: 1.1.0, PGP key 0123ABCD, source changes from oci://registry.example.org/demo/chart" ../out
    stage "echo three > $vendor/chart/values.yaml" "chart by hand"
    echo release | approve > ../out
    released
    grep -qx "  $vendor/chart: 1.1.0, PGP key 0123ABCD, tree or images changed, record didn't" ../out
    ! grep -q "nixos/ and kubernetes/" ../out || exit 1
    # A release that changes both says when each applies.
    stage "mkdir -p nixos && echo '{ }' > nixos/default.nix && echo four > $vendor/chart/values.yaml" "both"
    echo release | approve > ../out
    released
    grep -q "^This changes both nixos/ and kubernetes/: the cluster applies kubernetes/ within minutes" ../out

    # Below its record, each image a record pins that changes: new with its values, at another tag or digest, with
    # another signer or values, chosen for another guard, from the one it had, or no longer, or gone, by its signer as
    # the tool checks it; and none where only the images file changes, which is flagged, or where the record goes.
    # image <name> <values paths> <signer> <tag> <digest's number> [<file> <key> <value>]
    image() {
      chosen=
      [ -z "''${6:-}" ] || chosen=", \"chosen\": {\"file\": \"$6\", \"key\": \"$7\", \"value\": \"$8\"}"
      echo "{\"image\": \"registry.example.org/demo/$1\", \"values\": [\"''${2// /\", \"}\"], \"signer\": $3," \
        "\"tag\": \"$4\", \"digest\": \"$(printf 'sha256:%064d' "$5")\"$chosen}"
    }
    app() { record app "version:$1" "$1" none "" "$2" && echo "$2" > $vendor/app.images.env; }
    pinned() { grep -qxF "    registry.example.org/demo/$1" ../out; }
    run=https://github.com/example/app/.github/workflows/release.yml
    issuer=https://token.actions.githubusercontent.com
    workflow="{\"cosign\": {\"workflow\": \"$run\", \"ref\": \"refs/tags/v\", \"issuer\": \"$issuer\"}}"
    identity='{"cosign": {"identity": "csi@example.org", "issuer": "https://accounts.example.org"}}'
    keyed='{"cosign": {"key": "0123456789ABCDEF0123456789ABCDEF01234567", "hash": "sha512"}}'
    csi="cosign csi@example.org, issued by https://accounts.example.org"
    sidecar="cosign key 0123456789ABCDEF0123456789ABCDEF01234567 (sha512)"
    guard="chosen for charts/csi/Chart.yaml appVersion"
    pins="$(image app image.tag "$workflow" 1.0.0 1)"
    pins+=",$(image csi csi.tag "$identity" v3.0.0 2 charts/csi/Chart.yaml appVersion 1.0.0)"
    pins+=",$(image sidecar sidecar.tag "$keyed" 1.0.0 3)"
    stage 'app 1.0.0 "$pins"' "app pins its images"
    echo release | approve > ../out
    released
    grep -qx "  $vendor/app: new at 1.0.0, unsigned" ../out
    pinned "app: new at 1.0.0, cosign $run@refs/tags/v1.0.0, issued by $issuer, values image.tag"
    pinned "csi: new at v3.0.0, $csi, values csi.tag, $guard 1.0.0"
    pinned "sidecar: new at 1.0.0, $sidecar, values sidecar.tag"
    pins="$(image app image.tag "$workflow" 1.1.0 4)"
    pins+=",$(image csi csi.tag "$identity" v3.1.0 5 charts/csi/Chart.yaml appVersion 1.1.0)"
    pins+=",$(image sidecar sidecar.tag "$keyed" 1.0.0 6)"
    stage 'app 1.1.0 "$pins"' "app 1.1.0"
    echo release | approve > ../out
    released
    grep -qx "  $vendor/app: 1.0.0 to 1.1.0, unsigned" ../out
    pinned "app: 1.0.0 to 1.1.0, cosign $run@refs/tags/v1.1.0, issued by $issuer"
    pinned "csi: v3.0.0 to v3.1.0, $csi, $guard 1.1.0, from 1.0.0"
    pinned "sidecar: 1.0.0, $sidecar, another digest"
    pins="$(image app image.tag "$workflow" 1.1.0 4)"
    pins+=",$(image csi csi.tag "$identity" v3.1.0 5 charts/csi/Chart.yaml version 1.1.0)"
    pins+=",$(image sidecar sidecar.tag "$keyed" 1.0.0 6)"
    stage 'app 1.1.0 "$pins"' "csi chosen for another key"
    echo release | approve > ../out
    released
    pinned "csi: v3.1.0, $csi, chosen for charts/csi/Chart.yaml version 1.1.0, from charts/csi/Chart.yaml appVersion 1.1.0"
    [ "$(grep -c "^    registry.example.org/" ../out)" = 1 ]
    pins="$(image app image.tag '"none"' 1.1.0 4),$(image csi csi.tag "$identity" v3.1.0 5)"
    pins+=",$(image sidecar "sidecar.tag extra.tag" "$keyed" 1.0.0 6)"
    stage 'app 1.2.0 "$pins"' "app's images declared again"
    echo release | approve > ../out
    released
    pinned "app: 1.1.0, unsigned, signer changes from cosign $run@refs/tags/v1.1.0, issued by $issuer"
    pinned "csi: v3.1.0, $csi, no longer chosen"
    pinned "sidecar: 1.0.0, $sidecar, values change from sidecar.tag to sidecar.tag extra.tag"
    stage "echo edited > $vendor/app.images.env" "app's images by hand"
    echo release | approve > ../out
    released
    grep -qx "  $vendor/app: 1.2.0, unsigned, tree or images changed, record didn't" ../out
    ! grep -q "^    registry.example.org/" ../out || exit 1
    pins="$(image app image.tag '"none"' 1.1.0 4),$(image sidecar "sidecar.tag extra.tag" "$keyed" 1.0.0 6)"
    stage 'app 1.2.0 "$pins"' "csi no longer pinned"
    echo release | approve > ../out
    released
    grep -qx "  $vendor/app: 1.2.0, unsigned" ../out
    pinned "csi: no longer pinned"
    [ "$(grep -c "^    registry.example.org/" ../out)" = 1 ]
    stage "rm -r $vendor/app $vendor/app.json $vendor/app.images.env" "app gone"
    echo release | approve > ../out
    released
    grep -qx "  $vendor/app: removed" ../out
    ! grep -q "^    registry.example.org/" ../out || exit 1

    git config user.signingkey $keys/owner
    stage "echo four > four" four
    refused

    # On GitHub, a release needs every check on the candidate to have passed. A local server stands in for its API,
    # and git reaches the scratch remote through insteadOf.
    mkdir -p ../api
    python3 -m http.server --bind 127.0.0.1 --directory ../api 8008 > /dev/null 2>&1 &
    for _ in $(seq 50); do curl -fs http://127.0.0.1:8008/ > /dev/null && break; sleep 0.2; done
    export GITHUB_API_URL=http://127.0.0.1:8008
    git config url.$keys/remote.git.insteadOf https://github.com/test/suveraen
    git remote set-url origin https://github.com/test/suveraen
    git config user.signingkey $keys/new
    runs() { mkdir -p ../api/repos/test/suveraen/commits/$(git rev-parse HEAD) && echo "$1" > ../api/repos/test/suveraen/commits/$(git rev-parse HEAD)/check-runs; }
    stage "echo seven > seven" seven
    refused
    grep -q "Couldn't read the checks" ../out
    runs '{"check_runs":[{"name":"check","conclusion":"success"},{"name":"e2e","status":"in_progress","conclusion":null}]}'
    refused
    grep -q "Not every check" ../out
    runs '{"check_runs":[{"name":"check","conclusion":"failure"}]}'
    refused
    runs '{"check_runs":[]}'
    refused
    runs '{"check_runs":[{"name":"check","conclusion":"success"},{"name":"e2e","conclusion":"skipped"}]}'
    echo release | approve
    released

    git config approve.command | grep -q "ref=main&publicKeys="
    touch $out
  ''
