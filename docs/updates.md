# Updates

Basket updates itself from GitHub Releases, without third-party frameworks: CryptoKit verifies
an Ed25519 signature, the Security framework verifies the code signature, and the app swaps
its own bundle after it quits.

## The manifest: `latest.json`

Every published release carries a `latest.json` asset. The app reads
`https://github.com/Kilerd/basket/releases/latest/download/latest.json` (GitHub redirects to
the newest non-prerelease release).

```json
{
  "version": "0.0.2",
  "pub_date": "2026-11-21T10:00:00Z",
  "notes": "Markdown taken from the version's CHANGELOG section",
  "minimum_system_version": "26.0",
  "url": "https://github.com/Kilerd/basket/releases/download/v0.0.2/Basket-0.0.2-arm64.zip",
  "sha256": "9f2c…(64 hex characters)",
  "signature": "base64 Ed25519 signature over the raw bytes of the zip at `url`"
}
```

- `version`: SemVer `X.Y.Z`, equal to the app's `CFBundleShortVersionString` inside the zip.
- `url`: must be an `https://github.com/Kilerd/basket/releases/download/` URL.
- `sha256` and `signature` both cover the exact zip bytes; the zip is `ditto -c -k --keepParent`
  of the signed, notarized and stapled `Basket.app`.

## What the app checks before installing

1. The manifest parses, `version` is greater than the running version (no downgrades, no
   re-installs), `minimum_system_version` is satisfied, and `url` has the expected prefix.
2. The downloaded zip's SHA-256 equals `sha256`, and `signature` verifies with one of the public
   keys built into the app (`UpdateVerifier.trustedPublicKeysBase64`; an empty or malformed list
   turns updates off).
3. The extracted `Basket.app` has bundle id `dev.basket.app`, version equal to `version`, and a
   valid code signature (all architectures, nested code, strict) that satisfies

   ```text
   anchor apple generic and identifier "dev.basket.app"
     and certificate leaf[subject.OU] = "<team>"
     and certificate 1[field.1.2.840.113635.100.6.2.6] exists
     and certificate leaf[field.1.2.840.113635.100.6.1.13] exists
     and notarized
   ```

   (one line in the code): an Apple-issued chain, the bundle id, the team, a Developer ID
   intermediate and a Developer ID Application leaf certificate, and Apple's notarization.
   `<team>` is read from the running app's own signature, so it is never hard-coded.
4. Only then is the bundle swapped after Basket quits. A `/bin/sh` helper, which launchd runs as
   a job of its own ([The helper outlives Basket](#the-helper-outlives-basket)), runs
   `/usr/bin/codesign --verify --deep --strict -R "=<the same requirement>"` on the staged app
   right before it moves anything and again on the app in its final place; if either check
   fails, or a move fails, the previous version is put back and the reason is logged to
   `~/Library/Logs/Basket/update.log`. Otherwise the old app goes to the Trash and the new
   version is relaunched.

## Quitting to install

The helper waits for Basket's process to exit and gives up after 2 minutes ("still running after
2 minutes; update not installed" in `update.log`), so Basket must quit once the helper runs.
AppKit refuses to terminate while a window has a sheet attached (the unified log shows "App
termination blocked by modal sheet") or a modal session runs, and the update sheet itself is
such a sheet. After launching the helper, Basket therefore (`UpdateQuit`):

1. closes the update sheet and waits up to 2 s until no window has a sheet attached, then
   terminates;
2. if it still runs 2.5 s later (another sheet, an alert, a panel or a modal session held the quit
   up), ends every attached sheet and aborts the modal session, then terminates again;
3. if it still runs 2.5 s after that, runs the quit cleanup (stops its `container` child
   processes, writes its settings) and exits.

While it quits, the update sheet can't be shown again, and the "still working" question on quit
is skipped — installing refuses to start while an import, a recreation or a "Keep only" runs, so
only work started in that moment is stopped, as "Quit Anyway" would. The helper is not one of
the child processes the cleanup stops: it isn't a child of Basket at all (next section).

Versions 0.0.1–0.0.3 lack this and stay at "Installing. Basket quits and opens again…". Their
update can't finish on its own: install the latest DMG. Force-quitting them doesn't help — it
stops their helper too (next section), so the 0.0.4 release notes were wrong to suggest it.

## The helper outlives Basket

The helper must finish whatever happens to Basket once it runs: Basket quits, crashes, is killed
or is force-quit. 0.0.1–0.0.4 started it with `posix_spawn` in a session of its own, which only
protects it from signals sent to Basket's process group or terminal. A child stays in its parent
app's process *coalition*, and a Force Quit — ⌥⌘⎋, the Dock's Force Quit and Activity Monitor's
all call LaunchServices' force quit — sends SIGTERM to every process of the app's coalition. The
helper died with Basket without writing a line to `update.log` (#41; seen with Activity Monitor
on the maintainer's Mac, reproduced with the 0.0.3 updater). `kill`, `kill -9` and
`launchctl kill` on the app reach only the app, and a double fork or `setsid` doesn't leave the
coalition; only launchd puts a process into a new one.

So `UpdateSwap.launchDetached` hands the helper to launchd: `launchctl bootstrap gui/<uid>` with a
job (`UpdateSwap.job`) labelled `dev.basket.app.update.<UUID>` — the same `/bin/sh` command line,
`RunAtLoad`, no `KeepAlive`, `LaunchOnlyOnce` (launchd removes the job as soon as the helper exits,
however it exits), output appended to `update.log`, `PATH` and `HOME` set. The job file is written
into the user's temporary folder (launchd refuses a job file whose ownership it can't trust, as on
a disk image that ignores ownership) and deleted once `bootstrap` returns; nothing is installed in
`~/Library/LaunchAgents`, and the job never outlives the helper or the login session. If
`launchctl` fails, installing stops with "the installer couldn't start (…)" and Basket keeps
running unchanged.

As its own process, the helper isn't covered by Basket's privacy grants, and macOS's App
Management protection treats it as another app: it may rename an installed, launched Basket
bundle as a whole — all the swap does (into the staging folder, into place, to the Trash) — but
not write inside it. That was checked with a notarized Basket that had been launched once: a
launchd-run `/bin/sh` could not create or rename a file inside it, while the swap script replaced
it fine. Moving into `~/.Trash` works too. For a Basket kept in a privacy-protected folder
(Desktop, Documents, Downloads) macOS may refuse the helper access; the swap then fails safely
("could not move … aside; Basket was not changed") and Basket reopens unchanged.

Updates are disabled for ad-hoc signed builds (development builds and forks) and for apps
running translocated (from a quarantined download location) — the app asks the user to move
it to `/Applications` first.

DEBUG builds have their own bundle id, `dev.basket.app.debug` (docs/ARCHITECTURE.md, "Bundle
identifiers"), and expect it in place of `dev.basket.app` — in the bundle check and in the code
requirement — so a debug build only ever installs another debug build and never a release.
Release builds always expect `dev.basket.app`.

DEBUG builds only, for the local end-to-end test: `BASKET_UPDATE_ALLOW_UNNOTARIZED=1` drops
`and notarized` from the requirement (everything else stays), so a Developer ID build that was
never notarized can be installed over another one, and `BASKET_UPDATE_TEST_BLOCK_QUIT=1` keeps
Basket at "Installing…" after it started the helper, as 0.0.1–0.0.3 did, so the test can end it
the way a user would. The switches and their code are compiled out of release builds: `strings`
on a `swift build -c release` binary finds no `BASKET_UPDATE_ALLOW_UNNOTARIZED` or
`BASKET_UPDATE_TEST_BLOCK_QUIT` (nor the other DEBUG-only `BASKET_UPDATE_*` variables).

## End-to-end test

`scripts/update-e2e.sh` installs an update through the real UI, the way a user does:

1. It builds this checkout (DEBUG, bundle id `dev.basket.app.debug`, Developer ID signed: ad-hoc
   builds can't update) and the `BasketE2E.app` runner, copies the app — version A — onto a
   temporary disk image (never `/Applications`), and makes B: the same build with version
   A + 1000 (patch), signed again, zipped and signed with a throwaway key from
   `scripts/update-keygen.swift`, next to a `latest.json` with a `file://` URL.
2. `basket-ax update-install` launches A with the fixtures backend (a copy of `Fixtures/demo` in
   the temporary folder, outside any privacy-protected folder), `BASKET_UPDATE_FEED_URL`,
   `BASKET_UPDATE_TEST_PUBLIC_KEY` and `BASKET_UPDATE_ALLOW_UNNOTARIZED=1`, chooses
   Basket ▸ Check for Updates… in the menu bar, waits for the update sheet and presses
   “Install and Relaunch” (`update.install`) with AXPress.
3. It passes when A quits within 10 s of installing (“Installing…” shown or the sheet gone), the
   bundle on the image is then version B, B runs from there, and no `dev.basket.app.update.*`
   launchd job is left. B is quit, then the image is detached — the replaced copy, the staging
   folder and the key go with it. On a failure the swap helper is stopped before A, so no swap
   can happen later.

`scripts/update-e2e.sh kill` runs the install twice, each time over a fresh copy of A started with
`BASKET_UPDATE_TEST_BLOCK_QUIT=1` (`basket-ax update-install --kill …`): 1 s after “Installing…”
the runner ends A, once with SIGKILL and once with LaunchServices' force quit for A's pid (what
⌥⌘⎋, the Dock and Activity Monitor do; the only way to reach exactly A while another Basket may
run). Both must still end with B installed and running. With 0.0.4's `posix_spawn` helper the
SIGKILL run passed and the Force Quit run failed: nothing ran from the image after 60 s, A was
unchanged and `update.log` stayed empty.

It needs the Accessibility permission for `BasketE2E.app` (as `scripts/e2e.sh`) and an unlocked
screen — it waits up to `BASKET_UNLOCK_WAIT` seconds (default 600) for one. Another Basket, such
as the copy in `/Applications`, may keep running. Output goes to
`artifacts/update-e2e/<timestamp>-<pid>/` (`runner.log`, `result.json` and the helper's
`update.log` lines; in kill mode one set each in `sigkill/` and `force-quit/`). Exit code: 0 pass,
1 the update didn't install (or left its launchd job), 2 setup or runner error, 3 Accessibility
missing. Without `BASKET_UPDATE_ALLOW_UNNOTARIZED` the same install must stop with
a code-signature security error (a manual check: local builds aren't notarized).

## Keys

- **Private key:** base64 of the raw 32-byte Ed25519 key. It lives only in the
  `BASKET_UPDATE_SIGNING_KEY` secret of the protected `release` environment and in an encrypted
  offline backup — never as a plaintext file. Create it in a temporary folder, store it, back it
  up, and delete the folder:

  ```sh
  dir="$(mktemp -d)"
  swift scripts/update-keygen.swift "$dir/update-signing.key"   # mode 0600; prints only the public key
  gh secret set BASKET_UPDATE_SIGNING_KEY --env release --repo Kilerd/basket < "$dir/update-signing.key"
  # encrypted offline backup of "$dir/update-signing.key" (password manager, encrypted volume…)
  rm -rf "$dir"
  ```

- **Public keys:** base64 of the raw 32-byte public keys, compiled into the app as the list
  `UpdateVerifier.trustedPublicKeysBase64` (one `"…"` literal per line). A signature is valid if
  any key in the list verifies it.
- **Signing:** `swift scripts/update-sign.swift <zip>` reads `BASKET_UPDATE_SIGNING_KEY` from the
  environment and prints the base64 signature.
- **The release check:** the release workflow's `verify` job checks the signature against the
  key list of the **previous published release** — the keys installed copies trust — read from
  that release's tag (`scripts/update-keys.sh`). For the very first release with an updater it
  uses the release's own list. It also refuses a release whose own list is empty or can't be
  read, and warns when the signing key is not in that list (the next release must then be
  signed with another key). Dry runs sign with a throwaway key made in the job, never with
  `BASKET_UPDATE_SIGNING_KEY`, so nothing a dry run makes is accepted by an installed Basket.

### Rotating the key

Installed copies accept only the keys they were built with, so a new key reaches them one
release before it signs anything:

1. **Release N adds the new key.** Create the new pair as above, but keep the new private key in
   the encrypted backup only (don't set the secret yet). Add its public key to
   `trustedPublicKeysBase64` next to the old one and release N as usual: it is still signed with
   the old key, which N−1 trusts.
2. **Release N+1 onward signs with the new key.** Once N is published, replace the secret
   (`gh secret set BASKET_UPDATE_SIGNING_KEY …`) with the new private key. N+1 is checked against
   N's list, which holds both keys.
3. **Drop the old key later,** in any release after N, once installed copies have moved past N.

Copies older than N trust only the old key: they reject N+1 with a security error, so they can
update only while N is the latest release. Leave N as the latest release for a while (copies
check daily); anyone who missed it installs the current DMG. If the old key leaked, do the same
but remove the leaked key from the list already in N (N is still signed with it — the only key
older copies accept) and replace the secret right after N is published.
