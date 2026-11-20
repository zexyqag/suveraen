# Holds every vendored tree in the repository to its record. Then vendors a chart and a directory of manifests from a
# stand-in git upstream, docs, tests and dot entries left out and its licence added, and checks the result, a key no
# record is signed by gone; refuses a tree outside a piece's vendor directory, and a bump that changes a tree at the
# same version; summary names a key that comes; and verify refuses a tree changed with its record's hash to match, a
# commit no tag names pinned by hand at a version of its own, and a tag upstream moved to a commit at the same version.
# From a registry on loopback it pins the images a stand-in chart names: it refuses them pinned at fewer paths than the
# chart names them by, at a path under no map of the chart's defaults, one that isn't a tag's or one whose default is no
# string, at a new path at a version the last commit has, unsigned though a signature's tag names the digest, also at a
# tag pinned before with another signer, and checked with another hash than its key signed with; it keeps a digest
# while the chart's tag stays and takes a new tag's, pins one an RSA key kept as PGP keys are signed, and one the chart
# leaves unnamed with its repository beside it, refused where the chart names a repository or the image itself, where
# its guard's key is missing, and once its guard moves until its tag is given again; add over a record keeps its
# images; verify takes a record whose key changed as changed, and refuses a digest no signature of its key names,
# saying what the tag gives now, a tag the chart doesn't name, a guard its pin doesn't give and an unsigned digest a
# signature's tag names since; and images declared no more take their key and images file with them, and can't be
# removed again.
# On those trees, with signed records beside them, check refuses each way a tree and its keys can part from their
# records: a tree edited without its record, a README, a dot file, a link, a path its record drops, a Chart.yaml of
# another version, an entry no record owns, a vendor directory outside the pieces, a record the tool doesn't write, a
# cosign signer outside the chart's own repository or one its Chart.yaml names no repository for, a chart without a
# chart it depends on, a key of another fingerprint, a key no record names, a pin edited with its hash to match, a
# template that gives a pin's digest to another image, an edited or stray images file, a record an image line took its
# tree's hash from, a moved guard and an image's missing key.
{
  pkgs,
  charts,
  kubernetes,
  release,
}:
let
  # Two images for the stand-in registry, told apart by their config alone.
  image =
    name:
    pkgs.dockerTools.buildImage {
      inherit name;
      config.Cmd = [ name ];
    };
in
pkgs.runCommand "charts-test"
  {
    nativeBuildInputs = [
      charts
      pkgs.git
      pkgs.gnupg
      pkgs.jq
      pkgs.distribution
      pkgs.regclient
      pkgs.cosign
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
    # rehash <tree>: its record's hash made to match the tree as it stands.
    rehash() { jq --arg tree "$(treehash "$1")" '.tree = $tree' "$1.json" > "$1.json.new" && mv "$1.json.new" "$1.json"; }

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

    # The upstream of a chart that names an image at two paths by its app version, and another only once given its
    # repository, at a version per tag.
    git init -q appstream
    (
      cd appstream
      git config uploadpack.allowAnySHA1InWant true
      mkdir -p app/templates
      cat > app/values.yaml << 'EOF'
    image:
      tag: ""
    sidecar:
      tag: ""
    csi:
      repository: ""
      tag: ""
    helper:
      repository: localhost:5000/test/helper
      tag: ""
    extra:
      pullPolicy: Always
    number:
      tag: 1
    enabled: true
    EOF
      cat > app/templates/pod.yaml << 'EOF'
    apiVersion: v1
    kind: Pod
    metadata:
      name: app
    spec:
      containers:
        - name: app
          image: localhost:5000/test/app:{{ .Values.image.tag | default .Chart.AppVersion }}
        - name: sidecar
          image: localhost:5000/test/app:{{ .Values.sidecar.tag | default .Chart.AppVersion }}
        {{- with .Values.csi.repository }}
        - name: csi
          image: {{ . }}:{{ $.Values.csi.tag }}
        {{- end }}
    EOF
      for release in 1.0.0:1.0.0 1.0.1:1.0.0 1.1.0:1.1.0 1.2.0:1.2.0 1.3.0:1.3.0 1.4.0:1.4.0 1.5.0:1.5.0; do
        printf 'apiVersion: v2\nname: app\nversion: %s\nappVersion: "%s"\n' "''${release%:*}" "''${release#*:}" > app/Chart.yaml
        git add -A && git commit -qm "''${release%:*}" && git tag "v''${release%:*}"
      done
    )
    git config --global url."file://$PWD/appstream".insteadOf https://example.org/owner/app
    cat > registry.yml << EOF
    version: 0.1
    storage:
      filesystem:
        rootdirectory: $PWD/registry
    http:
      addr: 127.0.0.1:5000
    EOF

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

    # The app chart's images, pinned from a registry on loopback.
    registry serve ../registry.yml > ../registry.log 2>&1 &
    regctl registry set localhost:5000 --tls disabled
    for _ in $(seq 100); do regctl repo ls localhost:5000 > /dev/null 2>&1 && break; sleep 0.1; done
    app=$vendor/app image=localhost:5000/test/app csi=localhost:5000/test/csi
    regctl image import $image:1.0.0 ${image "one"}
    regctl image import $image:other ${image "two"}
    one=$(regctl image digest $image:1.0.0)
    two=$(regctl image digest $image:other)
    charts add $app https://example.org/owner/app v1.0.0 --path app --unsigned
    # Pinned at one of the two paths the chart names it by, the image still runs by its tag at the other.
    charts image $app $image --unsigned image.tag
    if charts bump $app v1.0.0 2> ../err; then exit 1; fi
    grep -qF "$app: its chart names $image as $image:1.0.0 $image:1.0.0@$one, not as $image:1.0.0@$one alone" ../err
    # A string set where the chart's defaults hold no map could turn a template on; and only a tag takes a pin.
    charts image $app $image --unsigned image.tag sidecar.tag enabled.tag
    if charts bump $app v1.0.0 2> ../err; then exit 1; fi
    grep -qF "$app: enabled.tag: the chart's defaults hold no map with keys at enabled." ../err
    if charts image $app $image --unsigned image.repository 2> ../err; then exit 1; fi
    grep -qF "That isn't an image a record takes" ../err
    charts image $app $image --unsigned image.tag sidecar.tag number.tag
    if charts bump $app v1.0.0 2> ../err; then exit 1; fi
    grep -qF "$app: number.tag: the chart's defaults give it as something other than a string." ../err
    # An image the chart names isn't one it leaves to be chosen.
    charts image $app $image --unsigned --chosen 1.0.0 Chart.yaml appVersion image.tag sidecar.tag
    if charts bump $app v1.0.0 2> ../err; then exit 1; fi
    grep -qF "$app: its chart names $image itself, as $image:1.0.0: declare it without --chosen." ../err
    charts image $app $image --unsigned image.tag sidecar.tag
    charts bump $app v1.0.0 2> ../err
    grep -qxF "$image:1.0.0: $one" ../err
    [ "$(grep -cxF "  tag: \"1.0.0@$one\"" $app/values.yaml)" = 2 ]
    jq -e --arg one "$one" '.images == [{image: "localhost:5000/test/app", values: ["image.tag", "sidecar.tag"],
      signer: "none", tag: "1.0.0", digest: $one}]' $app.json > /dev/null
    [ "$(cat $app.images.env)" = "$(printf 'image.tag=%s\nsidecar.tag=%s' $image:1.0.0@$one $image:1.0.0@$one)" ]
    charts check
    git add -A && git commit -qm app
    # Another path is another tree, at a version Flux has installed.
    charts image $app $image --unsigned image.tag sidecar.tag extra.tag
    if charts bump $app v1.0.0 2> ../err; then exit 1; fi
    grep -q "would change at version 1.0.0" ../err
    git checkout -q -- .
    # A tag moved upstream changes nothing while the chart names the same tag; a new tag gets the digest it has.
    regctl image copy $image:other $image:1.0.0
    charts bump $app v1.0.1
    jq -e --arg one "$one" '.images[0] | .tag == "1.0.0" and .digest == $one' $app.json > /dev/null
    git add -A && git commit -qm app-1.0.1
    regctl image copy $image:other $image:1.1.0
    charts bump $app v1.1.0
    jq -e --arg two "$two" '.images[0] | .tag == "1.1.0" and .digest == $two' $app.json > /dev/null
    git add -A && git commit -qm app-1.1.0

    # An RSA key kept as a chart's PGP key is, whose signature cosign attaches as it attaches one made with a key.
    gpg --batch --passphrase "" --quick-gen-key "Images <images@example.org>" rsa2048 sign never 2> /dev/null
    rsa=$(gpg --with-colons --list-keys images@example.org | awk -F: '$1 == "fpr" { print $10; exit }')
    mkdir -p release/chart-keys
    gpg --armor --export "$rsa" > release/chart-keys/$rsa.asc
    grip=$(gpg --with-colons --with-keygrip --list-secret-keys "$rsa" | awk -F: '$1 == "grp" { print $10; exit }')
    cosign generate $image@$two > ../payload.json
    gpg-connect-agent "SIGKEY $grip" "SETHASH --hash=sha512 $(sha512sum ../payload.json | cut -d' ' -f1)" \
      "/datafile ../signature" PKSIGN /bye > /dev/null
    # The agent gives the signature as a number, which may be shorter than the key.
    length=$(head -c 32 ../signature | LC_ALL=C sed -n 's/^(7:sig-val(3:rsa(1:s\([0-9]*\):.*/\1/p')
    { head -c $((256 - length)) /dev/zero; tail -c +$((22 + ''${#length})) ../signature | head -c "$length"; } |
      base64 -w0 > ../signature.b64
    cosign attach signature --payload ../payload.json --signature ../signature.b64 $image@$two 2> /dev/null
    # Unsigned as its record says, though a signature's tag names it.
    regctl image copy $image:other $image:1.2.0
    if charts bump $app v1.2.0 2> ../err; then exit 1; fi
    grep -qF "$image@$two has the tags above, which signatures and attestations take, yet its record says unsigned." ../err
    charts image $app $image --key "$rsa" sha256 image.tag sidecar.tag
    if charts bump $app v1.2.0 2> ../err; then exit 1; fi
    grep -qF "$image@$two isn't signed by key $rsa over its sha256." ../err
    charts image $app $image --key "$rsa" sha512 image.tag sidecar.tag
    charts bump $app v1.2.0
    jq -e --arg two "$two" --arg rsa "$rsa" '.images[0] | .tag == "1.2.0" and .digest == $two
      and .signer == {cosign: {key: $rsa, hash: "sha512"}}' $app.json > /dev/null
    # No chart is signed by the key, and it stays.
    [ -f release/chart-keys/$rsa.asc ]
    git add -A && git commit -qm app-1.2.0
    [ "$(charts verify --since HEAD~1)" = "$app: from its pin" ]
    # A key that changes changes each record it signs.
    sed -i '1a Comment: again' release/chart-keys/$rsa.asc
    [ "$(charts verify --since HEAD)" = "$app: from its pin" ]
    git checkout -q -- .

    # An image the chart leaves unnamed, at the tag a line gives it while the tree gives the guard it had.
    regctl image copy $image@$one $csi:2.0.0
    regctl image copy $image:other $image:1.3.0
    charts image $app $csi --unsigned --chosen 2.0.0 Chart.yaml nothing csi.tag
    if charts bump $app v1.3.0 2> ../err; then exit 1; fi
    grep -qF "$app: its Chart.yaml gives no scalar at nothing, which $csi is chosen for." ../err
    charts image $app $csi --unsigned --chosen 2.0.0 Chart.yaml appVersion helper.tag
    if charts bump $app v1.3.0 2> ../err; then exit 1; fi
    grep -qF "$app: helper.tag: the chart's defaults name a repository beside it, so $csi isn't one the chart leaves unnamed." ../err
    charts image $app $csi --unsigned --chosen 2.0.0 Chart.yaml appVersion csi.tag
    charts bump $app v1.3.0
    grep -qxF '  repository: "localhost:5000/test/csi"' $app/values.yaml
    grep -qxF "  tag: \"2.0.0@$one\"" $app/values.yaml
    grep -qxF "csi.tag=$csi:2.0.0@$one" $app.images.env
    jq -e --arg one "$one" '.images[1] | .chosen == {file: "Chart.yaml", key: "appVersion", value: "1.3.0"}
      and .tag == "2.0.0" and .digest == $one' $app.json > /dev/null
    git add -A && git commit -qm app-1.3.0
    regctl image copy $image:other $image:1.4.0
    if charts bump $app v1.4.0 2> ../err; then exit 1; fi
    grep -qF "$app: $csi is chosen for Chart.yaml appVersion 1.3.0, which the tree now gives as 1.4.0" ../err
    grep -qxF "Give each its tag again with image ... --chosen, before the bump." ../err
    charts image $app $csi --unsigned --chosen 2.0.0 Chart.yaml appVersion csi.tag
    charts bump $app v1.4.0
    jq -e --arg one "$one" '.images[1] | .chosen.value == "1.4.0" and .digest == $one' $app.json > /dev/null
    git add -A && git commit -qm app-1.4.0
    [ "$(charts verify --since HEAD~2)" = "$app: from its pin" ]
    # Another signer at a tag pinned before takes its digest again, as that signer passes it.
    charts image $app $image --unsigned image.tag sidecar.tag
    if charts bump $app v1.4.0 2> ../err; then exit 1; fi
    grep -qF "$image@$two has the tags above, which signatures and attestations take, yet its record says unsigned." ../err
    git checkout -q -- .
    # Added again, the tree keeps its images and their pins.
    charts add $app https://example.org/owner/app v1.4.0 --path app --unsigned
    git diff --quiet -- $app $app.images.env
    [ "$(jq -S . $app.json)" = "$(git show HEAD:./$app.json | jq -S .)" ]
    git checkout -q -- .

    # Check can't tell a digest the key never signed, a tag the chart doesn't name or a guard its pin doesn't give,
    # written in with all it holds them to; verify can, and says what the tag gives now.
    sed -i "s/@$two/@$one/" $app/values.yaml $app.images.env
    jq --arg one "$one" '.images[0].digest = $one' $app.json > ../record && cp ../record $app.json
    rehash $app
    charts check
    if charts verify --since HEAD 2> ../err; then exit 1; fi
    grep -qF "$app: its record pins $image at $one, which its registry doesn't hold or its signer doesn't pass; $image:1.4.0 gives $two now, which its signer passes." ../err
    git checkout -q -- .
    sed -i "s/1.4.0@/9.9.9@/" $app/values.yaml $app.images.env
    jq '.images[0].tag = "9.9.9"' $app.json > ../record && cp ../record $app.json
    rehash $app
    charts check
    if charts verify --since HEAD 2> ../err; then exit 1; fi
    grep -qF "$app: its chart names $image by 1.4.0, not by 9.9.9 as its record says." ../err
    git checkout -q -- .
    sed -i 's/^appVersion: .*/appVersion: 9.9.9/' $app/Chart.yaml
    jq '.images[1].chosen.value = "9.9.9"' $app.json > ../record && cp ../record $app.json
    rehash $app
    charts check
    if charts verify --since HEAD 2> ../err; then exit 1; fi
    grep -qF "$app: $csi is chosen for Chart.yaml appVersion 9.9.9, which its pin gives as 1.4.0." ../err
    git checkout -q -- .
    # An unsigned pin that a signature's tag names since.
    regctl image copy $image:other $csi:sha256-''${one#sha256:}.sig
    if charts verify --since HEAD~1 2> ../err; then exit 1; fi
    grep -qF "$app: its record pins $csi at $one, which its registry doesn't hold or its signer doesn't pass; $csi:2.0.0 gives $one now, which its signer doesn't pass either." ../err
    cd ..

    # Signed records beside them, of OCI charts, which check holds offline to their trees and keys.
    gpg --batch --passphrase "" --quick-gen-key "Signer <signer@example.org>" ed25519 sign never 2> /dev/null
    gpg --batch --passphrase "" --quick-gen-key "Other <other@example.org>" ed25519 sign never 2> /dev/null
    fingerprint() { gpg --with-colons --list-keys "$1" > colons && awk -F: '$1 == "fpr" { print $10; exit }' colons; }
    signer=$(fingerprint signer@example.org)
    other=$(fingerprint other@example.org)
    mkdir -p good/release/chart-keys
    cp -r repo/kubernetes good/
    cp repo/release/chart-keys/$rsa.asc good/release/chart-keys/
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
    record cosigned '{"cosign": {"workflow": "https://example.org/owner/demo/.github/workflows/release.yaml",
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
      "jq '.signer.cosign.workflow = \"https://example.org/owner/other/.github/workflows/release.yaml\"' cosigned.json > x && mv x cosigned.json"
    refused "cosigned.json isn't a record this tool writes" \
      "jq '.signer.cosign.workflow += \"@refs/heads/main\"' cosigned.json > x && mv x cosigned.json"
    refused "isn't in a repository its Chart.yaml gives as its source" \
      "sed -i 's,https://example.org/owner/demo,https://example.org/owner,' cosigned/Chart.yaml"
    refused "chart: depends on sub, but its charts/ holds nothing" \
      "printf 'dependencies:\\n  - name: sub\\n    version: 1.0.0\\n    repository: https://example.org/charts\\n' >> chart/Chart.yaml"
    refused "doesn't hold exactly one key, with fingerprint $signer" \
      "cp ../../../../../other.asc ../../../../release/chart-keys/$signer.asc"
    refused "$other.asc: no record is signed by it" "cp ../../../../../other.asc ../../../../release/chart-keys/$other.asc"
    refused "app: its values don't give image.tag as 1.4.0@$two" "sed -i 's/@$two/@$one/' app/values.yaml && rehash app"
    refused "app.images.env: not the images file its record gives" "sed -i 's/@$two/@$one/' app.images.env"
    refused "app: its chart names localhost:5000/test/other:1.4.0@$two, by a digest its record pins for $image alone" \
      "sed -i 's,test/app:{{ .Values.sidecar,test/other:{{ .Values.sidecar,' app/templates/pod.yaml && rehash app"
    refused "chart.images.env: in a vendor directory, but not the images file of a record that pins images" \
      "touch chart.images.env"
    refused "app: its record changed since its tree was written: bump it" "jq 'del(.tree)' app.json > x && mv x app.json"
    refused "app: $csi is chosen for Chart.yaml appVersion 1.4.0, which the tree gives as 9.9.9" \
      "sed -i 's/^appVersion: .*/appVersion: 9.9.9/' app/Chart.yaml && rehash app"
    refused "app.json: release/chart-keys/$rsa.asc doesn't hold exactly one key, with fingerprint $rsa." \
      "rm ../../../../release/chart-keys/$rsa.asc"

    # Declared no more, the images run by the chart's own tags again, and their key and images file go.
    cd repo
    charts image $app $csi --remove
    if charts image $app $csi --remove 2> ../err; then exit 1; fi
    grep -qF "$app.json declares no image $csi." ../err
    charts image $app $image --remove
    jq -e 'has("images") | not' $app.json > /dev/null
    [ ! -e release/chart-keys/$rsa.asc ]
    charts bump $app v1.5.0
    [ ! -e $app.images.env ]
    charts check
    touch $out
  ''
