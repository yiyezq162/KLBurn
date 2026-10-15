#!/usr/bin/env python3
"""Check actual ZIP payloads, provenance, overwrite guard and reproducibility."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("packaging", ROOT / "build/package-tools.py")
packaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packaging)


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.source = self.base / "source"
        self.source.mkdir()
        paths = set(packaging.COMMON.values()) | {"tools/customize/" + p for p in packaging.LAUNCHERS.values()}
        for name in paths:
            dest = self.source / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, dest)
        (self.source / "build").mkdir()
        (self.source / "build/config.sh").write_text('KLBURN_VERSION="1.11.0"\n')
        (self.source / ".gitignore").write_text("vendor/\ntest_out/\n")
        self.git("init", "-q")
        self.git("add", ".")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "-qm", "synthetic packaging fixture")
        (self.source / "vendor").mkdir()
        (self.source / "vendor/do-not-publish.txt").write_text("synthetic private marker")

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.source).decode().strip()

    def test_payload_and_hashes(self):
        output = self.base / "out"
        receipt = packaging.package(self.source, output)
        self.assertEqual(set(receipt["artifacts"]), {"Windows", "macOS", "Linux"})
        for platform, item in receipt["artifacts"].items():
            path = output / item["file"]
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), item["sha256"])
            with zipfile.ZipFile(path) as archive:
                self.assertEqual(set(archive.namelist()), set(packaging.COMMON) | {packaging.LAUNCHERS[platform], "SOURCE.json"})
                metadata = json.loads(archive.read("SOURCE.json"))
                self.assertEqual(metadata["commit"], self.git("rev-parse", "HEAD"))
                for name, digest in metadata["files"].items():
                    self.assertEqual(hashlib.sha256(archive.read(name)).hexdigest(), digest)
                mode = archive.getinfo(packaging.LAUNCHERS[platform]).external_attr >> 16
                self.assertEqual(bool(mode & 0o111), platform != "Windows")

    def test_reproducible(self):
        first = packaging.package(self.source, self.base / "first")
        second = packaging.package(self.source, self.base / "second")
        self.assertEqual(first, second)

    def test_dirty_source_rejected(self):
        (self.source / "LICENSE").write_text("changed")
        with self.assertRaises(ValueError):
            packaging.package(self.source, self.base / "out")

    def test_no_overwrite(self):
        output = self.base / "out"
        first = packaging.package(self.source, output)
        with self.assertRaises(ValueError):
            packaging.package(self.source, output)
        self.assertEqual(json.loads((output / "tools-manifest.json").read_text()), first)


if __name__ == "__main__":
    result = unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(PackagingTests))
    failed = len(result.failures) + len(result.errors)
    print("通过 %d 项，失败 %d 项" % (result.testsRun - failed - len(result.skipped), failed))
    sys.exit(not result.wasSuccessful())
