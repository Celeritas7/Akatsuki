-- R018 · fix (Oct 5) — the 30 m merge in akatsuki_anchor_add moved the Home point into test area "Test B"
-- (and could overwrite its label/radius).  Deleting Test B then hid Home.
-- 1 restores every anchor that was pulled out of its Cost area, from Cost's own row.
-- 2 changes the merge rule: merge only inside the SAME area; never relabel or resize a confirmed anchor.
-- Run whole file once.  Deletes nothing.

-- 1 · restore from Cost (area, label, radius, position) for any copied anchor that now differs
update akatsuki_anchors n set
  area_id = c.area_id::text, label = c.label, radius_m = c.radius_m, lat = c.lat, lng = c.lng,
  retired_at = null, seq = nextval('akatsuki_seq'), updated_at = now()
from cost_management_area_points c
where n.user_id = c.user_id and n.id = c.id::text
  and (n.area_id is distinct from c.area_id::text or n.label is distinct from c.label or n.radius_m is distinct from c.radius_m);

-- 2 · the merge rule
create or replace function akatsuki_anchor_add(p_area_id text, p_lat double precision, p_lng double precision, p_label text default null,
                                               p_entity_ref jsonb default null, p_source text default 'manual', p_app text default null,
                                               p_radius_m int default 200)
returns text language plpgsql security definer set search_path = public as $$
declare v_id text := gen_random_uuid()::text; v_near text; v_conf boolean;
begin
  if auth.uid() is null then perform akatsuki_fail('42501', 'not_signed_in', 'anchor_add needs a signed-in user'); end if;
  if p_lat is null or p_lng is null then perform akatsuki_fail('AK102', 'missing_field', 'lat and lng are required'); end if;
  if coalesce(trim(p_app), '') = '' then perform akatsuki_fail('AK102', 'missing_field', 'p_app is required'); end if;
  -- Merge only with a live anchor within 30 m IN THE SAME AREA.  Another area's anchor nearby is left alone.
  select id, confirmed into v_near, v_conf from akatsuki_anchors
   where user_id = auth.uid() and retired_at is null
     and area_id is not distinct from p_area_id
     and akatsuki_distance_m(lat, lng, p_lat, p_lng) <= 30
   order by akatsuki_distance_m(lat, lng, p_lat, p_lng) limit 1;
  if v_near is not null then
    -- A confirmed anchor keeps its label and radius; only an unconfirmed one takes the new values.
    update akatsuki_anchors set
      label      = case when v_conf then label else coalesce(nullif(trim(p_label), ''), label) end,
      radius_m   = case when v_conf then radius_m else coalesce(p_radius_m, radius_m) end,
      entity_ref = coalesce(entity_ref, p_entity_ref),
      confirmed  = confirmed or coalesce(p_source, 'manual') = 'manual',
      last_seen = now(), visits = visits + 1, seq = nextval('akatsuki_seq'), updated_at = now()
     where user_id = auth.uid() and id = v_near;
    return v_near;
  end if;
  insert into akatsuki_anchors (user_id, id, area_id, label, entity_ref, lat, lng, radius_m, source, confirmed, added_by)
  values (auth.uid(), v_id, p_area_id, nullif(trim(p_label), ''), p_entity_ref, p_lat, p_lng, coalesce(p_radius_m, 200),
          coalesce(p_source, 'manual'), coalesce(p_source, 'manual') = 'manual', p_app);
  return v_id;
end $$;

-- check: expect  Home · 西浦和 · visible
select n.label, a.label area, case when n.retired_at is null and a.retired_at is null then 'visible' else 'hidden' end state
  from akatsuki_anchors n join akatsuki_areas a on a.user_id = n.user_id and a.id = n.area_id
 where n.id = '7338acb4-212a-4d81-881e-9ce5e332077e';
