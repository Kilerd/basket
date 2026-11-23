#!/usr/bin/env bash
# True out-of-process E2E: BasketE2E.app launches build/Basket.app (the debug build, bundle id
# dev.basket.app.debug, from a temporary copy) with fixtures, drives it through the Accessibility
# API (AXUIElement) and audits every section. An installed Basket may keep running.
#   scripts/e2e.sh [demo|empty|stopped]
#   BASKET_LANGUAGE=de scripts/e2e.sh demo     run the app in another language
# Output: artifacts/e2e/<timestamp>[-<language>]-<pid>/{report.md,report.json,runner.log,<section>.ax.json,<section>.png}
# Exit code: the runner's, as recorded in report.json (0 ok, 1 findings, 2 runner error,
# 3 Accessibility permission missing).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

SET="${1:-demo}"
FIXTURES="$ROOT/Fixtures/$SET"
[[ -d "$FIXTURES" ]] || die "no fixture set at $FIXTURES (try: $(ls "$ROOT/Fixtures" | tr '\n' ' '))" 64

LANGUAGE="${BASKET_LANGUAGE:-}"

"$ROOT/scripts/build-app.sh" debug >/dev/null
"$ROOT/scripts/build-e2e-runner.sh" >/dev/null
check_app_language "$BUILD_DIR/Basket.app" "$LANGUAGE"

acquire_gui_lock "E2E run"

# The runner starts Basket through LaunchServices, so Basket runs from a temporary copy with its
# fixtures next to it: nothing it reads lies in a privacy-protected folder (stage_for_launch).
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/basket-e2e.XXXXXX")"
trap 'rm -rf "$STAGE" "$GUI_LOCK"' EXIT
stage_for_launch "$STAGE" "$BUILD_DIR/Basket.app" "$FIXTURES"

OUT="$ROOT/artifacts/e2e/$(date +%Y%m%d-%H%M%S)${LANGUAGE:+-$LANGUAGE}-$$"
mkdir -p "$OUT"
log "running BasketE2E.app with $(bundle_id_of "$STAGE/Basket.app")${LANGUAGE:+ in $LANGUAGE} (log: $OUT/runner.log)"
LANGUAGE_ARGS=()
[[ -n "$LANGUAGE" ]] && LANGUAGE_ARGS=(--language "$LANGUAGE" --locale "$(app_locale "$LANGUAGE")")
# Launched through LaunchServices so macOS attributes the Accessibility grant to BasketE2E.app
# itself (not to this terminal). Its stdout is invisible; it writes runner.log + report.json.
open -W -n "$BUILD_DIR/BasketE2E.app" --args \
  audit --app "$STAGE/Basket.app" --fixtures "$STAGE/fixtures" --out "$OUT" \
  ${LANGUAGE_ARGS[@]+"${LANGUAGE_ARGS[@]}"}

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
