# Task 5 — packaging/provenance/CI follow-up

Status: **DONE_WITH_CONCERNS — ready for independent controller review**, not
native/physical acceptance. Base `89e1c7d83530255d9db3a1d4847e826df88c7fa5`;
branch `codex/macos-sync-optimizations`. Work was confined to
`C:\Users\zz710\.codex\worktrees\macos-sync-optimizations\fanqie_flutter`.

## Scoped changes

- `scripts/macos_release_validation.py`: stdlib CLI/API for full production
  plist, resource/font/ICU/native-assets boundaries, safe paths and symlinks,
  file/directory/link snapshots, provenance, exact artifact sets, checksums,
  digest/size equality, exclusive local publication and remote verification.
  Uses the observed versioned App/FlutterMacOS framework layout and final
  `NativeAssetsManifest.json`; empty native-assets mapping is valid.
  Nonempty `charset.json` root is a list; the other three data roots are dicts.
  No arbitrary 362/2-entry count requirement was added.
- `scripts/package_macos.sh` / `scripts/verify_macos_bundle.sh` /
  `scripts/verify_macos_dmg.sh`: production version/build/entry checks and exact
  Release entitlements; ad-hoc staging, post-sign snapshot, private image
  without `-ov`, read-only mount, independent native/resource revalidation and
  snapshot equality, then three exclusive-created outputs. Old outputs are
  never replaced. Failed mount detach preserves its private mount with a
  diagnostic rather than deleting a mounted tree.
- `scripts/test_macos_package.py`: real-FS and actual CLI/runner/workflow-block
  tests, including corrupt/missing resources, malformed native modes, escaping
  links/paths, changed snapshots, wrong source/ref/run/attempt/version/SDK,
  wrong digests/sizes/file sets/checksum paths, repeated output publication,
  native architecture/permissions failures, mounted tampering and publication
  failure propagation. External native/gh commands are controlled doubles.
- `scripts/test_macos_reader_performance_pipeline.py`: both fake-process
  `read -t` timeouts are integer `1` for stock Bash 3.2. All six cases, watchdog,
  original exit statuses and no-leak assertions remain.
- `.github/workflows/macos-internal.yml`: retains mandatory Task 1 XCTest;
  adds package/provenance and lifecycle fixtures with separate logs.
  Bounded optional `full_platform` (15m), `reader_aot` (12m),
  `require_foreground`, and independent `live_api` (8m); manual panel/system
  fullscreen defines remain false. SDK machine evidence is collected after
  bootstrap, context binds native log/source/run, and mounted gates precede
  artifact upload. Publish validates downloaded provenance on Linux, refuses
  existing tags, then verifies remote source SHA and downloaded asset bytes/
  sizes/digests. Main-only, prerelease and `--latest=false` remain.
- `docs/MACOS_INTERNAL_RELEASE.md` / `docs/MACOS_CLIENT_VERIFICATION.md`:
  current naming/provenance, opt-ins and actual-validation boundaries;
  historical release evidence/assets preserved.

Outputs: `fanqie-v3.3.6-342-macos-arm64-internal.dmg`, same-name `.sha256`,
`build-info.json`. The new verified packager is **internal-only** and explicitly
rejects `release`; it does not route to Developer ID/notarization or mislabel
formal signing as ad-hoc. The bundle verifier's formal assessment mode remains.
This is an intentional packaging-interface limitation for review.

## RED → GREEN evidence

Python used:
`C:\Program Files\WindowsApps\OpenAI.CodexPrimaryRuntime.v26-1119-907-0_26.1119.907.0_x64__3k8sg7r9htsxt\dependencies\python\python.exe`.
Set `BASH_EXECUTABLE=C:\cygwin64\bin\bash.exe`, `PYTHONUTF8=1`.
All log names below are under
`C:\Users\zz710\.codex\worktrees\macos-sync-optimizations\fanqie_flutter\.dart_tool\codex-macos-followup\task-5\`.

| Commands (from workspace root) | Result | Logs |
|---|---|---|
| `python scripts/test_macos_package.py` before validators | RED: 14 expected failures, missing implementation | `package-red.log` |
| `python scripts/test_macos_package.py ShellPipelineTests.test_real_publish_block_verifies_build_qualified_remote_bytes ShellPipelineTests.test_real_publish_block_refuses_existing_tag_and_tampered_upload` before workflow changes | RED: 2 failures; old workflow looks for unqualified filename | `ci-red.log` |
| `python scripts/test_macos_package.py ValidationTests.test_data_json_root_boundary_includes_charset_list_and_rejects_empty` | RED: 8 empty-container subcases incorrectly accepted, then fixed | `data-root-red.log` |
| `python scripts/test_macos_package.py` | GREEN: 18 tests, exit 0; actual workflow blocks included | `package-green-final.log` |
| `python scripts/test_macos_reader_performance_pipeline.py` | GREEN: 6 tests, 39.794s, exit 0; all owned app/helpers dead | `lifecycle-green.log` |
| `python scripts/test_macos_native_pipeline.py` | GREEN: 19 tests, exit 0 | `native-pipeline-green.log` |
| `"D:\Install software\Flutter\flutter\bin\flutter.bat" --no-version-check --suppress-analytics test --no-pub --reporter expanded` | GREEN: 955 passed, 11 existing opt-in skips, exit 0 | `flutter-test.log` |
| Same Flutter CLI: `--no-version-check --suppress-analytics analyze --no-pub` | GREEN: no issues, exit 0 | `flutter-analyze.log` |
| Same Flutter CLI: `--no-version-check --suppress-analytics --version --machine` | Actual local Flutter 3.47.9 / Dart 3.13.7 | `flutter-version.json` |
| Cygwin Bash: each `scripts/*.sh` streamed through `tr -d '\r'` into `/bin/bash -n` | GREEN: all shell syntax, exit 0; not native Bash 3.2 execution | `shell-syntax.log` |
| `.dart_tool/codex-macos-followup/tools/actionlint.exe -shellcheck= .github/workflows/macos-internal.yml` | GREEN: exit 0 | `actionlint.log` |
| `git diff --check` | GREEN: exit 0; only checkout LF/CRLF notices | `diff-check.log` |

Intermediate fixture failures remain in `package-green-initial.log`,
`package-green-second.log`, `package-green-third.log`, `package-green-fourth.log`
and `package-green.log`; none count as GREEN evidence. Root causes were Windows
native link creation/relative separators, Cygwin-to-Windows path/encoding
adapters, directory-symlink type lost in copying, and accidental conversion of
the literal `/Applications` sentinel into a Cygwin installation path.
Copy doubles now use the same native Python/real FS, preserve link types in
two phases, and normalize copied shell CRLF. Production containment/snapshot
checks were not weakened to make fixtures pass.

## Self-review and remaining gates

- Reviewed the scoped diff against the brief/SDK boundary; Task 1 command
  fixtures still execute the required unchanged production Debug host/XCTest
  commands and propagate failures. Full platform/Profile precede the final
  production Release rebuild. New shell constructs are Bash 3.2 compatible;
  real `/bin/bash` 3.2 execution remains hosted-Mac evidence to obtain.
- `3.3.6+342`, macOS 12.0, arm64 and pinned SDK remain. No pubspec/dependency/
  lockfile, Android/Windows defaults/workflows, or old assets changed.
  Cleanup targets only operation/test-owned temporary paths. No production app
  was launched and no real user data/export/configuration was modified.
- No network, push, dispatch, PR, branch/worktree creation, merge, controller
  artifact deletion or public prerelease was performed. Worktree is retained.
- **Still required:** independent Task 5 and whole-branch review; controller
  execution of final hosted Mac native/platform/seven-scenario AOT and mounted
  production-DMG gates with `publish=false`, followed by verified DMG download.
  No final Mac artifact, real mount/signature result or hosted run is claimed.
  Requested hosted UI/foreground failure must remain diagnostic/fail-closed.
- Windows controlled commands do not prove native correctness, foreground
  FPS/Retina, audio, macOS 12 hardware or installation/upgrade acceptance.
  Developer ID, notarization and formal distribution are not claimed.

Implementation and portable gates are submitted for independent review; no
discretionary follow-up audit or CI dispatch is being started here.
