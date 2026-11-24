# A1E — Isolated recovery rehearsal (no production operations)

**Gate: NO-GO until an isolated restore is actually completed and security sign-off is recorded.** This document continues the merged A1E assessment. It does **not** authorize A1F, SQL deployment, Supabase upgrades, paid database branches, changes to production, or merging.

## What has actually passed

The privately supplied November 22 General_apps backup was independently checked:

- Custom-format database dump: saved SHA-256 matches the downloaded bytes; PGDMP header present.
- Separate database roles SQL: saved SHA-256 matches.
- Storage ZIP: saved SHA-256, ZIP CRC, all 409 stored object sizes and per-object hashes match.
- Storage manifest lists seven buckets (four with backed-up objects), and its before/after inventory is identical.

**These are integrity checks, not a restore.** The database and Storage files were captured at different times; the manifest explicitly marks the snapshot non-atomic and the Storage restore as pending. A backup does not automatically contain provider-level authentication settings, Edge Function secrets, or cloud configuration.

## A. Repeat the non-destructive checks on Windows

Only if you have privately downloaded the original General_apps backup folder onto a trusted computer:

1. Use the free Python installation already on the PC (Anaconda Python is fine). Run in the Akatsuki repository checkout:

   ~~~powershell
   python -m unittest discover -s tests -p test_a1e_verify_backup.py -v
   python tools/a1e_verify_backup.py --root "C:\path\to\private\General_apps_Backup_2026-11-22"
   ~~~

2. If pg_restore is on PATH, run the stronger archive read (still no connection to any database):

   ~~~powershell
   python tools/a1e_verify_backup.py --root "C:\path\to\private\General_apps_Backup_2026-11-22" --require-pg-restore --deep-dump-read
   ~~~

3. The tool never accepts a remote host, database URL, or password; it only reads private local files. A PASS confirms checksum/manifest/inventory/archive-read integrity. It **does not** mark A1E GO.

Do not upload the dumps, Storage archive, roles SQL, SHA files, inventory, personal data or private restore logs to this **public** GitHub repository.

## B. Recovery rehearsal — still to be performed

**Isolation is mandatory:** Use a disposable local database or fully isolated local Supabase-compatible stack. The live General_apps and Technical Supabase projects are both forbidden restore targets. Do not use any project that has real application data, even as a temporary restore destination.

Prerequisites:

- Local PostgreSQL/Supabase environment compatible with the backed-up PostgreSQL 17 schema, extensions, service roles and permissions, with disk space to restore.
- A written inventory of required extensions and privileged database roles; a stock PostgreSQL install may lack Supabase-specific extensions and produce misleading restore failures.
- A recovery operator who has verified that all hostnames and targets point only to loopback/disposable infrastructure. Never paste a production database connection URL into a restore command.
- Review whether roles SQL contains privileged grants before loading it in a disposable environment.
- No charges, provider upgrades, or cloud branches enabled without explicit permission.

Perform the rehearsal **only after** those local prerequisites exist and have been checked. Record in a **private** log:

1. Source archive date, format, PostgreSQL major version and digest verification.
2. Target PostgreSQL version and isolated target identifier; **confirm not General_apps or Technical**.
3. Restore result, errors/warnings and object count; no unexplained object or data failures accepted.
4. Representative checks for existing Akatsuki tasks, reminders, history, routes, app identities, functions, RLS policies, owner scoping, authentication and foreign-key consistency.
5. Separately rehearse restoration of a small selection of Storage payloads into **disposable local storage**, confirming correct metadata and bytes without overwriting any live bucket.
6. Document missing provider-level configuration and the effect of the non-atomic DB/Storage capture. Decide whether any gap is acceptable before declaring GO.

Post-restore isolated tests (after staging A1A then A1B **in the isolated database only**) include:

- tests/contract-registry-a1a.sql and tests/contract-registry-a1b.sql using synthetic users and rollback.
- Verify owner-only SELECT and absence of browser table writes.
- Verify anonymous RPC is denied, cross-owner reads are denied, duplicate registration is idempotent, invalid metadata is rejected.
- Ensure unrelated legacy tables/row counts and Akatsuki reminder/task workflows are unaffected.

## C. Security risk disposition before GO

The shared production project currently reports warnings involving 34 anonymous and 63 authenticated SECURITY DEFINER function exposures, 36 mutable function search paths, 3 public-schema extensions, 3 no-policy RLS tables and leaked-password protection. **Flags overlap and are not proof of exploitability.**

A targeted **read-only** inspection identified 16 anonymous-executable Akatsuki-prefixed SECURITY DEFINER routines. Fifteen refer to auth.uid(); the remaining one returns trigger, rather than being a normal directly callable business RPC. Existing routines should be checked for owner enforcement, privilege escalation, and function search-path safety before any changes. A separate read-only catalog query found neither anonymous nor authenticated roles can CREATE in public, mitigating one search-path risk. Do **not** mass-revoke EXECUTE; some routines support existing location, task and reminder features.

A1B's proposed registration RPC is authenticated-only, owner-scoped, has an empty fixed search path and validates an allowlist. Its effective permissions still require an isolated staging test. Registry declarations never grant service access or prove cross-project identity.

Before final sign-off, classify each relevant finding as **blocker**, **tested mitigation**, or **separately tracked hardening** with rationale. If a critical exploit path remains, A1E is NO-GO.

## D. Production deployment lock

The production registry tables and A1B RPC were absent when last checked, and the recorded migration history did not include A1A/A1B. Reconfirm **immediately before any future release**; the migration history alone is not sufficient to prove an object was never created manually.

A1F must run A1A **before** A1B, with an approved backup/rollback plan and post-deployment RLS tests. It requires explicit owner approval in a separate step. No GitHub PR merge is permission to deploy SQL.

**Current disposition: A1E NO-GO.** Read-only integrity checks PASS. Full isolated restore and focused authorization tests remain open. After A1E GO, request separate permission for A1F; continue A2–A5 afterward.
