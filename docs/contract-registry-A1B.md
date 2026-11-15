# A1B — metadata registration and service discovery

Status: **PR implementation only; not deployed**. The A1A database tables were not present in the live project at the time this work began; do not apply A1B before A1A and its staging validation.

## New operations

- `akatsuki_contract_register('app' | 'service', metadata_json)` inserts a **proposed**, owner-scoped metadata record. Repeated stable keys return `already_registered` and never overwrite existing entries. Edits and approvals require future A2 review/history. This is a self-declaration, **not verified app identity** or a service permission grant.
- The `AkatsukiContractRegistry(authenticatedAkatsukiSupabaseClient)` JavaScript helper exposes `registerApp`, `registerService`, `listApps`, `listServices`, `listContracts(serviceKey)`.
- Discovery uses the A1A owner-SELECT tables. `listContracts` returns only published/deprecated records, not drafts. No normal vocabulary reads/writes go through Akatsuki.
- The security-definer registration function has a fixed empty search path, checks `auth.uid()` and a strict metadata allowlist, inserts only rows owned by that user, denies unknown/privileged fields, and exposes EXECUTE only to `authenticated`. No generic browser table write grant is introduced.
- `identity_realms` declares provider labels, not tokens or proof of cross-project identity. Distinct Supabase accounts are **not** linked by UUID equality.

## Usage sketch (after deployment)

```js
const registry = AkatsukiContractRegistry(akatsukiSupabaseClient);
await registry.registerApp({app_key:'catalyst',name:'Catalyst',offline_capable:false});
await registry.registerService({service_key:'shared-vocabulary',name:'Shared Vocabulary'});
const services = await registry.listServices(); // owned declarations, proposed included
const published = await registry.listContracts('shared-vocabulary'); // [] until A2 publishes
```

## Release gate

1. Stage A1A then A1B in an isolated database/branch. Run their RLS/rollback SQL tests and Supabase database advisors, including SECURITY DEFINER exposure review.
2. Verify two signed-in users cannot discover each other's entries or overwrite registrations; anon cannot invoke the function.
3. Verify repeated registration is idempotent; invalid/unknown fields are rejected; no existing Akatsuki tasks, broadcasts, routes or history change.
4. Check `node tests/contract-registry-a1b.test.cjs` plus prior regression tests.
5. Get an explicit production deployment decision. GitHub merge alone does not run the migrations; A1A remains a prerequisite.

No Contracts UI, contract publication/approval, compatibility computation or active vocabulary integration is claimed by A1B. The next batch A1C will add the Hub display after a safe database rollout.
