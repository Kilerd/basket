#!/usr/bin/env bash
# Writes latest.json, the update manifest of a release (the contract is docs/updates.md), to stdout.
#   scripts/update-manifest.sh <version> <zip> <signature-base64> <notes-file> <minimum-system-version> <url>
# sha256 is computed from <zip>; pub_date is now, in UTC (UPDATE_PUB_DATE replaces it in tests).
# The release workflow checks the signature itself with scripts/update-verify.swift.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

[[ $# -eq 6 ]] || die "usage: scripts/update-manifest.sh <version> <zip> <signature-base64> <notes-file> <minimum-system-version> <url>" 64
V="$1" ZIP="$2" SIG="$3" NOTES="$4" MIN="$5" URL="$6"
NAME="$(basename "$ZIP")"

[[ "$V" =~ $SEMVER_RE ]] || die "version is not X.Y.Z"
[[ -f "$ZIP" ]] || die "no file $ZIP"
[[ "$SIG" =~ ^[A-Za-z0-9+/]{86}==$ ]] || die "the signature is not base64 of an Ed25519 signature (64 bytes)"
[[ -s "$NOTES" ]] || die "the notes file is empty"
[[ "$MIN" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die "minimum system version is not a macOS version"
[[ "$URL" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/download/v${V//./[.]}/(.+)$ \
   && "${BASH_REMATCH[1]}" == "$NAME" ]] \
  || die "url must be the GitHub release download of $NAME for v$V"
PUB="${UPDATE_PUB_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
[[ "$PUB" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || die "pub_date must be YYYY-MM-DDTHH:MM:SSZ"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

jq -n --arg version "$V" --arg pub_date "$PUB" --rawfile notes "$NOTES" \
  --arg minimum_system_version "$MIN" --arg url "$URL" --arg sha256 "$SHA" --arg signature "$SIG" \
  '{version: $version, pub_date: $pub_date, notes: ($notes | sub("\\s+$"; "")),
    minimum_system_version: $minimum_system_version, url: $url, sha256: $sha256, signature: $signature}'
