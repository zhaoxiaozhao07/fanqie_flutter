# macOS Sync Optimizations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Follow all five approved macOS sync items in order and produce a verified current-version self-use DMG without changing the main checkout or existing releases.

**Architecture:** Reuse the shared Dart desktop abstractions and the existing macOS native bridge. Native Swift owns sandbox directory authority and atomic file publication; a bounded native scroll classifier distinguishes discrete mouse wheels from precise/unknown scroll input. Packaging and provenance validation use portable Python with independent macOS signature and mounted-DMG checks.

**Tech Stack:** Flutter 3.47.9 / Dart 3.13.7, Swift/AppKit/Darwin, XCTest, Python standard library, Bash, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-11-22-macos-sync-design.md`

## Global Constraints

- Base commit: `114216f94c646d0191da5df858c58537f3624062`.
- Work only in the managed worktree on `codex/macos-sync-optimizations`.
- Application version remains `3.3.6+342`; minimum macOS build target remains `12.0`; architecture remains `arm64`.
- Flutter SDK is pinned to `3.47.9`, Dart to `3.13.7`; do not change pubspec dependencies or lockfile.
- Do not change Android/Windows defaults, old release assets, Android workflow, or Windows workflow.
- Preserve main-only public macOS prerelease publishing and self-use ad-hoc signing; isolated branch verification uses `publish=false`.
- No automatic main merge/push; no Developer ID/notarization fallback or misleading formal-release claims.
- Write behavioral tests before production changes. Keep native test hosts and export operations isolated from real user data.
- Do not claim hardware, foreground display FPS, real audio, macOS 12, or installation/upgrade acceptance from headless/Windows tests.
- Implement one task at a time; independent reviews follow each task.

---

### Task 1: Establish an executable macOS verification baseline

**Files:**
- Create: `scripts/test_macos_native.sh`
- Create: `scripts/test_macos_native_pipeline.py`
- Modify: `scripts/test_macos_platform.sh`
- Modify: `.github/workflows/macos-internal.yml`
- Modify: `docs/MACOS_CLIENT_VERIFICATION.md`

**Interfaces:**
- Consumes: existing `sign_macos_internal.sh APP debug` and native `Runner` XCTest scheme.
- Produces: `scripts/test_macos_native.sh`, a fail-closed arm64 production-Debug build/sign/XCTest gate reusable by CI and the platform integration script.
- Produces: CI logs for analyze, offline Dart tests, native XCTest and production Release. No publishing policy change.

- [ ] Write controlled-command behavioral tests: copy the real script into an isolated fixture; fake only `uname`, Flutter, signing and xcodebuild. Assert that native tests build the production target, failures stop subsequent commands, and non-arm64 is rejected.

```python
completed = subprocess.run(["bash", str(script)], env=fixture_env, capture_output=True)
self.assertEqual(completed.returncode, 0)
self.assertIn("--target lib/main.dart", command_log.read_text())
self.assertLess(command_log.read_text().index("flutter build"), command_log.read_text().index("xcodebuild test"))
```

- [ ] Run the test and record its expected failing evidence before creating the gate.
- [ ] Implement the reusable sequence with `set -euo pipefail`, explicit `--no-pub --target lib/main.dart`, internal Debug signing and sequential `xcodebuild test`.

```bash
"$FLUTTER" build macos --debug --no-pub --target lib/main.dart
"$ROOT/scripts/sign_macos_internal.sh" "$APP" debug
xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/macos -parallel-testing-enabled NO
```

- [ ] Reuse the native gate from the existing full platform script, pin the CI SDK, and run mandatory native XCTest before the final production Release build.
- [ ] Retain a way to run full native platform integration without claiming unattended runner coverage of manual save/physical display tests.
- [ ] Run pipeline fixture tests and shell syntax checks; commit only this task's files with `[skip ci]`.
- [ ] Task review; controller runs `publish=false` on the isolated branch and records actual native baseline or actionable failure before final delivery.

### Task 2: Add sandbox-correct uninterrupted macOS download output

**Files:**
- Modify: `lib/services/desktop_download_output.dart`
- Modify: `lib/services/download_service.dart`
- Modify: `lib/widgets/download_dialog.dart`
- Create: `macos/Runner/ReaderDownloadOutput.swift`
- Modify: `macos/Runner/MainFlutterWindow.swift`
- Modify: `macos/Runner.xcodeproj/project.pbxproj`
- Modify: `macos/Runner/DebugProfile.entitlements`
- Modify: `macos/Runner/Release.entitlements`
- Create: `test/macos_download_output_test.dart`
- Modify: `macos/RunnerTests/RunnerTests.swift`

**Interfaces:**
- Consumes: shared `cancelExport` IDs and existing desktop download/export result dictionaries.
- Produces: Mac handlers `getDownloadDirectory`, `pickDownloadDirectory`, `commitDownloadFile`.
- `getDownloadDirectory` / `pickDownloadDirectory` return `{'status':'saved','path':absolutePath}` or `cancelled` / `failed` with a readable error.
- `commitDownloadFile` accepts `id`, `sourcePath`, `fileName`; native Mac resolves its own authorized directory and does not trust the optional Dart `directory` as authorization.
- `DesktopDownloadOutput.resolve()`, `choose()` and `commit(File source, String name, {String? requestId, bool Function()? isCancelled})` retain their signatures.
- Mac persists a security-scoped directory bookmark natively; Windows retains `windows_download_dir`.

- [ ] Write Dart tests for native-resolved Mac output, remembered directory UI, cancellation/failure/malformed replies, no save dialog at download completion, and unchanged Windows routing.

```dart
debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
final result = await DesktopDownloadOutput.commit(source, '书.epub', requestId: 'job-1');
expect(result.status, FileExportStatus.saved);
expect(result.path, endsWith('书 (2).epub'));
```

- [ ] Record expected red evidence against the current Windows-only routing.
- [ ] Write native XCTest first for exact source bytes, numeric collisions, atomic non-overwrite races, invalid/link inputs, early/copy cancellation and committed-success semantics.

```swift
let first = try writer.commit(source, named: "书.epub", in: output)
let second = try writer.commit(source, named: "书.epub", in: output)
XCTAssertEqual(first.lastPathComponent, "书.epub")
XCTAssertEqual(second.lastPathComponent, "书 (2).epub")
XCTAssertEqual(try Data(contentsOf: first), originalBytes)
```

- [ ] Implement narrow Downloads sandbox permissions, a native bookmark-backed directory store, and serialized cancellation-aware background copying. Publish with an atomic no-replace operation (Darwin exclusive rename); never pre-delete an existing target, never leave a partial committed file, and fail clearly if a volume cannot guarantee the operation.
- [ ] Generalize the desktop UI and service dispatch without changing Windows path formatting/preferences or Android methods. Mac never recreates an unauthorized external directory in Dart.
- [ ] Run Mac output Dart tests and existing download/Windows regressions. Register the Swift source in Xcode; native tests must run on the final macOS CI.
- [ ] Commit this task's files and obtain a task-scoped review.

### Task 3: Classify native Mac scroll input before enabling repeat

**Files:**
- Create: `lib/services/reader_scroll_input.dart`
- Create: `macos/Runner/ReaderScrollInput.swift`
- Modify: `macos/Runner/MainFlutterWindow.swift`
- Modify: `macos/Runner.xcodeproj/project.pbxproj`
- Modify: `lib/services/reader_system_service.dart`
- Modify: `lib/widgets/reader_page_view.dart`
- Modify: `test/reader_wheel_interaction_test.dart`
- Create: `test/reader_scroll_input_test.dart`
- Modify: `macos/RunnerTests/RunnerTests.swift`

**Interfaces:**
- Consumes: existing native MethodChannel event handler and `PointerScrollEvent.timeStamp`.
- Produces: native `onReaderScrollInput` notification with `timestampMicros` and `precise` boolean before forwarding a scroll event to Flutter.
- Produces: bounded `ReaderScrollInput` classification lookup by source timestamp. Precise, unknown, stale or unmatched events never enable Mac repeating.
- Existing Windows wheel acceptance, selection/nested-scroll priorities and commit ownership remain unchanged.

- [ ] Write source-time matching tests with literal timestamps, bounded eviction, invalid inputs, precise/unknown fail-closed behavior and no classification reuse across platforms.
- [ ] Add Mac wheel cases for sustained discrete notches, explicit reversal, delayed dispatch, pending commit and unavailable chapters; preserve all existing precision/momentum/nested-scroll tests.

```dart
ReaderScrollInput.record({'timestampMicros': 1000000, 'precise': false});
await wheel(tester, const Offset(0, 120), timeStamp: const Duration(seconds: 1));
// Later complete notches after animation may turn, unlike precise/unknown input.
expect(reader.settled, [2, 3]);
```

- [ ] Record red evidence before implementing the classifier.
- [ ] Implement a local AppKit scroll event monitor, scoped to the main reader window, forwarding native precision and timestamp only. Remove the monitor when its owner is released.
- [ ] Route the notification through the existing shared event handler and replace Windows-only discrete-mouse gating with Windows-or-explicitly-classified-Mac gating.
- [ ] Use native CGEvent/NSEvent XCTest to distinguish pixel/precise versus line/discrete events; retain source-time fail-closed behavior if matching cannot be demonstrated.
- [ ] Run wheel/classifier plus desktop interaction regressions; commit and obtain task review.

### Task 4: Extend Mac-specific font, Retina and AOT evidence

**Files:**
- Modify: `test/reader_font_consistency_test.dart`
- Modify: `test/reader_page_window_test.dart`
- Modify: `test/windows_reading_optimization_test.dart` or create a focused `test/macos_reading_optimization_test.dart`
- Modify: `integration_test/macos_reader_performance.dart`
- Modify: `scripts/test_macos_reader_performance.sh`
- Modify: `docs/MACOS_CLIENT_VERIFICATION.md`

**Interfaces:**
- Consumes: the existing shared body/title/preview style and page engine; Task 3 scroll classification when testing discrete input.
- Produces: Mac and Windows coverage with independently derived platform font expectations.
- Produces: seven measured AOT scenarios (five single-column effects, actual double-column cover, actual cross-chapter cover), source anchor checks, bounded memory, cold-layout measurements and foreground-at-start/end metadata.
- Preserve helper APIs imported by the Windows performance entry point.

- [ ] Add Mac cases to existing behavioral regressions with literal expected font families/fallbacks (`Roboto` for system, `sans-serif` for generic, bundled/imported families unchanged), five page effects, mounted page reuse and 2× DPI double-to-single anchor retention.

```dart
tester.view.devicePixelRatio = 2;
expect(find.byKey(const ValueKey('reader-double-column-spread')), findsOneWidget);
tester.view.physicalSize = const Size(1480, 1280);
await tester.pumpAndSettle();
expect(address.layout.pageFor(originalPosition), address.pageIndex);
```

- [ ] Run these tests and investigate any real regression without changing Mac fonts to Windows-specific faces.
- [ ] Extend the existing Mac benchmark fixtures rather than copying unrelated Windows runner logic; independently assert actual column count and actual completed chapter transitions.
- [ ] Add foreground-state reporting/optional strict foreground gate, long-paragraph preservation and meaningful timing/memory budgets. Do not claim physical input latency or foreground FPS.
- [ ] Run Dart regressions and analyze; cloud AOT/native evidence is obtained during final CI. Record hardware-only limitations explicitly.
- [ ] Commit and obtain task review.

### Task 5: Harden package and release provenance, then verify the final DMG

**Files:**
- Create: `scripts/macos_release_validation.py`
- Create: `scripts/test_macos_package.py`
- Create: `scripts/verify_macos_dmg.sh`
- Modify: `scripts/verify_macos_bundle.sh`
- Modify: `scripts/package_macos.sh`
- Modify: `.github/workflows/macos-internal.yml`
- Modify: `docs/MACOS_INTERNAL_RELEASE.md`
- Modify: `docs/MACOS_CLIENT_VERIFICATION.md`

**Interfaces:**
- Consumes: current `3.3.6+342` production Mac app, Flutter machine JSON after SDK bootstrap, trigger SHA/ref/run/attempt and Task 1 test logs.
- Produces: build-qualified `fanqie-v3.3.6-342-macos-arm64-internal.dmg`, same-name `.sha256`, and `build-info.json`.
- Portable Python checks full plist version/build, production resource layout/native-assets, bundle snapshot digests, artifact digest/size and provenance equality.
- The mounted-DMG gate independently re-runs bundle checks and compares the embedded app to the pre-image snapshot.
- Existing main-only publishing remains. Publication validates downloaded provenance and verifies remote tag/asset hashes after upload; it never overwrites existing tags/assets.

- [ ] Write real filesystem fixture tests for wrong build/entry point, missing/empty fonts/data/ICU/native-assets, malformed native loading modes, traversal/escaping paths and tampered snapshots.
- [ ] Write artifact/provenance tests for wrong SHA/ref/run/attempt/version/SDK/digests/sizes, missing/extra files, checksum path traversal and repeated local output publication.

```python
with self.assertRaises(ValidationError):
    validate_provenance(info, trigger={**trigger, "source_commit": "b" * 40})
with self.assertRaises(FileExistsError):
    publish_local_verified_artifacts(stage, output)
self.assertEqual(old_image.read_bytes(), b"keep-old-package")
```

- [ ] Run red tests against missing validators/current unsafe behavior, then implement focused Python validation commands. Derive native-assets path/loading rules from actual Mac AOT layout; do not copy Windows DLL rules.
- [ ] Check full plist version/build in the shell verifier and native narrow permissions. Snapshot the verified staged bundle, create a private image without `-ov`, mount read-only, verify production contents and snapshot, then publish outputs without replacing existing files. Clean only this operation's private paths/files.
- [ ] Extend CI provenance creation to bind full version, build, source/ref, SDK and run identity; run portable validation tests, native tests and mounted-DMG checks before artifact upload.
- [ ] Validate provenance on the Linux publish job; verify the remote tag points to source SHA and the uploaded file sizes/digests match local verified files. Retain `--prerelease --latest=false` and main-only policy.
- [ ] Run Python tests, all Flutter tests, analyze, shell syntax, diff checks, task review and whole-branch review. Push only the isolated branch, run macOS Actions with `publish=false`, follow it to success/failure in this chat, and inspect/download the verified artifact.
- [ ] Record the final artifact/source/test evidence and hardware-only outstanding checks. Do not merge main, create a public prerelease, archive the requested worktree or claim incomplete physical acceptance as complete.
