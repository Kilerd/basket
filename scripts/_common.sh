# Shared helpers for Basket scripts. Source it; don't run it.
# shellcheck shell=bash

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# SwiftPM scratch path (the lead's `.build`; override with BASKET_SCRATCH for side-by-side runs).
SCRATCH="${BASKET_SCRATCH:-.build}"
# Where app bundles go (override with BASKET_BUILD_DIR so parallel lanes don't overwrite each other).
BUILD_DIR="${BASKET_BUILD_DIR:-$ROOT/build}"
VERSION="0.0.1"
# A release version: SemVer X.Y.Z, no leading zeros, no pre-release or build suffix (docs/RELEASING.md).
SEMVER_RE='^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$'

log() { printf '==> %s\n' "$*" >&2; }
# die <message> [exit-code]
die() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }

# semver_cmp <a> <b> — two X.Y.Z versions (SEMVER_RE): prints -1, 0 or 1.
semver_cmp() {
  local a b i
  IFS=. read -r -a a <<<"$1"
  IFS=. read -r -a b <<<"$2"
  for i in 0 1 2; do
    if (( a[i] > b[i] )); then echo 1; return; fi
    if (( a[i] < b[i] )); then echo -1; return; fi
  done
  echo 0
}

# swift_build <config> <product> — builds and prints the bin directory; fails if the build fails.
swift_build() {
  local config="$1" product="$2"
  (cd "$ROOT" && swift build --scratch-path "$SCRATCH" -c "$config" --product "$product" >&2) \
    || { printf 'error: swift build of %s failed\n' "$product" >&2; return 1; }
  (cd "$ROOT" && swift build --scratch-path "$SCRATCH" -c "$config" --show-bin-path)
}

# check_app_language <Basket.app> <language id or empty> — dies unless the built app ships that
# localization (BASKET_LANGUAGE for selftest.sh / e2e.sh, e.g. zh-Hans).
check_app_language() {
  local app="$1" language="$2"
  [[ -z "$language" ]] && return 0
  [[ "$language" =~ ^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})*$ ]] \
    || die "BASKET_LANGUAGE must be a language id such as zh-Hans (got '$language')" 64
  [[ -d "$app/Contents/Resources/$language.lproj" ]] \
    || die "Basket has no '$language' localization (have: $(cd "$app/Contents/Resources" && ls -d ./*.lproj | sed 's|^\./||; s|\.lproj$||' | tr '\n' ' '))" 64
}

# app_locale <language id> — the region format passed as -AppleLocale with BASKET_LANGUAGE, so
# numbers, sizes and dates follow the language too ("4,21 Go", "4.21 GB", "2026年11月21日").
app_locale() {
  case "$1" in
    en) echo en_US ;;
    fr) echo fr_FR ;;
    de) echo de_DE ;;
    ja) echo ja_JP ;;
    zh-Hans) echo zh_CN ;;
    zh-Hant) echo zh_TW ;;
    *) echo "${1//-/_}" ;;
  esac
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

# sign_app <Basket.app> <identity> [entitlements] — inside out: the `basket-docker` helper first
# (hardened runtime, its own identifier, same identity), then the app seals it. Used by
# build-app.sh and, for the Developer ID signature of a release, by sign-app.sh.
sign_app() {
  local app="$1" identity="$2" entitlements="${3:-}"
  local args=(--force --options runtime --identifier dev.basket.app.docker-shim --sign "$identity")
  if [[ "$identity" != "-" ]]; then
    if [[ "${BASKET_SIGN_TIMESTAMP:-0}" == "1" ]]; then args+=(--timestamp); else args+=(--timestamp=none); fi
  fi
  codesign "${args[@]}" "$app/Contents/Helpers/basket-docker" >&2
  sign_bundle "$app" "$identity" "$entitlements"
  codesign --verify --deep --strict "$app" || die "codesign --deep verification failed for $app"
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
