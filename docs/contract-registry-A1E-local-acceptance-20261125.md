# Akatsuki Contract Registry A1E — Local acceptance update (2026-11-25)

**Disposition: PARTIAL PASS / PRODUCTION NO-GO.**
This is a sanitized evidence update to the existing A1E readiness/recovery documents, not authorization to deploy A1A/A1B to General_apps or change Supabase subscription, production configuration, or other apps.

## Completed in a local, isolated PostgreSQL 17 scratch database

The operator confirmed the connection was to PostgreSQL 17 at 127.0.0.1:5433 and the disposable database was named `akatsuki_a1e_scratch`. It was created as a local copy of an existing **nonproduction** restored General_apps database, not from a live Supabase production connection.

1. A1A foundation migration completed with psql `ON_ERROR_STOP=1 -1` and exit code **0**, creating the three registry tables with RLS and owner SELECT policies.
2. Direct privilege inspection of all three tables confirmed RLS ON, anonymous SELECT OFF, authenticated SELECT ON, authenticated INSERT/UPDATE/DELETE OFF.
3. A1B registration migration completed with exit code **0**. Its RPC uses `SECURITY DEFINER`, a fixed empty `search_path`, and authenticated-only EXECUTE grants.
4. The optional SQL acceptance gate (`tests/contract-registry-a1e-isolated-gate.sql`) reached `ROLLBACK` with exit code **0** after correction in merged PR #40. It exercised simulated owner A/B isolation, anonymous execution denial, direct table-write denial, duplicate idempotency, metadata rejection and registration without a JWT subject. **These are role/JWT-claim simulations, not a full live Supabase Auth login test.**
5. Four pre-existing Akatsuki tables — applications, connections, reminders and tasks — were compared between the restored local source and scratch database. All **4/4** row counts were identical, and all **4/4** deterministic JSONB/MD5 content fingerprints matched. Fingerprints are suitable here to detect accidental data changes; they are not a cryptographic attestation of full recovery. This does **not** attest to every table, provider configuration, or live-production freshness.

The first acceptance-gate run produced a false negative due to the PostgreSQL 17 catalog encoding of `SET search_path = ''` as `search_path=""`. PR #40 corrected the test assertion to parse `pg_proc.proconfig` using `pg_options_to_table` while still checking `SECURITY DEFINER`. The corrected gate passed. The A1B migration itself was **not changed**.

## Read-only General_apps observations

A fresh read-only check found **none** of the three Contract Registry tables or the A1B registration function on production, and neither A1A nor A1B in the recorded migration history. Before any future authorized production rollout, independently re-check the catalog and migration history because manually applied SQL need not appear in migration history.

The shared-project Security Advisor continues to report:

| Finding | Count | Current disposition |
| --- | ---: | --- |
| Anonymous-executable SECURITY DEFINER routines | 34 | Existing shared-project concern; focused routine-by-routine owner/privilege review or explicit risk acceptance required |
| Authenticated-executable SECURITY DEFINER routines | 63 | Review reachable RPCs and owner enforcement; no bulk revocation |
| Mutable function search paths | 36 | Track affected routines and actual exploitability; do not assume all exploitable |
| Extensions in public | 3 | Track and evaluate compatibility/security implications |
| RLS enabled without a policy | 3 | Check intended default-deny behavior for affected tables |
| Leaked-password protection disabled | 1 | Separate authentication hardening decision |

These categories overlap and are **advisory warnings, not all demonstrated vulnerabilities**. None of these findings was introduced by production A1A/A1B, which remain undeployed. The new A1A/A1B paths passed isolated synthetic tests, but the existing Akatsuki RPC estate is not yet certified safe. Preserve reminder/task/location/link integrations; do not mass-revoke existing functions.

## Still required before A1E GO

- [ ] Confirm which parts of the local restore were successfully recovered and inventory any unresolved restore errors, missing Auth records/roles, extensions, FK validation or Supabase provider-level configuration. The scratch **clone** plus four-table comparison is not a fresh end-to-end restore rehearsal.
- [ ] Perform a **disposable local Storage recovery sample** and verify recovered payload bytes and database metadata; or explicitly accept and record the inability to rehearse it. The existing DB and Storage backup captures were **not atomic**.
- [ ] Record missing/recoverable Supabase Auth settings, Edge Functions, secrets and external configuration. Do not publish any private backup, tokens, account IDs or restore logs.
- [ ] Finish focused security risk disposition for Akatsuki's pre-existing callable functions, plus full Auth/session/owner-boundary testing or a justified scoped acceptance.
- [ ] Capture deployment-time baselines and an owner-approved narrow A1A-then-A1B release/stop/rollback plan; recheck schema and migration history immediately beforehand.
- [ ] Obtain **separate, explicit user approval** before any A1F SQL deployment or production permission changes.

### Decision

A1A and A1B are **locally functional and passed the isolated acceptance gate**. Data-preservation checks passed for the four monitored Akatsuki tables. **A1E remains NO-GO for A1F** while recovery gaps and broader security sign-off remain unclosed. It is safe to continue no-cost, read-only/local-only checks. A documentation PR merge is not production deployment authorization.
