#!/usr/bin/env bash
# Regenerates the README screenshots in docs/images/ from the synthetic `demo` fixtures (never
# from a real machine — AGENTS.md §1): runs the self-test, then re-encodes the chosen PNGs as
# metadata-free sRGB at ≤ 1600 px wide.
#   scripts/readme-shots.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

"$ROOT/scripts/selftest.sh" demo >/dev/null
RUN="$(ls -td "$ROOT"/artifacts/selftest/demo-* | head -1)"
ONB=""
if [[ -d "$ROOT/Fixtures/fresh" ]]; then
  BASKET_ONBOARDING=1 "$ROOT/scripts/selftest.sh" fresh >/dev/null || true
  ONB="$(ls -td "$ROOT"/artifacts/selftest/fresh-* 2>/dev/null | head -1)"
fi

mkdir -p "$ROOT/docs/images"
shot() { # <source png> <name>
  [[ -f "$1" ]] || { log "skip $2 (no $(basename "$1"))"; return 0; }
  swift "$ROOT/scripts/sanitize-png.swift" "$1" "$ROOT/docs/images/$2.png" 1600
  log "docs/images/$2.png"
}
shot "$RUN/overview.png" overview
shot "$RUN/containers.png" containers
shot "$RUN/images.png" images
shot "$RUN/migration.png" migration
[[ -n "$ONB" ]] && shot "$ONB/onboarding-welcome.png" onboarding
"$ROOT/scripts/check-leaks.sh" --all >/dev/null
log "screenshots refreshed from $RUN"
