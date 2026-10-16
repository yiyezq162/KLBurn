#!/usr/bin/env python3
"""Exercise notice preservation and fail-closed root/version boundaries."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("package_notices", PROJECT / "build/package-notices.py")
notices = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notices)


class PackageNoticeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.root = self.base / "root"
        (self.root / "var/lib/dpkg").mkdir(parents=True)
        (self.root / "usr/share/doc").mkdir(parents=True)
        self.source = self.base / "notices"
        self.source.mkdir()
        self.data = b"Copyright Fictional upstream\nLicense and original notice.\n"
        self.iso = "a" * 64
        (self.source / "example.COPYRIGHT").write_bytes(self.data)
        self.index = {"schema": 1, "source_iso": {"sha256": self.iso}, "notices": [
            {"binary_package": "example", "binary_version": "1.0", "file": "example.COPYRIGHT",
             "sha256": hashlib.sha256(self.data).hexdigest()}]}
        self.save_index()
        self.status([("example", "1.0")])

    def save_index(self):
        (self.source / "base-packages.json").write_text(json.dumps(self.index))

    def status(self, packages):
        text = "\n\n".join("Package: %s\nVersion: %s\nStatus: install ok installed" % row for row in packages)
        (self.root / "var/lib/dpkg/status").write_text(text + "\n")

    def existing(self, package="example", data=None):
        directory = self.root / "usr/share/doc" / package
        directory.mkdir(exist_ok=True)
        (directory / "copyright").write_bytes(self.data if data is None else data)
        return directory / "copyright"

    def run_restore(self):
        return notices.restore(self.root, self.source, self.iso)

    def test_missing_exact_notice_restored_and_recorded(self):
        receipt = self.run_restore()
        self.assertEqual(receipt["installed_packages"], 1)
        self.assertEqual(receipt["restored_packages"], ["example"])
        self.assertEqual((self.root / "usr/share/doc/example/copyright").read_bytes(), self.data)
        self.assertEqual((self.root / "usr/share/doc/klburn/licenses/base-packages/example.COPYRIGHT").read_bytes(), self.data)

    def test_existing_newer_notice_not_overwritten(self):
        self.status([("example", "2.0")])
        target = self.existing(data=self.data + b"New version notice\n")
        self.assertEqual(self.run_restore()["restored_packages"], [])
        self.assertTrue(target.read_bytes().endswith(b"New version notice\n"))

    def test_unknown_missing_package_fails_before_any_write(self):
        self.status([("example", "1.0"), ("unknown", "1.0")])
        with self.assertRaises(ValueError):
            self.run_restore()
        self.assertFalse((self.root / "usr/share/doc/example").exists())

    def test_missing_wrong_version_rejected(self):
        self.status([("example", "2.0")])
        with self.assertRaises(ValueError):
            self.run_restore()

    def test_wrong_iso_rejected(self):
        with self.assertRaises(ValueError):
            notices.restore(self.root, self.source, "b" * 64)

    def test_tampered_original_rejected(self):
        (self.source / "example.COPYRIGHT").write_bytes(self.data + b"changed")
        with self.assertRaises(ValueError):
            self.run_restore()

    def test_source_symlink_rejected(self):
        path = self.source / "example.COPYRIGHT"
        path.unlink()
        path.symlink_to(self.base / "outside")
        with self.assertRaises(ValueError):
            self.run_restore()

    def test_duplicate_catalogue_package_rejected(self):
        self.index["notices"].append(dict(self.index["notices"][0]))
        self.save_index()
        with self.assertRaises(ValueError):
            self.run_restore()

    def test_catalogue_traversal_rejected(self):
        self.index["notices"][0]["file"] = "../outside"
        self.save_index()
        with self.assertRaises(ValueError):
            self.run_restore()

    def test_broken_leaf_replaced_not_its_destination(self):
        parent = self.root / "usr/share/doc/example"
        parent.mkdir()
        (parent / "copyright").symlink_to("../obsolete/copyright")
        self.assertEqual(self.run_restore()["restored_packages"], ["example"])
        self.assertFalse((parent / "copyright").is_symlink())
        self.assertFalse((self.root / "usr/share/doc/obsolete").exists())

    def test_relative_doc_directory_link_accepted_read_only(self):
        self.existing("shared")
        (self.root / "usr/share/doc/example").symlink_to("shared")
        self.assertEqual(self.run_restore()["restored_packages"], [])

    def test_absolute_doc_link_uses_target_not_host(self):
        self.existing("shared")
        (self.root / "usr/share/doc/example").symlink_to("/usr/share/doc/shared")
        self.assertEqual(self.run_restore()["readable_notices"], 1)

    def test_common_license_link_accepted(self):
        common = self.root / "usr/share/common-licenses"
        common.mkdir()
        (common / "Example").write_bytes(self.data)
        parent = self.root / "usr/share/doc/example"
        parent.mkdir()
        (parent / "copyright").symlink_to("/usr/share/common-licenses/Example")
        self.assertEqual(self.run_restore()["packages"][0]["path"], "usr/share/common-licenses/Example")

    def test_broken_directory_link_not_written_through(self):
        (self.root / "usr/share/doc/example").symlink_to("missing-shared")
        with self.assertRaises(ValueError):
            self.run_restore()
        self.assertFalse((self.root / "usr/share/doc/missing-shared").exists())

    def test_link_to_host_file_not_read_or_modified(self):
        outside = self.base / "outside"
        outside.write_bytes(b"Do not read as an ISO license or modify\n")
        parent = self.root / "usr/share/doc/example"
        parent.symlink_to(outside.parent)
        with self.assertRaises(ValueError):
            self.run_restore()
        self.assertEqual(outside.read_bytes(), b"Do not read as an ISO license or modify\n")

    def test_existing_link_outside_doc_tree_rejected(self):
        (self.root / "etc").mkdir()
        (self.root / "etc/not-a-notice").write_bytes(self.data)
        parent = self.root / "usr/share/doc/example"
        parent.mkdir()
        (parent / "copyright").symlink_to("/etc/not-a-notice")
        with self.assertRaises(ValueError):
            self.run_restore()

    def test_link_loop_rejected(self):
        (self.root / "usr/share/doc/example").symlink_to("example")
        with self.assertRaises(ValueError):
            self.run_restore()

    def test_virtual_root_escape_rejected(self):
        parent = self.root / "usr/share/doc/example"
        parent.mkdir()
        (parent / "copyright").symlink_to("../../../../../outside")
        with self.assertRaises(ValueError):
            self.run_restore()

    def test_empty_existing_notice_rejected(self):
        self.existing(data=b"")
        with self.assertRaises(ValueError):
            self.run_restore()

    def test_duplicate_installed_package_rejected(self):
        self.status([("example", "1.0"), ("example", "1.0")])
        with self.assertRaises(ValueError):
            self.run_restore()

    def test_empty_installed_denominator_rejected(self):
        self.status([])
        with self.assertRaises(ValueError):
            self.run_restore()

    def test_host_root_and_root_symlink_rejected(self):
        with self.assertRaises(ValueError):
            notices.restore(Path("/"), self.source, self.iso)
        alias = self.base / "alias"
        alias.symlink_to(self.root)
        with self.assertRaises(ValueError):
            notices.restore(alias, self.source, self.iso)

    def test_sidecar_symlink_prevents_partial_repair(self):
        sidecar = self.root / "usr/share/doc/klburn"
        sidecar.symlink_to(self.base)
        with self.assertRaises(ValueError):
            self.run_restore()
        self.assertFalse((self.root / "usr/share/doc/example").exists())

    def test_real_catalogue_byte_hashes_and_known_base_versions(self):
        source = PROJECT / "docs/licenses/base-packages"
        rows = notices.catalogue(source, "e907d92eeec9df64163a7e454cbc8d7755e8ddc7ed42f99dbc80c40f1a138433")
        self.assertEqual(len(rows), 14)
        self.assertEqual(rows["openssl"][0]["binary_version"], "3.0.13-0ubuntu3.7")

    def test_build_hook_precedes_squashfs_and_follows_chroot(self):
        source = (PROJECT / "build/build-iso.sh").read_text()
        hook = source.index('python3 "$SCRIPT_DIR/package-notices.py"')
        self.assertGreater(hook, source.index('log "chroot 定制完成"'))
        self.assertLess(hook, source.index('step "5/9 打包 squashfs'))


if __name__ == "__main__":
    result = unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(PackageNoticeTests))
    failed = len(result.failures) + len(result.errors)
    print("通过 %d 项，失败 %d 项" % (result.testsRun - failed - len(result.skipped), failed))
    sys.exit(not result.wasSuccessful())
