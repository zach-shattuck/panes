#!/bin/bash
# Assembles a real Panes.app bundle from the SwiftPM release build and
# ad-hoc code-signs it (so TCC gives it a stable identity for testing).
#
# Re-run this after any code change. Note: ad-hoc signing means the bundle's
# identity changes whenever the binary changes, so macOS will treat a rebuilt
# Panes.app as a new app and you must re-grant permissions (or reset with
# `tccutil reset Accessibility dev.panes.app`). A paid Developer ID cert is
# what makes grants survive rebuilds.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Panes.app"

echo "▸ Building release binary…"
swift build -c release --package-path "$ROOT"

BIN="$ROOT/.build/release/Panes"
[ -f "$BIN" ] || { echo "build produced no binary at $BIN"; exit 1; }

echo "▸ Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Panes"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# Icons (run Scripts/make-icon.sh to (re)generate them from the SVG).
for icon in AppIcon.icns MenuBarIcon.png "MenuBarIcon@2x.png"; do
    [ -f "$ROOT/Resources/$icon" ] && cp "$ROOT/Resources/$icon" "$APP/Contents/Resources/"
done

echo "▸ Code-signing…"
# Prefer the stable self-signed "Panes Dev" identity (created by
# Scripts/setup-signing.sh) so TCC grants survive rebuilds; fall back to
# ad-hoc if it isn't set up.
if security find-identity -p codesigning 2>/dev/null | grep -q "Panes Dev"; then
    security unlock-keychain -p "panes-local-signing" "panes-signing.keychain" 2>/dev/null || true
    codesign --force --sign "Panes Dev" --identifier dev.panes.app "$APP"
    echo "  (signed with stable 'Panes Dev' identity — grants persist across rebuilds)"
else
    codesign --force --sign - --identifier dev.panes.app "$APP"
    echo "  (ad-hoc — run Scripts/setup-signing.sh once to stop re-granting after every rebuild)"
fi

echo "✓ Built $APP"

# Deploy to /Applications so the installed copy stays current on every
# rebuild — no manual re-copy needed. Happens automatically once Panes is in
# /Applications, or force it with INSTALL=1. TCC grants survive because the
# bundle id + signing identity are unchanged (the grant isn't path-bound).
if [ -d "/Applications/Panes.app" ] || [ "${INSTALL:-}" = "1" ]; then
    rm -rf "/Applications/Panes.app"
    cp -R "$APP" "/Applications/Panes.app"
    echo "✓ Installed to /Applications/Panes.app"
    echo "  Launch with:  open -a Panes"
else
    echo "  Launch with:  open \"$APP\"   (or run with INSTALL=1 to put it in /Applications)"
fi
