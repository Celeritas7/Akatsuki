# Akatsuki — founding rules

Akatsuki is the hub. Apps talk to Akatsuki, never to each other. This file is the
contract; paste it into any app project that joins.

## Naming
Every Supabase object Akatsuki owns is prefixed `akatsuki_` — tables, views, functions,
sequences, policies. No exceptions.

## Edges flexible, core rigid
- Akatsuki **adapts to** an app's *shape*: its address, its clock, its pattern, its
  private fields. Stored opaque, never renegotiated.
- An app **conforms to** Akatsuki's *contract*: one insert to publish, one cursor read to
  consume, payloads validated against `akatsuki_vocab`, shared enums read from vocab
  (never a local copy), an owner declared per shared path before the first write.
- Never write what you didn't just read. Publish on real change only, or two apps
  ping-pong forever.

## The card — 11 lines, filed before any adapter is written
Address · Clock · Trust · Emits · Accepts · Mapping · Owns · Deletes · Private · Session · Reach.
Six questions judge it: stable address? change signal? known pattern? payload map?
owned paths? reach? API sources add a seventh: secret resolved server-side?
An app that passes links to anything — including apps that don't exist yet.

## Three patterns — every link fits one, or the list is incomplete (not the app)
- **stream** — discrete addressable items. `akatsuki_requests`.
- **document** — one shared document, shredded into owned rows. `akatsuki_state`.
- **reply** — a request the target answers in place. `akatsuki_requests.reply`.

## Three ways to reach another app's data
- **stream** (brokered copy) — when there are change events, merges or deletes.
- **view** (`akatsuki_*` view over the provider's table, `security_invoker = on`, owned by
  Akatsuki) — read-only reference data, no conflict, zero copy.
- **direct** table read — never, going forward. Existing ones are flagged `defect` in
  `akatsuki_routes` until re-homed.

## Clocks
No app clock is trusted. `akatsuki_seq` orders everything. App clocks are recorded on
the row for diagnosis only. WF's `subtasks[].u` and Calendar/Sukkiri `updated_at` are
client-set and do not move on flag changes — proven Sep 21.

## Deletion is orphaning
A link whose origin is gone gets `orphaned_at` set. The row is kept. Nothing cascades
across apps.

## Failure is skipping
`ON CONFLICT DO NOTHING`, reported as `skipped`. A pass never aborts mid-flight. The
Sep 21 duplicate-folder race came from the opposite behaviour.

## Single-flight is server-side
`pg_advisory_xact_lock` per (user, app) inside `akatsuki_publish`. Tab-scoped guards do
not survive reloads, redirects or a second device.

## Security
RLS on every table: `user_id = auth.uid()`, `TO authenticated`. Views carry
`security_invoker = on` or they bypass RLS. Secrets live in Vault and are referenced by
name in `akatsuki_credentials`; a key that ships in a client bundle is `location =
'client_bundle'` and flagged. Service-role callers scope `user_id` themselves.

## Sources (external APIs)
A source is a card with `accepts = {}`. Pull on a policy, cache in `akatsuki_cache`, serve
every consumer from the cache. Never synchronous passthrough — the hub must not sit in
any app's render path.

## The same-origin trap
Apps on different ports do not share localStorage. Supabase, signed in as the same user,
is the only cross-app path. Akatsuki does not create an offline one. Say this in every
launch doc.

## Design
Scriptura design system, loaded from `_ds/`. Red-moon atmosphere flares on live
conflicts. Emoji are the icon system. Outfit is the only UI face.
