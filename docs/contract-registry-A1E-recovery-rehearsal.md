# Contract Registry A1E — Isolated recovery rehearsal and security gate

**Status: NO-GO.** This is a nonproduction runbook and staging-only test plan, not permission to deploy SQL. Keep all backups private. No production data, user-level rows, bucket object keys, tokens or passwords belong in this public repository.

## What has been checked

- The 2026-11-22 private General_apps database archive, separate roles SQL file and Storage ZIP match the SHA-256 values in their saved checksum files.
- The database archive is a PostgreSQL custom-format dump from PostgreSQL 17.6, produced with pg_dump 18.1. The available TOC inventory lists 4,290 entries and representative Akatsuki/auth/Storage database objects.
- Storage ZIP integrity passed; the private manifest lists seven buckets and 409 objects with matching per-object sizes and SHA-256 hashes. The database and Storage captures **are not atomic**.
- As of the last connected read-only catalog check, A1A/A1B were absent from the live General_apps database. Their source migration sequence remains A1A foundation, followed by A1B registration.
- **No full isolated PostgreSQL restore has passed.** A matching hash and readable TOC do not prove the database is restorable.

## Required environment (no billable Supabase branch)

Use a trusted Windows PC with a **genuinely local, isolated PostgreSQL server** and compatible Supabase dependencies. The PostgreSQL client tools alone (pg_dump or pg_restore) do not provide a server. An isolated local Supabase stack may be needed because the dump includes Supabase-specific schemas, roles, policies and extensions. Do not install Docker, upgrade a hosted project, or create a paid preview branch as part of this plan without the owner's decision.

**Safety preconditions:**

1. Disconnect any local port-forwarding or SSH tunnels to production. Do not use production connection strings, passwords or the production pooler.
2. Confirm you are connecting to a local server on 127.0.0.1, not a hosted project. Use a unique disposable database named with prefix **akatsuki_a1e_restore_**.
3. The target database MUST be newly created and empty. Do not use the default postgres database as the restoration target. **Never use --clean or --create against a shared database.**
4. Limit file access to your Windows account: the dump contains potentially sensitive login and application data.
5. Capture logs privately and share only pass/fail summaries; no real user rows or credentials.

## Steps for a local rehearsal

### 1. Verify backup bytes before restore

Download all relevant files from the private General_apps backup folder, including the database dump and checksum, roles SQL and checksum, and Storage ZIP and checksum. Keep them in one private parent folder (the script searches subfolders).

Run the already merged, nonconnecting script (from the Akatsuki repository root):

~~~powershell
$BackupRoot = 'C:\Path\To\Private\General_apps_Backup_2026-11-22'
.\tools\verify-contract-registry-A1E-backup.ps1 -BackupRoot $BackupRoot -ReadEntireDump
~~~

Every SHA-256 comparison must pass. The optional archive stream must complete successfully. This is **not** a restore.

### 2. Verify your local PostgreSQL destination

The examples below are for a **local** server only. Adjust the local PostgreSQL port if needed. These commands are instructions for the owner to run on their own isolated PC, **not executed by this PR**.

~~~powershell
$LocalHost = '127.0.0.1'
$LocalPort = 5432
$LocalUser = 'postgres'
$ScratchDb = 'akatsuki_a1e_restore_20261124'
$Dump = 'C:\Path\To\Private\General_apps.dump'

psql --version
pg_restore --version
psql -h $LocalHost -p $LocalPort -U $LocalUser -d postgres -X -Atc "select inet_server_addr(), current_database(), current_user, version();"
~~~

**STOP** unless the destination is a verified local, isolated PostgreSQL installation; an SSH tunnel can make a remote server look like localhost.

### 3. Create a new local database and try a full restore

Only after verifying the local destination:

~~~powershell
createdb -h $LocalHost -p $LocalPort -U $LocalUser $ScratchDb
pg_restore -h $LocalHost -p $LocalPort -U $LocalUser -d $ScratchDb --no-owner --no-privileges --single-transaction --exit-on-error --verbose $Dump
if ($LASTEXITCODE -ne 0) { throw 'Isolated restore FAILED: do not mark A1E GO.' }
~~~

No live project is contacted, and no existing database is dropped. If this fails due to missing Supabase roles, extensions, privileges or objects, **STOP** and record the failure; do not suppress errors or mark the restore PASS. Rehearse again only after building a compatible *local* environment. A plain PostgreSQL installation may not be sufficient.

### 4. Check representative recovered structures (locally, without exporting user rows)

~~~powershell
psql -h $LocalHost -p $LocalPort -U $LocalUser -d $ScratchDb -X -v ON_ERROR_STOP=1 -c "select to_regclass('public.akatsuki_tasks') as tasks, to_regclass('auth.users') as auth_users, to_regclass('storage.objects') as storage_metadata;"
~~~

Examine locally whether Akatsuki tasks, reminders/broadcasts, existing functions, owner RLS policies and cross-app dependencies were restored; compare representative counts against a saved predeployment baseline. A structurally successful restore with missing required extensions or incomplete data is still **NO-GO**. Backup Storage object **bytes** must be handled separately from the database's storage.objects metadata.

### 5. Test the registry migrations in this isolated database

Only after the isolated restore is genuinely successful and the environment is compatible:

~~~powershell
psql -h $LocalHost -p $LocalPort -U $LocalUser -d $ScratchDb -X -v ON_ERROR_STOP=1 -f .\supabase\migrations\20261115073011_contract_registry_foundation.sql
psql -h $LocalHost -p $LocalPort -U $LocalUser -d $ScratchDb -X -v ON_ERROR_STOP=1 -f .\supabase\migrations\20261115073735_contract_registry_registration.sql
psql -h $LocalHost -p $LocalPort -U $LocalUser -d $ScratchDb -X -v ON_ERROR_STOP=1 -f .\tests\contract-registry-a1a.sql
psql -h $LocalHost -p $LocalPort -U $LocalUser -d $ScratchDb -X -v ON_ERROR_STOP=1 -f .\tests\contract-registry-a1b.sql
psql -h $LocalHost -p $LocalPort -U $LocalUser -d $ScratchDb -X -v ON_ERROR_STOP=1 -f .\tests\contract-registry-a1e-security.sql
~~~

The A1E security test includes an early database-name guard, tests synthetic tenant isolation, denied browser table writes, anonymous execution denial, allowed authenticated registration, duplicate idempotence and a privileged-field rejection; it rolls back all of its synthetic data. It **must never be run on production**.

### 6. Document evidence privately

Record the local server version, full-restore exit code, missing extension/role errors (if any), representative object-presence checks, staged migration outcomes, synthetic RLS test outcomes, and remaining Storage recovery caveats. Do **not** publish the restored database, user row counts, passwords or private logs.

Do not automatically delete the scratch database after a failed test; preserve failure evidence until reviewed. Any eventual removal of a scratch database must be a separate, deliberate local action.

## Read-only security disposition to complete

The existing shared-project security advisor reports 34 anonymously executable SECURITY DEFINER warnings across General_apps; 16 carry an Akatsuki-prefixed function name. A catalog review shows one of the 16 is a trigger-returning function and the other 15 refer to auth.uid(); some verify a null owner explicitly, some scope data writes by owner identity. This reduces certain anonymous-access concerns, but the individual privilege boundaries and potential SQL injection/logic paths **have not all been proven safe**. There are also function-search-path warnings, public-schema extensions, RLS-without-policy notices and leaked-password protection configuration warnings.

A1A/A1B's new registry design is owner-scoped and additive on paper, but the actual RLS and SECURITY DEFINER behavior must pass the *isolated* tests above. Classify preexisting warnings based on demonstrated exploitability and whether they affect registry authorization; do **not** bulk-revoke existing app RPCs or alter production to silence lints.

## Gate summary

- [x] Database/roles/Storage backup bytes matched saved checksums
- [x] A1A -> A1B order reviewed, production absence checked
- [x] New isolated security test prepared
- [ ] Complete successful full isolated restore (including required dependencies)
- [ ] Storage recovery limits addressed / explicitly accepted
- [ ] Run and pass A1A/A1B/A1E stage tests
- [ ] Resolve or formally disposition any material security blockers
- [ ] Reconfirm live baseline and authorized rollback plan
- [ ] Obtain explicit owner approval for **A1F** before any live SQL

**Final A1E decision is still NO-GO.** Work on A2–A5 may be designed on separate branches, but deployment must not skip A1E/A1F gates.
