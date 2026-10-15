#!/usr/bin/env python3
"""Notice preservation and file boundaries; no compiler required."""
import importlib.util
from pathlib import Path
import sys
import tempfile
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


if __name__ == "__main__":
    result = unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(NoticeTests))
    failed = len(result.failures) + len(result.errors)
    print("通过 %d 项，失败 %d 项" % (result.testsRun - failed - len(result.skipped), failed))
    sys.exit(not result.wasSuccessful())
