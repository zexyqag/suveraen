# Runs the release command against a local repository: the first release trusts the signers it brings,
# later releases need one of them, and a release branch moved by anyone else is refused.
{ pkgs, approve }:
pkgs.runCommand "approve-test"
  {
    nativeBuildInputs = [
      approve
      pkgs.git
      pkgs.openssh
    ];
  }
  ''
    export HOME=$PWD GIT_CONFIG_GLOBAL=$PWD/gitconfig
    git config --global user.name test
    git config --global user.email test@example.org
    git config --global init.defaultBranch main
    ssh-keygen -q -t ed25519 -N "" -f release-key
    ssh-keygen -q -t ed25519 -N "" -f other-key

    git init -q --bare remote.git
    git clone -q remote.git work
    cd work
    echo '{"nodes":{}}' > flake.lock
    git add . && git commit -qm start && git push -q origin main main:staging

    expect_refusal() {
      if echo release | approve; then
        echo "approve should have refused: $1"
        exit 1
      fi
    }
    released() {
      git fetch -q origin
      [ "$(git rev-parse origin/main^{tree})" = "$(git rev-parse origin/staging^{tree})" ]
    }
    change() {
      git checkout -q staging && git pull -q
      echo "$1" > "$1" && git add . && git commit -qm "$1" && git push -q origin staging
    }

    change one
    expect_refusal "no signers on staging yet"

    mkdir release && cut -d' ' -f1,2 ../release-key.pub > release/signers
    git add . && git commit -qm signers && git push -q origin staging
    git config user.signingkey "$PWD/../release-key"
    echo release | approve
    released
    echo release | approve | grep -q "Nothing new"

    change two
    git config user.signingkey "$PWD/../other-key"
    expect_refusal "signed with a key that isn't a signer"
    if released; then
      echo "a release signed with the wrong key reached main"
      exit 1
    fi

    good=$(git rev-parse origin/main)
    git checkout -q -B tamper origin/main
    echo evil > evil && git add . && git commit -qm evil && git push -q origin tamper:main
    git config user.signingkey "$PWD/../release-key"
    expect_refusal "main moved without a signature"
    git push -q -f origin "$good:main"

    echo release | approve
    released
    touch $out
  ''
