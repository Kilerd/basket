#!/usr/bin/env bash
# Permission-free UI check: the app walks its own accessibility tree for every section
# (BASKET_SELFTEST_DIR), then `basket-ax lint` audits the dumps.
#   scripts/selftest.sh [demo|empty|stopped|fresh]
#   BASKET_LANGUAGE=zh-Hans scripts/selftest.sh demo     run the app in another language (and
#                                                        its region format: app_locale)
# Output: artifacts/selftest/<set>[-<language>]-<timestamp>/{<section>.png,<section>.ax.json,report.md,report.json,app.log}
# Exit code: lint's (0 clean, 1 error findings, 2 nothing to lint).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

SET="${1:-demo}"
FIXTURES="$ROOT/Fixtures/$SET"
[[ -d "$FIXTURES" ]] || die "no fixture set at $FIXTURES (try: $(ls "$ROOT/Fixtures" | tr '\n' ' '))" 64
APP_TIMEOUT="${BASKET_SELFTEST_TIMEOUT:-90}"
LANGUAGE="${BASKET_LANGUAGE:-}"

"$ROOT/scripts/build-app.sh" debug >/dev/null
log "swift build (debug) basket-ax"
AX="$(swift_build debug basket-ax)/basket-ax"
check_app_language "$BUILD_DIR/Basket.app" "$LANGUAGE"

acquire_gui_lock "self-test"

OUT="$ROOT/artifacts/selftest/$SET${LANGUAGE:+-$LANGUAGE}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
log "self-test with Fixtures/$SET${LANGUAGE:+ in $LANGUAGE} → $OUT (timeout ${APP_TIMEOUT}s)"

APP_PID=""
cleanup() { [[ -n "$APP_PID" ]] && kill -TERM "$APP_PID" 2>/dev/null || true; }
trap cleanup INT TERM

# The argument domain sets the language and its region format (-AppleLocale: "4,21 Go" in French)
# for this run only; nothing is written to defaults.
LANGUAGE_ARGS=()
[[ -n "$LANGUAGE" ]] && LANGUAGE_ARGS=(-AppleLanguages "($LANGUAGE)" -AppleLocale "$(app_locale "$LANGUAGE")")
env BASKET_BACKEND=fixtures BASKET_FIXTURES_DIR="$FIXTURES" BASKET_UI_TEST=1 BASKET_SELFTEST_DIR="$OUT" \
  "$BUILD_DIR/Basket.app/Contents/MacOS/Basket" -ApplePersistenceIgnoreState YES \
  ${LANGUAGE_ARGS[@]+"${LANGUAGE_ARGS[@]}"} >"$OUT/app.log" 2>&1 &
APP_PID=$!

# Watchdog: TERM after the timeout, KILL 5 s later.
SECONDS=0
APP_STATUS=""
while kill -0 "$APP_PID" 2>/dev/null; do
  if (( SECONDS >= APP_TIMEOUT )); then
    log "self-test exceeded ${APP_TIMEOUT}s — terminating the app"
    kill -TERM "$APP_PID" 2>/dev/null || true
    for _ in 1 2 3 4 5; do kill -0 "$APP_PID" 2>/dev/null || break; sleep 1; done
    kill -KILL "$APP_PID" 2>/dev/null || true
    APP_STATUS=124
    break
  fi
  sleep 0.5
done
set +e
wait "$APP_PID" 2>/dev/null
WAIT_STATUS=$?
set -e
APP_PID=""
APP_STATUS="${APP_STATUS:-$WAIT_STATUS}"
if [[ "$APP_STATUS" != 0 ]]; then
  log "app exited with status $APP_STATUS — last lines of app.log:"
  tail -n 20 "$OUT/app.log" >&2 || true
fi

set +e
"$AX" lint "$OUT"
LINT=$?
set -e
echo
echo "report: $OUT/report.md"
exit "$LINT"
