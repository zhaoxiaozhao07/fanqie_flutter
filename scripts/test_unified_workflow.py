#!/usr/bin/env python3
"""Parse actual workflows and exercise source/publication scope decisions."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

import yaml
import unified_release as release
from release_identity import repository_identity

ROOT = Path(__file__).resolve().parents[1]


def workflow(name):
    return yaml.safe_load((ROOT / ".github/workflows" / name).read_text(encoding="utf-8"))


def events(document):
    # PyYAML's YAML 1.1 spelling treats `on` as True; GitHub uses the literal.
    return document.get("on", document.get(True))


class WorkflowTests(unittest.TestCase):
    def test_every_client_build_precedes_assembly_and_publication(self):
        jobs = workflow("release.yml")["jobs"]
        for platform in ["android", "windows", "macos"]:
            self.assertEqual(set(jobs[platform]["needs"]), {"prepare", "quality"})
            self.assertIn("outputs.packages == 'true'", jobs[platform]["if"])
        self.assertTrue({"android", "windows", "macos", "quality"} <= set(jobs["assemble"]["needs"]))
        self.assertTrue({"android", "windows", "macos", "quality", "assemble"} <= set(jobs["publish"]["needs"]))
        self.assertIn("outputs.publish == 'true'", jobs["publish"]["if"])
        self.assertNotIn("always()", jobs["publish"]["if"])

    def test_existing_native_build_gates_are_reused_without_independent_release(self):
        jobs = workflow("release.yml")["jobs"]
        self.assertEqual(jobs["windows"]["uses"], "./.github/workflows/windows-build.yml")
        self.assertEqual(jobs["macos"]["uses"], "./.github/workflows/macos-build.yml")
        self.assertIs(jobs["windows"]["with"]["publish"], False)
        self.assertIs(jobs["macos"]["with"]["publish"], False)
        self.assertIs(jobs["macos"]["with"]["full_platform"], True)
        self.assertIs(jobs["macos"]["with"]["reader_aot"], True)
        self.assertIs(jobs["macos"]["with"]["live_api"], False)
        self.assertEqual(jobs["windows"]["with"]["release_tag"],
                         "${{ needs.prepare.outputs.release_tag }}")

    def test_same_exact_checkout_and_version_reaches_all_platforms(self):
        release_jobs = workflow("release.yml")["jobs"]
        for platform in ["android", "windows", "macos"]:
            self.assertEqual(release_jobs[platform]["with"]["version"],
                             "${{ needs.prepare.outputs.version }}")
        for name in ["release.yml", "android-release.yml", "windows-build.yml", "macos-build.yml"]:
            document = workflow(name)
            if name != "release.yml":
                self.assertIn("workflow_call", events(document))
                self.assertIn("artifact_name", events(document)["workflow_call"]["outputs"])
            for job in document["jobs"].values():
                for step in job.get("steps", []):
                    if step.get("uses", "").startswith("actions/checkout@"):
                        self.assertEqual(step.get("with", {}).get("persist-credentials"), False)
                    if step.get("uses", "").startswith("subosito/flutter-action@"):
                        self.assertEqual(step["with"]["flutter-version"], "3.47.9")

    def test_only_unified_publisher_gets_write_permission(self):
        document = workflow("release.yml")
        self.assertEqual(document["permissions"]["contents"], "read")
        jobs = document["jobs"]
        self.assertEqual(jobs["publish"]["permissions"]["contents"], "write")
        for name in ["prepare", "quality", "android", "windows", "macos", "assemble"]:
            self.assertNotEqual(jobs[name].get("permissions", {}).get("contents"), "write")
        # A skipped publish job in a callee still violates the caller's read
        # ceiling during GitHub startup validation. Build-only callees must
        # have no such job, regardless of false inputs/if expressions.
        for platform in ["android", "windows", "macos"]:
            path = jobs[platform]["uses"].rsplit("/", 1)[1]
            callee = workflow(path)
            self.assertEqual(callee["permissions"]["contents"], "read")
            for job in callee["jobs"].values():
                self.assertNotEqual(job.get("permissions", {}).get("contents"), "write")

    def test_wrapper_and_callee_concurrency_never_deadlock_each_other(self):
        for wrapper_name, builder_name in [
            ("windows-release.yml", "windows-build.yml"),
            ("macos-internal.yml", "macos-build.yml"),
        ]:
            wrapper, builder = workflow(wrapper_name), workflow(builder_name)
            self.assertNotEqual(wrapper["concurrency"]["group"], builder["concurrency"]["group"])
            self.assertEqual(wrapper["jobs"]["build"]["uses"], f"./.github/workflows/{builder_name}")
            self.assertIn("publish", wrapper["jobs"])
            self.assertNotIn("publish", builder["jobs"])

    def test_android_verifies_real_certificate_and_never_uploads_keystore(self):
        steps = workflow("android-release.yml")["jobs"]["build"]["steps"]
        scripts = "\n".join(step.get("run", "") for step in steps)
        self.assertIn("keytool -exportcert", scripts)
        self.assertIn("apksigner", scripts)
        self.assertIn("--certificate-sha256", scripts)
        self.assertIn("--release --no-pub --target lib/main.dart", scripts)
        self.assertIn("git diff --exit-code -- pubspec.lock", scripts)
        uploads = [step["with"]["path"] for step in steps if step.get("uses", "").startswith("actions/upload-artifact")]
        self.assertEqual(set(uploads), {"dist/android-ci/", "build/android/ci-logs/"})
        cleanup = next(step for step in steps if step.get("name") == "移除本次签名文件")
        self.assertEqual(cleanup["if"], "always()")


class ScopeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="release-scope-")
        self.addCleanup(self.tmp.cleanup)
        self.output = Path(self.tmp.name) / "output"
        self.identity = repository_identity()
        self.environment = {
            "GITHUB_SHA": "a" * 40, "GITHUB_REF": "refs/heads/main",
            "GITHUB_SERVER_URL": "https://github.com", "GITHUB_REPOSITORY": "owner/repo",
            "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1",
            "GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_OUTPUT": str(self.output),
        }

    def prepare(self, publish="false", ancestor=True):
        def run(arguments, **kwargs):
            return subprocess.CompletedProcess(arguments, 0 if ancestor or "fetch" in arguments else 1)
        with mock.patch.dict(os.environ, self.environment), \
                mock.patch.object(release.subprocess, "check_output", return_value="a" * 40), \
                mock.patch.object(release.subprocess, "run", side_effect=run):
            release.prepare(self.identity.version, publish)
        return dict(line.split("=", 1) for line in self.output.read_text().splitlines())

    def test_main_push_checks_code_but_does_not_create_release_or_duplicate_packages(self):
        self.environment["GITHUB_EVENT_NAME"] = "push"
        values = self.prepare()
        self.assertEqual(values["packages"], "false")
        self.assertEqual(values["publish"], "false")

    def test_branch_manual_dry_run_builds_all_three_without_publication(self):
        self.environment["GITHUB_REF"] = "refs/heads/codex/preview"
        values = self.prepare()
        self.assertEqual(values["packages"], "true")
        self.assertEqual(values["publish"], "false")

    def test_main_manual_can_publish_one_matching_release(self):
        values = self.prepare("true")
        self.assertEqual(values["publish"], "true")
        self.assertEqual(values["release_tag"], self.identity.tag)

    def test_branch_cannot_request_publication(self):
        self.environment["GITHUB_REF"] = "refs/heads/codex/preview"
        with self.assertRaises(ValueError):
            self.prepare("true")
        self.assertFalse(self.output.exists())

    def test_release_tag_must_point_at_main_reachable_source(self):
        self.environment["GITHUB_REF"] = f"refs/tags/{self.identity.tag}"
        self.environment["GITHUB_EVENT_NAME"] = "push"
        self.assertEqual(self.prepare()["publish"], "true")
        self.output.unlink()
        with self.assertRaises(ValueError):
            self.prepare(ancestor=False)

    def test_wrong_tag_version_is_rejected(self):
        self.environment["GITHUB_REF"] = "refs/tags/v0.0.0"
        with self.assertRaises(ValueError):
            self.prepare()


if __name__ == "__main__":
    unittest.main(verbosity=2)
