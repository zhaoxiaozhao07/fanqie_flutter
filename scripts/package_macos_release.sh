#!/usr/bin/env bash
set -euo pipefail
# Explicit manual compatibility route only. Never invoked by internal CI,
# never uses the ad-hoc provenance schema, never falls back to internal signing.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?Usage: package_macos_release.sh app-path output-directory}"
OUT="${2:?Output directory is required}"
VALIDATOR="$ROOT/scripts/macos_release_validation.py"
: "${MACOS_SIGN_IDENTITY:?Developer ID Application identity is required}"
: "${MACOS_NOTARY_PROFILE:?Notary keychain profile is required}"
[[ "$MACOS_SIGN_IDENTITY" == 'Developer ID Application:'* ]] || {
  echo 'Not a Developer ID identity' >&2; exit 2;
}
[[ "$(uname -m)" == arm64 ]]
[[ "$(awk '/^version:/{print $2}' "$ROOT/pubspec.yaml")" == 3.3.6+342 ]]
python3 "$VALIDATOR" bundle "$APP"
python3 "$VALIDATOR" check-output "$OUT" --mode release
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fanqie-package.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/artifacts"
ditto "$APP" "$WORK/content/番茄Reader.app"
STAGED="$WORK/content/番茄Reader.app"
ln -s /Applications "$WORK/content/Applications"
# Preserve the old order: leaf Mach-O, deepest containing bundles, main app.
find "$STAGED" -type f -print0 > "$WORK/leaf-files.list"
while IFS= read -r -d '' binary; do
  if file -b "$binary" | grep -q 'Mach-O'; then
    codesign --force --timestamp --options runtime --sign "$MACOS_SIGN_IDENTITY" "$binary"
  fi
done < "$WORK/leaf-files.list"
python3 - "$ROOT/scripts" "$STAGED" > "$WORK/signing-bundles.list" <<'PY'
from pathlib import Path
import sys
sys.path.insert(0, sys.argv[1])
from macos_release_validation import snapshot_bundle
root = Path(sys.argv[2])
bundles = [path for path, entry in snapshot_bundle(root).items()
           if entry['type'] == 'directory'
           and path.endswith(('.framework', '.app', '.xpc', '.bundle'))]
for path in sorted(bundles, key=lambda p: p.count('/'), reverse=True):
    sys.stdout.buffer.write(str(root / path).encode() + b'\0')
PY
while IFS= read -r -d '' bundle; do
  codesign --force --timestamp --options runtime --sign "$MACOS_SIGN_IDENTITY" "$bundle"
done < "$WORK/signing-bundles.list"
codesign --force --timestamp --options runtime --sign "$MACOS_SIGN_IDENTITY" \
  --entitlements "$ROOT/macos/Runner/Release.entitlements" "$STAGED"
ditto -c -k --keepParent "$STAGED" "$WORK/notarize.zip"
xcrun notarytool submit "$WORK/notarize.zip" --keychain-profile "$MACOS_NOTARY_PROFILE" --wait
xcrun stapler staple "$STAGED"
"$ROOT/scripts/verify_macos_bundle.sh" "$STAGED" release
python3 "$VALIDATOR" snapshot "$STAGED" "$WORK/bundle-snapshot.json"
NAME="fanqie-v3.3.6-342-macos-arm64.dmg"
IMAGE="$WORK/artifacts/$NAME"
hdiutil create -volname '番茄Reader 3.3.6 (342)' -srcfolder "$WORK/content" -format UDZO "$IMAGE"
codesign --force --timestamp --sign "$MACOS_SIGN_IDENTITY" "$IMAGE"
xcrun notarytool submit "$IMAGE" --keychain-profile "$MACOS_NOTARY_PROFILE" --wait
xcrun stapler staple "$IMAGE"
"$ROOT/scripts/verify_macos_dmg.sh" "$IMAGE" "$WORK/bundle-snapshot.json" release
(cd "$WORK/artifacts" && shasum -a 256 "$NAME" > "$NAME.sha256")
python3 "$VALIDATOR" publish-local "$WORK/artifacts" "$OUT" --mode release
echo "$OUT/$NAME"
