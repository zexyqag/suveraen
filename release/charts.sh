# charts add <tree> <source> <version> (--pgp <fingerprint> <key-url> | --cosign <workflow> <issuer> | --unsigned)
#        [--path <dir>] [--license <url-or-path>] [--drop <path>]...
# charts bump <tree> <version>
# charts check
# charts verify --since <rev>
# charts summary
# Run at the top of the repository. Vendors a chart, or a directory of manifests, into <tree>,
# kubernetes/platform/<piece>/vendor/<name>, from its upstream pin, with its record in <tree>.json: an OCI chart by its
# manifest's digest, its signature checked, or a directory, given by --path, of the commit a git tag names, the tag
# being <version>. Docs, tests, images and dot entries are left out, and a licence the package lacks is added from
# --license. A PGP key goes in release/chart-keys, where no key stays that no record names. check holds every tree to
# its record offline; verify also fetches every record whose record, tree or key changed since <rev> again from its pin
# and checks it gives the same tree. summary names what the records and keys change since HEAD.
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
export GNUPGHOME=$tmp/gnupg
mkdir -m 700 "$GNUPGHOME"
sum() { sha256sum "$1" | cut -d' ' -f1; }
# A path that stays below where it's joined to.
relative() { [[ -n $1 && $1 != /* && /$1/ != */../* && /$1/ != */./* && $1 != *//* ]]; }
treehash() {
  echo "sha256:$( (cd "$1" && find . -type f -printf '%P\0' | LC_ALL=C sort -z | xargs -0 -r sha256sum --) | sum -)"
}

valid='def rel: type == "string" and (split("/") | all(. != "" and . != "." and . != ".."));
  def hex(n): type == "string" and test("^[0-9a-f]{\(n)}$");
  def version: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._+-]*$");
  (keys - ["source", "version", "tag", "digest", "commit", "path", "signer", "license", "drop", "tree"] == [])
  and (if .source | type == "string" and test("^oci://[a-z0-9.:-]+/[a-z0-9._/-]+$") then
      (.version | version) and .tag == null and (.digest | type == "string" and startswith("sha256:") and (.[7:] | hex(64)))
      and .commit == null and .path == null
      and (.license | . == null or keys == ["sha256", "url"])
    else
      (.source | type == "string" and startswith("https://")) and (.tag | version) and (.version | . == null or version)
      and (.commit | hex(40)) and (.path | rel) and .digest == null and .signer == "none"
      and (.license | . == null or keys == ["path"] and (.path | rel) or keys == ["sha256", "url"])
    end)
  and (.signer == "none" or (.signer | objects | keys == ["pgp"] and (.pgp | test("^[0-9A-F]{40}$"))
    or keys == ["cosign"] and (.cosign | objects | keys == ["issuer", "workflow"] and all(.[]; type == "string")
      and (.workflow | test("^https://[^/@]+/[^/@]+/[^/@]+/\\.github/workflows/[^/@]+$")))))
  and (.license | . == null or has("path")
    or (.url | type == "string" and startswith("https://")) and (.sha256 | hex(64)))
  and (.drop | . == null or type == "array" and length > 0 and all(.[]; rel))
  and (.tree | . == null or type == "string" and startswith("sha256:") and (.[7:] | hex(64)))'

# What a tree may never hold: anything but files and directories, and names a line or git might not carry as they are.
odd() { (cd "$1" && LC_ALL=C find . -mindepth 1 \( ! -type f ! -type d -o -name '*[!A-Za-z0-9._+@=,~-]*' \) -printf '%P\n'); }
# Upstream's docs, tests, images and dot entries, which the release leaves out. .helmignore stays: Helm reads it.
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

# Fetches an OCI chart by its record's digest, checks its signer and unpacks it as <dir>.
oci() {
  local record=$1 dir=$2 key=$3 ref digest name version size top fpr workflow tags referrers
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
    # So that upstream starting to sign is noticed: a provenance, a signature's tag, or any referrer.
    [ "$(layer "$prov_type" | jq length)" = 0 ] || die "$ref@$digest has a provenance, yet its record says unsigned."
    tags=$(regctl tag ls "$ref")
    ! grep "^sha256-${digest#sha256:}" <<<"$tags" ||
      die "$ref@$digest has the tags above, which signatures and attestations take, yet its record says unsigned."
    referrers=$(regctl artifact list "$ref@$digest" --format '{{len .Descriptors}}')
    [ "$referrers" = 0 ] || die "$ref@$digest has $referrers referrers, yet its record says unsigned."
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
  local tree=$1 record=$2 key=$3 new=$tmp/tree old='' problem
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
  jq --arg tree "$(treehash "$new")" '.tree = $tree' "$record" >"$record.tree"
  mv "$record.tree" "$record"
  jq -e "$valid" "$record" >/dev/null || die "$new/Chart.yaml has version $(jq -r .version "$record"), not one a record takes."
  problem=$(problems "$new" "$record")
  [ -z "$problem" ] || die "$problem"
  if [ -f "$tree.json" ]; then
    old=$(called "$tree.json")
    # Flux installs a chart again only once its version changes.
    jq -e --slurpfile old "$tree.json" '.version == null or .tree == $old[0].tree or .version != $old[0].version' \
      "$record" >/dev/null || die "$tree would change at version $old, which Flux never installs again."
  fi
  mkdir -p "$tmp/diff/old"
  [ ! -d "$tree" ] || cp -r "$tree/." "$tmp/diff/old"
  cp -r "$new" "$tmp/diff/new"
  (cd "$tmp/diff" && git --no-pager diff --no-index --stat old new) || [ $? = 1 ]
  rm -rf "$tree"
  mkdir -p "$(dirname "$tree")"
  cp -r "$new" "$tree"
  cp "$record" "$tree.json"
  change "charts: ${tree##*/}" "$old" "$(called "$record")"
}

# Removes every key no record is signed by, as a record's signer may have changed.
prune() {
  local record fpr entry
  local -A used=()
  while IFS= read -r -d '' record; do
    fpr=$(jq -r '.signer.pgp? // empty' "$record")
    [ -z "$fpr" ] || used[$fpr.asc]=1
  done < <(records)
  [ -d "$keys_dir" ] || return 0
  while IFS= read -r -d '' entry; do
    [ -n "${used[${entry##*/}]:-}" ] || rm -rf -- "$entry"
  done < <(find "$keys_dir" -mindepth 1 -maxdepth 1 -print0)
}

add() {
  [ $# -ge 4 ] || usage
  local tree=${1%/} source=$2 version=$3 signer='' url='' path='' licence=null drops=() key='' digest='' commit='' drop file fpr
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
  jq -n --arg source "$source" --arg version "$version" --arg digest "$digest" --arg commit "$commit" \
    --arg path "$path" --argjson signer "$signer" --argjson license "$licence" --argjson drop "$drop" '
    {source: $source}
    + if $digest != "" then {version: $version, digest: $digest} else {tag: $version, commit: $commit, path: $path} end
    + {signer: $signer}
    + if $license then {license: $license} else {} end
    + if $drop != [] then {drop: $drop} else {} end' >"$tmp/record.json"
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

# Every vendor directory under kubernetes/, outside the trees themselves, and every record where records go.
vendors() { find kubernetes -type d -name vendor -prune -print0; }
records() {
  find kubernetes -mindepth 4 -maxdepth 4 -type f -path 'kubernetes/platform/*/vendor/*.json' -print0 | sort -z
}

# Holds every tree to its record and every key to the records it signs, saying each way one fails.
holds() {
  [ -d kubernetes ] || die "Run at the top of the repository, which holds kubernetes/."
  local failed=0 vendor entry record tree fpr problem
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
    problem=$(problems "$tree" "$record")
    [ -z "$problem" ] || refuse "$problem"
    [ "$(treehash "$tree")" = "$(jq -r .tree "$record")" ] ||
      refuse "$tree: its files aren't the ones its record names."
    fpr=$(jq -r '.signer.pgp? // empty' "$record")
    if [ -n "$fpr" ]; then
      used[$fpr.asc]=1
      [ -f "$keys_dir/$fpr.asc" ] && [ "$(fingerprint "$keys_dir/$fpr.asc")" = "$fpr" ] ||
        refuse "$record: $keys_dir/$fpr.asc doesn't hold exactly one key, with fingerprint $fpr."
    fi
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
  local rev=$2 record tree key old problem
  holds
  git rev-parse -q --verify "$rev^{commit}" >/dev/null || die "$rev isn't a commit."
  while IFS= read -r -d '' record; do
    tree=${record%.json}
    key=
    if jq -e .signer.pgp? "$record" >/dev/null; then key=$keys_dir/$(jq -r .signer.pgp "$record").asc; fi
    if git cat-file -e "$rev:./$record" 2>/dev/null && git diff --quiet "$rev" -- "$record" "$tree" ${key:+"$key"}; then
      continue
    fi
    echo "$tree: from its pin"
    rm -rf "$tmp/verify"
    build "$record" "$tmp/verify" "$key"
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
add | bump | check | verify | summary) "$command" "$@" ;;
*) usage ;;
esac
