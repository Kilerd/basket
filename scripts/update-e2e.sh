#!/usr/bin/env bash
# Real-UI end-to-end test of installing an update (docs/updates.md, "End-to-end test").
#   scripts/update-e2e.sh
# Basket A — this checkout's DEBUG build, Developer ID signed — runs from a temporary disk image
# (never /Applications) with a local test feed offering Basket B: the same build with a higher
# version, its zip signed with a throwaway update key. BasketE2E.app chooses
# Basket ▸ Check for Updates…, waits for the update sheet and presses “Install and Relaunch”
# (update.install) through the Accessibility API. Passes when A quits within 10 s of installing,
# the bundle on the image is then B, and B runs from there. B is quit and the image detached
# afterwards, so the replaced copy, the staging folder and the key go with it.
# Needs a Developer ID Application identity (ad-hoc builds can't update), the Accessibility
# permission for BasketE2E.app (as scripts/e2e.sh) and an unlocked screen (waits up to
# BASKET_UNLOCK_WAIT seconds, default 600). Another Basket may keep running meanwhile.
# Output: artifacts/update-e2e/<timestamp>-<pid>/{runner.log,result.json,update.log}
# Exit: 0 pass, 1 the update didn't install, 2 setup or runner error, 3 Accessibility missing.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

IDENTITY="${BASKET_SIGN_IDENTITY:-$(developer_id_identity)}"
[[ -n "$IDENTITY" && "$IDENTITY" != "-" ]] \
  || die "needs a Developer ID Application identity: ad-hoc signed builds can't update themselves" 2

screen_locked() {
  ioreg -n Root -d1 -a | plutil -extract IOConsoleUsers xml1 -o - - 2>/dev/null \
    | grep -A1 CGSSessionScreenIsLocked | grep -q '<true/>'
}

"$ROOT/scripts/build-app.sh" debug >/dev/null
"$ROOT/scripts/build-e2e-runner.sh" >/dev/null
OLD_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$BUILD_DIR/Basket.app/Contents/Info.plist")"
[[ "$OLD_VERSION" =~ $SEMVER_RE ]] || die "the build has no X.Y.Z version ($OLD_VERSION)" 2
# Far from any real release, so B is never mistaken for one.
NEW_VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1000))"

acquire_gui_lock "update E2E"
WAITED=0
while screen_locked; do
  (( WAITED >= ${BASKET_UNLOCK_WAIT:-600} )) && die "the screen stayed locked for ${WAITED}s; the E2E needs it unlocked" 2
  (( WAITED % 60 == 0 )) && log "the screen is locked; waiting for it to be unlocked"
  sleep 15; WAITED=$((WAITED + 15))
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/basket-update-e2e.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
VOLUME="$WORK/volume"
APP="$VOLUME/Applications/Basket.app"

# Every process that runs from the image or (the swap helper) names it: the helper first, so that
# stopping Basket can't let it swap anything afterwards.
stop_processes() {
  local pid comm helpers=() apps=()
  for pid in $(pgrep -f "$VOLUME/" || true); do
    comm="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
    case "$comm" in
      /bin/sh | sh) helpers+=("$pid") ;;
      "$VOLUME"/*) apps+=("$pid") ;;
    esac
  done
  for pid in ${helpers[@]+"${helpers[@]}"}; do log "stopping the swap helper (pid $pid)"; kill -KILL "$pid" 2>/dev/null || true; done
  for pid in ${apps[@]+"${apps[@]}"}; do log "stopping Basket (pid $pid)"; kill -TERM "$pid" 2>/dev/null || true; done
  for pid in ${apps[@]+"${apps[@]}"}; do
    for _ in 1 2 3 4 5 6; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    kill -KILL "$pid" 2>/dev/null || true
  done
}

cleanup() {
  local status=$?
  stop_processes
  if mount | grep -qF " on $VOLUME ("; then
    hdiutil detach "$VOLUME" >/dev/null 2>&1 || hdiutil detach -force "$VOLUME" >/dev/null 2>&1 \
      || log "could not detach $VOLUME"
  fi
  [[ "$WORK" == */basket-update-e2e.* && -d "$WORK" ]] && rm -rf "$WORK"
  rm -rf "$GUI_LOCK"
  exit "$status"
}
trap cleanup EXIT

log "Basket $OLD_VERSION on a temporary disk image; the feed offers $NEW_VERSION"
hdiutil create -size 2g -fs APFS -volname BasketUpdateE2E -type SPARSE "$WORK/disk" >/dev/null
mkdir "$VOLUME"
hdiutil attach -nobrowse -noautoopen -mountpoint "$VOLUME" "$WORK/disk.sparseimage" >/dev/null
mkdir -p "$VOLUME/Applications"
ditto "$BUILD_DIR/Basket.app" "$APP"
# A reads its fixtures from here, not from the checkout: see stage_for_launch in _common.sh.
ditto "$ROOT/Fixtures/demo" "$WORK/fixtures"

B="$WORK/b/Basket.app"
mkdir -p "$WORK/b" "$WORK/feed"
ditto "$BUILD_DIR/Basket.app" "$B"
plutil -replace CFBundleShortVersionString -string "$NEW_VERSION" "$B/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$NEW_VERSION" "$B/Contents/Info.plist"
sign_app "$B" "$IDENTITY"
ZIP="$WORK/feed/Basket-$NEW_VERSION-arm64.zip"
ditto -c -k --keepParent "$B" "$ZIP"
PUBLIC_KEY="$(swift "$ROOT/scripts/update-keygen.swift" "$WORK/key/update-test.key")"
SIGNATURE="$(BASKET_UPDATE_SIGNING_KEY="$(cat "$WORK/key/update-test.key")" swift "$ROOT/scripts/update-sign.swift" "$ZIP")"
jq -n --arg version "$NEW_VERSION" --arg pub_date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg url "file://$ZIP" --arg sha256 "$(shasum -a 256 "$ZIP" | cut -d' ' -f1)" --arg signature "$SIGNATURE" \
  '{version: $version, pub_date: $pub_date, notes: "Update end-to-end test build.", minimum_system_version: "26.0",
    url: $url, sha256: $sha256, signature: $signature}' >"$WORK/feed/latest.json"

OUT="$ROOT/artifacts/update-e2e/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$OUT"
UPDATE_LOG="$HOME/Library/Logs/Basket/update.log"
LOG_START="$(wc -c <"$UPDATE_LOG" 2>/dev/null || echo 0)"
log "running BasketE2E.app update-install (log: $OUT/runner.log)"
# Through LaunchServices, so the Accessibility grant of BasketE2E.app applies (scripts/e2e.sh).
open -W -n "$BUILD_DIR/BasketE2E.app" --args update-install --app "$APP" --fixtures "$WORK/fixtures" \
  --feed "file://$WORK/feed/latest.json" --public-key "$PUBLIC_KEY" --expect-version "$NEW_VERSION" --out "$OUT"

[[ -f "$OUT/runner.log" ]] && cat "$OUT/runner.log"
# The swap helper's lines from this run (it logs only when something is worth saying).
tail -c +"$((LOG_START + 1))" "$UPDATE_LOG" 2>/dev/null | tee "$OUT/update.log" | sed 's/^/update.log: /' || true
if [[ ! -f "$OUT/result.json" ]]; then
  log "no result.json — the runner failed early"
  exit 2
fi
CODE="$(plutil -extract exitCode raw -o - "$OUT/result.json" 2>/dev/null || echo 2)"
if [[ "$CODE" == 3 ]]; then
  log "BasketE2E needs the Accessibility permission; see scripts/e2e.sh for how to grant it"
fi
echo "result: $OUT/result.json"
exit "$CODE"
