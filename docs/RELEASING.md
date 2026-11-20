# Releasing Basket

Every release of Basket is built, signed, notarized and published by
[`.github/workflows/release.yml`](../.github/workflows/release.yml) on GitHub's runners, from this
public repository, when the maintainer pushes a `vX.Y.Z` tag. Nothing is built or signed on
anyone's own Mac. Versions are `0.0.x` for now: every iteration that lands on `main` is released
as the next patch ([AGENTS.md §6](../AGENTS.md#6-maintaining-basket-as-an-open-source-project)).

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

1. **The release pull request.** On a branch (`chore/release-vX.Y.Z`), run
   `scripts/release-prep.sh patch` (or `minor`, `major`, `X.Y.Z`; add `--dry-run` to see the diff
   first). It moves the entries under `## [Unreleased]` into `## [X.Y.Z] - <today, UTC>`, updates
   the compare links and sets `VERSION` in `scripts/_common.sh`. Commit
   `chore(release): vX.Y.Z`, open a pull request and merge it once CI is green. The push to `main`
   runs CI on the merged commit.
2. **The tag.** The maintainer tags that commit on `main` and pushes the tag:

   ```sh
   git fetch origin
   git tag -a vX.Y.Z <the merged commit on origin/main> -m "Basket X.Y.Z"
   git push origin vX.Y.Z
   ```

   Only the maintainer can create `v*` tags (the tag ruleset, below); no workflow pushes commits
   or tags.
3. **The run.** The tag push starts the workflow: `meta` checks the version and waits for `main`'s
   CI on the commit, `build` builds, then approve the `release` job (*Review deployments*);
   `verify` and `publish` follow.

### The first release

Without any `v*` tag a bump has nothing to bump: name the version (`scripts/release-prep.sh
0.0.1`). If `CHANGELOG.md` already has the version's section and `VERSION` matches, the script
changes nothing (new `[Unreleased]` entries wait for the next release), so there is nothing to
merge: tag the commit on `main` directly. The first release whose source has the updater signs its
update with a key from its own `UpdateVerifier.trustedPublicKeysBase64`; every later one is
checked against the previous release's list ([updates.md](updates.md#keys)).

### Dry runs

*Actions → Release → Run workflow*, on any branch or tag. A run started by hand is always a dry
run and publishes nothing:

- On `main`: it rehearses the release pull request (`release-prep.sh` with the **bump** or
  **version** input; the diff is in the run's summary), builds, and after the same approval signs
  with the Developer ID and notarizes. The update signature comes from a throwaway Ed25519 key made
  in the job: `BASKET_UPDATE_SIGNING_KEY` is never given to a dry run, and no installed Basket
  accepts what it signs. `verify` checks everything, including which release's keys a release
  would be checked against. CI that has not passed is a warning here.
- On a `vX.Y.Z` tag: the same for that tag.
- On any other branch: it builds only; the `release` environment accepts `main` and `v*` tags.

A dry run keeps only reports: the artifact `dry-run-report-vX.Y.Z` (`SHA256SUMS` and the release
page, two days). The signed app travels from `release` to `verify` inside the run (artifact
`signed`, one day for dry runs) with only the throwaway update signature; no zip, DMG or
`latest.json` is kept as a dry run's result. An exact **version** stays in the current major
version; only **bump** `major` starts a new one.

## What a release requires

The `meta` job stops a release unless:

- the run is the push of a tag `vX.Y.Z` (SemVer without pre-release or build suffix, no leading
  zeros) that equals `VERSION` in `scripts/_common.sh` at the tagged commit;
- the commit is on `main`;
- `CHANGELOG.md` has a non-empty `## [X.Y.Z]` section (`scripts/release-notes.sh X.Y.Z`);
- CI passed on the commit (`scripts/release-ci-check.sh`): the newest run of
  [`ci.yml`](../.github/workflows/ci.yml) for that very commit concluded `success`, waiting up to
  45 minutes for one in progress. Every commit on `main`, the merged release pull request
  included, gets its own run;
- no release `vX.Y.Z` exists yet. Releases are made once and never changed.

Later jobs stop it unless:

- all signing secrets are set (`release`): a release is never signed ad hoc;
- the app and the DMG are signed with the Developer ID, notarized, stapled and accepted by
  Gatekeeper, the zip and the DMG hold the same app, and the update signature verifies with the
  keys the **previous published release** trusts — its `trustedPublicKeysBase64`, read from its
  tag — while this release's own list is non-empty and readable (`verify`;
  [updates.md](updates.md#keys));
- the tag on `origin` still points at the commit that was built, before the draft is made and
  again right before it is published (`publish`).

`scripts/release-prep.sh` refuses a version that is not greater than the latest tag or lower than
`VERSION`, an exact version with a higher major version than `VERSION` and the latest tag (only
`major` starts one), an empty `## [Unreleased]` when it must create a section, a bump while there
is no tag, and skipping a version that was prepared (has a section) but never tagged. If the
version's section already exists, it moves nothing (new `[Unreleased]` entries wait for the next
release) and only makes `VERSION` and the links match, so running it again changes nothing.

## How the workflow works

| Job | Runner | Holds | What |
|---|---|---|---|
| `meta` | Linux | read-only token | the version, the commit, whether it publishes or signs; the checks above |
| `build` | macOS 26 | read-only token | `scripts/build-app.sh release` with an ad-hoc signature (it compiles the code, so it gets no secret) |
| `release` | macOS 26 | the `release` environment's secrets; approved once per run | `scripts/sign-app.sh` (Developer ID, hardened runtime, timestamp), `scripts/notarize.sh` on the app, the zip, `scripts/make-dmg.sh`, the DMG's signature, the keychain deleted, `notarize.sh` on the DMG, `scripts/update-sign.swift` (the production key only when publishing; a throwaway key in dry runs) |
| `verify` | macOS 26 | read-only token | the zip and the DMG (version, signature, stapled tickets, Gatekeeper, same app in both), the update signature against the previous published release's keys (`scripts/published-release.sh`, `scripts/update-keys.sh`, `scripts/update-verify.swift`), `latest.json` (`scripts/update-manifest.sh`), `SHA256SUMS`, the release page (`scripts/release-body.sh`) |
| `publish` | Linux | `contents: write`, `id-token: write`, `attestations: write`; pushed `vX.Y.Z` tags only | attestations of every file, then `scripts/release-publish.sh`: the tag check, a draft with every file, the draft downloaded and compared byte for byte, published by its release id; marked "latest" only when newer than every published release |

- **One job holds the secrets.** `release` runs in the protected `release` environment, so GitHub
  makes it wait for the maintainer's approval on every run. It runs this repository's scripts and
  Apple's tools (`codesign`, `notarytool`, `stapler`, `hdiutil`, `swift` for the signing script) on
  the app `build` made, which it never executes. Each step gets only the secrets it uses; the
  update signing key reaches only the signing step, and only when the run publishes. The temporary
  keychain has a fixed path, `$RUNNER_TEMP/basket-release.keychain-db`, and is deleted right after
  the last `codesign` by a step that always runs. Secret values are never printed, and the name in
  the signing identity is masked as well.
- **Artifacts are pinned.** Each job hands on a plain tar and puts out its SHA-256 as a job
  output. The next job refuses a tar with another hash (say, one replaced while the run waited for
  the approval), anything compressed, links, and any member outside the expected names
  (`scripts/unpack-artifact.sh`).
- **Write tokens only where needed.** `publish` is the only job that can write a release, and only
  for a pushed tag. Everything it does after creating the draft addresses that release by its id;
  a draft it made is deleted again if a check fails. The attestations name the workflow and the
  tag they ran for.
- **Inputs are data.** Workflow inputs and ref names reach `run:` steps only through environment
  variables, and the scripts validate them.
- **Actions are pinned** to full commit SHAs (with the version as a comment) in `release.yml` and
  `ci.yml`; Dependabot proposes updates.
- **No ad-hoc releases.** With none of the signing secrets (forks, an environment not set up yet)
  a dry run is signed ad hoc, not notarized and has no `latest.json`; a release stops. With only
  some of them, any run stops.

One release run at a time (`concurrency: release`); a second one waits and is never cancelled.

## Once: repository settings

The release relies on these settings; check them after any change to the repository's settings.

### The release environment

*Settings → Environments → `release`*:

- **Required reviewers:** the maintainer. *Prevent self-review* off (the maintainer approves the
  maintainer's releases), **Allow administrators to bypass off**: no run gets the secrets without
  an approval.
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
  | `BASKET_UPDATE_SIGNING_KEY` | the update signing key ([below](#the-update-signing-key)). Its public key is in `UpdateVerifier.trustedPublicKeysBase64` ([updates.md](updates.md#keys)); `verify` refuses a signature that the previous release's keys don't accept. |

  `LEAK_DENYLIST` stays a repository secret: CI's leak scan reads it.

### Tags, releases and `main`

- **Immutable releases** (*Settings → General → Releases*): a published release's files and tag
  cannot change. `publish` uploads everything to a draft first, so it works with them.
- **The `v*` tag ruleset** (*Settings → Rules → Rulesets*, target `refs/tags/v*`): creating,
  updating and deleting release tags is restricted; only repository admins (the maintainer)
  bypass it. GitHub Actions can't be a bypass actor on a personal repository, which is why no
  workflow creates or moves tags.
- **The `main` ruleset:** no deletion, no force push, changes through pull requests only
  (conversations resolved), required checks *Leak scan* and *Build, test and self-test*; only
  repository admins bypass it. Optionally also *Release scripts*.

### The update signing key

The Ed25519 key that signs `latest.json`'s zip lives in the `BASKET_UPDATE_SIGNING_KEY`
environment secret and in an encrypted offline backup, and nowhere else: no plaintext copy stays
on any disk. Make it in a temporary folder, store it, back it up and delete the folder:

```sh
dir="$(mktemp -d)"
swift scripts/update-keygen.swift "$dir/update-signing.key"   # prints the public key only
gh secret set BASKET_UPDATE_SIGNING_KEY --env release --repo Kilerd/basket < "$dir/update-signing.key"
# encrypted offline backup of "$dir/update-signing.key" (password manager, encrypted volume…)
rm -rf "$dir"
```

Its public key goes into `UpdateVerifier.trustedPublicKeysBase64`. Changing the key is a
two-release rotation ([updates.md, "Rotating the key"](updates.md#rotating-the-key)): never
replace the secret before a published release trusts the new key.

## When something fails

- **Before `publish`** nothing is published. Fix the cause and use *Re-run failed jobs* (the
  `release` job asks for the approval again). A fix that needs a new commit needs a new version.
- **No run started for the tag** (GitHub dropped the event): as long as no release of it exists,
  the maintainer deletes the tag on GitHub and pushes it again.
- **`publish` failed:** `release-publish.sh` deletes the draft it made; re-run `publish`. If a
  draft is left over, delete it on the releases page. If it says the tag moved, find out why
  before anything else: the tag no longer points at what was built and approved.
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
`source=Notarized Developer ID`.

## The scripts

| Script | Does |
|---|---|
| `scripts/release-prep.sh [--dry-run] <patch\|minor\|major\|X.Y.Z>` | The version, `CHANGELOG.md` and `VERSION` (above) |
| `scripts/release-notes.sh X.Y.Z` | Prints the version's `CHANGELOG.md` section |
| `scripts/release-ci-check.sh <commit>` | CI passed on the commit |
| `scripts/unpack-artifact.sh` | Checks and unpacks an artifact tar |
| `scripts/sign-app.sh`, `scripts/notarize.sh`, `scripts/make-dmg.sh` | Developer ID signature, notarization and stapling, the DMG |
| `scripts/update-sign.swift`, `scripts/update-verify.swift`, `scripts/update-manifest.sh` | The update signature, its check against one or more keys, `latest.json` ([updates.md](updates.md)) |
| `scripts/update-keys.sh [<git-rev>]` | The update keys a revision's app trusts (`trustedPublicKeysBase64`) |
| `scripts/published-release.sh [--below X.Y.Z]` | The newest published release (below a version) |
| `scripts/release-publish.sh` | The draft, its check and the release, by release id, after the tag check |
| `scripts/release-body.sh` | The release page |
| `scripts/select-xcode.sh` | CI: the pinned Xcode, as in `ci.yml` |

`scripts/tests/release-prep-test.sh` tests them in throwaway repositories, with stand-ins for `gh`
(CI job *Release scripts*; the update signature and DMG parts run on macOS only).
