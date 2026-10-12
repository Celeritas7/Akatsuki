-- ============================================================================
-- Akatsuki R023 — places: one list, owned by the hub.  Oct 4.  Idempotent.
--
-- Decision (user, Oct 4): Akatsuki owns places and location logic for every app.
-- Today there are three lists — WF subtasks[].loc (Home, Out, Shin-Ōkubo, Minami-Urawa,
-- user-added), Roadmap roadmap_locations (home/office/train, 0004), hub enum place.
-- After R023: one table, akatsuki_places.  Apps READ it (RLS select) and WRITE only through
-- three RPCs (add / edit / retire).  Hub-merged: many senders, the hub owns the row.
-- R018 (visits, GPS detector) fills lat/lng/radius later — columns are here now.
--
--   A. Reads.  Where WF keeps its place list; every loc value in use.
--   B. Table, RPCs, vocab, seed, the view.
--   C. Card + route updates.
-- ============================================================================

-- ═══ A · reads ═══════════════════════════════════════════════════════════════
-- A1 · Every loc value on a WF subtask, with use count.
select s->>'loc' loc, count(*) used
  from weekly_focus_entries e
  cross join lateral jsonb_array_elements(case when jsonb_typeof(e.payload->'subtasks') = 'array' then e.payload->'subtasks' else '[]'::jsonb end) s
 where coalesce(s->>'loc', '') <> '' group by 1 order by 2 desc;
-- A2 · Where WF stores its place picker list ("+ New…").  Expect one synthetic row (e.g. __board).
select board_id, item_key, left(payload::text, 300) from weekly_focus_entries
 where payload::text ilike '%Minami%' and item_key like '\_\_%';
-- A3 · Roadmap's list (0004).
select * from roadmap_locations order by 1;
select * from roadmap_role_locations order by 1;

-- ═══ B · the table ═══════════════════════════════════════════════════════════
create table if not exists akatsuki_places (
  user_id     uuid not null default auth.uid(),
  id          text not null,                          -- slug: 'home', 'shin-okubo'.  Stable; apps store this.
  label       text not null,                          -- 'Shin-Ōkubo'
  class       text not null,                          -- vocab enum place_class — what the suggester matches on
  aliases     text[] not null default '{}',           -- old labels / other apps' words ('train', 'Train')
  ord         int not null default 100,
  lat         double precision,                       -- R018 fills these
  lng         double precision,
  radius_m    int,
  added_by    text not null,                          -- app id
  seq         bigint not null default nextval('akatsuki_seq'),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  retired_at  timestamptz,                            -- never deleted; retired places keep old tasks readable
  primary key (user_id, id)
);
alter table akatsuki_places enable row level security;
drop policy if exists akatsuki_places_read on akatsuki_places;
create policy akatsuki_places_read on akatsuki_places for select to authenticated using (user_id = auth.uid());
-- no insert/update/delete policy: writes only through the RPCs below
comment on table akatsuki_places is 'R023 — the one place list. Hub-owned. Read: select. Write: akatsuki_place_add / _edit / _retire.';

create or replace function akatsuki_place_slug(p text) returns text language sql immutable as $$
  select trim(both '-' from regexp_replace(lower(translate(coalesce(p, ''),
    'ŌōŪūĀāĒēĪīÔôÛûÂâÊêÎîÖöÜüÄäÉéÈèÀàÇç', 'OoUuAaEeIiOoUuAaEeIiOoUuAaEeEeAaCc')), '[^a-z0-9]+', '-', 'g'))
$$;

-- add: returns the existing place when the label (or an alias) already matches.  status created | exists
create or replace function akatsuki_place_add(p_label text, p_class text, p_app text)
returns table (id text, label text, class text, status text)
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_slug text := akatsuki_place_slug(p_label);
begin
  if v_uid is null then perform akatsuki_fail('42501', 'not_signed_in', 'place_add needs a signed-in user'); end if;
  if v_slug = '' then perform akatsuki_fail('AK112', 'empty_label', 'place label is empty'); end if;
  if not exists (select 1 from akatsuki_vocab v where v.user_id = v_uid and v.ns = 'enum' and v.id = 'place_class'
                  and v.schema->'values' ? coalesce(p_class, 'out')) then
    perform akatsuki_fail('AK111', 'bad_place_class', format('class %s is not in vocab enum place_class', p_class)); end if;
  return query
    select p.id, p.label, p.class, 'exists'::text from akatsuki_places p
     where p.user_id = v_uid and p.retired_at is null
       and (p.id = v_slug or akatsuki_place_slug(p.label) = v_slug or exists (select 1 from unnest(p.aliases) a where akatsuki_place_slug(a) = v_slug))
     limit 1;
  if found then return; end if;
  -- a retired one with the same slug comes back
  update akatsuki_places p set retired_at = null, label = trim(p_label), class = coalesce(p_class, p.class), seq = nextval('akatsuki_seq'), updated_at = now()
   where p.user_id = v_uid and p.id = v_slug and p.retired_at is not null;
  if found then return query select v_slug, trim(p_label), coalesce(p_class, 'out'), 'created'::text; return; end if;
  insert into akatsuki_places (user_id, id, label, class, added_by) values (v_uid, v_slug, trim(p_label), coalesce(p_class, 'out'), p_app);
  return query select v_slug, trim(p_label), coalesce(p_class, 'out'), 'created'::text;
end $$;

-- edit: label / class / ord / aliases.  The id never changes — apps store it.
create or replace function akatsuki_place_edit(p_id text, p jsonb, p_app text)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then perform akatsuki_fail('42501', 'not_signed_in', 'place_edit needs a signed-in user'); end if;
  if p ? 'class' and not exists (select 1 from akatsuki_vocab v where v.user_id = v_uid and v.ns = 'enum' and v.id = 'place_class' and v.schema->'values' ? (p->>'class')) then
    perform akatsuki_fail('AK111', 'bad_place_class', format('class %s is not in vocab enum place_class', p->>'class')); end if;
  update akatsuki_places x set
    aliases = case when p ? 'label' and p->>'label' <> x.label then array(select distinct a from unnest(x.aliases || x.label) a) else x.aliases end
              || coalesce(array(select jsonb_array_elements_text(p->'aliases')), '{}'),
    label = coalesce(nullif(trim(p->>'label'), ''), x.label),
    class = coalesce(p->>'class', x.class),
    ord   = coalesce((p->>'ord')::int, x.ord),
    seq = nextval('akatsuki_seq'), updated_at = now()
   where x.user_id = v_uid and x.id = p_id;
  if not found then perform akatsuki_fail('AK113', 'place_unknown', format('no place %s', p_id)); end if;
end $$;

create or replace function akatsuki_place_retire(p_id text, p_app text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then perform akatsuki_fail('42501', 'not_signed_in', 'place_retire needs a signed-in user'); end if;
  update akatsuki_places set retired_at = now(), seq = nextval('akatsuki_seq'), updated_at = now()
   where user_id = auth.uid() and id = p_id and retired_at is null;
  if not found then perform akatsuki_fail('AK113', 'place_unknown', format('no live place %s', p_id)); end if;
end $$;

grant select on akatsuki_places to authenticated;
grant execute on function akatsuki_place_add(text, text, text), akatsuki_place_edit(text, jsonb, text), akatsuki_place_retire(text, text) to authenticated;
revoke execute on function akatsuki_place_add(text, text, text), akatsuki_place_edit(text, jsonb, text), akatsuki_place_retire(text, text) from anon;

-- B2 · vocab + seed.  The SQL editor has no session: user_id written explicitly.
do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
begin
  insert into akatsuki_vocab (user_id, ns, id, schema, meta) values
  (u, 'enum', 'place_class', '{"values":["home","office","transit","cafe","out"]}',
     '{"owner":"hub","note":"what the suggester matches. A place has one class; many places share one (Shin-Ōkubo, Minami-Urawa → out until you say otherwise)"}'),
  (u, 'error', 'AK111', null, '{"name":"bad_place_class","class":"contract","by":"place_add · place_edit","fix":"class must be in vocab enum place_class"}'),
  (u, 'error', 'AK112', null, '{"name":"empty_label","class":"contract","by":"place_add","fix":"give the place a name"}'),
  (u, 'error', 'AK113', null, '{"name":"place_unknown","class":"contract","by":"place_edit · place_retire","fix":"id must be a row in akatsuki_places"}')
  on conflict (user_id, ns, id) do update set schema = excluded.schema, meta = excluded.meta;
  -- the old enum place is replaced by the table
  update akatsuki_vocab set meta = coalesce(meta, '{}') || '{"retired":"R023 — use akatsuki_places (rows) and enum place_class (matching)"}'
   where user_id = u and ns = 'enum' and id = 'place';

  insert into akatsuki_places (user_id, id, label, class, aliases, ord, added_by) values
  (u, 'home',   'Home',   'home',    '{"@home"}',            10, 'hub'),
  (u, 'office', 'Office', 'office',  '{"@office"}',          20, 'hub'),
  (u, 'train',  'Train',  'transit', '{"@train","transit"}', 30, 'hub'),
  (u, 'cafe',   'Café',   'cafe',    '{"cafe"}',             40, 'hub'),
  (u, 'out',    'Out',    'out',     '{}',                   50, 'hub'),
  -- A2 (Oct 4) found no stored WF list: Shin-Ōkubo was in WF's picker but on no task (A1). Kept by name.
  (u, 'shin-okubo', 'Shin-Ōkubo', 'out', '{}',            60, 'wf')
  on conflict (user_id, id) do nothing;
  -- every place WF tasks already use (A1) — class 'out' until the user sets it
  insert into akatsuki_places (user_id, id, label, class, ord, added_by)
  select u, akatsuki_place_slug(l), l, 'out', 60 + row_number() over (order by l), 'wf'
    from (select distinct trim(s->>'loc') l
            from weekly_focus_entries e
            cross join lateral jsonb_array_elements(case when jsonb_typeof(e.payload->'subtasks') = 'array' then e.payload->'subtasks' else '[]'::jsonb end) s
           where e.user_id = u and coalesce(trim(s->>'loc'), '') <> '') x
   where akatsuki_place_slug(l) <> ''
     and not exists (select 1 from akatsuki_places p where p.user_id = u
                       and (p.id = akatsuki_place_slug(l) or exists (select 1 from unnest(p.aliases) a where akatsuki_place_slug(a) = akatsuki_place_slug(l))))
  on conflict (user_id, id) do nothing;
  -- Roadmap's 0004 rows: A3 (Oct 4) shows role_locations use home / office / train only — all seeded above. Nothing to copy.
end $$;

-- B3 · the shared tags view now resolves WF's loc to a place (by id, label or alias — WF still stores labels until it migrates).
-- Dropped first: the live view still had R022's text urg (the B7 fix never re-ran), and create-or-replace can't change a column type.
drop view if exists akatsuki_task_tags;
create view akatsuki_task_tags with (security_invoker = on) as
select e.user_id, e.board_id, e.item_key, s->>'id' as sub_id,
       e.board_id || '/' || e.item_key || '/' || (s->>'id') as addr_key,
       s->>'t' as title,
       coalesce((s->>'done')::bool, false) as done,
       coalesce((s->>'lat')::bool, false)  as parked,
       coalesce((s->>'del')::bool, false)  as deleted,
       s->'ctx'  as ctx,
       coalesce(s->>'urg', 'false') not in ('false', '', '0') as urg,
       nullif(nullif(s->>'dl', 'false'), '') as dl,
       nullif(s->>'when', '') as when_date,
       t.value->>'type'   as type,
       t.value->>'effort' as effort,
       t.value->>'level'  as level,
       coalesce((t.value->>'guessed')::bool, true) as guessed,
       e.updated_at as wf_updated_at, t.seq as rm_seq,
       nullif(s->>'loc', '') as loc,
       pl.id as place_id, pl.class as place_class
  from weekly_focus_entries e
  cross join lateral jsonb_array_elements(case when jsonb_typeof(e.payload->'subtasks') = 'array' then e.payload->'subtasks' else '[]'::jsonb end) s
  left join akatsuki_state t
    on t.user_id = e.user_id and t.doc = 'task_tags' and t.path = 'rm' and t.deleted_at is null
   and t.item_key = e.board_id || '/' || e.item_key || '/' || (s->>'id')
  left join lateral (
    select p.id, p.class from akatsuki_places p
     where p.user_id = e.user_id and coalesce(s->>'loc', '') <> ''
       and (p.id = s->>'loc' or p.id = akatsuki_place_slug(s->>'loc')
            or exists (select 1 from unnest(p.aliases) a where akatsuki_place_slug(a) = akatsuki_place_slug(s->>'loc')))
     order by (p.id = s->>'loc') desc limit 1) pl on true
 where e.item_key not like '\_\_%';
comment on view akatsuki_task_tags is 'R023 — WF owns ctx/urg/dl/when/loc; Roadmap owns type/effort/level (akatsuki_state doc task_tags); place resolved from akatsuki_places. Read-only.';
grant select on akatsuki_task_tags to authenticated;

-- ═══ C · cards + routes ══════════════════════════════════════════════════════
do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822'; a text;
begin
  foreach a in array array['wf','rm','cost','sukkiri','cal','scriptura','jlpt','cc'] loop
    insert into akatsuki_routes (user_id, from_app, to_app, kind, access, state, note) values
    (u, 'hub', a, 'places', 'view', 'proposed',
     'R023 — reads akatsuki_places; writes via akatsuki_place_add/_edit/_retire. Live when the app reads it instead of its own list.')
    on conflict (user_id, from_app, to_app, kind) do update set note = excluded.note;
  end loop;
  update akatsuki_apps set flags = flags || array[
    'R023 — places: subtasks[].loc moves from a label to an akatsuki_places id. The view resolves both meanwhile. WF''s own place list (A2) is retired; "+ New…" calls akatsuki_place_add.']::text[], updated_at = now()
   where user_id = u and id = 'wf' and not exists (select 1 from unnest(flags) f where f like 'R023 — places%');
  update akatsuki_apps set flags = flags || array[
    'R023 — places: roadmap_locations (0004) is replaced by akatsuki_places. roadmap_role_locations keeps its rows but its location id points at akatsuki_places.id. Stage 2 Settings edits places through the hub RPCs.']::text[], updated_at = now()
   where user_id = u and id = 'rm' and not exists (select 1 from unnest(flags) f where f like 'R023 — places%');
end $$;

-- ─── Verify ──────────────────────────────────────────────────────────────────
select id, label, class, aliases, ord, added_by from akatsuki_places where retired_at is null order by ord, id;
select loc, place_id, place_class, count(*) from akatsuki_task_tags where loc is not null group by 1, 2, 3 order by 4 desc;
-- every loc must resolve — expect 0 rows:
select distinct loc from akatsuki_task_tags where loc is not null and place_id is null;
