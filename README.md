# Akatsuki — the hub

Akatsuki is the broker between independent apps in one Supabase project. Apps talk to
the hub, never to each other. Every table, function, view and sequence is prefixed
`akatsuki_`.

## Layout

```
Akatsuki.dc.html            the app (Channel · Board · Standing · Hub)
support.js                  runtime for .dc.html
js/akatsuki-client.js       the SDK every app drops in — publish / consume / put / reply
js/config.js                SUPABASE_URL + anon key (fill in)
sql/akatsuki_schema_R001.sql  schema · RLS · RPCs · seed
_ds/                        Scriptura design system bundle
run-akatsuki-local.bat      serves on :8092
CLAUDE.md                   the founding rules — paste into any app joining the hub
```

## Launch

1. Supabase → SQL editor → run `sql/akatsuki_schema_R001.sql`. Idempotent.
   The seed names the owner uuid explicitly (auth.uid() is null in the editor) — change
   it if yours differs.
2. Fill `js/config.js`.
3. `run-akatsuki-local.bat` → http://localhost:8092/Akatsuki.dc.html → Hub tab → sign in
   (magic link, same account as your other apps). Without config the Hub shows the seed.

## An app joins in five steps

1. **File its card** — Hub tab → *File a card*, or a row in `akatsuki_apps`. Six
   questions decide linkability: address · signal · pattern · mapping · owners · reach.
2. **Add its kinds** to `akatsuki_vocab` (`ns='kind'`) with the required payload fields.
3. **Add a route** in `akatsuki_routes` — the hub rejects publishes with no route.
4. **Drop in the SDK:**
   ```html
   <script src="…/js/akatsuki-client.js"></script>
   <script>
     const hub = Akatsuki(supabase, 'travel');
     // on real change only — never on every save
     hub.publish({ to: 'cal', kind: 'trip.segment', addr: { trip_id, segment_id }, payload, clock: updated_at });
     // consumer side: one loop, one case per kind
     hub.listen({ 'trip.segment': async r => ({ addr: { event_id: upsertEvent(r.payload) } }) });
   </script>
   ```
5. **Sign in as the same user.** RLS is `user_id = auth.uid()` everywhere. Anon sees `[]`.

## Three patterns

- **stream** — discrete items. `akatsuki_requests` + `akatsuki_cursors` + `akatsuki_links`.
- **document** — one shared doc shredded into `akatsuki_state` rows with an `owner_app`.
  A trigger rejects writes from anyone but the owner. Read back via the `akatsuki_docs` view.
- **reply** — a stream row whose target writes `reply`; origin reads `hub.replies()`.

## What the hub does that apps no longer do

Orders by its own `akatsuki_seq` (no app clock is trusted) · dedupes on
`idempotency_key` with `ON CONFLICT DO NOTHING` · single-flights per app with
`pg_advisory_xact_lock` · validates kind, emits, accepts and route before insert ·
keeps orphaned links instead of deleting · caches source fetches once for all consumers.

## What it cannot do

Bridge two origins offline. :8080 and :8091 do not share localStorage; no table changes
that. Akatsuki improves the signed-in path; it does not create an offline one.
