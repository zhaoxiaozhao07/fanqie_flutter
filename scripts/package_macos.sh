#!/usr/bin/env bash
set -euo pipefail
# Internal self-use by default. Formal signing is explicit manual selection,
# never an automatic fallback or part of the self-use provenance/CI flow.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/macos/Build/Products/Release/FanqieReader.app}"
MODE="${2:-internal}"
OUT="${3:-$ROOT/build/macos/distribution}"
VALIDATOR="$ROOT/scripts/macos_release_validation.py"
[[ "$(uname -m)" == arm64 ]] || { echo 'Apple Silicon is required' >&2; exit 2; }
[[ "$MODE" == internal || "$MODE" == release ]] || exit 2
FULL_VERSION="$(python3 "$ROOT/scripts/release_identity.py" "$ROOT/pubspec.yaml")"
VERSION="${FULL_VERSION%%+*}"
BUILD="${FULL_VERSION##*+}"
if [[ "$MODE" == release ]]; then
  exec "$ROOT/scripts/package_macos_release.sh" "$APP" "$OUT"
fi
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
NAME="fanqie-v${VERSION}-${BUILD}-macos-arm64-internal.dmg"
# Create only inside this operation's private directory; never use -ov.
hdiutil create -volname "番茄Reader ${VERSION} (${BUILD})" -srcfolder "$WORK/content" \
  -format UDZO "$WORK/artifacts/$NAME"
"$ROOT/scripts/verify_macos_dmg.sh" "$WORK/artifacts/$NAME" "$WORK/bundle-snapshot.json"
python3 "$VALIDATOR" create "$WORK/artifacts" \
  --snapshot "$WORK/bundle-snapshot.json" --context "$MACOS_RELEASE_CONTEXT"
python3 "$VALIDATOR" publish-local "$WORK/artifacts" "$OUT"
echo "$OUT/$NAME"
