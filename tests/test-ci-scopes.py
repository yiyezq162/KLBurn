#!/usr/bin/env python3
"""Verify public scope and mandatory private replay guards in an isolated source copy."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
GUARDS = (
    "真机传感器样本至少吃到一份（否则上面整组是空转）",
    "真机数据里至少有一台判出了没接交流电的电源（否则降级那条没被验到）",
)


def missing_replay_failed(result):
    return (result.returncode == 1
            and re.search(r"通过 \d+ 项，失败 2 项", result.stdout) is not None
            and all(any("FAIL" in line and guard in line
                        for line in result.stdout.splitlines()) for guard in GUARDS))


class Scopes(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="klburn-ci-scopes-")
        cls.repo = Path(cls.temp.name)
        # Explicit source-only inputs; also works from a source archive without .git.
        for name in ("rootfs", "tools"):
            shutil.copytree(ROOT / name, cls.repo / name,
                            ignore=shutil.ignore_patterns("__pycache__"))
        (cls.repo / "tests").mkdir()
        for name in ("test-hw-checks.sh", "run-all.sh"):
            shutil.copy2(ROOT / "tests" / name, cls.repo / "tests" / name)
        cls.script = cls.repo / "tests/test-hw-checks.sh"
        cls.original = cls.script.read_text()

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def hardware(self, *args):
        env = dict(os.environ, TEST_SCOPE="public", scope="public")
        return subprocess.run(["bash", str(self.script), *args], cwd=self.repo,
                              env=env, text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=180)

    def test_default_still_requires_both_real_coverage_guards(self):
        self.assertTrue(missing_replay_failed(self.hardware()),
                        "Default must fail both real-replay guards without private data")

    def test_public_does_not_replay_private_directory(self):
        marker = self.repo / "test_out/PRIVATE_SENTINEL/raw"
        marker.mkdir(parents=True)
        (marker / "ipmi-sensors.txt").write_text("not a valid hardware sample\n")
        try:
            result = self.hardware("--public")
            self.assertEqual(result.returncode, 0, result.stdout[-3000:])
            self.assertIn("NOT_RUN：私有真机传感器/电源回放", result.stdout)
            self.assertNotIn("PRIVATE_SENTINEL", result.stdout)
            self.assertNotIn("FAIL", "\n".join(line for line in result.stdout.splitlines()
                                               if any(g in line for g in GUARDS)))
        finally:
            shutil.rmtree(self.repo / "test_out")

    def test_invalid_scope_rejected_by_both_entrypoints(self):
        for entry in ("test-hw-checks.sh", "run-all.sh"):
            for args in (("--publci",), ("--public", "extra")):
                result = subprocess.run(["bash", str(self.repo / "tests" / entry), *args],
                                        capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 2)

    def test_each_deleted_guard_mutation_is_detected(self):
        for guard in GUARDS:
            with self.subTest(guard=guard):
                pattern = r'^check "' + re.escape(guard) + r'".*\\\n[^\n]*\n'
                mutated, count = re.subn(pattern, "", self.original, flags=re.MULTILINE)
                self.assertEqual(count, 1)
                try:
                    self.script.write_text(mutated)
                    self.assertFalse(missing_replay_failed(self.hardware()),
                                     "Deleted coverage guard must not satisfy default contract")
                finally:
                    self.script.write_text(self.original)


if __name__ == "__main__":
    result = unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(Scopes))
    failed = len(result.failures) + len(result.errors)
    print(f"通过 {result.testsRun - failed} 项，失败 {failed} 项")
    raise SystemExit(not result.wasSuccessful())
