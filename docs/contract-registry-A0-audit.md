# Shared Application Contract Registry — A0 audit and design proposal

Status: **proposal only** (2026-11-15). No SQL, RPC, deployed UI, authorization, or production data changed.

## Evidence and baseline

- Repository `Celeritas7/Akatsuki`, `main` at `3f92a1e` (merged PR #30). PRs #26–#30 contain the existing stable task identity, action history, window/snooze engine, rule editor, and source-app reminder scheduling. None should be modified for this registry.
- `sql/akatsuki_schema_R001.sql`: `akatsuki_apps` identifies user-owned app cards; `akatsuki_vocab` defines **hub message kinds**, not language vocabulary; `akatsuki_routes` declares stream/view/direct routes; `akatsuki_sources` catalogs APIs that **Akatsuki fetches**, and `akatsuki_credentials` stores credential *names*. `akatsuki_requests`, `akatsuki_links`, `akatsuki_state`, `akatsuki_cache`, and the monotonic `akatsuki_seq` support existing hub workflows. Existing RLS scopes rows by `user_id`.
- `sql/akatsuki_logos_R049.sql`: `akatsuki_app_identity` maps an `app_key` to a user-scoped logo/home URL and optional `akatsuki_app_id`. This identity catalog is not an authorization registry.
- `index.html`: Hub has app cards, sources, credentials, routes and health findings. The eight-question linkability judgment is not an API-version compatibility check. The File a card flow uses `saveCard`; the contract UI should have a separate path and not alter this flow.
- A read-only inspection of the connected Supabase project on 2026-11-15 confirmed that the existing registry, routing, requests, links and identity tables are in use and have RLS enabled. Project identifiers, production row counts and user-level data are intentionally omitted from this public audit. This does **not** establish whether any particular language app is registered. No production writes were made.

## Gap assessment

| Need | Existing facility | Missing distinction |
| --- | --- | --- |
| Stable app identity | `akatsuki_apps`, `akatsuki_app_identity` | Cross-project immutable app key, aliases, account/identity realm metadata |
| Service discovery | `akatsuki_sources` | Independently operated service that clients call directly; not necessarily fetched/proxied by hub |
| Versioned contracts | `akatsuki_vocab.version` for event kinds | Immutable API spec revisions, compatibility range, breaking-change classification |
| Access requests | `akatsuki_routes` and `emits`/`accepts` | Requested vs approved vs **actually enforced** scopes; separate service authorization |
| Dependencies | Route links | App → service version constraint plus required/optional feature use |
| Health | Hub violations, source-fetch status, logo sync | Per app-service heartbeat, sync cursor age, error class and freshness |
| Audit | Request/violation history | Append-only proposals, review decisions, published revisions, supersessions |

Do **not** rename or reuse `akatsuki_vocab` for lexicon content, and do not reinterpret existing routes as grants. Retain the existing `akatsuki_apps` app cards and optional `akatsuki_app_identity` mapping; introduce separate namespace `akatsuki_contract_*` with stable global text keys and explicit links to existing IDs where verified. Avoid an enforced foreign key to a user-scoped app card until multiple-auth-realm ownership is established.

## Proposed A1–A4 data model (not executed)

All registry tables are owner/tenant scoped with RLS and explicit grants. Identifiers below are logical keys; migrations must pick constraints and indexes after inspecting live column and policy definitions.

| Logical table | Essential fields and purpose |
| --- | --- |
| `akatsuki_contract_apps` | `tenant_id`, `app_key`, display name, repository/home URL, identity realm(s), optional legacy card key, status. Stable `app_key`; never a human-readable title as primary identity. |
| `akatsuki_contract_services` | `tenant_id`, `service_key`, maintainer, discovery URL, independent endpoint metadata, auth-realm support, lifecycle. Do not store tokens, secrets or private endpoint credentials. |
| `akatsuki_contract_versions` | `tenant_id`, `service_key`, `contract_key`, immutable semantic version, spec JSON or digest/URI, publication status, declared API resources/operations, minimum clients, deprecation/sunset metadata. Published version is immutable. |
| `akatsuki_contract_requests` | `tenant_id`, `app_key`, `service_key`, version constraint, requested resource/operation/scope set, purpose, status (`draft/requested/reviewed/approved/rejected/withdrawn`), reviewer and timestamps. **Approval is a registry decision only, never an access grant.** |
| `akatsuki_contract_dependencies` | `tenant_id`, `app_key`, `service_key`, contract/version range, required/optional, feature flags, offline fallback, last compatibility verdict. No service → Akatsuki dependency. |
| `akatsuki_contract_health` | Owner-scoped current *reported* state: app/service/contract version, last attempt, last success, cursor age, sync mode, error code, reporter, report timestamp. Unknown/stale must not display as healthy. |
| `akatsuki_contract_events` | Append-only change history: actor, object/keys, event type, old/new digests or safe redacted metadata, timestamp, optional request correlation ID; do not store learning payloads or secrets. |

Consider a separate `contract_access_evidence` metadata record **only if** a service can safely attest an actual grant: authorization remains in that service, and a registry approval is never used as a JWT claim or RLS bypass. Discovery should be anonymously safe or authenticated as appropriate, but modifications and private reports must have tenant-scoped permissions. For multi-Supabase-project clients, resolve identities through explicit realm/provider + subject mappings or a trusted signed assertion; **never equate UUIDs across projects by coincidence**.

### Compatibility algorithm

1. Client declares supported contract key, semantic-version range, required operations, and optional capabilities.
2. Registry compares against immutable *published* versions and returns `compatible`, `degraded` (optional feature unavailable), `incompatible`, or `unknown` (missing evidence). Version range is necessary, **not sufficient**: required operations and auth mode must also match.
3. Breaking changes require a new major version and explicit dependent-app review. A deprecated version may remain compatible until its announced sunset.
4. Actual calls go directly to `shared-vocabulary`; the service independently validates identity, scopes, owner access, and RLS. Registry outage must not block a cached contract or direct service call.

### `shared-vocabulary` / `lex-v1` initial proposal

- `service_key`: `shared-vocabulary`; `contract_key`: `lex-v1`; initial release: `1.0.0-proposed` (not yet published or advertised as implemented).
- Resources: `languages`, `vocabulary`, `forms_readings`, `meanings_translations`, `source_id_mappings`, `lessons_media_refs`, `private_learning_evidence`, `sync_metadata`.
- Possible operations: `content.read` (authorized content), `progress.read_own`, `progress.write_own` (only if service later supports mutable progress), `learning_events.append_own`, `sync_metadata.read_own`. **Append-only** learning events must be idempotent and never overwritten by cross-app sync.
- Scopes are narrowly resource+operation specific. Public catalog reads and account-owned data access are distinct. An app's request does not grant access. Never expose service-role keys in an app bundle.
- Candidate pilot keys, pending confirmation against the actual repositories and auth integrations: `catalyst`, `kg-chart`, `burmese-study-advanced`, `japanese-study-advanced`, `chinese-study`, `chinese-study-simple`, `kata-kita`. These are **proposed registry keys, not verified registrations**.

## UI proposal

Add a distinct **Contracts** subsection to Hub; retain current app cards, Routes, Sources, Health and Reminders unchanged.

1. **Applications & services**: searchable cards with stable ID, project/identity realm, online/offline capability, owner and last observation.
2. **Contract library**: service → contract → published versions, resources and operations, deprecation notices, JSON/schema digest; draft revisions separated visually from published contracts.
3. **Access requests**: requested → reviewed → approved/rejected; clear warning: “Registry approval does not enable service access.”
4. **Dependencies**: app → service graph/table with range, compatible/degraded/incompatible/unknown status and affected apps for changes.
5. **Sync health & activity**: last success versus last attempt, stale/unknown indicators, per-integration errors, append-only contract decisions and version history.

Mobile: grouped service cards (start with `shared-vocabulary`), tap to reveal dependent apps, keep errors and versions legible; no map-like wall of all app nodes. Accessibility: textual status alongside color, keyboard navigable controls and readable timestamps.

## Incremental delivery and gates

- **A0 (this PR):** inventory/design only. No migration or UI changes.
- **A1:** additive isolated schema, owner RLS/GRANT review, read-only discovery and registration; synthetic tenant isolation tests. No vocabulary API assumption.
- **A2:** proposals, reviewer decision workflow, immutable version publication, append-only history; explicit distinction between approval and service grant.
- **A3:** dependency registration, contract range/capability comparison and change-impact UI; offline-safe last-known manifest.
- **A4:** opt-in signed/authorized health reporting, stale thresholds, sanitized error status and replay-safe event ingestion. No synchronization of vocabulary data inside Akatsuki.
- **A5:** only after the independently developed vocabulary service exposes its *real* versioned API: verify seven app repos and actual auth systems, register exact endpoints/capabilities, test direct access and offline behavior, and pilot one app first.

Every phase: separate PR, migrations staged and reversible, test in a nonproduction environment, confirm no existing task/reminder/user row changes, get explicit production rollout decision, and classify `implemented`, `merged`, `deployed` and `phone-tested` independently.

## Handoff contract to Shared Vocabulary Foundation

The Shared Vocabulary team owns its data model, auth/RLS, semantics, API implementation, sync protocol and actual grants. It should return to Akatsuki:

1. Canonical `service_key`, endpoint/discovery URL and auth realm(s) (no privileged keys).
2. `contract_key`, published version, machine-readable spec/digest and compatibility policy.
3. Exact resources and operations (including whether progress is mutable and whether events are append-only).
4. Account identity mapping strategy for apps using different Supabase projects, with authorization enforced by the service.
5. Stable vocabulary IDs and source-ID mapping behavior, event idempotency key, pagination/cursors and offline replay contract.
6. Optional sanitized health report format and service-side proof of access (not the registry's approval state).

Akatsuki will record app/service declarations, proposals, compatibility, dependencies and health but will **not** store canonical vocabulary or proxy normal vocabulary reads/writes. Applications call the vocabulary service directly and continue using cached contract metadata when Akatsuki is offline.
