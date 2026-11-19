# Holds every vendored tree in the repository to its record. Then vendors a chart and a directory of manifests from a
# stand-in git upstream, docs, tests and dot entries left out and its licence added, and checks the result, a key no
# record is signed by gone; refuses a tree outside a piece's vendor directory, and a bump that changes a tree at the
# same version; summary names a key that comes; and verify refuses a tree changed with its record's hash to match, a
# commit no tag names pinned by hand at a version of its own, and a tag upstream moved to a commit at the same version.
# On those trees, with signed records beside them, check refuses each way a tree and its keys can part from their
# records: a tree edited without its record, a README, a dot file, a link, a path its record drops, a Chart.yaml of
# another version, an entry no record owns, a vendor directory outside the pieces, a record the tool doesn't write, a
# cosign signer outside the chart's own repository or one its Chart.yaml names no repository for, a key of another
# fingerprint and a key no record names.
{
  pkgs,
  charts,
  kubernetes,
  release,
}:
pkgs.runCommand "charts-test"
  {
    nativeBuildInputs = [
      charts
      pkgs.git
      pkgs.gnupg
      pkgs.jq
    ];
  }
  ''
    mkdir real && cp -r ${kubernetes} real/kubernetes && cp -r ${release} real/release
    (cd real && charts check)

    export HOME=$PWD GIT_CONFIG_GLOBAL=$PWD/gitconfig GNUPGHOME=$PWD/gnupg
    git config --global user.name test
    git config --global user.email test@example.org
    git config --global init.defaultBranch main
    mkdir -m 700 gnupg
    # The record's formula, written out apart from the tool's.
    treehash() { echo "sha256:$( (cd "$1" && find . -type f -printf '%P\0' | LC_ALL=C sort -z | xargs -0 sha256sum --) | sha256sum | cut -d' ' -f1)"; }

    # The upstream, reached by its https URL.
    git init -q upstream
    (
      cd upstream
      git config uploadpack.allowAnySHA1InWant true
      mkdir -p chart/templates/tests chart/tests manifests/extra
      printf 'apiVersion: v2\nname: chart\nversion: 1.0.0\nsources:\n  - https://example.org/owner/demo\n' > chart/Chart.yaml
      echo 'replicas: 1' > chart/values.yaml
      echo 'kind: ConfigMap' > chart/templates/configmap.yaml
      echo 'kind: Pod' > chart/templates/tests/test.yaml
      echo notes > chart/templates/NOTES.txt
      echo test > chart/tests/unit.yaml
      echo readme > chart/README.md
      echo '*.tmp' > chart/.gitignore
      echo '.git' > chart/.helmignore
      echo 'resources: [crd.yaml]' > manifests/kustomization.yaml
      echo 'kind: CustomResourceDefinition' > manifests/crd.yaml
      echo 'kind: CustomResourceDefinition' > manifests/extra/experimental.yaml
      echo licence > LICENSE
      git add -A && git commit -qm one && git tag v1.0.0
      echo 'replicas: 2' > chart/values.yaml
      git commit -qam two && git tag v1.0.1
      sed -i s/1.0.0/1.1.0/ chart/Chart.yaml
      git commit -qam three && git tag -a -m three v1.1.0
    )
    git config --global url."file://$PWD/upstream".insteadOf https://example.org/owner/demo

    git init -q repo
    cd repo
    git commit -q --allow-empty -m start
    vendor=kubernetes/platform/demo/vendor
    if charts add kubernetes/apps/demo/vendor/chart https://example.org/owner/demo v1.0.0 --path chart --unsigned 2> ../err; then
      exit 1
    fi
    grep -qF "A tree is kubernetes/platform/<piece>/vendor/<name>" ../err
    charts add $vendor/chart https://example.org/owner/demo v1.0.0 --path chart --unsigned --license LICENSE
    stale=release/chart-keys/0123456789ABCDEF0123456789ABCDEF01234567.asc
    mkdir -p release/chart-keys && echo stale > $stale
    charts add $vendor/crds https://example.org/owner/demo v1.0.0 --path manifests --unsigned --license LICENSE --drop extra
    [ ! -e $stale ]
    (cd $vendor/chart && [ "$(find . -type f | sort | tr '\n' ' ')" = "./.helmignore ./Chart.yaml ./LICENSE ./templates/configmap.yaml ./values.yaml " ])
    (cd $vendor/crds && [ "$(find . -type f | sort | tr '\n' ' ')" = "./LICENSE ./crd.yaml ./kustomization.yaml " ])
    jq -e --arg tree "$(treehash $vendor/chart)" '.version == "1.0.0" and .tag == "v1.0.0" and .tree == $tree and .license == {path: "LICENSE"}' $vendor/chart.json > /dev/null
    jq -e '.tag == "v1.0.0" and (has("version") | not) and .drop == ["extra"]' $vendor/crds.json > /dev/null
    charts check
    [ "$(charts summary)" = "charts: chart 1.0.0, crds v1.0.0" ]
    git add -A && git commit -qm vendored
    echo key > $stale
    [ "$(charts summary)" = "charts: key 0123456789ABCDEF0123456789ABCDEF01234567 added" ]
    rm $stale

    # Flux installs a chart again only once its version changes.
    if charts bump $vendor/chart v1.0.1 2> ../err; then exit 1; fi
    grep -q "would change at version 1.0.0" ../err
    charts bump $vendor/chart v1.1.0
    [ "$(charts summary)" = "charts: chart 1.0.0 to 1.1.0" ]
    git add -A && git commit -qm bump
    [ "$(charts verify --since HEAD~1)" = "$vendor/chart: from its pin" ]
    [ -z "$(charts verify --since HEAD)" ]

    echo 'replicas: 3' > $vendor/chart/values.yaml
    jq --arg tree "$(treehash $vendor/chart)" '.tree = $tree' $vendor/chart.json > ../record && cp ../record $vendor/chart.json
    charts check
    if charts verify --since HEAD 2> ../err; then exit 1; fi
    grep -q "its pin gives another tree than its record names" ../err
    git checkout -q -- .

    # pin <version>: the chart's record pinned by hand to upstream's head, at that version, with its tree from there.
    pin() {
      rm -rf $vendor/chart
      git -C ../upstream archive --prefix=chart/ HEAD:chart templates/configmap.yaml values.yaml Chart.yaml .helmignore | tar -x -C $vendor
      cp ../upstream/LICENSE $vendor/chart/
      jq --arg commit "$(git -C ../upstream rev-parse HEAD)" --arg tree "$(treehash $vendor/chart)" --arg version "$1" \
        '.commit = $commit | .tree = $tree | .version = $version' $vendor/chart.json > ../record && cp ../record $vendor/chart.json
    }
    # A commit upstream serves, as it does a pull request's, though no tag names it.
    git -C ../upstream checkout -q v1.1.0
    sed -i s/1.1.0/1.2.0/ ../upstream/chart/Chart.yaml
    git -C ../upstream commit -qam untagged
    pin 1.2.0
    charts check
    if charts verify --since HEAD 2> ../err; then exit 1; fi
    grep -q "tag v1.1.0 names another commit than" ../err
    git checkout -q -- .
    # Upstream's tag moved to a commit of the same version.
    git -C ../upstream checkout -q v1.1.0
    echo 'replicas: 4' > ../upstream/chart/values.yaml
    git -C ../upstream commit -qam four
    git -C ../upstream tag -f -a -m four v1.1.0
    pin 1.1.0
    if charts verify --since HEAD 2> ../err; then exit 1; fi
    grep -q "changed since HEAD at version 1.1.0" ../err
    git checkout -q -- .
    cd ..

    # Signed records beside them, of OCI charts, which check holds offline to their trees and keys.
    gpg --batch --passphrase "" --quick-gen-key "Signer <signer@example.org>" ed25519 sign never 2> /dev/null
    gpg --batch --passphrase "" --quick-gen-key "Other <other@example.org>" ed25519 sign never 2> /dev/null
    fingerprint() { gpg --with-colons --list-keys "$1" > colons && awk -F: '$1 == "fpr" { print $10; exit }' colons; }
    signer=$(fingerprint signer@example.org)
    other=$(fingerprint other@example.org)
    mkdir -p good/release/chart-keys
    cp -r repo/kubernetes good/
    gpg --armor --export "$signer" > good/release/chart-keys/$signer.asc
    gpg --armor --export "$other" > other.asc
    for name in signed cosigned; do
      cp -r good/$vendor/chart good/$vendor/$name
    done
    record() {
      jq -n --arg tree "$(treehash good/$vendor/chart)" --argjson signer "$2" '{source: "oci://registry.example.org/demo/chart",
        version: "1.1.0", digest: "sha256:\("0" * 64)", signer: $signer, tree: $tree}' > good/$vendor/$1.json
    }
    record signed "{\"pgp\": \"$signer\"}"
    record cosigned '{"cosign": {"identity": "https://example.org/owner/demo/.github/workflows/release.yaml@refs/heads/main",
      "issuer": "https://token.actions.githubusercontent.com"}}'
    (cd good && charts check)

    # refused <why> <change>: a copy of the good trees, so changed, is refused for that reason.
    refused() {
      rm -rf case && cp -r good case
      (cd case/$vendor && eval "$2")
      if (cd case && charts check) 2> err; then
        echo "check should have refused: $2"
        exit 1
      fi
      grep -qF "$1" err || { cat err; exit 1; }
    }
    refused "chart: its files aren't the ones its record names" "echo 'replicas: 5' > chart/values.yaml"
    refused "holds README.md, which the release leaves out" "echo readme > chart/README.md"
    refused "holds .gitattributes, which the release leaves out" "echo '* -text' > chart/.gitattributes"
    refused "holds templates/link.yaml, where only files" "ln -s ../values.yaml chart/templates/link.yaml"
    refused "holds extra, which its record drops" "mkdir crds/extra && touch crds/extra/x.yaml"
    refused "its Chart.yaml has version 1.1.0, its record 1.1.1" "jq '.version = \"1.1.1\"' signed.json > x && mv x signed.json"
    refused "stray.yaml: in a vendor directory, but not a tree beside its record" "touch stray.yaml"
    refused "stray: in a vendor directory, but not a tree beside its record" "mkdir stray"
    refused "kubernetes/apps/demo/vendor: a vendor directory, but not kubernetes/platform/<piece>/vendor" \
      "mkdir -p ../../../apps/demo/vendor/chart"
    refused "signed.json isn't a record this tool writes" "jq '.signer = \"unsigned\"' signed.json > x && mv x signed.json"
    refused "isn't in a repository its Chart.yaml gives as its source" \
      "jq '.signer.cosign.identity = \"https://example.org/owner/other/.github/workflows/release.yaml@refs/heads/main\"' cosigned.json > x && mv x cosigned.json"
    refused "isn't in a repository its Chart.yaml gives as its source" \
      "sed -i 's,https://example.org/owner/demo,https://example.org/owner,' cosigned/Chart.yaml"
    refused "doesn't hold exactly one key, with fingerprint $signer" \
      "cp ../../../../../other.asc ../../../../release/chart-keys/$signer.asc"
    refused "$other.asc: no record is signed by it" "cp ../../../../../other.asc ../../../../release/chart-keys/$other.asc"
    touch $out
  ''
