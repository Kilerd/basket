#!/usr/bin/env bash
# Regenerates Resources/Branding/AppIcon.icns from Resources/Branding/basket-star.png.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
SRC="$ROOT/Resources/Branding/basket-star.png"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
swift "$ROOT/scripts/make-icon.swift" "$SRC" "$WORK/icon-1024.png"
SET="$WORK/AppIcon.iconset"; mkdir -p "$SET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$WORK/icon-1024.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$WORK/icon-1024.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$ROOT/Resources/Branding/AppIcon.icns"
cp "$WORK/icon-1024.png" "$ROOT/Resources/Branding/AppIcon-1024.png"
log "wrote Resources/Branding/AppIcon.icns"
