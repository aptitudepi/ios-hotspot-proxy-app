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
#
# Do not be tempted to add `-derivedDataPath` for tidier output: xcodebuild
# rejects it without `-scheme`, and CONFIGURATION_BUILD_DIR already controls
# where the product lands.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

APP_NAME="SocksBypass"
OUT_IPA="$PWD/SocksBypass-unsigned.ipa"

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
    CONFIGURATION_BUILD_DIR="$REPO_ROOT/build/ios" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    ENABLE_BITCODE=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    build

# CONFIGURATION_BUILD_DIR should put the product at build/ios/, but locate the
# .app rather than assuming: if a future Xcode ignores the override under
# -target, the product lands in build/<Config>-<sdk>/ instead.
APP="$(find . -maxdepth 4 -name "$APP_NAME.app" -type d -not -path './.git/*' -print -quit)"
if [ -z "$APP" ]; then
    echo "ERROR: no $APP_NAME.app was produced. Directory tree:" >&2
    find . -maxdepth 4 -type d -not -path './.git/*' >&2
    exit 1
fi

echo "==> Packaging .app from $APP"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
cp -a "$APP" "$STAGE/Payload/"
rm -f "$OUT_IPA"
# A .ipa is a zip with the app under Payload/.
( cd "$STAGE" && zip -qry "$OUT_IPA" Payload )

echo
echo "Done. Unsigned ipa:"
echo "  $OUT_IPA"
echo
echo "Sign and install it on Linux with Legacy iOS Kit / PlumeImpactor."