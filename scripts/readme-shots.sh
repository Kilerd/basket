#!/usr/bin/env bash
# Regenerates the README screenshots from the synthetic `demo` fixtures (never from a real
# machine — AGENTS.md §1): runs the self-test, then re-encodes the chosen PNGs as metadata-free
# sRGB at ≤ 1600 px wide.
#   scripts/readme-shots.sh             English → docs/images/
#   scripts/readme-shots.sh zh-Hans     another language (BASKET_LANGUAGE) → docs/images/zh-Hans/
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

LANGUAGE="${1:-}"
[[ "$LANGUAGE" == en ]] && LANGUAGE=""
DEST="$ROOT/docs/images${LANGUAGE:+/$LANGUAGE}"
SUFFIX="${LANGUAGE:+-$LANGUAGE}"

# Self-test output directories are <set>[-<language>]-<YYYYmmdd-HHMMSS>.
latest_run() { ls -td "$ROOT/artifacts/selftest/$1$SUFFIX"-20[0-9][0-9][01][0-9]* 2>/dev/null | head -1; }

BASKET_LANGUAGE="$LANGUAGE" "$ROOT/scripts/selftest.sh" demo >/dev/null
RUN="$(latest_run demo)"
[[ -n "$RUN" ]] || die "no self-test run found for demo$SUFFIX"
ONB=""
if [[ -d "$ROOT/Fixtures/fresh" ]]; then
  BASKET_LANGUAGE="$LANGUAGE" BASKET_ONBOARDING=1 "$ROOT/scripts/selftest.sh" fresh >/dev/null || true
  ONB="$(latest_run fresh)"
fi

mkdir -p "$DEST"
shot() { # <source png> <name>
  [[ -f "$1" ]] || { log "skip $2 (no $(basename "$1"))"; return 0; }
  swift "$ROOT/scripts/sanitize-png.swift" "$1" "$DEST/$2.png" 1600
  log "${DEST#"$ROOT"/}/$2.png"
}
shot "$RUN/overview.png" overview
shot "$RUN/containers.png" containers
shot "$RUN/images.png" images
shot "$RUN/migration.png" migration
[[ -n "$ONB" ]] && shot "$ONB/onboarding-welcome.png" onboarding
"$ROOT/scripts/check-leaks.sh" --all >/dev/null
log "screenshots refreshed from $RUN"
