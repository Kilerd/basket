#!/usr/bin/env bash
# Tests the release scripts (docs/RELEASING.md) in throwaway git repositories with a synthetic
# CHANGELOG.md: release-prep.sh (the first release, patch, minor, major, explicit, the major
# version cap, invalid input, an empty [Unreleased], idempotence), release-notes.sh,
# release-ci-check.sh, update-keys.sh (the trusted update keys of a revision),
# published-release.sh and release-publish.sh (the tag guard, the release id, "latest") against
# stand-ins for gh, unpack-artifact.sh, update-manifest.sh and release-body.sh; on macOS also the
# update key, signature and check (update-keygen/sign/verify.swift) and make-dmg.sh.
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
    "$SRC/scripts/release-ci-check.sh" "$SRC/scripts/update-keys.sh" "$SRC/scripts/published-release.sh" \
    "$SRC/scripts/release-publish.sh" "$dir/scripts/"
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
run "$R/scripts/release-prep.sh" 1.0.0
expect_rc "first release: an exact 1.0.0 while VERSION is 0.x is refused" 1
expect_contains "first release: the refusal points to major" "$ERR" "use \`major\`"
run "$R/scripts/release-prep.sh" 999999999.0.0
expect_rc "first release: an absurd major version is refused" 1
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
before="$(snapshot "$R")"
run "$R/scripts/release-prep.sh" 1.0.0
expect_rc "major cap: an exact 1.0.0 after v0.1.0 is refused" 1
run "$R/scripts/release-prep.sh" 2.0.0
expect_rc "major cap: 2.0.0 after v0.1.0 is refused" 1
[[ "$(snapshot "$R")" == "$before" ]] && pass "major cap: refusals change nothing" || fail "major cap: refusals change nothing"
run "$R/scripts/release-prep.sh" major
expect_out "major: 0.1.0 → 1.0.0" 1.0.0
expect_contains "major: link" "$(cat "$R/CHANGELOG.md")" "[1.0.0]: $URL/compare/v0.1.0...v1.0.0"
commit "$R" "chore(release): v1.0.0"; tag "$R" v1.0.0
add_entry "$R" "- Another change."
run "$R/scripts/release-prep.sh" 2.0.0
expect_rc "major cap: an exact 2.0.0 after v1.0.0 is refused" 1
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

runs "$INITIAL" "completed success https://ci/1"
ci "ci: own run succeeded" "$INITIAL" 0 "$INITIAL"
runs "$INITIAL" "completed failure https://ci/1"
ci "ci: own run failed" "$INITIAL" 1
runs "$INITIAL" "completed success https://ci/1"
# A release commit (the merged release pull request) needs its own run like any commit.
noruns "$FIRST_RELEASE_COMMIT"
ci "ci: a release commit without its own run fails (the parent's does not count)" "$FIRST_RELEASE_COMMIT" 1
runs "$FIRST_RELEASE_COMMIT" "in_progress none https://ci/2"
ci "ci: a release commit whose run has not finished" "$FIRST_RELEASE_COMMIT" 1
runs "$FIRST_RELEASE_COMMIT" "completed success https://ci/2"
ci "ci: a release commit with a passed run" "$FIRST_RELEASE_COMMIT" 0 "$FIRST_RELEASE_COMMIT"
ci "ci: a code commit without a run" "$CODE_COMMIT" 1
runs "$CODE_COMMIT" "in_progress none https://ci/4"
ci "ci: a code commit whose run has not finished" "$CODE_COMMIT" 1
runs "$CODE_COMMIT" "completed success https://ci/4"
ci "ci: a code commit with a passed run" "$CODE_COMMIT" 0 "$CODE_COMMIT"
export FAKE_GH_FAIL=1
ci "ci: gh failing fails" "$INITIAL" 1
unset FAKE_GH_FAIL
run env PATH="$TMP/bin:$PATH" GITHUB_REPOSITORY= "$R/scripts/release-ci-check.sh" HEAD
expect_rc "ci: no repository (64)" 64

# --- update-keys.sh: the update keys a revision trusts ---------------------------------------
K1="M3D6KG3mzKDpqS1IjpL08pujoEBDtFGGH+ntnICNVcA="
K2="$(printf 'B%.0s' $(seq 42))w="
UV="Sources/BasketCore/Update/UpdateVerifier.swift"
# verifier_swift <list body> — an UpdateVerifier.swift shaped like the real one.
verifier_swift() {
  cat <<SWIFT
public struct UpdateVerifier: Sendable {
    /// Keys; the release workflow reads trustedPublicKeysBase64 from here.
    public static let trustedPublicKeysBase64: [String] = [
$1
    ]
    public let publicKeys: [Data]
}
SWIFT
}
KR="$TMP/keys-repo"
new_repo "$KR" 0.0.1 "$HEAD_TEXT

## [Unreleased]

- Something."
run "$KR/scripts/update-keys.sh"
expect_rc "keys: no UpdateVerifier.swift (no updater) exits 3" 3
mkdir -p "$KR/$(dirname "$UV")"
verifier_swift "        \"$K1\"," > "$KR/$UV"
run "$KR/scripts/update-keys.sh"
expect_rc "keys: one key" 0
expect_out "keys: one key printed" "$K1"
commit "$KR" "feat: one key"; tag "$KR" v0.0.1
verifier_swift "        \"$K1\", // the first key
        // added for the rotation:
        \"$K2\"" > "$KR/$UV"
run "$KR/scripts/update-keys.sh"
expect_out "keys: two keys, comments, no trailing comma" "$K1
$K2"
commit "$KR" "feat: two keys"; tag "$KR" v0.0.2
run "$KR/scripts/update-keys.sh" v0.0.1
expect_out "keys: the list at an older tag" "$K1"
run "$KR/scripts/update-keys.sh" refs/tags/v0.0.2
expect_out "keys: the list at refs/tags/…" "$K1
$K2"
run "$KR/scripts/update-keys.sh" "$(git -C "$KR" rev-list --max-parents=0 HEAD)"
expect_rc "keys: a revision without the file exits 3" 3
run "$KR/scripts/update-keys.sh" v9.9.9
expect_rc "keys: an unknown revision fails" 1
run "$KR/scripts/update-keys.sh" '--output=/tmp/x'
expect_rc "keys: an option-like revision is refused (64)" 64
for body in "" "        // none yet" "        \"not a key\"" "        \"$K1\" + \"\"" "        UpdateVerifier.extraKey," \
            "        \"${K1%=}A\"" "        \"$K1\" \"$K2\"x"; do
  verifier_swift "$body" > "$KR/$UV"
  run "$KR/scripts/update-keys.sh"
  expect_rc "keys: refused list body '${body#        }'" 1
done
{ verifier_swift "        \"$K1\","; verifier_swift "        \"$K2\","; } > "$KR/$UV"
run "$KR/scripts/update-keys.sh"
expect_rc "keys: two lists are refused" 1
printf 'public let publicKeyBase64 = "%s"\n' "$K1" > "$KR/$UV"
run "$KR/scripts/update-keys.sh"
expect_rc "keys: no list (an old single key) is refused" 1
git -C "$KR" checkout -q -- .

# --- stand-in for gh: releases --------------------------------------------------------------
mkdir -p "$TMP/ghrel"
cat > "$TMP/ghrel/gh" <<'GH'
#!/usr/bin/env bash
# Stand-in for `gh api` on releases; state in $FAKE_GH:
#   releases.json  the repository's releases (GET …/releases?per_page=100)
#   draft/         the files of draft release 77 (POST …/releases makes it)
#   calls          one line per call: "<METHOD> <endpoint> <fields…>"
# FAKE_GH_FAIL=1 fails every call; FAKE_GH_TAMPER=1 changes every downloaded file.
set -euo pipefail
[[ "${1:-}" == api ]] || exit 2
shift
method=GET jq_expr="" input="" endpoint="" fields=()
while (( $# )); do
  case "$1" in
    -X|--method) method="$2"; shift 2 ;;
    --jq|-q) jq_expr="$2"; shift 2 ;;
    --input) input="$2"; shift 2 ;;
    -H|--header) shift 2 ;;
    -f|-F|--raw-field|--field) fields+=("$2"); shift 2 ;;
    --paginate) shift ;;
    -*) echo "fake gh: unknown option $1" >&2; exit 2 ;;
    *) endpoint="$1"; shift ;;
  esac
done
echo "$method $endpoint ${fields[*]:-}" >> "$FAKE_GH/calls"
[[ -z "${FAKE_GH_FAIL:-}" ]] || exit 1
reply() { if [[ -n "$jq_expr" ]]; then jq -r "$jq_expr"; else cat; fi; }
D="$FAKE_GH/draft"
assets() { (cd "$D" && ls | LC_ALL=C sort); }
tag_of() { jq -r .tag_name "$FAKE_GH/create.json"; }
case "$method $endpoint" in
  "GET repos/"*"/releases?per_page=100") reply < "$FAKE_GH/releases.json" ;;
  "POST repos/"*"/releases")
    repo="${endpoint#repos/}"; repo="${repo%/releases}"
    if [[ "$input" == - ]]; then cat > "$FAKE_GH/create.json"; else cp "$input" "$FAKE_GH/create.json"; fi
    mkdir "$D"
    printf '{"id": 77, "draft": true, "upload_url": "https://uploads.github.com/repos/%s/releases/77/assets{?name,label}"}\n' "$repo" | reply ;;
  "POST https://uploads.github.com/repos/"*"/releases/77/assets?name="*)
    name="${endpoint##*name=}"; cp "$input" "$D/$name"; jq -n --arg n "$name" '{name: $n}' | reply ;;
  "GET repos/"*"/releases/77/assets?per_page=100")
    assets | jq -R . | jq -s 'to_entries | map({id: (.key + 1000), state: "uploaded", name: .value})' | reply ;;
  "GET repos/"*"/releases/assets/"*)
    name="$(assets | sed -n "$(( ${endpoint##*/} - 999 ))p")"
    if [[ -n "${FAKE_GH_TAMPER:-}" ]]; then printf 'x'; fi
    cat "$D/$name" ;;
  "GET repos/"*"/releases/77")
    if [[ -e "$FAKE_GH/published" ]]; then d=false; else d=true; fi
    jq -n --arg t "$(tag_of)" --argjson d "$d" '{tag_name: $t, draft: $d}' | reply ;;
  "PATCH repos/"*"/releases/77")
    touch "$FAKE_GH/published"
    jq -n --arg t "$(tag_of)" '{tag_name: $t, draft: false, html_url: "https://github.com/Kilerd/basket/releases/tag/\($t)"}' | reply ;;
  "DELETE repos/"*"/releases/77") rm -rf "$D"; touch "$FAKE_GH/deleted" ;;
  *) echo "fake gh: unexpected $method $endpoint" >&2; exit 3 ;;
esac
GH
chmod +x "$TMP/ghrel/gh"
# releases <json array of {tag_name, draft, prerelease}> — resets the stand-in's state.
releases() {
  rm -rf "$TMP/ghstate"; mkdir -p "$TMP/ghstate"
  printf '%s\n' "$1" > "$TMP/ghstate/releases.json"
  : > "$TMP/ghstate/calls"
}
gh_env=(env PATH="$TMP/ghrel:$PATH" FAKE_GH="$TMP/ghstate" GITHUB_REPOSITORY=Kilerd/basket)

# --- published-release.sh --------------------------------------------------------------------
releases '[{"tag_name":"v0.0.1","draft":false,"prerelease":false},{"tag_name":"v0.0.10","draft":false,"prerelease":false},
  {"tag_name":"v0.0.9","draft":false,"prerelease":false},{"tag_name":"v0.1.0","draft":true,"prerelease":false},
  {"tag_name":"v0.0.11","draft":false,"prerelease":true},{"tag_name":"nightly","draft":false,"prerelease":false},
  {"tag_name":"v0.0.12-rc.1","draft":false,"prerelease":false}]'
run "${gh_env[@]}" "$KR/scripts/published-release.sh"
expect_out "published: the newest (numeric order; drafts, pre-releases and other tags ignored)" v0.0.10
run "${gh_env[@]}" "$KR/scripts/published-release.sh" --below 0.0.10
expect_out "published: the newest below a version" v0.0.9
run "${gh_env[@]}" "$KR/scripts/published-release.sh" --below 0.0.1
expect_out "published: nothing below the first" ""
expect_rc "published: nothing is no error" 0
releases '[]'
run "${gh_env[@]}" "$KR/scripts/published-release.sh"
expect_out "published: no releases at all" ""
run "${gh_env[@]}" FAKE_GH_FAIL=1 "$KR/scripts/published-release.sh"
expect_rc "published: gh failing fails" 1
run "${gh_env[@]}" "$KR/scripts/published-release.sh" --below v1.0.0
expect_rc "published: --below needs X.Y.Z (64)" 64

# --- release-publish.sh: tag guard, release id, latest ----------------------------------------
P="$TMP/publish"
new_repo "$P" 0.0.3 "$HEAD_TEXT

## [Unreleased]

## [0.0.3] - 2026-12-01

- Something."
BUILT="$(git -C "$P" rev-parse HEAD)"
tag "$P" v0.0.3
echo other > "$P/other.txt"; commit "$P" "chore: another commit"
OTHER="$(git -C "$P" rev-parse HEAD)"
git clone -q --bare "$P" "$TMP/origin.git"
git -C "$P" remote add origin "$TMP/origin.git"
A="$TMP/assets"
mkdir -p "$A"
printf 'dmg' > "$A/Basket-0.0.3.dmg"; printf 'zip' > "$A/Basket-0.0.3-arm64.zip"; printf '{}' > "$A/latest.json"
(cd "$A" && shasum -a 256 Basket-0.0.3.dmg Basket-0.0.3-arm64.zip latest.json) > "$A/SHA256SUMS"
printf 'Notes.\n' > "$TMP/body.md"
publish() { run "${gh_env[@]}" "$P/scripts/release-publish.sh" "$@"; }
calls() { cat "$TMP/ghstate/calls"; }

releases '[{"tag_name":"v0.0.2","draft":false,"prerelease":false}]'
publish v0.0.3 "$BUILT" "$A" "$TMP/body.md"
expect_rc "publish: a newer version" 0
expect_out "publish: prints the release URL" "https://github.com/Kilerd/basket/releases/tag/v0.0.3"
expect_contains "publish: the draft is made for the tag" "$(jq -c '{tag_name, draft}' "$TMP/ghstate/create.json")" '{"tag_name":"v0.0.3","draft":true}'
expect_contains "publish: uploads to the release id" "$(calls)" "POST https://uploads.github.com/repos/Kilerd/basket/releases/77/assets?name=Basket-0.0.3.dmg"
expect_contains "publish: published by id, marked latest" "$(calls)" "PATCH repos/Kilerd/basket/releases/77 draft=false make_latest=true"
expect_lacks "publish: never addresses a release by tag name" "$(calls)" "releases/tags/"
[[ "$(cd "$TMP/ghstate/draft" && ls | LC_ALL=C sort | tr '\n' ' ')" == "Basket-0.0.3-arm64.zip Basket-0.0.3.dmg SHA256SUMS latest.json " ]] \
  && pass "publish: every file uploaded" || fail "publish: every file uploaded" "$(ls "$TMP/ghstate/draft")"
[[ ! -e "$TMP/ghstate/deleted" ]] && pass "publish: the published release is kept" || fail "publish: the published release is kept"

releases '[{"tag_name":"v0.0.2","draft":false,"prerelease":false},{"tag_name":"v0.1.0","draft":false,"prerelease":false}]'
publish v0.0.3 "$BUILT" "$A" "$TMP/body.md"
expect_rc "publish: an older line's patch" 0
expect_contains "publish: not marked latest below a newer release" "$(calls)" "make_latest=false"
releases '[{"tag_name":"v0.0.3","draft":true,"prerelease":false},{"tag_name":"v0.0.4","draft":false,"prerelease":true}]'
publish v0.0.3 "$BUILT" "$A" "$TMP/body.md"
expect_contains "publish: drafts and pre-releases don't keep it from being latest" "$(calls)" "make_latest=true"

releases '[]'
publish v0.0.3 "$OTHER" "$A" "$TMP/body.md"
expect_rc "publish: the tag points at another commit than the built one" 1
expect_contains "publish: says the tag points elsewhere" "$ERR" "not at the commit that was built"
expect_lacks "publish: no draft when the tag is wrong" "$(calls)" "POST"
git -C "$TMP/origin.git" tag -f -a v0.0.3 -m moved "$OTHER" >/dev/null
releases '[]'
publish v0.0.3 "$BUILT" "$A" "$TMP/body.md"
expect_rc "publish: a tag moved on origin is refused" 1
expect_lacks "publish: nothing created for a moved tag" "$(calls)" "POST"
git -C "$TMP/origin.git" tag -f "v0.0.3" "$BUILT" >/dev/null # lightweight now
releases '[]'
publish v0.0.3 "$BUILT" "$A" "$TMP/body.md"
expect_rc "publish: a lightweight tag at the built commit" 0
git -C "$TMP/origin.git" tag -d v0.0.3 >/dev/null
releases '[]'
publish v0.0.3 "$BUILT" "$A" "$TMP/body.md"
expect_rc "publish: a tag missing on origin is refused" 1
git -C "$TMP/origin.git" tag -a v0.0.3 -m v0.0.3 "$BUILT"

releases '[]'
run "${gh_env[@]}" FAKE_GH_TAMPER=1 "$P/scripts/release-publish.sh" v0.0.3 "$BUILT" "$A" "$TMP/body.md"
expect_rc "publish: a draft whose files differ is refused" 1
expect_contains "publish: says which file differs" "$ERR" "differs from the file that was checked"
expect_lacks "publish: a refused draft is never published" "$(calls)" "PATCH"
[[ -e "$TMP/ghstate/deleted" ]] && pass "publish: the refused draft is deleted (by id)" || fail "publish: the refused draft is deleted (by id)"
expect_contains "publish: deleted by id" "$(calls)" "DELETE repos/Kilerd/basket/releases/77"

releases '[]'
publish 0.0.3 "$BUILT" "$A" "$TMP/body.md"
expect_rc "publish: a tag without v (64)" 64
publish v0.0.3 "${BUILT:0:12}" "$A" "$TMP/body.md"
expect_rc "publish: a short commit (64)" 64
mkdir "$A/sub"
publish v0.0.3 "$BUILT" "$A" "$TMP/body.md"
expect_rc "publish: a folder among the assets is refused" 1
rmdir "$A/sub"

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
  OTHER_PUB="$OUT"
  run swift "$SRC/scripts/update-verify.swift" "$M/Basket-0.0.1-arm64.zip" "$USIG" "$OTHER_PUB"
  expect_rc "update: not with another key" 1
  run swift "$SRC/scripts/update-verify.swift" "$M/Basket-0.0.1-arm64.zip" "$USIG" "$OTHER_PUB" "$PUB"
  expect_rc "update: with any key of a list (rotation)" 0
  expect_contains "update: names the key that verified it" "$OUT" "$PUB"
  run swift "$SRC/scripts/update-verify.swift" "$M/Basket-0.0.1-arm64.zip" "$USIG" "$OTHER_PUB" "$K1"
  expect_rc "update: not with a list without the signing key" 1
  run swift "$SRC/scripts/update-verify.swift" "$M/Basket-0.0.1-arm64.zip" "$USIG" "$PUB" "not a key"
  expect_rc "update: a malformed key in the list is refused (64)" 64
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
