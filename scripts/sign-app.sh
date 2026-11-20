#!/usr/bin/env bash
# Signs an already built Basket.app again, the way build-app.sh signs it (helper first, hardened
# runtime). The release workflow builds an ad-hoc app in a job without secrets; its `release`
# job then signs that app with the Developer ID here (docs/RELEASING.md).
#   BASKET_SIGN_IDENTITY=<identity> [BASKET_SIGN_TIMESTAMP=1] scripts/sign-app.sh <Basket.app>
# The identity is never printed.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

APP="${1:-}"
[[ -n "$APP" ]] || die "usage: $0 <Basket.app>" 64
[[ -x "$APP/Contents/MacOS/Basket" && -x "$APP/Contents/Helpers/basket-docker" ]] || die "not a Basket.app: $APP" 64
[[ -n "${BASKET_SIGN_IDENTITY:-}" ]] || die "set BASKET_SIGN_IDENTITY" 64

sign_app "$APP" "$BASKET_SIGN_IDENTITY"
log "signed $APP ($([[ "$BASKET_SIGN_IDENTITY" == "-" ]] && echo ad-hoc || echo "with the given identity"))"
