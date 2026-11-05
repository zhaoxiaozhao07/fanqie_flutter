#!/usr/bin/env bash
set -euo pipefail
APP="${1:?Usage: verify_macos_bundle.sh app-path [internal|release]}"
MODE="${2:-internal}"
[[ "$MODE" == internal || "$MODE" == release ]] || exit 2
PLIST="$APP/Contents/Info.plist"
[[ -f "$PLIST" ]] || { echo 'Missing app bundle' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :FanqieBuildTarget' "$PLIST")" == lib/main.dart ]] || {
  echo 'Refusing a test entry point as a client artifact; rebuild with --target lib/main.dart.' >&2
  exit 1
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" == com.fanqie.reader.macos ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")" == 12.0 ]]
COUNT=0
while IFS= read -r -d '' binary; do
  if file -b "$binary" | grep -q 'Mach-O'; then
    [[ "$(lipo -archs "$binary")" == arm64 ]] || { echo "Non-arm64 component: $binary" >&2; exit 1; }
    minimum="$(xcrun vtool -show-build "$binary" | awk '/minos/{print $2; exit}')"
    if [[ -z "$minimum" ]]; then
      minimum="$(otool -l "$binary" | awk '/LC_VERSION_MIN_MACOSX/{found=1;next} found && /version/{print $2;exit}')"
    fi
    python3 - "$minimum" <<'PY'
import sys
assert sys.argv[1], 'Missing minimum OS load command'
version = tuple(int(p) for p in sys.argv[1].split('.'))
assert version[:2] <= (12, 0), f'Native component requires macOS {sys.argv[1]}'
PY
    codesign --verify --strict "$binary"
    if [[ "$MODE" == release ]]; then
      signature="$(codesign -dv --verbose=4 "$binary" 2>&1)"
      grep -q 'Authority=Developer ID Application:' <<< "$signature"
      grep -q 'flags=.*runtime' <<< "$signature"
    fi
    COUNT=$((COUNT + 1))
  fi
done < <(find "$APP" -type f -print0)
[[ "$COUNT" -ge 2 ]]
codesign --verify --deep --strict "$APP"
ENTITLEMENTS="$(codesign -d --entitlements :- "$APP" 2>/dev/null)"
python3 - "$MODE" "$ENTITLEMENTS" <<'PY'
import plistlib, sys
p = plistlib.loads(sys.argv[2].encode())
for key in ['com.apple.security.app-sandbox', 'com.apple.security.network.client',
            'com.apple.security.files.user-selected.read-write']:
    assert p.get(key) is True, f'Missing entitlement: {key}'
if sys.argv[1] == 'release':
    assert not p.get('com.apple.security.cs.allow-jit'), 'Debug JIT entitlement in Release'
    assert not p.get('com.apple.security.network.server'), 'Debug server entitlement in Release'
PY
if [[ "$MODE" == release ]]; then
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi
echo "Verified $COUNT Mach-O components: arm64, macOS <=12, $MODE signing and permissions"
