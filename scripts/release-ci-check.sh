#!/usr/bin/env bash
# Checks that CI (.github/workflows/ci.yml) passed on a commit before it is released
# (docs/RELEASING.md, "What a release requires").
#   scripts/release-ci-check.sh <commit>
#
# The commit's newest CI run decides; a run still in progress is awaited. A release-only commit
# (one parent; changes nothing but CHANGELOG.md and the VERSION line of scripts/_common.sh, like
# the workflow's `chore(release): vX.Y.Z` commit) without a finished run of its own is judged by
# its parent's run instead: the workflow pushes that commit with GITHUB_TOKEN, which starts no CI.
#
# Prints the commit whose run counted. Needs gh with GH_TOKEN (actions: read) and the repository
# in GH_REPO or GITHUB_REPOSITORY. CI_WAIT_MINUTES (default 45) and CI_POLL_SECONDS (default 30)
# bound the wait; a commit without any run is given CI_START_SECONDS (default 120) to get one.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

REF="${1:-}"
[[ $# -eq 1 && -n "$REF" ]] || die "usage: scripts/release-ci-check.sh <commit>" 64
REPO="${GH_REPO:-${GITHUB_REPOSITORY:-}}"
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "set GITHUB_REPOSITORY (owner/repo)" 64
WAIT_MINUTES="${CI_WAIT_MINUTES:-45}"
POLL_SECONDS="${CI_POLL_SECONDS:-30}"
START_SECONDS="${CI_START_SECONDS:-120}"
[[ "$WAIT_MINUTES$POLL_SECONDS$START_SECONDS" =~ ^[0-9]+$ ]] || die "CI_*_MINUTES/SECONDS must be numbers" 64

SHA="$(git -C "$ROOT" rev-parse --verify --quiet "$REF^{commit}")" || die "unknown commit"

# ci_run <sha> — "<status> <conclusion> <url>" of the commit's newest CI run, or "none".
ci_run() {
  gh api "repos/$REPO/actions/workflows/ci.yml/runs?head_sha=$1&per_page=100" --jq '
    .workflow_runs | if length == 0 then "none"
    else (sort_by(.created_at) | last | "\(.status) \(.conclusion // "none") \(.html_url)") end'
}

# settle <sha> — the newest run once it has finished, or its state when the wait is over.
settle() {
  local sha="$1" state now started noted=0
  started="$(date +%s)"
  while :; do
    state="$(ci_run "$sha")" || die "cannot read the CI runs of ${sha:0:12} (gh api)"
    case "$state" in "completed "*) break ;; esac
    now="$(date +%s)"
    if [[ "$state" == none ]] && (( now - started >= START_SECONDS )); then break; fi
    (( now - started < WAIT_MINUTES * 60 )) || break
    if (( !noted )); then
      log "CI on ${sha:0:12}: ${state%% *}; waiting (up to $WAIT_MINUTES min)"
      noted=1
    fi
    sleep "$POLL_SECONDS"
  done
  printf '%s\n' "$state"
}

# release_only <sha> — one parent, and only CHANGELOG.md and the VERSION line changed.
release_only() {
  local sha="$1" parents files f bad
  parents="$(git -C "$ROOT" rev-list --parents -n 1 "$sha" | wc -w | tr -d '[:space:]')"
  [[ "$parents" == 2 ]] || return 1
  files="$(git -C "$ROOT" diff --name-only "$sha^" "$sha")"
  [[ -n "$files" ]] || return 1
  while IFS= read -r f; do
    case "$f" in CHANGELOG.md|scripts/_common.sh) ;; *) return 1 ;; esac
  done <<<"$files"
  bad="$(git -C "$ROOT" diff -U0 "$sha^" "$sha" -- scripts/_common.sh \
    | sed -n -e '/^+++ /d' -e '/^--- /d' -e '/^[-+]/p' \
    | grep -vE '^[-+]VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' || true)"
  [[ -z "$bad" ]]
}

state="$(ci_run "$SHA")" || die "cannot read the CI runs of ${SHA:0:12} (gh api)"
COUNTED="$SHA"
if [[ "$state" != "completed "* ]] && release_only "$SHA"; then
  COUNTED="$(git -C "$ROOT" rev-parse "$SHA^")"
  log "${SHA:0:12} is a release-only commit (CHANGELOG.md, VERSION) with no finished CI run: its parent ${COUNTED:0:12} decides"
  state="$(settle "$COUNTED")"
elif [[ "$state" != "completed "* ]]; then
  state="$(settle "$SHA")"
fi

read -r status conclusion url <<<"$state"
[[ "$state" != none ]] || die "no CI run for ${COUNTED:0:12}: only a commit that went through CI on GitHub is released"
[[ "$status" == completed ]] || die "CI on ${COUNTED:0:12} has not finished ($status after $WAIT_MINUTES min): $url"
[[ "$conclusion" == success ]] || die "CI on ${COUNTED:0:12} concluded '$conclusion': $url"
log "CI passed on ${COUNTED:0:12}: $url"
echo "$COUNTED"
