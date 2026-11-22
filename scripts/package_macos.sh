#!/usr/bin/env bash
set -euo pipefail
# Self-use only. No Developer ID/notarization fallback or formal-release claim.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/macos/Build/Products/Release/FanqieReader.app}"
MODE="${2:-internal}"
OUT="${3:-$ROOT/build/macos/distribution}"
VALIDATOR="$ROOT/scripts/macos_release_validation.py"
[[ "$(uname -m)" == arm64 ]] || { echo 'Apple Silicon is required' >&2; exit 2; }
[[ "$MODE" == internal ]] || { echo 'This verified packager supports self-use internal mode only; no signing fallback.' >&2; exit 2; }
[[ "$(awk '/^version:/{print $2}' "$ROOT/pubspec.yaml")" == 3.3.6+342 ]]
: "${MACOS_RELEASE_CONTEXT:?Verified SDK/source/run/native-test context is required}"
python3 "$VALIDATOR" bundle "$APP"
python3 "$VALIDATOR" check-output "$OUT"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fanqie-package.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/artifacts"
ditto "$APP" "$WORK/content/番茄Reader.app"
STAGED="$WORK/content/番茄Reader.app"
ln -s /Applications "$WORK/content/Applications"
printf '%s\n' '内部测试包，非正式分发。未使用 Developer ID 签名、未公证。' \
  '仅供受信任的开发测试；不表示已通过 Gatekeeper 或最低系统实机验收。' \
  > "$WORK/content/INTERNAL_TESTING.txt"
"$ROOT/scripts/sign_macos_internal.sh" "$STAGED" release
"$ROOT/scripts/verify_macos_bundle.sh" "$STAGED" internal
python3 "$VALIDATOR" snapshot "$STAGED" "$WORK/bundle-snapshot.json"
NAME="fanqie-v3.3.6-342-macos-arm64-internal.dmg"
# Create only inside this operation's private directory; never use -ov.
hdiutil create -volname '番茄Reader 3.3.6 (342)' -srcfolder "$WORK/content" \
  -format UDZO "$WORK/artifacts/$NAME"
"$ROOT/scripts/verify_macos_dmg.sh" "$WORK/artifacts/$NAME" "$WORK/bundle-snapshot.json"
python3 "$VALIDATOR" create "$WORK/artifacts" \
  --snapshot "$WORK/bundle-snapshot.json" --context "$MACOS_RELEASE_CONTEXT"
python3 "$VALIDATOR" publish-local "$WORK/artifacts" "$OUT"
echo "$OUT/$NAME"
