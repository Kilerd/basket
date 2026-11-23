#!/usr/bin/env bash
# Builds build/Basket.app from the SwiftPM `Basket` product, with the `basket-docker` shim in
# Contents/Helpers (DockerShimInstaller copies it to ~/.basket/bin/docker).
#   scripts/build-app.sh [debug|release]
# Bundle id: release builds are the product, dev.basket.app ("Basket"); debug builds are
# dev.basket.app.debug ("Basket (Debug)"), so they never share settings or LaunchServices identity
# with an installed Basket. BASKET_BUNDLE_ID=<id> overrides either, for special tests.
# Signing: $BASKET_SIGN_IDENTITY, else the first Developer ID Application identity, else ad-hoc.
# Hardened runtime; not sandboxed (Basket execs the `container` CLI).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

CONFIG="${1:-debug}"
[[ "$CONFIG" == debug || "$CONFIG" == release ]] || die "usage: $0 [debug|release]" 64
BUNDLE_ID="$(app_bundle_id "$CONFIG")"
if [[ "$CONFIG" == release ]]; then NAME="Basket"; else NAME="Basket (Debug)"; fi

log "swift build ($CONFIG) Basket"
BIN="$(swift_build "$CONFIG" Basket)"
[[ -x "$BIN/Basket" ]] || die "no executable at $BIN/Basket"
log "swift build ($CONFIG) basket-docker"
swift_build "$CONFIG" basket-docker >/dev/null
[[ -x "$BIN/basket-docker" ]] || die "no executable at $BIN/basket-docker"

APP="$BUILD_DIR/Basket.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN/Basket" "$APP/Contents/MacOS/Basket"
cp "$BIN/basket-docker" "$APP/Contents/Helpers/basket-docker"
# SwiftPM resource bundles of the app's targets, if any.
shopt -s nullglob
for bundle in "$BIN"/Basket_*.bundle; do
  [[ "$bundle" == *Tests.bundle ]] && continue   # test fixtures never ship
  cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob

cp "$ROOT/Resources/Branding/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# App strings: the String Catalog compiled into Contents/Resources/<lang>.lproj
# (Localizable.strings + .stringsdict for plurals), where Bundle.main finds them. Not a SwiftPM
# resource bundle: Bundle.module in a hand-assembled app is fragile. Every language in the
# catalog ships; en.lproj always exists (the development region).
log "compile String Catalog"
xcrun xcstringstool compile "$ROOT/Resources/Localization/Localizable.xcstrings" \
  --output-directory "$APP/Contents/Resources" >/dev/null || die "xcstringstool compile failed"
mkdir -p "$APP/Contents/Resources/en.lproj"
LOCALIZATIONS=""
for lproj in "$APP/Contents/Resources"/*.lproj; do
  LOCALIZATIONS+="<string>$(basename "$lproj" .lproj)</string>"
done

write_info_plist "$APP/Contents/Info.plist" "$BUNDLE_ID" "$NAME" Basket \
  "  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleLocalizations</key><array>${LOCALIZATIONS}</array>"

IDENTITY="${BASKET_SIGN_IDENTITY:-$(developer_id_identity)}"
IDENTITY="${IDENTITY:--}"
ENTITLEMENTS=""
if [[ "$CONFIG" == debug && "$IDENTITY" != "-" ]]; then
  # Debug builds stay attachable by lldb under the hardened runtime.
  ENTITLEMENTS="$BUILD_DIR/Basket-debug.entitlements"
  cat >"$ENTITLEMENTS" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>
XML
fi
log "codesign ($([[ "$IDENTITY" == "-" ]] && echo ad-hoc || echo "$IDENTITY"))"
sign_app "$APP" "$IDENTITY" "$ENTITLEMENTS"

log "built $APP ($BUNDLE_ID, $(signing_summary "$APP"))"
echo "$APP"
