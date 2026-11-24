#!/bin/sh
# Builds midway.app with just the Command Line Tools. Ad-hoc signed with the hardened runtime;
# Developer ID signing and notarization come with the Ship milestone.
set -eu
cd "$(dirname "$0")/.."
# Google OAuth client for Gmail, kept out of git (see config/Google.example.xcconfig).
if [ -f config/Google.xcconfig ]; then
  GOOGLE_CLIENT_ID=$(sed -n 's/^GOOGLE_CLIENT_ID *= *//p' config/Google.xcconfig)
  GOOGLE_CLIENT_SECRET=$(sed -n 's/^GOOGLE_CLIENT_SECRET *= *//p' config/Google.xcconfig)
fi
swift build -c release --product midway
app=build/midway.app
rm -rf "$app" && mkdir -p "$app/Contents/MacOS"
cp .build/release/midway "$app/Contents/MacOS/midway"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.midway.app</string>
  <key>CFBundleName</key><string>midway</string>
  <key>CFBundleExecutable</key><string>midway</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>GoogleClientID</key><string>${GOOGLE_CLIENT_ID:-}</string>
  <key>GoogleClientSecret</key><string>${GOOGLE_CLIENT_SECRET:-}</string>
</dict></plist>
PLIST
codesign --force --options runtime --sign - "$app"
echo "$app"
