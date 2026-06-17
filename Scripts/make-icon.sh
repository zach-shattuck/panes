#!/bin/bash
# Rasterizes the SVG logo into a macOS app icon (.icns) and a transparent
# menu-bar image. Run once (or after changing Resources/PanesLogo.svg).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RES="$ROOT/Resources"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- App icon: full logo (navy background) → AppIcon.icns ---
echo "→ rasterizing app icon"
qlmanage -t -s 1024 -o "$TMP" "$RES/PanesLogo.svg" >/dev/null 2>&1
SRC="$TMP/PanesLogo.svg.png"
[ -f "$SRC" ] || { echo "failed to rasterize PanesLogo.svg"; exit 1; }

ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for spec in "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" \
            "128:128x128" "256:128x128@2x" "256:256x256" "512:256x256@2x" \
            "512:512x512" "1024:512x512@2x"; do
    px="${spec%%:*}"; name="${spec##*:}"
    sips -z "$px" "$px" "$SRC" --out "$ICONSET/icon_${name}.png" >/dev/null 2>&1
done
iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"
echo "✓ $RES/AppIcon.icns"

# --- Menu-bar image: colored mark on transparency (no navy square) ---
# Rendered via NSImage, NOT qlmanage: qlmanage flattens SVG transparency onto
# a white background, which looks bad in the menu bar. NSImage preserves alpha.
echo "→ rendering menu-bar image (transparent)"
RENDER="$TMP/render.swift"
cat > "$RENDER" <<'SWIFT'
import AppKit
let a = CommandLine.arguments
guard let img = NSImage(contentsOfFile: a[1]) else { exit(1) }
let px = Int(a[3]) ?? 36
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
SWIFT
# MenuBarMark.svg is the monochrome (black) template-style mark used in the
# menu bar; the app icon uses the full colored PanesLogo.svg above.
swift "$RENDER" "$RES/MenuBarMark.svg" "$RES/MenuBarIcon.png" 18
swift "$RENDER" "$RES/MenuBarMark.svg" "$RES/MenuBarIcon@2x.png" 36
echo "✓ $RES/MenuBarIcon.png (+@2x, transparent template)"
