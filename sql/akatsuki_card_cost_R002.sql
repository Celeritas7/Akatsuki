-- ============================================================================
-- Akatsuki R002 — Cost Management joins the hub.
--
-- Run AFTER akatsuki_schema_R001.sql, in the same project (wylxvmkcrexwfpjpbhyy).
-- Idempotent: safe to re-run.
--
-- Three parts:
--   A. prerequisite — give the shared item a change signal (cost_management_expenses)
--   B. hub learns Cost: vocab (kinds + enums), the card, routes, credentials
--   C. what is deliberately NOT opened yet, and the one line that opens it
--
-- Card source: Cost Management's own reply, 2026-09-22. Anything the app could not
-- answer from its code is carried here as a flag, not smoothed over.
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- Guard.  R002 adds Cost to the hub; it does not create the hub.
-- ─────────────────────────────────────────────────────────────────────────────
do $$
begin
  if to_regclass('public.akatsuki_vocab') is null then
    raise exception 'akatsuki: hub not installed — run sql/akatsuki_schema_R001.sql first, then re-run this file';
  end if;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A · Prerequisite.  The shared item had no clock.
--
-- cost_management_expenses has no updated_at: handleUpdate changes fields in
-- place, so a re-read is indistinguishable from a real edit and there is no
-- revision to dedupe on. Server-set, so it also moves on flag-only changes —
-- the failure WF's subtasks[].u and Sukkiri's updated_at already have.
-- Without this the card's clock line is 'none' and no adapter should be written.
-- ─────────────────────────────────────────────────────────────────────────────
alter table cost_management_expenses add column if not exists created_at timestamptz not null default now();
alter table cost_management_expenses add column if not exists updated_at timestamptz not null default now();

create or replace function cost_management_expenses_touch() returns trigger
language plpgsql as $$ begin new.updated_at := now(); return new; end $$;

drop trigger if exists cost_management_expenses_touch on cost_management_expenses;
create trigger cost_management_expenses_touch
  before update on cost_management_expenses
  for each row execute function cost_management_expenses_touch();

-- ─────────────────────────────────────────────────────────────────────────────
-- B · The hub learns Cost.
-- ─────────────────────────────────────────────────────────────────────────────

-- B0 · vocab gains an 'enum' namespace.
-- CLAUDE.md: shared enums are READ FROM VOCAB, never kept as a local copy.
-- R001 had no namespace to put them in, so every app still hardcodes its own.
alter table akatsuki_vocab drop constraint if exists akatsuki_vocab_ns_check;
alter table akatsuki_vocab add constraint akatsuki_vocab_ns_check
  check (ns in ('context','kind','icon','palette','enum'));

do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
begin

  -- B1 · kinds Cost brings to the ecosystem -----------------------------------
  -- notes is absent from every payload on purpose: it is private (free text +
  -- the fare-leg breakdown). Money leaves the app, the story behind it does not.
  insert into akatsuki_vocab (user_id, ns, id, schema, meta) values
  (u, 'kind', 'expense.created',
     '{"required":["id","date","amount","currency"],"optional":["category","shop","kind","tags"]}',
     '{"emitted_by":"cost","on":"successful insert only — insertExpense / insertExpenses / dueAdd / logStop"}'),
  (u, 'kind', 'expense.updated',
     '{"required":["id","date","amount","currency"],"optional":["category","shop","kind","tags"]}',
     '{"emitted_by":"cost","on":"handleUpdate changes amount/date/category/shop/type/tags — never on form change"}'),
  (u, 'kind', 'expense.deleted',
     '{"required":["id"]}',
     '{"emitted_by":"cost","on":"hard delete","note":"consumers orphan their link; they do not delete"}'),
  (u, 'kind', 'expense.recategorized',
     '{"required":["field","from","to"],"optional":["count"]}',
     '{"emitted_by":"cost","on":"category/tag/shop rename cascade","note":"ONE event for the whole cascade, never N x expense.updated"}')
  on conflict (user_id, ns, id) do update set schema = excluded.schema, meta = excluded.meta;

  -- purchase_request / purchase_reply already exist from R001. Sharpen the
  -- reply so status is a vocab enum rather than a free string.
  update akatsuki_vocab set schema = '{"required":["id","status"],"optional":["expense_ids","amount","currency"]}',
                             meta   = '{"owner_of_status":"cost","note":"Sukkiri owns items[], Cost owns status"}'
   where user_id = u and ns = 'kind' and id = 'purchase_reply';

  -- B2 · enums — the single copy everyone reads ------------------------------
  insert into akatsuki_vocab (user_id, ns, id, schema, meta) values
  (u, 'enum', 'expense_type',      '{"values":["normal","fixed","outlier"]}',        '{"owner":"cost","was":"index.html:107 EXPENSE_TYPES + hardcoded <select> at 4006"}'),
  (u, 'enum', 'currency',          '{"values":["JPY","INR"]}',                        '{"owner":"cost","default":"JPY","was":"CURRENCIES map at index.html:161","column":"region"}'),
  (u, 'enum', 'stop_status',       '{"values":["open","logged","dismissed"]}',        '{"owner":"cost","enforced":"check constraint, 011_stops.sql"}'),
  (u, 'enum', 'pending_status',    '{"values":["pending","logged","dismissed"]}',     '{"owner":"cost","enforced":"comment only — no check constraint"}'),
  (u, 'enum', 'area_point_source', '{"values":["manual","auto"]}',                    '{"owner":"cost"}'),
  (u, 'enum', 'fare_origin',       '{"values":["manual","imported","api"]}',          '{"owner":"cost","enforced":"default only — no check constraint"}'),
  (u, 'enum', 'purchase_status',   '{"values":["pending","approved","rejected","logged"]}', '{"owner":"cost","note":"Cost writes this; Sukkiri reads it"}')
  on conflict (user_id, ns, id) do update set schema = excluded.schema, meta = excluded.meta;

  -- B3 · the card.  Replaces R001's thin reply-only stub. -------------------
  insert into akatsuki_apps (
    user_id, id, name, role, pattern, address_shape, clock_field, clock_trust,
    emits, accepts, deletes, private_fields, session, reach, payload_map, owned_paths, flags
  ) values (
    u, 'cost', 'Cost Management', 'app', 'stream',
    '{id} · cost_management_expenses.id bigint identity · owner user_id uuid on every table',
    'updated_at · server-set by cost_management_expenses_touch (part A of this file)',
    'trigger',
    -- emits: declared here so publish can validate; a route opens per consumer.
    '{expense.created,expense.updated,expense.deleted,expense.recategorized,purchase_reply}',
    -- accepts: ONLY what has a written adapter. place.stop and task.due are
    -- proposed (see part C) and stay out until one exists — an undeclared accept
    -- is what makes akatsuki_publish reject early instead of half-delivering.
    '{purchase_request}',
    'hard',
    '{notes,recurring.notes,fare_book.notes,stops.lat,stops.lng,stop_blocks.lat,stop_blocks.lng,stop_blocks.label,area_points.lat,area_points.lng,area_points.label,areas.lat,areas.lng,triggers.data,places_cache.candidates,stop_settings.cfg}',
    'jwt',
    ':5174 (python -m http.server) · public GitHub Pages · shared project wylxvmkcrexwfpjpbhyy · cloud only',
    '{"id":"id","date":"date","amount":"amount","currency":"region","category":"category","shop":"shop","kind":"expense_type","tags":"tags"}',
    '{cost_management_expenses.*,cost_management_shops.*,cost_management_categories.*,cost_management_tags.*,cost_management_recurring.*,cost_management_pending.*,cost_management_fare_book.*,cost_management_areas.*,cost_management_area_points.*,cost_management_stops.*,cost_management_places_usage.*,cost_management_places_cache.*,purchase_request.status}',
    '{"anon key ships in a PUBLIC GitHub Pages bundle (index.html:61) — RLS is the only gate; see akatsuki_credentials",
      "purchase requests cross via localStorage keys cost_management_purchase_requests / sukkiri_cost_requests (index.html:313) — different origins, so this path only ever worked by paste. Defect route, re-home to stream.",
      "cascade renames rewrite many expense rows (3630/3650/3680) — emit ONE expense.recategorized, not N updates",
      "flag-only changes still move no app clock: shops.is_favorite (3689), pending.status, area_points.confirmed",
      "?? resolved_at exists on cost_management_pending but no code sets it",
      "?? no CREATE TABLE exists for expenses / shops / tags / recurring — they predate the migration folder. Confirm against information_schema.columns before building on them.",
      "011_stops, 012_places_budget, 005_fare_lookup_cache are written but NOT applied live — any route touching stops is blocked on applying them",
      "expenses.id is bigint identity: the address is NOT portable across a restore. A consumer must key on the link row, never on the raw id."
    }'
  )
  on conflict (user_id, id) do update set
    name = excluded.name, role = excluded.role, pattern = excluded.pattern,
    address_shape = excluded.address_shape, clock_field = excluded.clock_field,
    clock_trust = excluded.clock_trust, emits = excluded.emits, accepts = excluded.accepts,
    deletes = excluded.deletes, private_fields = excluded.private_fields,
    session = excluded.session, reach = excluded.reach, payload_map = excluded.payload_map,
    owned_paths = excluded.owned_paths, flags = excluded.flags;

  -- B4 · routes ---------------------------------------------------------------
  insert into akatsuki_routes (user_id, from_app, to_app, kind, access, state, note) values
  -- the one live link, re-homed off localStorage
  (u, 'sukkiri', 'cost', 'purchase_request', 'stream', 'live',
     'was localStorage sukkiri_cost_requests + paste-JSON across origins. Now a stream; Cost answers with purchase_reply in place.'),
  (u, 'cost', 'sukkiri', 'purchase_reply', 'stream', 'live',
     'reply leg — rides the same akatsuki_requests row. Cost owns purchase_request.status; written via akatsuki_ack(reply), Sukkiri reads hub.replies().'),
  -- reference data Cost can hand out with zero copy
  (u, 'cost', 'cal', 'expense.created', 'stream', 'proposed',
     'a spend line on the day it happened — opens when Calendar declares it accepts expense.created')
  on conflict (user_id, from_app, to_app, kind) do update set
    access = excluded.access, state = excluded.state, note = excluded.note;

  -- the old defect row, now superseded
  update akatsuki_routes set state = 'retired', note = 'superseded by R002: brokered as a stream'
   where user_id = u and from_app = 'sukkiri' and to_app = 'cost' and kind = 'purchase_request' and access = 'direct';

  -- B5 · credentials — names and WHERE THEY LIVE, never the secret ----------
  insert into akatsuki_credentials (user_id, name, scope, location, consumers, rotated_at) values
  (u, 'supabase_anon', 'Shared project, RLS-gated', 'client_bundle', '{wf,rm,cal,sukkiri,cost}', '2026-09-21'),
  (u, 'google_places', 'Nearby search for stop detection', 'edge_env', '{cost}', null),
  (u, 'ekispert',      'Fare lookup',                      'edge_env', '{cost}', null)
  on conflict (user_id, name) do update set
    scope = excluded.scope, location = excluded.location, consumers = excluded.consumers;

  -- B6 · sources — Cost's two external APIs, declared as hub sources.
  -- Both already cache app-side; registering them means the NEXT consumer
  -- reads akatsuki_cache instead of spending Cost's quota.
  insert into akatsuki_sources (user_id, id, name, kind, endpoint, credential, fetch_policy, quota, emits, consumers, cache_ttl) values
  (u, 'places_nearby', 'Google Places nearby', 'api', 'supabase/functions/places-nearby', 'google_places',
     'on stop detection, cache-first', 'counted in cost_management_places_usage (calls per month)', 'place.candidates', '{cost}', interval '30 days'),
  (u, 'fare_lookup',   'Ekispert fare lookup', 'api', 'supabase/functions/fare-lookup', 'ekispert',
     'on unknown station pair, cache-first', 'unmetered', 'fare.quote', '{cost}', interval '180 days')
  on conflict (user_id, id) do update set
    endpoint = excluded.endpoint, credential = excluded.credential,
    fetch_policy = excluded.fetch_policy, quota = excluded.quota, cache_ttl = excluded.cache_ttl;

end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C · Deliberately NOT opened.
--
-- Each of these is a real candidate from Cost's card that fails one of the six
-- questions today. Opening one is two inserts — accept + route — and nothing else.
--
-- 1. place.stop → cost_management_stops (upsert on user_id,id)
--    Blocked: 011_stops.sql is not applied live. Address and idempotency are
--    already sound (id is derived from the visit's start time, so a visit cannot
--    double-insert; (user_id,id) + updated_at gives row + revision).
--      update akatsuki_apps set accepts = accepts || '{place.stop}' where id='cost';
--      insert into akatsuki_routes values (u,'<origin>','cost','place.stop','stream','half','…');
--
-- 2. task.due → cost_management_pending (upsert on rule_id,due_date)
--    Blocked: no origin has filed a card that emits a money-owed reminder.
--    Idempotency is the best in the app — unique (rule_id,due_date), already
--    upserted with ignoreDuplicates.
--
-- 3. category / tag vocabulary as reference data for other apps.
--    Reach = view, not stream: read-only, no conflict, zero copy. When a
--    consumer appears, create it as an akatsuki_-owned view — NOT a direct read:
--      create or replace view akatsuki_cost_categories with (security_invoker = on) as
--        select user_id, name, icon, color, sort_order from cost_management_categories;
--    security_invoker is not optional. Without it the view bypasses RLS.
--
-- 4. fare_book as reference data — same shape as 3, keyed on pair_key.
--
-- 5. shop.created — only worth a kind if another app needs the shop list. No
--    consumer, so no kind was minted. Do not mint kinds speculatively.
-- ─────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────
-- Verify
-- ─────────────────────────────────────────────────────────────────────────────
-- select id, pattern, clock_trust, cardinality(emits) e, cardinality(accepts) a,
--        cardinality(flags) open_questions from akatsuki_apps order by id;
-- select * from akatsuki_routes where from_app = 'cost' or to_app = 'cost';
-- select ns, id, schema from akatsuki_vocab where ns = 'enum';
-- select column_name, data_type from information_schema.columns
--  where table_name = 'cost_management_expenses' order by ordinal_position;
