#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLUTTER="${FLUTTER:-flutter}"
LOG="${MACOS_READER_PERF_LOG:-/tmp/fanqie-workspace-performance.log}"
REQUIRE_FOREGROUND="${MACOS_REQUIRE_FOREGROUND:-false}"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
  echo 'AOT Profile reading benchmark requires macOS arm64' >&2
  exit 2
}
[[ "$REQUIRE_FOREGROUND" == true || "$REQUIRE_FOREGROUND" == false ]] || {
  echo 'MACOS_REQUIRE_FOREGROUND must be true or false' >&2
  exit 2
}
[[ ! -L "$LOG" && ! -d "$LOG" ]] || {
  echo 'Refusing to overwrite a symlink/directory performance log' >&2
  exit 2
}
cd "$ROOT"
"$FLUTTER" build macos --profile --no-pub \
  --target integration_test/macos_reader_performance.dart \
  --dart-define="MACOS_REQUIRE_FOREGROUND=$REQUIRE_FOREGROUND"
APP="build/macos/Build/Products/Profile/FanqieReader.app"
"$ROOT/scripts/sign_macos_internal.sh" "$APP" debug
# Test-scoped only: an occluded profile window does not own a foreground
# display assertion. Do not let OS idle sleep stall the synthetic workload.
"$APP/Contents/MacOS/FanqieReader" > "$LOG" 2>&1 &
PID=$!
AWAKE_PID=''
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if kill -0 "$PID" 2>/dev/null; then
    # Target the app, not just a caffeinate parent that could leave it running.
    # Dart handles TERM cooperatively and restores its isolated state in finally.
    kill -TERM "$PID" 2>/dev/null || true
    local grace=$((SECONDS + 30))
    while kill -0 "$PID" 2>/dev/null && (( SECONDS < grace )); do sleep 0.5; done
    if kill -0 "$PID" 2>/dev/null; then
      echo 'AOT cleanup did not finish within 30s; forcing isolated app exit' >&2
      kill -KILL "$PID" 2>/dev/null || true
    fi
    wait "$PID" 2>/dev/null || true
  fi
  if [[ -n "$AWAKE_PID" ]]; then
    kill -TERM "$AWAKE_PID" 2>/dev/null || true
    local awake_grace=$((SECONDS + 5))
    while kill -0 "$AWAKE_PID" 2>/dev/null && (( SECONDS < awake_grace )); do sleep 0.1; done
    if kill -0 "$AWAKE_PID" 2>/dev/null; then
      echo 'Test-scoped caffeinate ignored TERM; forcing helper exit' >&2
      kill -KILL "$AWAKE_PID" 2>/dev/null || true
      local awake_reap=$((SECONDS + 1))
      while kill -0 "$AWAKE_PID" 2>/dev/null && (( SECONDS < awake_reap )); do sleep 0.1; done
    fi
    if kill -0 "$AWAKE_PID" 2>/dev/null; then
      # Never turn an EXIT trap into another unbounded wait, even after KILL.
      echo 'Test-scoped caffeinate did not exit after KILL; skipping blocking wait' >&2
      [[ "$status" != 0 ]] || status=1
    else
      wait "$AWAKE_PID" 2>/dev/null || true
    fi
  fi
  return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
/usr/bin/caffeinate -di -w "$PID" >/dev/null 2>&1 &
AWAKE_PID=$!
DEADLINE=$((SECONDS + 180))
while kill -0 "$PID" 2>/dev/null; do
  if (( SECONDS > DEADLINE )); then
    cat "$LOG"
    echo 'AOT Profile reading benchmark timed out' >&2
    exit 1
  fi
  if [[ -n "$AWAKE_PID" ]] && ! kill -0 "$AWAKE_PID" 2>/dev/null; then
    AWAKE_RESULT=0
    wait "$AWAKE_PID" || AWAKE_RESULT=$?
    AWAKE_PID=''
    if [[ "$AWAKE_RESULT" != 0 ]]; then
      cat "$LOG"
      echo 'Test-scoped caffeinate failed' >&2
      exit 1
    fi
  fi
  sleep 0.5
done
RESULT=0
wait "$PID" || RESULT=$?
if [[ -n "$AWAKE_PID" ]]; then
  AWAKE_DEADLINE=$((SECONDS + 5))
  while kill -0 "$AWAKE_PID" 2>/dev/null && (( SECONDS < AWAKE_DEADLINE )); do sleep 0.1; done
  if kill -0 "$AWAKE_PID" 2>/dev/null; then
    echo 'Test-scoped caffeinate did not finish after the benchmark app' >&2
    [[ "$RESULT" != 0 ]] || RESULT=1
    exit "$RESULT"
  fi
  AWAKE_RESULT=0
  wait "$AWAKE_PID" || AWAKE_RESULT=$?
  [[ "$RESULT" != 0 ]] || RESULT=$AWAKE_RESULT
  AWAKE_PID=''
fi
cat "$LOG"
if [[ "$RESULT" != 0 ]]; then exit "$RESULT"; fi
[[ "$(grep -c '^FANQIE_WORKSPACE_PERF_MODE ' "$LOG")" == 7 ]]
grep -q '^FANQIE_WORKSPACE_PERF_OK ' "$LOG"
