#!/usr/bin/env bash
# Prints the tag of the newest published release `vX.Y.Z` of the repository, or nothing when
# there is none. Drafts and pre-releases don't count: installed copies never see them
# (docs/updates.md). With --below X.Y.Z, the newest one lower than X.Y.Z: the release whose
# installed copies will check X.Y.Z's update signature.
#   scripts/published-release.sh [--below X.Y.Z]
# Needs gh with GH_TOKEN and the repository in GH_REPO or GITHUB_REPOSITORY.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

BELOW=""
case "$#:${1:-}" in
  0:) ;;
  2:--below) BELOW="$2"; [[ "$BELOW" =~ $SEMVER_RE ]] || die "--below needs X.Y.Z" 64 ;;
  *) die "usage: scripts/published-release.sh [--below X.Y.Z]" 64 ;;
esac
REPO="${GH_REPO:-${GITHUB_REPOSITORY:-}}"
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "set GITHUB_REPOSITORY (owner/repo)" 64

tags="$(gh api --paginate "repos/$REPO/releases?per_page=100" \
  --jq '.[] | select(.draft == false and .prerelease == false) | .tag_name')" \
  || die "cannot list the releases of $REPO (gh api)"

best=""
while IFS= read -r tag; do
  v="${tag#v}"
  [[ "$tag" == v* && "$v" =~ $SEMVER_RE ]] || continue
  if [[ -n "$BELOW" && "$(semver_cmp "$v" "$BELOW")" != -1 ]]; then continue; fi
  if [[ -z "$best" || "$(semver_cmp "$v" "$best")" == 1 ]]; then best="$v"; fi
done <<<"$tags"
if [[ -n "$best" ]]; then echo "v$best"; fi
