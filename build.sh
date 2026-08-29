#!/bin/bash
# Builds ClaudeUsageBar.app and installs it to /Applications.
#
#   ./build.sh            build + install + launch
#   ./build.sh --no-install   build into ./build only

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/build/ClaudeUsageBar.app"

if ! command -v clang >/dev/null 2>&1; then
  echo "clang not found. Install the Xcode command line tools first:"
  echo "  xcode-select --install"
  exit 1
fi

echo "Building..."
rm -rf "$DIR/build"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>ClaudeUsageBar</string>
	<key>CFBundleDisplayName</key>
	<string>Claude Usage</string>
	<key>CFBundleIdentifier</key>
	<string>com.haicreative.claudeusagebar</string>
	<key>CFBundleExecutable</key>
	<string>ClaudeUsageBar</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>12.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

# Objective-C, not Swift: compiling against the SDK's C headers sidesteps the
# swiftinterface/compiler version check that stock Command Line Tools trip on.
clang -O2 -fobjc-arc -Wall \
  -mmacosx-version-min=12.0 \
  -o "$APP/Contents/MacOS/ClaudeUsageBar" \
  "$DIR/main.m" \
  -framework Cocoa

codesign --force --sign - "$APP" >/dev/null 2>&1 || \
  echo "(ad-hoc signing skipped — app will still run)"

echo "Built: $APP"

if [ "${1:-}" = "--no-install" ]; then
  exit 0
fi

echo "Installing to /Applications..."
pkill -f "ClaudeUsageBar" 2>/dev/null || true
sleep 1
rm -rf "/Applications/ClaudeUsageBar.app"
cp -R "$APP" "/Applications/ClaudeUsageBar.app"

open "/Applications/ClaudeUsageBar.app"

echo
echo "Running. Look for the battery-style gauge in your menu bar."
echo
echo "macOS will ask once for permission to read the Claude Code token from your"
echo "Keychain — click 'Always Allow'."
echo
echo "To start it automatically at login:"
echo "  osascript -e 'tell application \"System Events\" to make login item at end with properties {path:\"/Applications/ClaudeUsageBar.app\", hidden:true}'"
echo
echo "To remove it:"
echo "  pkill -f ClaudeUsageBar; rm -rf /Applications/ClaudeUsageBar.app"
