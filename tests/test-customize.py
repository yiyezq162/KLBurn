#!/usr/bin/env python3
"""Exercise the actual customization CLI against disposable Git repositories."""
import json
import hashlib
import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("builder", ROOT / "tools/customize/klburn-builder.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class CustomizeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.source = self.base / "original"
        (self.source / "build").mkdir(parents=True)
        for name in ("branding.json", "branding.py"):
            shutil.copy2(ROOT / "build" / name, self.source / "build" / name)
        (self.source / "build/config.sh").write_text('KLBURN_VERSION="1.11.0"\n', encoding="utf-8")
        (self.source / ".gitignore").write_text("vendor/\ntest_out/\n", encoding="utf-8")
        self.git("init", "-q")
        self.git("add", ".")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "-qm", "synthetic source fixture")
        self.original = self.git("rev-parse", "HEAD")
        self.workspace = self.base / "custom workspace"

    def git(self, *args, cwd=None):
        return subprocess.check_output(["git", *args], cwd=cwd or self.source, text=True).strip()

    def command(self, *extra):
        return subprocess.run([sys.executable, str(ROOT / "tools/customize/klburn-builder.py"),
                               "--source", str(self.source), "--ref", "HEAD",
                               "--workspace", str(self.workspace), "--backend", "prepare", *extra],
                              capture_output=True, text=True)

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        target = self.workspace / "source"
        self.assertEqual(self.git("status", "--porcelain", cwd=target), "")
        self.assertEqual(self.git("remote", cwd=target), "")
        self.assertEqual(self.git("rev-parse", "HEAD"), self.original)
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertIn("NOT_RUN", result.stdout)
        return target

    def test_default_brand_private_commit(self):
        target = self.assert_success(self.command())
        data = json.loads((target / "build/branding.json").read_text())
        self.assertEqual(data["display_name"], "KLBurn")
        self.assertTrue(data["custom"])
        self.assertIn("-custom.", (target / "build/config.sh").read_text())
        self.assertEqual(json.loads((target / "build/custom-build.json").read_text())["upstream_commit"], self.original)

    def test_chinese_space_and_injection_as_data(self):
        name = '示例 实验室 $(exit 9) <script> "'
        target = self.assert_success(self.command("--name", name, "--console-name", "Example Lab"))
        self.assertEqual(json.loads((target / "build/branding.json").read_text())["display_name"], name)

    def test_existing_workspace_preserved(self):
        self.workspace.mkdir()
        marker = self.workspace / "keep.txt"
        marker.write_text("preserve me")
        self.assertNotEqual(self.command().returncode, 0)
        self.assertEqual(marker.read_text(), "preserve me")

    def test_unsafe_console_refused(self):
        self.assertNotEqual(self.command("--console-name", "$(touch injected)").returncode, 0)
        self.assertFalse((self.source / "injected").exists())
        self.assertEqual(self.git("rev-parse", "HEAD"), self.original)

    def test_non_png_logo_refused(self):
        logo = self.base / "logo.svg"
        logo.write_text('<svg onload="alert(1)"/>')
        self.assertNotEqual(self.command("--logo", str(logo)).returncode, 0)

    def collected_fixture(self):
        version = "1.11.0-custom.012345abcdef"
        output_dir = self.base / "collected"
        receipt_path = output_dir / ("release-" + version) / "manifest.json"
        receipt_path.parent.mkdir(parents=True)
        artifacts = {}
        for edition, prefix in (("full", "KLBurn-"), ("mem", "KLBurn-MEM-")):
            name = prefix + version + "-20261015.iso"
            payload = ("synthetic " + edition).encode()
            digest = hashlib.sha256(payload).hexdigest()
            (output_dir / name).write_bytes(payload)
            (output_dir / (name + ".sha256")).write_text(digest + "\n")
            artifacts[edition] = {"file": name, "bytes": len(payload), "sha256": digest}
        receipt = {"version": version, "commit": self.original, "artifacts": artifacts}
        receipt_path.write_text(json.dumps(receipt))
        return output_dir, version, receipt_path, receipt

    def test_collected_pair(self):
        path, version, _, receipt = self.collected_fixture()
        self.assertEqual(builder.verify_collected(path, version, self.original), receipt)

    def test_empty_collection_rejected(self):
        with self.assertRaises(ValueError):
            builder.verify_collected(self.base, "1.11.0-custom.012345abcdef", self.original)

    def test_missing_edition_rejected(self):
        path, version, receipt_path, receipt = self.collected_fixture()
        del receipt["artifacts"]["mem"]
        receipt_path.write_text(json.dumps(receipt))
        with self.assertRaises(ValueError):
            builder.verify_collected(path, version, self.original)

    def test_wrong_commit_rejected(self):
        path, version, _, _ = self.collected_fixture()
        with self.assertRaises(ValueError):
            builder.verify_collected(path, version, "0" * 40)

    def test_tampered_bytes_rejected(self):
        path, version, _, receipt = self.collected_fixture()
        iso = path / receipt["artifacts"]["mem"]["file"]
        iso.write_bytes(b"x" * iso.stat().st_size)
        with self.assertRaises(ValueError):
            builder.verify_collected(path, version, self.original)

    def test_receipt_path_traversal_rejected(self):
        path, version, receipt_path, receipt = self.collected_fixture()
        receipt["artifacts"]["full"]["file"] = "../private.iso"
        receipt_path.write_text(json.dumps(receipt))
        with self.assertRaises(ValueError):
            builder.verify_collected(path, version, self.original)

    def test_remote_early_failure_preserves_session_log(self):
        self.workspace.mkdir()
        def fail(command, **kwargs):
            kwargs["stdout"].write(b"synthetic early backend failure\n")
            return subprocess.CompletedProcess(command, 1)
        with mock.patch.object(builder, "run"), mock.patch.object(builder.subprocess, "run", side_effect=fail):
            with self.assertRaises(ValueError):
                builder.build_ssh(SimpleNamespace(ssh="builder@example.invalid"), self.source, self.workspace)
        log = (self.workspace / "ssh-session.log").read_text()
        self.assertEqual(log.count("synthetic early backend failure"), 2)
        receipt = json.loads((self.workspace / "remote-build.json").read_text())
        self.assertEqual(receipt["session_log"], "ssh-session.log")
        self.assertEqual(self.git("status", "--porcelain"), "")


if __name__ == "__main__":
    result = unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(CustomizeTests))
    failed = len(result.failures) + len(result.errors)
    print("通过 %d 项，失败 %d 项" % (result.testsRun - failed - len(result.skipped), failed))
    sys.exit(not result.wasSuccessful())
