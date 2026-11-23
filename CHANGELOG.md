# Changelog

All notable changes to Basket are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Versions are
`0.0.x` while Basket iterates quickly: every iteration that lands on `main` is released as the
next patch. Expect breaking changes until `0.1.0`.

## [Unreleased]

### Added

- Settings ▸ General ▸ Appearance: System, Light or Dark (#46). Basket can stay light or dark
  whatever macOS uses; the choice applies at once, without a relaunch, to every window, sheet,
  menu and the menu bar extra, including the charts and the inspect JSON colours. System follows
  macOS, as before.

### Changed

- OrbStack migration appears only when OrbStack is installed (#47): the sidebar's “OrbStack”
  group with “Migrate from OrbStack” (and its ⌘7 shortcut in the View menu) and the setup
  assistant's “From OrbStack” step are hidden otherwise, and the step list is numbered without
  it. Basket notices OrbStack being installed or removed while it runs and moves from an open
  migration section to the Overview. OrbStack is found in `/Applications`, `~/Applications` or
  any other folder macOS knows it in (not the Trash or a mounted disk image).

### Fixed

- Light mode: the text of tags (“Rosetta”, “8 platforms”, “OrbStack running”, “In Basket”) and
  orange warnings and green confirmations were hard to read, at about 2:1 contrast; they are now
  darkened just enough to reach 4.5:1 (WCAG AA). Dark mode is unchanged where it already passed.

## [0.0.5] - 2026-11-23

**Using 0.0.1, 0.0.2 or 0.0.3? Don't click Install and Relaunch** — those versions' updater
stays at “Installing…” and can't finish, and force-quitting Basket doesn't help (see below).
Download `Basket-0.0.5.dmg` from <https://github.com/Kilerd/basket/releases/latest> instead,
quit Basket and drag the new one to Applications. **On 0.0.4,** update as usual: Install and
Relaunch takes a few seconds and needs no permission prompts.

### Changed

- Development: debug builds (`scripts/build-app.sh debug`, the self-test and the end-to-end
  tests) are now “Basket (Debug)” with the bundle id `dev.basket.app.debug`, so they no longer
  read or write the settings of an installed Basket (#29). `scripts/e2e.sh` runs a temporary copy
  of the app with its fixtures, so it no longer stalls on a macOS prompt for access to the
  folder holding the checkout. Release builds keep `dev.basket.app`.

### Fixed

- Updates: the installer now survives a crash or force quit of Basket (#41). It ran as a child
  of Basket, and a Force Quit (⌥⌘⎋, the Dock or Activity Monitor) ends an app together with the
  processes it started, so the installer stopped too and the update was never installed — which
  is also why force-quitting a stuck 0.0.1–0.0.3, as the 0.0.4 notes suggested, didn't finish the
  update. launchd now runs the installer as a one-shot job of its own and removes the job when the
  installer is done. `scripts/update-e2e.sh kill` ends Basket with SIGKILL and with a Force Quit
  right after “Installing…” and checks that the update still installs.

## [0.0.4] - 2026-11-23

**Upgrading from 0.0.1, 0.0.2 or 0.0.3 — please read.** Those versions have a bug in their
updater: after you click **Install and Relaunch**, the update window can stay at “Installing.
Basket quits and opens again…”. The new version has already been downloaded and verified; the old
Basket just can't quit on its own.

- **Install the DMG instead:** download `Basket-0.0.4.dmg` from this release and drag it to
  Applications.

*Correction:* these notes first said that force-quitting Basket within 2 minutes lets the update
finish. It doesn't — the force quit stops the installer too (#41).

From 0.0.4 on, updates install without this step. **0.0.1–0.0.3 are no longer recommended:
install 0.0.4 or later.**

### Fixed

- Updates: installing an update no longer hangs at “Installing. Basket quits and opens again…”
  (#38). The update sheet kept macOS from quitting Basket, so the installer gave up after 2
  minutes; now Basket closes the sheet before it quits, closes any other sheet, alert or dialog
  that still holds the quit up, and as a last resort exits, so the update always installs. A new
  end-to-end test, `scripts/update-e2e.sh`, installs an update through the real update sheet.

## [0.0.3] - 2026-11-21

### Added

- Inspect: the JSON of containers and images is tidied (two-space indentation, `"key": value`,
  `[]` / `{}` for empty arrays and objects, original key order) and highlighted with system
  colours that keep WCAG AA contrast in light and dark mode (#32). Find (⌘F) searches it, long
  lines scroll sideways instead of wrapping, and Copy JSON copies the tidied text. Large documents
  are formatted and coloured off the main thread.
- Settings in the sidebar (#30): a Settings item at the bottom of the sidebar shows the settings
  in the main window, with the language first (Settings ▸ General ▸ Language). ⌘, and
  “Settings…” in the app menu and the menu bar open it; the separate Settings window is gone.
  After choosing another language, Basket names it and offers Relaunch Now, which reopens on
  Settings in the new language.

### Fixed

- Overview: the Disk card's breakdown now spans the card, its numbers ending where the usage bar
  ends, like the Memory card's values; the number columns are sized for every language, and the
  OrbStack comparison's memory and disk bars line up (#31). A new accessibility-audit rule,
  `card-trailing-alignment`, flags a card whose value column stops short of the card's edge.

## [0.0.2] - 2026-11-21

### Added

- Localization: Basket is available in English, Simplified Chinese, Traditional Chinese,
  Japanese, French and German (#8). It follows the macOS language; Settings ▸ General ▸ Language
  overrides it. Sizes, numbers, durations, dates and lists follow the language's conventions.
  A Chinese README (`README.zh-CN.md`) and a terminology glossary (`docs/l10n/glossary.md`).

### Fixed

- Migration: an image import could report "Exporting" again after it had moved on to loading,
  or even after it had finished (#19).
- Migration: the "In Basket" column no longer cuts off its label while images are being
  compared (#17).

## [0.0.1] - 2026-11-20

The first public version.

### Added

- Native SwiftUI app for macOS 26 on Apple silicon that drives Apple's `container` CLI through
  its JSON output, behind a backend protocol (`ContainerBackend`).
- Overview: real host memory per container VM (macOS footprint) split into guest in use, VM
  overhead and stranded memory; disk usage by category with reclaimable space; container
  system status with start/stop; an OrbStack vs Basket comparison when OrbStack is installed.
- Reclaim memory: restarts only the containers you select, one at a time, to return stranded
  memory to macOS. Memory Saver (off by default) stops containers idle for 15–120 minutes and
  never stops exempt, machine-backed or `--rm` containers.
- Containers: aligned list with state, ports, CPU, guest and host memory; start, stop, restart,
  kill and delete; logs with batched follow, inspect, live stats, shell in Terminal, open
  published port, copy IP; a run sheet with small memory defaults.
- Docker Compose: projects grouped in the container list with project start/stop/restart/down
  and merged logs; Compose Up… with a Swift YAML parser, `${VAR}` interpolation and `.env`,
  a plan sheet showing memory cost and what doesn't carry over, and service discovery through
  managed `/etc/hosts` entries (apple/container has no DNS between containers).
- Images: host-platform-only pulls by default (`linux/arm64`), extra-platform badges, "used
  by" column (machines included), "Keep only linux/arm64" slimming done locally
  (save → load → verify, never deleting the original first), run and delete.
- Migrate from OrbStack: lists OrbStack images and containers, imports images for this Mac's
  platform with content verification ("Name conflict" for same-name, different images), and
  recreates containers as `container run` commands with warnings.
- `docker` command: an optional shim (`basket-docker`, installed as `~/.basket/bin/docker` only
  when enabled) that translates everyday `docker` commands and flags to `container`.
- Guided setup: requirement checks, installing `container` (Homebrew or the official
  installer), starting the system, OrbStack migration and the `docker` command.
- Volumes, networks and Linux machines: list, create and delete. Menu bar extra with memory,
  idle containers and reclaim. Settings: CLI path, refresh interval, default memory, Memory
  Saver, launch at login, setup.
- Accessibility testing: an in-process self-test (`scripts/selftest.sh`, no permissions) and an
  out-of-process `AXUIElement` end-to-end runner (`scripts/e2e.sh`), with lint rules (labels,
  clipping, overlap, hit targets, truncation, column alignment, cross-section consistency) and
  a shared identifier contract. Synthetic `demo`, `empty`, `stopped` and `fresh` fixture sets.
- Open-source project setup: README, contributing guide, code of conduct, security policy,
  issue and PR templates, CI (build, tests, self-test, leak scan), Dependabot for GitHub
  Actions, CODEOWNERS. Licensed under Apache-2.0.
- Signed in-app updates: Basket checks GitHub Releases a minute after launch and then daily
  (Settings ▸ Updates, on by default) or on “Check for Updates…”, shows the release notes, and
  installs a new version only after its SHA-256, Ed25519 signature (from any of the app's trusted
  keys, so the key can be rotated), bundle id, version and notarized Developer ID code signature
  all check out. The code signature is checked again right before and right after the app is
  replaced, and the old copy is put back if either check fails; otherwise it goes to the Trash.
  Disabled, with the reason, for ad-hoc builds and apps that can't replace themselves.
- Release workflow (`.github/workflows/release.yml`): semver releases from a `vX.Y.Z` tag the
  maintainer pushes after a release pull request (`scripts/release-prep.sh`), built on GitHub's
  runners and published with a signed, notarized DMG, the update zip, `latest.json` for in-app
  updates, `SHA256SUMS` and build provenance attestations. Signing happens in one job of the
  protected `release` environment; the update signature is checked against the keys the previous
  release trusts; the release is published only while its tag still points at the built commit.
  Dry runs publish nothing, never use the update signing key and keep reports only. Actions are
  pinned by commit. See `docs/RELEASING.md`.

### Security

- Data safety: no CLI `prune`; reclaim deletes exactly the approved, snapshotted items;
  in-use deletions default to Cancel; `--rm` containers are never restarted or auto-stopped;
  quitting mid-operation cleans up temporary archives.
- OrbStack is accessed only through an allowlist of read-only `docker --context orbstack`
  commands, and only while its engine is already running.
- Confidentiality guard: `scripts/check-leaks.sh` scans for credentials, personal paths (also
  JSON-escaped and inside binary files), signing identities, the local identity and a private
  word list, in the pre-commit and commit-msg hooks and in CI.
- The app and its helper are signed with the hardened runtime; the signing identity is
  discovered at build time and never hard-coded. Terminal shells open through self-deleting
  `.command` files with shell-quoted arguments.

[Unreleased]: https://github.com/Kilerd/basket/compare/v0.0.5...HEAD
[0.0.5]: https://github.com/Kilerd/basket/compare/v0.0.4...v0.0.5
[0.0.4]: https://github.com/Kilerd/basket/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/Kilerd/basket/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/Kilerd/basket/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/Kilerd/basket/releases/tag/v0.0.1
