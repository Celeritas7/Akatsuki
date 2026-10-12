-- ═══════════════════════════════════════════════════════════════════════════
-- Akatsuki R018 · part B — the hub's visit detector (gate G4).  Oct 6.
-- Run in wylxvmkcrexwfpjpbhyy, whole file, Run.  Idempotent.  Deletes NOTHING in Cost.
--
-- Decisions in force (user, Oct 5):
--   D1  a visit ends at the last fix seen inside, never at resume time.  Unwatched time is recorded as coverage gaps.
--   D2  no blocks in the hub.  Home/office visits are recorded; each consumer filters (Cost keeps its own "never here").
-- Writes go through RPCs called by js/akatsuki-location.js (shipped by the hub, never forked).  Raw fixes never leave the device:
-- only a visit's eased centre (4 dp ≈ 10 m), its times and accuracy.  Visit key = (device, since).  akatsuki_seq orders writes.
-- Runs NEXT TO Cost's own detector for a comparison period; Cost's stops/stop_blocks/stop_settings stay until the user verifies.
-- Nothing is recorded while no connected app is open.
-- ═══════════════════════════════════════════════════════════════════════════

-- ═══ A · tables ═════════════════════════════════════════════════════════════
create table if not exists akatsuki_devices (
  user_id      uuid not null default auth.uid(),
  id           text not null,
  app          text not null,
  label        text,
  last_seen_at timestamptz,
  created_at   timestamptz not null default now(),
  primary key (user_id, id)
);

create table if not exists akatsuki_visits (
  user_id      uuid not null default auth.uid(),
  device       text not null,
  since        timestamptz not null,
  until        timestamptz,                   -- null while open; on close = last fix inside (D1)
  last_seen_at timestamptz not null,
  lat          double precision not null,     -- eased centre, 4 dp
  lng          double precision not null,
  radius_m     int not null default 70,
  acc_m        int,
  anchor_id    text,
  place_id     text,
  end_reason   text check (end_reason in ('left','gap','app_closed','superseded')),
  merged_into  bigint,
  source_app   text not null,
  seq          bigint not null default nextval('akatsuki_seq'),
  updated_seq  bigint not null default nextval('akatsuki_seq'),
  primary key (user_id, device, since)
);
create index if not exists akatsuki_visits_open on akatsuki_visits (user_id, device) where until is null;
create index if not exists akatsuki_visits_time on akatsuki_visits (user_id, since desc);

create table if not exists akatsuki_location_coverage (
  user_id    uuid not null default auth.uid(),
  device     text not null,
  app        text not null,
  since      timestamptz not null,
  until      timestamptz,
  seq        bigint not null default nextval('akatsuki_seq'),
  primary key (user_id, device, since)
);

create table if not exists akatsuki_stop_settings (
  user_id        uuid primary key default auth.uid(),
  enabled        boolean not null default true,
  radius_m       int not null default 70,
  dwell_s        int not null default 240,
  accuracy_max_m int not null default 150,
  stale_s        int not null default 120,
  heartbeat_s    int not null default 120,
  readopt_s      int not null default 600,
  tick_s         int not null default 20,
  updated_at     timestamptz not null default now()
);

do $$
declare t text;
begin
  foreach t in array array['akatsuki_devices','akatsuki_visits','akatsuki_location_coverage','akatsuki_stop_settings'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists %I on %I', t || '_owner', t);
    execute format('create policy %I on %I for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid())', t || '_owner', t);
  end loop;
end $$;
grant select on akatsuki_devices, akatsuki_visits, akatsuki_location_coverage, akatsuki_stop_settings to authenticated;

-- Seed settings from Cost's live cfg (generic half only; Cost keeps perCat/cats).
insert into akatsuki_stop_settings (user_id, enabled, radius_m, dwell_s)
select s.user_id,
       coalesce((s.cfg->>'enabled')::boolean, true),
       coalesce((s.cfg->>'radius')::int, 70),
       coalesce(((s.cfg->>'defaultMinutes')::numeric * 60)::int, 240)
  from cost_management_stop_settings s
on conflict (user_id) do nothing;
insert into akatsuki_stop_settings (user_id) values ('e91a5f37-e63a-4fd0-8488-4d7a51d56822') on conflict do nothing;

-- ═══ B · RPCs ═══════════════════════════════════════════════════════════════
create or replace function akatsuki_device_register(p_id text, p_app text, p_label text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then perform akatsuki_fail('42501', 'not_signed_in', 'device_register needs a signed-in user'); end if;
  if coalesce(trim(p_id), '') = '' or coalesce(trim(p_app), '') = '' then perform akatsuki_fail('AK102', 'missing_field', 'p_id and p_app are required'); end if;
  insert into akatsuki_devices (user_id, id, app, label, last_seen_at) values (auth.uid(), p_id, p_app, p_label, now())
  on conflict (user_id, id) do update set last_seen_at = now(), label = coalesce(excluded.label, akatsuki_devices.label);
end $$;

create or replace function akatsuki_coverage_mark(p_device text, p_app text, p_since timestamptz, p_until timestamptz)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then perform akatsuki_fail('42501', 'not_signed_in', 'coverage needs a signed-in user'); end if;
  insert into akatsuki_location_coverage (user_id, device, app, since, until) values (auth.uid(), p_device, p_app, p_since, p_until)
  on conflict (user_id, device, since) do update
    set until = greatest(akatsuki_location_coverage.until, excluded.until), seq = nextval('akatsuki_seq');
end $$;

-- First good fix after start: close this device's stale open visits (at their last_seen, D1); return the one to continue, if any.
create or replace function akatsuki_visit_resume(p_device text, p_lat double precision, p_lng double precision, p_acc_m int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_readopt int; v_since timestamptz; v_lat double precision; v_lng double precision;
begin
  if auth.uid() is null then perform akatsuki_fail('42501', 'not_signed_in', 'visit_resume needs a signed-in user'); end if;
  select coalesce(readopt_s, 600) into v_readopt from akatsuki_stop_settings where user_id = auth.uid();
  select since, lat, lng into v_since, v_lat, v_lng from akatsuki_visits
   where user_id = auth.uid() and device = p_device and until is null
     and last_seen_at > now() - make_interval(secs => coalesce(v_readopt, 600))
     and akatsuki_distance_m(lat, lng, p_lat, p_lng) <= radius_m + coalesce(p_acc_m, 0)
   order by since desc limit 1;
  update akatsuki_visits set until = last_seen_at, end_reason = 'app_closed', updated_seq = nextval('akatsuki_seq')
   where user_id = auth.uid() and device = p_device and until is null and since is distinct from v_since;
  if v_since is null then return null; end if;
  return jsonb_build_object('since', v_since, 'lat', v_lat, 'lng', v_lng);
end $$;

create or replace function akatsuki_visit_open(p_device text, p_since timestamptz, p_last_seen timestamptz,
                                               p_lat double precision, p_lng double precision, p_radius_m int, p_acc_m int, p_app text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_anchor text; v_place text; v_new boolean;
begin
  if auth.uid() is null then perform akatsuki_fail('42501', 'not_signed_in', 'visit_open needs a signed-in user'); end if;
  if p_device is null or p_since is null or p_lat is null or p_lng is null or coalesce(trim(p_app), '') = '' then
    perform akatsuki_fail('AK102', 'missing_field', 'device, since, lat, lng, app are required'); end if;
  -- one open visit per device
  update akatsuki_visits set until = last_seen_at, end_reason = 'superseded', updated_seq = nextval('akatsuki_seq')
   where user_id = auth.uid() and device = p_device and until is null and since <> p_since;
  select id, place_id into v_anchor, v_place from akatsuki_anchors
   where user_id = auth.uid() and retired_at is null and akatsuki_distance_m(lat, lng, p_lat, p_lng) <= radius_m
   order by akatsuki_distance_m(lat, lng, p_lat, p_lng) limit 1;
  if v_place is null then
    select id into v_place from akatsuki_places
     where user_id = auth.uid() and retired_at is null and lat is not null and radius_m is not null
       and akatsuki_distance_m(lat, lng, p_lat, p_lng) <= radius_m
     order by akatsuki_distance_m(lat, lng, p_lat, p_lng) limit 1;
  end if;
  insert into akatsuki_visits (user_id, device, since, last_seen_at, lat, lng, radius_m, acc_m, anchor_id, place_id, source_app)
  values (auth.uid(), p_device, p_since, coalesce(p_last_seen, p_since), round(p_lat::numeric, 4), round(p_lng::numeric, 4),
          coalesce(p_radius_m, 70), p_acc_m, v_anchor, v_place, p_app)
  on conflict (user_id, device, since) do nothing
  returning true into v_new;
  update akatsuki_devices set last_seen_at = now() where user_id = auth.uid() and id = p_device;
  return jsonb_build_object('status', case when v_new then 'opened' else 'exists' end, 'anchor_id', v_anchor, 'place_id', v_place);
end $$;

create or replace function akatsuki_visit_seen(p_device text, p_since timestamptz, p_last_seen timestamptz, p_acc_m int default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then perform akatsuki_fail('42501', 'not_signed_in', 'visit_seen needs a signed-in user'); end if;
  update akatsuki_visits set last_seen_at = greatest(last_seen_at, p_last_seen),
         acc_m = least(coalesce(acc_m, p_acc_m), coalesce(p_acc_m, acc_m)), updated_seq = nextval('akatsuki_seq')
   where user_id = auth.uid() and device = p_device and since = p_since and until is null;
end $$;

create or replace function akatsuki_visit_close(p_device text, p_since timestamptz, p_until timestamptz, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_seq bigint; v_lat double precision; v_lng double precision; v_until timestamptz; v_other bigint;
begin
  if auth.uid() is null then perform akatsuki_fail('42501', 'not_signed_in', 'visit_close needs a signed-in user'); end if;
  if p_reason not in ('left','gap','app_closed') then perform akatsuki_fail('AK102', 'bad_field', 'reason must be left | gap | app_closed'); end if;
  update akatsuki_visits
     set last_seen_at = greatest(last_seen_at, p_until), until = greatest(since, p_until), end_reason = p_reason,
         updated_seq = nextval('akatsuki_seq')
   where user_id = auth.uid() and device = p_device and since = p_since and until is null
  returning seq, lat, lng, until into v_seq, v_lat, v_lng, v_until;
  if v_seq is null then return; end if;
  -- Hub-merged: the same stay seen by another device → the later-starting row points at the earlier one.
  select o.seq into v_other from akatsuki_visits o
   where o.user_id = auth.uid() and o.device <> p_device and o.merged_into is null
     and o.since <= p_since and coalesce(o.until, o.last_seen_at) >= p_since
     and akatsuki_distance_m(o.lat, o.lng, v_lat, v_lng) <= 100
   order by o.since limit 1;
  if v_other is not null then
    update akatsuki_visits set merged_into = v_other where user_id = auth.uid() and device = p_device and since = p_since;
  end if;
end $$;

grant execute on function
  akatsuki_device_register(text, text, text),
  akatsuki_coverage_mark(text, text, timestamptz, timestamptz),
  akatsuki_visit_resume(text, double precision, double precision, int),
  akatsuki_visit_open(text, timestamptz, timestamptz, double precision, double precision, int, int, text),
  akatsuki_visit_seen(text, timestamptz, timestamptz, int),
  akatsuki_visit_close(text, timestamptz, timestamptz, text) to authenticated;
revoke execute on function
  akatsuki_device_register(text, text, text),
  akatsuki_coverage_mark(text, text, timestamptz, timestamptz),
  akatsuki_visit_resume(text, double precision, double precision, int),
  akatsuki_visit_open(text, timestamptz, timestamptz, double precision, double precision, int, int, text),
  akatsuki_visit_seen(text, timestamptz, timestamptz, int),
  akatsuki_visit_close(text, timestamptz, timestamptz, text) from anon;

-- ═══ C · views for consumers — no coordinates (waist rule) ═════════════════
create or replace view akatsuki_where_now with (security_invoker = on) as
select v.device, v.since, v.last_seen_at, v.anchor_id, n.label anchor_label, v.place_id, p.label place_label, p.class
  from akatsuki_visits v
  left join akatsuki_anchors n on n.user_id = v.user_id and n.id = v.anchor_id
  left join akatsuki_places p on p.user_id = v.user_id and p.id = v.place_id
 where v.until is null and v.merged_into is null and v.last_seen_at > now() - interval '10 minutes';

create or replace view akatsuki_visits_recent with (security_invoker = on) as
select v.device, v.since, v.until, v.until - v.since as dur, v.end_reason, v.anchor_id, n.label anchor_label,
       v.place_id, p.label place_label, p.class, v.source_app, v.seq
  from akatsuki_visits v
  left join akatsuki_anchors n on n.user_id = v.user_id and n.id = v.anchor_id
  left join akatsuki_places p on p.user_id = v.user_id and p.id = v.place_id
 where v.merged_into is null and v.since > now() - interval '30 days';
grant select on akatsuki_where_now, akatsuki_visits_recent to authenticated;

-- ═══ D · registry ═══════════════════════════════════════════════════════════
do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
begin
  insert into akatsuki_routes (user_id, from_app, to_app, kind, access, state, note) values
  (u, 'cost', 'hub', 'visit', 'stream', 'half',
     'R018 G4 — Cost runs js/akatsuki-location.js next to its own detector. Live after the comparison period (sql/akatsuki_location_R018_B_compare.sql) and the user''s OK; THEN Cost retires its sessionizer, stops, stop_blocks, stop_settings.')
  on conflict do nothing;
end $$;

-- ═══ E · checks — expect 4 tables, 1 settings row with Cost's radius/dwell ══
select table_name from information_schema.tables
 where table_name in ('akatsuki_devices','akatsuki_visits','akatsuki_location_coverage','akatsuki_stop_settings') order by 1;
select enabled, radius_m, dwell_s, accuracy_max_m, readopt_s from akatsuki_stop_settings;
