#!/usr/bin/env python3
"""Synthetic receipt/server fixtures test metadata gates, not actual publication."""
import copy
import hashlib
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("metadata", ROOT / "tools/update-site-release.py")
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)


class MetadataTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.folder = Path(self.tmp.name)
        base = {"version": "1.11.0", "commit": "a" * 40, "artifacts": {}}
        self.iso = copy.deepcopy(base)
        self.tools = copy.deepcopy(base)
        self.iso["private_internal_marker"] = "DO_NOT_EXPORT"
        self.remote = {"tag_name": "v1.11.0", "draft": False, "prerelease": True,
                       "published_at": "2026-10-15T01:00:00Z", "html_url": metadata.BASE + "tag/v1.11.0", "assets": []}
        names = {"full": "KLBurn-1.11.0-20261015.iso", "mem": "KLBurn-MEM-1.11.0-20261015.iso"}
        names.update({p: "KLBurn-Builder-" + p + "-1.11.0.zip" for p in ("Windows", "macOS", "Linux")})
        for kind, name in names.items():
            payload = ("synthetic-not-an-ISO-" + kind).encode()
            (self.folder / name).write_bytes(payload)
            digest = hashlib.sha256(payload).hexdigest()
            receipt = self.iso if kind in ("full", "mem") else self.tools
            receipt["artifacts"][kind] = {"file": name, "bytes": len(payload), "sha256": digest}
            self.remote["assets"].append({"name": name, "size": len(payload), "state": "uploaded",
                                           "digest": "sha256:" + digest,
                                           "browser_download_url": metadata.BASE + "download/v1.11.0/" + name})

    def export(self):
        return metadata.export_release(self.iso, self.tools, self.remote, self.folder, self.folder)

    def test_allowlist_and_prerelease(self):
        result = self.export()
        self.assertTrue(result["prerelease"])
        self.assertEqual(set(result), {"version", "commit", "date", "prerelease", "url", "assets"})
        self.assertEqual(set(result["assets"]), metadata.KINDS)
        self.assertNotIn("DO_NOT_EXPORT", repr(result))

    def test_server_digest_required(self):
        self.remote["assets"][0]["digest"] = None
        with self.assertRaises(ValueError): self.export()

    def test_local_corruption_rejected(self):
        (self.folder / self.iso["artifacts"]["full"]["file"]).write_bytes(b"changed")
        with self.assertRaises(ValueError): self.export()

    def test_commit_mismatch_rejected(self):
        self.tools["commit"] = "b" * 40
        with self.assertRaises(ValueError): self.export()

    def test_draft_and_wrong_tag_rejected(self):
        self.remote["draft"] = True
        with self.assertRaises(ValueError): self.export()
        self.remote["draft"] = False
        self.remote["tag_name"] = "v1.10.7"
        with self.assertRaises(ValueError): self.export()

    def test_hold_and_bad_link_rejected(self):
        with self.assertRaises(ValueError):
            metadata.validate({"schema": 1, "publication_ready": False, "releases": []})
        self.remote["assets"][0]["browser_download_url"] = "https://example.invalid/download.iso"
        with self.assertRaises(ValueError): self.export()

    def test_wrong_edition_name_rejected(self):
        result = self.export()
        result["assets"]["mem"] = result["assets"]["full"]
        with self.assertRaises(ValueError):
            metadata.validate({"schema": 1, "publication_ready": True, "releases": [result]})


if __name__ == "__main__":
    result = unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(MetadataTests))
    failed = len(result.failures) + len(result.errors)
    print("通过 %d 项，失败 %d 项" % (result.testsRun - failed - len(result.skipped), failed))
    sys.exit(not result.wasSuccessful())
