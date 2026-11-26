#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="build/AI Usage.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
swiftc -O -swift-version 5 UsageProviders.swift main.swift -o "$APP/Contents/MacOS/AIUsage"
codesign --force --sign - "$APP"

rm -rf "/Applications/AI Usage.app" "/Applications/ClaudeUsage.app"
cp -R "$APP" "/Applications/"
echo "OK: /Applications/AI Usage.app"
