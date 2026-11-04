-- ============================================================================
-- Akatsuki R063 · arrival broadcasts at AREAS too (Cost's "sub hubs") — 2026-11-04.  Idempotent.  After R062.
-- The person's choice: the Japan picker shows "My places" (akatsuki_places) and "Areas" (akatsuki_areas,
-- the list Cost shows as its areas: 浦和, 南浦和, 新大久保, Ageo office …).
--
--   A rule targets a place OR an area (exactly one).  An area rule fires when a visit begins inside the area:
--     · the visit's anchor belongs to the area (akatsuki_anchors.area_id — Cost's area points), or
--     · the visit is within the area's radius of its centre, or within the radius of one of its anchors.
--   Same guards as R062: arrivals after the rule was made, within the last 2 h, once a day per rule for
--   daily_first (Asia/Tokyo date), 'once' rules retire after firing, errors never block the visit write.
--   Area rules fire on a visit's INSERT (when it opens); place rules also on a later naming (UPDATE of place_id).
--
-- akatsuki_broadcast_rule_add gets p_area_id (named-argument calls from the R062 panel still work).
-- ============================================================================

-- ═══ A · rules can target an area ══════════════════════════════════════════
alter table public.akatsuki_broadcast_rules add column if not exists area_id text;
alter table public.akatsuki_broadcast_rules alter column place_id drop not null;
alter table public.akatsuki_broadcast_rules drop constraint if exists akatsuki_broadcast_rules_area_fk;
alter table public.akatsuki_broadcast_rules add constraint akatsuki_broadcast_rules_area_fk
  foreign key (user_id, area_id) references public.akatsuki_areas (user_id, id);
alter table public.akatsuki_broadcast_rules drop constraint if exists akatsuki_broadcast_rules_one_target;
alter table public.akatsuki_broadcast_rules add constraint akatsuki_broadcast_rules_one_target
  check ((place_id is null) <> (area_id is null));
create index if not exists akatsuki_broadcast_rules_area_idx on public.akatsuki_broadcast_rules (user_id, area_id) where state = 'active';


-- ═══ B · the add RPC takes a place or an area ══════════════════════════════
drop function if exists public.akatsuki_broadcast_rule_add(text, text, text, text, text);
create or replace function public.akatsuki_broadcast_rule_add(p_place_id text, p_title text, p_body text default null,
                                                              p_mode text default 'daily_first', p_app text default null,
                                                              p_area_id text default null)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare v uuid;
begin
  if auth.uid() is null then perform akatsuki_fail('42501', 'not_signed_in', 'sign in first'); end if;
  if char_length(btrim(coalesce(p_title, ''))) not between 1 and 120 then perform akatsuki_fail('AK102', 'bad_title', 'title must be 1–120 characters'); end if;
  if char_length(coalesce(p_body, '')) > 1000 then perform akatsuki_fail('AK102', 'bad_body', 'body must be at most 1000 characters'); end if;
  if coalesce(p_mode, '') not in ('daily_first', 'once') then perform akatsuki_fail('AK102', 'bad_mode', 'mode is daily_first or once'); end if;
  if (nullif(p_place_id, '') is null) = (nullif(p_area_id, '') is null) then
    perform akatsuki_fail('AK102', 'bad_target', 'give a place or an area (one of them)');
  end if;
  if nullif(p_place_id, '') is not null and not exists (
       select 1 from akatsuki_places pl where pl.user_id = auth.uid() and pl.id = p_place_id
          and pl.retired_at is null and pl.lat is not null and pl.lng is not null) then
    perform akatsuki_fail('AK102', 'bad_place', 'unknown place, or the place has no coordinates');
  end if;
  if nullif(p_area_id, '') is not null and not exists (
       select 1 from akatsuki_areas ar where ar.user_id = auth.uid() and ar.id = p_area_id
          and ar.retired_at is null and ar.lat is not null and ar.lng is not null) then
    perform akatsuki_fail('AK102', 'bad_area', 'unknown area, or the area has no coordinates');
  end if;
  insert into akatsuki_broadcast_rules (user_id, place_id, area_id, title, body, mode, created_by)
  values (auth.uid(), nullif(p_place_id, ''), nullif(p_area_id, ''), btrim(p_title), nullif(btrim(coalesce(p_body, '')), ''), p_mode,
          left(coalesce(nullif(btrim(p_app), ''), akatsuki_actor()), 40))
  returning id into v;
  return v;
end $$;
revoke execute on function akatsuki_broadcast_rule_add(text, text, text, text, text, text) from public, anon;
grant  execute on function akatsuki_broadcast_rule_add(text, text, text, text, text, text) to authenticated;


-- ═══ C · the arrival trigger: places (as R062) + areas ═════════════════════
create or replace function public.akatsuki_broadcast_on_arrival()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare r akatsuki_broadcast_rules; d date; v uuid; v_area_ok boolean; v_by text; v_place_new boolean;
begin
  -- OLD is only safe to read on UPDATE: decide once whether the visit has a newly set place
  if tg_op = 'UPDATE' then v_place_new := old.place_id is distinct from new.place_id; else v_place_new := true; end if;
  if new.since < now() - interval '2 hours' then return new; end if;            -- backlog, not an arrival now
  d := (new.since at time zone 'Asia/Tokyo')::date;
  begin
    for r in select * from akatsuki_broadcast_rules br
              where br.user_id = new.user_id and br.state = 'active' and br.created_at <= new.since
                and (   -- place rules: the visit has (or just got) this place
                        (br.place_id is not null and br.place_id = new.place_id and v_place_new)
                     or -- area rules: only when the visit opens
                        (br.area_id is not null and tg_op = 'INSERT'))
              order by br.created_at
              for update loop
      if r.mode = 'daily_first' and r.last_fired_on = d then continue; end if;
      if r.area_id is not null then
        select exists (select 1 from akatsuki_anchors n where n.user_id = new.user_id and n.id = new.anchor_id and n.area_id = r.area_id)
            or exists (select 1 from akatsuki_areas a where a.user_id = new.user_id and a.id = r.area_id and a.lat is not null
                         and new.lat is not null and akatsuki_distance_m(new.lat, new.lng, a.lat, a.lng) <= coalesce(a.radius_m, 500))
            or exists (select 1 from akatsuki_anchors n where n.user_id = new.user_id and n.area_id = r.area_id and n.retired_at is null
                         and n.lat is not null and new.lat is not null
                         and akatsuki_distance_m(new.lat, new.lng, n.lat, n.lng) <= coalesce(n.radius_m, 100))
          into v_area_ok;
        if not v_area_ok then continue; end if;
        v_by := left('arrive:' || coalesce((select a.label from akatsuki_areas a where a.user_id = new.user_id and a.id = r.area_id), r.area_id), 40);
      else
        v_by := left('arrive:' || r.place_id, 40);
      end if;
      insert into akatsuki_broadcasts (user_id, title, body, due_at, created_by, rule_id)
      values (r.user_id, r.title, r.body, now(), v_by, r.id)
      returning id into v;
      update akatsuki_broadcast_rules
         set last_fired_on = d, last_fired_at = now(), fired_count = fired_count + 1,
             state = case when mode = 'once' then 'fired' else state end, updated_at = now()
       where id = r.id;
    end loop;
  exception when others then
    raise warning 'akatsuki_broadcast_on_arrival: % (%)', sqlerrm, sqlstate;   -- never block the visit write
  end;
  return new;
end $$;
revoke execute on function akatsuki_broadcast_on_arrival() from public, anon, authenticated;
-- the R062 trigger (after insert or update of place_id on akatsuki_visits) keeps calling this function.
