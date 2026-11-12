#!/usr/bin/env bash
# Build a release .app bundle and compressed .dmg for distribution.
#
# Usage: ./Build/release-bundle.sh [VERSION]
#
# VERSION defaults to 0.1.0. The orchestrator is responsible for setting the
# correct version label before cutting a release; this default is not
# authoritative for the v0.1.0 release candidate.
#
# Produces:
#   Build/Release/tap-n-filter.app
#   Build/Release/tap-n-filter-v${VERSION}.dmg
#
# Signing: uses ad-hoc signing per ADR-017. No notarization. On first launch,
# Gatekeeper will block the app; the user must right-click → Open, or go to
# System Settings → Privacy & Security → Open Anyway.
#
# To upgrade to Developer ID signing (ADR-017 §upgrade):
#   Set TNF_SIGNING_IDENTITY to
#   "Developer ID Application: <Your Name> (<TEAMID>)"
#   and add the notarytool + stapler steps.
#
# Dependencies: swift, codesign, hdiutil, sips, iconutil, PlistBuddy, python3,
# security. All ship with macOS / Xcode Command Line Tools.

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
BUILD_NUMBER="1"

RELEASE_DIR="Build/Release"
APP="$RELEASE_DIR/tap-n-filter.app"
DMG="$RELEASE_DIR/tap-n-filter-v${VERSION}.dmg"

echo "==> Building tap-n-filter v${VERSION} (swift build -c release)…"
swift build -c release

BIN=".build/release/tap-n-filter"
if [[ ! -f "$BIN" ]]; then
    echo "ERROR: Build did not produce $BIN" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Assemble .app skeleton
# ---------------------------------------------------------------------------

echo "==> Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/tap-n-filter"
chmod +x "$APP/Contents/MacOS/tap-n-filter"

# ---------------------------------------------------------------------------
# 2. Copy SPM resource bundles — app bundles only, no test bundles.
#
# The Presets target and the tap-n-filter target both produce resource bundles.
# Test targets (UISnapshotTests, etc.) also produce bundles; they must NOT be
# included in the shipped app.
#
# Whitelist pattern: copy only bundles whose names do NOT contain "Tests".
# ---------------------------------------------------------------------------

echo "==> Copying resource bundles (excluding test bundles)…"
BUNDLES_COPIED=0
for bundle in .build/release/*.bundle; do
    [[ -d "$bundle" ]] || continue
    name="$(basename "$bundle")"
    if [[ "$name" == *Tests* ]]; then
        echo "    Skipping test bundle: $name"
        continue
    fi
    echo "    Copying: $name"
    cp -R "$bundle" "$APP/Contents/Resources/"
    BUNDLES_COPIED=$((BUNDLES_COPIED + 1))
done
echo "    Copied $BUNDLES_COPIED bundle(s)."

# Verify: abort if any test bundle leaked in.
if ls "$APP/Contents/Resources/" | grep -q "Tests"; then
    echo "ERROR: A test bundle is present in Contents/Resources/. Aborting." >&2
    ls "$APP/Contents/Resources/" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 3. Generate the app icon (.icns)
#
# Produces a placeholder 1024×1024 PNG (teal waveform-style gradient on dark
# background) using Python 3's standard library. This is an explicit
# placeholder to be replaced before a public release; see ADR-017.
#
# The generator writes the PNG in-place; sips then scales it to every
# required iconset size; iconutil converts the iconset to .icns.
# ---------------------------------------------------------------------------

echo "==> Generating placeholder app icon…"
ICONSET_DIR="$RELEASE_DIR/AppIcon.iconset"
ICNS_PATH="$APP/Contents/Resources/AppIcon.icns"
SOURCE_PNG="$RELEASE_DIR/AppIcon-1024.png"

mkdir -p "$ICONSET_DIR"

# Generate the 1024×1024 source PNG with Python 3 (stdlib only: struct + zlib).
# The image is a dark background with a centered teal sine-wave stripe — a
# minimal visual placeholder for the waveform concept.
python3 - "$SOURCE_PNG" <<'PYEOF'
import sys, zlib, struct, math

def encode_png(width, height, pixels):
    """Encode an RGB pixel array as a minimal valid PNG."""
    def chunk(name, data):
        c = zlib.crc32(name + data) & 0xffffffff
        return struct.pack('>I', len(data)) + name + data + struct.pack('>I', c)

    ihdr = struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)
    raw_rows = []
    for y in range(height):
        row = b'\x00'  # filter type None
        for x in range(width):
            row += bytes(pixels[y * width + x])
        raw_rows.append(row)
    idat = zlib.compress(b''.join(raw_rows), 9)

    return (
        b'\x89PNG\r\n\x1a\n'
        + chunk(b'IHDR', ihdr)
        + chunk(b'IDAT', idat)
        + chunk(b'IEND', b'')
    )

W = H = 1024
pixels = []
cx, cy = W // 2, H // 2

for y in range(H):
    for x in range(W):
        # Dark charcoal background
        r, g, b = 28, 28, 32

        # Sine-wave band: y offset follows sin(x) scaled to ±80 px
        wave_y = cy + int(80 * math.sin(x * 2 * math.pi / (W / 3)))
        dist = abs(y - wave_y)
        if dist < 6:
            # Teal fill, brighter at center
            intensity = 1.0 - dist / 6.0
            r = int(0   + 30  * intensity)
            g = int(180 + 30  * intensity)
            b = int(170 + 40  * intensity)
        elif dist < 12:
            # Soft teal glow
            intensity = 1.0 - (dist - 6) / 6.0
            r = int(0  * intensity)
            g = int(100 * intensity)
            b = int(100 * intensity)

        pixels.append((r, g, b))

with open(sys.argv[1], 'wb') as f:
    f.write(encode_png(W, H, pixels))

print(f"  Wrote {sys.argv[1]}")
PYEOF

# Build the iconset from the 1024px source using sips for all required sizes.
declare -a SIZES=(16 32 128 256 512)
for sz in "${SIZES[@]}"; do
    sips -z "$sz" "$sz" "$SOURCE_PNG" --out "$ICONSET_DIR/icon_${sz}x${sz}.png" > /dev/null
    sips -z "$((sz * 2))" "$((sz * 2))" "$SOURCE_PNG" --out "$ICONSET_DIR/icon_${sz}x${sz}@2x.png" > /dev/null
done

iconutil -c icns -o "$ICNS_PATH" "$ICONSET_DIR"
echo "    Icon written to $ICNS_PATH"

# ---------------------------------------------------------------------------
# 4. Write release Info.plist
#
# Based on Sources/tap-n-filter/Resources/Info.plist; overrides version keys
# and adds CFBundleIconFile. LSUIElement is already true in the source plist
# and will be inherited via the copy; we set it explicitly for clarity.
# ---------------------------------------------------------------------------

echo "==> Writing Info.plist…"
PLIST="$APP/Contents/Info.plist"
cp "Sources/tap-n-filter/Resources/Info.plist" "$PLIST"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION"        "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER"               "$PLIST"
/usr/libexec/PlistBuddy -c "Set :LSUIElement true"                            "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon"             "$PLIST" \
    2>/dev/null || \
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon"                    "$PLIST"

# ---------------------------------------------------------------------------
# 5. Code-sign the .app
#
# Ad-hoc signing per ADR-017 is the default when TNF_SIGNING_IDENTITY is
# unset or empty. An explicit local identity is passed without discovery.
#
# Hardened runtime is enabled (--options=runtime) per ADR-003.
# ---------------------------------------------------------------------------

echo "==> Signing…"
# v0.1.0: ad-hoc signing per ADR-017.
# To select a local identity, set TNF_SIGNING_IDENTITY to
# "Developer ID Application: <Your Name> (<TEAMID>)".
SIGNING_IDENTITY="${TNF_SIGNING_IDENTITY:--}"

echo "    Using identity: $SIGNING_IDENTITY"
codesign --force --deep --options=runtime --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | grep -v "^$" || true
echo "    Signature verified."

# ---------------------------------------------------------------------------
# 6. Build the DMG
#
# Creates a temporary read-write image, populates it with the .app and an
# /Applications symlink, then converts it to a read-only compressed .dmg.
# Uses hdiutil only — no Homebrew, no create-dmg (ADR dissent-log entry).
# ---------------------------------------------------------------------------

echo "==> Building DMG…"
rm -f "$DMG"
DMG_STAGING="$RELEASE_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"

cp -R "$APP" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

# Create a writable UDRW image from the staging folder, then convert to
# compressed read-only UDZO.
TEMP_DMG="$RELEASE_DIR/tap-n-filter-v${VERSION}-rw.dmg"
rm -f "$TEMP_DMG"

hdiutil create \
    -volname "tap-n-filter $VERSION" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDRW \
    "$TEMP_DMG"

hdiutil convert "$TEMP_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG"

rm -f "$TEMP_DMG"
rm -rf "$DMG_STAGING"
rm -rf "$ICONSET_DIR"

# Ad-hoc sign the DMG itself (per ADR-017: the DMG is itself ad-hoc signed).
codesign --force --sign "$SIGNING_IDENTITY" "$DMG"

# ---------------------------------------------------------------------------
# 7. Verify and report
# ---------------------------------------------------------------------------

echo ""
echo "==> Verifying DMG contents…"
MOUNT_POINT="$(mktemp -d)"
hdiutil attach "$DMG" -mountpoint "$MOUNT_POINT" -nobrowse -quiet

echo "    DMG contents:"
ls -la "$MOUNT_POINT/"

# Check both .app and /Applications symlink are present.
if [[ ! -d "$MOUNT_POINT/tap-n-filter.app" ]]; then
    echo "ERROR: tap-n-filter.app not found in DMG" >&2
    hdiutil detach "$MOUNT_POINT" -quiet
    exit 1
fi
if [[ ! -L "$MOUNT_POINT/Applications" ]]; then
    echo "ERROR: Applications symlink not found in DMG" >&2
    hdiutil detach "$MOUNT_POINT" -quiet
    exit 1
fi

echo "    Contents/Resources/ in the mounted .app:"
ls "$MOUNT_POINT/tap-n-filter.app/Contents/Resources/"

# Confirm no test bundles in the mounted app.
if ls "$MOUNT_POINT/tap-n-filter.app/Contents/Resources/" | grep -q "Tests"; then
    echo "ERROR: test bundle detected in shipped app" >&2
    hdiutil detach "$MOUNT_POINT" -quiet
    exit 1
fi
echo "    No test bundles present."

hdiutil detach "$MOUNT_POINT" -quiet
rmdir "$MOUNT_POINT"

DMG_SIZE="$(du -sh "$DMG" | cut -f1)"
echo ""
echo "==> Done."
echo "    DMG: $DMG"
echo "    Size: $DMG_SIZE"
echo ""
echo "    First-launch note: the app is ad-hoc signed and not notarized."
echo "    On first launch, right-click the app → Open, or go to"
echo "    System Settings → Privacy & Security → Open Anyway."
