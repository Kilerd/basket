# AGENTS.md

Instructions for AI coding agents (and humans) working on Basket — a native macOS app that
replaces OrbStack with Apple's [container](https://github.com/apple/container). Start with
`docs/ARCHITECTURE.md` (layout, backends, accessibility contract) and `docs/EVOLUTION.md`
(roadmap, measurements, iteration log).

## 1. Confidentiality — this repository is public

Everything you write can end up in a public commit, PR, issue or log. Treat these as
publishing, and never include:

- **Credentials of any kind**: API keys, access tokens (GitHub, cloud, registry, LLM
  providers), passwords, private keys, certificates, provisioning profiles, keychain exports,
  `.env` files, cookies, session ids, `docker login` / `container registry login` config.
- **Data from the developer's machine**: names of containers, images, volumes, networks or
  machines from their Docker / OrbStack / container installs; `inspect` output, environment
  variables, logs, hostnames, IP addresses, file paths. These often carry employer- or
  customer-internal names.
- **Personal identity**: real names, e-mail addresses, home paths (`/Users/<name>` — use
  `/Users/demo`), Apple Developer team ids or signing identity names.

How to work with real data safely:

- Capture real CLI output to `/tmp` (outside the repo), study its *shape*, then write
  fixtures with synthetic content: public images only (`redis`, `postgres`, `nginx`,
  `alpine`…), invented names, placeholder values, fake digests.
- Screenshots from the real backend show host data: keep them in `artifacts/` (gitignored).
  Only fixture-driven screenshots may be committed (e.g. into `docs/`).
- Signing: never hardcode an identity. Scripts discover it at runtime
  (`$BASKET_SIGN_IDENTITY`, else the first Developer ID identity, else ad-hoc).
- CI: secrets only through `${{ secrets.* }}`; never `echo`/`env`/`set -x` around them.
- Commit messages, branch names, PR titles/descriptions and issue comments follow the same
  rules.

Guard rails (do not bypass them):

- `scripts/check-leaks.sh` scans for credentials, personal paths (also JSON-escaped and
  inside binary files), signing identities, the local identity (user name, full name, git
  e-mail) and a private word list. It runs in the pre-commit and commit-msg hooks
  (`git config core.hooksPath .githooks`) and in CI (tree, every PR commit, every push). Never use `git commit --no-verify` to get past it; fix the content instead.
  A line that is a deliberate, harmless example may carry `leak-check: allow`.
- `.leak-denylist` (gitignored, one word or ERE per line) holds private words — employer,
  project and customer names — that must never appear in the repo. Keep it local; never
  commit it or copy its contents anywhere. CI reads the same list from the
  `LEAK_DENYLIST` secret.
- If something sensitive was pushed: stop, tell the maintainer, and rotate the credential.
  Rewriting history does not un-publish it.

## 2. Host safety

- The developer's Docker / OrbStack state is off limits: read-only commands only (`ls`,
  `ps`, `inspect`, `image ls`, `save`). Never start, stop, remove, prune, tag, pull or switch
  contexts there.
- `container` resources you create must be named `basket-test-*` and deleted afterwards.
  Never `container system stop`, never prune globally, never touch kernel or DNS settings.
- GUI runs (self-test, E2E) show windows on the developer's screen: keep them short and
  terminate everything you launch.

## 3. Build and test

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # if xcode-select points at CLT
swift build                          # parallel agents: --scratch-path .build-<lane>
swift test                           # unit tests (Core, AXKit)
scripts/build-app.sh [debug|release] # → build/Basket.app (BASKET_BUILD_DIR to relocate)
scripts/selftest.sh demo             # in-process accessibility audit + PNGs, no permissions needed
scripts/e2e.sh demo                  # out-of-process AXUIElement E2E (needs Accessibility for BasketE2E.app)
scripts/check-leaks.sh --all         # confidentiality scan of the working tree
```

Quality gates for UI changes: `selftest.sh demo|empty|stopped` and `e2e.sh demo` end with 0
errors and 0 warnings, and someone actually looks at the PNGs — clipped, misaligned or
inconsistent UI fails even when the lint passes. Check alignment at full resolution (crop with
`sips -c`): in tables and repeated rows, bars, icons and numbers line up down each column;
numbers use `.monospacedDigit()` and a fixed-width, right-aligned slot.

## 4. Code conventions

- Swift 6 language mode, SwiftUI + Observation, async/await. Apple frameworks only — no
  third-party dependencies.
- `Sources/BasketCore/Domain.swift` is the backend contract: additive changes only (new
  fields with defaults, new requirements with default implementations).
- Every interactive control has an accessible name and follows the identifier contract in
  `docs/ARCHITECTURE.md`; new sections extend the contract doc and the `contract` audit rule
  together.
- Destructive actions (delete, prune, restart, slim) must state exactly what is lost and act
  only on the items the user approved.
- Tests use swift-testing. Fixtures stay in raw CLI JSON shape.

## 5. Git

- Conventional commits: `<type>(<scope>): <description>` — feat, fix, refactor, docs, test,
  ci, chore, perf, build; imperative, lower case, no trailing period. Scopes: `core`, `app`,
  `ax`, `migration`, `scripts`, `ci`, `docs`.
- Commits carry human authorship only: no `Co-Authored-By` for AI agents, no "Generated
  with …" lines, no agent or model names in commits or PR text.
- Branches: `<type>/<short-slug>` (e.g. `feat/memory-saver`). Never commit to or force-push
  `main`.
- Enable the hooks once per clone: `git config core.hooksPath .githooks`.

## 6. Maintaining Basket as an open-source project

The project is developed in public at <https://github.com/Kilerd/basket>. Work so that an
outside contributor could follow every decision from the repository alone.

- **Issues first.** Every non-trivial change starts from a GitHub issue describing the problem
  or proposal (use the templates). Roadmap items in `docs/EVOLUTION.md` link to their issues.
  Labels: type (`bug`, `enhancement`, `docs`, `ci`, `chore`), area (`area:core`, `area:app`,
  `area:ax`, `area:migration`), `good first issue`, `help wanted`.
- **Pull requests.** One focused change per PR, linked with `Closes #N`, using the PR template
  checklist. Merge requirements: CI green (build, tests, leak scan, accessibility self-test),
  at least one review, no unresolved conversations. Squash-merge with a conventional-commit
  title. The maintainer has the final say on scope and product decisions.
- **Changelog and versions.** Fast iteration first: versions are `0.0.x` — every evolution
  iteration that lands on `main` is released as the next patch (`0.0.1`, `0.0.2`, …). The
  version lives in `scripts/_common.sh` (`VERSION`) and is bumped in the release PR. Moving
  to `0.1.0` is the maintainer's call once the backend contract and data handling are stable.
  Every user-visible PR adds a line under `## [Unreleased]` in `CHANGELOG.md` (Keep a
  Changelog format). Releases are tags `vX.Y.Z` on `main` with notes taken from the
  changelog; release builds are signed (and notarized once set up) by the maintainer only.
- **Releasing.** A release pull request (`scripts/release-prep.sh`), then the maintainer pushes the tag `vX.Y.Z`; `.github/workflows/release.yml` builds, signs and publishes it after the maintainer approves the run; see [docs/RELEASING.md](docs/RELEASING.md).
- **Security.** Vulnerabilities are reported privately (GitHub Security Advisories, see
  `SECURITY.md`) and never discussed in public issues before a fix ships.
- **Language.** Code, comments, commit messages, PRs and docs in English so anyone can
  contribute; issues and discussions may also be in Chinese.
- **Dependencies and assets.** Apple frameworks only. Any third-party asset (icons, images,
  fonts) records its source and license next to it (see `Resources/Branding/README.md`).
- **Docs stay current.** `README.md` (users), `CONTRIBUTING.md` (contributors),
  `docs/ARCHITECTURE.md` (design + accessibility contract), `docs/EVOLUTION.md` (roadmap,
  measurements, iteration log). A PR that changes behaviour updates the matching doc.
  README screenshots come from fixture-driven self-test runs, never from a real machine.
- **License.** Apache-2.0 (`LICENSE`, attributions in `NOTICE`). Contributions are accepted
  under the same license (inbound = outbound). New source files need no per-file header;
  third-party material must be Apache-2.0-compatible and listed in `NOTICE`.
