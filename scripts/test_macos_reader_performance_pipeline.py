#!/usr/bin/env python3
"""Behavioral lifecycle fixtures for the real Mac AOT shell runner.

Requires Python >=3.10 and POSIX Bash (BASH_EXECUTABLE on Windows).
Only the copied runner's absolute caffeinate executable path is substituted.
Flutter, signing, the app and caffeinate are isolated process/command doubles;
no Mac build, AOT measurement, native dispatch or network is exercised.
An independent Python watchdog bounds each run. Fake long-running processes
also have a 40-second self-limit and use FIFO/read builtins, not child sleepers.
"""

import os
from pathlib import Path
import shutil
import subprocess
import textwrap
import time
import unittest
import warnings


ROOT = Path(__file__).resolve().parents[1]
APP = Path("build/macos/Build/Products/Profile/FanqieReader.app/Contents/MacOS/FanqieReader")


class PerformancePipelineTests(unittest.TestCase):
    def setUp(self):
        import tempfile

        self.bash = os.environ.get("BASH_EXECUTABLE") or shutil.which("bash")
        if not self.bash:
            self.fail("Bash is required; set BASH_EXECUTABLE")
        self.temporary = tempfile.TemporaryDirectory(prefix="macos AOT lifecycle ")
        self.addCleanup(self.temporary.cleanup)
        self.root = (Path(self.temporary.name) / "checkout with spaces").resolve()
        self.bin = self.root / "fake bin"
        self.bin.mkdir(parents=True)
        (self.root / "scripts").mkdir()
        (self.root / APP).parent.mkdir(parents=True)
        self.process = None
        self.stopped_output = ("", "")
        self.addCleanup(self.stop_owned)
        self.shell_root = str(self.root)
        if os.name == "nt":
            self.shell_root = subprocess.check_output(
                [self.bash, "--noprofile", "--norc", "-c", 'cygpath -u "$1"', "_", str(self.root)],
                text=True, timeout=3,
            ).strip()
        self.env = os.environ.copy()
        for key in ("BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS", "CDPATH", "FLUTTER"):
            self.env.pop(key, None)
        self.env.update({
            "PATH": f"{self.shell_root}/fake bin:/usr/bin:/bin",
            "FIXTURE_ROOT": self.shell_root,
            "FIXTURE_APP_EXIT": "0",
            "FIXTURE_HOLD_APP": "0",
            "FIXTURE_HANG_HELPER": "0",
            "MACOS_REQUIRE_FOREGROUND": "false",
            "MACOS_READER_PERF_LOG": f"{self.shell_root}/performance.log",
            "FLUTTER": "flutter",
        })
        # Normalize checkout CRLF only here; do not rewrite lifecycle/deadlines.
        source = (ROOT / "scripts/test_macos_reader_performance.sh").read_text(encoding="utf-8")
        source = source.replace("/usr/bin/caffeinate", f'"{self.shell_root}/fake bin/caffeinate"')
        self.write(self.root / "scripts/test_macos_reader_performance.sh", source)
        self.write(self.bin / "uname", """\
            #!/usr/bin/env bash
            case "$1" in -s) echo Darwin;; -m) echo arm64;; *) exit 99;; esac
        """)
        self.write(self.bin / "flutter", """\
            #!/usr/bin/env bash
            [[ "$1" == build && "$2" == macos ]] || exit 99
            printf '%s\\n' "$*" > "$FIXTURE_ROOT/build-command"
        """)
        self.write(self.root / "scripts/sign_macos_internal.sh", """\
            #!/usr/bin/env bash
            [[ -x "$1/Contents/MacOS/FanqieReader" && "$2" == debug ]] || exit 98
            printf 'signed\\n' > "$FIXTURE_ROOT/signed"
        """)
        self.write(self.root / APP, """\
            #!/usr/bin/env bash
            printf '%s\\n' "$$" > "$FIXTURE_ROOT/app.pid"
            trap 'printf done > "$FIXTURE_ROOT/app.done"; exit 0' TERM INT
            if [[ "$FIXTURE_HOLD_APP" == 1 ]]; then
              mkfifo "$FIXTURE_ROOT/app.fifo"
              exec 8<>"$FIXTURE_ROOT/app.fifo"
              printf ready > "$FIXTURE_ROOT/app.ready"
              limit=$((SECONDS + 40))
              while (( SECONDS < limit )); do read -r -t 1 -u 8 value || :; done
              exit 93
            fi
            printf ready > "$FIXTURE_ROOT/app.ready"
            for ((i=0; i<7; i++)); do echo 'FANQIE_WORKSPACE_PERF_MODE {}'; done
            if [[ "$FIXTURE_APP_EXIT" == 0 ]]; then echo 'FANQIE_WORKSPACE_PERF_OK {}'; fi
            printf done > "$FIXTURE_ROOT/app.done"
            exit "$FIXTURE_APP_EXIT"
        """)
        self.write(self.bin / "caffeinate", """\
            #!/usr/bin/env bash
            [[ "$1" == -di && "$2" == -w && "$3" =~ ^[0-9]+$ ]] || exit 97
            printf '%s\\n' "$$" > "$FIXTURE_ROOT/helper.pid"
            printf '%s\\n' "$3" > "$FIXTURE_ROOT/helper-app.pid"
            mkfifo "$FIXTURE_ROOT/helper.fifo"
            exec 9<>"$FIXTURE_ROOT/helper.fifo"
            trap 'printf TERM >> "$FIXTURE_ROOT/helper.term"; [[ "$FIXTURE_HANG_HELPER" == 1 ]] || exit 0' TERM
            printf ready > "$FIXTURE_ROOT/helper.ready"
            limit=$((SECONDS + 40))
            while (( SECONDS < limit )); do
              if [[ "$FIXTURE_HANG_HELPER" != 1 && -f "$FIXTURE_ROOT/app.done" ]]; then exit 0; fi
              read -r -t 1 -u 9 value || :
            done
            exit 92
        """)

    @staticmethod
    def write(path, contents):
        path.write_text(textwrap.dedent(contents), encoding="utf-8", newline="\n")
        path.chmod(0o755)

    def shell(self, code, *arguments):
        return subprocess.run(
            [self.bash, "--noprofile", "--norc", "-c", code, "_", *arguments],
            env=self.env, capture_output=True, text=True, timeout=3,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
        )

    def pid(self, name):
        path = self.root / f"{name}.pid"
        if not path.exists():
            return None
        pid = path.read_text(encoding="utf-8").strip()
        if not pid.isdecimal() or int(pid) <= 1:
            self.fail(f"Invalid test-owned PID: {path}")
        return pid

    def alive(self, name):
        pid = self.pid(name)
        return pid is not None and self.shell('kill -0 "$1" 2>/dev/null', pid).returncode == 0

    def signal(self, name, signal):
        pid = self.pid(name)
        if pid is not None:
            self.shell('kill -s "$1" "$2" 2>/dev/null || :', signal, pid)

    def stop_owned(self):
        if self.process is None:
            return
        # Kill only PIDs recorded inside this test's private directory. Kill
        # the helper first so even the old runner can unblock wait and reap it.
        self.signal("helper", "KILL")
        self.signal("app", "KILL")
        if self.process.poll() is None:
            try:
                self.stopped_output = self.process.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                self.signal("app", "KILL")
                self.signal("runner", "KILL")
                self.stopped_output = self.process.communicate(timeout=3)
        for name in ("app", "helper"):
            deadline = time.monotonic() + 1
            while self.alive(name) and time.monotonic() < deadline:
                time.sleep(0.02)
            if self.alive(name):
                self.signal(name, "KILL")
                self.fail(f"Test-owned {name} PID {self.pid(name)} leaked after watchdog cleanup")

    def run_runner(self, *, app_exit=0, hang=False, signal=None):
        env = self.env | {
            "FIXTURE_APP_EXIT": str(app_exit),
            "FIXTURE_HANG_HELPER": "1" if hang else "0",
            "FIXTURE_HOLD_APP": "1" if signal else "0",
        }
        runner = f"{self.shell_root}/scripts/test_macos_reader_performance.sh"
        start = time.monotonic()
        # The shell is foreground, so INT is not inherited as ignored from an
        # asynchronous shell job. $0 preserves the copied script's ROOT logic.
        self.process = subprocess.Popen(
            [self.bash, "--noprofile", "--norc", "-c",
             'printf "%s\\n" "$$" > "$FIXTURE_ROOT/runner.pid"; source "$0"', runner],
            cwd=self.root, env=env, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
        )
        if signal:
            deadline = time.monotonic() + 3
            while not all((self.root / f"{name}.ready").exists() for name in ("app", "helper")):
                self.assertIsNone(self.process.poll(), "Runner exited before ready")
                self.assertLess(time.monotonic(), deadline, "Fixture did not become ready")
                time.sleep(0.02)
            self.signal("runner", signal)
        try:
            stdout, stderr = self.process.communicate(timeout=18)
        except subprocess.TimeoutExpired:
            ready = {
                name: (self.root / name).exists()
                for name in ("signed", "app.done", "helper.ready", "helper.term")
            }
            self.stop_owned()
            self.fail(
                "Independent 18s watchdog fired: runner did not finish bounded "
                f"helper cleanup (app_exit={app_exit}, signal={signal}). "
                f"Lifecycle markers: {ready}; watchdog recovered exit="
                f"{self.process.returncode}, owned app/helper reaped. "
                f"Runner stderr: {self.stopped_output[1]!r}"
            )
        elapsed = time.monotonic() - start
        self.assertFalse(self.alive("app"), stdout + stderr)
        self.assertFalse(self.alive("helper"), stdout + stderr)
        self.assertEqual(self.pid("app"), self.pid("helper-app"), "caffeinate must own the real app PID")
        print(
            f"fixture exit={self.process.returncode} elapsed={elapsed:.2f}s "
            f"app/helper dead hang={hang} signal={signal}",
            flush=True,
        )
        return self.process.returncode, stdout, stderr

    def test_normal_success(self):
        code, stdout, stderr = self.run_runner()
        self.assertEqual(code, 0, stdout + stderr)
        self.assertEqual(stdout.count("FANQIE_WORKSPACE_PERF_MODE "), 7)
        self.assertIn("FANQIE_WORKSPACE_PERF_OK ", stdout)

    def test_application_failure_preserves_exit_37(self):
        code, stdout, stderr = self.run_runner(app_exit=37)
        self.assertEqual(code, 37, stdout + stderr)

    def test_stubborn_helper_has_bounded_exit_trap_cleanup(self):
        code, stdout, stderr = self.run_runner(hang=True)
        self.assertEqual(code, 1, stdout + stderr)
        self.assertTrue((self.root / "helper.term").exists(), "Fault-injected helper must see TERM")

    def test_stubborn_helper_preserves_existing_application_failure(self):
        code, stdout, stderr = self.run_runner(app_exit=37, hang=True)
        self.assertEqual(code, 37, stdout + stderr)

    def test_term_failure_trap_preserves_143(self):
        code, stdout, stderr = self.run_runner(hang=True, signal="TERM")
        self.assertEqual(code, 143, stdout + stderr)

    def test_int_failure_trap_preserves_130(self):
        code, stdout, stderr = self.run_runner(hang=True, signal="INT")
        self.assertEqual(code, 130, stdout + stderr)


if __name__ == "__main__":
    warnings.filterwarnings("error", category=ResourceWarning)
    unittest.main(verbosity=2)
