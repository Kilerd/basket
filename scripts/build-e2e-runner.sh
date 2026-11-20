#!/usr/bin/env bash
# Builds build/BasketE2E.app: the `basket-ax` runner wrapped as a background (LSUIElement) app.
#   scripts/build-e2e-runner.sh [debug|release]
# It must be Developer-ID signed: TCC keys the one-time Accessibility grant on the designated
# requirement (bundle id + Team ID), so the grant survives rebuilds. An ad-hoc signature would
# need a new grant after every build.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

CONFIG="${1:-debug}"
[[ "$CONFIG" == debug || "$CONFIG" == release ]] || die "usage: $0 [debug|release]" 64

log "swift build ($CONFIG) basket-ax"
BIN="$(swift_build "$CONFIG" basket-ax)"
[[ -x "$BIN/basket-ax" ]] || die "no executable at $BIN/basket-ax"

APP="$BUILD_DIR/BasketE2E.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/basket-ax" "$APP/Contents/MacOS/basket-ax"
write_info_plist "$APP/Contents/Info.plist" dev.basket.e2e BasketE2E basket-ax \
  "  <key>LSUIElement</key><true/>"

IDENTITY="${BASKET_SIGN_IDENTITY:-$(developer_id_identity)}"
if [[ -z "$IDENTITY" ]]; then
  log "WARNING: no Developer ID Application identity — signing ad-hoc; the Accessibility grant will not survive rebuilds"
  IDENTITY="-"
fi
log "codesign ($IDENTITY)"
sign_bundle "$APP" "$IDENTITY"

log "designated requirement: $(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
log "built $APP ($(signing_summary "$APP"))"
echo "$APP"
