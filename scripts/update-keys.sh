#!/usr/bin/env bash
# Prints the update public keys a build of Basket trusts (docs/updates.md, "Keys"): the base64
# literals of `UpdateVerifier.trustedPublicKeysBase64` in
# Sources/BasketCore/Update/UpdateVerifier.swift, one per line, from the working tree or from
# <git-rev> (a release tag: the keys that release's installed copies trust).
#   scripts/update-keys.sh [<git-rev>]
#
# Exits 0 with at least one key; 1 when the list is missing, duplicated, empty or holds
# anything but key literals, commas and `//` comments; 3 when the file does not exist there
# (a release without the updater).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

FILE=Sources/BasketCore/Update/UpdateVerifier.swift
[[ $# -le 1 ]] || die "usage: scripts/update-keys.sh [<git-rev>]" 64

if [[ $# == 1 ]]; then
  REV="$1"
  [[ "$REV" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$ ]] || die "invalid revision" 64
  git -C "$ROOT" rev-parse --verify --quiet "$REV^{commit}" >/dev/null || die "unknown revision $REV"
  if ! git -C "$ROOT" cat-file -e "$REV:$FILE" 2>/dev/null; then
    log "$REV has no $FILE (no updater)"
    exit 3
  fi
  WHERE="$REV"
  read_source() { git -C "$ROOT" show "$REV:$FILE"; }
else
  if [[ ! -f "$ROOT/$FILE" ]]; then
    log "no $FILE (no updater)"
    exit 3
  fi
  WHERE="the working tree"
  read_source() { cat "$ROOT/$FILE"; }
fi

# The array literal after `trustedPublicKeysBase64: [String] =`, read token by token: anything
# that is not a 32-byte base64 literal, a comma, whitespace or a line comment is refused.
rc=0
keys="$(read_source | perl -0777 -ne '
  my @lists = /trustedPublicKeysBase64\s*:\s*\[String\]\s*=\s*\[(.*?)\]/sg;
  exit 2 unless @lists == 1;
  my $body = $lists[0];
  my @keys;
  while (length $body) {
    next if $body =~ s/^\s+//;
    next if $body =~ s/^,//;
    next if $body =~ s{^//[^\n]*}{};
    if ($body =~ s{^"([A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=)"}{}) { push @keys, $1; next }
    exit 3;
  }
  exit 4 unless @keys;
  print "$_\n" for @keys;
')" || rc=$?
case "$rc" in
  0) ;;
  2) die "$FILE in $WHERE has no (or more than one) \`trustedPublicKeysBase64: [String] = [...]\`" ;;
  3) die "UpdateVerifier.trustedPublicKeysBase64 in $WHERE holds something other than base64 key literals" ;;
  4) die "UpdateVerifier.trustedPublicKeysBase64 in $WHERE is empty" ;;
  *) die "cannot read $FILE in $WHERE" ;;
esac
printf '%s\n' "$keys"
