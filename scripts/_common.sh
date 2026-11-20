# Shared helpers for Basket scripts. Source it; don't run it.
# shellcheck shell=bash

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# SwiftPM scratch path (the lead's `.build`; override with BASKET_SCRATCH for side-by-side runs).
SCRATCH="${BASKET_SCRATCH:-.build}"
# Where app bundles go (override with BASKET_BUILD_DIR so parallel lanes don't overwrite each other).
BUILD_DIR="${BASKET_BUILD_DIR:-$ROOT/build}"
VERSION="0.0.1"

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit "${2:-1}"; }

# swift_build <config> <product> — builds and prints the bin directory; fails if the build fails.
swift_build() {
  local config="$1" product="$2"
  (cd "$ROOT" && swift build --scratch-path "$SCRATCH" -c "$config" --product "$product" >&2) \
    || { printf 'error: swift build of %s failed\n' "$product" >&2; return 1; }
  (cd "$ROOT" && swift build --scratch-path "$SCRATCH" -c "$config" --show-bin-path)
}

# developer_id_identity — the first "Developer ID Application" signing identity, or nothing.
developer_id_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1
}

# write_info_plist <path> <bundle-id> <name> <executable> [extra plist XML keys]
write_info_plist() {
  local path="$1" id="$2" name="$3" exe="$4" extra="${5:-}"
  cat >"$path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>${exe}</string>
  <key>CFBundleIdentifier</key><string>${id}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>${name}</string>
  <key>CFBundleDisplayName</key><string>${name}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
${extra}
</dict>
</plist>
PLIST
  plutil -lint "$path" >/dev/null || die "invalid Info.plist at $path"
}

# sign_bundle <app> <identity> [entitlements] — hardened runtime, no sandbox.
sign_bundle() {
  local app="$1" identity="$2" entitlements="${3:-}"
  local args=(--force --options runtime --sign "$identity")
  # Local builds: no secure timestamp (works offline). Set BASKET_SIGN_TIMESTAMP=1 for distribution.
  if [[ "$identity" != "-" ]]; then
    if [[ "${BASKET_SIGN_TIMESTAMP:-0}" == "1" ]]; then args+=(--timestamp); else args+=(--timestamp=none); fi
  fi
  [[ -n "$entitlements" ]] && args+=(--entitlements "$entitlements")
  codesign "${args[@]}" "$app" >&2
  codesign --verify --strict "$app" || die "codesign verification failed for $app"
}

# signing_summary <app> — "Authority=…" line (or "adhoc").
signing_summary() {
  local info
  info="$(codesign -dvv "$1" 2>&1)"
  if grep -q '^Authority=' <<<"$info"; then grep -m1 '^Authority=' <<<"$info"; else echo "Signature=adhoc"; fi
}

# acquire_gui_lock <what> — one GUI run (self-test or E2E) at a time on this Mac: runs share the
# screen and the dev.basket.app bundle id, and a second instance never opens its main window.
# Released on exit; a lock left by a dead process is taken over.
acquire_gui_lock() {
  local what="$1" waited=0 holder
  GUI_LOCK="${TMPDIR:-/tmp}/basket-gui.lock"
  until mkdir "$GUI_LOCK" 2>/dev/null; do
    holder="$(cat "$GUI_LOCK/pid" 2>/dev/null || true)"
    if [[ -n "$holder" ]] && ! kill -0 "$holder" 2>/dev/null; then rm -rf "$GUI_LOCK"; continue; fi
    (( waited % 30 == 0 )) && log "$what: waiting for another GUI run (pid ${holder:-?}) to finish"
    (( waited >= 1200 )) && die "gave up waiting for the GUI lock at $GUI_LOCK" 2
    sleep 1; waited=$((waited + 1))
  done
  echo $$ > "$GUI_LOCK/pid"
  trap 'rm -rf "$GUI_LOCK"' EXIT
}
