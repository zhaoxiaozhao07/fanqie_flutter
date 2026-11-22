#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${1:?Usage: verify_macos_dmg.sh image pre-image-snapshot.json [internal|release]}"
SNAPSHOT="${2:?Pre-image bundle snapshot is required}"
MODE="${3:-internal}"
[[ "$MODE" == internal || "$MODE" == release ]] || exit 2
[[ -f "$IMAGE" && ! -L "$IMAGE" && -f "$SNAPSHOT" ]] || exit 2
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fanqie-dmg.XXXXXX")"
MOUNT="$WORK/mount"
mkdir "$MOUNT"
ATTACHED=false
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ "$ATTACHED" == true ]]; then
    if ! hdiutil detach "$MOUNT"; then
      echo "Detach failed; preserving this operation's mount at $MOUNT" >&2
      [[ "$status" != 0 ]] || status=1
      return "$status"
    fi
  fi
  rm -rf "$WORK"
  return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
hdiutil verify "$IMAGE"
if [[ "$MODE" == release ]]; then
  xcrun stapler validate "$IMAGE"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$IMAGE"
fi
# Mark before attach: even a partially successful attach must be detached.
ATTACHED=true
hdiutil attach "$IMAGE" -readonly -nobrowse -mountpoint "$MOUNT"
python3 - "$MOUNT" "$MODE" <<'PY'
from pathlib import Path
import sys
mount = Path(sys.argv[1])
expected = {'番茄Reader.app', 'Applications'}
if sys.argv[2] == 'internal':
    expected.add('INTERNAL_TESTING.txt')
if {p.name for p in mount.iterdir()} != expected:
    sys.exit('Unexpected/missing image contents')
link = mount / 'Applications'
if not link.is_symlink() or link.readlink() != Path('/Applications'):
    sys.exit('Invalid Applications link')
if sys.argv[2] == 'internal':
    notice = mount / 'INTERNAL_TESTING.txt'
    if not notice.is_file() or notice.is_symlink() or notice.stat().st_size == 0:
        sys.exit('Missing internal notice')
PY
"$ROOT/scripts/verify_macos_bundle.sh" "$MOUNT/番茄Reader.app" "$MODE"
python3 "$ROOT/scripts/macos_release_validation.py" compare "$MOUNT/番茄Reader.app" "$SNAPSHOT"
hdiutil detach "$MOUNT"
ATTACHED=false
echo 'Verified read-only mounted DMG against pre-image production bundle'
