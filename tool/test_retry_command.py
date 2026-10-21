"""Retries must recover flaky simulator runs without hiding real failures."""
import sys
import tempfile
import time
import unittest
from pathlib import Path

from retry_command import main, run


def python(code):
    return [sys.executable, "-c", code]


class RetryCommandTest(unittest.TestCase):
    def test_success_runs_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp, "log")
            code = run(python(f"open({str(log)!r}, 'a').write('x')"), attempts=2, timeout=30)
            self.assertEqual(code, 0)
            self.assertEqual(log.read_text(), "x")

    def test_failure_then_success_is_retried(self):
        with tempfile.TemporaryDirectory() as tmp:
            marker = Path(tmp, "seen")
            flaky = python(f"import os,sys; p={str(marker)!r}; seen=os.path.exists(p); open(p,'w').close(); sys.exit(0 if seen else 3)")
            self.assertEqual(run(flaky, attempts=2, timeout=30), 0)

    def test_persistent_failure_keeps_the_last_exit_code(self):
        self.assertEqual(run(python("import sys; sys.exit(5)"), attempts=2, timeout=30), 5)

    def test_hang_is_killed_and_reported_as_timeout(self):
        started = time.monotonic()
        code = run(python("import time; time.sleep(60)"), attempts=1, timeout=0.5)
        self.assertEqual(code, 124)
        self.assertLess(time.monotonic() - started, 10)

    def test_hung_child_processes_are_killed_with_the_group(self):
        with tempfile.TemporaryDirectory() as tmp:
            late = Path(tmp, "late")
            # The grandchild would write the file after the timeout if it survived.
            parent = python(
                "import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',"
                f"\"import time; time.sleep(1.5); open({str(late)!r},'w').close()\"]); time.sleep(60)")
            self.assertEqual(run(parent, attempts=1, timeout=0.5), 124)
            time.sleep(2)
            self.assertFalse(late.exists())

    def test_before_retry_runs_only_between_attempts(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp, "log")
            code = run(python("import sys; sys.exit(1)"), attempts=3, timeout=30,
                       before_retry=f"echo r >> {log}")
            self.assertEqual(code, 1)
            self.assertEqual(log.read_text().split(), ["r", "r"])

    def test_cli_accepts_separator_and_rejects_missing_command(self):
        self.assertEqual(main(["--timeout-minutes", "1", "--", *python("pass")]), 0)
        with self.assertRaises(SystemExit):
            main(["--timeout-minutes", "1"])


if __name__ == "__main__":
    unittest.main()
