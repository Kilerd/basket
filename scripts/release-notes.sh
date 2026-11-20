#!/usr/bin/env bash
# Prints the release notes of a version: its `## [X.Y.Z]` section of CHANGELOG.md, without the
# heading and without surrounding blank lines. Fails if the section is missing or empty.
#   scripts/release-notes.sh X.Y.Z
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

WANT="${1:-}"
[[ $# -eq 1 && "$WANT" =~ $SEMVER_RE ]] || die "usage: scripts/release-notes.sh X.Y.Z" 64

rc=0
awk -v ver="$WANT" '
  function is_end(s) { return s ~ /^## / || s ~ /^\[(Unreleased|[0-9]+\.[0-9]+\.[0-9]+)\]: / }
  !found { if ($0 == "## [" ver "]" || index($0, "## [" ver "] ") == 1) found = 1; next }
  is_end($0) { exit }
  { buf[++n] = $0 }
  END {
    if (!found) exit 3
    first = 1; while (first <= n && buf[first] ~ /^[ \t]*$/) first++
    last = n; while (last >= first && buf[last] ~ /^[ \t]*$/) last--
    if (first > last) exit 4
    for (i = first; i <= last; i++) print buf[i]
  }' "$ROOT/CHANGELOG.md" || rc=$?
case "$rc" in
  0) ;;
  3) die "CHANGELOG.md has no '## [$WANT]' section" ;;
  4) die "the '## [$WANT]' section of CHANGELOG.md is empty" ;;
  *) die "cannot read CHANGELOG.md" ;;
esac
