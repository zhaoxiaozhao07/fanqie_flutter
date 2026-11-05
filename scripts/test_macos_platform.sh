#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLUTTER="${FLUTTER:-flutter}"
[[ "$(uname -m)" == arm64 ]] || { echo 'Apple Silicon is required' >&2; exit 2; }
cd "$ROOT"
"$FLUTTER" test integration_test/macos_client_platform_test.dart -d macos --reporter expanded "$@"
# Do not run xcodebuild concurrently with Flutter: both update the same build.
# Compile the normal app before host tests, not the integration test entry point.
"$FLUTTER" build macos --debug
"$ROOT/scripts/sign_macos_internal.sh" build/macos/Build/Products/Debug/FanqieReader.app debug
xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/macos \
  -parallel-testing-enabled NO
