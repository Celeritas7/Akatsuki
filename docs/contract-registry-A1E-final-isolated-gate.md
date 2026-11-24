# Contract Registry A1E — Isolated restoration and security acceptance

**NO-GO: A1F is not authorized.** This document supports the remaining A1E review only. It changes no production database, Supabase plan, or existing Akatsuki application code.

## Evidence checked

- The private November 22 General_apps dump, database roles file, and Storage ZIP each matched their saved SHA-256 digest.
- The Storage ZIP passed CRC validation; all 409 stored object payloads matched the manifest hashes and sizes. The original database and Storage captures are *not atomic*.
- Five synthetic Python backup-verifier tests passed. PostgreSQL archive parsing and a full isolated database restore are **not yet demonstrated** in the current execution environment.
- General_apps currently has no A1A/A1B migration history entries, contract registry tables, or registration RPC. Re-check immediately before any approved production rollout.
- The shared-project Security Advisor currently reports 34 anonymous-definer function notices, 63 authenticated-definer notices, 36 mutable search paths, 3 extensions in public, 3 RLS tables lacking policies, and leaked-password protection disabled. Categories overlap; these are not all confirmed vulnerabilities.
- Sixteen anonymously executable SECURITY DEFINER functions have Akatsuki-prefixed names. Fifteen reference auth.uid() and one is a trigger function; these facts alone **do not constitute a full security sign-off**. Do not bulk-revoke existing legacy RPC permissions and break reminders, locations, or linked applications.

## 1. Check the Windows machine first — no database changes

Check whether a local PostgreSQL server is installed **in addition to the client utilities**:

~~~powershell
Get-Command pg_restore, psql, postgres, initdb, pg_ctl -ErrorAction SilentlyContinue |
  Select-Object Name, Source
Test-Path "$env:ProgramFiles\PostgreSQL\17\bin\postgres.exe"
~~~

A client-only installation is not sufficient for a restore rehearsal. PostgreSQL server 17 with the needed Supabase roles/extensions, or a compatible isolated local Supabase stack, is required. **Do not** create a paid cloud branch or upgrade General_apps. If no compatible local server exists, STOP: A1E stays NO-GO.

## 2. Verify the private backup again

In an Akatsuki repository checkout, using the private backup directory on your trusted computer:

~~~powershell
python -m unittest discover -s tests -p test_a1e_verify_backup.py -v
python tools/a1e_verify_backup.py --root "C:\private\General_apps_Backup_2026-11-22" --require-pg-restore --deep-dump-read
~~~

This only reads files; it does not restore or connect to a server. Keep the dump, SHA files, Storage ZIP, roles SQL, file paths, passwords, and restore logs outside the public repository.

## 3. Restore ONLY to a disposable local PostgreSQL environment

Before running any pg_restore database write, the operator must verify all of the following:

- The target is an empty, disposable local database named with the **akatsuki_a1e_** prefix, on a server physically controlled by the operator.
- Its connection really terminates locally, not in a tunnel or proxy to a cloud Supabase project.
- The local PostgreSQL version, Supabase extensions, schemas and roles can accept the backup.
- The target is **not** the live General_apps or Technical database, nor any other real-user database.
- An isolated restore procedure, without destructive --clean/--create flags against existing databases, is agreed in advance.

Record restore exit codes, warnings, installed objects, data row counts and the result of representative Akatsuki tasks, reminders, routes, and connected-app checks in a **private** log. A missing extension or failed restore object is a **failure pending investigation**, not permission to patch production.

Separately test representative Storage object restoration to disposable local storage with matching metadata. The non-atomic capture limitation needs an explicit recovery decision.

## 4. Test registry permissions in the isolated database

Only after the **local** restore is verified, apply the merged A1A migration and then A1B to the disposable test copy. Run the existing A1A/A1B SQL tests, followed by the new isolated-only acceptance test:

~~~powershell
node tests/contract-registry-a1e-isolated-gate.test.cjs
psql -h 127.0.0.1 -p 5432 -U postgres -d akatsuki_a1e_scratch -v ON_ERROR_STOP=1 -f tests/contract-registry-a1e-isolated-gate.sql
~~~

The SQL test explicitly refuses non-scratch database names or non-loopback server addresses. **Loopback is not sufficient by itself**; confirm there is no port-forward first. It checks owner-select RLS policies, browser table grants, registration RPC access, duplicate handling, anonymous denial, invalid fields and cross-owner isolation. Synthetic records are rolled back at the end.

The Node test validates SQL safety structure only; it is **not** a substitute for actually running the SQL against the isolated PostgreSQL database.

## Final decision / hard stop

A1E can be declared **GO** only after real isolated recovery, representative integrity checks, isolated A1A/A1B role tests, risk disposition of registry-relevant security findings, and a documented rollback plan. Get the owner's **separate explicit approval** before A1F deploys any SQL to General_apps. Continue A2-A5 only under their own reviewed gates.
