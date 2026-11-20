#!/usr/bin/env bash
# CI only: points /Applications/Xcode.app at $XCODE_APP and selects it, so `swift` in a workflow
# and in scripts/ (which use /Applications/Xcode.app, see _common.sh) are the same toolchain.
# The same as the "Select Xcode" step of .github/workflows/ci.yml.
#   XCODE_APP=/Applications/Xcode_26.6.app scripts/select-xcode.sh
set -euo pipefail

: "${XCODE_APP:?set XCODE_APP to the Xcode the workflow pins}"
if [ ! -d "$XCODE_APP" ]; then
  echo "::error::$XCODE_APP is not on this runner image; installed:"
  ls -d /Applications/Xcode*.app
  exit 1
fi
if [ -L /Applications/Xcode.app ] || [ ! -e /Applications/Xcode.app ]; then
  sudo ln -sfn "$XCODE_APP" /Applications/Xcode.app
else
  echo "::warning::/Applications/Xcode.app is not a symlink; scripts/ will use it as is"
fi
sudo xcode-select -s /Applications/Xcode.app
sw_vers
xcodebuild -version
swift --version
