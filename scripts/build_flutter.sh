#!/usr/bin/env bash
# FieldTrack — build production Flutter release APKs.
#
# Run from a machine with the Flutter SDK installed (NOT the VPS — the VPS
# never builds the mobile app, only the backend + admin web).
#
# Usage:
#   cd mobile && ../scripts/build_flutter.sh
# or
#   ./scripts/build_flutter.sh   (from repo root)

set -euo pipefail

cd "$(dirname "$0")/../mobile"

echo "==> Checking for production env file"
if [ ! -f .env.prod ]; then
    echo "ERROR: mobile/.env.prod not found." >&2
    echo "Copy .env.prod.example -> .env.prod and fill in your real domain." >&2
    exit 1
fi
cp .env.prod .env
echo "    copied .env.prod -> .env"

echo "==> Checking for production Firebase config"
if [ ! -f android/app/google-services.json ]; then
    echo "ERROR: mobile/android/app/google-services.json not found." >&2
    echo "Download it from the Firebase console (Project settings -> your" >&2
    echo "Android app -> google-services.json) and place it there." >&2
    exit 1
fi
echo "    found android/app/google-services.json"

echo "==> Cleaning previous build"
flutter clean
flutter pub get

echo "==> Building split-per-ABI release APKs"
# --split-per-abi produces one APK per CPU architecture instead of one
# universal APK containing all of them. Each per-ABI APK is roughly 1/3 the
# size of the universal APK, which matters on the low-end Android devices
# (min SDK 21) this app targets — smaller download, less storage used.
flutter build apk --release --split-per-abi

OUT_DIR="build/app/outputs/flutter-apk"
echo ""
echo "================================================================"
echo " Build complete. APKs:"
echo "================================================================"
for apk in "$OUT_DIR"/app-*-release.apk; do
    [ -f "$apk" ] || continue
    size=$(du -h "$apk" | cut -f1)
    printf "  %-45s %s\n" "$(basename "$apk")" "$size"
done
echo "================================================================"
echo ""
echo "Which APK for which phone:"
echo "  app-armeabi-v7a-release.apk  -> older/budget 32-bit ARM phones"
echo "                                   (most common for low-end Android)"
echo "  app-arm64-v8a-release.apk    -> modern 64-bit ARM phones (most"
echo "                                   phones from ~2017 onward)"
echo "  app-x86_64-release.apk       -> emulators / x86 tablets (rare)"
echo ""
echo "If unsure which a device needs, arm64-v8a covers the vast majority of"
echo "phones in active use; armeabi-v7a is the fallback for older devices."
