-- R021 · Sukkiri ↔ Calendar — Phase B gate + route flip (Oct 1)
-- Sukkiri build sk-20261001-s4b: pushCalCloud deleted, syncCycles/syncGarbage on, cycles carry wk.
-- Before Part A: in Sukkiri, Settings → "Push cycles to calendar" once (every cycle re-sends with wk).
-- Then run Part A. Every row must be pass = true. Only then run Part B.

-- ═══ 0 · declare wk on the kind (run once) ══════════════════════════════════
update akatsuki_vocab set schema = jsonb_set(schema, '{optional}', '["color","wk"]')
 where user_id = 'e91a5f37-e63a-4fd0-8488-4d7a51d56822' and ns = 'kind' and id = 'cycle.home';

-- Diagnose (if check 2 fails): when did Sukkiri last write each cycle, and what?
-- select item_key, updated_at, updated_by, value from akatsuki_state
--  where doc = 'calapp_sukkiri' and path = 'cycles' and deleted_at is null order by updated_at desc;

-- ═══ A · gate check (read-only) ═════════════════════════════════════════════
with u as (select 'e91a5f37-e63a-4fd0-8488-4d7a51d56822'::uuid id),
st as (
  select s.* from akatsuki_state s, u
   where s.user_id = u.id and s.doc = 'calapp_sukkiri' and s.deleted_at is null
),
cyc as (select * from st where path = 'cycles' and item_key <> ''),
b as (  -- Phase B start = first cycle row written with wk
  select min(updated_at) at from cyc where value ? 'wk'
)
select 1 n, 'home cycles exist, owned + written by sukkiri' chk,
       count(*) > 0 and bool_and(owner_app = 'sukkiri' and updated_by = 'sukkiri') pass,
       count(*)::text || ' rows' detail
  from cyc where value->>'kind' = 'home'
union all
select 2, 'every home cycle has wk (boolean)',
       count(*) > 0 and coalesce(bool_and(jsonb_typeof(value->'wk') = 'boolean'), false),
       count(*) filter (where jsonb_typeof(value->'wk') is distinct from 'boolean')::text || ' missing'
  from cyc where value->>'kind' = 'home'
union all
select 3, 'home cycle keys are sk_<id>',
       coalesce(bool_and(item_key like 'sk\_%'), true),
       coalesce(string_agg(item_key, ', ') filter (where item_key not like 'sk\_%'), 'ok')
  from cyc where value->>'kind' = 'home'
union all
select 4, 'digital cycles owned by cal, never written by sukkiri',
       coalesce(bool_and(owner_app = 'cal' and updated_by = 'cal'), true),
       count(*)::text || ' rows'
  from cyc where value->>'kind' = 'digital'
union all
select 5, 'no cycle row of unknown kind',
       count(*) = 0, count(*)::text || ' rows'
  from cyc where coalesce(value->>'kind', '') not in ('home', 'digital')
union all
select 6, 'garbage owned + written by sukkiri only',
       coalesce(bool_and(owner_app = 'sukkiri' and updated_by = 'sukkiri'), true),
       count(*)::text || ' rows'
  from st where path = 'garbage' and item_key <> ''
union all
select 7, 'cal paths (away·done·overrides·block·show·wm) owned + written by cal',
       count(*) = 6 and bool_and(owner_app = 'cal' and coalesce(updated_by, 'cal') = 'cal'),
       count(*)::text || ' of 6'
  from st where item_key = '' and path in ('away','done','overrides','block','show','wm')
union all
select 8, 'no sukkiri violations since Phase B (old whole-row write gone)',
       (select at from b) is not null and count(*) = 0,
       coalesce('since ' || (select at from b)::text, 'no wk row yet') || ' · ' || count(*)::text || ' rows'
  from akatsuki_violations v, u
 where v.user_id = u.id and v.actor = 'sukkiri' and v.at >= (select at from b)
union all
select 9, 'Calendar view sees the same home cycles',
       (select count(*) from cyc where value->>'kind' = 'home')
     = coalesce((select count(*) from akatsuki_docs d, u, jsonb_array_elements(d.items) e
                  where d.user_id = u.id and d.doc = 'calapp_sukkiri' and d.path = 'cycles'
                    and e->>'kind' = 'home'), 0),
       'state vs akatsuki_docs'
union all
select 10, 'no leftover whole-row garbage (R009 seed dropped)',
       count(*) = 0, count(*)::text || ' rows'
  from st where path = 'garbage' and item_key = ''
order by n;

-- ═══ B · flip routes to live (run only after every A row is true) ═══════════
-- Re-checks the hard gates itself and refuses if any fail.
-- do $$
-- declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
--         bad int; n int;
-- begin
--   select count(*) into bad from akatsuki_state
--    where user_id = u and doc = 'calapp_sukkiri' and path = 'cycles' and item_key <> ''
--      and deleted_at is null and value->>'kind' = 'home'
--      and (owner_app <> 'sukkiri' or jsonb_typeof(value->'wk') is distinct from 'boolean');
--   if bad > 0 then raise exception 'R021 gate: % home cycle rows wrong owner or missing wk', bad; end if;
--
--   select count(*) into bad from akatsuki_violations
--    where user_id = u and actor = 'sukkiri'
--      and at >= (select min(updated_at) from akatsuki_state
--                  where user_id = u and doc = 'calapp_sukkiri' and path = 'cycles' and value ? 'wk');
--   if bad > 0 then raise exception 'R021 gate: % sukkiri violations since Phase B', bad; end if;
--
--   update akatsuki_routes set state = 'live', note = 'LIVE R021 (sk-20261001-s4b). ' || coalesce(note, '')
--    where user_id = u and state <> 'live'
--      and (from_app, to_app) in (('sukkiri','cal'), ('cal','sukkiri'));
--   get diagnostics n = row_count;
--   raise notice 'R021: % routes now live', n;
-- end $$;
--
-- Confirm:
-- select from_app, to_app, kind, access, state from akatsuki_routes
--  where (from_app, to_app) in (('sukkiri','cal'), ('cal','sukkiri')) order by 1, 3;
