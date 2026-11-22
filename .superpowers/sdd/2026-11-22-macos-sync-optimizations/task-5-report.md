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

## Fix round 1 / 5 — incremental evidence

Fix base: `2c8e7051a23ffecaa1a9dc5a78f9a5d716924b88`.
Implementation commit: **`b96bbf7b0400643969d3090c27035c721f3058ae`** `[skip ci]`;
this append is a following report-only commit. The earlier internal-only
interface disposition above describes 2c8e705, **not the restored current
manual compatibility route**. Final review/CI should use the returned HEAD.

### Findings fixed

- **I1:** `snapshot_bundle` now raises `ValidationError` through `os.walk`
  `onerror`. A real extra fixture directory/file and one injected PermissionError
  at that actual scandir boundary prove bundle validation, snapshot creation and
  comparison fail instead of accepting an omitted file. Valid framework links
  and containment checks remain.
- **I2:** explicit `package_macos.sh APP release OUT` dispatches only to new
  `scripts/package_macos_release.sh`, with required Developer ID identity/notary
  profile. Preserves leaf → nested → app signing, app ZIP notarization/stapling/
  Gatekeeper, then private DMG signing/notarization/stapling/Gatekeeper, read-only
  formal bundle/snapshot verification and exclusive two-file publication.
  Filename is `fanqie-v3.3.6-342-macos-arm64.dmg`; no ad-hoc build-info or internal
  context is read/generated. Internal CI/provenance remains unchanged and cannot
  choose formal mode or fall back automatically. Enumeration producers in the
  helper run fail-closed into private lists before signing consumers.
- **I3 precise diagnosis:** reproduced the named test without parallel Flutter,
  retaining 25s: first call exit 37 at 12.235s, second call `TimeoutExpired` at
  **25.031s**. Captured stdout/stderr show both verifier passes reached 20
  “Mach-O” components, tampered snapshot was rejected, fake detach returned and
  mounted cleanup completed. Last boundary was package EXIT-trap private
  `rm -rf`, at the elapsed deadline—not evidence of a persistent bridge/mount
  deadlock. The faulty `file` double classified all 17 resource/plist files as
  native code as well as the three actual fixture code files: two ~10s verifier
  passes, 40 lipo calls and 53 native Python executions (30 path conversions).
  Fixed only that classification; the real verifier now reports three components,
  protected by a RED→GREEN output assertion. Same diagnostic entry afterward:
  calls **6.969s / 13.062s**, exits 37/1, two three-component passes and 19 Python
  executions. The runner watchdog remains exactly 25s; no skip, deadline increase
  or success-on-timeout. No process-ownership mechanism changed. No legacy Task 4
  process was inspected/killed by this worker or used to explain this failure.
- **M1:** DMG root/Applications/notice checks and native minimum-OS rejection now
  use explicit runtime failures. Four optimized-Python cases reproduce the former
  bypasses and now fail correctly, including native minos 13.0.
- **M2 evidence annotation only:** original/fresh 955/11 suite success includes
  inherited injected download-error and headless MissingPluginException
  diagnostics; it is not “pristine output” or native-plugin acceptance. No reader/
  network behavior or diagnostic suppression changed.

### Incremental RED/GREEN and logs

Same Python/BASH_EXECUTABLE/environment and log directory as above. No Flutter
process ran alongside these focused/covering runs.

| Command suffix after `python scripts/test_macos_package.py` | Result | Log |
|---|---|---|
| `ShellPipelineTests.test_native_verifier_rejects_wrong_arch_and_broad_internal_permissions` with new count check, before classifier fix | RED: expected 3, actual 20 | `timeout-classification-red.log` |
| Above plus `ShellPipelineTests.test_tampered_mounted_app_and_create_failure_publish_nothing` | GREEN: 2 | `timeout-classification-green.log` |
| `ValidationTests.test_real_directory_scan_error_cannot_bless_partial_snapshot` | RED: incomplete tree accepted; GREEN after onerror | `round1-i1-{red,green}.log` |
| Four `test_optimized_python_still_rejects_*` cases | RED: 4; GREEN: 4 | `round1-m1-{red,green}.log` |
| Three explicit-formal credential/success/failure cases | RED: 6 failing subcases before route restoration | `round1-i2-red.log` |
| `ShellPipelineTests.test_explicit_release_runs_formal_gates_and_never_replaces_outputs` | GREEN: 1, including repeated publication | `round1-i2-formal-success-green.log` |
| No suffix: complete package suite | **GREEN: 26, 131.665s, exit 0** | `round1-package-green.log` |

Diagnostic runner: `.dart_tool/codex-macos-followup/task-5/diagnose-package-timeout.py`;
baseline success/timeout are in `timeout-diagnostic-run{1,2}.log`, with captured
`timeout-diagnostic-2-2.{json,stdout.log,stderr.log}`. Fixed trace/timing/output:
`timeout-diagnostic-fix1.log` and `timeout-diagnostic-fix1-{1,2}.*`.
Controller's `final-controller-test_macos_package.log` and
`final-controller-package-isolated.log` remain untouched, visible failures.
Formal fixture development also exposed unavailable Cygwin `shasum` and native
Python text stdout CRLF. Its controlled replacement hashes actual FS bytes with
stdlib Python and emits binary LF, not a canned digest; production checksum/
no-clobber checks were not relaxed (`round1-i2-checksum-adapter-red.log`).

Additional covering commands:

- `python scripts/test_macos_reader_performance_pipeline.py`: **6 / 42.119s**,
  exit 0, all owned app/helpers dead; `round1-lifecycle-green.log`.
- `python scripts/test_macos_native_pipeline.py`: **19 / 15.184s**, exit 0;
  `round1-native-pipeline-green.log`.
- All shell scripts through CRLF-normalized `/bin/bash -n`: exit 0,
  `round1-shell-syntax.log`; actionlint `-shellcheck=` on unchanged macOS CI:
  exit 0, `round1-actionlint.log`; staged `git diff --check`: exit 0,
  `round1-diff-check.log`.
- No Dart/Swift/dependency changes; per controller instruction, no redundant
  full Flutter rerun. Its fresh **955 passed / 11 opt-in skips + clean analyze**
  remains source-applicable, not proof of native/platform/physical acceptance.

Round 1 scoped implementation and portable gates converge and are submitted for
independent review. No credentials, network/CI/push/PR/merge or real user-data
operations occurred. Actual hosted Mac native/platform/seven-scenario AOT,
mounted final DMG/download, stock Bash 3.2 execution and physical gates remain
controller-owned; no formal certificate/notarization success is claimed.
