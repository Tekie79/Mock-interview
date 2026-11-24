#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodebuild >/dev/null || { echo 'Xcode is required for the macOS application build.' >&2; exit 1; }
output="${1:-$PWD/.build/macos-app}"
xcodebuild -project MockInterview.xcodeproj -scheme MockInterview -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$output" CODE_SIGNING_ALLOWED=NO build
test -d "$output/Build/Products/Release/MockInterview.app"
printf '%s\n' "$output/Build/Products/Release/MockInterview.app"
