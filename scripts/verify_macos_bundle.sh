#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?Usage: verify_macos_bundle.sh app-path [internal|release]}"
MODE="${2:-internal}"
[[ "$MODE" == internal || "$MODE" == release ]] || exit 2
PLIST="$APP/Contents/Info.plist"
[[ -f "$PLIST" ]] || { echo 'Missing app bundle' >&2; exit 1; }
# Includes full 3.3.6/342 plist, production entry point, AOT resources, ICU,
# font/native-assets manifests and non-escaping framework links.
python3 "$ROOT/scripts/macos_release_validation.py" bundle "$APP"
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
if not sys.argv[1]:
    sys.exit('Missing minimum OS load command')
version = tuple(int(p) for p in sys.argv[1].split('.'))
if version[:2] > (12, 0):
    sys.exit(f'Native component requires macOS {sys.argv[1]}')
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
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fanqie-permissions.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
codesign -d --entitlements :- "$APP" > "$WORK/entitlements.plist" 2>/dev/null
# Both internal and formal production AOT must have the same narrow permissions;
# ad-hoc signing is not permission to include Debug JIT/server entitlements.
python3 "$ROOT/scripts/macos_release_validation.py" entitlements "$WORK/entitlements.plist"
if [[ "$MODE" == release ]]; then
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi
echo "Verified $COUNT Mach-O components: arm64, macOS <=12, $MODE signing and permissions"
