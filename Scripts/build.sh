#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$(xcrun --show-sdk-path)"
# Any other TERTIA_BUILD_DIR is that caller's private scratch directory; the shared default .build/direct (also when
# named explicitly, as `make build` does) is written by one build at a time under .build/.build.lock (taken in this
# shell, released on exit). Whether OUT is .build/direct is decided before it exists, and it is created only once the
# lock is held, so a `make clean` holding the lock never sees a half-made build folder.
OUT="${TERTIA_BUILD_DIR:-$ROOT/.build/direct}"
SHARED_OUT="$(python3 -I -c 'import os, sys; print(int(os.path.realpath(sys.argv[1]) == os.path.realpath(sys.argv[2])))' "$OUT" "$ROOT/.build/direct")"
if [ "$SHARED_OUT" = 1 ]; then
  mkdir -p "$ROOT/.build"
  exec 9>"$ROOT/.build/.build.lock"
  python3 -I "$ROOT/Scripts/publish.py" lock-fd --timeout "${TERTIA_LOCK_TIMEOUT:-90}" 9
fi
mkdir -p "$OUT"
rm -f "$OUT/tertia"

COMMON_FLAGS=(
  -O
  -whole-module-optimization
  -swift-version 6
  -target arm64-apple-macosx14.0
  -sdk "$SDK"
  -parse-as-library
)

echo "==> [1/4] Compiling TertiaCore"
swiftc "${COMMON_FLAGS[@]}" \
  -module-name TertiaCore \
  -framework Security \
  -emit-module -emit-module-path "$OUT/TertiaCore.swiftmodule" \
  -emit-library -static -o "$OUT/libTertiaCore.a" \
  "$ROOT"/Sources/TertiaCore/*.swift

echo "==> [2/4] Compiling TertiaCLI (UI-free)"
swiftc "${COMMON_FLAGS[@]}" \
  -module-name TertiaCLI \
  -I "$OUT" \
  -emit-module -emit-module-path "$OUT/TertiaCLI.swiftmodule" \
  -emit-library -static -o "$OUT/libTertiaCLI.a" \
  "$ROOT"/Sources/TertiaCLI/*.swift

echo "==> [3/4] Compiling TertiaUI"
swiftc "${COMMON_FLAGS[@]}" \
  -module-name TertiaUI \
  -I "$OUT" \
  -framework SwiftUI -framework AppKit \
  -emit-module -emit-module-path "$OUT/TertiaUI.swiftmodule" \
  -emit-library -static -o "$OUT/libTertiaUI.a" \
  "$ROOT"/Sources/TertiaUI/*.swift

echo "==> [4/4] Linking unified TertiaApp & TertiaWidget"
swiftc "${COMMON_FLAGS[@]}" \
  -module-name TertiaApp \
  -I "$OUT" \
  -L "$OUT" -lTertiaCLI -lTertiaUI -lTertiaCore \
  -framework SwiftUI -framework AppKit -framework WidgetKit -framework Security -framework UserNotifications \
  -o "$OUT/TertiaApp" \
  "$ROOT"/Sources/TertiaApp/*.swift

swiftc "${COMMON_FLAGS[@]}" \
  -module-name TertiaWidget \
  -I "$OUT" \
  -L "$OUT" -lTertiaUI -lTertiaCore \
  -framework WidgetKit -framework SwiftUI -framework AppKit -framework Security \
  -o "$OUT/TertiaWidget" \
  "$ROOT"/Sources/TertiaWidget/*.swift

echo "Built unified release binaries in $OUT"
