#!/usr/bin/env bash
# Makes the drag-to-Applications disk image of a release (docs/RELEASING.md): the app and a link
# to /Applications, compressed (UDZO). Signing and notarizing it is the release workflow's job.
#   scripts/make-dmg.sh <Basket.app> <out.dmg> <volume-name>
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

APP="${1:-}" OUT="${2:-}" VOLUME="${3:-}"
[[ $# -eq 3 && -d "$APP" && -n "$OUT" && -n "$VOLUME" ]] \
  || die "usage: scripts/make-dmg.sh <Basket.app> <out.dmg> <volume-name>" 64
[[ ! -e "$OUT" ]] || die "$OUT exists"

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"
# hdiutil occasionally fails with "Resource busy" on CI runners.
for attempt in 1 2 3; do
  if hdiutil create -volname "$VOLUME" -srcfolder "$STAGE" -fs HFS+ -format UDZO \
      -imagekey zlib-level=9 -ov "$OUT" >&2; then
    break
  fi
  (( attempt < 3 )) || die "hdiutil create failed"
  log "hdiutil create failed (attempt $attempt); retrying"
  sleep 10
done
hdiutil verify "$OUT" >&2
log "made $OUT"
