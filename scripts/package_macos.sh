#!/usr/bin/env bash
set -euo pipefail
# Internal builds are explicitly named; public names are gated on Developer ID,
# app AND DMG notarization, stapled tickets and Gatekeeper assessment.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/macos/Build/Products/Release/FanqieReader.app}"
MODE="${2:-internal}"
OUT="${3:-$ROOT/build/macos/distribution}"
[[ "$(uname -m)" == arm64 ]] || { echo 'Apple Silicon is required' >&2; exit 2; }
[[ "$MODE" == internal || "$MODE" == release ]] || exit 2
VERSION="$(awk '/^version:/{split($2,v,"+");print v[1]}' "$ROOT/pubspec.yaml")"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$VERSION" ]]
if [[ "$MODE" == release ]]; then
  : "${MACOS_SIGN_IDENTITY:?Developer ID Application identity is required}"
  : "${MACOS_NOTARY_PROFILE:?Notary keychain profile is required}"
  [[ "$MACOS_SIGN_IDENTITY" == 'Developer ID Application:'* ]] || { echo 'Not a Developer ID identity' >&2; exit 2; }
fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fanqie-package.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ditto "$APP" "$WORK/content/番茄Reader.app"
STAGED="$WORK/content/番茄Reader.app"
ln -s /Applications "$WORK/content/Applications"
if [[ "$MODE" == internal ]]; then
  NAME="fanqie-v$VERSION-macos-arm64-internal.dmg"
  printf '%s\n' '内部测试包，非正式分发。未使用 Developer ID 签名、未公证。' \
    '仅供受信任的开发测试；不表示已通过 Gatekeeper 或最低系统实机验收。' \
    > "$WORK/content/INTERNAL_TESTING.txt"
  "$ROOT/scripts/sign_macos_internal.sh" "$STAGED" release
  "$ROOT/scripts/verify_macos_bundle.sh" "$STAGED" internal
else
  NAME="fanqie-v$VERSION-macos-arm64.dmg"
  # Sign leaf executable code, then containing frameworks/bundles, then the app.
  while IFS= read -r -d '' binary; do
    if file -b "$binary" | grep -q 'Mach-O'; then
      codesign --force --timestamp --options runtime --sign "$MACOS_SIGN_IDENTITY" "$binary"
    fi
  done < <(find "$STAGED" -type f -print0)
  while IFS= read -r -d '' bundle; do
    codesign --force --timestamp --options runtime --sign "$MACOS_SIGN_IDENTITY" "$bundle"
  done < <(python3 - "$STAGED" <<'PY'
import os, sys
root = sys.argv[1]
bundles = []
for path, dirs, _ in os.walk(root):
    if path != root and path.endswith(('.framework', '.app', '.xpc', '.bundle')):
        bundles.append(path)
for path in sorted(bundles, key=lambda p:p.count('/'), reverse=True):
    sys.stdout.buffer.write(path.encode() + b'\0')
PY
)
  codesign --force --timestamp --options runtime --sign "$MACOS_SIGN_IDENTITY" \
    --entitlements "$ROOT/macos/Runner/Release.entitlements" "$STAGED"
  ditto -c -k --keepParent "$STAGED" "$WORK/notarize.zip"
  xcrun notarytool submit "$WORK/notarize.zip" --keychain-profile "$MACOS_NOTARY_PROFILE" --wait
  xcrun stapler staple "$STAGED"
  "$ROOT/scripts/verify_macos_bundle.sh" "$STAGED" release
fi
hdiutil create -volname "番茄Reader $VERSION" -srcfolder "$WORK/content" \
  -ov -format UDZO "$OUT/$NAME"
if [[ "$MODE" == release ]]; then
  codesign --force --timestamp --sign "$MACOS_SIGN_IDENTITY" "$OUT/$NAME"
  xcrun notarytool submit "$OUT/$NAME" --keychain-profile "$MACOS_NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUT/$NAME"
  xcrun stapler validate "$OUT/$NAME"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$OUT/$NAME"
fi
hdiutil verify "$OUT/$NAME"
(cd "$OUT" && shasum -a 256 "$NAME" > "$NAME.sha256")
echo "$OUT/$NAME"
