#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The local HTTPS/HTTP2 wire-profile test needs a python3 with TLSv1.3 and ALPN; fail fast before building.
TERTIA_RESOLVED_PYTHON="$(python3 -I "$ROOT/Scripts/publish.py" print-test-python)"

# This run's private build directory and bundle, so overlapping builds, packages, and tests never clobber each other.
# It is removed on exit, after run-watched has stopped every process that could still write into it. TERM or INT is
# forwarded to run-watched (`$!`, empty until it is launched) and waited out before that cleanup.
TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/tertia-test-build.XXXXXX")"
# Verifier scratch folders live under TERTIA_TEST_SCRATCH_ROOT, and every throwaway Keychain service the verifier
# creates is appended to TERTIA_TEST_KEYCHAIN_LOG, so cleanup removes both even after a watchdog kill.
TERTIA_TEST_SCRATCH_ROOT="$TEST_BUILD/scratch"
TERTIA_TEST_KEYCHAIN_LOG="$TEST_BUILD/keychain-services.txt"
mkdir -p "$TERTIA_TEST_SCRATCH_ROOT"
: > "$TERTIA_TEST_KEYCHAIN_LOG"
cleanup_test_run() {
  if [ -f "$TERTIA_TEST_KEYCHAIN_LOG" ]; then
    sort -u "$TERTIA_TEST_KEYCHAIN_LOG" | while IFS= read -r svc; do
      case "$svc" in
        club.tertia.macos.test.*) /usr/bin/security delete-generic-password -s "$svc" >/dev/null 2>&1 || true ;;
      esac
    done
  fi
  rm -rf "$TEST_BUILD"
}
trap cleanup_test_run EXIT
trap 'if [ -n "${!:-}" ]; then kill -TERM "$!" 2>/dev/null || true; wait "$!" 2>/dev/null || true; fi; exit 143' TERM INT
export ROOT TEST_BUILD TERTIA_RESOLVED_PYTHON TERTIA_TEST_SCRATCH_ROOT TERTIA_TEST_KEYCHAIN_LOG

# The whole pipeline runs in its own process group under one 115 s watchdog (no argument or environment flag skips
# it): on timeout, or TERM/INT, run-watched stops the packager, compiler, and verifier group before this shell cleans up.
# It runs in the background so a TERM or INT sent to this shell alone is forwarded at once and waited out.
python3 -I "$ROOT/Scripts/publish.py" run-watched --timeout 115 -- bash -c '
set -euo pipefail
export TERTIA_BUILD_DIR="$TEST_BUILD" TERTIA_PACKAGE_BUILD_DIR="$TEST_BUILD" TERTIA_DIST_APP="$TEST_BUILD/Tertia.app" SIGN_IDENTITY="-"
# Package first so the bundle under test is always built and signed from current source.
"$ROOT/Scripts/package_app.sh"

echo "==> Building & running VerifyCoreTests (Core + CLI/MCP + UI + App)"
swiftc -Onone \
  -swift-version 6 \
  -target arm64-apple-macosx14.0 \
  -sdk "$(xcrun --show-sdk-path)" \
  -parse-as-library \
  -I "$TEST_BUILD" \
  -L "$TEST_BUILD" -lTertiaCLI -lTertiaUI -lTertiaCore \
  -framework AppKit -framework SwiftUI -framework Security \
  -o "$TEST_BUILD/VerifyCoreTests" \
  "$ROOT/Scripts/VerifyCoreTests.swift"

# Behavioral binary checks run the signed executable of the bundle packaged above.
TERTIA_APP_BIN="$TEST_BUILD/Tertia.app/Contents/MacOS/Tertia" "$TEST_BUILD/VerifyCoreTests"
' &
wait "$!"
