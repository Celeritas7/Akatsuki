-- ═══════════════════════════════════════════════════════════════════════════
-- Akatsuki R018 · part A — location handover from Cost, gates G2 + G3.
-- Run in wylxvmkcrexwfpjpbhyy, whole file, Run.  Idempotent.  Deletes NOTHING in Cost.
--
-- G2  areas + anchors: hub tables, filled from Cost's 9 areas and 11 area_points (uuid kept as text id).
--     Cost's own tables stay; Cost switches to the hub view/RPCs in its next build, user verifies, THEN Cost retires its copy.
-- G3  Google Places via hub Edge Function `akatsuki-places-nearby` (deploy separately — see supabase/functions/).
--     Cap + usage counted server-side (fixes Cost B8: anon key could spend quota).  Cache in akatsuki_cache.
-- Not in this file: visits, coverage, devices, stop settings (G4 — needs akatsuki-location.js, D1/D2 confirmed Oct 5).
-- ═══════════════════════════════════════════════════════════════════════════

-- ═══ A · tables ═════════════════════════════════════════════════════════════
create table if not exists akatsuki_areas (
  user_id    uuid not null default auth.uid(),
  id         text not null,                   -- Cost's uuid as text on migration; slug for new ones
  label      text not null,
  lat        double precision,
  lng        double precision,
  radius_m   int not null default 500,
  country    text,                            -- 'JP'  (replaces Cost's region = currency code)
  tz         text,                            -- 'Asia/Tokyo'
  added_by   text not null,
  seq        bigint not null default nextval('akatsuki_seq'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  retired_at timestamptz,
  primary key (user_id, id)
);

create table if not exists akatsuki_anchors (
  user_id    uuid not null default auth.uid(),
  id         text not null,
  area_id    text,
  place_id   text,                            -- → akatsuki_places.id once promoted to a named place
  label      text,
  entity_ref jsonb,                           -- {"app":"cost","kind":"shop","name":"…"} — replaces label==shop-name convention
  lat        double precision not null,
  lng        double precision not null,
  radius_m   int not null default 200,
  source     text not null default 'manual',  -- manual | auto
  confirmed  boolean not null default true,
  visits     int not null default 0,
  first_seen timestamptz not null default now(),
  last_seen  timestamptz not null default now(),
  added_by   text not null,
  seq        bigint not null default nextval('akatsuki_seq'),
  updated_at timestamptz not null default now(),
  retired_at timestamptz,
  primary key (user_id, id)
);
create index if not exists akatsuki_anchors_area on akatsuki_anchors (user_id, area_id);

do $$
declare t text;
begin
  foreach t in array array['akatsuki_areas','akatsuki_anchors'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists %I on %I', t || '_owner', t);
    execute format('create policy %I on %I for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid())', t || '_owner', t);
  end loop;
end $$;
grant select on akatsuki_areas, akatsuki_anchors to authenticated;

-- ═══ B · migration from Cost (copy, not move) ══════════════════════════════
-- Cost tables are untouched.  Re-running re-syncs labels/positions; hub-side edits after adoption win (updated_at check).
insert into akatsuki_areas (user_id, id, label, lat, lng, radius_m, country, tz, added_by, created_at, updated_at)
select user_id, id::text, name, lat, lng, radius_m,
       case when region = 'JPY' then 'JP' when region = 'INR' then 'IN' else null end,
       case when region = 'JPY' then 'Asia/Tokyo' when region = 'INR' then 'Asia/Kolkata' else null end,
       'cost', created_at, updated_at
  from cost_management_areas
on conflict (user_id, id) do update set
  label = excluded.label, lat = excluded.lat, lng = excluded.lng, radius_m = excluded.radius_m, updated_at = now()
  where akatsuki_areas.updated_at <= excluded.updated_at;

insert into akatsuki_anchors (user_id, id, area_id, label, entity_ref, lat, lng, radius_m, source, confirmed, added_by, first_seen, last_seen)
select ap.user_id, ap.id::text, ap.area_id::text, ap.label,
       -- Cost convention: label == exact shop name makes the pin that shop.  Preserved as an explicit ref.
       case when ap.label is not null and exists (select 1 from cost_management_shops s where s.user_id = ap.user_id and s.name = ap.label)
            then jsonb_build_object('app','cost','kind','shop','name',ap.label) end,
       ap.lat, ap.lng, ap.radius_m, ap.source, ap.confirmed, 'cost', ap.created_at, ap.created_at
  from cost_management_area_points ap
on conflict (user_id, id) do update set
  label = excluded.label, entity_ref = coalesce(akatsuki_anchors.entity_ref, excluded.entity_ref),
  lat = excluded.lat, lng = excluded.lng, radius_m = excluded.radius_m, confirmed = excluded.confirmed, updated_at = now();

-- ═══ C · RPCs — the only write path for apps ═══════════════════════════════
create or replace function akatsuki_area_add(p_label text, p_lat double precision, p_lng double precision, p_radius_m int, p_app text)
returns text language plpgsql security definer set search_path = public as $$
declare v_id text;
begin
  if auth.uid() is null then perform akatsuki_fail('42501', 'not_signed_in', 'area_add needs a signed-in user'); end if;
  if coalesce(trim(p_label), '') = '' then perform akatsuki_fail('AK102', 'missing_field', 'label is required'); end if;
  v_id := akatsuki_place_slug(p_label);
  insert into akatsuki_areas (user_id, id, label, lat, lng, radius_m, added_by)
  values (auth.uid(), v_id, trim(p_label), p_lat, p_lng, coalesce(p_radius_m, 500), p_app)
  on conflict (user_id, id) do update set
    label = excluded.label, lat = coalesce(excluded.lat, akatsuki_areas.lat), lng = coalesce(excluded.lng, akatsuki_areas.lng),
    radius_m = excluded.radius_m, retired_at = null, seq = nextval('akatsuki_seq'), updated_at = now();
  return v_id;
end $$;

create or replace function akatsuki_anchor_add(p_area_id text, p_lat double precision, p_lng double precision, p_label text,
                                               p_entity_ref jsonb, p_source text, p_app text)
returns text language plpgsql security definer set search_path = public as $$
declare v_id text := gen_random_uuid()::text; v_near text;
begin
  if auth.uid() is null then perform akatsuki_fail('42501', 'not_signed_in', 'anchor_add needs a signed-in user'); end if;
  if p_lat is null or p_lng is null then perform akatsuki_fail('AK102', 'missing_field', 'lat and lng are required'); end if;
  -- Within 30 m of a live anchor → that anchor is updated, not duplicated (the Sep 21 folder race, inverted).
  select id into v_near from akatsuki_anchors
   where user_id = auth.uid() and retired_at is null
     and akatsuki_distance_m(lat, lng, p_lat, p_lng) <= 30
   order by akatsuki_distance_m(lat, lng, p_lat, p_lng) limit 1;
  if v_near is not null then
    update akatsuki_anchors set label = coalesce(nullif(trim(p_label), ''), label), entity_ref = coalesce(p_entity_ref, entity_ref),
      area_id = coalesce(p_area_id, area_id), last_seen = now(), visits = visits + 1, seq = nextval('akatsuki_seq'), updated_at = now()
     where user_id = auth.uid() and id = v_near;
    return v_near;
  end if;
  insert into akatsuki_anchors (user_id, id, area_id, label, entity_ref, lat, lng, source, confirmed, added_by)
  values (auth.uid(), v_id, p_area_id, nullif(trim(p_label), ''), p_entity_ref, p_lat, p_lng,
          coalesce(p_source, 'manual'), coalesce(p_source, 'manual') = 'manual', p_app);
  return v_id;
end $$;

create or replace function akatsuki_anchor_edit(p_id text, p_patch jsonb, p_app text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then perform akatsuki_fail('42501', 'not_signed_in', 'anchor_edit needs a signed-in user'); end if;
  update akatsuki_anchors x set
    label      = coalesce(nullif(trim(p_patch->>'label'), ''), x.label),
    area_id    = coalesce(p_patch->>'area_id', x.area_id),
    place_id   = coalesce(p_patch->>'place_id', x.place_id),
    entity_ref = coalesce(p_patch->'entity_ref', x.entity_ref),
    radius_m   = coalesce((p_patch->>'radius_m')::int, x.radius_m),
    confirmed  = coalesce((p_patch->>'confirmed')::boolean, x.confirmed),
    retired_at = case when (p_patch->>'retire')::boolean then now() else x.retired_at end,
    seq = nextval('akatsuki_seq'), updated_at = now()
   where x.user_id = auth.uid() and x.id = p_id;
  if not found then perform akatsuki_fail('AK114', 'anchor_unknown', format('no anchor %s', p_id)); end if;
end $$;

create or replace function akatsuki_distance_m(a_lat double precision, a_lng double precision, b_lat double precision, b_lng double precision)
returns double precision language sql immutable as $$
  select 6371000 * 2 * asin(sqrt(power(sin(radians(b_lat - a_lat) / 2), 2)
       + cos(radians(a_lat)) * cos(radians(b_lat)) * power(sin(radians(b_lng - a_lng) / 2), 2)))
$$;

grant execute on function akatsuki_area_add(text, double precision, double precision, int, text),
  akatsuki_anchor_add(text, double precision, double precision, text, jsonb, text, text),
  akatsuki_anchor_edit(text, jsonb, text), akatsuki_distance_m(double precision, double precision, double precision, double precision) to authenticated;
revoke execute on function akatsuki_area_add(text, double precision, double precision, int, text),
  akatsuki_anchor_add(text, double precision, double precision, text, jsonb, text, text),
  akatsuki_anchor_edit(text, jsonb, text) from anon;

-- ═══ D · view Cost reads during G2 (shape close to Cost's own, so the adapter is a column rename) ══
create or replace view akatsuki_cost_areas with (security_invoker = on) as
select a.id, a.label as name, a.lat, a.lng, a.radius_m, a.created_at, a.updated_at,
       case a.country when 'JP' then 'JPY' when 'IN' then 'INR' end as region   -- Cost's currency, derived
  from akatsuki_areas a where a.retired_at is null;
create or replace view akatsuki_cost_area_points with (security_invoker = on) as
select n.id, n.area_id, n.lat, n.lng, n.radius_m, n.label, n.source, n.confirmed, n.first_seen as created_at,
       n.entity_ref->>'name' as shop_name
  from akatsuki_anchors n where n.retired_at is null;
grant select on akatsuki_cost_areas, akatsuki_cost_area_points to authenticated;

-- ═══ E · Google Places: cap + usage, server-side ═══════════════════════════
-- Called by the Edge Function with the USER's JWT (never service role), so RLS scopes it.  Returns the new count, or fails AK210 when capped.
create or replace function akatsuki_places_budget_take()
returns int language plpgsql security definer set search_path = public as $$
declare v_month text := to_char(now() at time zone 'Asia/Tokyo', 'YYYY-MM'); v_calls int; v_cap int;
begin
  if auth.uid() is null then perform akatsuki_fail('42501', 'not_signed_in', 'budget needs a signed-in user'); end if;
  select coalesce((payload->>'cap')::int, 1000) into v_cap from akatsuki_cache
   where user_id = auth.uid() and source = 'places_usage' and key = 'cap';
  v_cap := coalesce(v_cap, 1000);
  insert into akatsuki_cache (user_id, source, key, payload, expires_at)
  values (auth.uid(), 'places_usage', v_month, '{"calls":1}', null)
  on conflict (user_id, source, key) do update
    set payload = jsonb_set(akatsuki_cache.payload, '{calls}', to_jsonb(coalesce((akatsuki_cache.payload->>'calls')::int, 0) + 1)), fetched_at = now()
  returning (payload->>'calls')::int into v_calls;
  if v_calls > v_cap then perform akatsuki_fail('AK210', 'places_capped', format('Google budget used (%s/%s this month)', v_calls - 1, v_cap)); end if;
  return v_calls;
end $$;
grant execute on function akatsuki_places_budget_take() to authenticated;
revoke execute on function akatsuki_places_budget_take() from anon;

-- Nearest cached corner within 100 m (Cost's rule), unexpired.
create or replace function akatsuki_places_cache_get(p_lat double precision, p_lng double precision)
returns jsonb language sql stable security invoker set search_path = public as $$
  select c.payload from akatsuki_cache c
   where c.user_id = auth.uid() and c.source = 'places_nearby'
     and (c.expires_at is null or c.expires_at > now())
     and akatsuki_distance_m((c.payload->'q'->>'lat')::double precision, (c.payload->'q'->>'lng')::double precision, p_lat, p_lng) <= 100
   order by akatsuki_distance_m((c.payload->'q'->>'lat')::double precision, (c.payload->'q'->>'lng')::double precision, p_lat, p_lng)
   limit 1
$$;
grant execute on function akatsuki_places_cache_get(double precision, double precision) to authenticated;

-- ═══ F · registry: vocab · credentials · sources · routes ═════════════════
do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
begin
  insert into akatsuki_vocab (user_id, ns, id, schema, meta) values
  (u, 'error', 'AK114', null, '{"name":"anchor_unknown","class":"contract","by":"anchor_edit","fix":"id must be a live akatsuki_anchors row"}'),
  (u, 'error', 'AK210', null, '{"name":"places_capped","class":"outcome","by":"places_budget_take","fix":"monthly Google cap reached; raise cap row (places_usage/cap) or wait for next month"}'),
  (u, 'kind', 'place.nearby', '{"type":"object","required":["lat","lng"],"properties":{"lat":{"type":"number"},"lng":{"type":"number"},"force":{"type":"boolean"}}}',
     '{"owner":"hub","direction":"app → hub Edge Function akatsuki-places-nearby","reply":"{status: hit|fetched|empty|capped|error, candidates:[{place_id,name,types,lat,lng,distance_m}]}","note":"button-only; a detector-driven lookup must be queued, never synchronous"}')
  on conflict (user_id, ns, id) do update set schema = excluded.schema, meta = excluded.meta;

  insert into akatsuki_credentials (user_id, name, scope, location, consumers, rotated_at) values
  (u, 'google_places', 'GOOGLE_PLACES_API_KEY — Supabase Edge secret, read by akatsuki-places-nearby (hub) and places-nearby (Cost, retires at G3)', 'edge_env', '{hub,cost}', null)
  on conflict (user_id, name) do update set scope = excluded.scope, location = excluded.location, consumers = excluded.consumers;

  insert into akatsuki_sources (user_id, id, name, kind, endpoint, credential, fetch_policy, quota, emits, consumers, cache_ttl) values
  (u, 'places_nearby', 'Google Places (New) searchNearby', 'api', 'supabase/functions/akatsuki-places-nearby', 'google_places',
     'on tap, cache-first (nearest corner ≤ 100 m) · counted + capped server-side (akatsuki_places_budget_take)',
     'akatsuki_cache places_usage/<YYYY-MM> · cap row places_usage/cap (default 1000)', 'place.nearby', '{cost}', interval '30 days')
  on conflict (user_id, id) do update set
    name = excluded.name, endpoint = excluded.endpoint, fetch_policy = excluded.fetch_policy, quota = excluded.quota, cache_ttl = excluded.cache_ttl;

  insert into akatsuki_routes (user_id, from_app, to_app, kind, access, state, note) values
  (u, 'hub', 'cost', 'areas',        'view', 'half', 'R018 G2 — Cost reads akatsuki_cost_areas / _area_points, writes via akatsuki_area_add / anchor_add / anchor_edit. Live when ShopAreasPanel shows the hub list and the 4 write sites hit the RPCs; THEN Cost retires cost_management_areas/area_points/shop_locations→re-key.'),
  (u, 'cost', 'hub', 'place.nearby', 'stream', 'half', 'R018 G3 · reply-shaped call to Edge Fn — Cost invokes akatsuki-places-nearby instead of places-nearby. Live when one tap returns candidates with place_id and places_usage increments; THEN Cost deletes its places-nearby function.')
  on conflict do nothing;

  -- Cost's direct reads of its own location tables are its domain — not flagged.  Flag only the exposure Cost reported:
  update akatsuki_credentials set scope = scope || ' · ⚠ Cost fn: CORS * + default JWT only, cap client-side (B8) — closed by G3'
   where user_id = u and name = 'google_places' and scope not like '%B8%';
end $$;

-- ═══ G · gate queries — paste results ══════════════════════════════════════
-- G2a  expect 9 / 11, all added_by cost
select 'areas' t, count(*), count(*) filter (where added_by = 'cost') from_cost from akatsuki_areas
union all select 'anchors', count(*), count(*) filter (where added_by = 'cost') from akatsuki_anchors;
-- G2b  anchors that resolved to a Cost shop (entity_ref set) vs plain pins
select count(*) filter (where entity_ref is not null) shop_pins, count(*) filter (where entity_ref is null) plain from akatsuki_anchors;
-- G2c  the 3 Cost blocks → which anchors do they sit on?  (D2: these become places home/office in R018 part B)
select b.label block, n.label anchor, round(akatsuki_distance_m(b.lat, b.lng, n.lat, n.lng)) d_m
  from cost_management_stop_blocks b join akatsuki_anchors n on akatsuki_distance_m(b.lat, b.lng, n.lat, n.lng) <= 150 order by 1, 3;
-- G3a  registry
select id, endpoint, consumers from akatsuki_sources where id = 'places_nearby';
select from_app, to_app, kind, state from akatsuki_routes where kind in ('areas','place.nearby');
