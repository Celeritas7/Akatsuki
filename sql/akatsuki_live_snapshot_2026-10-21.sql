-- ============================================================================
-- Akatsuki — live snapshot, 2026-10-21.  RECONSTRUCTED, not an original migration.
--
-- Why this file exists: migrations after R026 (roughly R027–R044: OwnTracks
-- ingest, places, sources/weather/forecast/fx/climate, Setu views) were run in
-- the SQL editor and never committed.  The original files (with their comments,
-- seed updates and akatsuki_apps / vocab / routes changes) are lost.  This file
-- is read back from the live catalog of project wylxvmkcrexwfpjpbhyy with
-- pg_get_functiondef / pg_get_viewdef / pg_policy, so the repo can rebuild the
-- schema.  Only objects with NO definition anywhere in sql/ are included.
--
-- NOT covered (re-check before relying on the repo as the source of truth):
--   · functions/views that exist in an older sql/ file but were redefined later
--     live — the live body may differ from the committed one.
--   · data changes: akatsuki_apps cards, akatsuki_vocab kinds, akatsuki_routes,
--     akatsuki_sources rows, akatsuki_stop_settings defaults.
--   · grants: the three tables below carry Supabase's default anon/authenticated
--     grants; RLS (select-only, owner) is what protects them.
--
-- Idempotent where Postgres allows it.  Matching edge functions:
--   supabase/functions/akatsuki-ping · akatsuki-sources · akatsuki-tts · akatsuki-places-nearby
-- ============================================================================


-- ═══ Tables ════════════════════════════════════════════════════════════════

create table if not exists public.akatsuki_ingest_tokens (
  user_id uuid not null default auth.uid(),
  id text not null,
  token_hash bytea not null,
  created_at timestamp with time zone not null default now(),
  last_used_at timestamp with time zone,
  revoked_at timestamp with time zone,
  constraint akatsuki_ingest_tokens_pkey primary key (user_id, id)
);
alter table public.akatsuki_ingest_tokens enable row level security;
drop policy if exists akatsuki_ingest_tokens_owner on public.akatsuki_ingest_tokens;
create policy akatsuki_ingest_tokens_owner on public.akatsuki_ingest_tokens
  as permissive for select to authenticated using ((user_id = auth.uid()));

create table if not exists public.akatsuki_ingest_state (
  user_id uuid not null,
  device text not null,
  anchor_lat double precision,
  anchor_lng double precision,
  since timestamp with time zone,
  last_in timestamp with time zone,
  last_ping timestamp with time zone,
  open boolean not null default false,
  misses integer not null default 0,
  cov_since timestamp with time zone,
  updated_at timestamp with time zone not null default now(),
  constraint akatsuki_ingest_state_pkey primary key (user_id, device)
);
alter table public.akatsuki_ingest_state enable row level security;
drop policy if exists akatsuki_ingest_state_owner on public.akatsuki_ingest_state;
create policy akatsuki_ingest_state_owner on public.akatsuki_ingest_state
  as permissive for select to authenticated using ((user_id = auth.uid()));

create table if not exists public.akatsuki_climate_points (
  user_id uuid not null default auth.uid(),
  id text not null,
  label text not null,
  lat double precision not null,
  lng double precision not null,
  added_by text not null,
  created_at timestamp with time zone not null default now(),
  retired_at timestamp with time zone,
  constraint akatsuki_climate_points_pkey primary key (user_id, id)
);
alter table public.akatsuki_climate_points enable row level security;
drop policy if exists akatsuki_climate_points_read on public.akatsuki_climate_points;
create policy akatsuki_climate_points_read on public.akatsuki_climate_points
  as permissive for select to authenticated using ((user_id = auth.uid()));


-- ═══ Functions ═════════════════════════════════════════════════════════════

-- Ingest tokens (OwnTracks today; the pattern R037's mail producer reuses).
CREATE OR REPLACE FUNCTION public.akatsuki_ingest_token_new(p_label text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_tok text;
begin
  if auth.uid() is null then perform akatsuki_fail('42501', 'not_signed_in', 'token needs a signed-in user'); end if;
  if coalesce(trim(p_label), '') = '' then perform akatsuki_fail('AK102', 'missing_field', 'label is required'); end if;
  v_tok := encode(extensions.gen_random_bytes(24), 'hex');
  insert into akatsuki_ingest_tokens (user_id, id, token_hash) values (auth.uid(), p_label, extensions.digest(v_tok, 'sha256'))
  on conflict (user_id, id) do update set token_hash = excluded.token_hash, created_at = now(), revoked_at = null, last_used_at = null;
  return v_tok;   -- copy it into OwnTracks now; it is not readable again
end $function$;

CREATE OR REPLACE FUNCTION public.akatsuki_ingest_token_revoke(p_label text)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update akatsuki_ingest_tokens set revoked_at = now() where user_id = auth.uid() and id = p_label;
$function$;

-- Background location in (called by edge function akatsuki-ping).
CREATE OR REPLACE FUNCTION public.akatsuki_ping(p_token text, p_lat double precision, p_lng double precision, p_acc_m integer, p_t timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  u uuid; dev text; s akatsuki_stop_settings; st akatsuki_ingest_state; r4lat numeric; r4lng numeric;
  d double precision; v_anchor text; v_place text; v_other bigint; out jsonb := '{}'::jsonb; src constant text := 'owntracks';
begin
  select user_id, id into u, dev from akatsuki_ingest_tokens
   where token_hash = extensions.digest(coalesce(p_token, ''), 'sha256') and revoked_at is null;
  if u is null then perform akatsuki_fail('42501', 'bad_token', 'unknown or revoked token'); end if;
  dev := 'ot:' || dev;
  update akatsuki_ingest_tokens set last_used_at = now() where user_id = u and id = substr(dev, 4);
  select * into s from akatsuki_stop_settings where user_id = u;
  if s.user_id is null then insert into akatsuki_stop_settings (user_id) values (u) returning * into s; end if;
  if not s.enabled then return jsonb_build_object('status', 'disabled'); end if;
  if p_lat is null or p_lng is null or p_t is null then perform akatsuki_fail('AK102', 'missing_field', 'lat, lng, t'); end if;
  if p_t > now() + interval '5 minutes' or p_t < now() - interval '1 day' then return jsonb_build_object('status', 'ignored', 'why', 'time'); end if;

  insert into akatsuki_devices (user_id, id, app, label, last_seen_at) values (u, dev, src, substr(dev, 4), now())
  on conflict (user_id, id) do update set last_seen_at = now();
  insert into akatsuki_ingest_state (user_id, device) values (u, dev) on conflict do nothing;
  select * into st from akatsuki_ingest_state where user_id = u and device = dev for update;

  -- gap: silence longer than ingest_gap_s ⇒ the open visit ends at last fix inside (D1); coverage splits
  if st.last_ping is not null and p_t - st.last_ping > make_interval(secs => s.ingest_gap_s) then
    if st.open then
      update akatsuki_visits set until = greatest(since, st.last_in), last_seen_at = greatest(last_seen_at, st.last_in),
             end_reason = 'gap', updated_seq = nextval('akatsuki_seq')
       where user_id = u and device = dev and since = st.since and until is null;
      out := out || jsonb_build_object('closed', 'gap');
    end if;
    if st.cov_since is not null then
      insert into akatsuki_location_coverage (user_id, device, app, since, until) values (u, dev, src, st.cov_since, st.last_ping)
      on conflict (user_id, device, since) do update set until = greatest(akatsuki_location_coverage.until, excluded.until), seq = nextval('akatsuki_seq');
    end if;
    st.anchor_lat := null; st.open := false; st.misses := 0; st.cov_since := null;
  end if;
  st.cov_since := coalesce(st.cov_since, p_t);
  insert into akatsuki_location_coverage (user_id, device, app, since, until) values (u, dev, src, st.cov_since, p_t)
  on conflict (user_id, device, since) do update set until = greatest(akatsuki_location_coverage.until, excluded.until), seq = nextval('akatsuki_seq');
  st.last_ping := p_t;

  if p_acc_m is not null and p_acc_m > s.accuracy_max_m then
    update akatsuki_ingest_state set last_ping = st.last_ping, cov_since = st.cov_since, anchor_lat = st.anchor_lat, open = st.open, misses = st.misses, updated_at = now()
     where user_id = u and device = dev;
    return out || jsonb_build_object('status', 'ignored', 'why', 'accuracy');
  end if;

  if st.anchor_lat is null then
    st.anchor_lat := p_lat; st.anchor_lng := p_lng; st.since := p_t; st.last_in := p_t; st.misses := 0; st.open := false;
    out := out || jsonb_build_object('status', 'anchored');
  else
    d := akatsuki_distance_m(st.anchor_lat, st.anchor_lng, p_lat, p_lng);
    if d - coalesce(p_acc_m, 0) > s.radius_m then                       -- clearly outside
      st.misses := st.misses + 1;
      if st.misses >= 2 then
        if st.open then
          update akatsuki_visits set until = greatest(since, st.last_in), last_seen_at = greatest(last_seen_at, st.last_in),
                 end_reason = 'left', updated_seq = nextval('akatsuki_seq')
           where user_id = u and device = dev and since = st.since and until is null
          returning lat, lng into r4lat, r4lng;
          -- hub-merge with another device's overlapping stay (same step as akatsuki_visit_close)
          select o.seq into v_other from akatsuki_visits o
           where o.user_id = u and o.device <> dev and o.merged_into is null
             and o.since <= st.since and coalesce(o.until, o.last_seen_at) >= st.since
             and akatsuki_distance_m(o.lat, o.lng, r4lat, r4lng) <= 100
           order by o.since limit 1;
          if v_other is not null then update akatsuki_visits set merged_into = v_other where user_id = u and device = dev and since = st.since; end if;
          out := out || jsonb_build_object('closed', 'left');
        end if;
        st.anchor_lat := p_lat; st.anchor_lng := p_lng; st.since := p_t; st.last_in := p_t; st.misses := 0; st.open := false;
        out := out || jsonb_build_object('status', 'anchored');
      else
        out := out || jsonb_build_object('status', 'miss');
      end if;
    elsif d > s.radius_m then
      out := out || jsonb_build_object('status', 'fuzzy');                -- neither in nor out: moves nothing
    else
      st.misses := 0; st.last_in := p_t;
      st.anchor_lat := st.anchor_lat * 0.8 + p_lat * 0.2; st.anchor_lng := st.anchor_lng * 0.8 + p_lng * 0.2;
      if not st.open and extract(epoch from p_t - st.since) >= s.dwell_s then
        r4lat := round(st.anchor_lat::numeric, 4); r4lng := round(st.anchor_lng::numeric, 4);
        select id, place_id into v_anchor, v_place from akatsuki_anchors
         where user_id = u and retired_at is null and akatsuki_distance_m(lat, lng, st.anchor_lat, st.anchor_lng) <= radius_m
         order by akatsuki_distance_m(lat, lng, st.anchor_lat, st.anchor_lng) limit 1;
        if v_place is null then
          select id into v_place from akatsuki_places
           where user_id = u and retired_at is null and lat is not null and radius_m is not null
             and akatsuki_distance_m(lat, lng, st.anchor_lat, st.anchor_lng) <= radius_m
           order by akatsuki_distance_m(lat, lng, st.anchor_lat, st.anchor_lng) limit 1;
        end if;
        update akatsuki_visits set until = last_seen_at, end_reason = 'superseded', updated_seq = nextval('akatsuki_seq')
         where user_id = u and device = dev and until is null and since <> st.since;
        insert into akatsuki_visits (user_id, device, since, last_seen_at, lat, lng, radius_m, acc_m, anchor_id, place_id, source_app)
        values (u, dev, st.since, st.last_in, r4lat, r4lng, s.radius_m, p_acc_m, v_anchor, v_place, src)
        on conflict (user_id, device, since) do nothing;
        st.open := true;
        out := out || jsonb_build_object('status', 'opened', 'place_id', v_place);
      elsif st.open then
        update akatsuki_visits set last_seen_at = greatest(last_seen_at, p_t),
               acc_m = least(coalesce(acc_m, p_acc_m), coalesce(p_acc_m, acc_m)), updated_seq = nextval('akatsuki_seq')
         where user_id = u and device = dev and since = st.since and until is null;
        out := out || jsonb_build_object('status', 'seen');
      else
        out := out || jsonb_build_object('status', 'dwelling', 'for_s', extract(epoch from p_t - st.since)::int);
      end if;
    end if;
  end if;

  update akatsuki_ingest_state
     set anchor_lat = st.anchor_lat, anchor_lng = st.anchor_lng, since = st.since, last_in = st.last_in, last_ping = st.last_ping,
         open = st.open, misses = st.misses, cov_since = st.cov_since, updated_at = now()
   where user_id = u and device = dev;
  return out;
end $function$;

-- Places: name the spot of a visit; restore a retired place.
CREATE OR REPLACE FUNCTION public.akatsuki_place_here(p_device text, p_since timestamp with time zone, p_place_id text DEFAULT NULL::text, p_label text DEFAULT NULL::text, p_class text DEFAULT NULL::text, p_move boolean DEFAULT false, p_app text DEFAULT 'akatsuki'::text)
 RETURNS TABLE(id text, label text, class text, status text, renamed integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare u uuid := auth.uid(); v_lat double precision; v_lng double precision; v_pid text; v_st text;
        pl akatsuki_places; d double precision; n int;
begin
  if u is null then perform akatsuki_fail('42501', 'not_signed_in', 'place_here needs a signed-in user'); end if;
  select x.lat, x.lng into v_lat, v_lng from akatsuki_visits x
   where x.user_id = u and x.device = p_device and x.since = p_since and x.merged_into is null;
  if v_lat is null then perform akatsuki_fail('AK117', 'visit_unknown', format('no visit %s @ %s with a spot', p_device, p_since)); end if;

  if p_place_id is null then
    select a.id, a.status into v_pid, v_st from akatsuki_place_add(p_label, coalesce(p_class, 'out'), p_app) a;
  else v_pid := p_place_id; v_st := 'exists'; end if;
  select * into pl from akatsuki_places p where p.user_id = u and p.id = v_pid and p.retired_at is null;
  if pl.id is null then perform akatsuki_fail('AK113', 'place_unknown', format('no place %s', v_pid)); end if;

  if pl.lat is not null then
    d := akatsuki_distance_m(pl.lat, pl.lng, v_lat, v_lng);
    if d > coalesce(pl.radius_m, 100) and not p_move then
      perform akatsuki_fail('AK116', 'place_far', format('%s is already set %s m from here', pl.label, round(d)::int)); end if;
  end if;
  if pl.lat is null or p_move then
    update akatsuki_places p set lat = v_lat, lng = v_lng, radius_m = coalesce(p.radius_m, 100),
           seq = nextval('akatsuki_seq'), updated_at = now()
     where p.user_id = u and p.id = v_pid;
    if v_st = 'exists' then v_st := case when pl.lat is null then 'pinned' else 'moved' end; end if;
  end if;

  update akatsuki_visits x set place_id = v_pid, updated_seq = nextval('akatsuki_seq')
   where x.user_id = u and x.merged_into is null and x.since > now() - interval '30 days'
     and ((x.device = p_device and x.since = p_since)
          or (x.place_id is null and x.lat is not null and akatsuki_distance_m(x.lat, x.lng, v_lat, v_lng) <= 100));
  get diagnostics n = row_count;
  return query select v_pid, pl.label, pl.class, v_st, n;
end $function$;

CREATE OR REPLACE FUNCTION public.akatsuki_place_restore(p_id text, p_app text)
 RETURNS TABLE(id text, label text, class text, status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid(); pl akatsuki_places; v_clash text;
begin
  if v_uid is null then perform akatsuki_fail('42501', 'not_signed_in', 'place_restore needs a signed-in user'); end if;
  select * into pl from akatsuki_places p where p.user_id = v_uid and p.id = p_id;
  if pl.id is null then perform akatsuki_fail('AK113', 'place_unknown', format('no place %s', p_id)); end if;
  if pl.retired_at is null then return query select pl.id, pl.label, pl.class, 'live'::text; return; end if;

  select p.label into v_clash from akatsuki_places p
   where p.user_id = v_uid and p.retired_at is null and p.id <> pl.id
     and (akatsuki_place_slug(p.label) = akatsuki_place_slug(pl.label)
          or exists (select 1 from unnest(p.aliases) a where akatsuki_place_slug(a) = akatsuki_place_slug(pl.label)))
   limit 1;
  if v_clash is not null then
    perform akatsuki_fail('AK118', 'place_taken', format('live place "%s" already answers to "%s" — rename or retire it first', v_clash, pl.label)); end if;

  update akatsuki_places x set retired_at = null, seq = nextval('akatsuki_seq'), updated_at = now()
   where x.user_id = v_uid and x.id = pl.id;
  return query select pl.id, pl.label, pl.class, 'restored'::text;
end $function$;


-- ═══ Views (all security_invoker = on) ═════════════════════════════════════
-- The setu_* / chatak_* / cost_* views read other apps' tables; those tables
-- must exist before these run.

create or replace view public.akatsuki_weather with (security_invoker = on) as
 SELECT user_id,
    key,
    payload ->> 'label'::text AS label,
    payload ->> 'place_id'::text AS place_id,
    payload ->> 'class'::text AS class,
    payload -> 'now'::text AS now,
    payload -> 'days'::text AS days,
    fetched_at,
    expires_at,
    payload ->> 'attribution'::text AS attribution
   FROM akatsuki_cache c
  WHERE source = 'weather'::text AND (expires_at IS NULL OR expires_at > now());

create or replace view public.akatsuki_setu_trips with (security_invoker = on) as
 SELECT id, user_id, origin, destination, country, dep, ret, travellers, model_key,
    rev, created_at, updated_at, deleted_at
   FROM setu_trips;

create or replace view public.akatsuki_setu_day_trips with (security_invoker = on) as
 SELECT id, user_id, name, place_id, lat, lng, date, notes, added_by, accepted,
    rev, created_at, updated_at, deleted_at
   FROM setu_day_trips;

create or replace view public.akatsuki_setu_trip_rules with (security_invoker = on) as
 SELECT id, user_id, trip_id, "group", text, applies_to, source_url, checked_at, status,
    origin, accepted, done, reported_on, rev, created_at, updated_at, deleted_at
   FROM setu_trip_rules;

create or replace view public.akatsuki_setu_food_notes with (security_invoker = on) as
 SELECT id, user_id, shop_id, status, dish, snooze_week, rating, review, go_back,
    reviewed_on, visit_since, visit_device, added_by, accepted, rev, created_at, updated_at, deleted_at
   FROM setu_food_notes;

create or replace view public.akatsuki_setu_forecast_targets with (security_invoker = on) as
 SELECT d.user_id,
    d.id,
    d.name,
    d.date,
    COALESCE(d.lat, p.lat) AS lat,
    COALESCE(d.lng, p.lng) AS lng
   FROM setu_day_trips d
     LEFT JOIN akatsuki_places p ON p.user_id = d.user_id AND p.id = d.place_id
  WHERE d.deleted_at IS NULL AND d.accepted AND d.date >= (now() AT TIME ZONE 'Asia/Tokyo'::text)::date
    AND d.date <= ((now() AT TIME ZONE 'Asia/Tokyo'::text)::date + 15)
    AND COALESCE(d.lat, p.lat) IS NOT NULL AND COALESCE(d.lng, p.lng) IS NOT NULL;

create or replace view public.akatsuki_chatak_prices with (security_invoker = on) as
 SELECT entered_by AS user_id,
    id,
    item_id,
    COALESCE(cost_shop_id, shop_name) AS shop,
    entered_at
   FROM chatak_matrix_prices p
  WHERE entered_by IS NOT NULL;

create or replace view public.akatsuki_cost_shop_areas with (security_invoker = on) as
 SELECT user_id, shop_id, area_id
   FROM cost_management_shop_locations l;


-- ═══ pg_cron jobs (as live) ════════════════════════════════════════════════
-- Secrets come from Vault (name 'akatsuki_tts_cron').  Run each block once;
-- cron.schedule with an existing name replaces the job.

select cron.schedule('akatsuki-visit-sweep',  '*/10 * * * *', $$ select akatsuki_visit_sweep(); $$);
select cron.schedule('akatsuki-backup',       '30 17 * * *',  $$ select akatsuki_backup_run(); $$);
select cron.schedule('akatsuki-health',       '0 18 * * *',   $$ select akatsuki_health_check(); $$);
select cron.schedule('akatsuki-health-close', '5 18 * * *',   $$ select akatsuki_health_close(); $$);

select cron.schedule('akatsuki-fx', '10 1 * * *', $$
  select net.http_post(
    url     := 'https://wylxvmkcrexwfpjpbhyy.supabase.co/functions/v1/akatsuki-sources',
    headers := jsonb_build_object('Content-Type','application/json',
                 'Authorization','Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'akatsuki_tts_cron')),
    body    := '{"source":"fx"}'::jsonb);
$$);

select cron.schedule('akatsuki-climate', '20 1 1 * *', $$
  select net.http_post(
    url     := 'https://wylxvmkcrexwfpjpbhyy.supabase.co/functions/v1/akatsuki-sources',
    headers := jsonb_build_object('Content-Type','application/json',
                 'Authorization','Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'akatsuki_tts_cron')),
    body    := '{"source":"climate"}'::jsonb,
    timeout_milliseconds := 60000);
$$);

select cron.schedule('akatsuki-forecast', '15 */6 * * *', $$
  select net.http_post(
    url     := 'https://wylxvmkcrexwfpjpbhyy.supabase.co/functions/v1/akatsuki-sources',
    headers := jsonb_build_object('Content-Type','application/json',
                 'Authorization','Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'akatsuki_tts_cron')),
    body    := '{"source":"forecast"}'::jsonb,
    timeout_milliseconds := 60000);
$$);

select cron.schedule('akatsuki-weather', '5 * * * *', $$
  select net.http_post(
    url     := 'https://wylxvmkcrexwfpjpbhyy.supabase.co/functions/v1/akatsuki-sources',
    headers := jsonb_build_object('Content-Type','application/json',
                 'Authorization','Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'akatsuki_tts_cron')),
    body    := '{"source":"weather"}'::jsonb,
    timeout_milliseconds := 60000);
$$);

-- akatsuki-tts: SECURITY NOTE.  The LIVE job has the service-role JWT pasted
-- into its command in plain text (unlike the jobs above, which read Vault).
-- The key is NOT reproduced here.  Recommended: rotate the service-role key,
-- then re-create the job in the Vault form below.
select cron.schedule('akatsuki-tts', '* * * * *', $$
  select net.http_post(
    url     := 'https://wylxvmkcrexwfpjpbhyy.supabase.co/functions/v1/akatsuki-tts',
    headers := jsonb_build_object('Content-Type','application/json',
                 'Authorization','Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'akatsuki_tts_cron')),
    body    := '{}'::jsonb)
  where exists (select 1 from akatsuki_audio where status = 'wanted'
                   or (status = 'making' and claimed_at < now() - interval '10 minutes'));
$$);
