#!/usr/bin/env bash
# Tests the release scripts (docs/RELEASING.md) in throwaway git repositories with a synthetic
# CHANGELOG.md: release-prep.sh (the first release, patch, minor, major, explicit, invalid input,
# an empty [Unreleased], idempotence), release-notes.sh, release-ci-check.sh (against a stand-in
# for gh), unpack-artifact.sh, update-manifest.sh and release-body.sh; on macOS also the update
# key, signature and check (update-keygen/sign/verify.swift) and make-dmg.sh.
#   scripts/tests/release-prep-test.sh
# Needs bash, git, awk, sed, jq, tar, gzip and shasum. CI runs it on Linux.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# The test repositories ignore the global git config (hooks, signing) and use a test identity.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export RELEASE_DATE=2026-12-01
unset GH_REPO CI_WAIT_MINUTES CI_POLL_SECONDS CI_START_SECONDS
URL=https://github.com/Kilerd/basket

PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); printf 'ok    %s\n' "$1"; }
fail() {
  FAILED=$((FAILED + 1)); printf 'FAIL  %s\n' "$1"
  if [[ -n "${2:-}" ]]; then printf '%s\n' "$2" | sed 's/^/      /'; fi
}

# run <cmd...> — runs a command; its stdout, stderr and exit code land in OUT, ERR and RC.
run() {
  RC=0
  "$@" >"$TMP/out" 2>"$TMP/err" || RC=$?
  OUT="$(cat "$TMP/out")"
  ERR="$(cat "$TMP/err")"
}
expect_rc() { # <name> <code>
  if [[ "$RC" == "$2" ]]; then pass "$1"; else fail "$1" "exit $RC, expected $2; stderr: $ERR"; fi
}
expect_out() { # <name> <stdout>
  if [[ "$OUT" == "$2" ]]; then pass "$1"; else fail "$1" "stdout: '$OUT', expected '$2'; stderr: $ERR"; fi
}
expect_contains() { # <name> <text> <needle>
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1" "missing '$3' in: $2"; fi
}
expect_lacks() { # <name> <text> <needle>
  if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1" "unexpected '$3' in: $2"; fi
}
expect_file() { # <name> <file> <expected-content>
  local d
  if d="$(diff -u <(printf '%s\n' "$3") "$2")"; then pass "$1"; else fail "$1" "$d"; fi
}
version_of() { sed -n 's/^VERSION="\(.*\)"$/\1/p' "$1/scripts/_common.sh"; }
snapshot() { cat "$1/CHANGELOG.md" "$1/scripts/_common.sh" | shasum -a 256; }

# new_repo <dir> <VERSION> <CHANGELOG.md content> — a git repository with the release scripts.
new_repo() {
  local dir="$1"
  mkdir -p "$dir/scripts"
  cp -p "$SRC/scripts/_common.sh" "$SRC/scripts/release-prep.sh" "$SRC/scripts/release-notes.sh" \
    "$SRC/scripts/release-ci-check.sh" "$dir/scripts/"
  sed "s/^VERSION=\"[^\"]*\"\$/VERSION=\"$2\"/" "$SRC/scripts/_common.sh" > "$dir/scripts/_common.sh"
  printf '%s\n' "$3" > "$dir/CHANGELOG.md"
  git -C "$dir" init -q -b main
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "initial"
}
commit() { git -C "$1" add -A; git -C "$1" commit -q -m "$2"; }
tag() { git -C "$1" tag -a "$2" -m "$2"; }
# add_entry <dir> <line> — a bullet under a new `### Changed` right below [Unreleased].
add_entry() {
  awk -v entry="$2" '{ print } /^## \[Unreleased\]$/ { print ""; print "### Changed"; print ""; print entry }' \
    "$1/CHANGELOG.md" > "$TMP/cl" && cat "$TMP/cl" > "$1/CHANGELOG.md"
}

HEAD_TEXT='# Changelog

All notable changes are documented in this file.'

# --- The first release: no tag, VERSION 0.0.1, everything still under [Unreleased] -------------
R="$TMP/first"
new_repo "$R" 0.0.1 "$HEAD_TEXT

## [Unreleased]

The first public version.

### Added

- First feature.
- Release workflow.

[Unreleased]: $URL/compare/v0.0.1...HEAD
[0.0.1]: $URL/releases/tag/v0.0.1"

before="$(snapshot "$R")"
run "$R/scripts/release-prep.sh" patch
expect_rc "first release: a bump without any tag is refused" 1
expect_contains "first release: the refusal names the version to give" "$ERR" "name the first version explicitly"
run "$R/scripts/release-prep.sh" 0.0.0
expect_rc "first release: lower than VERSION is refused" 1
[[ "$(snapshot "$R")" == "$before" ]] && pass "first release: refusals change nothing" || fail "first release: refusals change nothing"

run "$R/scripts/release-prep.sh" --dry-run 0.0.1
expect_rc "first release: dry run" 0
expect_contains "first release: dry run shows the new section" "$OUT" "+## [0.0.1] - 2026-12-01"
[[ "$(snapshot "$R")" == "$before" ]] && pass "first release: dry run writes nothing" || fail "first release: dry run writes nothing"

FIRST_EXPECTED="$HEAD_TEXT

## [Unreleased]

## [0.0.1] - 2026-12-01

The first public version.

### Added

- First feature.
- Release workflow.

[Unreleased]: $URL/compare/v0.0.1...HEAD
[0.0.1]: $URL/releases/tag/v0.0.1"
run "$R/scripts/release-prep.sh" 0.0.1
expect_rc "first release: 0.0.1 (equal to VERSION)" 0
expect_out "first release: prints the version" 0.0.1
expect_file "first release: [0.0.1] cut from [Unreleased], links kept" "$R/CHANGELOG.md" "$FIRST_EXPECTED"
[[ "$(version_of "$R")" == 0.0.1 ]] && pass "first release: VERSION stays 0.0.1" || fail "first release: VERSION stays 0.0.1"
[[ -z "$(git -C "$R" status --porcelain -- scripts)" ]] && pass "first release: scripts/_common.sh untouched" || fail "first release: scripts/_common.sh untouched"
after="$(snapshot "$R")"
run "$R/scripts/release-prep.sh" 0.0.1
expect_rc "first release: second run succeeds" 0
[[ "$(snapshot "$R")" == "$after" ]] && pass "first release: second run changes nothing" || fail "first release: second run changes nothing"
run "$R/scripts/release-notes.sh" 0.0.1
expect_out "first release: release notes" "The first public version.

### Added

- First feature.
- Release workflow."
commit "$R" "chore(release): v0.0.1"
FIRST_RELEASE_COMMIT="$(git -C "$R" rev-parse HEAD)"
tag "$R" v0.0.1

# The same without any link definitions: they are added.
R2="$TMP/first-nolinks"
new_repo "$R2" 0.0.1 "$HEAD_TEXT

## [Unreleased]

The first public version.

### Added

- First feature.
- Release workflow."
run "$R2/scripts/release-prep.sh" 0.0.1
expect_file "first release without links: links added" "$R2/CHANGELOG.md" "$FIRST_EXPECTED"

# --- patch, idempotence, the prepared-but-untagged guard ------------------------------------
add_entry "$R" "- Faster lists."
run "$R/scripts/release-prep.sh" 0.0.1
expect_rc "after v0.0.1: the same version again is refused" 1
before="$(snapshot "$R")"
run "$R/scripts/release-prep.sh" --dry-run patch
expect_rc "patch: dry run" 0
expect_contains "patch: dry run shows the section" "$OUT" "+## [0.0.2] - 2026-12-01"
expect_contains "patch: dry run shows VERSION" "$OUT" '+VERSION="0.0.2"'
[[ "$(snapshot "$R")" == "$before" ]] && pass "patch: dry run writes nothing" || fail "patch: dry run writes nothing"
run "$R/scripts/release-prep.sh" patch
expect_out "patch: 0.0.1 → 0.0.2" 0.0.2
expect_file "patch: CHANGELOG.md" "$R/CHANGELOG.md" "$HEAD_TEXT

## [Unreleased]

## [0.0.2] - 2026-12-01

### Changed

- Faster lists.

## [0.0.1] - 2026-12-01

The first public version.

### Added

- First feature.
- Release workflow.

[Unreleased]: $URL/compare/v0.0.2...HEAD
[0.0.2]: $URL/compare/v0.0.1...v0.0.2
[0.0.1]: $URL/releases/tag/v0.0.1"
[[ "$(version_of "$R")" == 0.0.2 ]] && pass "patch: VERSION 0.0.2" || fail "patch: VERSION 0.0.2"
after="$(snapshot "$R")"
run "$R/scripts/release-prep.sh" 0.0.2
expect_out "patch: running it again with 0.0.2" 0.0.2
run "$R/scripts/release-prep.sh" patch
expect_out "patch: running it again with patch" 0.0.2
[[ "$(snapshot "$R")" == "$after" ]] && pass "patch: second runs change nothing" || fail "patch: second runs change nothing"
run "$R/scripts/release-notes.sh" 0.0.2
expect_out "patch: release notes" "### Changed

- Faster lists."
commit "$R" "chore(release): v0.0.2"
PATCH_RELEASE_COMMIT="$(git -C "$R" rev-parse HEAD)"
add_entry "$R" "- Pending change."
commit "$R" "docs: pending change"
run "$R/scripts/release-prep.sh" 0.0.2
expect_rc "prepared 0.0.2 with new entries: tagging it is allowed" 0
expect_contains "prepared 0.0.2 with new entries: they stay under [Unreleased]" "$ERR" "stay there for the next release"
run "$R/scripts/release-prep.sh" minor
expect_rc "prepared 0.0.2 untagged: minor is refused" 1
expect_contains "prepared 0.0.2 untagged: says to release 0.0.2 first" "$ERR" "release 0.0.2 first"
tag "$R" v0.0.2

# --- minor, major, explicit ----------------------------------------------------------------
run "$R/scripts/release-prep.sh" 0.0.2
expect_rc "explicit: equal to the latest tag is refused" 1
run "$R/scripts/release-prep.sh" 0.0.1
expect_rc "explicit: lower than the latest tag is refused" 1
run "$R/scripts/release-prep.sh" minor
expect_out "minor: 0.0.2 → 0.1.0" 0.1.0
expect_contains "minor: section" "$(cat "$R/CHANGELOG.md")" "## [Unreleased]

## [0.1.0] - 2026-12-01

### Changed

- Pending change.

## [0.0.2] - 2026-12-01"
expect_contains "minor: links" "$(cat "$R/CHANGELOG.md")" "[Unreleased]: $URL/compare/v0.1.0...HEAD
[0.1.0]: $URL/compare/v0.0.2...v0.1.0
[0.0.2]: $URL/compare/v0.0.1...v0.0.2"
[[ "$(version_of "$R")" == 0.1.0 ]] && pass "minor: VERSION 0.1.0" || fail "minor: VERSION 0.1.0"
commit "$R" "chore(release): v0.1.0"; tag "$R" v0.1.0
add_entry "$R" "- Breaking change."
run "$R/scripts/release-prep.sh" major
expect_out "major: 0.1.0 → 1.0.0" 1.0.0
expect_contains "major: link" "$(cat "$R/CHANGELOG.md")" "[1.0.0]: $URL/compare/v0.1.0...v1.0.0"
commit "$R" "chore(release): v1.0.0"; tag "$R" v1.0.0
add_entry "$R" "- Another change."
run "$R/scripts/release-prep.sh" 1.2.0
expect_out "explicit: 1.2.0" 1.2.0
expect_contains "explicit: section and link" "$(cat "$R/CHANGELOG.md")" "## [1.2.0] - 2026-12-01"
expect_contains "explicit: link" "$(cat "$R/CHANGELOG.md")" "[1.2.0]: $URL/compare/v1.0.0...v1.2.0"
[[ "$(version_of "$R")" == 1.2.0 ]] && pass "explicit: VERSION 1.2.0" || fail "explicit: VERSION 1.2.0"
git -C "$R" checkout -q -- .

# --- invalid input -------------------------------------------------------------------------
before="$(snapshot "$R")"
for bad in 1.2 v1.2.3 1.2.3-rc.1 01.2.3 1.02.3 1.2.3.4 latest " 1.2.3" "" "--bogus"; do
  run "$R/scripts/release-prep.sh" "$bad"
  expect_rc "invalid: '$bad' is refused (64)" 64
done
run "$R/scripts/release-prep.sh"
expect_rc "invalid: no argument (64)" 64
run "$R/scripts/release-prep.sh" --dry-run
expect_rc "invalid: --dry-run alone (64)" 64
run "$R/scripts/release-prep.sh" patch minor
expect_rc "invalid: two versions (64)" 64
run "$R/scripts/release-prep.sh" $'1.2.3\n::error::x'
expect_rc "invalid: a newline in the input (64)" 64
expect_lacks "invalid: input is not echoed raw" "$ERR" $'\n::error::'
[[ "$(snapshot "$R")" == "$before" ]] && pass "invalid: nothing changed" || fail "invalid: nothing changed"

# --- an empty [Unreleased] -----------------------------------------------------------------
E="$TMP/empty"
new_repo "$E" 0.0.1 "$HEAD_TEXT

## [Unreleased]

## [0.0.1] - 2026-11-20

- First feature.

[Unreleased]: $URL/compare/v0.0.1...HEAD
[0.0.1]: $URL/releases/tag/v0.0.1"
run "$E/scripts/release-prep.sh" --dry-run 0.0.1
expect_rc "prepared already: dry run of VERSION" 0
expect_out "prepared already: dry run shows no diff" ""
tag "$E" v0.0.1
before="$(snapshot "$E")"
run "$E/scripts/release-prep.sh" patch
expect_rc "empty [Unreleased]: refused" 1
expect_contains "empty [Unreleased]: says so" "$ERR" "has no entries"
awk '{ print } /^## \[Unreleased\]$/ { print ""; print "### Added"; print "" }' "$E/CHANGELOG.md" > "$TMP/cl"
cat "$TMP/cl" > "$E/CHANGELOG.md"
before="$(snapshot "$E")"
run "$E/scripts/release-prep.sh" patch
expect_rc "[Unreleased] with only a heading: refused" 1
[[ "$(snapshot "$E")" == "$before" ]] && pass "empty [Unreleased]: nothing changed" || fail "empty [Unreleased]: nothing changed"

# --- release-notes.sh ----------------------------------------------------------------------
run "$E/scripts/release-notes.sh" 0.0.1
expect_out "notes: the section without heading" "- First feature."
run "$E/scripts/release-notes.sh" 0.0.9
expect_rc "notes: a missing section fails" 1
run "$E/scripts/release-notes.sh" v0.0.1
expect_rc "notes: v0.0.1 is not a version (64)" 64
N="$TMP/notes-empty"
new_repo "$N" 0.0.2 "$HEAD_TEXT

## [Unreleased]

## [0.0.2] - 2026-12-01

## [0.0.1] - 2026-11-20

- First feature."
run "$N/scripts/release-notes.sh" 0.0.2
expect_rc "notes: an empty section fails" 1
run "$N/scripts/release-notes.sh" 0.0.1
expect_out "notes: the last section ends at the end of the file" "- First feature."

# --- release-ci-check.sh, with a stand-in for gh -------------------------------------------
mkdir -p "$TMP/bin" "$TMP/runs"
cat > "$TMP/bin/gh" <<'GH'
#!/bin/sh
# Stand-in for `gh api …/runs?head_sha=<sha>…`: prints $FAKE_RUNS/<sha>, or "none".
[ -z "${FAKE_GH_FAIL:-}" ] || exit 1
for a in "$@"; do
  case "$a" in *head_sha=*)
    sha="${a#*head_sha=}"; sha="${sha%%&*}"
    if [ -f "$FAKE_RUNS/$sha" ]; then cat "$FAKE_RUNS/$sha"; else echo none; fi
    exit 0 ;;
  esac
done
exit 2
GH
chmod +x "$TMP/bin/gh"
export FAKE_RUNS="$TMP/runs"
ci() { # <name> <commit> <want-rc> [<want-stdout>]
  run env PATH="$TMP/bin:$PATH" GITHUB_REPOSITORY=Kilerd/basket CI_WAIT_MINUTES=0 CI_POLL_SECONDS=0 CI_START_SECONDS=0 \
    "$R/scripts/release-ci-check.sh" "$2"
  expect_rc "$1" "$3"
  if [[ -n "${4:-}" ]]; then expect_out "$1: counted commit" "$4"; fi
}
runs() { printf '%s\n' "$2" > "$TMP/runs/$1"; }
noruns() { rm -f "$TMP/runs/$1"; }
INITIAL="$(git -C "$R" rev-list --max-parents=0 HEAD)"
git -C "$R" checkout -q -b code
mkdir -p "$R/Sources"; echo "// code" > "$R/Sources/x.swift"; commit "$R" "feat: code"
CODE_COMMIT="$(git -C "$R" rev-parse HEAD)"
sed 's/^SCRATCH=/SCRATCH_X=/' "$R/scripts/_common.sh" > "$TMP/c" && cat "$TMP/c" > "$R/scripts/_common.sh"; commit "$R" "chore: not only VERSION"
OTHER_LINE_COMMIT="$(git -C "$R" rev-parse HEAD)"

runs "$INITIAL" "completed success https://ci/1"
ci "ci: own run succeeded" "$INITIAL" 0 "$INITIAL"
runs "$INITIAL" "completed failure https://ci/1"
ci "ci: own run failed" "$INITIAL" 1
runs "$INITIAL" "completed success https://ci/1"
noruns "$FIRST_RELEASE_COMMIT"
ci "ci: release commit (CHANGELOG only) without a run: the parent counts" "$FIRST_RELEASE_COMMIT" 0 "$INITIAL"
runs "$INITIAL" "completed failure https://ci/1"
ci "ci: release commit, parent failed" "$FIRST_RELEASE_COMMIT" 1
runs "$INITIAL" "completed success https://ci/1"
runs "$FIRST_RELEASE_COMMIT" "completed failure https://ci/2"
ci "ci: release commit with its own failed run" "$FIRST_RELEASE_COMMIT" 1
runs "$FIRST_RELEASE_COMMIT" "in_progress none https://ci/2"
ci "ci: release commit whose run is still going: the parent counts" "$FIRST_RELEASE_COMMIT" 0 "$INITIAL"
PATCH_PARENT="$(git -C "$R" rev-parse "$PATCH_RELEASE_COMMIT^")"
runs "$PATCH_PARENT" "completed success https://ci/3"
ci "ci: release commit (CHANGELOG and VERSION): the parent counts" "$PATCH_RELEASE_COMMIT" 0 "$PATCH_PARENT"
ci "ci: a code commit without a run" "$CODE_COMMIT" 1
runs "$CODE_COMMIT" "in_progress none https://ci/4"
ci "ci: a code commit whose run has not finished" "$CODE_COMMIT" 1
runs "$CODE_COMMIT" "completed success https://ci/4"
ci "ci: a code commit with a passed run" "$CODE_COMMIT" 0 "$CODE_COMMIT"
ci "ci: a change to _common.sh besides VERSION is no release commit" "$OTHER_LINE_COMMIT" 1
export FAKE_GH_FAIL=1
ci "ci: gh failing fails" "$INITIAL" 1
unset FAKE_GH_FAIL
run env PATH="$TMP/bin:$PATH" GITHUB_REPOSITORY= "$R/scripts/release-ci-check.sh" HEAD
expect_rc "ci: no repository (64)" 64

# --- unpack-artifact.sh --------------------------------------------------------------------
U="$TMP/unpack"
mkdir -p "$U/src/Basket.app/Contents/MacOS"
echo plist > "$U/src/Basket.app/Contents/Info.plist"
echo bin > "$U/src/Basket.app/Contents/MacOS/Basket"
COPYFILE_DISABLE=1 tar -cf "$U/app.tar" -C "$U/src" Basket.app
SHA="$(shasum -a 256 "$U/app.tar" | cut -d' ' -f1)"
ALLOW='^Basket\.app(/[^/]+)*$'
run "$SRC/scripts/unpack-artifact.sh" "$U/app.tar" "$SHA" "$U/out" "$ALLOW"
expect_rc "unpack: the expected tar" 0
[[ -f "$U/out/Basket.app/Contents/MacOS/Basket" ]] && pass "unpack: files in place" || fail "unpack: files in place"
run "$SRC/scripts/unpack-artifact.sh" "$U/app.tar" "$SHA" "$U/out" "$ALLOW"
expect_rc "unpack: refuses a non-empty destination" 1
run "$SRC/scripts/unpack-artifact.sh" "$U/app.tar" "$(printf '0%.0s' $(seq 64))" "$U/out2" "$ALLOW"
expect_rc "unpack: refuses another sha256" 1
echo x > "$U/src/evil.txt"
COPYFILE_DISABLE=1 tar -cf "$U/evil.tar" -C "$U/src" Basket.app evil.txt
run "$SRC/scripts/unpack-artifact.sh" "$U/evil.tar" "$(shasum -a 256 "$U/evil.tar" | cut -d' ' -f1)" "$U/out3" "$ALLOW"
expect_rc "unpack: refuses an unexpected member" 1
[[ ! -e "$U/out3" ]] && pass "unpack: refused tar left nothing" || fail "unpack: refused tar left nothing"
ln -s /etc "$U/src/Basket.app/Contents/link"
COPYFILE_DISABLE=1 tar -cf "$U/link.tar" -C "$U/src" Basket.app
run "$SRC/scripts/unpack-artifact.sh" "$U/link.tar" "$(shasum -a 256 "$U/link.tar" | cut -d' ' -f1)" "$U/out4" "$ALLOW"
expect_rc "unpack: refuses a symlink" 1
rm "$U/src/Basket.app/Contents/link"
gzip -c "$U/app.tar" > "$U/app.tar.gz"
run "$SRC/scripts/unpack-artifact.sh" "$U/app.tar.gz" "$(shasum -a 256 "$U/app.tar.gz" | cut -d' ' -f1)" "$U/out5" "$ALLOW"
expect_rc "unpack: refuses a compressed tar" 1

# --- update-manifest.sh and release-body.sh --------------------------------------------------
M="$TMP/manifest"
mkdir -p "$M"
printf 'zip bytes' > "$M/Basket-0.0.1-arm64.zip"
printf '### Added\n\n- "Quoted" feature.\n\n' > "$M/notes.md"
SIG="$(printf 'A%.0s' $(seq 86))=="
MURL="$URL/releases/download/v0.0.1/Basket-0.0.1-arm64.zip"
run env UPDATE_PUB_DATE=2026-12-01T10:00:00Z "$SRC/scripts/update-manifest.sh" 0.0.1 "$M/Basket-0.0.1-arm64.zip" "$SIG" "$M/notes.md" 26.0 "$MURL"
expect_rc "manifest: written" 0
ZSHA="$(shasum -a 256 "$M/Basket-0.0.1-arm64.zip" | cut -d' ' -f1)"
want="$(jq -cn --arg s "$ZSHA" --arg sig "$SIG" --arg url "$MURL" \
  '{version: "0.0.1", pub_date: "2026-12-01T10:00:00Z", notes: "### Added\n\n- \"Quoted\" feature.", minimum_system_version: "26.0", url: $url, sha256: $s, signature: $sig}')"
[[ "$(printf '%s' "$OUT" | jq -c .)" == "$want" ]] && pass "manifest: the contract's fields" || fail "manifest: the contract's fields" "$OUT"
run "$SRC/scripts/update-manifest.sh" 0.0.1 "$M/Basket-0.0.1-arm64.zip" "$SIG" "$M/notes.md" 26.0 "https://example.com/Basket-0.0.1-arm64.zip"
expect_rc "manifest: refuses a URL outside GitHub releases" 1
run "$SRC/scripts/update-manifest.sh" 0.0.1 "$M/Basket-0.0.1-arm64.zip" "$SIG" "$M/notes.md" 26.0 "$URL/releases/download/v0.0.2/Basket-0.0.1-arm64.zip"
expect_rc "manifest: refuses another version's URL" 1
run "$SRC/scripts/update-manifest.sh" 0.0.1 "$M/Basket-0.0.1-arm64.zip" "short==" "$M/notes.md" 26.0 "$MURL"
expect_rc "manifest: refuses a malformed signature" 1

printf '%s  Basket-0.0.1.dmg\n' "$ZSHA" > "$M/SHA256SUMS"
run "$SRC/scripts/release-body.sh" 0.0.1 signed "$M/notes.md" "$M/SHA256SUMS"
expect_rc "body: signed" 0
expect_contains "body: early-release note" "$OUT" "Early release"
expect_contains "body: notes" "$OUT" '- "Quoted" feature.'
expect_contains "body: notarized" "$OUT" "notarized by Apple"
expect_contains "body: checksums" "$OUT" "$ZSHA  Basket-0.0.1.dmg"
expect_contains "body: attestation check" "$OUT" "--source-ref refs/tags/v0.0.1"
expect_lacks "body: signed has no quarantine advice" "$OUT" "xattr"
run "$SRC/scripts/release-body.sh" 0.0.1 adhoc "$M/notes.md" "$M/SHA256SUMS"
expect_contains "body: ad hoc explains Gatekeeper" "$OUT" "xattr -dr com.apple.quarantine /Applications/Basket.app"
expect_contains "body: ad hoc points to #7" "$OUT" "$URL/issues/7"
run "$SRC/scripts/release-body.sh" 1.0.0 signed "$M/notes.md" "$M/SHA256SUMS"
expect_lacks "body: 1.0.0 is no early release" "$OUT" "Early release"

# --- macOS only: the update signature end to end, the DMG ------------------------------------
if [[ "$(uname -s)" == Darwin ]] && command -v swift >/dev/null 2>&1; then
  K="$TMP/keys"
  mkdir -p "$K"
  run swift "$SRC/scripts/update-keygen.swift" "$K/update.key"
  expect_rc "update: keygen" 0
  PUB="$OUT"
  run env BASKET_UPDATE_SIGNING_KEY="$(cat "$K/update.key")" swift "$SRC/scripts/update-sign.swift" "$M/Basket-0.0.1-arm64.zip"
  expect_rc "update: sign" 0
  USIG="$OUT"
  expect_lacks "update: the key is never printed" "$OUT$ERR" "$(cat "$K/update.key")"
  run swift "$SRC/scripts/update-verify.swift" "$M/Basket-0.0.1-arm64.zip" "$USIG" "$PUB"
  expect_rc "update: the signature verifies with the public key" 0
  printf 'other bytes' > "$M/other.zip"
  run swift "$SRC/scripts/update-verify.swift" "$M/other.zip" "$USIG" "$PUB"
  expect_rc "update: not for other bytes" 1
  run swift "$SRC/scripts/update-keygen.swift" "$K/other.key"
  run swift "$SRC/scripts/update-verify.swift" "$M/Basket-0.0.1-arm64.zip" "$USIG" "$OUT"
  expect_rc "update: not with another key" 1
  run env UPDATE_PUB_DATE=2026-12-01T10:00:00Z "$SRC/scripts/update-manifest.sh" 0.0.1 "$M/Basket-0.0.1-arm64.zip" "$USIG" "$M/notes.md" 26.0 "$MURL"
  expect_rc "update: a real signature fits the manifest" 0

  if command -v hdiutil >/dev/null 2>&1; then
    run "$SRC/scripts/make-dmg.sh" "$U/src/Basket.app" "$TMP/Basket-0.0.1.dmg" "Basket 0.0.1"
    expect_rc "dmg: made and verified" 0
  fi
else
  echo "skip  update signature and DMG tests (macOS only)"
fi

echo
echo "release scripts: $PASSED passed, $FAILED failed"
(( FAILED == 0 ))
