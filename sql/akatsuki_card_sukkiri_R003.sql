-- ============================================================================
-- Akatsuki R003 — Sukkiri joins the hub.  Run after R001 and R002.  Idempotent.
--
-- Card source: Sukkiri's own reply, 2026-09-22.  Sukkiri is a DOCUMENT app:
-- one per-user JSON doc, whole-row upsert, client clock that moves on every save.
-- The hub's job is to shred that doc into owned rows (akatsuki_state) so
-- Calendar's half (away / done / overrides / block) can never be clobbered.
--
-- No part A: there is no SQL fix for "no per-cycle clock" — the cycle lives
-- inside a jsonb column.  The change signal is made app-side by the adapter
-- (content hash per cycle, publish on real change only).
-- ============================================================================
do $$
begin
  if to_regclass('public.akatsuki_vocab') is null then
    raise exception 'akatsuki: hub not installed — run R001, R002 first';
  end if;
end $$;

do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
begin

  -- Sukkiri's names map onto kinds R001 already minted. Do NOT mint duplicates:
  --   cleaning.cycle.upserted / .removed → cycle.home
  --   garbage.rules.changed              → trash.pickup
  --   purchase.request.created           → purchase_request
  update akatsuki_vocab set
    schema = '{"required":["id","totalYen","items"],"optional":["requestedAt","currency"]}',
    meta   = '{"emitted_by":"sukkiri","on":"Shopping tab send-to-cost — the one event-shaped write in the app","items":"[{name,priceYen,link,reason,category}]"}'
   where user_id = u and ns = 'kind' and id = 'purchase_request';
  update akatsuki_vocab set
    meta = '{"owner":"sukkiri","doc":"calapp_sukkiri","path":"cycles","item_key":"sk_<cycleId>","anchor":"dkey(dueAt(c)) — moves on every mark-done"}'
   where user_id = u and ns = 'kind' and id = 'cycle.home';
  update akatsuki_vocab set
    meta = '{"owner":"sukkiri","doc":"calapp_sukkiri","path":"garbage","item_key":"garbage[].id","rule":"only when a category has days.length — else Calendar rules stand"}'
   where user_id = u and ns = 'kind' and id = 'trash.pickup';

  insert into akatsuki_vocab (user_id, ns, id, schema, meta) values
  (u, 'enum', 'cycle_kind', '{"values":["home","digital"]}', '{"owner":"cal","note":"home = Sukkiri writes, digital = Calendar writes"}'),
  (u, 'enum', 'photo_kind', '{"values":["ideal","current"]}', '{"owner":"sukkiri","enforced":"check constraint"}'),
  (u, 'enum', 'area_id',    '{"values":["bed","desk","wardrobe","floor","laundry","custom"]}', '{"owner":"sukkiri","enforced":"comment only"}'),
  (u, 'enum', 'log_kind',   '{"values":["info","inspect","shop"]}', '{"owner":"sukkiri"}')
  on conflict (user_id, ns, id) do update set schema = excluded.schema, meta = excluded.meta;

  insert into akatsuki_apps (
    user_id, id, name, role, pattern, address_shape, clock_field, clock_trust,
    emits, accepts, deletes, private_fields, session, reach, payload_map, owned_paths, flags
  ) values (
    u, 'sukkiri', 'Sukkiri', 'app', 'document',
    'sukkiri_state.user_id (one doc) → payload.cycles[].id text c… · published as sk_<cycleId> · sukkiri_cost_requests.id req…',
    'sukkiri_state.updated_at · client-set · moves on EVERY save incl. flag-only · no per-cycle timestamp',
    'client',
    '{cycle.home,trash.pickup,purchase_request}',
    '{purchase_reply}',
    'hard',
    '{payload.log,payload.points,payload.streak,payload.notes,payload.form,payload.budget,payload.areas[].ideal,payload.areas[].current,sukkiri_reports.summary,sukkiri_reports.areas,sukkiri_photos.storage_path}',
    'jwt',
    ':8091 · shared project wylxvmkcrexwfpjpbhyy · email+password · localStorage authoritative, cloud mirror',
    '{"id":"sk_+cycles[].id","name":"cycles[].name","every":"cycles[].days","anchor":"dkey(dueAt(c))","color":"cycles[].color ?? CAL_COL","kind":"literal home","totalYen":"sum(items[].priceYen)","items":"shop[] where bought=false"}',
    '{calapp_sukkiri.cycles[kind=home],calapp_sukkiri.garbage,sukkiri_state.*,sukkiri_reports.*,sukkiri_photos.*,sukkiri_timers.*,purchase_request.items}',
    '{"pushCal/pushCalCloud run on EVERY save with no dirty check — every kind fires on any state change. Adapter adds a per-item content hash; publish only when it differs.",
      "whole-payload upsert of calendar_app_sukkiri: Calendar''s digital cycles, away, done, overrides, block are filter-and-concat — a concurrent Calendar write is lost. Fix = owner-shredded rows in akatsuki_state, doc calapp_sukkiri.",
      "cycle delete reaches Calendar only as an omission from the next cycles[] write — R003 makes it an explicit hub.remove().",
      "purchase_reply: Cost writes status back, but Sukkiri has NO read path. Adapter adds hub.replies() polling.",
      "sukkiri_cost_requests.status CHECK was pending|approved|rejected — widened below to match the shared enum, which also has logged.",
      "sukkiri_reports, sukkiri_photos, sukkiri_cost_requests exist in SQL but have no write path in the app — they live only in sukkiri_state.payload + localStorage.",
      "sukkiri_timers.payload.rev is the only monotonic revision in the app — the pattern every other doc path should copy.",
      "pullCalAway() reads calendar_app_sukkiri directly — defect; after R003 it reads akatsuki_docs."
    }'
  )
  on conflict (user_id, id) do update set
    name = excluded.name, pattern = excluded.pattern, address_shape = excluded.address_shape,
    clock_field = excluded.clock_field, clock_trust = excluded.clock_trust, emits = excluded.emits,
    accepts = excluded.accepts, deletes = excluded.deletes, private_fields = excluded.private_fields,
    session = excluded.session, reach = excluded.reach, payload_map = excluded.payload_map,
    owned_paths = excluded.owned_paths, flags = excluded.flags;

  -- Routes. The two Sukkiri → cal rows stay 'defect' until the adapter is wired
  -- and pushCalCloud is deleted; the UPDATEs at the bottom flip them to live.
  insert into akatsuki_routes (user_id, from_app, to_app, kind, access, state, note) values
  (u, 'sukkiri', 'cal', 'cycle.home',   'stream', 'defect', 'today: whole-row upsert of calendar_app_sukkiri. Target: hub.put(calapp_sukkiri, cycles, sk_<id>) per cycle + hub.remove on delete'),
  (u, 'sukkiri', 'cal', 'trash.pickup', 'stream', 'defect', 'same row. Target: hub.put(calapp_sukkiri, garbage, <id>) per category'),
  (u, 'cal', 'sukkiri', 'away',      'view', 'proposed', 'Sukkiri reads akatsuki_docs where doc=calapp_sukkiri — Calendar owns the path'),
  (u, 'cal', 'sukkiri', 'done',      'view', 'proposed', 'same'),
  (u, 'cal', 'sukkiri', 'overrides', 'view', 'proposed', 'same'),
  (u, 'cal', 'sukkiri', 'block',     'view', 'proposed', 'same'),
  (u, 'cal', 'sukkiri', 'garbage',   'view', 'proposed', 'read back only when Sukkiri has no rules of its own (gcats)')
  on conflict (user_id, from_app, to_app, kind) do update set access = excluded.access, note = excluded.note;

  -- Ownership of the shared doc, declared once so the guard trigger enforces it.
  -- Sukkiri owns cycles[home] + garbage; Calendar owns these. Empty seed rows
  -- carry the owner; real values arrive from each app's adapter.
  insert into akatsuki_state (user_id, doc, path, item_key, owner_app, value, updated_by) values
  (u, 'calapp_sukkiri', 'away',      '', 'cal', null, 'cal'),
  (u, 'calapp_sukkiri', 'done',      '', 'cal', null, 'cal'),
  (u, 'calapp_sukkiri', 'overrides', '', 'cal', null, 'cal'),
  (u, 'calapp_sukkiri', 'block',     '', 'cal', null, 'cal'),
  (u, 'calapp_sukkiri', 'show',      '', 'cal', null, 'cal'),
  (u, 'calapp_sukkiri', 'wm',        '', 'cal', null, 'cal')
  on conflict do nothing;

end $$;

-- Sukkiri-side prerequisite (its own table, same project): accept the shared enum.
alter table sukkiri_cost_requests drop constraint if exists sukkiri_cost_requests_status_check;
alter table sukkiri_cost_requests add  constraint sukkiri_cost_requests_status_check
  check (status in ('pending','approved','rejected','logged'));

-- Once the adapter is wired and pushCalCloud is deleted:
--   update akatsuki_routes set state='live' where from_app='sukkiri' and to_app='cal';
--   update akatsuki_routes set state='live' where from_app='cal' and to_app='sukkiri';
