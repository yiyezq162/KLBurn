#!/usr/bin/env python3
"""Brand input boundaries: actual shell roundtrip, not string matching."""
import importlib.util
import json
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("branding", ROOT / "build/branding.py")
branding = importlib.util.module_from_spec(spec)
spec.loader.exec_module(branding)


class BrandingTests(unittest.TestCase):
    def setUp(self):
        self.data = branding.load_brand(ROOT / "build/branding.json")

    def load(self, data):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "branding.json"
            path.write_text(json.dumps(data), encoding="utf-8")
            return branding.load_brand(path)

    def test_default_both_editions(self):
        for edition in ("full", "mem"):
            values = branding.constants(self.data, edition)
            self.assertEqual(values["COMPANY_NAME"], "KLBurn")
            self.assertEqual(values["BRAND_CUSTOM"], "0")
            self.assertEqual(len(values["BRAND_SHA256"]), 64)
        self.assertNotEqual(branding.constants(self.data, "full")["REPORT_TITLE"],
                            branding.constants(self.data, "mem")["REPORT_TITLE"])

    def test_chinese_spaces_and_shell_roundtrip(self):
        self.data.update(display_name="示例 实验室 ' \" $HOME $(exit 42) `exit 43` <script>", custom=True)
        data = self.load(self.data)
        for edition in ("full", "mem"):
            values = branding.constants(data, edition)
            script = "\n".join(k + "=" + shlex.quote(v) for k, v in values.items())
            script += '\nprintf "%s" "$COMPANY_NAME"'
            result = subprocess.check_output(["bash", "-c", script], text=True)
            self.assertEqual(result, self.data["display_name"] + "（定制构建）")

    def test_path_traversal_rejected(self):
        for value in ("../logo.png", "/tmp/a.png", "a/b.png", "https://example.com/a.png"):
            with self.subTest(value=value):
                self.data["logo"] = value
                with self.assertRaises(ValueError):
                    self.load(self.data)

    def test_controls_rejected(self):
        for value in ("x\ny", "x\x1by", "x\u202ey", "x\x00y"):
            with self.subTest(value=repr(value)):
                self.data["display_name"] = value
                with self.assertRaises(ValueError):
                    self.load(self.data)

    def test_console_input_rejected(self):
        for value in ("中文", "$(id)", "a'", "a" * 41, "-option"):
            with self.subTest(value=value):
                self.data["console_name"] = value
                with self.assertRaises(ValueError):
                    self.load(self.data)

    def test_digest_covers_identity(self):
        before = branding.constants(self.data, "full")["BRAND_SHA256"]
        self.data["display_name"] = "示例 实验室"
        self.assertNotEqual(before, branding.constants(self.data, "full")["BRAND_SHA256"])


if __name__ == "__main__":
    result = unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(BrandingTests))
    failed = len(result.failures) + len(result.errors)
    print("通过 %d 项，失败 %d 项" % (result.testsRun - failed - len(result.skipped), failed))
    sys.exit(not result.wasSuccessful())
