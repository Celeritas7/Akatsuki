"""Synthetic-fixture tests: never use real backups, credentials or a database."""
import importlib.util
import io
import json
from contextlib import redirect_stdout, redirect_stderr
from pathlib import Path
import tempfile
import unittest
from zipfile import ZIP_DEFLATED, ZipFile
import hashlib

MODULE_PATH = Path(__file__).resolve().parents[1] / "tools" / "a1e_verify_backup.py"
spec = importlib.util.spec_from_file_location("a1e_verify_backup", MODULE_PATH)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def write_fixture(root, object_digest_valid=True, same_inventory=True):
    d = root / "General_apps.dump"
    d.write_bytes(b"PGDMP" + b"synthetic-only")
    roles = root / "General_apps.roles-test.sql"
    roles.write_text("--synthetic-only", encoding="utf-8")
    payload = b"hello synthetic object"
    inv = {"project_ref": "dummy-local", "buckets": [{"id": "test"}], "objects": [{"id": "1"}]}
    manifest = {
        "format": "general-apps-storage-backup", "project_name": "General_apps",
        "project_ref": "dummy-local", "bucket_count": 1, "object_count": 1,
        "stable_inventory_match": True, "atomic_database_snapshot": False,
        "actual_restore_test": "pending", "total_bytes": len(payload),
        "objects": [{"local_path": "objects/000001.bin", "bytes": len(payload),
                     "sha256": hashlib.sha256(payload if object_digest_valid else b"wrong").hexdigest()}]
    }
    z = root / "General_apps_storage_test.zip"
    with ZipFile(z, "w", compression=ZIP_DEFLATED) as archive:
        archive.writestr("manifest.json", json.dumps(manifest))
        archive.writestr("inventory-before.json", json.dumps(inv))
        archive.writestr("inventory-after.json", json.dumps(inv if same_inventory else {**inv, "objects": []}))
        archive.writestr("objects/000001.bin", payload)
    for f in [d, roles, z]:
        Path(str(f) + ".sha256").write_text(f"{sha(f)}  {f.name}\n", encoding="utf-8")
    return d, roles, z


class BackupVerifierTests(unittest.TestCase):
    def run_check(self, root):
        out = io.StringIO()
        with redirect_stdout(out), redirect_stderr(out):
            status = module.main(["--root", str(root)])
        return status, out.getvalue()

    def test_valid_fixture_passes_but_not_a_restore(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            write_fixture(root)
            status, output = self.run_check(root)
            self.assertEqual(status, 0, output)
            self.assertIn("not a restore or production GO", output)
            self.assertIn("Storage ZIP CRC", output)

    def test_checksum_tamper_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            dump, _, _ = write_fixture(root)
            dump.write_bytes(dump.read_bytes() + b"changed")
            status, output = self.run_check(root)
            self.assertEqual(status, 1)
            self.assertIn("Checksum mismatch", output)

    def test_storage_payload_hash_mismatch_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            write_fixture(root, object_digest_valid=False)
            status, output = self.run_check(root)
            self.assertEqual(status, 1)
            self.assertIn("object length or hash mismatch", output)

    def test_inventory_drift_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            write_fixture(root, same_inventory=False)
            status, output = self.run_check(root)
            self.assertEqual(status, 1)
            self.assertIn("before/after inventory mismatch", output)

    def test_non_custom_dump_is_rejected_even_with_matching_hash(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            dump, _, _ = write_fixture(root)
            dump.write_bytes(b"not-a-dump")
            Path(str(dump) + ".sha256").write_text(f"{sha(dump)}  {dump.name}\n")
            status, output = self.run_check(root)
            self.assertEqual(status, 1)
            self.assertIn("custom format", output)


if __name__ == "__main__":
    unittest.main()
