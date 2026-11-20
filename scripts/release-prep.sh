#!/usr/bin/env bash
# Prepares a release in this checkout (docs/RELEASING.md): picks the version, moves the entries
# under `## [Unreleased]` in CHANGELOG.md into `## [X.Y.Z] - YYYY-MM-DD` (UTC), leaves an empty
# `## [Unreleased]`, updates the compare links at the bottom and sets VERSION in
# scripts/_common.sh. It commits and tags nothing.
#
#   scripts/release-prep.sh [--dry-run] <patch|minor|major|X.Y.Z>
#
# - patch/minor/major bump the latest vX.Y.Z tag. Without any tag, name the first version
#   explicitly (e.g. 0.0.1).
# - X.Y.Z must be greater than the latest tag and not lower than VERSION.
# - A new section needs entries under [Unreleased]. If CHANGELOG.md already has the version's
#   section (prepared in a pull request), nothing is moved: only VERSION and the links are made
#   to match. A second run therefore changes nothing.
#
# Prints the version on stdout. --dry-run prints the diff instead and writes nothing.
# RELEASE_DATE=YYYY-MM-DD replaces today's UTC date (tests).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

CHANGELOG="$ROOT/CHANGELOG.md"
COMMON="$ROOT/scripts/_common.sh"
DEFAULT_REPO_URL="https://github.com/Kilerd/basket"
USAGE="usage: scripts/release-prep.sh [--dry-run] <patch|minor|major|X.Y.Z>"

DRY_RUN=0
ARG=""
NARGS=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    *) ARG="$a"; NARGS=$((NARGS + 1)) ;;
  esac
done
[[ "$NARGS" == 1 && -n "$ARG" ]] || die "$USAGE" 64

# safe <text> — for messages: input comes from a workflow form, so no control characters.
safe() { local s="$1"; s="${s//[^A-Za-z0-9._+-]/?}"; printf '%s' "${s:0:40}"; }
is_semver() { [[ "$1" =~ $SEMVER_RE ]]; }
# semver_cmp <a> <b> — prints -1, 0 or 1.
semver_cmp() {
  local a b i
  IFS=. read -r -a a <<<"$1"
  IFS=. read -r -a b <<<"$2"
  for i in 0 1 2; do
    if (( a[i] > b[i] )); then echo 1; return; fi
    if (( a[i] < b[i] )); then echo -1; return; fi
  done
  echo 0
}
has_tag() { git -C "$ROOT" rev-parse -q --verify "refs/tags/v$1" >/dev/null; }
has_section() { grep -qE "^## \[${1//./[.]}\]( |$)" "$CHANGELOG"; }

git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "$ROOT is not a git checkout: the latest vX.Y.Z tag decides the next version"
[[ -f "$CHANGELOG" ]] || die "no CHANGELOG.md in $ROOT"

# The latest release tag (vX.Y.Z only; other tags are ignored).
LAST=""
while IFS= read -r tag; do
  v="${tag#v}"
  is_semver "$v" || continue
  if [[ -z "$LAST" || "$(semver_cmp "$v" "$LAST")" == 1 ]]; then LAST="$v"; fi
done < <(git -C "$ROOT" tag --list 'v*')

[[ "$(grep -c '^VERSION="' "$COMMON" || true)" == 1 ]] \
  || die "scripts/_common.sh must have exactly one VERSION=\"X.Y.Z\" line"
CURRENT="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$COMMON")"
is_semver "$CURRENT" || die "VERSION in scripts/_common.sh is not X.Y.Z"

case "$ARG" in
  patch|minor|major)
    [[ -n "$LAST" ]] || die "there is no vX.Y.Z tag yet: name the first version explicitly (VERSION is $CURRENT)"
    IFS=. read -r MAJ MIN PAT <<<"$LAST"
    case "$ARG" in
      patch) TARGET="$MAJ.$MIN.$((PAT + 1))" ;;
      minor) TARGET="$MAJ.$((MIN + 1)).0" ;;
      major) TARGET="$((MAJ + 1)).0.0" ;;
    esac ;;
  *)
    is_semver "$ARG" \
      || die "invalid version '$(safe "$ARG")': expected patch, minor, major or X.Y.Z (no leading zeros, no suffix)" 64
    TARGET="$ARG" ;;
esac

if [[ -n "$LAST" && "$(semver_cmp "$TARGET" "$LAST")" != 1 ]]; then
  die "$TARGET is not greater than the latest tag v$LAST"
fi
if [[ "$(semver_cmp "$TARGET" "$CURRENT")" == -1 ]]; then
  die "$TARGET is lower than VERSION ($CURRENT) in scripts/_common.sh"
fi
if has_tag "$TARGET"; then die "the tag v$TARGET exists already"; fi
# Never skip a version that was prepared (it has a section) but not tagged.
if [[ "$TARGET" != "$CURRENT" ]] && has_section "$CURRENT" && ! has_tag "$CURRENT"; then
  die "VERSION $CURRENT has a CHANGELOG.md section but no tag v$CURRENT: release $CURRENT first"
fi

DATE="${RELEASE_DATE:-$(date -u +%Y-%m-%d)}"
[[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "RELEASE_DATE must be YYYY-MM-DD" 64
REPO_URL="$(sed -n -E 's#^\[Unreleased\]: (https://[^ ]+)/compare/.*#\1#p' "$CHANGELOG" | head -n 1)"
REPO_URL="${REPO_URL:-$DEFAULT_REPO_URL}"
UNRELEASED_LINK="[Unreleased]: $REPO_URL/compare/v$TARGET...HEAD"
if [[ -n "$LAST" ]]; then
  VERSION_LINK="[$TARGET]: $REPO_URL/compare/v$LAST...v$TARGET"
else
  VERSION_LINK="[$TARGET]: $REPO_URL/releases/tag/v$TARGET"
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# CHANGELOG.md: the Unreleased section ends at the next `## ` heading or the link definitions.
rc=0
awk -v ver="$TARGET" -v date="$DATE" -v ulink="$UNRELEASED_LINK" -v vlink="$VERSION_LINK" \
    -v status="$TMP/status" '
  function is_link(s) { return s ~ /^\[(Unreleased|[0-9]+\.[0-9]+\.[0-9]+)\]: / }
  { line[NR] = $0 }
  END {
    n = NR; u = 0
    for (i = 1; i <= n; i++) if (line[i] ~ /^## \[Unreleased\][ \t]*$/) { if (u) exit 5; u = i }
    if (!u) exit 2
    e = n + 1
    for (i = u + 1; i <= n; i++) if (line[i] ~ /^## / || is_link(line[i])) { e = i; break }
    entries = 0; first = 0; last = 0
    for (i = u + 1; i < e; i++) {
      if (line[i] ~ /^[ \t]*$/) continue
      if (!first) first = i
      last = i
      if (line[i] !~ /^### /) entries = 1
    }
    head = "## [" ver "]"; vprefix = "[" ver "]: "
    has = 0; has_vlink = 0
    for (i = 1; i <= n; i++) {
      if (line[i] == head || index(line[i], head " ") == 1) has = 1
      if (index(line[i], vprefix) == 1) has_vlink = 1
    }
    if (!has && !entries) exit 3
    print (has ? "existing" : "new"), entries > status

    for (i = 1; i <= u; i++) print line[i]
    start = u + 1
    if (!has) {
      print ""
      print head " - " date
      print ""
      for (i = first; i <= last; i++) print line[i]
      if (e <= n) print ""
      start = e
    }
    seen_u = 0; seen_v = 0; prev = line[u]
    for (i = start; i <= n; i++) {
      if (index(line[i], "[Unreleased]: ") == 1) {
        if (seen_u) continue
        print ulink; seen_u = 1
        if (!has_vlink && !seen_v) { print vlink; seen_v = 1 }
        continue
      }
      if (index(line[i], vprefix) == 1) {
        if (!seen_v) { print vlink; seen_v = 1 }
        continue
      }
      print line[i]; prev = line[i]
    }
    if (!seen_u) {
      if (prev !~ /^[ \t]*$/ && !is_link(prev)) print ""
      print ulink
      if (!seen_v) print vlink
    }
  }' "$CHANGELOG" > "$TMP/CHANGELOG.md" || rc=$?
case "$rc" in
  0) ;;
  2) die "CHANGELOG.md has no '## [Unreleased]' heading" ;;
  3) die "nothing to release: '## [Unreleased]' in CHANGELOG.md has no entries (add what changed first)" ;;
  5) die "CHANGELOG.md has more than one '## [Unreleased]' heading" ;;
  *) die "could not rewrite CHANGELOG.md" ;;
esac
read -r SECTION PENDING < "$TMP/status"
if [[ "$SECTION" == existing && "$PENDING" == 1 ]]; then
  log "note: CHANGELOG.md has a [$TARGET] section already; the entries under [Unreleased] stay there for the next release"
fi

sed "s/^VERSION=\"[^\"]*\"\$/VERSION=\"$TARGET\"/" "$COMMON" > "$TMP/_common.sh"

# show_diff <label> <old> <new> — unified diff; diff exits 1 when the files differ.
show_diff() { diff -u -L "a/$1" -L "b/$1" "$2" "$3" || [[ $? == 1 ]]; }

if (( DRY_RUN )); then
  show_diff CHANGELOG.md "$CHANGELOG" "$TMP/CHANGELOG.md"
  show_diff scripts/_common.sh "$COMMON" "$TMP/_common.sh"
  if cmp -s "$CHANGELOG" "$TMP/CHANGELOG.md" && cmp -s "$COMMON" "$TMP/_common.sh"; then
    log "dry run: $TARGET is prepared already (no changes)"
  else
    log "dry run: would prepare $TARGET (latest tag: ${LAST:+v}${LAST:-none})"
  fi
  exit 0
fi

CHANGED=""
# Rewrite in place (cat keeps the files' modes).
if ! cmp -s "$CHANGELOG" "$TMP/CHANGELOG.md"; then cat "$TMP/CHANGELOG.md" > "$CHANGELOG"; CHANGED+=" CHANGELOG.md"; fi
if ! cmp -s "$COMMON" "$TMP/_common.sh"; then cat "$TMP/_common.sh" > "$COMMON"; CHANGED+=" scripts/_common.sh"; fi
if [[ -n "$CHANGED" ]]; then
  log "prepared $TARGET (latest tag: ${LAST:+v}${LAST:-none}; changed:$CHANGED)"
else
  log "$TARGET is prepared already (no changes)"
fi
echo "$TARGET"
