# approve [--first-release]
# Signs what the staging branch holds as the next release and publishes it on main. Run it in a clone of the
# repository with git's user.signingkey set to your SSH (security key) signing key. After each release it prints
# the command for next time, which runs approve from that signed release instead of from your working tree.
export GIT_PAGER=cat
remote=origin
candidate_branch=staging
release_branch=main
signers_file=release/signers

first=false
if [ "${1:-}" = --first-release ]; then
  first=true
fi

die() {
  echo "$*" >&2
  exit 1
}
# Commit subjects, file names and keys come from whoever pushed; terminal control codes could fake this screen.
clean() { LC_ALL=C tr -d '\000-\010\013-\037\177'; }
signers_of() { git show "$1:$signers_file" 2>/dev/null | awk 'NF && $1 !~ /^#/ { print $1, $2 }'; }
allowed_of() { signers_of "$1" | awk '{ print "release", $1, $2 }' >"$2"; }
# Commands below feed grep -q from a variable: in a pipe, grep stopping early can kill the writer, and pipefail
# then turns a match into a failure.
signed_by() {
  grep -q '^gpgsig -----BEGIN SSH SIGNATURE-----' <<<"$(git cat-file commit "$1")" &&
    git -c gpg.format=ssh -c gpg.ssh.allowedSignersFile="$2" verify-commit "$1" >/dev/null 2>&1
}
tree() { git rev-parse "$1^{tree}"; }
is_release() { git rev-parse -q --verify "$1^2" >/dev/null && [ "$(tree "$1")" = "$(tree "$1^2")" ]; }
show_signers() {
  signers_of "$1" | while read -r type key; do
    echo "$type $key" | ssh-keygen -lf - | clean
  done
}

# Paths below are the repository's, wherever in the clone this runs.
cd "$(git rev-parse --show-toplevel)"
state=$(git rev-parse --absolute-git-dir)/approve
mkdir -p "$state"
# Fully qualified refs only, and no tags: a tag named like a branch would otherwise win.
git fetch --quiet --no-tags "$remote" \
  "+refs/heads/$release_branch:refs/approve/release" "+refs/heads/$candidate_branch:refs/approve/candidate"
release=$(git rev-parse --verify "refs/approve/release^{commit}")
candidate=$(git rev-parse --verify "refs/approve/candidate^{commit}")
# Trust starts from the last release this clone made, never from what the remote says.
anchor=$(git rev-parse -q --verify "refs/approve/last^{commit}" || true)

if $first; then
  [ -z "$anchor" ] || die "This clone has made releases already; --first-release is only for the very first one."
  git merge-base --is-ancestor "$release" "$candidate" ||
    die "$release_branch holds changes that aren't on $candidate_branch. Merge $release_branch into $candidate_branch first."
  [ -n "$(signers_of "$candidate")" ] ||
    die "$candidate_branch has no $signers_file: add the public halves of your signing keys there first."
  echo "First release. From now on, only these keys can sign releases. Check that each fingerprint is one of yours:"
  show_signers "$candidate"
  echo
  allowed_of "$candidate" "$state/current"
else
  [ -n "$anchor" ] || die "This clone has no record of a release. For the very first one, run approve --first-release.
To continue from another machine, record the last release you made there: git update-ref refs/approve/last <commit>."
  grep -qx "$anchor" <<<"$(git rev-list --first-parent "$release")" ||
    die "$release_branch doesn't continue from the last release this clone made ($anchor). It was rewound or replaced: stop and find out who moved it."
  for commit in $(git rev-list --first-parent --reverse "$anchor..$release"); do
    allowed_of "$commit^1" "$state/check"
    { is_release "$commit" && signed_by "$commit" "$state/check"; } ||
      die "$release_branch has a commit that isn't a release signed by a signer: $commit. Stop and find out who pushed it."
  done
  git merge-base --is-ancestor "$release^2" "$candidate" ||
    die "$candidate_branch no longer contains the last release. It was rewritten; stop and find out why."
  allowed_of "$release" "$state/current"
fi

if git merge-base --is-ancestor "$candidate" "$release"; then
  echo "Nothing new on $candidate_branch."
  exit 0
fi

echo "Candidate: $candidate"
# The configured URL, not the insteadOf-expanded one, says which repository this is.
url=$(git config --get "remote.$remote.url")
if [[ $url =~ github\.com[:/]([^/]+)/([^/]+)$ ]]; then
  repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"
  runs=$(curl -fsS "${GITHUB_API_URL:-https://api.github.com}/repos/$repo/commits/$candidate/check-runs?per_page=100") ||
    die "Couldn't read the checks of $candidate. Look at https://github.com/$repo/commits/$candidate and try again."
  echo "Checks:"
  jq -r '.check_runs[] | "  \(.name): \(.conclusion // .status)"' <<<"$runs" | clean
  jq -e '.check_runs | length > 0 and all(.conclusion | IN("success", "neutral", "skipped"))' <<<"$runs" >/dev/null ||
    die "Not every check on $candidate has passed. Release once they have."
fi

# Kanidm applies a migration again once the bytes under its file's ID change, and refuses one that makes an entry it
# holds, so each tenant that applied a file making one fails it at every start once its text is another, or once
# another file makes that entry. Such a file is a value of a ConfigMap the cluster applies from kubernetes/ that names
# classes; this prints each in a commit as its file's ID and each entry's, its text and where it is.
creates() {
  { git grep -z -l -F class "$1" -- 'kubernetes/*.yaml' || [ $? = 1 ]; } | while IFS= read -r -d '' file; do
    data=$(git show "$file" | yq ea -o=json -I=0 'select(.kind == "ConfigMap") | .data // {} | to_entries[]') ||
      die "$(printf %s "${file#*:}" | clean) isn't YAML in $1."
    jq -r --arg at "${file#*:}" '(.value | fromjson? | objects) as $m
      | ($m.assertions | arrays | .[] | objects | select(has("class")) | .id) as $entry
      | (["file", $m.id], ["entry", $entry]) as $id
      | [($id | tojson), (.value | tojson), "\($at): \(.key)"] | @tsv' <<<"$data"
  done
}
# The text main first held under each ID, through every release, which tenants may have applied since.
: >"$state/made"
last=
for commit in $(git rev-list --first-parent --reverse "$release"); do
  kube=$(git rev-parse -q --verify "$commit:kubernetes" || true)
  [ -n "$kube" ] && [ "$kube" != "$last" ] || continue
  last=$kube
  creates "$commit" >>"$state/made"
done
creates "$candidate" >"$state/candidate"
changed=$(awk -F '\t' 'FILENAME == ARGV[1] { if (!($1 in made)) made[$1] = $2; next }
  $1 in made && made[$1] != $2 && !seen[$3]++ { print "  " $3 }' "$state/made" "$state/candidate" | clean)
[ -z "$changed" ] || die "These files make a Kanidm entry, but not with the text main first held under their ID or for that entry:
$changed
Kanidm refuses such a file at every start of every tenant that applied the old one. Revert each to that text, or make a new entry under new IDs and remove the old one."

echo
echo "Changes since the last release:"
git log --format='%h %s' "$release..$candidate" | clean
echo
git diff --stat "$release" "$candidate" | clean
locks() { git show "$1:flake.lock" | jq -S '.nodes | map_values({locked: (.locked // {} | del(.lastModified)), inputs})'; }
if ! git diff --quiet "$release" "$candidate" -- flake.lock; then
  echo
  echo "Inputs that change:"
  { diff <(locks "$release") <(locks "$candidate") || true; } | clean
fi
# Each vendored tree that changes, by its record's path without .json, with its versions, signer and source. Only the
# tool writes a tree from upstream, and it writes the record too: a tree that changes alone was changed some other way.
charts() {
  git diff --name-only --no-renames "$release" "$candidate" -- 'kubernetes/platform/*/vendor/*' |
    sed -E 's,/vendor/([^/]*)(\.json$|/.*),/vendor/\1,' | sort -u | while IFS= read -r stem; do
    old=$(git show "$release:$stem.json" 2>/dev/null || echo null)
    new=$(git show "$candidate:$stem.json" 2>/dev/null || echo null)
    same=false
    if git diff --quiet "$release" "$candidate" -- "$stem.json"; then same=true; fi
    jq -n -r --arg stem "$stem" --argjson old "$old" --argjson new "$new" --argjson same "$same" '
      def called: .version // .tag;
      def signer: if . == "none" then "unsigned" elif .pgp? then "PGP key \(.pgp)"
        elif .cosign? then "cosign \(.cosign.identity), issued by \(.cosign.issuer)" else error end;
      "  \($stem): " + if $new == null and $old == null then "holds no record"
      elif $new == null then "removed"
      else [if $old == null then "new at \($new | called)" elif ($old | called) == ($new | called) then $new | called
          else "\($old | called) to \($new | called)" end, ($new.signer | signer)]
        + if $old != null and $old.signer != $new.signer then ["signer changes"] else [] end
        + if $old != null and $old.source != $new.source then ["source changes from \($old.source)"] else [] end
        + if $same then ["tree changed, record didn\u0027t"] else [] end
        | join(", ") end' || die "$(printf %s "$stem" | clean).json isn't a chart's record."
  done
}
vendored=$(charts | clean)
if [ -n "$vendored" ]; then
  echo
  echo "Charts that change:"
  echo "$vendored"
fi
if ! $first && ! git diff --quiet "$release" "$candidate" -- "$signers_file"; then
  echo
  echo "The signers change. After this release, only these keys can sign:"
  show_signers "$candidate"
fi
trust=$(git diff --name-only "$release" "$candidate" -- "$signers_file" flake.nix flake.lock nixos/source.nix \
  nixos/upgrade.nix nixos/cluster.nix nixos/flux-images.json nixos/default.nix .github release | clean)
if [ -n "$trust" ]; then
  echo
  echo "These change how releases are checked. Read them closely; every other change runs as root too:"
  echo "$trust"
fi
if ! git diff --quiet "$release" "$candidate" -- nixos && ! git diff --quiet "$release" "$candidate" -- kubernetes; then
  echo
  echo "This changes both nixos/ and kubernetes/: the cluster applies kubernetes/ within minutes, the servers nixos/ at"
  echo "tonight's upgrade. If kubernetes/ relies on the servers' change, start nixos-upgrade.service on each server once"
  echo "this is released."
fi

echo
read -r -p "Type 'release' to sign and publish this: " answer
[ "$answer" = release ] || die "Nothing released."

today=$(date -u +%F)
message="Release $today"
pinned=$(git show "$candidate:flake.lock" | jq -r '.nodes[.nodes.root.inputs.nixpkgs].locked | "\(.rev) of \(.lastModified | todate)"')
canary="Canary, $today. As of today:
- I have received no order that forbids me to tell members about it, such as a secrecy order from a court or the police.
- No authority has demanded suveraen's keys or passwords, or required me to change suveraen to collect data or weaken its encryption.
- To my knowledge, no authority has seized, copied or secretly accessed a suveraen server or disk.
This can't cover orders served only on Hetzner, or anything done without my knowledge.
The release pins nixpkgs $pinned, so this was signed after that.
If the newest release has no canary, assume one of these statements may no longer hold."
echo
echo "$canary"
# Never renewed by default: under a gag order the release still goes out, just without it.
read -r -p "Type 'true' if every line still holds, to sign it into this release; Enter leaves it out: " holds || holds=
if [ "$holds" = true ]; then
  message+=$'\n\n'"$canary"
fi

# The release commit carries the candidate's exact tree, so what gets deployed is what was tested.
commit=$(git -c gpg.format=ssh commit-tree -S "$candidate^{tree}" -p "$release" -p "$candidate" -m "$message")
signed_by "$commit" "$state/current" ||
  die "The release isn't signed by a current signer. Check git's user.signingkey."
allowed_of "$candidate" "$state/next"
signed_by "$commit" "$state/next" ||
  die "Your signing key isn't in the new $signers_file. Change keys in two releases: add the new key and release, then remove the old one and release with the new key."
# Refuse if main moved since it was checked above.
git push --quiet --force-with-lease="refs/heads/$release_branch:$release" "$remote" "$commit:refs/heads/$release_branch"
git update-ref refs/approve/last "$commit"

case $url in
/*) flake="git+file://$url" ;;
https://*) flake="git+$url" ;;
*@*:*) flake="git+ssh://${url%%:*}/${url#*:}" ;;
*) flake="git+$url" ;;
esac
keys=$(signers_of "$candidate" | jq -R -s -r '
  {"ssh-ed25519": "ssh-ed25519", "sk-ssh-ed25519@openssh.com": "ssh-ed25519-sk",
   "sk-ecdsa-sha2-nistp256@openssh.com": "ssh-ecdsa-sk", "ssh-rsa": "ssh-rsa"} as $nix
  | split("\n") | map(select(length > 0) | split(" ") | {type: $nix[.[0]], key: .[1]}) | tojson | @uri')
git config approve.command "nix --extra-experimental-features verified-fetches run '$flake?ref=$release_branch&publicKeys=$keys#approve'"
echo "Released $commit. The cluster picks it up within minutes, the servers tonight."
[ "$holds" = true ] || echo "This release has no canary."
echo "Next time, run this; Nix checks the release's signature before running approve from it:"
echo "  $(git config approve.command)"
