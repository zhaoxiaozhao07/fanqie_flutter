#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLUTTER="${FLUTTER:-flutter}"
LOG="${MACOS_READER_PERF_LOG:-/tmp/fanqie-workspace-performance.log}"
[[ "$(uname -m)" == arm64 ]] || exit 2
cd "$ROOT"
"$FLUTTER" build macos --profile --no-pub --target integration_test/macos_reader_performance.dart
APP="build/macos/Build/Products/Profile/FanqieReader.app"
"$ROOT/scripts/sign_macos_internal.sh" "$APP" debug
# Test-scoped only: an occluded profile window does not own a foreground
# display assertion. Do not let OS idle sleep stall the synthetic workload.
/usr/bin/caffeinate -di "$APP/Contents/MacOS/FanqieReader" > "$LOG" 2>&1 &
PID=$!
cleanup() {
  if kill -0 "$PID" 2>/dev/null; then kill "$PID" 2>/dev/null || true; fi
}
trap cleanup EXIT
DEADLINE=$((SECONDS + 180))
while kill -0 "$PID" 2>/dev/null; do
  if (( SECONDS > DEADLINE )); then
    cat "$LOG"
    echo 'AOT Profile reading benchmark timed out' >&2
    exit 1
  fi
  sleep 0.5
done
RESULT=0
wait "$PID" || RESULT=$?
cat "$LOG"
[[ "$RESULT" == 0 ]]
grep -q '^FANQIE_WORKSPACE_PERF_OK ' "$LOG"
