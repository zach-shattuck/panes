#!/bin/bash
# Builds Panes.app, zips it for a GitHub release, and prints the sha256 to
# paste into the Homebrew cask. Run this for every new release.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Build + sign the bundle (also installs it to /Applications).
bash "$ROOT/Scripts/bundle.sh"

cd "$ROOT"
rm -f Panes.zip
# ditto makes a proper macOS archive that preserves the .app bundle.
ditto -c -k --keepParent Panes.app Panes.zip

echo ""
echo "✓ Panes.zip ready for upload"
echo "  sha256: $(shasum -a 256 Panes.zip | awk '{print $1}')"
echo "  size:   $(du -h Panes.zip | awk '{print $1}')"
