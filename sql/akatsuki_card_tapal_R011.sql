-- ============================================================================
-- Akatsuki R011 — Tapal files its card.  Run after R010.  Idempotent.
-- Source: Tapal's own reply, 2026-09-23.  No routes yet: the WF link is
-- undecided, and an emit with no consumer opens nothing.
--
--   A. TRUST test (writes nothing).  R007's lesson: "RLS on" is not an answer.
--   B. Tapal-side clock repair — senders get updated_at; no-op PATCHes stop
--      moving updated_at.  No Tapal code change needed.
--   C. The card, vocab kinds, Tapal's enums, the one defect route.
--
-- Calendar's task.done + akatsuki_wf_tasks view moves to R012.
-- ============================================================================

-- ═════════════════════════════════════════════════════════════════
-- PART A · Trust test.  Paste all three results back.
-- ═════════════════════════════════════════════════════════════════
select c.relname table_name, c.relrowsecurity rls,
       (select count(*) from pg_policies p where p.tablename = c.relname) policies,
       (select string_agg(p.cmd || ' ' || p.roles::text || ' ' || coalesce(p.qual, p.with_check, 'true'), ' | ')
          from pg_policies p where p.tablename = c.relname) predicates,
       (select data_type from information_schema.columns where table_name = c.relname and column_name = 'user_id') user_id_type
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relkind = 'r' and c.relname like 'tapal_%' order by 1;

select table_name, grantee, string_agg(privilege_type, ',' order by privilege_type) privs
  from information_schema.role_table_grants
 where table_schema = 'public' and (table_name like 'tapal_%' or table_name = 'authentication_mode_user_roles')
   and grantee in ('anon','authenticated') group by 1,2 order by 1,2;

-- tapal_my_role is SECURITY DEFINER: without a pinned search_path it can be hijacked.
select proname, prosecdef, proconfig from pg_proc where proname = 'tapal_my_role';

-- Legacy rows with no owner (pre-auth).
select 'addresses' t, count(*) filter (where user_id is null) null_owner, count(*) total from tapal_addresses
union all
select 'shipments', count(*) filter (where user_id is null), count(*) from tapal_shipments;

-- ═════════════════════════════════════════════════════════════════
-- PART B · Clock repair (Tapal-side DDL).
-- ═════════════════════════════════════════════════════════════════
-- 1 · saveAddr PATCHes on every click.  tapal_touch moves updated_at even when
--     nothing changed, so a no-op save looks like a real change.  Fire the
--     trigger only when the row actually differs.  The client can then publish
--     iff the returned updated_at moved.
drop trigger if exists tapal_addresses_touch on tapal_addresses;
create trigger tapal_addresses_touch before update on tapal_addresses
  for each row when (old is distinct from new) execute function tapal_touch();

-- 2 · Senders have no clock at all.  Same trigger, same rule.
alter table tapal_senders add column if not exists updated_at timestamptz not null default now();
drop trigger if exists tapal_senders_touch on tapal_senders;
create trigger tapal_senders_touch before update on tapal_senders
  for each row when (old is distinct from new) execute function tapal_touch();

-- Shipments: insert + delete only today, so no clock needed.  The day phase 12
-- (tracking) updates status, it gets the same column + trigger first.

-- ═════════════════════════════════════════════════════════════════
-- PART C · The card.
-- ═════════════════════════════════════════════════════════════════
do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
begin

  insert into akatsuki_apps (
    user_id, id, name, role, pattern, address_shape, clock_field, clock_trust,
    emits, accepts, deletes, private_fields, session, reach, payload_map, owned_paths, flags
  ) values (
    u, 'tapal', 'Tapal', 'app', 'stream',
    '{id} uuid on tapal_addresses / tapal_senders / tapal_shipments · shipments.address_id → addresses.id',
    'updated_at · server-set by tapal_touch on addresses and senders (senders from R011 part B), fires only on a real change · shipments: none, insert/delete only',
    'trigger',
    '{address.upserted,address.archived,shipment.logged,shipment.removed,sender.upserted,sender.deleted}',
    '{}',
    'hard',
    '{tapal_addresses.phone,tapal_addresses.line,tapal_senders.phone,tapal_senders.line,tapal_addresses.notes,tapal_shipments.notes,tapal_settings.sender_*}',
    'jwt',
    ':5111 (run-tapal-local.bat, python -m http.server) · Netlify · shared project wylxvmkcrexwfpjpbhyy · Google OAuth or magic link, no SDK · session in localStorage tapal-session',
    '{"address":{"id":"id","rev":"updated_at","label":"label","name":"name","city":"city","district":"district","state":"state","postal":"pin","country":"country","archived":"archived"},
      "shipment":{"id":"id","address_id":"address_id","recipient":"recipient","contents":"contents","service":"service","consignment_no":"consignment_no","booked_on":"booked_on","status":"status","cost":"cost"},
      "sender":{"id":"id","rev":"updated_at","label":"label","name":"name","city":"city","district":"district","state":"state","postal":"pin","country":"country"}}',
    '{tapal_addresses.*,tapal_senders.*,tapal_shipments.*,tapal_settings.*}',
    '{
      "TRUST differs from every other app: addresses, shipments and settings are shared by role (tapal_my_role() via authentication_mode_user_roles), not scoped by user_id = auth.uid(). Hub rows ARE per user, so an event published by operator X lands in X''s hub only. Fine while you are the only operator; a second operator needs a decision.",
      "?? phone and line are PII — held PRIVATE by default (not in payload_map). Release per consumer only if a route needs them; an unsent field can be released later, a sent one cannot be recalled.",
      "?? legacy rows with user_id null on addresses/shipments (pre-auth). Harmless under role RLS; they cannot be published under the right owner until claimed. Part A counts them.",
      "?? tapal_my_role is SECURITY DEFINER — confirm proconfig pins search_path (part A).",
      "no SDK: akatsuki-client.js takes a supabase client. Tapal needs supabase-js or a fetch shim for rpc/akatsuki_publish · akatsuki_consume · akatsuki_ack, sending its JWT + x-akatsuki-app: tapal.",
      "offline writes go to localStorage parcel-label-data and are never pushed. Publish only after the server write succeeds; offline edits emit nothing.",
      "publish rule for addresses/senders: only when the PATCH response updated_at differs from the one sent (R011 part B makes no-op saves leave it unchanged).",
      "?? service enum may be incomplete — options past index.html:120 unread.",
      "?? README says port 5173; run-tapal-local.bat says 5111. The bat file is the truth; fix the README.",
      "roadmap accepts: shipment.tracking (phase 12, updates status — needs a clock first), estimate.chosen (phase 13). Not declared until an adapter exists."
    }'
  )
  on conflict (user_id, id) do update set
    name = excluded.name, role = excluded.role, pattern = excluded.pattern,
    address_shape = excluded.address_shape, clock_field = excluded.clock_field, clock_trust = excluded.clock_trust,
    emits = excluded.emits, accepts = excluded.accepts, deletes = excluded.deletes,
    private_fields = excluded.private_fields, session = excluded.session, reach = excluded.reach,
    payload_map = excluded.payload_map, owned_paths = excluded.owned_paths, flags = excluded.flags,
    updated_at = now();

  insert into akatsuki_vocab (user_id, ns, id, schema, meta) values
  (u, 'kind', 'address.upserted', '{"required":["id","rev","name","country","archived"],"optional":["label","city","district","state","postal"]}',
     '{"emitted_by":"tapal","on":"POST, or PATCH whose updated_at moved and archived did not flip","idempotency_key":"default — rev is in the payload"}'),
  (u, 'kind', 'address.archived', '{"required":["id","rev"],"optional":[]}',
     '{"emitted_by":"tapal","on":"PATCH {archived:true} — soft delete; consumers orphan, never cascade"}'),
  (u, 'kind', 'shipment.logged',  '{"required":["id","status","booked_on"],"optional":["address_id","recipient","contents","service","consignment_no","cost"]}',
     '{"emitted_by":"tapal","on":"POST tapal_shipments","idempotency_key":"tapal:shipment.logged:<id> — insert-only, published once","types":{"status":"enum shipment_status","service":"enum shipment_service","cost":"numeric(10,2)","booked_on":"date"}}'),
  (u, 'kind', 'shipment.removed', '{"required":["id"],"optional":[]}',
     '{"emitted_by":"tapal","on":"DELETE tapal_shipments — hard","idempotency_key":"tapal:shipment.removed:<id>"}'),
  (u, 'kind', 'sender.upserted',  '{"required":["id","rev","name","country"],"optional":["label","city","district","state","postal"]}',
     '{"emitted_by":"tapal","on":"POST, or PATCH whose updated_at moved (clock from R011 part B)"}'),
  (u, 'kind', 'sender.deleted',   '{"required":["id"],"optional":[]}',
     '{"emitted_by":"tapal","on":"DELETE tapal_senders — hard","idempotency_key":"tapal:sender.deleted:<id>"}')
  on conflict (user_id, ns, id) do update set schema = excluded.schema, meta = excluded.meta;

  insert into akatsuki_vocab (user_id, ns, id, schema, meta) values
  (u, 'enum', 'shipment_status',  '{"values":["packed","booked","in transit","delivered","problem"]}', '{"owner":"tapal","source":"index.html #lgStatus","note":"no DB check constraint"}'),
  (u, 'enum', 'shipment_service', '{"values":["Speed Post","India Post Parcel (surface)","DTDC","Delhivery","Blue Dart","Xpressbees","Bus parcel","Hand carried"]}', '{"owner":"tapal","source":"index.html #lgService","note":"?? may be incomplete — options past line 120 unread"}'),
  (u, 'enum', 'country',          '{"values":["India","Japan","United States","United Kingdom","Singapore","Australia","United Arab Emirates","Other"]}', '{"owner":"tapal","source":"js/countries.js FORMATS keys"}')
  on conflict (user_id, ns, id) do update set schema = excluded.schema, meta = excluded.meta;

  -- tapal_my_role() reads another app's table through SECURITY DEFINER — a
  -- direct cross-app read.  Owner of authentication_mode_user_roles unregistered.
  insert into akatsuki_routes (user_id, from_app, to_app, kind, access, state, note) values
  (u, 'auth', 'tapal', 'role.lookup', 'direct', 'defect',
     'R011 — tapal_my_role() (SECURITY DEFINER) reads authentication_mode_user_roles by email, bypassing its RLS. Owner app unregistered. Re-home as an akatsuki_* view with security_invoker = on once the owner files a card.')
  on conflict (user_id, from_app, to_app, kind) do update set access = excluded.access, state = excluded.state, note = excluded.note;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Verify
-- ─────────────────────────────────────────────────────────────────────────────
-- select id, pattern, clock_trust, cardinality(emits) emits, cardinality(flags) open from akatsuki_apps where id = 'tapal';
-- select ns, id from akatsuki_vocab where meta->>'emitted_by' = 'tapal' or meta->>'owner' = 'tapal' order by 1,2;
-- select tgname, pg_get_triggerdef(oid) from pg_trigger where tgname like 'tapal_%_touch';
