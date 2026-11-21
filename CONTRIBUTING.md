# Contributing to Basket

Thanks for your interest in Basket. This guide covers the practical side: setting up, the
checks your change must pass, and how changes get from an issue to `main`. The rules behind it
live in [AGENTS.md](AGENTS.md). It is written for coding agents, but it applies to every
contributor. Read **§1 Confidentiality** and **§2 Host safety** before you start.

By taking part you agree to the [Code of Conduct](CODE_OF_CONDUCT.md). Report security problems
privately (see [SECURITY.md](SECURITY.md)), never in a public issue.

## Setup

You need:

- macOS 26 or later on Apple silicon.
- **Xcode 26** with the macOS 26 SDK. The package uses `swift-tools-version: 6.2` and Swift 6
  language mode. There are no third-party dependencies.
- Apple's `container` CLI (`brew install container`). You only need it to run Basket against
  the real backend or to run the opt-in integration tests. Unit tests, the self-test and the
  end-to-end test use fixtures.

```sh
git clone https://github.com/Kilerd/basket.git
cd basket
git config core.hooksPath .githooks   # once per clone: runs the leak scan before every commit
```

**`DEVELOPER_DIR`.** If `xcode-select -p` prints `/Library/Developer/CommandLineTools`,
SwiftPM cannot find the macOS 26 SDK. Point it at Xcode, either for each shell or for the whole
system:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# or: sudo xcode-select -s /Applications/Xcode.app
```

The scripts in `scripts/` set this path themselves.

**Optional: a private word list.** Create `.leak-denylist` at the repo root. It holds one word
or extended regular expression per line, matched without regard to case, and `#` starts a
comment. List the names that must never appear in this repository, such as your employer, your
customers and internal projects. Git ignores the file. Never commit it and never copy its
contents anywhere. `scripts/check-leaks.sh` and the pre-commit hook read it. CI reads its own
list from a repository secret.

## Build, test and check

| Command | What it does |
|---|---|
| `swift build` | Builds every target |
| `swift test` | Runs the unit tests (swift-testing) for BasketCore and BasketAXKit |
| `scripts/build-app.sh [debug\|release]` | Bundles and signs `build/Basket.app` |
| `scripts/selftest.sh demo\|empty\|stopped` | In-process accessibility audit and screenshots for one fixture set. Needs no permissions |
| `scripts/e2e.sh demo` | Out-of-process `AXUIElement` end-to-end test. Needs the Accessibility permission for `BasketE2E.app` |
| `BASKET_LANGUAGE=de scripts/selftest.sh demo` | Either test in another language (`zh-Hans`, `zh-Hant`, `ja`, `fr`, `de`) and its region format (numbers, sizes, dates) |
| `scripts/sync-strings.sh [--prune]` | Adds new UI strings to the String Catalog and marks (or drops) unused ones |
| `scripts/check-l10n.sh` | Localization gate: catalog in sync, every language complete, placeholders match |
| `scripts/check-leaks.sh --all` | Confidentiality scan of the working tree (`--staged` runs in the pre-commit hook) |

Notes:

- **Parallel checkouts or builds.** Pass `--scratch-path .build-<name>` to `swift build` and
  `swift test`. For the scripts, set `BASKET_SCRATCH=.build-<name>` and
  `BASKET_BUILD_DIR=$PWD/build/<name>`.
- **Signing.** The scripts sign with `$BASKET_SIGN_IDENTITY`, else the first "Developer ID
  Application" identity in your keychain, else ad-hoc. Never hard-code an identity. With an
  ad-hoc signature, `BasketE2E.app` loses its Accessibility permission on every rebuild. A
  stable Developer ID identity keeps it.
- **Self-test and end-to-end runs open real windows** on your screen. Keep the display awake
  and don't use the mouse or keyboard while they run. They clean up after themselves.
- **Integration tests are opt-in** because they use the real `container` CLI and create
  resources named `basket-test-*`, which they remove afterwards:
  - `BASKET_INTEGRATION=1 swift test`
  - `BASKET_MIGRATION_LIVE=1 swift test --filter MigrationLiveTests` (reads OrbStack only)

  Never run anything that changes your Docker or OrbStack state, and never stop the
  `container` system or prune it globally (AGENTS.md §2).
- Output goes to `artifacts/` (ignored by git). Screenshots taken against the real backend
  show your data, so they stay there.

## Quality gates

A pull request is merged when all of these hold:

1. **CI is green.** CI runs the build, `swift test`, the localization check, the leak scan (full
   tree plus every commit in the PR), and the self-test on the `demo`, `empty` and `stopped`
   fixture sets plus `demo` in Simplified Chinese and German.
2. **For UI changes:** `scripts/selftest.sh demo|empty|stopped` and `scripts/e2e.sh demo` end
   with 0 errors and 0 warnings, in English and in German (`BASKET_LANGUAGE=de`, the longest
   labels). **Someone has also looked at the PNGs.** Clipped, misaligned or inconsistent UI fails
   even when the lint passes. Attach fixture screenshots to the PR.
   `BASKET_SELFTEST_EXTRAS=1` also captures sheets and detail tabs.
3. It has at least one approving review and no unresolved conversations.

## Workflow

1. **Start with an issue.** Every non-trivial change begins as a GitHub issue that describes the
   problem or proposal. Use the templates. Comment that you are working on it so nobody
   duplicates the work. Small fixes such as typos or obvious one-line bugs can go straight to a
   PR. Issues and discussions may be in English or Chinese. Code, comments, commits, PRs and
   docs are in English.
2. **Branch** from `main` as `<type>/<short-slug>`, for example `feat/memory-saver` or
   `fix/prune-exact-list`. Never push to `main` directly.
3. **Commit** using [Conventional Commits](https://www.conventionalcommits.org/):
   `<type>(<scope>): <description>`.
   - Types: `feat`, `fix`, `refactor`, `docs`, `test`, `ci`, `chore`, `perf`, `build`.
   - Scopes: `core`, `app`, `ax`, `migration`, `scripts`, `ci`, `docs`.
   - Write the description in the imperative, in lower case, with no trailing period, for
     example `fix(core): stop only the approved containers`.
   - Commits carry human authorship only: no AI co-author trailers and no "Generated with …"
     lines.
4. **Open a PR** using the template. Keep it to one focused change and link the issue with
   `Closes #N`. If the change is user-visible, add a line under `## [Unreleased]` in
   [CHANGELOG.md](CHANGELOG.md). If it changes behaviour, update the matching doc: `README.md`
   for users, this file for contributors, `docs/ARCHITECTURE.md` for design and the
   accessibility contract, `docs/EVOLUTION.md` for the roadmap and measurements.
5. **Merge.** PRs are squash-merged with a conventional-commit title. The maintainer has the
   final say on scope and product decisions.

Versions are `0.0.x` for now. Each iteration that lands on `main` is released as the next patch.
The maintainer tags releases (`vX.Y.Z`) and signs release builds.
How a release is cut, built, signed and checked: [docs/RELEASING.md](docs/RELEASING.md).

## Code conventions

The full list is in [AGENTS.md §4](AGENTS.md#4-code-conventions). In short:

- Swift 6 language mode, SwiftUI with Observation, and async/await. Apple frameworks only.
- `Sources/BasketCore/Domain.swift` is the backend contract. Change it only by adding: new
  fields get defaults, and new protocol requirements get default implementations.
- Destructive actions (delete, prune, restart, slim) state exactly what will be lost and act
  only on the items the user approved.
- Tests use swift-testing (`import Testing`).

### Adding a section, sheet or control

The UI tests rely on a stable **accessibility identifier contract**, defined in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#accessibility-identifier-contract). When you add
UI:

1. Give every interactive control an accessible name and an identifier that follows the
   contract: `<section>.action.<verb>`, `<section>.row.<id>`, `sheet.<name>`,
   `<name>.<control>`, `settings.<name>`, and so on.
2. A new sidebar section needs `sidebar.<section>` and `section.<section>`. A list section also
   needs `<section>.search`, `<section>.action.refresh`, and either `<section>.list` or
   `<section>.empty`.
3. Update the contract table in `docs/ARCHITECTURE.md` and the `contract` audit rule
   (`AXAuditRules.sections` / `listSections` in `Sources/BasketAXKit/AXAuditRules.swift`) in the
   same PR, along with its tests in `Tests/BasketAXKitTests`.
4. Add or extend fixtures so the new UI has data in `demo` and a sensible state in `empty` and
   `stopped`. Then run the self-test on all three sets and the end-to-end test, and look at the
   screenshots.

Prefer `.accessibilityElement(children: .combine)` on a real container. Using `.ignore` with a
label tends to produce role-less (`AXUnknown`) elements.

### Localization

Basket ships in English, 简体中文, 繁體中文, 日本語, Français and Deutsch. All UI text lives in one
String Catalog, `Resources/Localization/Localizable.xcstrings`, keyed by the English text
(design: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#localization); words and typography:
[docs/l10n/glossary.md](docs/l10n/glossary.md)).

**Writing UI text**

- SwiftUI literals (`Text("Delete")`, `Button("Cancel")`, `.help("…")`) are localized
  automatically. Text built in code uses `String(localized: "…")`; in BasketCore,
  `String(localized: "…", bundle: .main)`. A `String` variable passed to `Text`, `Button`,
  `Label`, `.help` or `.accessibilityLabel` is shown as is, so it must already be localized.
- Write whole sentences with interpolations (`"Delete \(name)?"`), never glue translated pieces
  together or build English plurals in code. For counts, interpolate the number and add plural
  forms to the catalog; a plural form must contain the number. When the singular has no number
  ("Delete “web”?"), use a second string and pick it with `count == 1`.
- Sizes (`Format.memory`, `Format.disk`), percentages, durations and dates come from formatters;
  lists of names from `.localizedList`. Never write units or separators into a string.
- Accessibility identifiers, commands, paths and other data are never localized
  (`Text(verbatim:)` for data).
- Add a `comment:` to short or ambiguous strings ("Down", "Default") for translators.

**After changing UI text**, run `scripts/sync-strings.sh --prune` (adds the new keys, drops the
ones no longer used), translate the new keys into every language, and run
`scripts/check-l10n.sh`. Translations can be edited in Xcode (open the `.xcstrings` file) or as
JSON:

```sh
swift scripts/l10n.swift missing Resources/Localization/Localizable.xcstrings de > /tmp/de.json
# translate: { "<key>": "<translation>" } or { "<key>": { "one": "…", "other": "…" } }
swift scripts/l10n.swift apply Resources/Localization/Localizable.xcstrings de /tmp/de.json
```

Look at the result: `BASKET_LANGUAGE=<id> scripts/selftest.sh demo` (and `e2e.sh`) must stay at 0
errors and 0 warnings, and German is the best test for labels that don't fit.

**Adding a language** is a translation-only change: translate every key into the new language
(`l10n.swift missing … <id>` lists them all) and apply it. The build compiles every language in
the catalog into the app and lists it in `CFBundleLocalizations`, the Settings language picker
offers it, and `check-l10n.sh` then requires it to stay complete. Add a column to the glossary,
run the self-test and onboarding (`BASKET_ONBOARDING=1 BASKET_FAKE_BREW=1 scripts/selftest.sh fresh`)
in that language, and look at every screenshot.

### Fixtures are synthetic

Fixtures (`Fixtures/*`, `Tests/BasketCoreTests/Fixtures`) keep the **exact raw CLI JSON shape**
(`container … --format json`, `docker … --format json`) but contain only **invented content**:

- public images only (`redis`, `postgres`, `nginx`, `alpine`, …);
- made-up container, volume and network names;
- placeholder values and fake digests;
- `/Users/demo` for home paths.

To learn a new output shape, capture the real output to `/tmp` (outside the repo), study it,
then write a synthetic fixture. Never commit captured output, `inspect` dumps, environment
values, logs or screenshots from your own machine. README and PR screenshots come only from
fixture-driven self-test runs.

## License

Basket is licensed under the [Apache License 2.0](LICENSE). Contributions are accepted under
the same license (inbound = outbound, as in section 5 of the license). There is no CLA, and new
source files need no license header. Third-party material (code, icons, images, fonts) must be
Apache-2.0-compatible. Record its source and license next to it (see
[Resources/Branding/README.md](Resources/Branding/README.md)) and list it in [NOTICE](NOTICE).
