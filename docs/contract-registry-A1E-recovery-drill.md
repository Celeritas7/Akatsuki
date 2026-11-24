# Akatsuki Contract Registry A1E — Isolated recovery rehearsal

**Status: recovery drill not yet executed. This file is a procedure, not evidence of a successful restore.**

This runbook continues [A1E readiness](contract-registry-A1E-readiness.md) after the November 22, 2026, private `General_apps` backup was checked. Do not deploy A1A/A1B until the recovery and security gates are complete, and then request separate explicit approval for A1F.

## Backup evidence and limitations

- A private custom-format PostgreSQL archive (71,806,611 bytes), roles SQL (6,024 bytes), and Storage ZIP (28,466,325 bytes) were fetched and independently compared against their saved SHA-256 digests: **MATCH**.
- The PostgreSQL archive inventory produced at backup creation reports **4,290 TOC entries** and includes representative Akatsuki task, Auth, and Storage database objects.
- The Storage ZIP passes CRC checks. Its manifest declares **7 buckets**, **409 objects** and 27,273,176 object bytes. Independent verification found **409/409 matching size and SHA-256 payloads**.
- The Storage manifest explicitly records `actual_restore_test: pending` and `atomic_database_snapshot: false`. The database and Storage objects were not captured at the same atomic instant.
- Backup integrity is **not** equivalent to successful restoration or guaranteed complete service recovery. Database dumps do not contain Storage object payloads; backups also do not by themselves reproduce Supabase Auth settings, Edge Functions, external secrets, providers or hosted configuration.

**Never** commit private backup files, individual Storage object keys, passwords, tokens, archive manifests or production connection strings to this public repository or to pull-request logs.

## A. Free read-only checks on the owner's Windows PC

These steps **do not** write to or connect to any database. Run them from a trusted private computer after downloading the complete backup folder from Drive:

```powershell
cd C:\path\to\Akatsuki
$backupRoot = Join-Path $env:USERPROFILE 'Downloads\General_apps_Backup_2026-11-22'
.\tools\verify-contract-registry-A1E-backup.ps1 -BackupRoot $backupRoot -ReadEntireDump
```

The script validates checksums, uses `pg_restore --list` to inspect the archive and, with `-ReadEntireDump`, streams the full archive to the Windows NUL device. This is a **full archive read**, *not* a restore.

Expected: all three checksum matches; archive TOC includes representative Akatsuki and Auth data entries; full stream succeeds. If `pg_restore` is missing or any command errors, capture the failure and stop. Never paste secrets into the output.

## B. Full isolated PostgreSQL restore — prerequisites

A full recovery test needs an **existing isolated, private, nonproduction** PostgreSQL/Supabase-compatible environment. It must be entirely separate from `General_apps` and `Technical` production and cannot introduce charges or expose live user records.

Before attempting any restore, verify and record:

1. The target is **localhost** or a separately authorized isolated test server, not a Supabase project URL or pooler.
2. The target is **empty**, has dedicated credentials, is not publicly reachable and has outbound network calls blocked. A restored database may contain cron definitions, triggers or integration functions; do not allow restored production integrations to send notifications, network requests or emails.
3. PostgreSQL version is compatible with the archive source (dumped from PostgreSQL **17.6**, using `pg_dump` **18.1**) and a matching `pg_restore` is installed. Check local binaries with `pg_restore --version` and `psql --version`.
4. Required Supabase-managed roles, extensions and schemas can be provided safely in the test environment. A generic vanilla PostgreSQL installation may be insufficient; missing extensions or role privileges invalidate a full-restore PASS.
5. A separately approved test database name such as `akatsuki_a1e_rehearsal` is available. **Never** use `postgres` on the production host. Do not reuse an existing local database containing user data.
6. The user accepts that restoring private Auth and application data to the isolated machine means the recovered files and database must be protected and later deleted securely.

**No full restoration has been attempted in this task.** The execution environment available for A1E currently has no PostgreSQL server or `pg_restore` binary. Do not create a paid cloud instance or install Docker as an unapproved substitute.

## C. Restoration drill (only after B is satisfied)

1. Record local target identity, PostgreSQL version, extensions and network isolation. Use explicit `--host 127.0.0.1`, a dedicated local test port and a dedicated new database. **Do not** rely on `PGHOST`, `DATABASE_URL` or any cloud connection variables.
2. Review the archive TOC and roles SQL privately before applying any restored database objects. Restore to the isolated **empty** target, capturing a private log and exit code. If Supabase-managed extensions/roles fail, mark **BLOCKED**, not PASS. Do not downgrade errors to warnings.
3. Confirm representative **schema, data, foreign keys, triggers, functions, owners, RLS policies and effective grants**. Checking only that `pg_restore` exited is insufficient.
4. Verify restoration of existing Akatsuki reminders, shared tasks, routes, request history, application connections and other shared application schemas. Compare **counts and aggregate summaries** against securely recorded pre-deployment baselines; do not publish user-level values.
5. Restore or validate Storage objects and metadata in the isolated environment, with no outbound connectivity. Verify that file references resolve; identify objects changed between the non-atomic database and Storage captures.
6. Verify authenticated/anonymous role behavior with synthetic accounts, not real-user logins. Execute the existing A1A/A1B SQL tests **only in disposable staging after A1A then A1B have been applied there**; also execute `tests/contract-registry-a1e-permissions.sql`.
7. Review all errors, differences, permission failures and unresolved settings. A failure in a required restore capability is a NO-GO.

A partial table-only restore or `--no-owner --no-privileges` smoke test can be useful diagnostic evidence but **cannot be counted as complete recovery**, because it does not prove owner/grant/RLS preservation.

## D. Proof needed for an A1E GO

- [x] Private dump, roles and Storage backups present; their downloaded hashes match saved digests.
- [x] All 409 Storage objects checked; ZIP CRC passes.
- [ ] Full PostgreSQL archive streamed successfully with `pg_restore` (no server connection).
- [ ] Actual restore to an isolated Supabase-compatible target succeeds without unreviewed required errors.
- [ ] Representative Akatsuki and other shared application data match secure baselines.
- [ ] Restored RLS/grants and synthetic tenant separation verified.
- [ ] Storage recovery and non-atomic capture mismatch risks tested/accepted explicitly.
- [ ] Registry A1A/A1B staged in correct order, independently security-tested and rollback rehearsed.
- [ ] Existing elevated-function security warnings reviewed and disposition signed off.
- [ ] Separate explicit approval received before A1F production SQL.

Until all hard requirements pass: **A1E = NO-GO, A1F = not authorized**.
