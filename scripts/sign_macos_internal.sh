#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?Usage: sign_macos_internal.sh app-path [debug|release]}"
MODE="${2:-release}"
case "$MODE" in
  debug) ENTITLEMENTS="$ROOT/macos/Runner/DebugProfile.entitlements" ;;
  release) ENTITLEMENTS="$ROOT/macos/Runner/Release.entitlements" ;;
  *) exit 2 ;;
esac
# Flutter's incremental AOT embedding can change App.framework after Xcode has
# cached the outer seal. Refresh ONLY the internal ad-hoc outer signature. The
# Developer ID flow is separate and signs all components with Hardened Runtime.
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"
