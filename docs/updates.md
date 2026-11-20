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
2. The downloaded zip's SHA-256 equals `sha256`, and `signature` verifies with the public key
   built into the app (`Curve25519.Signing.PublicKey`).
3. The extracted `Basket.app` has bundle id `dev.basket.app`, version equal to `version`, and a
   valid code signature that satisfies
   `anchor apple generic and identifier "dev.basket.app" and certificate leaf[subject.OU] = "<team>"`,
   where `<team>` is read from the running app's own signature (so it is never hard-coded).
4. Only then is the bundle swapped (old app moved to the Trash, new one moved into place) after
   Basket quits, and the new version relaunched.

Updates are disabled for ad-hoc signed builds (development builds and forks) and for apps
running translocated (from a quarantined download location) — the app asks the user to move
it to `/Applications` first.

## Keys

- Private key: base64 of the raw 32-byte Ed25519 key, created once with
  `swift scripts/update-keygen.swift ~/.config/basket/update-signing.key` (mode 0600; prints
  only the public key). It is stored as the `BASKET_UPDATE_SIGNING_KEY` secret of the protected
  `release` environment and nowhere else in GitHub.
- Public key: base64 of the raw 32-byte public key, compiled into the app
  (`UpdateVerifier.publicKeyBase64`).
- Signing: `swift scripts/update-sign.swift <zip>` reads `BASKET_UPDATE_SIGNING_KEY` from the
  environment and prints the base64 signature.
- Rotation: generate a new pair, ship an app version containing the new public key *signed with
  the old key*, then switch the secret. Apps older than that release keep verifying with the old
  key, so they must update once through the transition release.
