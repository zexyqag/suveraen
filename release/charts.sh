# charts add <tree> <source> <version> (--pgp <fingerprint> <key-url> | --cosign <workflow> <issuer> | --unsigned)
#        [--path <dir>] [--license <url-or-path>] [--drop <path>]...
# charts bump <tree> <version>
# charts image <tree> <image> (--key <fingerprint> <hash> | --workflow <workflow> <ref> <issuer>
#        | --identity <identity> <issuer> | --unsigned) [--chosen <tag> <file> <key>] <values path>...
# charts image <tree> <image> --remove
# charts check
# charts verify --since <rev>
# charts summary
# Run at the top of the repository. Vendors a chart, or a directory of manifests, into <tree>,
# kubernetes/platform/<piece>/vendor/<name>, from its upstream pin, with its record in <tree>.json: an OCI chart by its
# manifest's digest, its signature checked, or a directory, given by --path, of the commit a git tag names, the tag
# being <version>. Docs, tests, pictures and dot entries are left out, and a licence the package lacks is added from
# --license. A PGP key goes in release/chart-keys, where no key stays that no record names. check holds every tree to
# its record offline; verify also fetches every record that, or whose key, changed since <rev> again from its pin and
# checks it gives the same tree. summary names what the records and keys change since HEAD.
# image declares in a tree's record an image its chart runs, where its tag goes and who signs it, and drops a key no
# record names any more. The next add or bump pins each one in the chart's values.yaml and in <tree>.images.env, at the
# digest of the tag the chart names it by, or that --chosen gives while the tree's <file> gives <key> as it did then,
# checked against its signer: only a workflow's signature names a tag, the git tag its run started from, while a key's
# or an identity's names the digest alone.
chart_type=application/vnd.cncf.helm.chart.content.v1.tar+gzip
prov_type=application/vnd.cncf.helm.chart.provenance.v1.prov
keys_dir=release/chart-keys
piece='kubernetes/platform/[a-z0-9][a-z0-9-]*/vendor'
named="^$piece/[a-z0-9][a-z0-9.-]*\$"

usage() {
  grep '^# charts \|^#        ' "${BASH_SOURCE[0]}" | cut -c3- >&2
  exit 2
}
die() {
  echo "$*" >&2
  exit 1
}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GNUPGHOME=$tmp/gnupg HELM_CACHE_HOME=$tmp/helm HELM_CONFIG_HOME=$tmp/helm HELM_DATA_HOME=$tmp/helm
mkdir -m 700 "$GNUPGHOME"
sum() { sha256sum "$1" | cut -d' ' -f1; }
# A path that stays below where it's joined to.
relative() { [[ -n $1 && $1 != /* && /$1/ != */../* && /$1/ != */./* && $1 != *//* ]]; }
treehash() {
  echo "sha256:$( (cd "$1" && find . -type f -printf '%P\0' | LC_ALL=C sort -z | xargs -0 -r sha256sum --) | sum -)"
}

valid='def rel: type == "string" and (split("/") | all(. != "" and . != "." and . != ".."));
  def hex(n): type == "string" and test("^[0-9a-f]{\(n)}\\z");
  def version: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._+-]*\\z");
  def sha256: type == "string" and startswith("sha256:") and (.[7:] | hex(64));
  def workflow: type == "string" and test("^https://[^/@\\s]+/[^/@\\s]+/[^/@\\s]+/\\.github/workflows/[^/@\\s]+\\z");
  def https: type == "string" and test("^https://[!-~]+\\z");
  def image: (keys - ["image", "values", "signer", "chosen", "tag", "digest"] == [])
    and (.image | type == "string" and test("^[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]+)?(/[a-z0-9._-]+)+\\z"))
    and (.values | type == "array" and length > 0 and all(.[]; type == "string" and test("^([A-Za-z0-9_-]+\\.)+tag\\z")))
    and (.signer == "none" or (.signer | type == "object" and keys == ["cosign"] and (.cosign | type == "object"
      and (keys == ["hash", "key"] and (.key | type == "string" and test("^[0-9A-F]{40}\\z"))
        and (.hash | IN("sha256", "sha384", "sha512"))
      or keys == ["issuer", "ref", "workflow"] and (.workflow | workflow)
        and (.ref | type == "string" and test("^refs/tags/[A-Za-z0-9._-]*\\z")) and (.issuer | https)
      or keys == ["identity", "issuer"] and (.identity | type == "string" and test("^[!-~]+\\z")) and (.issuer | https)))))
    and (.chosen | . == null or type == "object" and keys - ["value"] == ["file", "key"] and (.file | rel)
      and (.key | type == "string" and test("^[A-Za-z0-9_-]+(\\.[A-Za-z0-9_-]+)*\\z"))
      and (.value | . == null or type == "string"))
    and (.tag | . == null or version) and (.digest | . == null or sha256)
    and if .chosen then .tag != null else (.tag == null) == (.digest == null) end;
  (keys - ["source", "version", "tag", "digest", "commit", "path", "signer", "license", "drop", "images", "tree"] == [])
  and (.images | . == null or type == "array" and length > 0 and all(.[]; type == "object" and image)
    and (map(.image) | . == unique) and ([.[].values[]] | length == (unique | length)))
  and (if .source | type == "string" and test("^oci://[a-z0-9.:-]+/[a-z0-9._/-]+\\z") then
      (.version | version) and .tag == null and (.digest | sha256)
      and .commit == null and .path == null
      and (.license | . == null or keys == ["sha256", "url"])
    else
      (.source | type == "string" and startswith("https://")) and (.tag | version) and (.version | . == null or version)
      and (.commit | hex(40)) and (.path | rel) and .digest == null and .signer == "none"
      and (.license | . == null or keys == ["path"] and (.path | rel) or keys == ["sha256", "url"])
    end)
  and (.signer == "none" or (.signer | objects | keys == ["pgp"] and (.pgp | test("^[0-9A-F]{40}\\z"))
    or keys == ["cosign"] and (.cosign | objects | keys == ["issuer", "workflow"] and (.issuer | https)
      and (.workflow | workflow))))
  and (.license | . == null or has("path")
    or (.url | type == "string" and startswith("https://")) and (.sha256 | hex(64)))
  and (.drop | . == null or type == "array" and length > 0 and all(.[]; rel))
  and (.tree | . == null or sha256)'

# What a tree may never hold: anything but files and directories, and names a line or git might not carry as they are.
odd() { (cd "$1" && LC_ALL=C find . -mindepth 1 \( ! -type f ! -type d -o -name '*[!A-Za-z0-9._+@=,~-]*' \) -printf '%P\n'); }
# Upstream's docs, tests, pictures and dot entries, which the release leaves out. .helmignore stays: Helm reads it.
dropped() {
  (cd "$1" && find . -mindepth 1 \( -name '.*' ! -name .helmignore \
    -o -type d \( -name tests -o -name test -o -name ci \) \
    -o -path '*/templates/NOTES.txt' \
    -o -type f ! -name 'LICENSE*' ! -name 'NOTICE*' ! -name 'COPYING*' \( -name 'README*' -o -name 'CHANGELOG*' \
    -o -name '*.md' -o -name '*.md.gotmpl' -o -name '*.rst' -o -name 'artifacthub-*.yaml' -o -name 'artifacthub-*.yml' \
    -o -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.gif' -o -iname '*.svg' -o -iname '*.ico' \
    -o -iname '*.webp' \) \) -prune -printf '%P\n')
}

# The primary key's fingerprint, if the file holds exactly one key.
fingerprint() {
  gpg --batch --show-keys --with-colons "$1" 2>/dev/null |
    awk -F: '$1 == "pub" { n++; next } $1 == "fpr" && !seen++ { fpr = $10 } END { if (n == 1) print fpr }'
}

# A chart's dependencies, as Helm reads them, from its lock where it has one, against what its charts/ holds, at every
# depth: source-controller would fetch what charts/ lacks from wherever the chart says, with nothing to pin it by.
unvendored() {
  local file want held sub
  want=$(for file in Chart.lock requirements.lock Chart.yaml requirements.yaml; do
    if [ -f "$1/$file" ]; then
      yq '.dependencies[]?.name' "$1/$file"
      [[ $file != *.lock ]] || break
    fi
  done | LC_ALL=C sort | paste -sd' ')
  held=$(for sub in "$1"/charts/*; do
    if [ -f "$sub/Chart.yaml" ]; then yq .name "$sub/Chart.yaml"; elif [ -e "$sub" ]; then echo "${sub##*/}"; fi
  done | LC_ALL=C sort | paste -sd' ')
  [ "$want" = "$held" ] || echo "$1: depends on ${want:-nothing}, but its charts/ holds ${held:-nothing}"
  for sub in "$1"/charts/*/; do
    [ ! -f "$sub/Chart.yaml" ] || unvendored "${sub%/}"
  done
}

# Why a tree doesn't stand as its record describes it, one line each; nothing if it does.
problems() {
  local tree=$1 record=$2 name path chart workflow sources
  while IFS= read -r path; do
    echo "$tree: holds $path, where only files and directories with plain names may be"
  done < <(odd "$tree")
  while IFS= read -r path; do
    echo "$tree: holds $path, which the release leaves out"
  done < <(dropped "$tree")
  while IFS= read -r path; do
    [ ! -e "$tree/$path" ] || echo "$tree: holds $path, which its record drops"
  done < <(jq -r '.drop // [] | .[]' "$record")
  if [ ! -f "$tree/Chart.yaml" ]; then
    jq -r --arg tree "$tree" 'if .digest then "\($tree): has no Chart.yaml, though an OCI source holds a chart"
      elif .version then "\($tree): has no Chart.yaml, though its record gives a version" else empty end' "$record"
    return 0
  fi
  name=$(jq -r 'if .path then .path else .source end | sub(".*/"; "")' "$record")
  chart=$(yq -o=json '{"name": .name, "version": .version, "sources": (.sources // [])}' "$tree/Chart.yaml") ||
    { echo "$tree: its Chart.yaml isn't YAML"; return 0; }
  jq -r --arg tree "$tree" --arg name "$name" --argjson chart "$chart" '
    (if $chart.name != $name then "\($tree): its Chart.yaml names \($chart.name), not \($name)" else empty end),
    (if $chart.version != .version then
      "\($tree): its Chart.yaml has version \($chart.version), its record \(.version // "none")" else empty end)
    ' "$record"
  unvendored "$tree"
  # A signature by any workflow would only show that someone signed: it must be one in the chart's own repository, which
  # a source names only as https://<host>/<owner>/<repository>.
  workflow=$(jq -r '.signer.cosign?.workflow // empty' "$record")
  sources=$(jq -c '[.sources[] | strings | ascii_downcase | sub("(\\.git)?/*$"; "")
    | select(test("^https://[^/]+/[^/]+/[^/]+$")) | . + "/"]' <<<"$chart")
  if [ -n "$workflow" ] && ! jq -e --arg id "${workflow,,}" 'any(.[]; . as $s | $id | startswith($s))' <<<"$sources" >/dev/null; then
    echo "$tree: its signer $workflow isn't in a repository its Chart.yaml gives as its source:" \
      "$(jq -c .sources <<<"$chart")"
  fi
}

# unpack <archive> <dir> <name>: unpacks an archive's one top directory into <dir>, after checking it holds only files
# and directories under it, and prints that directory's name.
unpack() {
  local archive=$1 into=$2 what=$3 listing entry top='' stage=$tmp/unpack
  listing=$(tar -tvzf "$archive" --quoting-style=escape)
  ! grep -qv '^[-d]' <<<"$listing" || die "$what holds more than files and directories."
  listing=$(tar -tzf "$archive" --quoting-style=escape)
  while IFS= read -r entry; do
    entry=${entry%/}
    { relative "$entry" && [[ $entry != *\\* ]] && [ "${top:=${entry%%/*}}" = "${entry%%/*}" ]; } ||
      die "$what holds $entry, outside one plain top directory."
  done <<<"$listing"
  rm -rf "$stage" && mkdir "$stage"
  tar -xzf "$archive" -C "$stage" --no-same-owner --no-same-permissions
  [ -d "$stage/$top" ] && [ ! -e "$into/$top" ] || die "$what doesn't hold a directory $top of its own."
  mkdir -p "$into"
  mv "$stage/$top" "$into/$top"
  echo "$top"
}
# Helm loads a subchart from charts/ as an archive or as a directory; the release keeps directories.
subcharts() {
  local archive sub
  for archive in "$1"/charts/*.tgz; do
    [ -f "$archive" ] || continue
    sub=$(unpack "$archive" "$1/charts" "$2, ${archive#"$1"/}")
    rm "$archive"
    subcharts "$1/charts/$sub" "$2, ${archive#"$1"/}"
  done
}

# Checks a prov's signature with the key, and that it names the archive's sha256 under the given file name, as Helm
# does. gpgv, unlike helm verify, reads any key gpg does.
provenance() {
  local key=$1 fpr=$2 prov=$3 archive=$4 file=$5 named
  gpg --batch --dearmor <"$key" >"$tmp/keyring.gpg"
  rm -f "$tmp/signed"
  gpgv --keyring "$tmp/keyring.gpg" --status-fd 3 --output "$tmp/signed" "$prov" 3>"$tmp/status" 2>"$tmp/gpgv" ||
    die "The provenance of $file isn't signed by $fpr: $(cat "$tmp/gpgv")"
  grep -q "^\[GNUPG:\] VALIDSIG .* $fpr\$" "$tmp/status" || die "The provenance of $file isn't signed by $fpr."
  named=$(awk 'files; $0 == "..." { files = 1 }' "$tmp/signed" | file=$file yq '.files[strenv(file)]')
  [ "$named" = "sha256:$(sum "$archive")" ] || die "The provenance names $named for $file, not its sha256."
}

# unsigned <repository> <digest>: that neither a signature's tag nor any referrer names the digest, so that upstream
# starting to sign is noticed.
unsigned() {
  local tags referrers
  tags=$(regctl tag ls "$1") || return
  ! grep "^sha256-${2#sha256:}" <<<"$tags" ||
    die "$1@$2 has the tags above, which signatures and attestations take, yet its record says unsigned."
  referrers=$(regctl artifact list "$1@$2" --format '{{len .Descriptors}}') || return
  [ "$referrers" = 0 ] || die "$1@$2 has $referrers referrers, yet its record says unsigned."
}

# signed <image> <digest> <signer> <tag>: checks the digest is signed by an image's signer, or by nobody. An image's
# signer isn't held to the chart's own repository, as a chart's is: a project may sign them from another repository.
signed() {
  local ref=$1@$2 signer=$3 fpr hash identity issuer
  issuer=$(jq -r '.cosign?.issuer? // empty' <<<"$signer")
  case $(jq -r 'if . == "none" then "none" else .cosign | keys | join(" ") end' <<<"$signer") in
  none) unsigned "$1" "$2" ;;
  "hash key")
    fpr=$(jq -r .cosign.key <<<"$signer") hash=$(jq -r .cosign.hash <<<"$signer")
    # The key the release keeps in PGP's form, which cosign reads as the RSA key it holds.
    { gpg --batch --quiet --import "$keys_dir/$fpr.asc" && gpg --batch --export-ssh-key "$fpr!" >"$tmp/key.ssh" &&
      ssh-keygen -e -m PKCS8 -f "$tmp/key.ssh" >"$tmp/key.pem" &&
      cosign verify --key "$tmp/key.pem" --signature-digest-algorithm "$hash" --insecure-ignore-tlog "$ref" \
        >/dev/null; } ||
      die "$ref isn't signed by key $fpr over its $hash."
    ;;
  "issuer ref workflow")
    # A workflow's certificate names the ref its run started from: the tag's own.
    identity=$(jq -r '.cosign.workflow + "@" + .cosign.ref' <<<"$signer")$4
    cosign verify --certificate-identity "$identity" --certificate-oidc-issuer "$issuer" "$ref" >/dev/null ||
      die "$ref isn't signed by $identity, issued by $issuer."
    ;;
  "identity issuer")
    identity=$(jq -r .cosign.identity <<<"$signer")
    cosign verify --certificate-identity "$identity" --certificate-oidc-issuer "$issuer" "$ref" >/dev/null ||
      die "$ref isn't signed by $identity, issued by $issuer."
    ;;
  *) die "$ref: its record's signer is none this tool checks." ;;
  esac
}

# render <chart> <file>: the chart rendered with its defaults alone.
render() {
  helm template chart "$1" >"$2" 2>"$tmp/helm.err" || die "$1 doesn't render: $(cat "$tmp/helm.err")"
}
# names <file> <image>: each way a render names an image, <image>:<tag> with @<digest> where it gives one, once each.
names() {
  { grep -oE "(^|[^A-Za-z0-9./_-])${2//./\\.}:[A-Za-z0-9_][A-Za-z0-9_.-]*(@sha256:[0-9a-f]{64})?" "$1" || true; } |
    sed -E 's/^[^a-z0-9]//' | LC_ALL=C sort -u
}
# guard <tree> <file> <key>: the scalar <file> gives at <key>, as text; nothing, and it fails, where it gives none.
guard() {
  [ -f "$1/$2" ] && yq -o=json . "$1/$2" 2>/dev/null |
    jq -er --arg key "$3" 'try getpath($key | split(".")) catch null | select(. != null) | scalars | tostring' 2>/dev/null
}
# The values a record's images pin, a path and its value on each line in one order whatever the record's: each tag's
# path gives <tag>@<digest>, and a chosen image's repository beside it the image.
pairs() {
  jq -r '.images[] | .image as $image | (.tag + "@" + .digest) as $pin | .chosen as $chosen | .values[]
    | [., $pin], if $chosen then [sub("tag$"; "repository"), $image] else empty end | @tsv' "$1" | LC_ALL=C sort
}
# The images file a record gives: each path an image's tag goes at, and the image as its pin names it.
envfile() {
  jq -r '.images[] | (.image + ":" + .tag + "@" + .digest) as $ref | .values[] | "\(.)=\($ref)"' "$1" | LC_ALL=C sort
}

# derive <tree> <dir> <record>: each image the record declares, a tab and what the chart in <dir>, unpinned, gives for
# it: the one tag its render names a named image by, or a chosen image's guard. Each path is first held to what a tag
# can be in Helm's own defaults, a string or nothing under a map that holds more, so that a tag's pin, which a template
# takes as true, can't turn on what the chart leaves off.
derive() {
  local tree=$1 dir=$2 record=$3 copy=$tmp/defaults image path chosen shape refs file key now
  rm -rf "$copy" && cp -r "$dir" "$copy" && mkdir -p "$copy/templates"
  [ ! -e "$copy/templates/zz-charts-values.yaml" ] ||
    die "$tree holds templates/zz-charts-values.yaml, the template the tool adds to read its defaults."
  echo '{{ .Values | toJson }}' >"$copy/templates/zz-charts-values.yaml"
  helm template chart "$copy" --show-only templates/zz-charts-values.yaml 2>"$tmp/helm.err" |
    sed '1,/^# Source: /d' >"$tmp/defaults.json" || die "$tree doesn't render: $(cat "$tmp/helm.err")"
  jq -e 'type == "object"' "$tmp/defaults.json" >/dev/null 2>&1 || die "$tree: Helm gives its defaults as no map."
  while IFS=$'\t' read -r image path chosen; do
    shape=$(jq -r --arg path "$path" --arg chosen "$chosen" '
      (try getpath($path | split(".") | .[:-1]) catch null) as $map
      | if ($map | type) != "object" or $map == {} then "map" elif $map.tag | . != null and type != "string" then "tag"
        elif $chosen == "true" and ($map.repository | . != null and . != "") then "repository" else "" end' \
      "$tmp/defaults.json")
    case $shape in
    map) die "$tree: $path: the chart's defaults hold no map with keys at ${path%.tag}." ;;
    tag) die "$tree: $path: the chart's defaults give it as something other than a string." ;;
    repository)
      die "$tree: $path: the chart's defaults name a repository beside it, so $image isn't one the chart leaves unnamed."
      ;;
    esac
  done < <(jq -r '.images[] | (.chosen != null) as $chosen | .image as $image | .values[] | [$image, ., $chosen] | @tsv' \
    "$record")
  render "$dir" "$tmp/unpinned"
  while IFS=$'\t' read -r image file key; do
    refs=$(names "$tmp/unpinned" "$image")
    if [ -z "$file" ]; then
      [[ -n $refs && $refs != *@* && $refs != *$'\n'* ]] ||
        die "$tree: its chart names $image as $(paste -sd' ' <<<"${refs:-nothing}"), not by one tag alone."
      now=${refs#"$image:"}
      [[ $now =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || die "$tree: its chart names $image by $now, not a tag a record takes."
    else
      [ -z "$refs" ] ||
        die "$tree: its chart names $image itself, as $(paste -sd' ' <<<"$refs"): declare it without --chosen."
      now=$(guard "$dir" "$file" "$key") || die "$tree: its $file gives no scalar at $key, which $image is chosen for."
    fi
    printf '%s\t%s\n' "$image" "$now"
  done < <(jq -r '.images[] | [.image, .chosen.file // "", .chosen.key // ""] | @tsv' "$record")
}

# splice <file> <path> <value>: the file with one string set, spliced in at the parser's marks, so that every other byte
# stays as upstream wrote it. Keys missing on the way go on new lines below the deepest key there is.
splice='
import json, sys, yaml
file, keys, value = sys.argv[1], sys.argv[2].split("."), json.dumps(sys.argv[3])
text = open(file, newline="").read()
lines = text.splitlines(keepends=True)
start = [0]
for line in lines:
    start.append(start[-1] + len(line))
at = lambda mark: start[mark.line] + mark.column
node, key = yaml.compose(text), None
for depth, name in enumerate(keys):
    if not isinstance(node, yaml.MappingNode) or node.flow_style:
        sys.exit(file + ": " + (".".join(keys[:depth]) or "the top") + " is not a block mapping")
    found = [(k, v) for k, v in node.value if isinstance(k, yaml.ScalarNode) and k.value == name]
    if not found:
        indent = node.value[0][0].start_mark.column if node.value else key.start_mark.column + 2
        block = "".join(" " * (indent + 2 * i) + k + ":" + (" " + value if i == len(keys) - depth - 1 else "") + "\n"
            for i, k in enumerate(keys[depth:]))
        if key is None:
            sys.stdout.write(text + ("" if text.endswith("\n") else "\n") + block)
        else:
            below = key.start_mark.line + 1
            sys.stdout.write("".join(lines[:below]) + block + "".join(lines[below:]))
        sys.exit()
    key, node = found[0]
if not isinstance(node, yaml.ScalarNode) or not node.start_mark.line == node.end_mark.line == key.start_mark.line:
    sys.exit(file + ": " + sys.argv[2] + " is not a scalar on its key line")
begin, end = at(node.start_mark), at(node.end_mark)
if begin == end:
    begin = end = at(key.end_mark) + 1
    value = " " + value
sys.stdout.write(text[:begin] + value + text[end:])
'
# pin <values file> <path> <value>, refused if what YAML reads in the file would change anywhere else.
pin() {
  local want
  want=$(yq -o=json -I=0 . "$1" | jq -cS --arg path "$2" --arg value "$3" 'setpath($path | split("."); $value)')
  python3 -I -c "$splice" "$1" "$2" "$3" >"$tmp/pinned" || die "$1: $2 can't be pinned in place."
  [ "$(yq -o=json -I=0 . "$tmp/pinned" | jq -cS .)" = "$want" ] || die "$1: pinning $2 would change more than $2."
  cat "$tmp/pinned" >"$1"
}
# pins <dir> <record>: writes the values the record's images pin into the chart's values.yaml.
pins() {
  local path value
  pairs "$2" >"$tmp/pairs"
  while IFS=$'\t' read -r path value; do
    pin "$1/values.yaml" "$path" "$value"
  done <"$tmp/pairs"
}
# unpinned <tree> <dir> <record>: why the chart in <dir> doesn't name each image its record pins by its pin alone, and
# at least once, or gives another name one of their digests, one line each; nothing if neither.
unpinned() {
  local image pin refs digest images ref name
  render "$2" "$tmp/pinned.yaml"
  while IFS=$'\t' read -r image pin; do
    refs=$(names "$tmp/pinned.yaml" "$image" | paste -sd' ')
    [ "$refs" = "$pin" ] || echo "$1: its chart names $image as ${refs:-nothing}, not as $pin alone"
  done < <(jq -r '.images[] | [.image, .image + ":" + .tag + "@" + .digest] | @tsv' "$3")
  # A declared path that a template takes for another image gives that image this one's digest.
  while IFS=$'\t' read -r digest images; do
    while IFS= read -r ref; do
      name=${ref%@*}
      [[ ! $name =~ ^(.+):[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || name=${BASH_REMATCH[1]}
      [[ " $images " = *" $name "* ]] || echo "$1: its chart names $ref, by a digest its record pins for $images alone"
    done < <(grep -oE "[A-Za-z0-9./_:-]*@$digest" "$tmp/pinned.yaml" | LC_ALL=C sort -u)
  done < <(jq -r '.images | group_by(.digest)[] | [.[0].digest, (map(.image) | join(" "))] | @tsv' "$3")
}

# Fetches an OCI chart by its record's digest, checks its signer and unpacks it as <dir>.
oci() {
  local record=$1 dir=$2 key=$3 ref digest name version size top fpr workflow
  ref=$(jq -r '.source | ltrimstr("oci://")' "$record")
  digest=$(jq -r .digest "$record")
  name=${ref##*/}
  version=$(jq -r .version "$record")
  regctl manifest get --format raw-body "$ref@$digest" >"$tmp/manifest"
  [ "sha256:$(sum "$tmp/manifest")" = "$digest" ] || die "$ref@$digest: the registry sent another manifest."
  layer() { jq -c --arg type "$1" '[.layers[]? | select(.mediaType == $type)]' "$tmp/manifest"; }
  # fetch <descriptor> <file>
  fetch() {
    regctl blob get "$ref" "$(jq -r .digest <<<"$1")" >"$2"
    size=$(stat -c %s "$2")
    jq -e --arg sum "sha256:$(sum "$2")" --argjson size "$size" '.digest == $sum and .size == $size' <<<"$1" >/dev/null ||
      die "$ref@$digest: a layer isn't the one its manifest names."
  }
  [ "$(layer "$chart_type" | jq length)" = 1 ] || die "$ref@$digest doesn't hold exactly one chart."
  fetch "$(layer "$chart_type" | jq -c '.[0]')" "$tmp/chart.tgz"
  case $(jq -r 'if .signer == "none" then "none" else .signer | keys[0] end' "$record") in
  pgp)
    fpr=$(jq -r .signer.pgp "$record")
    [ "$(layer "$prov_type" | jq length)" = 1 ] || die "$ref@$digest has no provenance to check."
    fetch "$(layer "$prov_type" | jq -c '.[0]')" "$tmp/chart.prov"
    provenance "$key" "$fpr" "$tmp/chart.prov" "$tmp/chart.tgz" "$name-$version.tgz"
    ;;
  cosign)
    # A workflow's certificate names the ref its run started from, a tag, a branch or a merged pull request, so the
    # signer is the workflow, from any ref of its repository.
    workflow=$(jq -r .signer.cosign.workflow "$record" | sed 's/[].[*^()+?{}|$\\]/\\&/g')
    cosign verify --certificate-identity-regexp "^$workflow@refs/" \
      --certificate-oidc-issuer "$(jq -r .signer.cosign.issuer "$record")" "$ref@$digest" >/dev/null
    ;;
  none)
    [ "$(layer "$prov_type" | jq length)" = 0 ] || die "$ref@$digest has a provenance, yet its record says unsigned."
    unsigned "$ref" "$digest"
    ;;
  esac
  top=$(unpack "$tmp/chart.tgz" "$tmp/chart" "$ref@$digest")
  mv "$tmp/chart/$top" "$dir"
  rmdir "$tmp/chart"
}

# The commit a git repository's tag names.
tagged() {
  local commit
  commit=$(git ls-remote "$1" "refs/tags/$2" "refs/tags/$2^{}" | awk -v tag="refs/tags/$2" '
    $2 == tag { direct = $1 } $2 == tag "^{}" { peeled = $1 } END { print peeled ? peeled : direct }')
  [ -n "$commit" ] || die "$1 has no tag $2."
  echo "$commit"
}

# Copies a directory of a fetched commit as <dir>: regular files alone, as git holds them.
gitdir() {
  local git=$1 commit=$2 path=$3 dir=$4 entry meta file mode type object
  [ "$(git -C "$git" cat-file -t "$commit:$path" 2>/dev/null)" = tree ] || die "$commit holds no directory $path."
  mkdir -p "$dir"
  while IFS= read -r -d '' entry; do
    meta=${entry%%$'\t'*} file=${entry#*$'\t'}
    read -r mode type object <<<"$meta"
    { [ "$type" = blob ] && [[ $mode = 100644 || $mode = 100755 ]] && relative "$file"; } ||
      die "$path/$file at $commit isn't a plain file."
    mkdir -p "$dir/$(dirname "$file")"
    git -C "$git" cat-file blob "$object" >"$dir/$file"
  done < <(git -C "$git" ls-tree -r -z "$commit:$path")
}

# build <record> <dir> [<key>]: the tree a record names, fetched again from its pin and its signer checked.
build() {
  local record=$1 dir=$2 key=${3:-} source commit path tag licence file
  jq -e "$valid" "$record" >/dev/null 2>&1 || die "$record isn't a record this tool writes."
  source=$(jq -r .source "$record")
  rm -rf "$tmp/git"
  case $source in
  oci://*) oci "$record" "$dir" "$key" ;;
  *)
    commit=$(jq -r .commit "$record")
    path=$(jq -r .path "$record")
    # Any commit upstream holds can be fetched, a pull request's too: the pin counts only as what upstream's tag names.
    tag=$(jq -r .tag "$record")
    [ "$(tagged "$source" "$tag")" = "$commit" ] || die "$source's tag $tag names another commit than $commit."
    git init -q "$tmp/git"
    git -C "$tmp/git" -c transfer.fsckObjects=true fetch -q --depth 1 "$source" "$commit"
    [ "$(git -C "$tmp/git" rev-parse FETCH_HEAD)" = "$commit" ] || die "$source sent another commit than $commit."
    gitdir "$tmp/git" "$commit" "$path" "$dir"
    ;;
  esac
  [ ! -f "$dir/Chart.yaml" ] || subcharts "$dir" "$source"
  find "$dir" -type f -exec chmod 644 {} + -o -type d -exec chmod 755 {} +
  while IFS= read -r file; do
    rm -rf "${dir:?}/$file"
  done < <(dropped "$dir")
  while IFS= read -r file; do
    [ -e "$dir/$file" ] || die "$record drops $file, which upstream doesn't hold."
    rm -rf "${dir:?}/$file"
  done < <(jq -r '.drop // [] | .[]' "$record")
  licence=$(jq -c '.license // empty' "$record")
  if [ -n "$licence" ]; then
    [ -z "$(find "$dir" -maxdepth 1 \( -name 'LICENSE*' -o -name 'COPYING*' \))" ] ||
      die "$source ships its own licence: leave --license out."
    if jq -e .path <<<"$licence" >/dev/null; then
      file=$(jq -r .path <<<"$licence")
      [ "$(git -C "$tmp/git" cat-file -t "$commit:$file" 2>/dev/null)" = blob ] || die "$commit holds no file $file."
      git -C "$tmp/git" cat-file blob "$commit:$file" >"$dir/LICENSE"
    else
      curl -fsSL --proto =https "$(jq -r .url <<<"$licence")" -o "$dir/LICENSE"
      [ "$(sum "$dir/LICENSE")" = "$(jq -r .sha256 <<<"$licence")" ] || die "The licence isn't the one its record names."
    fi
    chmod 644 "$dir/LICENSE"
  fi
  find "$dir" -mindepth 1 -type d -empty -delete
}

# What a record is called by: its chart's version, or else its tag.
called() { jq -r '.version // .tag' "$1"; }
# What a record's change shows in a summary: its tree's name, and its version or the two.
change() {
  if [ -z "$2" ] || [ "$2" = "$3" ]; then echo "$1 $3"; else echo "$1 $2 to $3"; fi
}

# Builds a record's tree, holds it to the rules and writes both, after showing what changes.
write() {
  local tree=$1 record=$2 key=$3 new=$tmp/tree old='' problem committed image now entry digest
  build "$record" "$new" "$key"
  # A git source's version is its chart's, when it holds one.
  if jq -e .commit "$record" >/dev/null; then
    if [ -f "$new/Chart.yaml" ]; then
      jq --arg version "$(yq .version "$new/Chart.yaml")" '.version = $version' "$record" >"$record.chart"
    else
      jq 'del(.version)' "$record" >"$record.chart"
    fi
    mv "$record.chart" "$record"
  fi
  if jq -e .images "$record" >/dev/null; then
    derive "$tree" "$new" "$record" >"$tmp/derived"
    problem=$(jq -r --rawfile derived "$tmp/derived" --arg tree "$tree" '
      ($derived | split("\n") | map(select(. != "") | split("\t") | {key: .[0], value: .[1]}) | from_entries) as $now
      | .images[] | select(.chosen.value != null and .chosen.value != $now[.image]) | "\($tree): \(.image) is chosen for"
        + " \(.chosen.file) \(.chosen.key) \(.chosen.value), which the tree now gives as \($now[.image])"' "$record")
    [ -z "$problem" ] || die "$problem
Give each its tag again with image ... --chosen, before the bump."
    # A digest stays while its tag does, so that a tag moved upstream changes nothing. The list comes on fd 3, which no
    # command in the loop reads as its input.
    while IFS=$'\t' read -r -u 3 image now; do
      entry=$(jq -c --arg image "$image" --arg now "$now" '.images[] | select(.image == $image)
        | if .chosen then .chosen.value = $now elif .tag == $now then . else .tag = $now | del(.digest) end' "$record")
      if ! jq -e .digest <<<"$entry" >/dev/null; then
        digest=$(regctl image digest "$image:$(jq -r .tag <<<"$entry")")
        signed "$image" "$digest" "$(jq -c .signer <<<"$entry")" "$(jq -r .tag <<<"$entry")"
        echo "$image:$(jq -r .tag <<<"$entry"): $digest" >&2
        entry=$(jq -c --arg digest "$digest" '.digest = $digest' <<<"$entry")
      fi
      jq --argjson entry "$entry" '(.images[] | select(.image == $entry.image)) = $entry' "$record" >"$record.image"
      mv "$record.image" "$record"
    done 3<"$tmp/derived"
    pins "$new" "$record"
    problem=$(unpinned "$tree" "$new" "$record")
    [ -z "$problem" ] || die "$problem"
  fi
  jq --arg tree "$(treehash "$new")" '.tree = $tree' "$record" >"$record.tree"
  mv "$record.tree" "$record"
  jq -e "$valid" "$record" >/dev/null || die "$new/Chart.yaml has version $(jq -r .version "$record"), not one a record takes."
  problem=$(problems "$new" "$record")
  [ -z "$problem" ] || die "$problem"
  [ ! -f "$tree.json" ] || old=$(called "$tree.json")
  # Flux installs a chart again only once its version changes from the last commit's, which a cluster may run.
  if committed=$(git show "HEAD:./$tree.json" 2>/dev/null); then
    jq -e --argjson old "$committed" '.version == null or .tree == $old.tree or .version != $old.version' "$record" \
      >/dev/null ||
      die "$tree would change at version $(jq -r '.version // .tag' <<<"$committed"), which Flux never installs again."
  fi
  mkdir -p "$tmp/diff/old"
  [ ! -d "$tree" ] || cp -r "$tree/." "$tmp/diff/old"
  cp -r "$new" "$tmp/diff/new"
  (cd "$tmp/diff" && git --no-pager diff --no-index --stat old new) || [ $? = 1 ]
  rm -rf "$tree"
  mkdir -p "$(dirname "$tree")"
  cp -r "$new" "$tree"
  cp "$record" "$tree.json"
  if jq -e .images "$record" >/dev/null; then envfile "$record" >"$tree.images.env"; else rm -f "$tree.images.env"; fi
  change "charts: ${tree##*/}" "$old" "$(called "$record")"
}

# The fingerprints of the keys a record's chart and images are signed with.
signers() { jq -r '.signer.pgp?, .images[]?.signer.cosign?.key? | strings' "$1" | LC_ALL=C sort -u; }

# Removes every key no record is signed by, as a record's signer may have changed.
prune() {
  local record fpr entry
  local -A used=()
  while IFS= read -r -d '' record; do
    while IFS= read -r fpr; do
      used[$fpr.asc]=1
    done < <(signers "$record")
  done < <(records)
  [ -d "$keys_dir" ] || return 0
  while IFS= read -r -d '' entry; do
    [ -n "${used[${entry##*/}]:-}" ] || rm -rf -- "$entry"
  done < <(find "$keys_dir" -mindepth 1 -maxdepth 1 -print0)
}

add() {
  [ $# -ge 4 ] || usage
  local tree=${1%/} source=$2 version=$3 signer='' url='' path='' licence=null drops=() key='' digest='' commit='' images=null
  local drop file fpr
  shift 3
  while [ $# -gt 0 ]; do
    case $1 in
    --pgp)
      [ $# -ge 3 ] || usage
      signer=$(jq -n --arg fpr "$2" '{pgp: $fpr}') url=$3
      shift 3
      ;;
    --cosign)
      [ $# -ge 3 ] || usage
      signer=$(jq -n --arg workflow "$2" --arg issuer "$3" '{cosign: {workflow: $workflow, issuer: $issuer}}')
      shift 3
      ;;
    --unsigned) signer='"none"' && shift ;;
    --path | --license | --drop)
      [ $# -ge 2 ] || usage
      case $1 in
      --path) path=$2 ;;
      --license) licence=$2 ;;
      --drop) drops+=("$2") ;;
      esac
      shift 2
      ;;
    *) usage ;;
    esac
  done
  [ -n "$signer" ] || usage
  [[ $tree =~ $named ]] ||
    die "A tree is kubernetes/platform/<piece>/vendor/<name>, in lowercase letters, digits and dashes, and dots in <name>."
  case $source in
  oci://*)
    [ -z "$path" ] || die "--path is for git sources."
    digest=$(regctl image digest "${source#oci://}:$version")
    ;;
  https://*)
    [ -n "$path" ] || die "A git source needs --path, the directory to vendor."
    [ "$signer" = '"none"' ] || die "A git source is pinned by its commit alone: give --unsigned."
    commit=$(tagged "$source" "$version")
    ;;
  *) die "A source is oci://<registry>/<repository> or the https URL of a git repository." ;;
  esac
  case $licence in
  null) ;;
  https://*)
    curl -fsSL --proto =https "$licence" -o "$tmp/licence"
    licence=$(jq -n --arg url "$licence" --arg sha256 "$(sum "$tmp/licence")" '{url: $url, sha256: $sha256}')
    ;;
  *)
    [ -n "$commit" ] || die "An OCI chart's licence comes from an https URL."
    licence=$(jq -n --arg path "$licence" '{path: $path}')
    ;;
  esac
  if [ -n "$url" ]; then
    key=$tmp/key.asc
    fpr=$(jq -r .pgp <<<"$signer")
    curl -fsSL --proto =https "$url" -o "$tmp/key"
    [ "$(fingerprint "$tmp/key")" = "$fpr" ] || die "$url doesn't hold exactly one key, with fingerprint $fpr."
    # The release keeps keys armoured, as some upstreams don't publish theirs.
    if grep -q '^-----BEGIN PGP PUBLIC KEY BLOCK-----' "$tmp/key"; then
      mv "$tmp/key" "$key"
    else
      gpg --batch --quiet --import "$tmp/key"
      gpg --batch --armor --export "$fpr" >"$key"
      [ "$(fingerprint "$key")" = "$fpr" ] || die "$url's key doesn't armour to one key with fingerprint $fpr."
    fi
  fi
  drop=[]
  for file in "${drops[@]}"; do drop=$(jq -c --arg file "$file" '. + [$file]' <<<"$drop"); done
  # Added again, a tree keeps the images its record declares, pinned anew as a bump pins them.
  [ ! -f "$tree.json" ] || images=$(jq -c '.images // null' "$tree.json")
  jq -n --arg source "$source" --arg version "$version" --arg digest "$digest" --arg commit "$commit" \
    --arg path "$path" --argjson signer "$signer" --argjson license "$licence" --argjson drop "$drop" \
    --argjson images "$images" '
    {source: $source}
    + if $digest != "" then {version: $version, digest: $digest} else {tag: $version, commit: $commit, path: $path} end
    + {signer: $signer}
    + if $license then {license: $license} else {} end
    + if $drop != [] then {drop: $drop} else {} end
    + if $images then {images: $images} else {} end' >"$tmp/record.json"
  write "$tree" "$tmp/record.json" "$key"
  if [ -n "$key" ]; then
    mkdir -p "$keys_dir"
    cp "$key" "$keys_dir/$(jq -r .pgp <<<"$signer").asc"
  fi
  prune
}

bump() {
  [ $# = 2 ] || usage
  local tree=${1%/} version=$2 source key='' commit
  [[ $tree =~ $named ]] && [ -f "$tree.json" ] || die "$tree has no record: add it first."
  source=$(jq -r .source "$tree.json")
  if [[ $source = oci://* ]]; then
    jq --arg version "$version" --arg digest "$(regctl image digest "${source#oci://}:$version")" \
      '.version = $version | .digest = $digest | del(.tree)' "$tree.json" >"$tmp/record.json"
  else
    commit=$(tagged "$source" "$version")
    jq --arg tag "$version" --arg commit "$commit" '.tag = $tag | .commit = $commit | del(.tree)' \
      "$tree.json" >"$tmp/record.json"
  fi
  if jq -e .signer.pgp? "$tree.json" >/dev/null; then
    key=$keys_dir/$(jq -r .signer.pgp "$tree.json").asc
  fi
  write "$tree" "$tmp/record.json" "$key"
}

image() {
  [ $# -ge 3 ] || usage
  local tree=${1%/} image=$2 signer chosen=null
  shift 2
  [[ $tree =~ $named ]] && [ -f "$tree.json" ] || die "$tree has no record: add it first."
  [ -f "$tree/Chart.yaml" ] || die "$tree holds no chart, in whose values an image's pin could go."
  if [ "$*" = --remove ]; then
    jq -e --arg image "$image" 'any(.images[]?; .image == $image)' "$tree.json" >/dev/null ||
      die "$tree.json declares no image $image."
    jq --arg image "$image" 'del(.tree) | .images -= [.images[] | select(.image == $image)]
      | if .images == [] then del(.images) end' "$tree.json" >"$tmp/record.json"
  else
    case $1 in
    --key)
      [ $# -ge 3 ] || usage
      [ -f "$keys_dir/$2.asc" ] || die "$keys_dir/$2.asc doesn't exist: an image's key is one the release keeps for a chart."
      signer=$(jq -n --arg key "$2" --arg hash "$3" '{cosign: {key: $key, hash: $hash}}')
      shift 3
      ;;
    --workflow)
      [ $# -ge 4 ] || usage
      signer=$(jq -n --arg workflow "$2" --arg ref "$3" --arg issuer "$4" \
        '{cosign: {workflow: $workflow, ref: $ref, issuer: $issuer}}')
      shift 4
      ;;
    --identity)
      [ $# -ge 3 ] || usage
      signer=$(jq -n --arg identity "$2" --arg issuer "$3" '{cosign: {identity: $identity, issuer: $issuer}}')
      shift 3
      ;;
    --unsigned) signer='"none"' && shift ;;
    *) usage ;;
    esac
    if [ "${1:-}" = --chosen ]; then
      [ $# -ge 4 ] || usage
      chosen=$(jq -n --arg tag "$2" --arg file "$3" --arg key "$4" '{tag: $tag, file: $file, key: $key}')
      shift 4
    fi
    [ $# -gt 0 ] || usage
    # Its digest stays while its tag and signer do, as a bump keeps it then. A chosen image's tag, given again, holds for
    # whatever the next bump's tree gives at its key.
    jq --arg image "$image" --argjson signer "$signer" --argjson chosen "$chosen" '
      def kind: {signer, chosen: (.chosen | if . then {file, key} else null end), tag: (if .chosen then .tag else null end)};
      ([.images[]? | select(.image == $image)] | .[0]) as $old
      | ({image: $image, values: $ARGS.positional, signer: $signer}
        + if $chosen then {chosen: ($chosen | {file, key}), tag: $chosen.tag} else {} end) as $entry
      | del(.tree)
      | .images = ([.images[]? | select(.image != $image)]
        + [$entry + if $old and ($old | kind) == ($entry | kind) then $old | {tag, digest} | with_entries(select(.value))
          else {} end]
        | sort_by(.image))' "$tree.json" --args "$@" >"$tmp/record.json"
  fi
  jq -e "$valid" "$tmp/record.json" >/dev/null 2>&1 || die "That isn't an image a record takes: see its name, its signer," \
    "--chosen, and its values paths, a.b.tag each, and no other image's."
  cp "$tmp/record.json" "$tree.json"
  prune
}

# Every vendor directory under kubernetes/, outside the trees themselves, and every record where records go.
vendors() { find kubernetes -type d -name vendor -prune -print0; }
records() {
  find kubernetes -mindepth 4 -maxdepth 4 -type f -path 'kubernetes/platform/*/vendor/*.json' -print0 | sort -z
}

# Holds every tree to its record and every key to the records it signs, saying each way one fails.
holds() {
  [ -d kubernetes ] || die "Run at the top of the repository, which holds kubernetes/."
  local failed=0 vendor entry record tree fpr problem values path value image file key now
  local -A used=()
  refuse() {
    echo "$*" >&2
    failed=1
  }
  while IFS= read -r -d '' vendor; do
    if ! [[ $vendor =~ ^$piece$ ]]; then
      refuse "$vendor: a vendor directory, but not kubernetes/platform/<piece>/vendor"
      continue
    fi
    while IFS= read -r -d '' entry; do
      case $entry in
      *.json) tree=${entry%.json} ;;
      *.images.env)
        tree=${entry%.images.env}
        if ! { [ -f "$entry" ] && [ ! -L "$entry" ] && [ -f "$tree.json" ] &&
          jq -e .images "$tree.json" >/dev/null 2>&1; }; then
          refuse "$entry: in a vendor directory, but not the images file of a record that pins images"
        fi
        continue
        ;;
      *) tree=$entry ;;
      esac
      [[ $tree =~ $named ]] && [ -d "$tree" ] && [ ! -L "$tree" ] && [ -f "$tree.json" ] && [ ! -L "$tree.json" ] ||
        refuse "$entry: in a vendor directory, but not a tree beside its record"
    done < <(find "$vendor" -mindepth 1 -maxdepth 1 -print0)
  done < <(vendors)
  while IFS= read -r -d '' record; do
    tree=${record%.json}
    [ -d "$tree" ] || continue
    if ! jq -e "$valid" "$record" >/dev/null 2>&1; then
      refuse "$record isn't a record this tool writes."
      continue
    fi
    while IFS= read -r fpr; do
      used[$fpr.asc]=1
      [ -f "$keys_dir/$fpr.asc" ] && [ "$(fingerprint "$keys_dir/$fpr.asc")" = "$fpr" ] ||
        refuse "$record: $keys_dir/$fpr.asc doesn't hold exactly one key, with fingerprint $fpr."
    done < <(signers "$record")
    problem=$(problems "$tree" "$record")
    [ -z "$problem" ] || refuse "$problem"
    # Only image takes a tree's hash or a pin from its record, and the next bump gives both back.
    if jq -e '.tree == null or any(.images[]?; .digest == null or .chosen != null and .chosen.value == null)' "$record" \
      >/dev/null; then
      refuse "$tree: its record changed since its tree was written: bump it"
      continue
    fi
    [ "$(treehash "$tree")" = "$(jq -r .tree "$record")" ] ||
      refuse "$tree: its files aren't the ones its record names."
    jq -e .images "$record" >/dev/null || continue
    cmp -s "$tree.images.env" <(envfile "$record") || refuse "$tree.images.env: not the images file its record gives"
    values=$(yq -o=json . "$tree/values.yaml" 2>/dev/null) || values=null
    while IFS=$'\t' read -r path value; do
      [ "$(jq -r --arg path "$path" 'getpath($path | split(".")) | strings' <<<"$values")" = "$value" ] ||
        refuse "$tree: its values don't give $path as $value"
    done < <(pairs "$record")
    while IFS=$'\t' read -r image file key value; do
      now=$(guard "$tree" "$file" "$key") || now=nothing
      [ "$now" = "$value" ] || refuse "$tree: $image is chosen for $file $key $value, which the tree gives as $now"
    done < <(jq -r '.images[] | select(.chosen) | [.image, .chosen.file, .chosen.key, .chosen.value] | @tsv' "$record")
    problem=$(unpinned "$tree" "$tree" "$record")
    [ -z "$problem" ] || refuse "$problem"
  done < <(records)
  if [ -d "$keys_dir" ]; then
    while IFS= read -r -d '' entry; do
      [ -n "${used[${entry##*/}]:-}" ] || refuse "$entry: no record is signed by it."
    done < <(find "$keys_dir" -mindepth 1 -maxdepth 1 -print0)
  fi
  [ "$failed" = 0 ]
}
check() {
  [ $# = 0 ] || usage
  holds
}

verify() {
  [ $# = 2 ] && [ "$1" = --since ] || usage
  local rev=$2 record tree key keys fpr old problem image now tag digest signer
  holds
  git rev-parse -q --verify "$rev^{commit}" >/dev/null || die "$rev isn't a commit."
  while IFS= read -r -d '' record; do
    tree=${record%.json}
    key=
    if jq -e .signer.pgp? "$record" >/dev/null; then key=$keys_dir/$(jq -r .signer.pgp "$record").asc; fi
    keys=()
    while IFS= read -r fpr; do keys+=("$keys_dir/$fpr.asc"); done < <(signers "$record")
    # holds has held each tree and images file to its record.
    if git cat-file -e "$rev:./$record" 2>/dev/null && git diff --quiet "$rev" -- "$record" "${keys[@]}"; then
      continue
    fi
    echo "$tree: from its pin"
    rm -rf "$tmp/verify"
    build "$record" "$tmp/verify" "$key"
    # Tags aren't resolved again, as upstream moves them: the chart names the tags, and each digest its signer holds.
    if jq -e .images "$record" >/dev/null; then
      derive "$tree" "$tmp/verify" "$record" >"$tmp/derived"
      while IFS=$'\t' read -r image now; do
        problem=$(jq -r --arg tree "$tree" --arg image "$image" --arg now "$now" '.images[] | select(.image == $image)
          | if .chosen then select(.chosen.value != $now) | "\($tree): \($image) is chosen for \(.chosen.file)"
            + " \(.chosen.key) \(.chosen.value), which its pin gives as \($now)."
          else select(.tag != $now) | "\($tree): its chart names \($image) by \($now), not by \(.tag) as its record says."
          end' "$record")
        [ -z "$problem" ] || die "$problem"
      done <"$tmp/derived"
      while IFS=$'\t' read -r -u 3 image tag digest signer; do
        if ! regctl manifest head "$image@$digest" >/dev/null || ! (signed "$image" "$digest" "$signer" "$tag"); then
          # Only to help find the pin the record should hold, never to take it.
          if ! now=$(regctl image digest "$image:$tag" 2>/dev/null); then
            now="$image:$tag gives no digest now"
          elif ! (signed "$image" "$now" "$signer" "$tag") >/dev/null 2>&1; then
            now="$image:$tag gives $now now, which its signer doesn't pass either"
          elif [ "$signer" = '"none"' ]; then
            now="$image:$tag gives $now now, which shows no signature"
          else
            now="$image:$tag gives $now now, which its signer passes"
          fi
          die "$tree: its record pins $image at $digest, which its registry doesn't hold or its signer doesn't pass; $now."
        fi
      done 3< <(jq -r '.images[] | [.image, .tag, .digest, (.signer | tojson)] | @tsv' "$record")
      pins "$tmp/verify" "$record"
    fi
    problem=$(problems "$tmp/verify" "$record")
    [ -z "$problem" ] || die "$problem"
    if [ "$(treehash "$tmp/verify")" != "$(jq -r .tree "$record")" ]; then
      diff -r "$tmp/verify" "$tree" >&2 || true
      die "$tree: its pin gives another tree than its record names."
    fi
    if old=$(git show "$rev:./$record" 2>/dev/null); then
      jq -e --argjson old "$old" '.version == null or .tree == $old.tree or .version != $old.version' "$record" \
        >/dev/null || die "$tree changed since $rev at version $(called "$record"), which Flux never installs again."
    fi
  done < <(records)
}

summary() {
  [ $# = 0 ] || usage
  local record old changes=() line state key
  while IFS= read -r -d '' record; do
    old=
    if git cat-file -e "HEAD:./$record" 2>/dev/null; then
      ! cmp -s <(git show "HEAD:./$record") "$record" || continue
      old=$(git show "HEAD:./$record" | jq -r '.version // .tag')
    fi
    changes+=("$(change "$(basename "$record" .json)" "$old" "$(called "$record")")")
  done < <(records)
  # A key that comes, changes or goes changes whom the release trusts, even with every record as it was.
  while read -r state key; do
    case $state in
    '??' | A) state=added ;;
    D) state=removed ;;
    *) state=changed ;;
    esac
    changes+=("key $(basename "$key" .asc) $state")
  done < <(git status --porcelain --untracked-files=all --no-renames -- "$keys_dir")
  [ ${#changes[@]} = 0 ] && return
  printf -v line '%s, ' "${changes[@]}"
  echo "charts: ${line%, }"
}

command=${1:-}
[ $# = 0 ] || shift
case $command in
add | bump | image | check | verify | summary) "$command" "$@" ;;
*) usage ;;
esac
