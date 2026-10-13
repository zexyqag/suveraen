# approve [candidate branch] [release branch]
# Signs what the candidate branch holds as the next release and pushes it to the release branch.
# Run it from a clone of the repository, with git's user.signingkey set to your SSH (security key) signing key.
export GIT_PAGER=cat
remote=origin
candidate_branch=${1:-staging}
release_branch=${2:-main}
signers_file=release/signers

git fetch --quiet "$remote" "$release_branch" "$candidate_branch"
release=$(git rev-parse "$remote/$release_branch")
candidate=$(git rev-parse "$remote/$candidate_branch")

allowed=$(mktemp)
trap 'rm -f "$allowed"' EXIT
allowed_signers() {
  git show "$1:$signers_file" | awk 'NF && $1 !~ /^#/ { print "release", $1, $2 }' >"$allowed"
}
verify() {
  git -c gpg.format=ssh -c gpg.ssh.allowedSignersFile="$allowed" verify-commit "$1" 2>/dev/null
}

# Trust comes from the last signed release, never from the candidate.
if git cat-file -e "$release:$signers_file" 2>/dev/null; then
  allowed_signers "$release"
  if ! verify "$release"; then
    echo "$remote/$release_branch ($release) is not signed by one of its signers. Stop and find out who moved it." >&2
    exit 1
  fi
  if ! git rev-parse -q --verify "$release^2" >/dev/null ||
    [ "$(git rev-parse "$release^{tree}")" != "$(git rev-parse "$release^2^{tree}")" ] ||
    ! git merge-base --is-ancestor "$release^2" "$candidate"; then
    echo "$release_branch holds changes that aren't on $candidate_branch. Merge $release_branch into $candidate_branch first." >&2
    exit 1
  fi
else
  if [ -n "$(git log -1 --format=%H "$release" -- "$signers_file")" ]; then
    echo "$release_branch no longer has $signers_file. Releases can't continue without it; restore it on $candidate_branch." >&2
    exit 1
  fi
  if ! git cat-file -e "$candidate:$signers_file" 2>/dev/null; then
    echo "$candidate_branch has no $signers_file: add your signing keys' public halves there first." >&2
    exit 1
  fi
  if ! git merge-base --is-ancestor "$release" "$candidate"; then
    echo "$release_branch holds changes that aren't on $candidate_branch. Merge $release_branch into $candidate_branch first." >&2
    exit 1
  fi
  echo "First release. From now on, only these keys can sign releases; check that they are yours:"
  git show "$candidate:$signers_file"
  echo
  allowed_signers "$candidate"
fi

if git merge-base --is-ancestor "$candidate" "$release"; then
  echo "Nothing new on $candidate_branch."
  exit 0
fi

echo "Candidate: $candidate"
url=$(git remote get-url "$remote")
if [[ $url =~ github\.com[:/]([^/]+)/([^/]+)$ ]]; then
  repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"
  echo "Checks:"
  curl -fsS "https://api.github.com/repos/$repo/commits/$candidate/check-runs" |
    jq -r '.check_runs[] | "  \(.name): \(.conclusion // .status)"' ||
    echo "  (couldn't read them; look at https://github.com/$repo/commits/$candidate)"
fi

echo
echo "Changes since the last release:"
git log --oneline "$release..$candidate"
echo
git diff --stat "$release" "$candidate"
locks() { git show "$1:flake.lock" | jq -S '.nodes | map_values(.locked // {} | {rev, url, narHash})'; }
if ! git diff --quiet "$release" "$candidate" -- flake.lock; then
  echo
  echo "Inputs that change:"
  diff <(locks "$release") <(locks "$candidate") || true
fi
trust=$(git diff --name-only "$release" "$candidate" -- "$signers_file" flake.nix nixos/source.nix nixos/upgrade.nix .github release)
if [ -n "$trust" ]; then
  echo
  echo "Read these closely; they decide who and what is trusted:"
  echo "$trust"
fi

echo
read -r -p "Type 'release' to sign and publish this: " answer
if [ "$answer" != release ]; then
  echo "Nothing released."
  exit 1
fi

# The release commit carries the candidate's exact tree, so what gets deployed is what was tested.
commit=$(git -c gpg.format=ssh commit-tree -S "$candidate^{tree}" -p "$release" -p "$candidate" -m "Release $(date -u +%F)")
if ! verify "$commit"; then
  echo "The new release isn't signed by one of the signers in $signers_file. Check git's user.signingkey." >&2
  exit 1
fi
git push --quiet "$remote" "$commit:refs/heads/$release_branch"
echo "Released $commit. The cluster picks it up within minutes, the servers tonight."
