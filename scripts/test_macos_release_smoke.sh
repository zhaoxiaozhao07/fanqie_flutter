#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLUTTER="${FLUTTER:-flutter}"
LOG="${MACOS_RELEASE_SMOKE_LOG:-/tmp/fanqie-release-smoke.log}"
[[ "$(uname -m)" == arm64 ]] || exit 2
cd "$ROOT"
BUILD_ARGS=(build macos --release --no-pub --target integration_test/macos_release_smoke.dart)
WAIT_SECONDS=60
if [[ "${MACOS_SAVE_PANEL_TEST:-0}" == 1 ]]; then
  BUILD_ARGS+=(--dart-define=MACOS_SAVE_PANEL_TEST=true)
  WAIT_SECONDS=600
fi
"$FLUTTER" "${BUILD_ARGS[@]}"
"$ROOT/scripts/sign_macos_internal.sh" build/macos/Build/Products/Release/FanqieReader.app release
build/macos/Build/Products/Release/FanqieReader.app/Contents/MacOS/FanqieReader > "$LOG" 2>&1 &
PID=$!
cleanup() {
  if kill -0 "$PID" 2>/dev/null; then kill "$PID" 2>/dev/null || true; fi
}
trap cleanup EXIT
DEADLINE=$((SECONDS + WAIT_SECONDS))
while kill -0 "$PID" 2>/dev/null; do
  if (( SECONDS > DEADLINE )); then
    cat "$LOG"
    echo 'Release smoke test timed out' >&2
    exit 1
  fi
  sleep 0.5
done
RESULT=0
wait "$PID" || RESULT=$?
cat "$LOG"
[[ "$RESULT" == 0 ]]
grep -q '^FANQIE_RELEASE_SMOKE_OK ' "$LOG"
grep -q '^FANQIE_RELEASE_QUIT_ALLOWED ' "$LOG"
# Never deliver the isolated smoke entry point as the client.
"$FLUTTER" build macos --release --no-pub --target lib/main.dart
"$ROOT/scripts/sign_macos_internal.sh" build/macos/Build/Products/Release/FanqieReader.app release
"$ROOT/scripts/verify_macos_bundle.sh" build/macos/Build/Products/Release/FanqieReader.app internal
