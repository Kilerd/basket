# Basket — architecture

Basket is a native macOS app (SwiftUI, macOS 26+, Apple silicon) that replaces OrbStack with
Apple's own container stack: [apple/container](https://github.com/apple/container) on top of
Virtualization.framework. Every container runs in its own lightweight VM, so memory is paid per
container and returned when it stops; there is no always-on Linux VM and no ever-growing
`data.img`.

**Product focus: memory and disk.** OrbStack's pain points are a large resident VM and a data
image that only grows (138 GB measured on the author's machine). Basket makes both visible and
reclaimable: real host memory per container VM, disk usage by category with one-click reclaim,
host-platform-only image pulls (a multi-arch pull of `alpine` stores ~10 variants), sparse
volumes, and a side-by-side comparison with an installed OrbStack.

## Layout

```
Package.swift                 SwiftPM; build with DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
Sources/BasketCore/           Domain model + backends (no UI)
  Domain.swift                UI-facing model + `ContainerBackend` protocol (the contract)
  CLI*/                       `CLIBackend`: runs the `container` CLI with `--format json`
  Fixture*/                   `FixtureBackend`: serves raw CLI JSON from a directory (E2E)
  HostResources*/             phys_footprint of container VMs, OrbStack inspection
  Migration/                  OrbStack → Basket: read-only docker access, image import, container recreation
  Compose/                    YAML parser, compose loader/planner, project grouping, up/down/start/stop
  Update/                     Signed self-update: manifest, Ed25519 + code-signature checks, installer, swap helper
  JSON/                       JSONFormatter: one-pass re-indent of inspect JSON + highlight tokens
Sources/Basket/               SwiftUI app (main window and its sections, Settings included; menu bar extra)
Sources/BasketAXKit/          Accessibility snapshot model, capture (in-process + AXUIElement), lint rules, reports
Sources/basket-ax/            E2E runner CLI (`audit` drives Basket.app via AX; `lint` checks dumped snapshots;
                              `update-install` installs an update through the UI, for update-e2e.sh)
Fixtures/demo/                Rich, deterministic raw-CLI JSON used by FixtureBackend in E2E runs
Fixtures/fresh/               A new Mac: no `container` CLI (`cli-missing`), OrbStack installed — onboarding self-test
Tests/BasketCoreTests/        Decoder/backend tests; Fixtures/ = container 1.7.1 output from throwaway test
                              containers on public images, scrubbed of host paths and user names
Tests/BasketAXKitTests/       Lint-rule tests on synthetic AX trees
Resources/Localization/       Localizable.xcstrings — every UI string, all languages (see Localization)
scripts/                      build-app.sh, build-e2e-runner.sh, selftest.sh, e2e.sh, update-e2e.sh, sync-strings.sh, check-l10n.sh
```

## Localization

Basket is localized into English (source), Simplified Chinese, Traditional Chinese, Japanese,
French and German; terms and typography are in [l10n/glossary.md](l10n/glossary.md).

- **One String Catalog**, `Resources/Localization/Localizable.xcstrings`, keyed by the English
  text. `scripts/build-app.sh` compiles it with `xcrun xcstringstool compile` into
  `Basket.app/Contents/Resources/<lang>.lproj` (`Localizable.strings`, plus `.stringsdict` for
  plurals) and lists those languages in `CFBundleLocalizations`; `CFBundleDevelopmentRegion` is
  `en`. It is not a SwiftPM resource bundle: `Bundle.module` inside a hand-assembled app is fragile,
  and `Bundle.main` is where SwiftUI and `String(localized:)` look by default.
- **Keys come from the compiler.** `scripts/sync-strings.sh` builds the `Basket` product with
  `swiftc -emit-localized-strings` (its own scratch path, `<scratch>-strings`) and merges the
  `.stringsdata` of the Basket and BasketCore sources with `xcstringstool sync`: new keys are
  added, unused ones marked stale (`--prune` drops them). `scripts/check-l10n.sh` (CI) fails when
  the catalog is out of date, a key lacks a translation in any language, placeholders don't match,
  or the catalog doesn't compile; `scripts/l10n.swift` does the catalog checks and imports/exports
  translations as JSON.
- **In code**: SwiftUI literals are `LocalizedStringKey`s; text built in code uses
  `String(localized:)`. BasketCore uses `String(localized: …, bundle: .main)`, so tests (no app
  bundle) see the English keys and the `basket-docker` CLI stays English. Plurals are catalog
  variations (a plural form must contain the number; it varies on the first integer argument);
  lists use `ListFormatStyle`, and sizes, percentages, durations and dates use formatters.
  Accessibility identifiers are never localized.
- **Language**: macOS's preferred languages, or Settings ▸ General ▸ Language (the Settings
  section at the bottom of the sidebar, ⌘,), which writes `AppleLanguages` in Basket's own
  defaults. It takes effect after a relaunch: the section then says “Relaunch Basket to switch to
  <language>” next to Relaunch Now, which quits normally and reopens Basket on Settings. It is
  not applied live on purpose: injecting `.environment(\.locale, …)` re-resolves only SwiftUI
  `Text("…")` literals, while the ~650 `String(localized:)` texts (sidebar, window titles, status
  bars, states, BasketCore messages), the formatters (`Format`, dates) and the AppKit menus keep
  the launch language — a window half in one language and half in another. Self-test and E2E
  pick one with `BASKET_LANGUAGE=<id>`: `-AppleLanguages (<id>)` plus the matching region format
  `-AppleLocale` (`app_locale` in `scripts/_common.sh`: fr_FR, de_DE, ja_JP, zh_CN, zh_TW, en_US),
  for that run only, so screenshots show the language's number and date formats ("4,21 Go"); the
  E2E runner takes `--language <id> --locale <id>`.

## Appearance

Settings ▸ General ▸ Appearance (`settings.appearance`, right after Language) offers System, Light
and Dark (`AppAppearance`, state in `AppearanceChoice`). Unlike the language it applies at once and
app-wide: it sets `NSApp.appearance` (nil, `.aqua`, `.darkAqua`), so every window, sheet, alert,
menu, the Settings section and the menu bar extra follow it. The choice is saved as `appearance`
(`system` is the absent key) in Basket's own defaults, the running bundle's domain, and applied in
`applicationWillFinishLaunching`, before the first window. UI-test runs neither read nor write it
and start at System; `BASKET_APPEARANCE=system|light|dark` sets one run's appearance without
saving it. “System” is the Language picker's word for “follow macOS”, not Apple's “Auto”, which
in System Settings switches by time of day; Basket follows whatever macOS shows, Auto included.

A live switch only works with dynamic colours: system colours, `Color(light:dark:)` (the chart and
meter series) and `ReadableColor`, which resolves a colour per appearance and moves it toward black
or white just far enough to reach WCAG AA (4.5:1) on the surfaces it sits on: the inspect JSON
palette (`JSONPalette`), the text of tinted capsules (`Pill`: “Rosetta”, “8 platforms”) and status
text (`Color.warningText`, `Color.successText`); plain orange or green text is about 2:1 on a light
background. Never store a colour resolved once (`cgColor`, `usingColorSpace` outside a dynamic
provider): it keeps the appearance it was resolved in. The self-test captures every section in
both appearances through the setting itself (`<section>-light.png`, `<section>-dark.png`).

## Why the CLI and not ContainerClient/XPC

`container … --format json` is the documented, versioned interface; linking `ContainerClient`
ties the app to the apiserver's internal XPC protocol and its release cadence. A list call costs
~45 ms, cheap enough to poll. The backend sits behind `ContainerBackend`, so an XPC backend can
replace it later without touching the UI.

## Runtime switches (environment variables)

| Variable | Meaning |
|---|---|
| `BASKET_BACKEND` | `cli` (default) or `fixtures` |
| `BASKET_FIXTURES_DIR` | directory for `FixtureBackend` (e.g. `Fixtures/demo`) |
| `BASKET_CONTAINER_CLI` | explicit path to the `container` binary |
| `BASKET_UI_TEST` | `1` = deterministic UI: fixed 1280×820 window, no animations, no polling jitter |
| `BASKET_INITIAL_SECTION` | sidebar section to open first (`overview`, `containers`, …, `settings`) |
| `BASKET_SELFTEST_DIR` | self-test: visit every section, write `<section>.png` + `<section>.ax.json` (plus `settings-end`, the end of the Settings form, and `settings-language`, the relaunch prompt after a language change; UI-test runs never save the language), then every section again as `<section>-light.png` and `<section>-dark.png` (switched through Settings ▸ General ▸ Appearance, never saved), then quit |
| `BASKET_APPEARANCE` | `system`, `light` or `dark`: this run's appearance instead of the one chosen in Settings, never saved (`scripts/selftest.sh` passes it on; the E2E runner keeps the system appearance) |
| `BASKET_DOCKER_CLI` | explicit path to the `docker` binary used to read OrbStack (default: OrbStack's own) |
| `BASKET_ONBOARDING` | `1` = open "Set Up Basket" at launch even in UI-test/self-test runs (otherwise it opens only on first launch or when the CLI is missing, and never in UI tests); with `BASKET_SELFTEST_DIR` the self-test walks every step first (`onboarding-<step>[-<state>].png/.ax.json`, plus `-dark.png`) |
| `BASKET_FAKE_BREW` | UI-test/fixture runs only: `1` = pretend Homebrew is installed so the onboarding shows "Install with Homebrew" (a simulated install); fixture runs never look at the real Homebrew |
| `BASKET_DOCKER_DRYRUN` | `basket-docker` (the `docker` shim): `1` = print the translated `container` command instead of running it |
| `BASKET_COMPOSE_CLI` | `basket-docker`: program that handles `docker compose …` (otherwise a `basket-compose` next to the shim, else refused with a pointer to Compose Up…) |
| `BASKET_UPDATE_FEED_URL` | DEBUG builds only (release builds ignore it): `file://` or `https://` URL of a test `latest.json`; archives must sit in the same directory (the only way a `file://` download URL passes validation) |
| `BASKET_UPDATE_TEST_PUBLIC_KEY` | DEBUG builds only: base64 Ed25519 public key that replaces the built-in list, for archives signed with a throwaway key |
| `BASKET_UPDATE_ALLOW_UNNOTARIZED` | DEBUG builds only: `1` = an update needs a Developer ID signature of the running app's team but no notarization (the requirement without `and notarized`; local end-to-end test). Compiled out of release builds |
| `BASKET_UPDATE_AUTO_INSTALL` | DEBUG builds only, with `BASKET_UPDATE_FEED_URL`: `1` = check 2 s after launch and start the install in code (a manual shortcut; `scripts/update-e2e.sh` presses Install and Relaunch through the Accessibility API instead) |
| `BASKET_UPDATE_TEST_BLOCK_QUIT` | DEBUG builds only: `1` = after starting the swap helper, stay at “Installing…” instead of quitting (as 0.0.1–0.0.3 did), so `scripts/update-e2e.sh kill` can end Basket with SIGKILL or a Force Quit. Compiled out of release builds |

## Bundle identifiers

| Build | Bundle id | Name |
|---|---|---|
| Release (`scripts/build-app.sh release`, every published release) | `dev.basket.app` | Basket |
| Debug (`scripts/build-app.sh debug`; self-test, E2E and update E2E builds) | `dev.basket.app.debug` | Basket (Debug) |

`BASKET_BUNDLE_ID=<id>` gives `build-app.sh` another id for special tests. Debug builds never share
an installed Basket's settings (`defaults read dev.basket.app.debug`), saved window state or
LaunchServices identity, so they run next to it. Code that means "this app" takes the running
bundle's id (`Bundle.main.bundleIdentifier`, `UserDefaults.standard`); code that means "the
released product" keeps `dev.basket.app`: the update requirement in release builds
(`UpdatePolicy.bundleIdentifier`; DEBUG builds expect their own id, see [updates.md](updates.md)),
the release workflow's checks, and the `docker` shim, a copy in `~/.basket/bin` that reads the
installed app's `containerCLIPath`.

## Data-safety rules

Basket manages state the user cares about, so destructive operations follow fixed rules
(enforced in `Sources/BasketCore/Images/` and `Sources/BasketCore/Memory/`, covered by tests):

- **No CLI `prune`.** Reclaim and "remove unused" delete exactly the names the user approved,
  after re-checking current state; anything that started, gained a user or vanished since
  approval is skipped and reported (`ApprovedDeletion`). Images used by machines count as used.
- **Slimming never deletes the original first.** "Keep only linux/arm64" runs
  `image save --platform linux/arm64` → verify the archive → `image load` (repoints the tag) →
  verify → delete a throwaway tag to free the other variants. If the load fails, the archive is
  kept under `~/Library/Application Support/Basket/Image Archives` and the error shows the
  restore command (`ImageSlimmer`).
- **`--rm` containers are never restarted or auto-stopped**: stopping deletes them. Basket reads
  `autoRemove` from `<appRoot>/containers/<id>/options.json` (`ContainerSummary.removeOnStop`);
  when unknown, restart asks and Memory Saver skips the container unless the user opted it in.
- **Reclaim plans are snapshots.** The disk reclaim sheet freezes its plan when it opens, lists
  every item in full, defaults stopped containers to off, and has no Return shortcut on Delete.
  If any machine's base image is unknown (inspect failed), no image counts as unused anywhere.
- **Restarts are per container**: stop → start one at a time, re-reading `removeOnStop` right
  before each stop; failures and skips are reported, the rest continue (`MemoryReclaim.restart`).
  Compose project restarts follow the same rule, service by service in dependency order.
- **Quitting mid-operation** (slim, import, recreate) asks first, then cancels children and
  removes temp folders; leftover slim archives appear in Images with Restore/Delete.
- **Confirmations name what is lost** (containers using an image, in-memory state on restart),
  and "Cancel" is the default button for in-use deletions.
- **"Already in Basket" means identical content**: an OrbStack image matches only when the
  platform manifest digest (or layers + config + creation time) is equal; a name-only match is
  a "Name conflict", is never imported over, and is excluded from the cleanup command.
- **OrbStack is read-only**: only allowlisted `docker --context orbstack` reads and `save`, and
  only while its engine is already running. Basket never deletes anything from OrbStack.

## Accessibility (AX) testing

The UI is tested the way VoiceOver sees it — through the accessibility tree — on two paths:

1. **Self-test (no permissions).** `BASKET_SELFTEST_DIR` makes the app walk its own
   NSAccessibility tree (`InProcessAXCapture`) for every section and dump it as JSON next to a
   PNG of the window. `basket-ax lint <dir>` runs the rules. `scripts/selftest.sh` does both.
2. **True E2E (needs Accessibility permission once).** `BasketE2E.app` (the `basket-ax`
   runner, Developer-ID signed so the grant survives rebuilds) launches Basket.app, drives it
   with `AXUIElement` (press sidebar items, buttons), captures the tree out of process and runs
   the same rules. `scripts/e2e.sh`. Basket starts through LaunchServices, so it is its own
   responsible process for privacy checks: the script runs a temporary copy of the app with its
   fixtures next to it, never files in the checkout. Reading a checkout in `~/Documents` would make
   macOS ask "Basket would like to access files in your Documents folder", and Basket would wait in
   that read, before its first window, until someone answers (issue #29; the runner then reports
   that Basket never finished launching). An installed Basket may keep running meanwhile.

Rules (BasketAXKit): every interactive element has an accessible name; no element is outside
its window; sibling interactive elements don't overlap; hit targets are not tiny; buttons in one
group share a height; identifiers are unique; static text is not obviously truncated; inside a
card (`overview.card.*`, or any group with a full-width bar) a right-aligned value column ends
where the card's full-width content ends (`card-trailing-alignment`); and the cross-section
consistency contract below holds. No rule depends on the UI language: elements are
found by identifier, and a section's title by the accessible name of its `section.<name>` root.
Run both paths in other languages with `BASKET_LANGUAGE` (German has the longest labels, Chinese
and Japanese text is checked for truncation from two characters on).

### Accessibility identifier contract

| Element | Identifier |
|---|---|
| Main window | `basket.main` |
| Sidebar items | `sidebar.<section>` — `overview`, `containers`, `images`, `volumes`, `networks`, `machines`, `migration`, and `settings` (pinned at the bottom, above the status footer) |
| Section root | `section.<section>` |
| Toolbar / header actions | `<section>.action.<verb>` (e.g. `containers.action.new`, `images.action.pull`) |
| Search field | `<section>.search` |
| List / table | `<section>.list` |
| Row | `<section>.row.<id>` |
| Detail pane | `<section>.detail` |
| Inspect tab (containers, images) | text area `<section>.detail.inspect` (“Inspect output for <name>”), buttons `<section>.detail.inspect.{find,copy}` |
| Empty state | `<section>.empty` |
| Overview cards | `overview.card.<memory|disk|system|orbstack>` |
| Card actions | `overview.action.<verb>` — e.g. `reclaim` (disk), `reclaim-memory`, `stop-idle` |
| Sheets | `sheet.<name>` (e.g. `sheet.reclaim-memory`); its controls `<name>.<control>` (`reclaim-memory.action.confirm`, `reclaim-memory.container.<id>`) |
| Disk reclaim / image recovery | `sheet.reclaim` with items `reclaim.{containers,images,volumes}.item.<id>`; Images recovery strip `images.recovery`, `images.recovery.{restore,delete}.<archive file>` |
| Settings section | root `section.settings` (title “Settings”, ⌘, and the app menu's and menu bar's “Settings…” select it); controls `settings.<name>` (e.g. `settings.memory-saver`, `settings.memory-saver-idle`); General ▸ Language: picker `settings.language` (System + every shipped language, each named in itself) and, after a change, the prompt `settings.language-pending` with `settings.language-relaunch` (“Relaunch Now”); General ▸ Appearance: picker `settings.appearance` (System, Light, Dark; applied at once) |
| Compose | header rows `containers.group.<project>` (disclosure `containers.group.<project>.toggle`), service rows keep `containers.row.<id>`; `containers.action.compose-up` (toolbar, ⇧⌘O), project detail `containers.detail` with `containers.action.project-{start,stop,restart,down,reveal}`; sheet `sheet.compose-plan` with `compose-plan.{file,memory,cpus,service-names,existing,services,service.<name>,warning.<n>,commands,progress,error,copy,cancel,up,show,done}` |
| Onboarding (“Set Up Basket” window) | window `onboarding.window`; one step root `onboarding.step.<welcome|install|system|orbstack|docker|done>`; every button/link `onboarding.action.<verb>` (`back`, `continue`, `skip`, `later`, `not-now`, `install-brew`, `cancel`, `download`, `check-again`, `choose-cli`, `start-system`, `migrate`, `enable-docker`, `disable-docker`, `docs`, `open-basket`); other elements `onboarding.<control>` (`progress`, `title`, `status`, `log`, `error`, `requirement.<name>`, `compare.<memory|disk>`, `planned-change`, `summary`, `memory-saver`). Linted with this contract instead of `basket.main`. Settings: `settings.run-setup`, `settings.docker-command` |
| Updates | sheet `sheet.update`: title `update.version` (“Basket X.Y.Z is available”), `update.notes`, `update.progress`, `update.error`, buttons `update.{install,later,skip,cancel,retry,done,releases}`; checking / up to date / unavailable / failed-check title `update.status`. Settings: `settings.updates.{automatic,check,status}` |
| Migration | `section.migration` (title “Migrate from OrbStack”), `migration.tabs`, `migration.summary`, `migration.action.{import,recreate,refresh,select-all,select-none,copy-cleanup}`, rows `migration.row.<image reference or container name>`; sheets `sheet.migration-import` (`migration.import.{cancel,done}`), `sheet.migration-recreate` (`migration.recreate.{name,command,copy,run}`) |

Every list section (`containers`, `images`, `volumes`, `networks`, `machines`, `migration`) must expose
`<section>.search`, `<section>.action.refresh`, and either `<section>.list` or `<section>.empty`.
`settings` is a form, not a list: it needs only `sidebar.settings` and `section.settings`.

## First run (“Set Up Basket”)

A separate window (`OnboardingView`, state in `AppStore+Onboarding.swift`) opens instead of the main
window on first launch (`onboardingCompletedVersion` below `OnboardingPolicy.currentVersion`) and
whenever the `container` CLI can't be found; never in UI-test runs unless `BASKET_ONBOARDING=1`.
Steps: requirements (macOS 26+, Apple silicon) → install `container` (`brew install container`
streamed and cancellable when Homebrew exists, else Apple's installer + Check Again, or pick the
binary → `containerCLIPath`) → `container system start --enable-kernel-install` (streamed; the first
start downloads ~650 MB of kernel files) → OrbStack comparison and “Migrate Images & Containers…”
(only when OrbStack is installed) → the `docker` command (`DockerShimInstaller`: shows the detected
shell, what `docker` resolves to today and the exact rc-file text before Enable) → summary with the
Memory Saver switch. Fixture runs (`Fixtures/fresh`: `cli-missing` marker, `docker-shim.json`)
simulate the install, the start and the docker command; they never touch Homebrew or the real home.

## Memory insights and Memory Saver

apple/container VMs have no memory balloon: a VM's host footprint follows the guest's high-water
mark and only shrinks when the VM restarts. `MemoryInsights` (BasketCore/Memory) splits each
running container's footprint into *guest in use + VM overhead + stranded*, with the overhead
fitted to measurements (≈ 238 MiB + 25 MiB per doubling of the limit above 256 MiB); a container is
flagged when ≥ 128 MiB and ≥ 10 % of its footprint is stranded. Reclaiming = restarting it.

`IdleTracker` turns successive `container stats` samples into "idle since" (CPU < 1 % of a core
and network < 1 KB/s over every interval; gaps > 5 min or counters going backwards restart it).
Memory Saver (off by default) stops containers idle for 15–120 min; `MemorySaverPolicy` never
stops exempt or machine-backed containers, nor ones started with `--rm` (stopping deletes them;
`CLIBackend` reads `autoRemove` from `<appRoot>/containers/<id>/options.json`), and stops ones
whose `--rm` status is unknown only if the user opted in. With the window closed it samples once a
minute, and only while Memory Saver is on.

## Migrating from OrbStack

`OrbStackMigrator` (BasketCore/Migration) reads OrbStack's Docker engine and never changes it:
every docker call is checked against a read-only allowlist (`--context orbstack` + `image ls`,
`image inspect`, `ps`, `inspect`, `version`, `save -o <file>`) and only made while the engine is up
(`OrbStackEngine`: the `OrbStack Helper vmgr` process runs *and* `~/.orbstack/run/docker.sock`
accepts a connection — a docker call against a stopped engine might start it).

- **Images.** `docker save --platform linux/arm64 -o <tmp>` (OrbStack's containerd store keeps
  partial multi-platform indexes; a plain `save` fails on the missing variants, and `--platform`
  copies only this Mac's variant) → `container image load` → the archive's temp directory is
  removed on success, failure and cancellation. Images OrbStack only has for another platform
  (often linux/amd64) are exported as that platform and run under Rosetta. The load also creates an
  `untagged@sha256:…` image for the attestation manifest docker exports; the migrator deletes the
  ones it created. Free space needed: Docker's disk-usage figure + 512 MiB.
- **Containers.** `docker inspect` → `RecreationPlanner` → `container run` flags (only what differs
  from the image's defaults), named volumes created empty (data isn't copied), and a warning for
  everything apple/container can't express (restart policy, healthcheck, custom networks/aliases/
  links, privileged, devices, GPUs, host namespaces, …). `-P` publishes the exposed ports on the same
  numbers; no Docker memory limit becomes 1G.
- Basket never deletes from OrbStack; the section shows how much could be freed and the
  `docker --context orbstack image rm …` command once the images are in Basket.
- `Fixtures/demo/orbstack-*.json` are synthetic (public images + an invented “acme” project) in the
  raw docker 29 format. `BASKET_MIGRATION_LIVE=1 swift test --filter MigrationLiveTests` runs the
  real import/recreate check (creates and removes `basket-test-mig-*`).

## Compose projects

apple/container has no compose, so Basket reads compose files itself (`BasketCore/Compose`, Apple
frameworks only):

- `YAMLParser` — the YAML 1.2 subset compose files use: block/flow collections, all scalar styles
  (block `|` `>` with chomping and indentation indicators), comments, anchors/aliases, merge keys
  (`<<: *x`), `!!str`-style tags, core-schema typing; errors carry line:column.
- `ComposeLoader` — interpolation (`${VAR}`, `${VAR:-d}`, `${VAR-d}`, `${VAR:?e}`, `${VAR:+r}`, `$$`)
  from `.env` next to the file overridden by the process environment; `env_file`; short and long
  `ports`/`volumes`; `networks` (+aliases), `depends_on` (list/map), resources (`mem_limit`, `cpus`,
  `deploy.resources.limits`). What apple/container can't express (restart policies, healthchecks,
  privileged, devices, secrets, build, …) becomes a warning instead of being dropped silently.
- `ComposePlanner` — Compose's naming (`<project>-<service>-1`, `<project>_default`,
  `<project>_<volume>`) and labels (`com.docker.compose.project`, `.service`, `.container-number`,
  `.project.working_dir`, `.project.config_files`, `.depends_on`, plus `dev.basket.compose=1`),
  dependency order, the equivalent `container` commands and a resource summary. Every service gets an
  explicit memory limit (512 MB by default, from Settings): each one is its own VM, and its host cost
  is the limit plus ≈ 240–290 MB of VM overhead (`MemoryInsights.Model`).
- `ComposeOperations` — `up` (create missing networks/volumes, run services in order, reuse existing
  project containers), `down` (containers and the project's labelled networks; volumes only when
  asked), `start`/`stop` in dependency order, `restart` one service at a time in dependency order
  (stop → start each, `--rm` services skipped, failures don't stop the rest; the outcome lists
  failures and skips, then /etc/hosts is refreshed). `ComposeProject.group` turns the container
  list into projects (by label) for the Containers table.

**Service discovery.** Containers on the same apple/container network can't resolve each other by
name (no embedded DNS in 1.7). After a project starts — and whenever Basket starts or restarts one of
its containers — `ComposeHosts` writes the service names, container names and aliases of every
project container sharing a network into each container's `/etc/hosts`, inside a
`# basket-compose begin … end` block that is replaced idempotently (`container exec --user 0 <id> sh -c …`,
shell builtins only). Images without `sh` can't be updated (reported, not fatal), and a container
restarted outside Basket keeps stale entries until the project is started again from Basket.
`BASKET_COMPOSE_LIVE=1 swift test --filter ComposeLiveTests` runs a real redis + alpine project
(`basket-test-cmp`), proves `app` reaches `db:6379` by name, and takes it down again.

## Inspect JSON

The Inspect tab of containers and images (`InspectJSONView`) shows the backend's inspect output
through `JSONFormatter` (BasketCore): a streaming tokenizer over the UTF-8 bytes that re-emits the
document with two-space indentation, `"key": value` and `[]` / `{}` for empty containers, keeps
key order, copies strings (escapes included) and numbers byte for byte, and returns token ranges
in UTF-16 offsets. It is linear and iterative (an explicit stack, so nesting depth can't overflow);
5 MB takes ~15 ms in a release build. Output that isn't exactly one JSON value is shown unchanged.

`JSONHighlighter` turns the tokens into attributes off the main thread; documents over 200 K
UTF-16 units appear as plain text first and get their colours when ready. Keys, strings, numbers,
`true`/`false`/`null` and punctuation take `systemPurple`, `systemTeal`, `systemOrange`,
`systemBlue` and `secondaryLabelColor`, each moved toward black or white just far enough to reach
WCAG AA (4.5:1) against `textBackgroundColor`, which the text view draws itself
(`ContrastRatio` in BasketAXKit, through `ReadableColor`; the measured table is in `JSONPalette`).
The colours are dynamic, so appearance changes (macOS's or Settings ▸ General ▸ Appearance) apply
at once. The NSTextView (TextKit 2) is read-only and selectable, with the find bar (⌘F, also the
Find button) and no line wrapping: `NoWrapScrollView` sizes it to the widest line, because an
unbounded text container makes TextKit 2 lay out the whole document (seconds for a few MB) instead
of the visible part. Copy JSON copies the formatted text.

## Updates

Basket updates itself from GitHub Releases with Apple frameworks only; the format, keys and
checks are specified in [updates.md](updates.md). In code (`BasketCore/Update`):

- `UpdateManifest` decodes `latest.json` strictly (every field required, `X.Y.Z` versions, the
  `url` must start with `https://github.com/Kilerd/basket/releases/download/`, no query,
  fragment, `..` or escapes, a `.zip`) into an `UpdateOffer`; `eligibility` never offers the same
  or an older version and respects `minimum_system_version`.
- `UpdateInstaller.prepare` streams the zip (256 MB cap, cancellable) into a private directory on
  the app's own volume (`FileManager.url(for: .itemReplacementDirectory…)`), then `UpdateVerifier`
  checks SHA-256 and the Ed25519 signature against any of `trustedPublicKeysBase64` (a list, so the
  key can be rotated), `ditto -x -k` extracts it, and the single `.app` inside must have bundle id
  `dev.basket.app` (`UpdatePolicy.appBundleIdentifier`; DEBUG builds set their own id), the
  manifest's version and a code signature satisfying `CodeSignature.requirement(teamID:identifier:)`
  — a notarized Developer ID app of the running app's own team (`SecCodeCopySelf`). Any failure
  deletes the staging directory.
- `UpdateSwap` hands a `/bin/sh` helper (paths and the requirement as positional parameters) to
  launchd as a one-shot job of its own, so it outlives Basket even when Basket crashes or is
  force-quit ([updates.md](updates.md#the-helper-outlives-basket)). The helper waits for Basket's
  pid to exit, runs `codesign --verify --deep --strict -R` with
  the same requirement on the staged app, renames the old app into the staging directory, renames
  the new one into place, checks it there again (putting the old one back if a check or a rename
  fails), clears quarantine only if present, moves the old app to the Trash and opens the new one.
  Its output goes to `~/Library/Logs/Basket/update.log`.
- `UpdateQuit` quits Basket once the helper runs: it closes the update sheet and waits for it to
  detach (AppKit refuses to terminate while a sheet is attached), terminates, and if Basket still
  runs, ends every sheet and modal session and terminates again, then runs the quit cleanup and
  exits ([updates.md](updates.md#quitting-to-install)). Its steps are injected, so the order is
  unit-tested without AppKit.
- `UpdateController` (app) checks a minute after launch and then daily when Settings ▸ Updates ▸
  “Automatically check for updates” is on (default), and from “Check for Updates…” in the app
  menu and the menu bar extra. Updates are disabled, with the reason shown, for ad-hoc or unsigned
  builds, translocated apps and folders Basket can't write to. A checksum, signature, bundle or
  code-signature mismatch is shown as a security error with no way to install anyway.

End-to-end check: `scripts/update-e2e.sh` (no `/Applications`; needs a Developer ID identity,
since ad-hoc builds can't update, and the Accessibility permission for `BasketE2E.app`) installs
an update through the real UI — Check for Updates…, the update sheet, “Install and Relaunch”
pressed through the Accessibility API — and checks that Basket quits, the bundle is swapped and
the new version relaunches ([updates.md](updates.md#end-to-end-test)); `scripts/update-e2e.sh kill`
ends Basket with SIGKILL and with a Force Quit instead and expects the same. Without
`BASKET_UPDATE_ALLOW_UNNOTARIZED` the same install must stop with a code-signature security error.
