#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${1:?Usage: verify_macos_dmg.sh image pre-image-snapshot.json}"
SNAPSHOT="${2:?Pre-image bundle snapshot is required}"
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
# Mark before attach: even a partially successful attach must be detached.
ATTACHED=true
hdiutil attach "$IMAGE" -readonly -nobrowse -mountpoint "$MOUNT"
python3 - "$MOUNT" <<'PY'
from pathlib import Path
import sys
mount = Path(sys.argv[1])
assert {p.name for p in mount.iterdir()} == {
    '番茄Reader.app', 'Applications', 'INTERNAL_TESTING.txt'
}, 'Unexpected/missing image contents'
link = mount / 'Applications'
assert link.is_symlink() and link.readlink() == Path('/Applications'), 'Invalid Applications link'
notice = mount / 'INTERNAL_TESTING.txt'
assert notice.is_file() and not notice.is_symlink() and notice.stat().st_size > 0, 'Missing internal notice'
PY
"$ROOT/scripts/verify_macos_bundle.sh" "$MOUNT/番茄Reader.app" internal
python3 "$ROOT/scripts/macos_release_validation.py" compare "$MOUNT/番茄Reader.app" "$SNAPSHOT"
hdiutil detach "$MOUNT"
ATTACHED=false
echo 'Verified read-only mounted DMG against pre-image production bundle'
