#!/usr/bin/env bash
set -euo pipefail

# Use an isolated emulator: this test deliberately presses Home and locks it.
DEVICE_ID="${DEVICE_ID:-emulator-5554}"
FLUTTER="${FLUTTER:-flutter}"
case "$DEVICE_ID" in
  emulator-*) ;;
  *) echo "Use an isolated emulator for this unattended lock-screen test." >&2; exit 2 ;;
esac
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="${PLATFORM_TEST_LOG:-/tmp/fanqie-platform-tests.log}"
TARGET="${PLATFORM_TEST_TARGET:-integration_test/reader_platform_test.dart}"
EXTRA_ARGS=(--reporter expanded)
SOAK_BUDGET=0
if [[ "$TARGET" == *reader_soak_test.dart ]]; then
  SOAK_SECONDS="${SOAK_SECONDS:-1800}"
  if ! [[ "$SOAK_SECONDS" =~ ^[0-9]+$ ]] || [ "$SOAK_SECONDS" -lt 5 ] || [ "$SOAK_SECONDS" -gt 3600 ]; then
    echo "SOAK_SECONDS must be 5–3600." >&2; exit 2
  fi
  EXTRA_ARGS+=("--dart-define=SOAK_SECONDS=$SOAK_SECONDS")
  SOAK_BUDGET="$SOAK_SECONDS"
fi
PACKAGE="com.fanqie.fanqie_flutter"
restore() {
  adb -s "$DEVICE_ID" shell input keyevent 224 >/dev/null 2>&1 || true
  adb -s "$DEVICE_ID" shell wm dismiss-keyguard >/dev/null 2>&1 || true
  adb -s "$DEVICE_ID" shell am start -n "$PACKAGE/.MainActivity" >/dev/null 2>&1 || true
}
cleanup() {
  restore
  if [ -n "${TEST_PID:-}" ] && kill -0 "$TEST_PID" 2>/dev/null; then
    kill "$TEST_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT
cd "$ROOT"
: > "$LOG"
"$FLUTTER" test "$TARGET" -d "$DEVICE_ID" "${EXTRA_ARGS[@]}" > "$LOG" 2>&1 &
TEST_PID=$!
BACKGROUND=0
VERIFIED=0
PAUSED=0
PLAYED=0
CAPTURED=0
DEADLINE=$((SECONDS + 1800 + SOAK_BUDGET))
while kill -0 "$TEST_PID" 2>/dev/null; do
  if [ "$SECONDS" -gt "$DEADLINE" ]; then
    echo "Android platform verification timed out; see $LOG" >&2
    exit 1
  fi
  if [ "$CAPTURED" = 0 ] && grep -q 'FANQIE_READER_SETTINGS_CAPTURE' "$LOG"; then
    adb -s "$DEVICE_ID" exec-out screencap -p > "${LOG%.log}-settings.png"
    CAPTURED=1
  fi
  if [ "$BACKGROUND" = 0 ] && grep -q 'FANQIE_BACKGROUND_READY' "$LOG"; then
    adb -s "$DEVICE_ID" shell input keyevent 3
    adb -s "$DEVICE_ID" shell input keyevent 223
    BACKGROUND=1
  fi
  if [ "$PAUSED" = 0 ] && grep -q 'FANQIE_MEDIA_PAUSE_READY' "$LOG"; then
    adb -s "$DEVICE_ID" shell cmd media_session dispatch pause
    PAUSED=1
  fi
  if [ "$PLAYED" = 0 ] && grep -q 'FANQIE_MEDIA_PLAY_READY' "$LOG"; then
    adb -s "$DEVICE_ID" shell cmd media_session dispatch play
    PLAYED=1
  fi
  if [ "$VERIFIED" = 0 ] && grep -q 'FANQIE_BACKGROUND_VERIFIED' "$LOG"; then
    adb -s "$DEVICE_ID" shell dumpsys media_session > "${LOG%.log}-media-session.log"
    adb -s "$DEVICE_ID" shell dumpsys activity services "$PACKAGE" > "${LOG%.log}-services.log"
    restore
    VERIFIED=1
  fi
  sleep 0.5
done
RESULT=0
wait "$TEST_PID" || RESULT=$?
cat "$LOG"
if [ "$RESULT" != 0 ]; then exit "$RESULT"; fi
if [ "$BACKGROUND" != 1 ] || [ "$VERIFIED" != 1 ] || [ "$PAUSED" != 1 ] || [ "$PLAYED" != 1 ]; then
  echo "Background/screen-off verification did not complete." >&2
  exit 1
fi
