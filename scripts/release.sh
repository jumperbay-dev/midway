#!/bin/sh
# Developer ID release, run on your Mac (no CI): build, sign Sparkle's helpers and the app with the hardened runtime,
# notarize, staple, zip, and write a Sparkle appcast signed with the EdDSA key in your Keychain.
# Usage: scripts/release.sh 0.2.0 [build-number]
set -eu
cd "$(dirname "$0")/.."
[ -f config/Release.xcconfig ] || { echo "config/Release.xcconfig is missing; copy config/Release.example.xcconfig"; exit 1; }
conf() { sed -n "s/^$1 *= *//p" config/Release.xcconfig; }
export VERSION="${1:?usage: scripts/release.sh <version> [build]}"
export BUILD="${2:-$(git rev-list --count HEAD)}"
export SPARKLE_FEED_URL="$(conf SPARKLE_FEED_URL)" SPARKLE_PUBLIC_KEY="$(conf SPARKLE_PUBLIC_KEY)"
identity="$(conf DEVELOPER_ID)"; profile="$(conf NOTARY_PROFILE)"
for v in "$identity" "$profile" "$SPARKLE_FEED_URL" "$SPARKLE_PUBLIC_KEY"; do
  case "$v" in ""|*replace-me*|*example.com*|*TEAMID1234*) echo "fill in every value in config/Release.xcconfig"; exit 1;; esac
done
git diff --quiet HEAD || { echo "commit first: releases are built from a clean tree"; exit 1; }

./scripts/bundle.sh
app=build/midway.app
sign() { codesign --force --timestamp --options runtime --sign "$identity" "$@"; }
# Inside out, as Sparkle's docs ask: XPC services, helpers, the framework, then the app.
s="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$s/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$s/XPCServices/Downloader.xpc"
sign "$s/Autoupdate"
sign "$s/Updater.app"
sign "$app/Contents/Frameworks/Sparkle.framework"
sign "$app"
codesign --verify --strict --deep --verbose=2 "$app"

out=build/release; mkdir -p "$out"
zip="$out/midway-$VERSION.zip"
ditto -c -k --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
rm "$zip" && ditto -c -k --keepParent "$app" "$zip"   # the stapled app is what ships
spctl --assess --type execute --verbose "$app"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast --download-url-prefix "$(dirname "$SPARKLE_FEED_URL")/" "$out"
echo "Upload $zip and $out/appcast.xml to $(dirname "$SPARKLE_FEED_URL")/"
