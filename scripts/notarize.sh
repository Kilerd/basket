#!/usr/bin/env bash
# Notarizes a release file with Apple's notary service and staples the ticket (docs/RELEASING.md).
#   APPLE_ID=… APPLE_PASSWORD=… APPLE_TEAM_ID=… scripts/notarize.sh <submission> [<staple-target>]
# <submission> is a zip of the app (ditto -c -k --keepParent) or a disk image; the ticket is
# stapled to <staple-target> (default: the submission; for a zip, pass the app). Waits for Apple's
# answer; anything but "Accepted" prints Apple's log and fails. APPLE_PASSWORD is an app-specific
# password of APPLE_ID. The credentials are never printed.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

FILE="${1:-}"
TARGET="${2:-$FILE}"
[[ $# -ge 1 && $# -le 2 && -f "$FILE" && -e "$TARGET" ]] \
  || die "usage: scripts/notarize.sh <submission> [<staple-target>]" 64
[[ -n "${APPLE_ID:-}" && -n "${APPLE_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]] \
  || die "set APPLE_ID, APPLE_PASSWORD and APPLE_TEAM_ID" 64

OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
AUTH=(--apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID")

log "notarizing $(basename "$FILE"); waiting for Apple"
rc=0
xcrun notarytool submit "$FILE" "${AUTH[@]}" --wait --timeout 1h --output-format json >"$OUT/submit.json" || rc=$?
id="$(plutil -extract id raw -o - "$OUT/submit.json" 2>/dev/null || true)"
status="$(plutil -extract status raw -o - "$OUT/submit.json" 2>/dev/null || true)"
[[ "$id" =~ ^[0-9a-fA-F-]{36}$ ]] || id=""
log "notary service: ${status:-no answer} (submission ${id:-unknown}, notarytool exit $rc)"
if [[ "$status" != Accepted ]]; then
  if [[ -n "$id" ]] && xcrun notarytool log "$id" "${AUTH[@]}" "$OUT/log.json" >/dev/null 2>&1; then
    cat "$OUT/log.json" >&2
  fi
  die "Apple did not accept $(basename "$FILE")"
fi

xcrun stapler staple "$TARGET" >&2
xcrun stapler validate "$TARGET" >&2
log "notarized and stapled $(basename "$TARGET")"
