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
4. Only then is the bundle swapped after Basket quits. A detached `/bin/sh` helper runs
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
the child processes the cleanup stops: it is started in its own session and is not a `CLIRunner`
child, so it outlives Basket.

Versions 0.0.1–0.0.3 lack this and stay at "Installing. Basket quits and opens again…"; force-quit
Basket (⌥⌘⎋) within 2 minutes and the helper installs the update, or install the DMG.

Updates are disabled for ad-hoc signed builds (development builds and forks) and for apps
running translocated (from a quarantined download location) — the app asks the user to move
it to `/Applications` first.

DEBUG builds only, for the local end-to-end test: `BASKET_UPDATE_ALLOW_UNNOTARIZED=1` drops
`and notarized` from the requirement (everything else stays), so a Developer ID build that was
never notarized can be installed over another one. The switch and its code are compiled out of
release builds: `strings` on a `swift build -c release` binary finds no
`BASKET_UPDATE_ALLOW_UNNOTARIZED` (nor the other DEBUG-only `BASKET_UPDATE_*` variables).

## End-to-end test

`scripts/update-e2e.sh` installs an update through the real UI, the way a user does:

1. It builds this checkout (DEBUG, Developer ID signed: ad-hoc builds can't update) and the
   `BasketE2E.app` runner, copies the app — version A — onto a temporary disk image (never
   `/Applications`), and makes B: the same build with version A + 1000 (patch), signed again,
   zipped and signed with a throwaway key from `scripts/update-keygen.swift`, next to a
   `latest.json` with a `file://` URL.
2. `basket-ax update-install` launches A with the fixtures backend, `BASKET_UPDATE_FEED_URL`,
   `BASKET_UPDATE_TEST_PUBLIC_KEY` and `BASKET_UPDATE_ALLOW_UNNOTARIZED=1`, chooses
   Basket ▸ Check for Updates… in the menu bar, waits for the update sheet and presses
   “Install and Relaunch” (`update.install`) with AXPress.
3. It passes when A quits within 10 s of installing (“Installing…” shown or the sheet gone), the
   bundle on the image is then version B, and B runs from there. B is quit, then the image is
   detached — the replaced copy, the staging folder and the key go with it. On a failure the
   swap helper is stopped before A, so no swap can happen later.

It needs the Accessibility permission for `BasketE2E.app` (as `scripts/e2e.sh`) and an unlocked
screen — it waits up to `BASKET_UNLOCK_WAIT` seconds (default 600) for one. Another Basket, such
as the copy in `/Applications`, may keep running. Output goes to
`artifacts/update-e2e/<timestamp>-<pid>/` (`runner.log`, `result.json` and the helper's
`update.log` lines). Exit code: 0 pass, 1 the update didn't install, 2 setup or runner error,
3 Accessibility missing. Without `BASKET_UPDATE_ALLOW_UNNOTARIZED` the same install must stop with
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
