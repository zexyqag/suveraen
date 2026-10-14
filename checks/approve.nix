# Runs the release command against a scratch repository: the first release, refusals for a wrong key, a forged
# or rewound main, a tag posing as main and an unsafe key change, terminal control codes stripped from the review,
# a key change done in two releases, the canary signed in only when confirmed, and refusals while checks fail or
# can't be read.
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
