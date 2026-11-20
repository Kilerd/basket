#!/usr/bin/env bash
# Writes the GitHub release page of a version (docs/RELEASING.md) to stdout: an "early release"
# note, the CHANGELOG notes, how to install and how to check the download.
#   scripts/release-body.sh <version> <signed|adhoc> <notes-file> <SHA256SUMS>
# signed: Developer ID, notarized, with latest.json. adhoc: no secrets were available (a dry run;
# a release is never ad hoc), so the page explains Gatekeeper. The repository comes from
# GITHUB_REPOSITORY (default Kilerd/basket).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

[[ $# -eq 4 ]] || die "usage: scripts/release-body.sh <version> <signed|adhoc> <notes-file> <SHA256SUMS>" 64
V="$1" MODE="$2" NOTES="$3" SUMS="$4"
[[ "$V" =~ $SEMVER_RE ]] || die "version is not X.Y.Z"
[[ "$MODE" == signed || "$MODE" == adhoc ]] || die "mode is signed or adhoc" 64
[[ -s "$NOTES" && -s "$SUMS" ]] || die "missing notes or SHA256SUMS"
REPO="${GITHUB_REPOSITORY:-Kilerd/basket}"
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "GITHUB_REPOSITORY is not owner/repo"
DMG="Basket-$V.dmg"
ZIP="Basket-$V-arm64.zip"

if [[ "$V" == 0.* ]]; then
  cat <<EOF
> **Early release.** Basket is below 1.0 and changes quickly: every iteration that lands on
> \`main\` is released, and versions may break things between them.

EOF
fi
cat "$NOTES"
cat <<EOF

## Install

Basket needs macOS 26 or later on Apple silicon and Apple's \`container\` CLI
(\`brew install container\`).

- **New install:** download \`$DMG\`, open it and drag Basket to Applications.
EOF
if [[ "$MODE" == signed ]]; then
  cat <<EOF
- **Updates:** Basket finds new versions through this release's \`latest.json\` and installs
  \`$ZIP\` itself, after checking its checksum, its update signature and its Developer ID
  signature ([docs/updates.md](https://github.com/$REPO/blob/v$V/docs/updates.md)).

The app is signed with a Developer ID and notarized by Apple, so it opens like any other app.
EOF
else
  cat <<EOF
- \`$ZIP\` holds the same app.

> **Not notarized.** This build has an ad-hoc signature, not a Developer ID, so macOS
> Gatekeeper blocks it the first time and it does not update itself
> ([#7](https://github.com/$REPO/issues/7) tracks signed builds). After checking the download
> (below), either remove the quarantine flag:
>
> \`\`\`sh
> xattr -dr com.apple.quarantine /Applications/Basket.app
> \`\`\`
>
> or open Basket once, then choose **Open Anyway** in System Settings → Privacy & Security
> (Control-click → Open no longer skips Gatekeeper since macOS 15).
EOF
fi
cat <<EOF

## Check the download

\`SHA256SUMS\` lists every file of this release:

\`\`\`sh
shasum -a 256 -c --ignore-missing SHA256SUMS
\`\`\`

Every file has a build provenance attestation: GitHub's record that this repository's release
workflow built it from the tag \`v$V\`. With the GitHub CLI:

\`\`\`sh
gh attestation verify $DMG --repo $REPO \\
  --signer-workflow $REPO/.github/workflows/release.yml --source-ref refs/tags/v$V
\`\`\`

\`\`\`text
EOF
cat "$SUMS"
echo '```'
