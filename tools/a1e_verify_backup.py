#!/usr/bin/env python3
"""Read-only A1E backup integrity preflight; does not connect to PostgreSQL.

A real database restoration in an isolated environment is still required for GO.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
from zipfile import ZipFile


class BackupError(Exception):
    pass


def one(root: Path, glob: str) -> Path:
    matches = [p for p in root.rglob(glob) if p.is_file()]
    if len(matches) != 1:
        raise BackupError(f"Expected one {glob!r}, found {len(matches)}")
    return matches[0]


def file_digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def check_checksum(path: Path) -> None:
    candidates = [Path(str(path) + suffix) for suffix in (".sha256", ".sha256.bin")]
    if path.name.endswith(".bin"):
        without_bin = Path(str(path)[:-4])
        candidates += [Path(str(without_bin) + suffix) for suffix in (".sha256", ".sha256.bin")]
    candidates = [c for c in candidates if c.is_file()]
    if len(candidates) != 1:
        raise BackupError(f"Missing or ambiguous checksum for {path.name}")
    value = candidates[0].read_text(encoding="utf-8-sig").strip().split()[0]
    if not re.fullmatch(r"[a-fA-F0-9]{64}", value):
        raise BackupError(f"Invalid checksum format for {path.name}")
    if file_digest(path).casefold() != value.casefold():
        raise BackupError(f"Checksum mismatch for {path.name}")
    print(f"PASS: {path.name}: SHA-256 match ({path.stat().st_size:,} bytes)")


def check_dump(path: Path, require_tools: bool, deep: bool) -> None:
    with path.open("rb") as stream:
        if stream.read(5) != b"PGDMP":
            raise BackupError("Database dump is not PostgreSQL custom format (PGDMP)")
    executable = shutil.which("pg_restore")
    if not executable:
        if require_tools or deep:
            raise BackupError("pg_restore unavailable: install free local PostgreSQL tools first")
        print("SKIP: pg_restore archive parse (tool unavailable)")
        return
    result = subprocess.run([executable, "--list", str(path)], capture_output=True, text=True)
    if result.returncode:
        raise BackupError(f"pg_restore --list failed (exit {result.returncode})")
    for name in ("TABLE DATA public akatsuki_tasks", "TABLE DATA auth users"):
        if name not in result.stdout:
            raise BackupError(f"Expected archive inventory object missing: {name}")
    print("PASS: pg_restore inventory includes representative Akatsuki and auth data")
    if deep:
        # -f discards the locally generated SQL/data stream. No -d or DB credentials.
        result = subprocess.run([executable, "--file", os.devnull, str(path)], capture_output=True)
        if result.returncode:
            raise BackupError(f"pg_restore archive stream failed (exit {result.returncode})")
        print("PASS: full archive stream read without a database connection")


def safe_member(name: str) -> bool:
    p = PurePosixPath(name)
    return not (name.startswith("/") or "\\" in name or ".." in p.parts or "" in p.parts)


def check_storage(path: Path) -> None:
    with ZipFile(path) as archive:
        names = archive.namelist()
        if len(set(names)) != len(names) or not all(safe_member(n) for n in names):
            raise BackupError("Unsafe or duplicate ZIP members")
        if archive.testzip() is not None:
            raise BackupError("Storage ZIP CRC verification failed")
        required = {"manifest.json", "inventory-before.json", "inventory-after.json"}
        if not required.issubset(names):
            raise BackupError("Storage manifest/inventory files missing")
        manifest = json.loads(archive.read("manifest.json"))
        before = json.loads(archive.read("inventory-before.json"))
        after = json.loads(archive.read("inventory-after.json"))
        if (manifest.get("format") != "general-apps-storage-backup"
                or manifest.get("project_name") != "General_apps"):
            raise BackupError("Unexpected Storage backup format or project")
        if not manifest.get("stable_inventory_match"):
            raise BackupError("Storage backup reports unstable before/after inventory")
        if manifest.get("project_ref") != before.get("project_ref") or manifest.get("project_ref") != after.get("project_ref"):
            raise BackupError("Storage backup project identifier inconsistency")
        for key in ("buckets", "objects"):
            if before.get(key) != after.get(key):
                raise BackupError("Storage before/after inventory mismatch")
        objects = manifest.get("objects")
        if not isinstance(objects, list) or len(objects) != manifest.get("object_count"):
            raise BackupError("Storage manifest object count mismatch")
        if len(before.get("buckets", [])) != manifest.get("bucket_count"):
            raise BackupError("Storage bucket inventory count mismatch")
        total = 0
        seen = set()
        for entry in objects:
            name = entry["local_path"]
            if not name.startswith("objects/") or not safe_member(name) or name not in names or name in seen:
                raise BackupError("Missing, duplicate or unsafe object payload")
            seen.add(name)
            h = hashlib.sha256()
            length = 0
            with archive.open(name) as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    length += len(chunk)
                    h.update(chunk)
            if length != entry["bytes"] or h.hexdigest().casefold() != entry["sha256"].casefold():
                raise BackupError("Storage object length or hash mismatch")
            total += length
        if total != manifest.get("total_bytes"):
            raise BackupError("Storage total payload length mismatch")
        print(f"PASS: Storage ZIP CRC and {len(objects)} object hashes; {manifest['bucket_count']} buckets")
        if manifest.get("atomic_database_snapshot") is not True:
            print("NOTE: PostgreSQL and Storage captures are NOT atomic")
        if manifest.get("actual_restore_test") != "passed":
            print("BLOCKER: Storage restore test not demonstrated")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path, help="Local, private backup directory")
    parser.add_argument("--require-pg-restore", action="store_true")
    parser.add_argument("--deep-dump-read", action="store_true", help="Read archive fully; no DB connection")
    args = parser.parse_args(argv)
    try:
        root = args.root.resolve(strict=True)
        if not root.is_dir():
            raise BackupError("--root is not a directory")
        dumps = [p for p in root.rglob("General_apps.dump*")
                 if p.is_file() and p.name in ("General_apps.dump", "General_apps.dump.bin")]
        if len(dumps) != 1:
            raise BackupError(f"Expected one General_apps.dump; found {len(dumps)}")
        dump = dumps[0]
    except (OSError, BackupError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    try:
        roles = one(root, "General_apps.roles-*.sql")
        zips = [p for p in root.rglob("General_apps_storage_*.zip") if p.is_file()]
        if len(zips) != 1:
            raise BackupError(f"Expected one Storage ZIP; found {len(zips)}")
        storage = zips[0]
        for path in (dump, roles, storage):
            check_checksum(path)
        check_dump(dump, args.require_pg_restore, args.deep_dump_read)
        check_storage(storage)
        print("A1E integrity preflight completed: not a restore or production GO")
    except (BackupError, OSError, ValueError, KeyError, TypeError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
