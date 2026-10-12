-- ═══════════════════════════════════════════════════════════════════════════
-- Akatsuki R018 · part A2 — fills the contract gaps Cost v49 reported (Oct 5).
-- Run whole file, once.  Idempotent.  Deletes nothing in Cost.
--   1 area_edit (rename · country · radius · retire)           — Cost gap 1
--   2 area_add takes p_country; ids minted as uuid text         — Cost gap 2 + live ids are uuid (probe Q3)
--   3 anchor_add takes p_radius_m                               — Cost gap 3
--   Param names Cost guessed (p_app, p_patch) are correct.  'auto' anchors ARE stored confirmed = false.
-- Signatures change → old functions dropped first (PostgREST can't pick between overloads with defaults).
-- ═══════════════════════════════════════════════════════════════════════════

drop function if exists akatsuki_area_add(text, double precision, double precision, int, text);
drop function if exists akatsuki_anchor_add(text, double precision, double precision, text, jsonb, text, text);

-- country: 'JP' | 'IN' | null.  Cost may pass its currency instead ('JPY'/'INR'); mapped here so Cost never stores a currency in the hub.
create or replace function akatsuki_country_of(p text)
returns text language sql immutable as $$
  select case upper(coalesce(p, '')) when 'JPY' then 'JP' when 'JP' then 'JP' when 'INR' then 'IN' when 'IN' then 'IN' else null end
$$;

create function akatsuki_area_add(p_label text, p_lat double precision, p_lng double precision,
                                  p_radius_m int default 500, p_country text default null, p_app text default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_id text := gen_random_uuid()::text; v_c text := akatsuki_country_of(p_country);
begin
  if auth.uid() is null then perform akatsuki_fail('42501', 'not_signed_in', 'area_add needs a signed-in user'); end if;
  if coalesce(trim(p_label), '') = '' then perform akatsuki_fail('AK102', 'missing_field', 'label is required'); end if;
  if coalesce(trim(p_app), '') = '' then perform akatsuki_fail('AK102', 'missing_field', 'p_app is required'); end if;
  insert into akatsuki_areas (user_id, id, label, lat, lng, radius_m, country, tz, added_by)
  values (auth.uid(), v_id, trim(p_label), p_lat, p_lng, coalesce(p_radius_m, 500), v_c,
          case v_c when 'JP' then 'Asia/Tokyo' when 'IN' then 'Asia/Kolkata' end, p_app);
  return v_id;
end $$;

create or replace function akatsuki_area_edit(p_id text, p_patch jsonb, p_app text)
returns void language plpgsql security definer set search_path = public as $$
declare v_c text;
begin
  if auth.uid() is null then perform akatsuki_fail('42501', 'not_signed_in', 'area_edit needs a signed-in user'); end if;
  if p_patch ? 'label' and coalesce(trim(p_patch->>'label'), '') = '' then perform akatsuki_fail('AK102', 'missing_field', 'label cannot be empty'); end if;
  v_c := case when p_patch ? 'country' then akatsuki_country_of(p_patch->>'country')
              when p_patch ? 'region'  then akatsuki_country_of(p_patch->>'region') end;
  update akatsuki_areas x set
    label      = coalesce(nullif(trim(p_patch->>'label'), ''), x.label),
    lat        = coalesce((p_patch->>'lat')::double precision, x.lat),
    lng        = coalesce((p_patch->>'lng')::double precision, x.lng),
    radius_m   = coalesce((p_patch->>'radius_m')::int, x.radius_m),
    country    = case when p_patch ? 'country' or p_patch ? 'region' then v_c else x.country end,
    tz         = case when p_patch ? 'country' or p_patch ? 'region' then case v_c when 'JP' then 'Asia/Tokyo' when 'IN' then 'Asia/Kolkata' end else x.tz end,
    retired_at = case when (p_patch->>'retire')::boolean then now() when (p_patch->>'retire')::boolean is false then null else x.retired_at end,
    seq = nextval('akatsuki_seq'), updated_at = now()
   where x.user_id = auth.uid() and x.id = p_id;
  if not found then perform akatsuki_fail('AK115', 'area_unknown', format('no area %s', p_id)); end if;
  -- Retiring an area never deletes its anchors; they keep area_id and are hidden with it in the Cost view.
end $$;

create function akatsuki_anchor_add(p_area_id text, p_lat double precision, p_lng double precision, p_label text default null,
                                    p_entity_ref jsonb default null, p_source text default 'manual', p_app text default null,
                                    p_radius_m int default 200)
returns text language plpgsql security definer set search_path = public as $$
declare v_id text := gen_random_uuid()::text; v_near text;
begin
  if auth.uid() is null then perform akatsuki_fail('42501', 'not_signed_in', 'anchor_add needs a signed-in user'); end if;
  if p_lat is null or p_lng is null then perform akatsuki_fail('AK102', 'missing_field', 'lat and lng are required'); end if;
  if coalesce(trim(p_app), '') = '' then perform akatsuki_fail('AK102', 'missing_field', 'p_app is required'); end if;
  select id into v_near from akatsuki_anchors
   where user_id = auth.uid() and retired_at is null and akatsuki_distance_m(lat, lng, p_lat, p_lng) <= 30
   order by akatsuki_distance_m(lat, lng, p_lat, p_lng) limit 1;
  if v_near is not null then
    -- Merge into the existing anchor.  An 'auto' sighting never demotes a confirmed anchor, and never overwrites its radius.
    update akatsuki_anchors set label = coalesce(nullif(trim(p_label), ''), label), entity_ref = coalesce(p_entity_ref, entity_ref),
      area_id = coalesce(p_area_id, area_id),
      radius_m = case when coalesce(p_source, 'manual') = 'manual' and p_radius_m is not null then p_radius_m else radius_m end,
      last_seen = now(), visits = visits + 1, seq = nextval('akatsuki_seq'), updated_at = now()
     where user_id = auth.uid() and id = v_near;
    return v_near;
  end if;
  insert into akatsuki_anchors (user_id, id, area_id, label, entity_ref, lat, lng, radius_m, source, confirmed, added_by)
  values (auth.uid(), v_id, p_area_id, nullif(trim(p_label), ''), p_entity_ref, p_lat, p_lng, coalesce(p_radius_m, 200),
          coalesce(p_source, 'manual'), coalesce(p_source, 'manual') = 'manual', p_app);
  return v_id;
end $$;

grant execute on function akatsuki_area_add(text, double precision, double precision, int, text, text),
  akatsuki_area_edit(text, jsonb, text),
  akatsuki_anchor_add(text, double precision, double precision, text, jsonb, text, text, int),
  akatsuki_country_of(text) to authenticated;
revoke execute on function akatsuki_area_add(text, double precision, double precision, int, text, text),
  akatsuki_area_edit(text, jsonb, text),
  akatsuki_anchor_add(text, double precision, double precision, text, jsonb, text, text, int) from anon;

-- Cost view: anchors of a retired area hidden too (so "Delete area" hides its spots, as Cost's cascade did, without deleting).
create or replace view akatsuki_cost_area_points with (security_invoker = on) as
select n.id, n.area_id, n.lat, n.lng, n.radius_m, n.label, n.source, n.confirmed, n.first_seen as created_at,
       n.entity_ref->>'name' as shop_name
  from akatsuki_anchors n
  left join akatsuki_areas a on a.user_id = n.user_id and a.id = n.area_id
 where n.retired_at is null and (a.id is null or a.retired_at is null);
grant select on akatsuki_cost_area_points to authenticated;

do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
begin
  insert into akatsuki_vocab (user_id, ns, id, schema, meta) values
  (u, 'error', 'AK115', null, '{"name":"area_unknown","class":"contract","by":"area_edit","fix":"id must be an akatsuki_areas row"}')
  on conflict (user_id, ns, id) do update set meta = excluded.meta;
end $$;

-- ─── checks — paste results ─────────────────────────────────────────────────
-- C1  the 3 functions with their argument lists
select p.proname, pg_get_function_identity_arguments(p.oid) args
  from pg_proc p where p.proname in ('akatsuki_area_add','akatsuki_area_edit','akatsuki_anchor_add') order by 1;
-- C2  Cost's own compare (from its reply): areas — empty = lists match
select coalesce(c.id::text, h.id) id, c.name cost_name, h.name hub_name, c.region c_reg, h.region h_reg
  from cost_management_areas c full join akatsuki_cost_areas h on h.id = c.id::text
 where c.id is null or h.id is null or c.name is distinct from h.name or c.lat is distinct from h.lat
    or c.lng is distinct from h.lng or c.radius_m is distinct from h.radius_m or c.region is distinct from h.region;
