#!/usr/bin/env python3
"""Portable real-FS/CLI and controlled-command packaging regressions.

Command doubles exercise orchestration, NOT Mach-O/signature/DMG acceptance.
All files, mounts and outputs live in a test-owned temporary checkout.
"""
import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest import mock

try:
    import macos_release_validation as v
except ModuleNotFoundError:
    v = None

ROOT = Path(__file__).resolve().parents[1]
NAME = "fanqie-v3.3.6-342-macos-arm64-internal.dmg"
FORMAL_NAME = "fanqie-v3.3.6-342-macos-arm64.dmg"
ASSETS = "Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets"
ICU = "Contents/Frameworks/FlutterMacOS.framework/Versions/A/Resources/icudtl.dat"
FONT_MANIFEST = [
    {"family": family, "fonts": [{"asset": asset}]} for family, asset in [
        ("ReaderKaiTi", "assets/fonts/LXGWWenKaiLite-Regular.ttf"),
        ("ReaderSongTi", "assets/fonts/ZCOOLXiaoWei-Regular.ttf"),
        ("MaterialIcons", "fonts/MaterialIcons-Regular.otf"),
        ("packages/cupertino_icons/CupertinoIcons", "packages/cupertino_icons/assets/CupertinoIcons.ttf"),
    ]
]
RESOURCE_FILES = [
    "AssetManifest.bin", "NOTICES.Z", "assets/icons/fanqie.png",
    "assets/fonts/LXGW-OFL.txt", "assets/fonts/ZCOOL-OFL.txt",
    "assets/data/font_map.json", "assets/data/reader_script_map.json",
    "assets/data/charset.json", "assets/data/lib_font_map.json",
] + [f["fonts"][0]["asset"] for f in FONT_MANIFEST]


def write(path, data=b"fixture"):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data.encode() if isinstance(data, str) else data)


def bundle(app):
    write(app / "Contents/Info.plist", plistlib.dumps({
        "CFBundleShortVersionString": "3.3.6", "CFBundleVersion": "342",
        "FanqieBuildTarget": "lib/main.dart", "CFBundleIdentifier": "com.fanqie.reader.macos",
        "CFBundleExecutable": "FanqieReader", "LSMinimumSystemVersion": "12.0",
    }))
    write(app / "Contents/MacOS/FanqieReader")
    (app / "Contents/MacOS/FanqieReader").chmod(0o755)
    for framework in ("App", "FlutterMacOS"):
        base = app / f"Contents/Frameworks/{framework}.framework"
        write(base / f"Versions/A/{framework}")
        (base / "Versions/A/Resources").mkdir(exist_ok=True)
        (base / "Versions/Current").symlink_to("A", target_is_directory=True)
        (base / "Resources").symlink_to(Path("Versions/Current/Resources"), target_is_directory=True)
        (base / framework).symlink_to(Path(f"Versions/Current/{framework}"))
    for name in RESOURCE_FILES:
        write(app / ASSETS / name, '["first","second"]' if name.endswith("/charset.json")
              else '{"fixture":"value"}' if name.endswith(".json") else b"resource")
    write(app / ASSETS / "FontManifest.json", json.dumps(FONT_MANIFEST))
    write(app / ASSETS / "NativeAssetsManifest.json",
          '{"format-version":[1,0,0],"native-assets":{}}')
    write(app / ICU)


def trigger():
    return {
        "source_commit": "a" * 40, "source_ref": "refs/heads/codex/macos-sync-optimizations",
        "workflow_run": "https://github.com/owner/repo/actions/runs/123",
        "run_id": "123", "run_attempt": "1",
    }


def context():
    return trigger() | {
        "flutter": {"frameworkVersion": "3.47.9", "dartSdkVersion": "3.13.7",
                    "frameworkRevision": "b" * 40},
        "xcode": "Xcode fixture",
        "test_logs": {"native-xctest.log": {
            "sha256": hashlib.sha256(b"native gate passed\n").hexdigest(), "size": 19}},
    }


class BundleFixture:
    def setUp(self):
        self.assertIsNotNone(v, "Task5 portable validators are not implemented")
        self.tmp = tempfile.TemporaryDirectory(prefix="macos packaging ")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve(strict=True)
        self.app = self.root / "production.app"
        bundle(self.app)


class ValidationTests(BundleFixture, unittest.TestCase):
    def test_fixture_temp_parent_alias_preserves_real_cleanup_ownership(self):
        with tempfile.TemporaryDirectory(prefix="macos temp-parent alias ") as temporary:
            parent = Path(temporary)
            real = parent / "real"
            real.mkdir()
            alias = parent / "alias"
            alias.symlink_to(real, target_is_directory=True)
            owned = ValidationTests("test_observed_versioned_aot_layout_and_empty_native_mapping")
            try:
                with mock.patch.object(tempfile, "tempdir", str(alias)):
                    owned.setUp()
                content = owned.root / "image-content"
                write(content / "owned-bytes", b"owned")
                self.assertEqual((content / "owned-bytes").read_bytes(), b"owned")
                self.assertTrue(content.resolve().is_relative_to(owned.root))
            finally:
                owned.doCleanups()

    def stage(self):
        stage = self.root / "stage"
        stage.mkdir()
        write(stage / NAME, b"verified image")
        v.create_artifacts(stage, v.snapshot_bundle(self.app), context())
        return stage

    def test_observed_versioned_aot_layout_and_empty_native_mapping(self):
        v.validate_bundle(self.app)
        snap = v.snapshot_bundle(self.app)
        self.assertEqual(snap["Contents/Frameworks/App.framework/Resources"]["target"],
                         "Versions/Current/Resources")
        self.assertEqual(snap[f"{ASSETS}/AssetManifest.bin"]["sha256"],
                         hashlib.sha256(b"resource").hexdigest())

    def test_wrong_version_build_entrypoint_identifier_minimum_executable(self):
        path = self.app / "Contents/Info.plist"
        good = plistlib.loads(path.read_bytes())
        for key, bad in [
            ("CFBundleVersion", "341"), ("CFBundleVersion", 342),
            ("CFBundleShortVersionString", "3.3.5"),
            ("FanqieBuildTarget", "integration_test/macos_reader_performance.dart"),
            ("CFBundleIdentifier", "other"), ("LSMinimumSystemVersion", "13.0"),
            ("CFBundleExecutable", "../escape"),
        ]:
            with self.subTest(key=key, bad=bad):
                path.write_bytes(plistlib.dumps(good | {key: bad}))
                with self.assertRaises(v.ValidationError):
                    v.validate_bundle(self.app)
        path.write_bytes(plistlib.dumps(good))

    def test_missing_and_empty_production_resources(self):
        paths = [self.app / ASSETS / n for n in
                 RESOURCE_FILES + ["FontManifest.json", "NativeAssetsManifest.json"]]
        paths += [self.app / ICU, self.app / "Contents/MacOS/FanqieReader"]
        for path in paths:
            old = path.read_bytes()
            for missing in (True, False):
                with self.subTest(path=path, missing=missing):
                    if missing:
                        path.unlink()
                    else:
                        path.write_bytes(b"")
                    with self.assertRaises(v.ValidationError):
                        v.validate_bundle(self.app)
                    write(path, old)

    def test_font_manifest_mapping_and_escaping_paths(self):
        path = self.app / ASSETS / "FontManifest.json"
        for bad in ("../outside.ttf", "/tmp/font.ttf", "assets\\font.ttf", "missing.ttf"):
            fonts = copy.deepcopy(FONT_MANIFEST)
            fonts[0]["fonts"][0]["asset"] = bad
            path.write_text(json.dumps(fonts))
            with self.assertRaises(v.ValidationError):
                v.validate_bundle(self.app)

    def test_data_json_root_boundary_includes_charset_list_and_rejects_empty(self):
        v.validate_bundle(self.app)
        for name in ("font_map", "lib_font_map", "reader_script_map", "charset"):
            path = self.app / ASSETS / f"assets/data/{name}.json"
            old = path.read_bytes()
            for bad in ("{}", "[]", "null", '"scalar"', "{malformed"):
                with self.subTest(name=name, bad=bad):
                    path.write_text(bad)
                    with self.assertRaises(v.ValidationError):
                        v.validate_bundle(self.app)
            path.write_bytes(old)

    def test_mac_loading_modes_and_bundled_framework_not_windows_basename(self):
        framework = self.app / "Contents/Frameworks/ffi.framework"
        write(framework / "Versions/A/ffi")
        (framework / "ffi").symlink_to(Path("Versions/A/ffi"))
        path = self.app / ASSETS / "NativeAssetsManifest.json"
        for loading in (["absolute", "ffi.framework/ffi"], ["system", "/usr/lib/libSystem.B.dylib"],
                        ["system", "/System/Library/Frameworks/Security.framework/Security"],
                        ["executable"], ["process"]):
            path.write_text(json.dumps({"format-version": [1, 0, 0],
                                       "native-assets": {"macos_arm64": {"package:p/a": loading}}}))
            v.validate_bundle(self.app)
        for loading in ([], ["relative", "ffi.dll"], ["absolute", "ffi.dll"],
                        ["absolute", "/tmp/ffi.dylib"], ["absolute", "../ffi.framework/ffi"],
                        ["absolute", "missing.framework/missing"], ["executable", "extra"],
                        ["process", 4], ["system", "/tmp/evil.dylib"],
                        ["system", "/usr/lib/../tmp/evil"], "process"):
            with self.subTest(loading=loading):
                path.write_text(json.dumps({"format-version": [1, 0, 0],
                                           "native-assets": {"macos_arm64": {"p": loading}}}))
                with self.assertRaises(v.ValidationError):
                    v.validate_bundle(self.app)
        for bad in ({"format-version": [2, 0, 0], "native-assets": {}},
                    {"format-version": [1, 0, 0], "native-assets": []},
                    {"format-version": [1, 0, 0], "native-assets": {"windows_x64": {}}},
                    {"format-version": [1, 0, 0], "native-assets": {"macos_arm64": []}}):
            path.write_text(json.dumps(bad))
            with self.assertRaises(v.ValidationError):
                v.validate_bundle(self.app)

    def test_external_dangling_symlinks_and_changed_snapshots(self):
        snap = v.snapshot_bundle(self.app)
        path = self.app / ASSETS / "AssetManifest.bin"
        path.write_bytes(b"tampered")
        with self.assertRaises(v.ValidationError):
            v.compare_snapshot(self.app, snap)
        for target in (self.root / "outside", self.root / "absent"):
            write(self.root / "outside")
            path.unlink()
            path.symlink_to(target)
            with self.assertRaises(v.ValidationError):
                v.snapshot_bundle(self.app)
        path.unlink()
        write(path)
        with self.assertRaises(v.ValidationError):
            v.compare_snapshot(self.app, {**snap, "../outside": {"type": "file"}})

    def test_real_directory_scan_error_cannot_bless_partial_snapshot(self):
        directory = self.app / "Contents/extra-real-content"
        write(directory / "must-not-be-omitted.txt", b"real fixture bytes")
        expected = v.snapshot_bundle(self.app)
        self.assertIn("Contents/extra-real-content/must-not-be-omitted.txt", expected)
        scandir = os.scandir
        for operation in (lambda: v.validate_bundle(self.app),
                          lambda: v.snapshot_bundle(self.app),
                          lambda: v.compare_snapshot(self.app, expected)):
            injected = False

            def scan(path):
                nonlocal injected
                if Path(path) == directory and not injected:
                    injected = True
                    raise PermissionError(13, "single fixture scan boundary denied", str(path))
                return scandir(path)

            with mock.patch.object(v.os, "scandir", side_effect=scan):
                with self.assertRaises(v.ValidationError):
                    operation()
            self.assertTrue(injected, "The real extra directory scan must be reached")
        v.compare_snapshot(self.app, expected)

    def test_real_directory_entry_classification_error_cannot_omit_children(self):
        directory = self.app / "Contents/extra-dir-entry-content"
        write(directory / "must-not-be-omitted.txt", b"real child bytes")
        expected = v.snapshot_bundle(self.app)
        self.assertIn("Contents/extra-dir-entry-content/must-not-be-omitted.txt", expected)
        scandir = os.scandir
        for label, operation in (
            ("snapshot", lambda: v.snapshot_bundle(self.app)),
            ("bundle", lambda: v.validate_bundle(self.app)),
            ("comparison", lambda: v.compare_snapshot(self.app, expected)),
        ):
            with self.subTest(validator=label):
                injected = False

                class FaultEntry:
                    def __init__(self, entry):
                        self.entry = entry

                    def __getattr__(self, name):
                        return getattr(self.entry, name)

                    def is_dir(self, *args, **kwargs):
                        nonlocal injected
                        if not injected:
                            injected = True
                            raise PermissionError(13, "single real entry classification denied", self.entry.path)
                        return self.entry.is_dir(*args, **kwargs)

                class ScanEntries:
                    def __init__(self, stream):
                        self.stream = stream

                    def __enter__(self):
                        self.stream.__enter__()
                        return self

                    def __exit__(self, *args):
                        return self.stream.__exit__(*args)

                    def __iter__(self):
                        return self

                    def __next__(self):
                        entry = next(self.stream)
                        return FaultEntry(entry) if Path(entry.path) == directory else entry

                with mock.patch.object(v.os, "scandir", side_effect=lambda path: ScanEntries(scandir(path))):
                    with self.assertRaises(v.ValidationError) as caught:
                        operation()
                self.assertTrue(injected, "The real directory entry must reach is_dir")
                # Comparison must reject the classification boundary itself,
                # not silently omit the child and only notice digest inequality.
                self.assertIn(directory.name, str(caught.exception))
        v.compare_snapshot(self.app, expected)

    def test_provenance_is_bound_to_trigger_full_version_sdk_and_snapshot(self):
        stage = self.stage()
        info = json.loads((stage / "build-info.json").read_text())
        v.validate_provenance(info, trigger=trigger())
        for key, bad in [
            ("source_commit", "b" * 40), ("source_ref", "refs/heads/main"),
            ("run_id", "124"), ("run_attempt", "2"), ("workflow_run", "https://evil/run"),
            ("version", "3.3.6+341"), ("build", "341"), ("architecture", "x86_64"),
            ("build_target", "test.dart"), ("minimum_macos_target", "13.0"),
            ("signing", "Developer ID"), ("notarized", True), ("build_mode", "Debug"),
            ("bundle_snapshot_sha256", "0" * 64),
            ("flutter", {"frameworkVersion": "3.47.8", "dartSdkVersion": "3.13.7"}),
            ("flutter", {"frameworkVersion": "3.47.9", "dartSdkVersion": "3.13.6"}),
            ("test_logs", {}),
        ]:
            with self.subTest(key=key):
                with self.assertRaises(v.ValidationError):
                    v.validate_provenance(info | {key: bad}, trigger=trigger())
        with self.assertRaises(v.ValidationError):
            v.validate_provenance(info, trigger=trigger() | {"source_commit": "b" * 40})
        altered = copy.deepcopy(info)
        altered["bundle_snapshot"][f"{ASSETS}/AssetManifest.bin"]["size"] += 1
        with self.assertRaises(v.ValidationError):
            v.validate_provenance(altered, trigger=trigger())

    def test_artifact_set_checksums_digests_sizes_and_traversal(self):
        stage = self.stage()
        v.validate_artifacts(stage, trigger())
        image = stage / NAME
        old = image.read_bytes()
        image.write_bytes(b"other image")
        with self.assertRaises(v.ValidationError):
            v.validate_artifacts(stage, trigger())
        image.write_bytes(old)
        info_path = stage / "build-info.json"
        good_info = json.loads(info_path.read_text())
        for key, bad in (("sha256", "0" * 64), ("size", 0), ("size", len(old) + 1)):
            info = copy.deepcopy(good_info)
            info["artifacts"][NAME][key] = bad
            info_path.write_text(json.dumps(info))
            with self.assertRaises(v.ValidationError):
                v.validate_artifacts(stage, trigger())
        info_path.write_text(json.dumps(good_info))
        checksum = stage / f"{NAME}.sha256"
        good = checksum.read_bytes()
        for target in ("../outside.dmg", "/tmp/image.dmg", "other.dmg"):
            content = f"{hashlib.sha256(old).hexdigest()}  {target}\n".encode()
            checksum.write_bytes(content)
            info = copy.deepcopy(good_info)
            info["artifacts"][checksum.name] = {"sha256": hashlib.sha256(content).hexdigest(),
                                                "size": len(content)}
            info_path.write_text(json.dumps(info))
            with self.assertRaises(v.ValidationError):
                v.validate_artifacts(stage, trigger())
        checksum.write_bytes(good)
        info_path.write_text(json.dumps(good_info))
        write(stage / "extra")
        with self.assertRaises(v.ValidationError):
            v.validate_artifacts(stage, trigger())
        (stage / "extra").unlink()
        checksum.unlink()
        with self.assertRaises(v.ValidationError):
            v.validate_artifacts(stage, trigger())

    def test_local_publication_never_replaces_any_existing_output(self):
        stage = self.stage()
        output = self.root / "output"
        v.publish_local_verified_artifacts(stage, output)
        with self.assertRaises(FileExistsError):
            v.publish_local_verified_artifacts(stage, output)
        for existing in (NAME, f"{NAME}.sha256", "build-info.json"):
            out = self.root / existing.replace(".", "_")
            write(out / existing, b"keep-old-package")
            with self.assertRaises(FileExistsError):
                v.publish_local_verified_artifacts(stage, out)
            self.assertEqual((out / existing).read_bytes(), b"keep-old-package")
            self.assertEqual(list(out.iterdir()), [out / existing])

    def test_remote_tag_and_downloaded_assets_are_verified(self):
        stage = self.stage()
        remote = self.root / "downloaded"
        shutil.copytree(stage, remote)
        tag = "macos-internal-v3.3.6-123-1"
        tag_info = {"ref": f"refs/tags/{tag}", "object": {"type": "commit", "sha": "a" * 40}}
        release = {"tag_name": tag, "prerelease": True, "draft": False,
                   "assets": [{"name": p.name, "size": p.stat().st_size} for p in stage.iterdir()]}
        v.validate_remote(stage, remote, trigger(), tag_info, release)
        with self.assertRaises(v.ValidationError):
            v.validate_remote(stage, remote, trigger(),
                              tag_info | {"object": {"type": "commit", "sha": "b" * 40}}, release)
        for bad in (release | {"prerelease": False}, release | {"assets": []}):
            with self.assertRaises(v.ValidationError):
                v.validate_remote(stage, remote, trigger(), tag_info, bad)
        write(remote / NAME, b"tampered upload")
        with self.assertRaises(v.ValidationError):
            v.validate_remote(stage, remote, trigger(), tag_info, release)

    def test_cli_fails_closed_on_bad_bundle_json_and_missing_context(self):
        cli = ROOT / "scripts/macos_release_validation.py"
        result = subprocess.run([sys.executable, str(cli), "bundle", str(self.app)],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        write(self.app / ASSETS / "NativeAssetsManifest.json", "{bad")
        result = subprocess.run([sys.executable, str(cli), "bundle", str(self.app)],
                                capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        env = {k: val for k, val in os.environ.items() if not k.startswith("GITHUB_")}
        result = subprocess.run([sys.executable, str(cli), "context", "--sdk", "missing",
                                 "--native-log", "missing", "--output", str(self.root / "ctx")],
                                env=env, capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)


class ShellPipelineTests(BundleFixture, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.bash = os.environ.get("BASH_EXECUTABLE") or shutil.which("bash")
        self.assertTrue(self.bash, "Bash required; set BASH_EXECUTABLE")
        self.checkout = self.root / "checkout with spaces"
        self.bin = self.checkout / "bin"
        self.bin.mkdir(parents=True)
        scripts = self.checkout / "scripts"
        scripts.mkdir()
        for name in ("package_macos.sh", "verify_macos_dmg.sh",
                     "verify_macos_bundle.sh", "macos_release_validation.py",
                     "package_macos_release.sh"):
            if name == "package_macos_release.sh" and not (ROOT / "scripts" / name).exists():
                continue  # RED fixture for the explicitly restored route.
            path = scripts / name
            write(path, (ROOT / "scripts" / name).read_text(encoding="utf-8"))
            path.chmod(0o755)
        write(self.checkout / "pubspec.yaml", "version: 3.3.6+342\n")
        write(self.checkout / "macos/Runner/Release.entitlements", (ROOT / "macos/Runner/Release.entitlements").read_bytes())
        self.command(scripts / "sign_macos_internal.sh",
                     'printf internal > "$FIXTURE_ROOT/internal-sign-called"')
        self.shell_root = str(self.root)
        if os.name == "nt":
            self.shell_root = subprocess.check_output(
                [self.bash, "-c", 'cygpath -u "$1"', "_", str(self.root)],
                text=True, timeout=5).strip()
        shell_bin = f"{self.shell_root}/checkout with spaces/bin"
        self.env = os.environ.copy()
        for key in ("BASH_ENV", "ENV", "SHELLOPTS", "CDPATH",
                    "MACOS_SIGN_IDENTITY", "MACOS_NOTARY_PROFILE"):
            self.env.pop(key, None)
        self.env.update(PATH=f"{shell_bin}:/usr/bin:/bin", TMPDIR=self.shell_root,
                        FIXTURE_ROOT=self.shell_root, FIXTURE_MOUNT_TAMPER="0",
                        FIXTURE_CREATE_EXIT="0", FIXTURE_ARCH="arm64", FIXTURE_JIT="0",
                        PYTHONUTF8="1",
                        LANG="C.UTF-8" if os.name == "nt" else "en_US.UTF-8",
                        LC_ALL="C.UTF-8" if os.name == "nt" else "en_US.UTF-8",
                        MACOS_RELEASE_CONTEXT=f"{self.shell_root}/context.json")
        write(self.root / "context.json", json.dumps(context()))
        bridge = ""
        if os.name == "nt":
            self.env["CYGWIN"] = "winsymlinks:nativestrict"
            # Boundary adapter only: Windows Python needs native absolute paths.
            bridge = """\
                converted=()
                for arg in "$@"; do
                  if [[ "$arg" == /* ]]; then arg="$(cygpath -w "$arg")"; fi
                  converted+=("$arg")
                done
                set -- "${converted[@]}"
            """
        self.command(self.bin / "python3", textwrap.dedent(bridge) +
                     f'exec "{str(Path(sys.executable)).replace(chr(92), "/")}" "$@"')
        write(self.root / "copy.py", """
import os, pathlib, shutil, sys
source, dest = map(pathlib.Path, sys.argv[1:])
dest.mkdir(parents=True, exist_ok=True)
links = []
directories = [(source, dest)]
for parent, dirs, files in os.walk(source, followlinks=False):
    for name in dirs + files:
        src = pathlib.Path(parent) / name
        dst = dest / src.relative_to(source)
        if src.is_symlink():
            links.append((src, dst, src.is_dir()))
        elif src.is_dir():
            dst.mkdir(exist_ok=True)
            directories.append((src, dst))
        else:
            shutil.copy2(src, dst)
for src, dst, is_dir in links:
    dst.symlink_to(src.readlink(), target_is_directory=is_dir)
for src, dst in reversed(directories):
    shutil.copystat(src, dst)
""")
        if os.name == "nt":
            write(self.root / "link.py", """
from pathlib import Path
import sys
Path(sys.argv[1]).symlink_to(Path('/Applications'), target_is_directory=True)
""")
            self.command(self.bin / "ln",
                         '[[ "$1" == -s && "$2" == /Applications ]]; python3 "$FIXTURE_ROOT/link.py" "$3"')
        self.command(self.bin / "uname", 'echo arm64')
        self.command(self.bin / "file", """
            case "$2" in
              */Contents/MacOS/FanqieReader|*/Contents/Frameworks/App.framework/Versions/A/App|*/Contents/Frameworks/FlutterMacOS.framework/Versions/A/FlutterMacOS)
                echo 'Mach-O 64-bit arm64';;
              *) echo data;;
            esac
        """)
        self.command(self.bin / "lipo", 'echo "$FIXTURE_ARCH"')
        self.command(self.bin / "xcrun", """
            case "$1" in
              vtool) echo "minos ${FIXTURE_MINOS:-12.0}";;
              notarytool)
                [[ "$2" == submit && "$4" == --keychain-profile &&
                   "$5" == "$MACOS_NOTARY_PROFILE" && "$6" == --wait ]] || exit 97
                if [[ "$3" == *.zip ]]; then exit "${FIXTURE_NOTARY_APP_EXIT:-0}"
                else exit "${FIXTURE_NOTARY_DMG_EXIT:-0}"; fi;;
              stapler) exit "${FIXTURE_STAPLER_EXIT:-0}";;
              *) exit 96;;
            esac
        """, record=True)
        entitlements = plistlib.loads((ROOT / "macos/Runner/Release.entitlements").read_bytes())
        write(self.root / "permissions-0.plist", plistlib.dumps(entitlements))
        write(self.root / "permissions-1.plist",
              plistlib.dumps(entitlements | {"com.apple.security.cs.allow-jit": True}))
        self.command(self.bin / "codesign", """
            if [[ "$1" == -d ]]; then
              cat "$FIXTURE_ROOT/permissions-$FIXTURE_JIT.plist"
            elif [[ "$1" == -dv ]]; then
              echo 'Authority=Developer ID Application: FIXTURE ONLY'
              echo 'flags=0x10000(runtime)'
            else
              exit "${FIXTURE_CODESIGN_EXIT:-0}"
            fi
        """, record=True)
        self.command(self.bin / "spctl", """
            if [[ "$3" == open ]]; then exit "${FIXTURE_SPCTL_OPEN_EXIT:-0}"
            else exit "${FIXTURE_SPCTL_EXECUTE_EXIT:-0}"; fi
        """, record=True)
        self.command(self.bin / "ditto", """
            if [[ "$1" == -c ]]; then
              [[ "$2" == -k && "$3" == --keepParent ]] || exit 95
              shift 3
              printf 'fixture zip' > "$2"
            else
              python3 "$FIXTURE_ROOT/copy.py" "$1" "$2"
            fi
        """)
        # macOS shasum is not installed in the controller's Cygwin. Keep actual
        # file hashing in stdlib Python, rather than echoing a canned digest.
        write(self.root / "shasum.py", """
import hashlib, pathlib, sys
path = pathlib.Path(sys.argv[1])
sys.stdout.buffer.write((hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.name + '\\n').encode())
""")
        self.command(self.bin / "shasum",
                     '[[ "$#" == 3 && "$1" == -a && "$2" == 256 ]]; '
                     'python3 "$FIXTURE_ROOT/shasum.py" "$3"')
        self.command(self.bin / "hdiutil", """
            case "$1" in
              create)
                [[ "$FIXTURE_CREATE_EXIT" == 0 ]] || exit "$FIXTURE_CREATE_EXIT"
                shift
                while (( $# )); do
                  case "$1" in
                    -ov) exit 95;;
                    -srcfolder) source="$2"; shift 2;;
                    -volname|-format) shift 2;;
                    *) image="$1"; shift;;
                  esac
                done
                python3 "$FIXTURE_ROOT/copy.py" "$source" "$FIXTURE_ROOT/image-content"
                printf 'verified image' > "$image";;
              verify) [[ -s "$2" ]];;
              attach)
                shift; readonly=0
                while (( $# )); do
                  case "$1" in
                    -readonly) readonly=1; shift;;
                    -mountpoint) mount="$2"; shift 2;;
                    *) shift;;
                  esac
                done
                [[ "$readonly" == 1 ]] || exit 94
                python3 "$FIXTURE_ROOT/copy.py" "$FIXTURE_ROOT/image-content" "$mount"
                if [[ "$FIXTURE_MOUNT_TAMPER" == 1 ]]; then
                  printf tampered > "$mount/番茄Reader.app/Contents/MacOS/FanqieReader"
                fi
                printf attached > "$FIXTURE_ROOT/attached";;
              detach) printf detached > "$FIXTURE_ROOT/detached";;
              *) exit 96;;
            esac
        """)

    @staticmethod
    def command(path, body, *, record=False):
        prefix = ""
        if record:
            prefix = (
                '{ printf "%s" "' + path.name + '"; '
                'for argument in "$@"; do printf "\\t%s" "$argument"; done; '
                'printf "\\n"; } >> "$FIXTURE_ROOT/native-commands.log"\n'
            )
        write(path, "#!/usr/bin/env bash\nset -euo pipefail\n" + prefix + textwrap.dedent(body) + "\n")
        path.chmod(0o755)

    def run_shell(self, name, *args):
        return subprocess.run([self.bash, "--noprofile", "--norc",
                               f"{self.shell_root}/checkout with spaces/scripts/{name}", *args],
                              env=self.env, capture_output=True, text=True,
                              encoding="utf-8", errors="replace", timeout=25)

    def test_package_mount_snapshot_and_no_clobber(self):
        args = (f"{self.shell_root}/production.app", "internal", f"{self.shell_root}/out")
        result = self.run_shell("package_macos.sh", *args)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        v.validate_artifacts(self.root / "out", trigger())
        self.assertTrue((self.root / "detached").exists())
        result = self.run_shell("package_macos.sh", *args)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / "out" / NAME).read_bytes(), b"verified image")
        self.assertFalse(list(self.root.glob("fanqie-package.*")))
        self.assertFalse(list(self.root.glob("fanqie-dmg.*")))

    def test_tampered_mounted_app_and_create_failure_publish_nothing(self):
        args = (f"{self.shell_root}/production.app", "internal", f"{self.shell_root}/out")
        self.env["FIXTURE_CREATE_EXIT"] = "37"
        result = self.run_shell("package_macos.sh", *args)
        self.assertEqual(result.returncode, 37, result.stderr)
        self.assertFalse(list((self.root / "out").glob("*")))
        self.env["FIXTURE_CREATE_EXIT"] = "0"
        self.env["FIXTURE_MOUNT_TAMPER"] = "1"
        result = self.run_shell("package_macos.sh", *args)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.root / "detached").exists())
        self.assertFalse(list((self.root / "out").glob("*")))
        self.assertFalse(list(self.root.glob("fanqie-package.*")))
        self.assertFalse(list(self.root.glob("fanqie-dmg.*")))

    def test_native_verifier_rejects_wrong_arch_and_broad_internal_permissions(self):
        app = f"{self.shell_root}/production.app"
        result = self.run_shell("verify_macos_bundle.sh", app, "internal")
        self.assertEqual(result.returncode, 0, result.stderr)
        # The fixture has three code files; resources must not inflate native
        # checks into dozens of Windows/Cygwin subprocess launches.
        self.assertIn("Verified 3 Mach-O components:", result.stdout)
        self.env["FIXTURE_ARCH"] = "x86_64"
        self.assertNotEqual(self.run_shell("verify_macos_bundle.sh", app, "internal").returncode, 0)
        self.env["FIXTURE_ARCH"] = "arm64"
        self.env["FIXTURE_JIT"] = "1"
        self.assertNotEqual(self.run_shell("verify_macos_bundle.sh", app, "internal").returncode, 0)

    def test_optimized_python_still_rejects_native_minimum_above_12(self):
        self.env.update(PYTHONOPTIMIZE="1", FIXTURE_MINOS="13.0")
        result = self.run_shell("verify_macos_bundle.sh", f"{self.shell_root}/production.app", "internal")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def bad_image_optimized(self, fault):
        content = self.root / "image-content"
        app = content / "番茄Reader.app"
        bundle(app)
        link = content / "Applications"
        link.symlink_to(Path("/not-Applications" if fault == "link" else "/Applications"),
                        target_is_directory=True)
        write(content / "INTERNAL_TESTING.txt", b"" if fault == "notice" else b"internal")
        if fault == "root":
            write(content / "extra-root-file")
        write(self.root / "image.dmg", b"fixture image")
        write(self.root / "snapshot.json", json.dumps(v.snapshot_bundle(app)))
        self.env["PYTHONOPTIMIZE"] = "1"
        result = self.run_shell("verify_macos_dmg.sh", f"{self.shell_root}/image.dmg",
                                f"{self.shell_root}/snapshot.json")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.root / "detached").exists())
        self.assertFalse(list(self.root.glob("fanqie-dmg.*")))

    def test_optimized_python_still_rejects_extra_image_root_file(self):
        self.bad_image_optimized("root")

    def test_optimized_python_still_rejects_wrong_applications_link(self):
        self.bad_image_optimized("link")

    def test_optimized_python_still_rejects_empty_internal_notice(self):
        self.bad_image_optimized("notice")

    def formal_environment(self):
        self.env.pop("MACOS_RELEASE_CONTEXT", None)
        self.env.update(MACOS_SIGN_IDENTITY="Developer ID Application: FIXTURE ONLY",
                        MACOS_NOTARY_PROFILE="fixture-not-a-real-profile")

    def test_explicit_release_requires_credentials_without_internal_fallback(self):
        self.env.pop("MACOS_RELEASE_CONTEXT", None)
        for identity, profile in ((None, None), ("Not Developer ID", "fixture"),
                                  ("Developer ID Application: FIXTURE ONLY", None)):
            for key, value in (("MACOS_SIGN_IDENTITY", identity), ("MACOS_NOTARY_PROFILE", profile)):
                self.env.pop(key, None)
                if value is not None:
                    self.env[key] = value
            result = self.run_shell("package_macos.sh", f"{self.shell_root}/production.app",
                                    "release", f"{self.shell_root}/formal-out")
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(list((self.root / "formal-out").glob("*")))
            self.assertFalse((self.root / "internal-sign-called").exists())
            self.assertFalse((self.root / "native-commands.log").exists())

    def test_explicit_release_runs_formal_gates_and_never_replaces_outputs(self):
        self.formal_environment()
        args = (f"{self.shell_root}/production.app", "release", f"{self.shell_root}/formal-out")
        result = self.run_shell("package_macos.sh", *args)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        out = self.root / "formal-out"
        self.assertEqual({p.name for p in out.iterdir()}, {FORMAL_NAME, f"{FORMAL_NAME}.sha256"})
        self.assertEqual((out / f"{FORMAL_NAME}.sha256").read_bytes(),
                         f"{hashlib.sha256(b'verified image').hexdigest()}  {FORMAL_NAME}\n".encode())
        self.assertFalse((self.root / "internal-sign-called").exists())
        self.assertFalse((self.root / "image-content/INTERNAL_TESTING.txt").exists())
        commands = [line.split("\t") for line in (self.root / "native-commands.log").read_text().splitlines()]
        signatures = [c for c in commands if c[:2] == ["codesign", "--force"]]
        self.assertEqual(len(signatures), 7, "Three leaves, two frameworks, app and DMG must be signed")
        self.assertTrue(all(c[c.index("--sign") + 1] == "Developer ID Application: FIXTURE ONLY"
                            for c in signatures))
        submits = [c for c in commands if c[:3] == ["xcrun", "notarytool", "submit"]]
        self.assertEqual(len(submits), 2)
        self.assertTrue(submits[0][3].endswith(".zip"))
        self.assertTrue(submits[1][3].endswith(".dmg"))
        self.assertTrue(all(c[-3:] == ["--keychain-profile", "fixture-not-a-real-profile", "--wait"]
                            for c in submits))
        self.assertEqual({c[3] for c in commands if c[:3] == ["spctl", "--assess", "--type"]},
                         {"execute", "open"})
        self.assertTrue(any(c[:3] == ["xcrun", "stapler", "validate"] and c[-1].endswith(".dmg")
                            for c in commands))
        before = {p.name: p.read_bytes() for p in out.iterdir()}
        result = self.run_shell("package_macos.sh", *args)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual({p.name: p.read_bytes() for p in out.iterdir()}, before)
        self.assertFalse(list(self.root.glob("fanqie-package.*")))
        self.assertFalse(list(self.root.glob("fanqie-dmg.*")))

    def test_formal_gate_failures_publish_nothing_and_never_fall_back(self):
        self.formal_environment()
        for key, code in (("FIXTURE_CODESIGN_EXIT", 36), ("FIXTURE_NOTARY_APP_EXIT", 37),
                          ("FIXTURE_NOTARY_DMG_EXIT", 38), ("FIXTURE_STAPLER_EXIT", 39),
                          ("FIXTURE_SPCTL_OPEN_EXIT", 40)):
            with self.subTest(gate=key):
                content = self.root / "image-content"
                if content.exists():
                    self.assertTrue(content.resolve().is_relative_to(self.root))
                    shutil.rmtree(content)
                self.env[key] = str(code)
                result = self.run_shell("package_macos.sh", f"{self.shell_root}/production.app",
                                        "release", f"{self.shell_root}/formal-out")
                self.assertEqual(result.returncode, code, result.stdout + result.stderr)
                self.env.pop(key)
                self.assertFalse(list((self.root / "formal-out").glob("*")))
                self.assertFalse((self.root / "internal-sign-called").exists())
                self.assertFalse(list(self.root.glob("fanqie-package.*")))
                self.assertFalse(list(self.root.glob("fanqie-dmg.*")))


    def prepare_publish(self):
        stage = self.checkout / "dist/macos"
        stage.mkdir(parents=True)
        write(stage / NAME, b"verified image")
        ctx = context() | {"source_ref": "refs/heads/main"}
        v.create_artifacts(stage, v.snapshot_bundle(self.app), ctx)
        shutil.copytree(stage, self.root / "remote-source")
        tag = "macos-internal-v3.3.6-123-1"
        write(self.root / "tag.json", json.dumps({
            "ref": f"refs/tags/{tag}", "object": {"type": "commit", "sha": "a" * 40, "url": "fixture"}}))
        write(self.root / "release.json", json.dumps({
            "tag_name": tag, "prerelease": True, "draft": False,
            "assets": [{"name": p.name, "size": p.stat().st_size} for p in stage.iterdir()]}))
        write(self.root / "refs.json", "[]")
        self.env.update(GITHUB_SHA="a" * 40, GITHUB_REF="refs/heads/main",
                        GITHUB_RUN_ID="123", GITHUB_RUN_ATTEMPT="1", GITHUB_RUN_NUMBER="1",
                        GITHUB_SERVER_URL="https://github.com", GITHUB_REPOSITORY="owner/repo",
                        GITHUB_STEP_SUMMARY=f"{self.shell_root}/summary",
                        GH_TOKEN="fixture-not-a-token", VERSION="3.3.6", FULL_VERSION="3.3.6+342",
                        BUILD_NUMBER="342")
        self.command(self.bin / "gh", """
            if [[ "$1" == api ]]; then
              case "$2" in
                *matching-refs*) cat "$FIXTURE_ROOT/refs.json";;
                *git/ref/*) cat "$FIXTURE_ROOT/tag.json";;
                *releases/tags/*) cat "$FIXTURE_ROOT/release.json";;
                *) exit 97;;
              esac
            elif [[ "$1" == release && "$2" == create ]]; then
              printf created > "$FIXTURE_ROOT/release-created"
            elif [[ "$1" == release && "$2" == download ]]; then
              while (( $# )); do
                if [[ "$1" == --dir ]]; then dest="$2"; break; fi
                shift
              done
              python3 "$FIXTURE_ROOT/copy.py" "$FIXTURE_ROOT/remote-source" "$dest"
            else exit 98; fi
        """, record=True)
        # Execute the real publication block, not source-string assertions.
        lines = (ROOT / ".github/workflows/macos-internal.yml").read_text(encoding="utf-8").splitlines()
        start = lines.index("      - name: 创建 macOS 预发布版本（不覆盖既有标签或附件）")
        run = lines.index("        run: |", start)
        body = []
        for line in lines[run + 1:]:
            if line.strip() and not line.startswith("          "):
                break
            body.append(line[10:])
        script = self.checkout / "scripts/publish-fixture.sh"
        write(script, "#!/usr/bin/env bash\n" + "\n".join(body) + "\n")
        return stage

    def run_publish(self):
        self.publish_run = getattr(self, "publish_run", 0) + 1
        logs = (ROOT / "build/macos/ci-logs/package-fragments" if
                os.environ.get("GITHUB_ACTIONS") == "true" else
                ROOT / ".dart_tool/codex-macos-followup/task-5/round3-publish-fragments")
        logs.mkdir(parents=True, exist_ok=True)
        prefix = logs / f"{self._testMethodName}-{self.publish_run}"
        env = self.env | {"PS4": "+fixture:${BASH_VERSION}:${SECONDS}:${LINENO}: "}
        script = self.checkout / "scripts/publish-fixture.sh"
        prefix.with_suffix(".script.sh").write_bytes(script.read_bytes())
        prefix.with_suffix(".fake-gh.sh").write_bytes((self.bin / "gh").read_bytes())
        prefix.with_suffix(".refs.json").write_bytes((self.root / "refs.json").read_bytes())
        result = subprocess.run(
            [self.bash, "--noprofile", "--norc", "-x",
             f"{self.shell_root}/checkout with spaces/scripts/publish-fixture.sh"],
            cwd=self.checkout, env=env, capture_output=True, text=True,
            encoding="utf-8", errors="replace", timeout=25)
        prefix.with_suffix(".stdout.log").write_text(result.stdout, encoding="utf-8")
        prefix.with_suffix(".stderr.log").write_text(result.stderr, encoding="utf-8")
        calls = self.root / "native-commands.log"
        prefix.with_suffix(".gh-calls.log").write_bytes(calls.read_bytes() if calls.exists() else b"")
        prefix.with_suffix(".execution.json").write_text(json.dumps({
            "command": result.args, "exit": result.returncode,
            "fixture_root": str(self.root), "canonical_root": str(self.root.resolve()),
            "cwd": str(self.checkout), "release_created": (self.root / "release-created").exists(),
            # Only fixture-selected identity/environment fields; no real tokens.
            "env": {key: env.get(key) for key in (
                "GITHUB_ACTIONS", "GITHUB_SHA", "GITHUB_REF", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT",
                "GITHUB_REPOSITORY", "VERSION", "BUILD_NUMBER", "FULL_VERSION", "FIXTURE_ROOT", "PATH",
                "BASH_ENV", "SHELLOPTS", "BASHOPTS", "POSIXLY_CORRECT")},
        }, indent=2), encoding="utf-8")
        self.publish_diagnostic = f"Captured fragment/gh/env/stdout/stderr: {prefix}"
        return result

    def test_real_publish_block_verifies_build_qualified_remote_bytes(self):
        self.prepare_publish()
        result = self.run_publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.root / "release-created").exists(),
                        result.stdout + result.stderr + self.publish_diagnostic)
        self.assertIn("Verified remote", result.stdout, self.publish_diagnostic)
        commands = [line.split("\t") for line in
                    (self.root / "native-commands.log").read_text(encoding="utf-8").splitlines()]
        creates = [command for command in commands if command[:3] == ["gh", "release", "create"]]
        self.assertEqual(len(creates), 1, self.publish_diagnostic)
        self.assertEqual(creates[0][creates[0].index("--title") + 1],
                         "番茄Reader macOS 自用 v3.3.6（构建 1）")

    def test_real_publish_block_rejects_wrong_provenance_before_upload(self):
        stage = self.prepare_publish()
        path = stage / "build-info.json"
        info = json.loads(path.read_text())
        info["source_commit"] = "b" * 40
        path.write_text(json.dumps(info))
        result = self.run_publish()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / "release-created").exists())

    def test_real_publish_block_refuses_existing_tag_and_tampered_upload(self):
        self.prepare_publish()
        write(self.root / "refs.json", '[{"ref":"refs/tags/macos-internal-v3.3.6-123-1"}]')
        result = self.run_publish()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr + self.publish_diagnostic)
        self.assertFalse((self.root / "release-created").exists())
        write(self.root / "refs.json", "[]")
        write(self.root / "remote-source" / NAME, b"bad upload")
        result = self.run_publish()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr + self.publish_diagnostic)
        self.assertTrue((self.root / "release-created").exists(), result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
