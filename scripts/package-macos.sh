#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodebuild >/dev/null || { echo 'Xcode is required for the macOS application build.' >&2; exit 1; }
output="${1:-$PWD/.build/macos-app}"
xcodebuild -project MockInterview.xcodeproj -scheme MockInterview -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$output" CODE_SIGNING_ALLOWED=NO build
app="$output/Build/Products/Release/MockInterview.app"
plist="$app/Contents/Info.plist"
test -x "$app/Contents/MacOS/MockInterview"
xcrun lipo "$app/Contents/MacOS/MockInterview" -verify_arch arm64 x86_64
test ! -d "$app/Contents/_CodeSignature"
plutil -lint "$plist"
test "$(plutil -extract CFBundlePackageType raw "$plist")" = APPL
test "$(plutil -extract LSMinimumSystemVersion raw "$plist")" = 14.2
test -n "$(plutil -extract CFBundleShortVersionString raw "$plist")"
test -n "$(plutil -extract CFBundleVersion raw "$plist")"
test "$(plutil -extract CFBundleIconFile raw "$plist")" = MockInterview.icns
test -s "$app/Contents/Resources/MockInterview.icns"
for usage in NSAudioCaptureUsageDescription NSMicrophoneUsageDescription NSSpeechRecognitionUsageDescription; do
  test -n "$(plutil -extract "$usage" raw "$plist")"
done
printf '%s\n' "$app"
