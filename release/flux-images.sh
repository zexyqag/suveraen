# flux-images
# Pins each image the flake's Flux installs to a digest, in nixos/flux-images.json. A tag the table already pins keeps
# its digest, so a tag moved upstream changes nothing. A new tag's digest counts only once its signature is Flux's:
# made by Flux's release workflow, run from the image's own repository for that very tag.
table=nixos/flux-images.json
cd "$(git rev-parse --show-toplevel)"
images=$(flux install --export |
  yq ea '[select(.kind == "Deployment") | .. | select(tag == "!!map" and has("image")) | .image] | unique | .[]')
pins={}
while read -r image; do
  digest=$(jq -r --arg image "$image" '.[$image] // ""' "$table")
  if [ -z "$digest" ]; then
    name=${image%:*}
    digest=$(regctl image digest "$image")
    cosign verify "$name@$digest" \
      --certificate-oidc-issuer https://token.actions.githubusercontent.com \
      --certificate-identity-regexp '^https://github\.com/fluxcd/gha-workflows/\.github/workflows/controller-release\.yaml@refs/tags/v[0-9.]+$' \
      --certificate-github-workflow-repository "${name#*/}" \
      --certificate-github-workflow-ref "refs/tags/${image##*:}" >/dev/null
    echo "$image: $digest"
  fi
  pins=$(jq --arg image "$image" --arg digest "$digest" '.[$image] = $digest' <<<"$pins")
done <<<"$images"
jq -S . <<<"$pins" >"$table"
