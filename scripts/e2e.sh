#!/usr/bin/env bash
# True out-of-process E2E: BasketE2E.app launches build/Basket.app with fixtures, drives it
# through the Accessibility API (AXUIElement) and audits every section.
#   scripts/e2e.sh [demo|empty|stopped]
# Output: artifacts/e2e/<timestamp>/{report.md,report.json,runner.log,<section>.ax.json,<section>.png}
# Exit code: the runner's, as recorded in report.json (0 ok, 1 findings, 2 runner error,
# 3 Accessibility permission missing).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

SET="${1:-demo}"
FIXTURES="$ROOT/Fixtures/$SET"
[[ -d "$FIXTURES" ]] || die "no fixture set at $FIXTURES (try: $(ls "$ROOT/Fixtures" | tr '\n' ' '))" 64

"$ROOT/scripts/build-app.sh" debug >/dev/null
"$ROOT/scripts/build-e2e-runner.sh" >/dev/null

acquire_gui_lock "E2E run"

OUT="$ROOT/artifacts/e2e/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$OUT"
log "running BasketE2E.app (log: $OUT/runner.log)"
# Launched through LaunchServices so macOS attributes the Accessibility grant to BasketE2E.app
# itself (not to this terminal). Its stdout is invisible; it writes runner.log + report.json.
open -W -n "$BUILD_DIR/BasketE2E.app" --args \
  audit --app "$BUILD_DIR/Basket.app" --fixtures "$FIXTURES" --out "$OUT"

REPORT="$OUT/report.json"
if [[ ! -f "$REPORT" ]]; then
  log "no report.json — the runner failed early. runner.log:"
  cat "$OUT/runner.log" >&2 2>/dev/null || true
  exit 2
fi
CODE="$(plutil -extract exitCode raw -o - "$REPORT" 2>/dev/null || echo 2)"

[[ -f "$OUT/report.md" ]] && cat "$OUT/report.md"
echo
echo "report: $OUT/report.md"

if [[ "$CODE" == 3 ]]; then
  cat >&2 <<EOF

BasketE2E needs the Accessibility permission (one time; it survives rebuilds because the
runner is Developer-ID signed):
  1. Open System Settings › Privacy & Security › Accessibility
       open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
  2. Turn on "BasketE2E". If it isn't listed, click +, choose
       $BUILD_DIR/BasketE2E.app
     and turn it on.
  3. Run scripts/e2e.sh again.
Optional: also allow BasketE2E under "Screen & System Audio Recording" to get per-section
window screenshots in the report.
EOF
fi
exit "$CODE"
