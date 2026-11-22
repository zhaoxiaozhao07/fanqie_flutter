#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLUTTER="${FLUTTER:-flutter}"
APP=build/macos/Build/Products/Debug/FanqieReader.app
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS is required' >&2; exit 2; }
[[ "$(uname -m)" == arm64 ]] || { echo 'Apple Silicon is required' >&2; exit 2; }
cd "$ROOT"

# An integration run can leave a different FLUTTER_TARGET in generated settings.
# Always restore the production host without resolving or changing dependencies.
"$FLUTTER" build macos --debug --no-pub --target lib/main.dart
"$ROOT/scripts/sign_macos_internal.sh" "$APP" debug
# Flutter and Xcode update the same build tree; never run them concurrently.
xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/macos -parallel-testing-enabled NO
