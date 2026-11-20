# Releasing Basket

Every release of Basket is built, signed, notarized and published by
[`.github/workflows/release.yml`](../.github/workflows/release.yml) on GitHub's runners, from this
public repository. Nothing is built or signed on anyone's own Mac. Versions are `0.0.x` for now:
every iteration that lands on `main` is released as the next patch
([AGENTS.md §6](../AGENTS.md#6-maintaining-basket-as-an-open-source-project)).

## What a release contains

| File | For |
|---|---|
| `Basket-X.Y.Z.dmg` | First installs: open it and drag Basket to Applications. Signed with the Developer ID, notarized and stapled. |
| `Basket-X.Y.Z-arm64.zip` | The in-app updater: `ditto -c -k --keepParent` of the notarized, stapled `Basket.app` ([updates.md](updates.md)). |
| `latest.json` | The update manifest (version, notes, URL, SHA-256 and Ed25519 signature of the zip; [updates.md](updates.md)). |
| `SHA256SUMS` | The SHA-256 of every file above. |
| `basket-vX.Y.Z.sigstore.json` | The build provenance attestations of those files, for offline checks. |

The release page holds the version's `CHANGELOG.md` section, how to install, and the checksums.
Releases are **not** marked as pre-releases, although `0.x` versions are early: GitHub's
`releases/latest` (which the updater reads) and the "Latest" badge skip pre-releases, so marking
them would leave Basket without a latest release. The page says "Early release" instead, and the
`0.x` version itself tells SemVer users that anything may change.

## Cutting a release

### One click (from `main`)

*Actions → Release → Run workflow* on `main`, untick **Dry run**, and leave **bump** at `patch`
(or pick `minor`/`major`, or type an exact **version**). The `prepare` job then:

1. runs `scripts/release-prep.sh`: the next version from the latest `vX.Y.Z` tag, the entries under
   `## [Unreleased]` moved into `## [X.Y.Z] - <today, UTC>`, the compare links, `VERSION` in
   `scripts/_common.sh`;
2. checks that CI passed on `main`'s head (it waits for a run in progress);
3. commits `chore(release): vX.Y.Z` as `github-actions[bot]` (leak-scanned), creates the annotated
   tag `vX.Y.Z` and pushes both at once (`git push --atomic`);
4. starts this workflow on the tag. A tag pushed with the workflow's `GITHUB_TOKEN` triggers no
   workflow, so the release run is a `workflow_dispatch` on the tag.

Approve the `release` job in that new run (*Review deployments*). The push needs the settings in
[One-click releases](#one-click-releases); if GitHub refuses it, nothing was pushed or published.

### A release pull request and a tag

1. On a branch, run `scripts/release-prep.sh patch` (or `minor`, `major`, `X.Y.Z`; add `--dry-run`
   to see the diff first), commit `chore(release): vX.Y.Z`, open a PR and merge it.
2. Tag the merged commit and push the tag:

   ```sh
   git tag -a vX.Y.Z <commit on main> -m "Basket X.Y.Z"
   git push origin vX.Y.Z
   ```

3. Approve the `release` job of the run that starts. If none starts (GitHub dropped the event, or
   the tag was pushed by a workflow), run the workflow on the tag with **Dry run** unticked:
   `gh workflow run release.yml --ref vX.Y.Z -f dry_run=false`.

### The first release, v0.0.1

There is no `v*` tag yet and `VERSION` is already `0.0.1`, so give the version explicitly (a bump
needs a previous tag): run the one-click path with **version** `0.0.1`. `release-prep.sh` cuts
`## [0.0.1] - <today>` from `## [Unreleased]`, keeps `VERSION`, and links
`[0.0.1]: …/releases/tag/v0.0.1`. If `CHANGELOG.md` already has the `[0.0.1]` section, nothing is
moved and the tag goes on `main`'s head. Nothing requires an earlier release; its `latest.json` is
the first manifest.

### Dry runs

Any manual run with **Dry run** ticked (the default) publishes nothing:

- On `main`: it rehearses the one-click release (the `release-prep.sh` diff is in the run's
  summary), builds, and after the same approval signs, notarizes, staples and update-signs with the
  real secrets, then writes `latest.json`, `SHA256SUMS` and the release page. Everything stays on
  the run for two days as the artifact `dry-run-vX.Y.Z`. CI that has not passed is a warning here.
- On a `vX.Y.Z` tag: the same for that tag.
- On any other branch: it builds only; the `release` environment accepts `main` and `v*` tags.

## What a release requires

The `meta` job stops a release unless:

- the tag is `vX.Y.Z` (SemVer without pre-release or build suffix, no leading zeros) and equals
  `VERSION` in `scripts/_common.sh` at the tagged commit;
- the commit is on `main`;
- `CHANGELOG.md` has a non-empty `## [X.Y.Z]` section (`scripts/release-notes.sh X.Y.Z`);
- CI passed on the commit (`scripts/release-ci-check.sh`): the newest run of
  [`ci.yml`](../.github/workflows/ci.yml) for that commit concluded `success`, waiting up to 45
  minutes for one in progress. **Exception:** a release-only commit (one parent, changing nothing
  but `CHANGELOG.md` and the `VERSION` line) without a finished run of its own is judged by its
  parent's run. The one-click release commit is pushed with `GITHUB_TOKEN`, which starts no CI, and
  its content (changelog text and a version string) is leak-scanned before the push; `prepare`
  checked the parent's CI before pushing anything;
- no release `vX.Y.Z` exists yet. Releases are made once and never changed.

`scripts/release-prep.sh` refuses a version that is not greater than the latest tag or lower than
`VERSION`, an empty `## [Unreleased]` when it must create a section, a bump while there is no tag,
and skipping a version that was prepared (has a section) but never tagged. If the version's
section already exists (prepared in a PR), it moves nothing (new `[Unreleased]` entries wait for
the next release) and only makes `VERSION` and the links match, so running it again changes nothing.

## How the workflow works

| Job | Runner | Holds | What |
|---|---|---|---|
| `prepare` | Linux | `contents: write`, `actions: write`; one-click runs only | the release commit and tag, then the run on the tag |
| `meta` | Linux | read-only token | the version, the commit, whether it publishes or signs; the checks above |
| `build` | macOS 26 | read-only token | `scripts/build-app.sh release` with an ad-hoc signature (it compiles the code, so it gets no secret) |
| `release` | macOS 26 | the `release` environment's secrets; approved once per run | `scripts/sign-app.sh` (Developer ID, hardened runtime, timestamp), `scripts/notarize.sh` on the app, the zip, `scripts/make-dmg.sh`, the DMG's signature, the keychain deleted, `notarize.sh` on the DMG, `scripts/update-sign.swift` |
| `verify` | macOS 26 | read-only token | the zip and the DMG (version, signature, stapled tickets, Gatekeeper, same app in both), the update signature against the key in the app's source (`scripts/update-verify.swift`), `latest.json` (`scripts/update-manifest.sh`), `SHA256SUMS`, the release page (`scripts/release-body.sh`) |
| `publish` | Linux | `contents: write`, `id-token: write`, `attestations: write`; `vX.Y.Z` tags that are not dry runs | attestations of every file, a draft release with every file, the draft checked against `SHA256SUMS`, then published as the latest release |

- **One job holds the secrets.** `release` runs in the protected `release` environment, so GitHub
  makes it wait for the maintainer's approval on every run. It runs this repository's scripts and
  Apple's tools (`codesign`, `notarytool`, `stapler`, `hdiutil`, `swift` for the signing script) on
  the app `build` made, which it never executes. Each step gets only the secrets it uses; the
  temporary keychain is deleted right after the last `codesign`, whatever happened. Secret values
  are never printed, and the name in the signing identity is masked as well.
- **Artifacts are pinned.** Each job hands on a plain tar and puts out its SHA-256 as a job
  output. The next job refuses a tar with another hash (say, one replaced while the run waited for
  the approval), anything compressed, links, and any member outside the expected names
  (`scripts/unpack-artifact.sh`).
- **Write tokens only where needed.** `publish` is the only job that can write a release, and only
  for a tag; `prepare` can push the release commit and tag in one-click runs. The attestations
  name the workflow and the tag they ran for.
- **Inputs are data.** Workflow inputs and ref names reach `run:` steps only through environment
  variables, and the scripts validate them.
- **All or nothing.** With none of the signing secrets (forks, an environment not set up yet) the
  build is signed ad hoc, not notarized, has no `latest.json`, and the release page explains
  Gatekeeper and points to [#7](https://github.com/Kilerd/basket/issues/7). With only some of
  them, the run stops.

One release run at a time (`concurrency: release`); a second one waits and is never cancelled.

## Once: repository settings

### The release environment

*Settings → Environments → `release`*:

- **Required reviewers:** the maintainer. *Prevent self-review* off (the maintainer approves the
  maintainer's releases), *Allow administrators to bypass* off.
- **Deployment branches and tags:** selected only, the branch `main` (dry runs) and the tag
  pattern `v*`.
- **Environment secrets** (`gh secret set <NAME> --env release --repo Kilerd/basket`). Keep no
  copy of them as repository secrets: any workflow on any branch can read those.

  | Secret | Value |
  |---|---|
  | `APPLE_CERTIFICATE` | base64 of the Developer ID Application certificate with its private key, exported as `.p12` (`base64 -i developer-id.p12`) |
  | `APPLE_CERTIFICATE_PASSWORD` | the `.p12`'s password |
  | `APPLE_SIGNING_IDENTITY` | the full identity, `Developer ID Application: <name> (<team id>)` (`security find-identity -v -p codesigning`) |
  | `APPLE_TEAM_ID` | the ten-character team id |
  | `KEYCHAIN_PASSWORD` | any random string (`openssl rand -hex 32`) for the run's throwaway keychain |
  | `APPLE_ID` | the Apple ID that notarizes |
  | `APPLE_PASSWORD` | an app-specific password of that Apple ID (account.apple.com → Sign-In and Security) |
  | `BASKET_UPDATE_SIGNING_KEY` | the update signing key: `swift scripts/update-keygen.swift ~/.config/basket/update-signing.key`, then `gh secret set BASKET_UPDATE_SIGNING_KEY --env release --repo Kilerd/basket < ~/.config/basket/update-signing.key`. Its public key goes into `UpdateVerifier.publicKeyBase64` ([updates.md](updates.md)); `verify` refuses a signature that key does not accept. |

  `LEAK_DENYLIST` stays a repository secret: CI and `prepare`'s leak scan read it.

### Tags and releases

- **A tag ruleset** for `refs/tags/v*` that lets only the maintainer create, update or delete
  release tags (*Settings → Rules → Rulesets*, target tags, bypass: repository admin).
- **Immutable releases** (*Settings → General → Releases*): a published release's files and tag
  cannot change. `publish` uploads everything to a draft first, so it works with them.
- Optionally, the **Release scripts** check (`ci.yml`) among `main`'s required checks.

### One-click releases

`prepare` pushes the release commit to `main` and the tag with the workflow's `GITHUB_TOKEN`, as
`github-actions[bot]`. That works only where neither `main`'s protection nor the `v*` tag ruleset
blocks it, for example with GitHub Actions in the rulesets' bypass lists. A personal access token
is deliberately not supported: it would be a write credential outside the `release` environment.
Without those settings, use [a release pull request and a tag](#a-release-pull-request-and-a-tag);
the environment's approval guards both paths alike.

## When something fails

- **Before `publish`** nothing is published. Fix the cause and use *Re-run failed jobs* (the
  `release` job asks for the approval again), or start a new run.
- **One-click run, after the push:** the tag exists, so don't run the one-click path again (it
  would prepare the next version). Re-run the failed jobs of the run on the tag, or run the
  workflow on the tag with **Dry run** unticked.
- **`publish` failed after creating the draft:** check the draft, delete it
  (`gh release delete vX.Y.Z --repo Kilerd/basket`; the tag stays) and re-run `publish`.
- **A published release is never changed.** Fix forward with a new version.

## Verifying a download

```sh
shasum -a 256 -c --ignore-missing SHA256SUMS
gh attestation verify Basket-X.Y.Z.dmg --repo Kilerd/basket \
  --signer-workflow Kilerd/basket/.github/workflows/release.yml --source-ref refs/tags/vX.Y.Z
```

The first checks the files against `SHA256SUMS`; the second checks, with the GitHub CLI, that this
repository's release workflow built the file for that very tag (add
`--bundle basket-vX.Y.Z.sigstore.json` to check against the bundle on the release). For the
installed app, `spctl --assess -vv /Applications/Basket.app` prints
`source=Notarized Developer ID`. An ad-hoc build (no signing secrets) is not notarized: its release
page says so and shows how to open it.

## The scripts

| Script | Does |
|---|---|
| `scripts/release-prep.sh [--dry-run] <patch\|minor\|major\|X.Y.Z>` | The version, `CHANGELOG.md` and `VERSION` (above) |
| `scripts/release-notes.sh X.Y.Z` | Prints the version's `CHANGELOG.md` section |
| `scripts/release-ci-check.sh <commit>` | CI passed on the commit (or a release commit's parent) |
| `scripts/unpack-artifact.sh` | Checks and unpacks an artifact tar |
| `scripts/sign-app.sh`, `scripts/notarize.sh`, `scripts/make-dmg.sh` | Developer ID signature, notarization and stapling, the DMG |
| `scripts/update-sign.swift`, `scripts/update-verify.swift`, `scripts/update-manifest.sh` | The update signature, its check, `latest.json` ([updates.md](updates.md)) |
| `scripts/release-body.sh` | The release page |
| `scripts/select-xcode.sh` | CI: the pinned Xcode, as in `ci.yml` |

`scripts/tests/release-prep-test.sh` tests them in throwaway repositories (CI job *Release
scripts*; the update signature and DMG parts run on macOS only).
