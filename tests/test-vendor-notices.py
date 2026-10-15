#!/usr/bin/env python3
"""Notice preservation and file boundaries; no compiler required."""
import importlib.util
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import shutil
import unittest

spec = importlib.util.spec_from_file_location("notices", Path(__file__).resolve().parents[1] / "build/vendor-notices.py")
notices = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notices)


class NoticeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.src = self.root / "source"
        self.src.mkdir()
        self.out = self.root / "output"
        self.data = b"Copyright Example upstream\r\nAll original notice bytes retained.\r\n"
        (self.src / "LICENSE").write_bytes(self.data)

    def test_exact_bytes_and_optional_notice(self):
        (self.src / "NOTICE").write_bytes(self.data + b"Additional attribution\n")
        self.assertEqual(notices.copy_notices(self.src, self.out, ["LICENSE"], ["NOTICE"]), 2)
        self.assertEqual((self.out / "LICENSE").read_bytes(), self.data)
        self.assertEqual((self.out / "NOTICE").read_bytes(), (self.src / "NOTICE").read_bytes())

    def test_missing_optional(self):
        self.assertEqual(notices.copy_notices(self.src, self.out, ["LICENSE"], ["NOTICE"]), 1)

    def test_validate_all_before_write(self):
        with self.assertRaises(ValueError):
            notices.copy_notices(self.src, self.out, ["LICENSE", "LICENSE.3rdparty"])
        self.assertFalse(self.out.exists())

    def test_binary_rejected(self):
        (self.src / "LICENSE").write_bytes(b"fake archive header\x00" * 3)
        with self.assertRaises(ValueError):
            notices.copy_notices(self.src, self.out, ["LICENSE"])

    def test_upstream_page_break_preserved(self):
        data = self.data + b"\fThird-party notice on next page\n"
        (self.src / "LICENSE.3rdparty").write_bytes(data)
        notices.copy_notices(self.src, self.out, ["LICENSE.3rdparty"])
        self.assertEqual((self.out / "LICENSE.3rdparty").read_bytes(), data)

    def test_terminal_control_rejected(self):
        (self.src / "LICENSE").write_bytes(self.data + b"\x1b[2J")
        with self.assertRaises(ValueError):
            notices.copy_notices(self.src, self.out, ["LICENSE"])
        self.assertFalse(self.out.exists())

    def test_traversal_rejected(self):
        for name in ["../LICENSE", "/etc/passwd", "nested/LICENSE"]:
            with self.subTest(name=name), self.assertRaises(ValueError):
                notices.copy_notices(self.src, self.out, [name])

    def test_source_symlink_rejected(self):
        (self.src / "NOTICE").symlink_to(self.src / "LICENSE")
        with self.assertRaises(ValueError):
            notices.copy_notices(self.src, self.out, ["LICENSE"], ["NOTICE"])
        self.assertFalse(self.out.exists())

    def test_destination_symlink_preserves_target(self):
        self.out.mkdir()
        outside = self.root / "outside"
        outside.write_text("preserve")
        (self.out / "LICENSE").symlink_to(outside)
        with self.assertRaises(ValueError):
            notices.copy_notices(self.src, self.out, ["LICENSE"])
        self.assertEqual(outside.read_text(), "preserve")

    def boot_fixture(self):
        upstream = Path(__file__).resolve().parents[1] / "docs/licenses"
        shutil.copytree(upstream, self.src, dirs_exist_ok=True)
        manifest = self.src / "boot-components.json"
        data = json.loads(manifest.read_text())
        return manifest, data, data["source_iso"]["sha256"]

    def test_boot_exact_notice_set(self):
        manifest, data, digest = self.boot_fixture()
        self.assertEqual(notices.copy_boot_notices(self.src, self.out, digest), 7)
        self.assertEqual((self.out / manifest.name).read_bytes(), manifest.read_bytes())
        for item in data["notices"]:
            content = (self.out / item["file"]).read_bytes()
            self.assertEqual(content, (self.src / item["file"]).read_bytes())
            self.assertEqual(hashlib.sha256(content).hexdigest(), item["sha256"])

    def test_boot_wrong_iso_rejected(self):
        self.boot_fixture()
        with self.assertRaises(ValueError):
            notices.copy_boot_notices(self.src, self.out, "0" * 64)
        self.assertFalse(self.out.exists())

    def test_boot_incomplete_manifest_rejected(self):
        manifest, data, digest = self.boot_fixture()
        data["notices"].pop()
        manifest.write_text(json.dumps(data))
        with self.assertRaises(ValueError):
            notices.copy_boot_notices(self.src, self.out, digest)
        self.assertFalse(self.out.exists())

    def test_boot_tampered_notice_rejected(self):
        _, data, digest = self.boot_fixture()
        (self.src / data["notices"][-1]["file"]).write_bytes(self.data)
        with self.assertRaises(ValueError):
            notices.copy_boot_notices(self.src, self.out, digest)
        self.assertFalse(self.out.exists())

    def test_boot_traversal_rejected(self):
        manifest, data, digest = self.boot_fixture()
        data["notices"][0]["file"] = "../LICENSE"
        manifest.write_text(json.dumps(data))
        with self.assertRaises(ValueError):
            notices.copy_boot_notices(self.src, self.out, digest)
        self.assertFalse(self.out.exists())

    def test_boot_missing_notice_rejected(self):
        _, data, digest = self.boot_fixture()
        (self.src / data["notices"][-1]["file"]).unlink()
        with self.assertRaises(ValueError):
            notices.copy_boot_notices(self.src, self.out, digest)
        self.assertFalse(self.out.exists())


if __name__ == "__main__":
    result = unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(NoticeTests))
    failed = len(result.failures) + len(result.errors)
    print("通过 %d 项，失败 %d 项" % (result.testsRun - failed - len(result.skipped), failed))
    sys.exit(not result.wasSuccessful())
