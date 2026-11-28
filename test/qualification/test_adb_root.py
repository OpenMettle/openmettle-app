"""Check the hosted emulator setup using a scripted adb connection."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HELPER = Path(__file__).with_name("adb_root.sh")


class AdbRootTest(unittest.TestCase):
    def run_helper(self, *, recover):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            programs = {
                "timeout": 'shift\nexec "$@"',
                "sleep": "exit 0",
                "adb": r'''
case "$*" in
  root)
    echo root >> attempts
    if [ "$RECOVER" = yes ] && [ "$(wc -l < attempts)" -eq 1 ]; then
      echo "adb: unable to connect for root: closed" >&2
      exit 1
    fi ;;
  wait-for-device) exit 0 ;;
  "shell id -u")
    if [ "$RECOVER" = yes ]; then echo 0; else echo 2000; fi ;;
  *) exit 1 ;;
esac''',
            }
            for name, body in programs.items():
                path = work / name
                path.write_text("#!/bin/sh\n" + body + "\n", encoding="utf-8")
                path.chmod(0o700)
            env = {**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"],
                   "GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted",
                   "ANDROID_SERIAL": "emulator-5554", "RECOVER": "yes" if recover else "no"}
            result = subprocess.run(["bash", str(HELPER.resolve())], cwd=work, env=env,
                                    capture_output=True, timeout=10)
            return result.returncode, len((work / "attempts").read_text().splitlines())

    def test_reconnects_after_a_closed_root_transport(self):
        self.assertEqual(self.run_helper(recover=True), (0, 2))

    def test_command_success_with_unprivileged_shell_exhausts_retries(self):
        self.assertEqual(self.run_helper(recover=False), (1, 6))
