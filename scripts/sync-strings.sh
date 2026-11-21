#!/usr/bin/env bash
# Brings the String Catalog in line with the sources: the compiler lists every localizable string
# of the Basket and BasketCore targets (`swiftc -emit-localized-strings`: SwiftUI literals,
# String(localized:), LocalizedStringResource), then `xcstringstool sync` adds new keys and marks
# keys no longer used as stale. Translations are never touched.
#   scripts/sync-strings.sh            update Resources/Localization/Localizable.xcstrings
#   scripts/sync-strings.sh --prune    … and drop the stale keys
#   scripts/sync-strings.sh --check    change nothing; exit 1 (listing the keys) if a sync would
#                                      change the catalog
# The extraction build uses its own scratch path ($BASKET_SCRATCH-strings, e.g. .build-strings) so
# the extra compiler flag doesn't invalidate the regular build.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

MODE="${1:-sync}"
case "$MODE" in sync|--prune|--check) ;; *) die "usage: $0 [--prune|--check]" 64 ;; esac

CATALOG="$ROOT/Resources/Localization/Localizable.xcstrings"
[[ -f "$CATALOG" ]] || die "no catalog at $CATALOG"
STRINGS_SCRATCH="${SCRATCH%/}-strings"
[[ "$STRINGS_SCRATCH" = /* ]] || STRINGS_SCRATCH="$ROOT/$STRINGS_SCRATCH"
DATA="$STRINGS_SCRATCH/stringsdata"
TARGETS=(Basket BasketCore)

# One .stringsdata per source file, named after the file: two files with the same name would
# overwrite each other's keys.
dupes="$(for t in "${TARGETS[@]}"; do find "$ROOT/Sources/$t" -name '*.swift' -exec basename {} \;; done | sort | uniq -d)"
[[ -z "$dupes" ]] || die "source file names must be unique across ${TARGETS[*]} (string extraction): $dupes"

# Always recompile both modules: an incremental build would skip unchanged files and leave
# their keys out.
rm -rf "$DATA"
mkdir -p "$DATA"
for t in "${TARGETS[@]}"; do rm -rf "$STRINGS_SCRATCH"/*/debug/"$t".build; done
log "extracting strings (swift build --scratch-path ${STRINGS_SCRATCH#"$ROOT"/})"
(cd "$ROOT" && swift build --scratch-path "$STRINGS_SCRATCH" --product Basket \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$DATA" >&2) \
  || die "extraction build failed"

ARGS=()
shopt -s nullglob
for f in "$DATA"/*.stringsdata; do
  for t in "${TARGETS[@]}"; do
    if grep -q "\"source\" *: *\"$ROOT/Sources/$t/" "$f"; then ARGS+=(--stringsdata "$f"); break; fi
  done
done
shopt -u nullglob
(( ${#ARGS[@]} > 0 )) || die "the build produced no .stringsdata for ${TARGETS[*]}"
log "$(( ${#ARGS[@]} / 2 )) source files with localizable strings"

l10n() { swift "$ROOT/scripts/l10n.swift" "$@"; }

if [[ "$MODE" == --check ]]; then
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  cp "$CATALOG" "$WORK/Localizable.xcstrings"
  xcrun xcstringstool sync "$WORK/Localizable.xcstrings" "${ARGS[@]}"
  if ! l10n diff "$CATALOG" "$WORK/Localizable.xcstrings" >"$WORK/diff.txt"; then
    sed 's/^/  /' "$WORK/diff.txt" >&2
    die "the catalog is out of date with the sources ($(wc -l <"$WORK/diff.txt" | tr -d ' ') keys): run scripts/sync-strings.sh"
  fi
  log "catalog matches the sources"
  exit 0
fi

BEFORE="$(mktemp)"
trap 'rm -f "$BEFORE"' EXIT
cp "$CATALOG" "$BEFORE"
xcrun xcstringstool sync "$CATALOG" "${ARGS[@]}"
[[ "$MODE" == --prune ]] && l10n prune "$CATALOG" >&2
l10n diff "$BEFORE" "$CATALOG" || true
l10n stats "$CATALOG"
