# Shared brief for Basket workers

Read `docs/ARCHITECTURE.md` first. It is the source of truth for layout, env switches and the
accessibility-identifier contract.

## Environment
- Repo: the checkout root (public at github.com/Kilerd/basket). **Workers never commit or push — the lead does git.**
- macOS 26.3, Apple silicon, Swift 6.3, Xcode 26.6 at `/Applications/Xcode.app`.
  `xcode-select` points at CommandLineTools, so **always** `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
  before `swift build` / `swift test`.
- Several workers share this checkout. **Use your own scratch path**: `swift build --scratch-path .build-<lane>`
  (`swift test --scratch-path .build-<lane>`). Never delete other lanes' scratch dirs.
- `container` CLI 1.7.1 is installed (`/opt/homebrew/bin/container`) and its system service is running.
  Real output samples: `Tests/BasketCoreTests/Fixtures/*.json` (captured from a running `probe-alpine`).
- Signing: scripts pick `$BASKET_SIGN_IDENTITY`, else the first "Developer ID Application" identity from
  `security find-identity -v -p codesigning`, else ad-hoc. A stable identity keeps the Accessibility grant across rebuilds.

## Hard limits
- **The repo is public.** Never commit data from the host: no names from the user's OrbStack/Docker, no env values,
  no personal paths (use `/Users/demo/...`), no secrets. Fixtures are synthetic content in the real JSON shape.
- **Do not touch OrbStack or Docker state.** The user runs real workloads there. Read-only commands
  (`docker images`, `docker ps`, `du`, `ps`, `footprint`) are fine; never stop/remove/modify anything.
- `container` state: only create resources prefixed `basket-test-` (or the existing `probe-alpine`) and
  delete what you create. Never `container system stop`, never prune globally, never touch kernel/DNS (sudo).
- No third-party dependencies. Apple frameworks only.
- Stay inside your lane's files. `Sources/BasketCore/Domain.swift` is the contract: only the Core lane
  may change it, and only additively (new fields with defaults; new protocol requirements with a
  default implementation) — never rename or remove.
- If you need something from another lane, don't edit their files: code against the documented API,
  and list the need in your report.
- If the build breaks because of files in another lane mid-edit, wait ~1 minute and retry; don't "fix" them.
- GUI windows you launch appear on the user's screen: keep runs short and always terminate what you start.

## Style
Swift 6 language mode (strict concurrency). SwiftUI + Observation (`@Observable`), async/await, no
Combine unless needed. Small files grouped by feature. Comments only where the why isn't obvious.
Tests use swift-testing (`import Testing`).

## Report back (≤ 40 lines)
1. Outcome: DONE / PARTIAL / BLOCKED
2. What was built (bullets, file — purpose)
3. Verification: exact commands + results
4. Gaps, risks, contract changes, needs from other lanes
No full diffs or files.

## Since v0.1 (read this too)
- The app, backends and AX toolkit exist. Learn the code you touch before changing it; keep the existing
  structure (`Sources/Basket/App/AppStore*.swift` = state/actions, `Views/<Section>/` = UI,
  `Support/Components.swift` = shared UI pieces, `Sources/BasketCore/` = backends).
- **Quality gate for any UI change:** `BASKET_SCRATCH=.build-<lane> BASKET_BUILD_DIR=$PWD/build/<lane> scripts/selftest.sh demo` (also `empty`
  and `stopped` if you touched states) must end with 0 errors and 0 warnings, and you must look at the PNGs
  it writes under `artifacts/selftest/` (Read renders images) — misaligned, clipped or inconsistent UI is a
  failure even if the lint passes. `BASKET_SELFTEST_EXTRAS=1` also captures sheets/detail tabs/Settings.
- New sections/sheets must follow the AX identifier contract in docs/ARCHITECTURE.md; extend the contract
  doc and `AXAuditor` contract rule together if you add a section.
- Full test suite: `swift test --scratch-path .build-<lane>` (all 142+ tests must stay green).
- Fixture changes: keep `Fixtures/*` in raw CLI format and update FixtureBackend tests.
- Measured facts: each container VM costs ~230–310 MB host memory regardless of its limit; host footprint
  follows the guest's high-water mark and never shrinks until the VM restarts (no balloon).
- **True E2E (Accessibility is granted to BasketE2E.app):** `BASKET_SCRATCH=.build-<lane> BASKET_BUILD_DIR=$PWD/build/<lane> scripts/e2e.sh demo`
  drives the app out of process via AXUIElement (what VoiceOver sees) and must exit 0 with 0 warnings for UI changes.
  It takes ~1 min and shows the app on screen. Role-less elements (AXUnknown) usually come from
  `.accessibilityElement(children: .ignore)` + label — prefer `.combine` on a real container.
- Alignment is part of the gate (user feedback, 2026-11-20): in tables/repeated rows, same-type elements
  (bars, icons, numbers) must line up down each column at full resolution; numbers `.monospacedDigit()` in a
  fixed-width right-aligned slot; a bar never follows variable-width text.
