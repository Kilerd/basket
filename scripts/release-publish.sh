#!/usr/bin/env bash
# Publishes a release (docs/RELEASING.md, the `publish` job): every file of <assets-dir> goes into
# a new draft release of the existing tag <tag>, is downloaded again and compared byte for byte,
# and then the draft is published. Everything acts on the id of the release this script created,
# never on the tag name (another draft or release of the same tag is never touched).
#   scripts/release-publish.sh <tag> <commit> <assets-dir> <notes-file>
#
# - Refuses unless the tag on origin points at <commit> (the commit that was built), checked
#   before the draft is made and again right before it is published.
# - Marks the release as GitHub's latest only when its version is greater than every published
#   release's (scripts/published-release.sh); an older line's patch never becomes "latest".
# - A draft it made is deleted again if anything fails before it is published.
#
# Prints the release's URL. Needs gh with GH_TOKEN (contents: write), jq, the repository in
# GH_REPO or GITHUB_REPOSITORY and the `origin` remote (git ls-remote).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

[[ $# -eq 4 ]] || die "usage: scripts/release-publish.sh <tag> <commit> <assets-dir> <notes-file>" 64
TAG="$1" SHA="$2" ASSETS="$3" NOTES="$4"
V="${TAG#v}"
[[ "$TAG" == v* && "$V" =~ $SEMVER_RE ]] || die "the tag is not vX.Y.Z" 64
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || die "the commit must be a full sha" 64
[[ -d "$ASSETS" ]] || die "no assets folder $ASSETS" 64
[[ -s "$NOTES" ]] || die "the notes file is empty" 64
REPO="${GH_REPO:-${GITHUB_REPOSITORY:-}}"
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "set GITHUB_REPOSITORY (owner/repo)" 64

FILES=()
while IFS= read -r name; do
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && -f "$ASSETS/$name" && ! -L "$ASSETS/$name" ]] \
    || die "unexpected item in the assets folder: $name"
  FILES+=("$name")
done < <(cd "$ASSETS" && ls -A | LC_ALL=C sort)
(( ${#FILES[@]} > 0 )) || die "the assets folder is empty"

# remote_commit — the commit the tag points at on origin (an annotated tag peeled), or nothing.
remote_commit() {
  local refs
  refs="$(git -C "$ROOT" ls-remote --tags origin)" || die "cannot list the tags on origin"
  awk -v t="refs/tags/$TAG" '
    $2 == t "^{}" { peeled = $1 }
    $2 == t { direct = $1 }
    END { print (peeled != "" ? peeled : direct) }' <<<"$refs"
}
check_tag() { # <when>
  local at
  at="$(remote_commit)"
  [[ -n "$at" ]] || die "the tag $TAG is not on origin ($1): nothing is published"
  [[ "$at" == "$SHA" ]] \
    || die "the tag $TAG points at ${at:0:12} on origin, not at the commit that was built (${SHA:0:12}) ($1): nothing is published"
}

check_tag "before the draft"

NEWEST="$("$ROOT/scripts/published-release.sh")" || die "cannot read the published releases"
LATEST=true
if [[ -n "$NEWEST" && "$(semver_cmp "$V" "${NEWEST#v}")" != 1 ]]; then
  LATEST=false
  log "$TAG is not newer than the published $NEWEST: it is not marked as the latest release"
fi

# The draft, by id from here on.
created="$(jq -n --arg tag "$TAG" --arg name "Basket $V" --rawfile body "$NOTES" \
    '{tag_name: $tag, name: $name, body: $body, draft: true, prerelease: false}' \
  | gh api -X POST "repos/$REPO/releases" --input - --jq '"\(.id) \(.upload_url)"')" \
  || die "cannot create the draft release of $TAG"
read -r ID UPLOAD <<<"$created"
[[ "$ID" =~ ^[0-9]+$ ]] || die "the new release has no id"
UPLOAD="${UPLOAD%%\{*}"
[[ "$UPLOAD" == "https://uploads.github.com/repos/$REPO/releases/$ID/assets" ]] \
  || die "unexpected upload URL for release $ID"
PUBLISHED=0
WORK="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK"
  (( !PUBLISHED )) || return 0
  # Only a release that is still a draft is deleted.
  if [[ "$(gh api "repos/$REPO/releases/$ID" --jq .draft 2>/dev/null || true)" == true ]]; then
    log "deleting the draft release $ID"
    gh api -X DELETE "repos/$REPO/releases/$ID" >/dev/null || log "could not delete the draft release $ID: delete it by hand"
  else
    log "release $ID is not a draft (or can't be read): check it by hand"
  fi
}
trap cleanup EXIT
log "draft release $ID for $TAG"

for name in "${FILES[@]}"; do
  gh api -X POST -H "Content-Type: application/octet-stream" "$UPLOAD?name=$name" \
    --input "$ASSETS/$name" --jq .name >/dev/null || die "cannot upload $name"
done

# What the draft holds is exactly what was attested and checked: the same names, the same bytes.
listing="$(gh api "repos/$REPO/releases/$ID/assets?per_page=100" --jq '.[] | "\(.id) \(.state) \(.name)"')" \
  || die "cannot list the draft's files"
names="$(awk '{ print $3 }' <<<"$listing" | LC_ALL=C sort)"
[[ "$names" == "$(printf '%s\n' "${FILES[@]}")" ]] || die "the draft does not hold exactly the files to publish"
mkdir "$WORK/draft"
while read -r aid state name; do
  [[ "$aid" =~ ^[0-9]+$ && "$state" == uploaded ]] || die "$name is not uploaded completely"
  gh api -H "Accept: application/octet-stream" "repos/$REPO/releases/assets/$aid" > "$WORK/draft/$name" \
    || die "cannot download $name from the draft"
  cmp -s "$WORK/draft/$name" "$ASSETS/$name" || die "$name in the draft differs from the file that was checked"
done <<<"$listing"

state="$(gh api "repos/$REPO/releases/$ID" --jq '"\(.tag_name) \(.draft)"')" || die "cannot read release $ID"
[[ "$state" == "$TAG true" ]] || die "release $ID is no longer a draft of $TAG"
check_tag "before publishing"
out="$(gh api -X PATCH "repos/$REPO/releases/$ID" -F draft=false -f make_latest="$LATEST" \
  --jq '"\(.tag_name) \(.draft) \(.html_url)"')" || die "cannot publish release $ID"
read -r tag draft url <<<"$out"
[[ "$tag $draft" == "$TAG false" ]] || die "release $ID was not published as $TAG"
PUBLISHED=1
log "published $TAG (release $ID, latest: $LATEST)"
echo "$url"
