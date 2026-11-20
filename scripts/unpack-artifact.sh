#!/usr/bin/env bash
# Unpacks an artifact of the release workflow, refusing anything unexpected (docs/RELEASING.md):
#   scripts/unpack-artifact.sh <tar> <sha256> <new-or-empty-dir> <member-ERE>
# - the tar's sha256 must be the one its job put out (an artifact replaced while the run waited
#   for the release approval is refused);
# - it must be a plain, uncompressed tar of regular files and directories only (no links, no
#   devices), every member a relative path without `..` that matches <member-ERE>.
set -euo pipefail

die() { printf 'unpack-artifact: %s\n' "$*" >&2; exit 1; }
[[ $# -eq 4 ]] || { echo "usage: scripts/unpack-artifact.sh <tar> <sha256> <dir> <member-ERE>" >&2; exit 64; }
TAR="$1" WANT="$2" DEST="$3" ALLOW="$4"
NAME="$(basename "$TAR")"

[[ -f "$TAR" ]] || die "no file $TAR"
[[ "$WANT" =~ ^[0-9a-f]{64}$ ]] || die "the expected sha256 of $NAME is not 64 hex characters"
GOT="$(shasum -a 256 "$TAR" | cut -d' ' -f1)"
[[ "$GOT" == "$WANT" ]] || die "$NAME has sha256 $GOT, not $WANT (the one its job put out)"
# A plain tar has "ustar" at offset 257; tar would pick a decompressor for anything else.
[[ "$(dd if="$TAR" bs=1 skip=257 count=5 2>/dev/null)" == ustar ]] || die "$NAME is not a plain tar"

NAMES="$(tar -tf "$TAR")"
TYPES="$(tar -tvf "$TAR" | cut -c1)"
[[ -n "$NAMES" ]] || die "$NAME is empty"
[[ "$(printf '%s\n' "$NAMES" | wc -l)" == "$(printf '%s\n' "$TYPES" | wc -l)" ]] \
  || die "$NAME has member names that cannot be listed one per line"
while IFS= read -r member <&3 && IFS= read -r type <&4; do
  case "$type" in -|d) ;; *) die "$NAME: '$member' is not a regular file or directory" ;; esac
  path="${member%/}"
  [[ -n "$path" && "$path" != /* && "/$path/" != */../* && "/$path/" != */./* ]] \
    || die "$NAME: '$member' is not a plain relative path"
  [[ "$path" =~ $ALLOW ]] || die "$NAME: '$member' is not an expected member"
done 3<<<"$NAMES" 4<<<"$TYPES"

if [[ -e "$DEST" ]]; then
  [[ -d "$DEST" && -z "$(ls -A "$DEST")" ]] || die "$DEST exists and is not an empty directory"
fi
mkdir -p "$DEST"
tar -xf "$TAR" -C "$DEST"
echo "unpacked $NAME (sha256 $GOT) into $DEST"
