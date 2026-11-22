#!/usr/bin/env python3
"""Run real macOS gate/CI shell commands with isolated external-command doubles.

No Flutter SDK, Xcode, signing identity, network, or Mac desktop is used here.
Only uname, Flutter, internal signing, and xcodebuild are replaced. These tests
verify command contracts and failure propagation, not native macOS correctness.
On Windows, set BASH_EXECUTABLE to a Cygwin/Git Bash executable if needed.
"""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
NATIVE_COMMANDS = [
    ("flutter", "build", "macos", "--debug", "--no-pub", "--target", "lib/main.dart"),
    ("sign", "build/macos/Build/Products/Debug/FanqieReader.app", "debug"),
    (
        "xcodebuild", "test", "-workspace", "macos/Runner.xcworkspace",
        "-scheme", "Runner", "-configuration", "Debug",
        "-destination", "platform=macOS,arch=arm64",
        "-derivedDataPath", "build/macos", "-parallel-testing-enabled", "NO",
    ),
]
PLATFORM_COMMAND = (
    "flutter", "test", "integration_test/macos_client_platform_test.dart",
    "-d", "macos", "--no-pub", "--reporter", "expanded",
)
ANALYZE_COMMAND = ("flutter", "analyze", "--no-pub")
DART_COMMAND = ("flutter", "test", "--no-pub", "--reporter", "expanded")
RELEASE_COMMAND = (
    "flutter", "build", "macos", "--release", "--no-pub", "--target", "lib/main.dart",
    "--build-name=3.3.6", "--build-number=342",
)


def ci_verification_commands():
    """Extract and execute verification run blocks, never setup or publishing.

    This deliberately narrow block-scalar reader uses the workflow's indentation.
    Assertions are on executed commands, exit codes, and logs, not source text.
    Actions scheduling, SDK installation, YAML validation, and permissions are
    outside this fixture's coverage and must be reviewed/validated separately.
    """
    names = {
        "静态分析", "离线单元与组件回归", "原生 XCTest（生产 Debug 主机）",
        "构建生产入口 Release",
    }
    lines = (ROOT / ".github/workflows/macos-internal.yml").read_text(
        encoding="utf-8"
    ).splitlines()
    in_build = False
    name = None
    blocks = []
    for index, line in enumerate(lines):
        if line == "  build:":
            in_build = True
        elif in_build and line.strip() and line.startswith("  ") and not line.startswith("    "):
            break
        if not in_build:
            continue
        if line.startswith("      - "):
            name = line.removeprefix("      - name: ") if line.startswith("      - name: ") else None
        if name in names and line == "        run: |":
            body = []
            for following in lines[index + 1:]:
                if following.strip() and not following.startswith("          "):
                    break
                body.append(following[10:])
            blocks.append("\n".join(body))
    return "\n".join(blocks)


def command_double(name, body):
    return textwrap.dedent(f"""\
        #!/usr/bin/env bash
        set -euo pipefail
        printf '%s\\t%s' '{name}' "$PWD" >> "$COMMAND_LOG"
        for argument in "$@"; do
          printf '\\t%s' "$argument" >> "$COMMAND_LOG"
        done
        printf '\\n' >> "$COMMAND_LOG"
        printf 'fixture {name} %s\\n' "$*"
    """) + textwrap.dedent(body)


FLUTTER_DOUBLE = """\
    case "$1" in
      analyze) exit "$FIXTURE_ANALYZE_EXIT" ;;
      test)
        if [[ "$2" == integration_test/macos_client_platform_test.dart ]]; then
          exit "$FIXTURE_INTEGRATION_EXIT"
        fi
        exit "$FIXTURE_DART_EXIT"
        ;;
      build)
        if [[ " $* " == *' --debug '* ]]; then
          [[ "$FIXTURE_BUILD_EXIT" == 0 ]] || exit "$FIXTURE_BUILD_EXIT"
          # Signing must wait for a completed build, not just a logged start.
          sleep 0.05
          mkdir -p build/macos/Build/Products/Debug/FanqieReader.app
          printf 'built\\n' > "$FIXTURE_ROOT/debug-built"
        elif [[ " $* " == *' --release '* ]]; then
          exit "$FIXTURE_RELEASE_EXIT"
        else
          exit 99
        fi
        ;;
      *) exit 99 ;;
    esac
"""


class NativePipelineTests(unittest.TestCase):
    def setUp(self):
        self.bash = os.environ.get("BASH_EXECUTABLE") or shutil.which("bash")
        if not self.bash:
            self.fail("Bash is required; set BASH_EXECUTABLE")
        self.temporary = tempfile.TemporaryDirectory(prefix="macos pipeline ")
        self.addCleanup(self.temporary.cleanup)
        # macOS /var can alias /private/var; use the physical path so cwd
        # assertions do not depend on a host's temporary-directory symlink.
        self.root = (Path(self.temporary.name) / "checkout with spaces").resolve()
        self.bin = self.root / "fake bin"
        self.bin.mkdir(parents=True)
        (self.root / "scripts").mkdir()
        self.logs = self.root / "build/macos/ci-logs"
        self.logs.mkdir(parents=True)
        self.caller = self.root / "outside caller"
        self.caller.mkdir()
        self.command_log = self.root / "commands.tsv"
        self.command_log.touch()
        # Normalize checkout CRLF only in the isolated fixture, not by mocking
        # or rewriting gate logic. A missing gate stays missing for the RED run.
        for name in ("test_macos_native.sh", "test_macos_platform.sh"):
            source = ROOT / "scripts" / name
            if source.exists():
                self.write(self.root / "scripts" / name, source.read_text(encoding="utf-8"))
        if os.name == "nt":
            self.shell_root = subprocess.check_output(
                [self.bash, "--noprofile", "--norc", "-c", 'cygpath -u "$1"', "_", str(self.root)],
                text=True,
            ).strip()
        else:
            self.shell_root = str(self.root)
        self.env = os.environ.copy()
        for key in ("BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS", "CDPATH", "FLUTTER"):
            self.env.pop(key, None)
        self.env.update({
            "PATH": f"{self.shell_root}/fake bin:/usr/bin:/bin",
            "COMMAND_LOG": f"{self.shell_root}/commands.tsv",
            "FIXTURE_ROOT": self.shell_root,
            "FIXTURE_OS": "Darwin", "FIXTURE_ARCH": "arm64",
            "FIXTURE_ANALYZE_EXIT": "0", "FIXTURE_DART_EXIT": "0",
            "FIXTURE_INTEGRATION_EXIT": "0", "FIXTURE_BUILD_EXIT": "0",
            "FIXTURE_SIGN_EXIT": "0", "FIXTURE_XCTEST_EXIT": "0",
            "FIXTURE_RELEASE_EXIT": "0", "VERSION": "3.3.6", "BUILD_NUMBER": "342",
        })
        self.write(self.bin / "uname", """\
            #!/usr/bin/env bash
            case "$1" in
              -s) printf '%s\\n' "$FIXTURE_OS" ;;
              -m) printf '%s\\n' "$FIXTURE_ARCH" ;;
              *) exit 99 ;;
            esac
        """)
        self.write(self.bin / "flutter", command_double("flutter", FLUTTER_DOUBLE))
        self.write(self.bin / "custom flutter", command_double("custom-flutter", FLUTTER_DOUBLE))
        self.write(self.root / "scripts/sign_macos_internal.sh", command_double("sign", """\
            [[ -f "$FIXTURE_ROOT/debug-built" && -d "$1" && "$2" == debug ]] || exit 98
            [[ "$FIXTURE_SIGN_EXIT" == 0 ]] || exit "$FIXTURE_SIGN_EXIT"
            printf 'signed\\n' > "$FIXTURE_ROOT/debug-signed"
        """))
        self.write(self.bin / "xcodebuild", command_double("xcodebuild", """\
            [[ -f "$FIXTURE_ROOT/debug-signed" ]] || exit 98
            exit "$FIXTURE_XCTEST_EXIT"
        """))

    @staticmethod
    def write(path, contents):
        path.write_text(textwrap.dedent(contents), encoding="utf-8", newline="\n")
        path.chmod(0o755)

    def run_script(self, name="test_macos_native.sh", arguments=(), **environment):
        return subprocess.run(
            [self.bash, "--noprofile", "--norc", f"{self.shell_root}/scripts/{name}", *arguments],
            cwd=self.caller, env=self.env | environment, capture_output=True, text=True, timeout=30,
        )

    def run_ci(self, **environment):
        return subprocess.run(
            [self.bash, "--noprofile", "--norc", "-c", ci_verification_commands()],
            cwd=self.root, env=self.env | environment, capture_output=True, text=True, timeout=30,
        )

    def commands(self):
        rows = [line.split("\t") for line in self.command_log.read_text(encoding="utf-8").splitlines()]
        for row in rows:
            self.assertEqual(row[1], self.shell_root, "Commands must run from the checkout root")
        return [tuple([row[0], *row[2:]]) for row in rows]

    def assert_exit(self, completed, code):
        self.assertEqual(completed.returncode, code, completed.stdout + completed.stderr)

    def assert_ci_failure(self, code, expected, log, **environment):
        self.assert_exit(self.run_ci(**environment), code)
        self.assertEqual(self.commands(), expected)
        self.assertIn("fixture", (self.logs / log).read_text(encoding="utf-8"))

    def test_native_builds_production_debug_then_signs_then_runs_xctest(self):
        self.assert_exit(self.run_script(), 0)
        self.assertEqual(self.commands(), NATIVE_COMMANDS)

    def test_native_respects_flutter_override_with_spaces(self):
        self.assert_exit(self.run_script(FLUTTER=f"{self.shell_root}/fake bin/custom flutter"), 0)
        self.assertEqual(self.commands(), [("custom-flutter", *NATIVE_COMMANDS[0][1:]), *NATIVE_COMMANDS[1:]])

    def test_native_rejects_non_arm64_before_building(self):
        self.assert_exit(self.run_script(FIXTURE_ARCH="x86_64"), 2)
        self.assertEqual(self.commands(), [])

    def test_native_rejects_non_macos_before_building(self):
        self.assert_exit(self.run_script(FIXTURE_OS="Linux"), 2)
        self.assertEqual(self.commands(), [])

    def test_native_build_failure_stops_signing_and_xctest(self):
        self.assert_exit(self.run_script(FIXTURE_BUILD_EXIT="33"), 33)
        self.assertEqual(self.commands(), NATIVE_COMMANDS[:1])

    def test_native_sign_failure_stops_xctest(self):
        self.assert_exit(self.run_script(FIXTURE_SIGN_EXIT="34"), 34)
        self.assertEqual(self.commands(), NATIVE_COMMANDS[:2])

    def test_native_propagates_xctest_failure(self):
        self.assert_exit(self.run_script(FIXTURE_XCTEST_EXIT="35"), 35)
        self.assertEqual(self.commands(), NATIVE_COMMANDS)

    def test_platform_forwards_manual_controls_then_restores_production_host(self):
        controls = (
            "--dart-define=MACOS_SAVE_PANEL_TEST=true",
            "--dart-define=MACOS_NATIVE_FULLSCREEN_TEST=true",
            "--dart-define=MACOS_READER_SCREENSHOTS=true",
        )
        self.assert_exit(self.run_script("test_macos_platform.sh", controls), 0)
        self.assertEqual(self.commands(), [(*PLATFORM_COMMAND, *controls), *NATIVE_COMMANDS])

    def test_platform_integration_failure_stops_native_gate(self):
        self.assert_exit(self.run_script("test_macos_platform.sh", FIXTURE_INTEGRATION_EXIT="36"), 36)
        self.assertEqual(self.commands(), [PLATFORM_COMMAND])

    def test_platform_propagates_native_failure(self):
        self.assert_exit(self.run_script("test_macos_platform.sh", FIXTURE_XCTEST_EXIT="35"), 35)
        self.assertEqual(self.commands(), [PLATFORM_COMMAND, *NATIVE_COMMANDS])

    def test_platform_rejects_non_arm64_before_integration(self):
        self.assert_exit(self.run_script("test_macos_platform.sh", FIXTURE_ARCH="x86_64"), 2)
        self.assertEqual(self.commands(), [])

    def test_platform_rejects_non_macos_before_integration(self):
        self.assert_exit(self.run_script("test_macos_platform.sh", FIXTURE_OS="Linux"), 2)
        self.assertEqual(self.commands(), [])

    def test_ci_runs_native_xctest_before_final_production_release(self):
        self.assert_exit(self.run_ci(), 0)
        self.assertEqual(self.commands(), [ANALYZE_COMMAND, DART_COMMAND, *NATIVE_COMMANDS, RELEASE_COMMAND])
        for log in ("flutter-analyze.log", "flutter-test.log", "native-xctest.log", "flutter-build.log"):
            self.assertIn("fixture", (self.logs / log).read_text(encoding="utf-8"))

    def test_ci_analyze_failure_stops_all_builds(self):
        self.assert_ci_failure(31, [ANALYZE_COMMAND], "flutter-analyze.log", FIXTURE_ANALYZE_EXIT="31")

    def test_ci_offline_test_failure_stops_all_builds(self):
        self.assert_ci_failure(32, [ANALYZE_COMMAND, DART_COMMAND], "flutter-test.log", FIXTURE_DART_EXIT="32")

    def test_ci_debug_build_failure_stops_native_and_release(self):
        self.assert_ci_failure(
            33, [ANALYZE_COMMAND, DART_COMMAND, *NATIVE_COMMANDS[:1]],
            "native-xctest.log", FIXTURE_BUILD_EXIT="33",
        )

    def test_ci_sign_failure_stops_native_and_release(self):
        self.assert_ci_failure(
            34, [ANALYZE_COMMAND, DART_COMMAND, *NATIVE_COMMANDS[:2]],
            "native-xctest.log", FIXTURE_SIGN_EXIT="34",
        )

    def test_ci_xctest_failure_survives_tee_and_stops_release(self):
        self.assert_ci_failure(
            35, [ANALYZE_COMMAND, DART_COMMAND, *NATIVE_COMMANDS],
            "native-xctest.log", FIXTURE_XCTEST_EXIT="35",
        )

    def test_ci_propagates_release_build_failure(self):
        self.assert_ci_failure(
            37, [ANALYZE_COMMAND, DART_COMMAND, *NATIVE_COMMANDS, RELEASE_COMMAND],
            "flutter-build.log", FIXTURE_RELEASE_EXIT="37",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
