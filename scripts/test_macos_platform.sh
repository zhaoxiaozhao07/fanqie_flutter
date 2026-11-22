#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLUTTER="${FLUTTER:-flutter}"
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS is required' >&2; exit 2; }
[[ "$(uname -m)" == arm64 ]] || { echo 'Apple Silicon is required' >&2; exit 2; }
cd "$ROOT"
"$FLUTTER" test integration_test/macos_client_platform_test.dart -d macos \
  --no-pub --reporter expanded "$@"
# Keep the full integration/manual entry point, then restore the production host
# and run the same fail-closed native gate used by CI.
"$ROOT/scripts/test_macos_native.sh"
