# Changelog

All notable changes to Basket are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Versions are
`0.0.x` while Basket iterates quickly: every iteration that lands on `main` is released as the
next patch. Expect breaking changes until `0.1.0`.

## [Unreleased]

### Added

- Signed in-app updates: Basket checks GitHub Releases a minute after launch and then daily
  (Settings ▸ Updates, on by default) or on “Check for Updates…”, shows the release notes, and
  installs a new version only after its SHA-256, Ed25519 signature, bundle id, version and
  Developer ID code signature all check out; the old copy goes to the Trash. Disabled, with the
  reason, for ad-hoc builds and apps that can't replace themselves.

### Fixed

- Output of `container` commands could go missing on a heavily loaded Mac (empty error messages,
  lost log and progress lines): a command's stdout and stderr are now read to the end before it
  counts as finished. When a background process it started keeps the output open, Basket stops
  waiting after 1 s but still keeps everything the command itself wrote (#2).
- Compose: restarting a project restarts its services one at a time in dependency order, so a
  service that fails to start no longer leaves the others stopped; services started with `--rm`
  are skipped, and the banner lists what failed or was skipped (#1).

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

[Unreleased]: https://github.com/Kilerd/basket/compare/v0.0.1...HEAD
[0.0.1]: https://github.com/Kilerd/basket/releases/tag/v0.0.1
