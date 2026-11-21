#!/usr/bin/env bash
# Localization gate (CI): the String Catalog matches the sources, every key is translated into
# every language in the catalog with matching placeholders, and the catalog compiles.
#   scripts/check-l10n.sh
# Fix a failure with scripts/sync-strings.sh [--prune] and translations (CONTRIBUTING.md,
# "Localization").
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

CATALOG="$ROOT/Resources/Localization/Localizable.xcstrings"
STATUS=0

log "1/3 catalog vs sources"
"$ROOT/scripts/sync-strings.sh" --check || STATUS=1

log "2/3 translations"
swift "$ROOT/scripts/l10n.swift" check "$CATALOG" || STATUS=1
swift "$ROOT/scripts/l10n.swift" stats "$CATALOG"

log "3/3 compile"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
if xcrun xcstringstool compile "$CATALOG" --output-directory "$OUT" >/dev/null; then
  for f in "$OUT"/*.lproj/*; do plutil -lint "$f" >/dev/null || { log "invalid compiled file $f"; STATUS=1; }; done
  log "compiled: $(cd "$OUT" && ls -d *.lproj | tr '\n' ' ')"
else
  log "xcstringstool compile failed"
  STATUS=1
fi

(( STATUS == 0 )) && log "localization OK" || log "localization check failed"
exit "$STATUS"
