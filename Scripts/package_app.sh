#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${TERTIA_DIST_APP:-$ROOT/dist/Tertia.app}"
# One packaging run per destination at a time: build, stage, sign, and publish all happen under the lock next to the
# destination (dist/.Tertia.app.lock by default; a private TERTIA_DIST_APP gets its own), taken in this shell (no
# environment flag can skip it) and released when the script exits.
APP_DIR="$(dirname "$APP")" APP_NAME="$(basename "$APP")"
mkdir -p "$APP_DIR"
exec 9>"$APP_DIR/.$APP_NAME.lock"
python3 -I "$ROOT/Scripts/publish.py" lock-fd --timeout "${TERTIA_LOCK_TIMEOUT:-90}" 9
# Build into a per-run directory removed on exit (TERTIA_BUILD_DIR, shared with `make build`, is never used), so
# overlapping `make build`, `make package`, and `make test` runs never overwrite each other's intermediates. Only
# Scripts/test.sh passes TERTIA_PACKAGE_BUILD_DIR, its own private per-run directory.
OWN_BUILD=""
if [ -n "${TERTIA_PACKAGE_BUILD_DIR:-}" ]; then BUILD_OUT="$TERTIA_PACKAGE_BUILD_DIR"; else BUILD_OUT="$ROOT/.build/pkg.$$"; OWN_BUILD="$BUILD_OUT"; fi

# A run killed by SIGKILL skips its EXIT trap: remove the staging bundles of this destination (safe under its lock) and
# the per-run build directories whose owning process (the numeric suffix) is gone.
python3 -I "$ROOT/Scripts/publish.py" remove-dead "$APP_DIR/.$APP_NAME.stage."*
if [ -n "$OWN_BUILD" ]; then python3 -I "$ROOT/Scripts/publish.py" remove-dead "$ROOT/.build/pkg."*; fi

# Assemble, sign, and verify a staging bundle next to the destination; only a verified bundle replaces it.
STAGE_APP="$APP_DIR/.$APP_NAME.stage.$$"
ICONSET_DIR="$BUILD_OUT/AppIcon.$$.iconset"
WIDGET_ENT="$BUILD_OUT/widget.$$.entitlements"
WIDGET_APPEX="$STAGE_APP/Contents/PlugIns/TertiaWidget.appex"
LOGIN_KEYCHAIN="${TERTIA_KEYCHAIN_PATH:-$HOME/Library/Keychains/login.keychain-db}"
if [ -z "${SIGN_IDENTITY:-}" ]; then
  APPLE_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" 2>/dev/null \
    | /usr/bin/sed -En 's/.*"((Developer ID Application|Apple Development): [^"]*)".*/\1/p' | /usr/bin/head -n 1)"
  SIGN_IDENTITY="${APPLE_IDENTITY:--}"
fi
trap 'rm -rf "$STAGE_APP" "$ICONSET_DIR" "$WIDGET_ENT" ${OWN_BUILD:+"$OWN_BUILD"}' EXIT

TERTIA_BUILD_DIR="$BUILD_OUT" "$ROOT/Scripts/build.sh"

echo "==> Assembling $STAGE_APP"
rm -rf "$STAGE_APP"
mkdir -p "$STAGE_APP/Contents/MacOS" "$STAGE_APP/Contents/Helpers" "$STAGE_APP/Contents/Resources" "$WIDGET_APPEX/Contents/MacOS"

cp "$BUILD_OUT/TertiaApp" "$STAGE_APP/Contents/MacOS/Tertia"
ln -s ../MacOS/Tertia "$STAGE_APP/Contents/Helpers/tertia"
cp "$BUILD_OUT/TertiaWidget" "$WIDGET_APPEX/Contents/MacOS/TertiaWidget"

cp "$ROOT/Packaging/App-Info.plist" "$STAGE_APP/Contents/Info.plist"
cp "$ROOT/Packaging/Widget-Info.plist" "$WIDGET_APPEX/Contents/Info.plist"
cp "$ROOT/LICENSE" "$STAGE_APP/Contents/Resources/LICENSE"

# Generate crisp 512x512 AppIcon.icns from monochrome luxury T emblem (per-run iconset, removed on exit)
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
python3 - "$ICONSET_DIR" <<'PY'
import struct, zlib, sys, os

out_dir = sys.argv[1]

def write_png(path, size):
    rows = []
    for y in range(size):
        row = bytearray([0])
        for x in range(size):
            # Soft rounded obsidian squircle border + crisp ivory T emblem
            nx = abs(x - size / 2.0) / (size / 2.0)
            ny = abs(y - size / 2.0) / (size / 2.0)
            r_dist = (nx ** 4.5 + ny ** 4.5) ** (1.0 / 4.5)
            if r_dist > 0.96:
                row.extend((0, 0, 0, 0))
            elif r_dist > 0.91:
                row.extend((38, 38, 38, 255))
            else:
                top_bar = int(0.28 * size) <= y < int(0.36 * size) and int(0.24 * size) <= x < int(0.76 * size)
                stem = int(0.45 * size) <= x < int(0.55 * size) and int(0.28 * size) <= y < int(0.74 * size)
                if top_bar or stem:
                    row.extend((245, 245, 245, 255))
                else:
                    row.extend((10, 10, 10, 255))
        rows.append(bytes(row))
    raw = b"".join(rows)
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)
    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)

# Render each unique size once; the shell copies the @2x duplicates below.
for s, name in [(16, "icon_16x16.png"), (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
                (128, "icon_128x128.png"), (256, "icon_256x256.png"), (512, "icon_512x512.png")]:
    write_png(os.path.join(out_dir, name), s)
PY
cp "$ICONSET_DIR/icon_32x32.png" "$ICONSET_DIR/icon_16x16@2x.png"
cp "$ICONSET_DIR/icon_256x256.png" "$ICONSET_DIR/icon_128x128@2x.png"
cp "$ICONSET_DIR/icon_512x512.png" "$ICONSET_DIR/icon_256x256@2x.png"
iconutil -c icns "$ICONSET_DIR" -o "$STAGE_APP/Contents/Resources/AppIcon.icns"

# Entitlement-free host (signed without an entitlements plist) and sandboxed widget (network only): no App Groups, so ad-hoc and Developer ID builds
# share one layout and amfid always permits launch.
cat > "$WIDGET_ENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
EOF

# Both staged executables must be exactly the binaries this run built (checked before signing rewrites them).
cmp -s "$BUILD_OUT/TertiaApp" "$STAGE_APP/Contents/MacOS/Tertia" || { echo "error: staged executable differs from $BUILD_OUT/TertiaApp" >&2; exit 1; }
cmp -s "$BUILD_OUT/TertiaWidget" "$WIDGET_APPEX/Contents/MacOS/TertiaWidget" || { echo "error: staged widget differs from $BUILD_OUT/TertiaWidget" >&2; exit 1; }

echo "==> Signing inside-out (identity: $SIGN_IDENTITY)"
codesign --force --options runtime --entitlements "$WIDGET_ENT" --sign "$SIGN_IDENTITY" "$WIDGET_APPEX"
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$STAGE_APP"

xattr -cr "$STAGE_APP"
codesign --verify --deep --strict --verbose=2 "$STAGE_APP"

# Atomic swap (renamex_np RENAME_SWAP): dist/Tertia.app is never missing, and a failed swap leaves it untouched.
python3 -I "$ROOT/Scripts/publish.py" swap "$STAGE_APP" "$APP"
echo "Packaged and verified: $APP"
