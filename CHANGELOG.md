# Changelog

All notable changes to Basket are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Versions are
`0.0.x` while Basket iterates quickly: every iteration that lands on `main` is released as the
next patch. Expect breaking changes until `0.1.0`.

## [Unreleased]

### Added

- Inspect: the JSON of containers and images is tidied (two-space indentation, `"key": value`,
  `[]` / `{}` for empty arrays and objects, original key order) and highlighted with system
  colours that keep WCAG AA contrast in light and dark mode (#32). Find (⌘F) searches it, long
  lines scroll sideways instead of wrapping, and Copy JSON copies the tidied text. Large documents
  are formatted and coloured off the main thread.

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

[Unreleased]: https://github.com/Kilerd/basket/compare/v0.0.2...HEAD
[0.0.2]: https://github.com/Kilerd/basket/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/Kilerd/basket/releases/tag/v0.0.1
