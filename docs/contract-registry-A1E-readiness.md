# Contract Registry A1E — Deployment prerequisites and recovery gate

**Status: NO-GO (2026-11-22 UTC).** This is a sanitized, read-only assessment. Nothing in this report authorizes production migration execution.

## Baseline and migration sequence

- Target: the existing **General_apps** Supabase project. The Technical project is separate.
- The latest inspected Akatsuki `main` contains:
  1. `supabase/migrations/20261115073011_contract_registry_foundation.sql` (**A1A**, owner-scoped metadata tables, RLS, SELECT grants).
  2. `supabase/migrations/20261115073735_contract_registry_registration.sql` (**A1B**, proposed app/service registration RPC, narrow authenticated EXECUTE).
- A1B **requires A1A**. Never reverse the order or apply them in parallel.
- The connected project's migration history did **not** include either registry migration when checked for this report. A separate prior read-only catalog check found no registry tables or registration function. Re-check schema presence and migration history immediately before any future A1F decision; manually applied SQL might not appear in migration history.
- A1C is already merged. Its read-only Hub UI must remain safe when the schema is unavailable and must not generate example records or registration writes.
- Existing reminders, snooze windows, shared tasks, app links, routing, health, histories, browser storage and unrelated app tables are outside A1A/A1B scope and MUST be preserved.

## Private backup integrity evidence (do not attach backups or credentials to public issues/PRs)

Private **2026-11-22** General_apps backup materials were inspected without connecting a restore operation to production:

| Item | Evidence | Result |
| --- | --- | --- |
| Custom-format database dump | 71,806,611 bytes; downloaded SHA-256 matches its separately stored checksum; header `PGDMP` | **PASS — matching bytes** |
| Database object inventory | Existing archive inventory reports 4,290 TOC entries and includes Akatsuki task tables and auth/Storage metadata | **PASS — inventory available** |
| Database roles SQL | 6,024 bytes; downloaded SHA-256 matches saved checksum | **PASS — matching bytes** |
| Storage backup ZIP | 28,466,325 bytes; ZIP SHA-256 matches saved checksum; CRC check passes | **PASS — matching bytes** |
| Storage manifest | Seven buckets, 409 objects; **all 409** payload sizes and per-object SHA-256 digests match; pre/post inventory was stable | **PASS — payload checks** |
| Complete isolated PostgreSQL restore | No restore completed with an appropriately compatible nonproduction PostgreSQL/Supabase environment | **BLOCKER — not tested** |
| Atomic DB + Storage capture | The Storage manifest explicitly says the captures are not one atomic snapshot | **LIMITATION** |

A matching checksum proves integrity relative to the saved digest, **not** that the original capture is complete or restorable. The Storage ZIP holds object payloads; database dumps alone do not include Storage object bytes. Auth configuration, Edge Functions, secrets and other provider settings need separate recovery documentation. Never publish the private manifests, dumps, file keys, or backup locations.

## Current security review — read-only

Supabase security advisor findings on the shared project: three RLS-enabled/no-policy informational notices, 36 mutable function search-path warnings, three extensions in public, 34 anonymously executable SECURITY DEFINER function warnings, 63 signed-in SECURITY DEFINER warnings, and one leaked-password protection warning. Categories can overlap, and flags are **not** automatically demonstrated vulnerabilities.

Targeted catalog inspection found 16 anonymously executable Akatsuki-prefixed SECURITY DEFINER functions. One is a trigger-returning function; the other 15 reference `auth.uid()`. Examples examined use owner scoping or explicit sign-in checks. `anon` and `authenticated` cannot CREATE in the `public` schema. This reduces certain risks but **does not complete a full authorization/security review**. In particular, do not assume every definer is safe just because it mentions `auth.uid()`, and do not bulk-revoke RPC permissions that existing reminders, locations, tasks, or integrations rely on.

**Registry-specific A1B code inspection:** the registration function checks `auth.uid()`, uses a fixed empty search path, enforces an input allowlist and owner-scoped proposed records, and grants EXECUTE to authenticated only. Its SECURITY DEFINER behavior needs owner/anonymous/cross-tenant testing in an isolated environment and post-deployment permission verification. Registry declarations are not service grants and cannot equate user IDs across projects.

Security disposition before GO:
- Review each registry path for owner scope, injected identifiers, anonymous access, RLS bypass and effective grants.
- Verify the A1A owner SELECT policies and absence of browser INSERT/UPDATE/DELETE grants.
- Verify A1B denies anonymous execution, forbids duplicates/privileged fields, and never mutates existing app tables.
- Classify preexisting advisor findings as blocking, mitigated, or separate tracked debt based on actual exploitability and impact. No automatic production-wide permission revocation.
- Confirm the exact deployment objects do not introduce new unreviewed advisor warnings.

## GO criteria before A1F

- [x] Separate private database and Storage archives exist and their saved checksums match.
- [x] Storage manifest payload digests and ZIP CRC verified.
- [x] A1A then A1B order and source files independently inspected.
- [x] Current recorded migration history checked.
- [ ] Successfully **restore** the database in an isolated nonproduction environment compatible with the source database; check representative Akatsuki records, functions, grants and RLS there.
- [ ] Document the scope and limitations of Storage recovery, including restore test or an explicitly accepted limitation.
- [ ] Complete the focused security risk disposition and synthetic tenant-isolation/anonymous-access tests.
- [ ] Capture predeployment application and database baselines; validate no existing reminder, task, route, registration or history objects will be changed.
- [ ] Reconfirm schema/migration state, deployment window, verified rollback plan and recovery owner.
- [ ] Request and obtain explicit owner approval **before** any production A1F SQL.

## A1F stop / rollback criteria (plan only)

Apply A1A and A1B separately **only after GO and explicit approval**. If A1A fails, stop and inspect actual catalog/transaction state; do not run A1B. If A1B fails, do not delete A1A tables automatically; investigate and preserve newly written registry data. For an approved narrow rollback, disable registry access appropriately, remove A1B RPC after dependency review, and only then consider removing registry version → service → app tables if empty or separately preserved. Never automatically drop legacy Akatsuki tables, auth objects, reminders or Storage. Full disaster recovery uses the independently verified backup and runbook rather than an untested production restore.

**Deployment verdict: NO-GO until recovery rehearsal, risk disposition and explicit user authorization.** Next after A1F: separate reviewable A2, A3, A4 and A5 work.
