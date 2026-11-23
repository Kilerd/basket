# Evolution log

Basket evolves in iterations. Each iteration: build → self-test + AX audit → look at the
screenshots → compare with the OrbStack feature map below → pick the highest-value gaps (memory
and disk first) → implement → verify. Findings and decisions are logged here.

## OrbStack → Basket feature map

| OrbStack | Apple-native building block | Basket status |
|---|---|---|
| Containers UI (list, logs, terminal, stats) | `container list/logs/exec/stats` | 0.0.1 |
| Images, volumes, networks | `container image/volume/network` | 0.0.1 |
| Linux machines | `container machine` | 0.0.1 |
| Menu bar app | SwiftUI `MenuBarExtra` | 0.0.1 |
| Dynamic memory, low idle footprint | one lightweight VM per container (Virtualization.framework) | 0.0.1: real per-VM host memory shown |
| Disk: `data.img` that only grows | per-image content store, sparse volumes, `system df` | 0.0.1: usage + reclaim; host-platform-only pulls |
| Migrate from OrbStack / Docker | `docker save --platform` → `container image load` | 0.0.1: images (host platform only) + container recreation |
| Docker Compose | — (no compose in apple/container; no container-name DNS) | 0.0.1: Swift YAML parser, planner, `/etc/hosts` service discovery, grouped UI |
| `*.orb.local` domains | `container system dns create` (sudo) | planned |
| `docker build` | `container build` (BuildKit builder VM) | planned |
| Kubernetes | `container cluster` (experimental) | planned |
| Rosetta x86 | `--rosetta`, `--platform linux/amd64` | partial (run sheet) |
| Auto start at login | `SMAppService` + `system start` | 0.0.1 (login item) |
| `docker` CLI muscle memory | — | 0.0.1: translating `docker` shim (`~/.basket/bin/docker`, opt-in PATH block) |
| First-run setup | — | 0.0.1: setup assistant (install `container`, start system, migrate, `docker` shim) |
| Docker socket / Docker Engine API | — | open question: a Docker Engine API shim is large (`socktainer` exists) |

## Iterations

### 0.0.1 — foundation (2026-11-20)
- Environment: macOS 26.3, `container` 1.7.1 via Homebrew; OrbStack measured at 138 GB data,
  probe `alpine` container VM at ~235–265 MB host footprint with a 256 MB limit.
- Decisions: SwiftPM app bundled by script (no Xcode project); CLI JSON backend behind
  `ContainerBackend`; deterministic `FixtureBackend` for E2E; two AX test paths (in-process
  self-test without permissions, out-of-process `AXUIElement` runner with a one-time grant).
- Observation: a plain `container image pull alpine` stores every platform variant (10 for
  alpine). Basket pulls `linux/arm64` only by default.
- Result: ~10.8k lines of Swift; 142 tests (Core 70, AXKit 72) green; self-test AX audit
  0 errors / 0 warnings on `demo`, `empty`, `stopped` fixture sets and on the real CLI.
  Real numbers on the author's Mac: OrbStack 3.12 GB memory / 148 GB disk vs Basket 240 MB / 899 MB
  (one container).
- Measured: per-container VM overhead is ~230–310 MB regardless of the memory limit
  (256M → 240 MB, 1G → 287 MB, 2G → 312 MB). Host footprint follows the guest's high-water mark
  and never shrinks (guest touched 500 MB then freed: host stayed at 778 MB while the guest used
  55 MB) — no balloon / free-page reporting. Memory levers are therefore: stop idle containers,
  and restart containers holding stranded memory. Lowering limits only caps the high-water mark.

### 0.0.1 (continued) — review rounds, memory, migration, compose, setup, open source (2026-11-20)
- First independent review → CHANGES NEEDED. High: "Keep only arm64" deleted then re-pulled
  (local/loaded images lost — verified 401); restart = stop+start deletes `--rm` containers (flag
  invisible in list/inspect). Medium: `image prune --all` deletes more than the approved list;
  machine base images look unused; image delete dialog proceeded despite in-use warning; log follow
  hops to the main thread per line; ~90 CLI launches/min and 9–13% CPU while the window is visible.
  Verified sound: no fd/zombie leaks over 3,000 runs, no pipe deadlock at 50 MB, kill-on-timeout,
  shell quoting, `.command` file handling.
- Lanes: Memory (stranded memory + Memory Saver + polling cost + `--rm` safety), Migration
  (OrbStack images/containers, read-only, engine-up detection), Safety (local slim via
  save/load, exact-list prune, honest dialogs, batched logs, iterator-drop kills child), AX
  (remote AXUIElement E2E now that Accessibility is granted; global deadline).
- Open source: developed in public at <https://github.com/Kilerd/basket> under Apache-2.0.
  Governance follows AGENTS.md §6: issues first, one focused PR per change, CI green (build,
  tests, leak scan, accessibility self-test on `demo`/`empty`/`stopped`), one review,
  squash-merge, and a CHANGELOG entry for every user-visible change. README, CONTRIBUTING,
  SECURITY (private advisories), the Code of Conduct, issue and PR templates, CI and Dependabot
  were added. README screenshots come from the `demo` fixture self-test.
- User feedback: a ragged Memory column (bar after variable-width text) → fixed-slot cells and a
  new `column-alignment` AX rule that compares same-role elements across table rows; the bar
  became a real accessibility element (progress indicator).
- More lanes: Compose (Swift YAML parser, planner, grouped list, `/etc/hosts` discovery — real
  `up` → `nc db 6379` → `+PONG` → `down`), docker shim (`basket-docker`, ~11 ms start,
  `exec -it` TTY passthrough), onboarding (setup assistant), second review (3 high: name-only
  "already in Basket", reclaim sheet hiding items, a real user name in a fixture — all fixed,
  scanner blind spots closed).
- Measured: stranded-memory reclaim 809 MB → 287 MB (521 MiB back to macOS); Basket's own polling
  cost −30 % CPU (0.39 s/min with another app in front); log follow 20 % → 9 % CPU at
  ~3,800 lines/s; slim `alpine` 30.4 MB → 4.19 MB; OrbStack `busybox` import 6.14 MB → 1.92 MB.
- Result: 395 tests green; self-test 0/0 on `demo`, `empty`, `stopped`, `fresh` (17 snapshots);
  out-of-process E2E 0/0; leak scan clean. Shipped in `v0.0.1`.
- Process lesson: too many parallel lanes pushed the load average past 400 and made subprocess
  tests flaky — keep ≤ 3 build-heavy lanes at once.

### Release engineering and the first release (2026-11-20)
- Open-source flow in practice: issues #1–#24, every change through a PR with CI (leak scan,
  build, 395→452 tests, accessibility self-test on GitHub's `macos-26` runner) and squash merges.
- CI caught a real bug the fast local Mac hid: child output was dropped when readers ran later
  than a 1 s timer (#2) — fixed by draining to EOF; a delayed-reader test forces the race.
- Signed auto-update (CryptoKit Ed25519 + notarized Developer ID requirement, key list for
  rotation, re-verify around the swap) and a SemVer release workflow modelled on a protected
  environment: one approved job holds the secrets; verify checks the previous release's keys;
  publish re-checks the tag and attests every asset. An independent security review drove the
  hardening (SHA-pinned actions, dry runs without the production key, tag ruleset, immutable
  releases, no admin bypass).
- Gap found and closed: commits from agent worktrees scanned without the private word list
  (#23); a full-history rescan was clean.
- **v0.0.1 released**: DMG + update zip + `latest.json` + `SHA256SUMS` + provenance. Verified
  from a fresh download: checksums, Ed25519 signature with the production key, deep code
  signature, stapled notarization, Gatekeeper "Notarized Developer ID", attestations.
- Lessons: release-only constraints of personal repos (no Actions bypass in rulesets → the
  maintainer pushes tags); keep CHANGELOG additions conflict-friendly (every PR appends to the
  same Unreleased block — rebases needed manual merges).

### 0.0.2 — six languages (2026-11-21)
- Maintainer asked for multiple languages, then widened the scope twice (zh/ja/en/fr/de, then
  繁體中文). One String Catalog compiled by the build script into `<lang>.lproj` (no SwiftPM
  resource bundle), keys extracted with `swiftc -emit-localized-strings`, `check-l10n.sh` in CI.
  1,319 keys, fully translated in zh-Hans, zh-Hant, ja, fr, de.
- Two independent translation reviews (CJK; French + German) found real errors — zh-Hant
  translated `compose down` as "close" (it deletes), German used "laden" for pull, load and
  download, zh-Hans "项目" meant both "Compose project" and "items" — and settled conventions:
  CJK spacing (space between CJK and Latin/digits, none between a number and a CJK unit),
  Up/Down translated in zh/ja but kept in fr/de, `-AppleLocale` in self-tests so screenshots show
  real number formatting.
- Gates: self-test 0/0 in all six languages (demo + onboarding; empty/stopped in en/zh-Hans/de),
  CI runs zh-Hans and de self-tests. The out-of-process E2E needs an unlocked screen; it runs on
  `main` before the tag is pushed.
- Flaky tests fixed at the root: a watchdog that was cancelled but not awaited (#19), and
  macOS's first-launch check of every new executable serializing fake CLIs (#20) — the whole
  suite went from ~12 s to ~3 s.

### 0.0.3 — feedback round (2026-11-21)
- Maintainer feedback turned straight into issues and PRs: Settings moved into the sidebar with
  the language picker first (#30; live switching was tried and rejected — only plain SwiftUI text
  follows a locale override, ~650 code-built strings and AppKit menus don't, so Basket offers a
  one-click relaunch instead); the Disk card's breakdown now spans the card (#31) and a new AX
  rule, `card-trailing-alignment`, catches value columns that stop short of a card's edge;
  inspect JSON is tidied and highlighted with WCAG-AA system colours and ⌘F (#32).
- E2E lessons: an installed Basket with the same bundle id makes a second instance hang
  (issue #29), and a locked screen blocks LaunchServices-launched apps too — both looked alike.
- CI caught another wall-clock test (5 MB formatting under 3 s): timing tests now check
  scaling ratios, not absolute time.

### 0.0.4 — the update that couldn't quit (2026-11-23)
- The maintainer's first real in-app update (0.0.1 → 0.0.2) hung at "Installing…". The unified
  log said it plainly: `App termination blocked by modal sheet` — the update sheet itself stopped
  `NSApp.terminate`, and the swap helper gave up after 2 minutes, leaving 0.0.1 intact.
- The local update test had used the DEBUG auto-install path, which never shows the sheet. Now
  `scripts/update-e2e.sh` presses Install and Relaunch through the Accessibility API; it fails
  on the old code and passes with the fix (dismiss the sheet, escalate, last-resort exit).
- Releases ≤ 0.0.3 still run the old install code, so updating from them can stall once more
  (force-quit within 2 minutes, or install the DMG). From 0.0.4 on, updates quit cleanly.
- Debugging note: zsh's builtin `log` shadows `/usr/bin/log`.

## Research notes
- Compose: apple/container has no official Compose (PR #398 proposes it, unmerged as of 2026-10).
  Third-party: `container-compose` (mcrich23), `apple-compose` (Go). Known gap: service-name DNS on
  custom networks.
- Docker API: Apple closed the Docker-socket FR as not planned. `socktainer` (brew) exposes a
  partial Docker Engine API v1.51 socket on top of apple/container — candidate for an optional
  "Docker compatibility" toggle so existing `docker` workflows keep working.
