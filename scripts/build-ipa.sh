#!/usr/bin/env bash
# Local equivalent of .github/workflows/build-ios.yml.
#
# Builds an unsigned device .ipa from the SocksBypass target. Requires macOS with
# Xcode. Produces no signature and needs no credentials — signing happens later,
# on Linux, at install time.
#
# There is no shared `SocksBypass` scheme; the only shared scheme is
# `SocksBypass-Benchmark`, whose archive action is pinned to a configuration
# linking a gitignored, uncommitted Vendor/HevSocks5Server.xcframework. So we
# build by `-target` and zip the .app ourselves.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="SocksBypass"
OUT_IPA="SocksBypass-unsigned.ipa"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "ERROR: this script needs macOS + Xcode. Got $(uname -s)." >&2
    exit 1
fi

echo "==> Toolchain"
xcodebuild -version

echo "==> Building unsigned device .app"
# No CODE_SIGN_* credentials anywhere: unsigned on purpose.
xcodebuild \
    -project SocksBypass.xcodeproj \
    -target "$APP_NAME" \
    -configuration Release \
    -sdk iphoneos \
    -derivedDataPath "$PWD/.derivedData" \
    CONFIGURATION_BUILD_DIR="$PWD/build/ios" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    ENABLE_BITCODE=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    build

APP="build/ios/$APP_NAME.app"
if [ ! -d "$APP" ]; then
    echo "ERROR: expected .app not found at $APP" >&2
    exit 1
fi

echo "==> Packaging .ipa"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
cp -a "$APP" "$STAGE/Payload/"
rm -f "$OUT_IPA"
# A .ipa is a zip with the app under Payload/.
( cd "$STAGE" && zip -qry "$OLDPWD/$OUT_IPA" Payload )

echo
echo "Done. Unsigned ipa:"
echo "  $PWD/$OUT_IPA"
echo
echo "Sign and install it on Linux with Legacy iOS Kit / PlumeImpactor."