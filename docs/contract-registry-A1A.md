# Contract Registry A1A — isolated database foundation

Status: **proposed PR only**. This migration has not been applied to the live Supabase project, and no UI or client registration code is included.

## Scope

- Three tenant/owner-scoped metadata tables: `akatsuki_contract_apps`, `akatsuki_contract_services`, `akatsuki_contract_versions`.
- Stable app/service keys, explicit identity realm declarations, offline-capability metadata, HTTPS-only discovery links, semantic API versions, and an owner-scoped service → version foreign key.
- Owner-only **SELECT** RLS for authenticated users. `anon` has no access; authenticated browser clients have **no insert, update or delete grant**. Registration write APIs come in A1B; review/publication workflow comes in A2.
- The owner UUID is an Akatsuki-registry account scope, **not** proof of shared identity across Supabase projects. No API keys, personal vocabulary, learning events or access tokens belong in these tables.
- A declared or published contract does **not** confer actual service permissions. The shared service retains its own authentication and RLS.

## Staging verification / release gate

1. Check out this PR against the latest `main`. Review `supabase/migrations/*_contract_registry_foundation.sql` and confirm all three table names are absent in staging.
2. Apply the additive migration to a **disposable staging database or development branch**, not to the live project.
3. Run `tests/contract-registry-a1a.sql` against staging. It uses synthetic accounts and rolls back all data inserts, and checks RLS, effective grants, cross-owner visibility and rejected browser writes.
4. Run `node tests/contract-registry-a1a.test.cjs` and existing JavaScript tests. Run Supabase security advisors against staging.
5. Confirm all existing Akatsuki reminder counts, event history, routes and application data are unchanged before production rollout.
6. Schedule a separate, explicitly approved production migration after PR review. Merging the repository branch does not establish a database deployment.

No generic browser CRUD grants are planned. A1B adds narrow owner-checked registration endpoints and read-only discovery. A2 adds immutable publication, proposal/review history and contract approval; A3 and A4 add dependencies and reporting in separate migrations.

## Reversal

Before any A1B clients or entries exist, these three new tables may be removed in reverse dependency order **only following an explicit approved rollback**. Do not automatically drop them in application startup or release scripts. Never roll back existing Akatsuki schemas or data.
