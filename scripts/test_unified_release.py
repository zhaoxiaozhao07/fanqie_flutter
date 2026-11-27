#!/usr/bin/env python3
"""Real-file release fixtures and a controlled GitHub API, not device tests."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

from release_identity import read_identity, repository_identity
from test_macos_package import bundle, context
import macos_release_validation as mac

try:
    import unified_release as release
except ModuleNotFoundError:
    release = None


class FakeGitHub:
    def __init__(self):
        self.calls = []
        self.refs = []
        self.drafts = []
        self.current = None
        self.fail_upload = False
        self.fail_absence = False
        self.corrupt_digest = False
        self.published = False
        self.tag_objects = {}

    def request(self, method, path, *, body=None, file=None, expected=200):
        self.calls.append((method, path, body))
        if self.fail_absence and "/releases/tags/" in path:
            raise RuntimeError("HTTP 403 is not absence")
        if method == "GET" and "/git/matching-refs/" in path:
            return copy.deepcopy(self.refs)
        if method == "GET" and "/releases/tags/" in path:
            if expected != 404:
                raise AssertionError("Only a genuine 404 proves absence")
            return None
        if method == "GET" and "/releases?" in path:
            return copy.deepcopy(self.drafts)
        if method == "POST" and path.endswith("/git/refs"):
            self.refs = [{"ref": body["ref"], "object": {
                "type": "commit", "sha": body["sha"],
            }}]
            return self.refs[0]
        if method == "POST" and path.endswith("/releases"):
            self.current = dict(body, id=7, assets=[],
                                upload_url="https://uploads.github.com/owner/repo/releases/7/assets{?name,label}")
            return copy.deepcopy(self.current)
        if file is not None:
            if self.fail_upload:
                raise RuntimeError("Controlled upload failure")
            from urllib.parse import parse_qs, urlparse
            name = parse_qs(urlparse(path).query)["name"][0]
            data = Path(file).read_bytes()
            self.current["assets"].append({
                "name": name, "size": len(data), "state": "uploaded",
                "digest": "sha256:" + hashlib.sha256(data).hexdigest(),
            })
            return copy.deepcopy(self.current["assets"][-1])
        if method == "GET" and "/git/ref/tags/" in path:
            return copy.deepcopy(self.refs[0])
        if method == "GET" and "/git/tags/" in path:
            return copy.deepcopy(self.tag_objects[path.rsplit("/", 1)[1]])
        if method == "GET" and path.endswith("/releases/7"):
            result = copy.deepcopy(self.current)
            if self.corrupt_digest and result["assets"]:
                result["assets"][0]["digest"] = "sha256:" + "0" * 64
            return result
        if method == "PATCH" and path.endswith("/releases/7"):
            if body.get("draft") is False:
                if len(self.current["assets"]) not in {3, 10}:
                    raise AssertionError("Never publish a partial release")
                self.published = True
            self.current.update(body)
            return copy.deepcopy(self.current)
        raise AssertionError((method, path))


class IdentityTests(unittest.TestCase):
    def test_version_is_read_from_the_requested_checkout(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "pubspec.yaml"
            path.write_text("name: fixture\nversion: 4.2.1+999\n")
            identity = read_identity(path)
            self.assertEqual(identity.version, "4.2.1")
            self.assertEqual(identity.build, "999")
            self.assertEqual(identity.tag, "v4.2.1")

    def test_duplicate_malformed_and_unbuilt_versions_fail(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "pubspec.yaml"
            for text in ["version: 3.3.7", "version: 03.3.7+343",
                         "version: 3.3.7+0", "version: 3.3.7+343\nversion: 3.3.7+343"]:
                path.write_text(text)
                with self.subTest(text=text), self.assertRaises(ValueError):
                    read_identity(path)


class AndroidSignerTests(unittest.TestCase):
    def report(self, prefix, certificate):
        return (
            "Verifies\nVerified using v2 scheme (APK Signature Scheme v2): true\n"
            f"Number of signers: 1\n{prefix} certificate SHA-256 digest: {certificate}\n"
        )

    def test_actual_current_build_tools_v2_section_and_legacy_prefix(self):
        for prefix in ["V2 Signer:", "Signer #1", "V3.1 Signer:"]:
            with self.subTest(prefix=prefix):
                self.assertEqual(release.signing_certificate(
                    self.report(prefix, "b" * 64), "b" * 64,
                ), "b" * 64)

    def test_all_signature_schemes_must_match_the_one_configured_certificate(self):
        report = self.report("V2 Signer:", "b" * 64)
        same = report + f"V3 Signer: certificate SHA-256 digest: {'b' * 64}\n"
        self.assertEqual(release.signing_certificate(same, "b" * 64), "b" * 64)
        different = report + f"V3 Signer: certificate SHA-256 digest: {'c' * 64}\n"
        with self.assertRaises(ValueError):
            release.signing_certificate(different, "b" * 64)

    def test_wrong_signer_multiple_signers_unverified_signature_or_public_key_fail(self):
        good = self.report("V2 Signer:", "b" * 64)
        for bad in [good.replace("b" * 64, "c" * 64),
                    good.replace("Number of signers: 1", "Number of signers: 2"),
                    good.replace("): true", "): false"),
                    good.replace("certificate SHA-256", "public key SHA-256")]:
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                release.signing_certificate(bad, "b" * 64)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(release, "Unified release is not implemented")
        self.tmp = tempfile.TemporaryDirectory(prefix="unified release ")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.identity = repository_identity()
        self.trigger = context()
        self.trigger["source_ref"] = "refs/heads/main"
        self.sdk = {"frameworkVersion": "3.47.9", "dartSdkVersion": "3.13.7", "channel": "stable"}
        self.api = FakeGitHub()
        for platform in ["android", "windows", "macos"]:
            (self.root / platform).mkdir()
        app = self.root / "app"
        bundle(app)
        image = self.root / "macos" / mac.NAME
        image.write_bytes(b"controlled image, native acceptance is separate")
        mac.create_artifacts(self.root / "macos", mac.snapshot_bundle(app), self.trigger)
        self.android_name = f"fanqie-v{self.identity.version}.apk"
        self.windows_name = f"FanqieReader-{self.identity.version}-{self.identity.build}-windows-x64.zip"
        apk = self.root / "android" / self.android_name
        with zipfile.ZipFile(apk, "w") as archive:
            for name in ["AndroidManifest.xml", "classes.dex", "resources.arsc",
                         "assets/flutter_assets/AssetManifest.bin",
                         "assets/flutter_assets/FontManifest.json"]:
                archive.writestr(name, b"fixture")
            for abi in ["arm64-v8a", "armeabi-v7a", "x86_64"]:
                for library in ["libapp.so", "libflutter.so"]:
                    archive.writestr(f"lib/{abi}/{library}", b"ELF fixture")
        payload = {"FanqieReader.exe": b"PE fixture", "flutter_windows.dll": b"PE engine"}
        winzip = self.root / "windows" / self.windows_name
        with zipfile.ZipFile(winzip, "w") as archive:
            for name, data in payload.items():
                archive.writestr(name, data)
        common = {
            **{k: self.trigger[k] for k in mac.TRIGGER_KEYS},
            "schema_version": 1, "version": self.identity.full_version,
            "release_tag": self.identity.tag, "flutter": self.sdk,
            "build_target": "lib/main.dart", "build_mode": "Release",
        }
        self.write_info("android", self.android_name, common | {
            "build": self.identity.build, "architecture": "universal",
            "application_id": "com.fanqie.fanqie_flutter",
            "signing": "release-keystore", "signed": True,
            "signing_certificate_sha256": "b" * 64,
            "native_abis": ["arm64-v8a", "armeabi-v7a", "x86_64"],
        })
        self.write_info("windows", self.windows_name, common | {
            "architecture": "x64", "signing": "unsigned",
            "authenticode_signed": False, "runtime": {"family": "VC143"},
            "package_files_sha256": {k: hashlib.sha256(v).hexdigest() for k, v in payload.items()},
        })

    def write_info(self, platform, name, info):
        directory = self.root / platform
        (directory / f"{name}.sha256").write_text(
            f"{mac.digest(directory / name)}  {name}\n", encoding="utf-8", newline="\n",
        )
        info["assets"] = {n: mac.record(directory / n) for n in [name, f"{name}.sha256"]}
        (directory / f"{platform}-build-info.json").write_text(json.dumps(info))

    def assemble(self):
        output = self.root / "release"
        release.assemble(self.root / "android", self.root / "windows", self.root / "macos",
                         output, self.trigger)
        return output

    def test_all_three_clients_and_checksums_are_required(self):
        stage = self.assemble()
        self.assertEqual(len(list(stage.iterdir())), 10)
        release.validate_stage(stage, self.trigger)
        manifest = mac.read_json(stage / "release-manifest.json")
        self.assertEqual(set(manifest["platforms"]), {"android", "windows", "macos"})
        self.assertFalse(manifest["platforms"]["macos"]["notarized"])

    def test_missing_client_never_creates_a_release(self):
        (self.root / "macos" / mac.NAME).unlink()
        with self.assertRaises(ValueError):
            self.assemble()
        self.assertEqual(self.api.calls, [])

    def test_wrong_source_version_run_attempt_or_sdk_is_rejected(self):
        path = self.root / "android/android-build-info.json"
        good = mac.read_json(path)
        for key, value in [("source_commit", "c" * 40), ("source_ref", "refs/heads/other"),
                           ("version", "0.0.0+1"), ("run_attempt", "2"),
                           ("flutter", self.sdk | {"frameworkVersion": "3.47.4"})]:
            path.write_text(json.dumps(good | {key: value}))
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.assemble()
        path.write_text(json.dumps(good))

    def test_tampered_stage_or_metadata_is_rejected(self):
        stage = self.assemble()
        (stage / self.windows_name).write_bytes(b"tampered")
        with self.assertRaises(ValueError):
            release.validate_stage(stage, self.trigger)

    def test_output_collision_never_overwrites_old_files(self):
        output = self.root / "release"
        output.mkdir()
        previous = output / self.android_name
        previous.write_bytes(b"keep old")
        with self.assertRaises((ValueError, FileExistsError)):
            self.assemble()
        self.assertEqual(previous.read_bytes(), b"keep old")

    def test_complete_verified_draft_is_the_only_public_transition(self):
        stage = self.assemble()
        release.publish(self.api, stage, self.trigger, "owner/repo", "notes")
        self.assertTrue(self.api.published)
        self.assertEqual(len(self.api.current["assets"]), 10)
        patch = next(i for i, call in enumerate(self.api.calls) if call[0] == "PATCH")
        uploads = [i for i, call in enumerate(self.api.calls) if "uploads.github.com" in call[1]]
        self.assertEqual(len(uploads), 10)
        self.assertTrue(all(i < patch for i in uploads))

    def test_upload_failure_never_publishes_partial_assets(self):
        self.api.fail_upload = True
        with self.assertRaises(RuntimeError):
            release.publish(self.api, self.assemble(), self.trigger, "owner/repo", "notes")
        self.assertFalse(self.api.published)

    def test_remote_asset_digest_failure_never_publishes(self):
        self.api.corrupt_digest = True
        with self.assertRaises(ValueError):
            release.publish(self.api, self.assemble(), self.trigger, "owner/repo", "notes")
        self.assertFalse(self.api.published)

    def test_authentication_failure_is_not_release_absence(self):
        self.api.fail_absence = True
        with self.assertRaises(RuntimeError):
            release.publish(self.api, self.assemble(), self.trigger, "owner/repo", "notes")
        self.assertFalse(self.api.published)

    def test_existing_release_draft_or_tag_is_not_overwritten(self):
        for kind in ["draft", "tag"]:
            self.api = FakeGitHub()
            if kind == "draft":
                self.api.drafts = [{"tag_name": self.identity.tag, "draft": True}]
            else:
                self.api.refs = [{"ref": f"refs/tags/{self.identity.tag}",
                                  "object": {"type": "commit", "sha": self.trigger["source_commit"]}}]
            stage = self.root / f"stage-{kind}"
            release.assemble(self.root / "android", self.root / "windows", self.root / "macos",
                             stage, self.trigger)
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                release.publish(self.api, stage, self.trigger, "owner/repo", "notes")
            self.assertFalse(self.api.published)

    def test_branch_verification_cannot_publish(self):
        stage = self.assemble()
        branch = self.trigger | {"source_ref": "refs/heads/codex/preview"}
        with self.assertRaises(ValueError):
            release.publish(self.api, stage, branch, "owner/repo", "notes")
        self.assertEqual(self.api.calls, [])

    def use_triggering_tag(self):
        self.trigger["source_ref"] = f"refs/tags/{self.identity.tag}"
        for path in [self.root / "android/android-build-info.json",
                     self.root / "windows/windows-build-info.json",
                     self.root / "macos/build-info.json"]:
            info = mac.read_json(path)
            info["source_ref"] = self.trigger["source_ref"]
            path.write_text(json.dumps(info))
        self.api.refs = [{
            "ref": self.trigger["source_ref"],
            "object": {"type": "commit", "sha": self.trigger["source_commit"]},
        }]

    def test_matching_triggering_tag_is_supported_without_moving_it(self):
        self.use_triggering_tag()
        release.publish(self.api, self.assemble(), self.trigger, "owner/repo", "notes")
        self.assertTrue(self.api.published)
        self.assertFalse(any(call[0] == "POST" and call[1].endswith("/git/refs")
                             for call in self.api.calls))

    def test_annotated_tag_resolves_to_the_exact_commit(self):
        self.use_triggering_tag()
        self.api.refs[0]["object"] = {"type": "tag", "sha": "c" * 40}
        self.api.tag_objects["c" * 40] = {
            "object": {"type": "commit", "sha": self.trigger["source_commit"]},
        }
        release.publish(self.api, self.assemble(), self.trigger, "owner/repo", "notes")
        self.assertTrue(self.api.published)

    def test_wrong_or_cyclic_triggering_tag_never_publishes(self):
        self.use_triggering_tag()
        self.api.refs[0]["object"] = {"type": "tag", "sha": "c" * 40}
        self.api.tag_objects["c" * 40] = {"object": {"type": "tag", "sha": "c" * 40}}
        with self.assertRaises(ValueError):
            release.publish(self.api, self.assemble(), self.trigger, "owner/repo", "notes")
        self.assertFalse(self.api.published)

    def test_debug_android_or_forged_mac_signing_claims_cannot_publish(self):
        path = self.root / "android/android-build-info.json"
        original = mac.read_json(path)
        path.write_text(json.dumps(original | {"signing": "debug", "signed": True}))
        with self.assertRaises(ValueError):
            self.assemble()
        path.write_text(json.dumps(original))
        stage = self.assemble()
        manifest = mac.read_json(stage / "release-manifest.json")
        manifest["platforms"]["macos"]["notarized"] = True
        (stage / "release-manifest.json").write_text(json.dumps(manifest))
        with self.assertRaises(ValueError):
            release.validate_stage(stage, self.trigger)

    def test_zip_escape_and_payload_replacement_fail_even_with_new_outer_hash(self):
        path = self.root / "windows/windows-build-info.json"
        info = mac.read_json(path)
        zip_path = self.root / "windows" / self.windows_name
        with zipfile.ZipFile(zip_path, "a") as archive:
            archive.writestr("../outside.exe", b"do not extract")
        self.write_info("windows", self.windows_name, info)
        with self.assertRaises(ValueError):
            self.assemble()

    def test_apk_resource_names_remain_case_sensitive_but_exact_duplicates_fail(self):
        path = self.root / "android" / self.android_name
        with zipfile.ZipFile(path, "a") as archive:
            archive.writestr("res/drawable/Resource.xml", b"upper")
            archive.writestr("res/drawable/resource.xml", b"lower")
        self.assertEqual(set(release.android_payload(path)), release.ABIS)
        with zipfile.ZipFile(path, "a") as archive:
            archive.writestr("res/drawable/resource.xml", b"duplicate")
        with self.assertRaises(ValueError):
            release.android_payload(path)

    def test_android_standalone_publish_verifies_and_uploads_only_android(self):
        android_tag = release.android_release_tag()
        self.trigger["source_ref"] = f"refs/tags/{android_tag}"
        info_path = self.root / "android/android-build-info.json"
        info = mac.read_json(info_path)
        info["source_ref"] = self.trigger["source_ref"]
        info_path.write_text(json.dumps(info))
        self.api.refs = [{
            "ref": self.trigger["source_ref"],
            "object": {"type": "commit", "sha": self.trigger["source_commit"]},
        }]
        result = release.publish_android(
            self.api, self.root / "android", self.trigger, "owner/repo", "android notes",
        )
        self.assertTrue(self.api.published)
        self.assertEqual(result["tag_name"], android_tag)
        self.assertEqual(len(self.api.current["assets"]), 3)
        self.assertEqual(
            {asset["name"] for asset in self.api.current["assets"]},
            set(release.names("android")),
        )
        self.assertFalse(any(call[0] == "POST" and call[1].endswith("/git/refs")
                             for call in self.api.calls))


if __name__ == "__main__":
    unittest.main(verbosity=2)
