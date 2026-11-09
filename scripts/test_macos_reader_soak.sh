#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLUTTER="${FLUTTER:-flutter}"
[[ "$(uname -m)" == arm64 ]] || exit 2
cd "$ROOT"
# Temporary test-scoped assertions, not a change to the user's power settings
# or the client's foreground-only keep-awake behavior.
exec /usr/bin/caffeinate -di "$FLUTTER" test \
  integration_test/macos_reader_soak_test.dart -d macos \
  --dart-define="SOAK_SECONDS=${SOAK_SECONDS:-1800}" \
  --dart-define="SOAK_TICK_MS=${SOAK_TICK_MS:-4000}" \
  --reporter expanded "$@"
