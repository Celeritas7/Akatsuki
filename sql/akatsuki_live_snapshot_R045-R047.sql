-- ============================================================================
-- Akatsuki R045–R047 — live snapshot, read back 2026-10-24.  RECONSTRUCTED.
--
-- R045–R047 were run from the design chat in the SQL editor (24 Oct) and never
-- committed.  This file is read back from the live catalog of project
-- wylxvmkcrexwfpjpbhyy (pg_get_viewdef, pg_attribute, pg_policy, cron.job) so the
-- repo can rebuild the schema.  It runs after R050.  Idempotent.
--
--   R045  Health Log registered (receive-only) · weather payload rh/pressure/wind ·
--         table akatsuki_weather_daily + source weather_history + cron 07:30 UTC
--   R046  weather risk / change / seasons / plan key (all in akatsuki-sources v13
--         and its cache payload; the only schema change is the seasons column)
--   R047  view akatsuki_food_dish_ingredients · Food Department registered (id food)
--   (akatsuki_visit_points, found live at the time, is Setu's R051 — its own file)
--
-- NOT in this file, on purpose — this repo is public:
--   · the akatsuki_apps cards for healthlog and food, their routes, and the
--     akatsuki_sources row weather_history (their notes carry personal detail);
--   · akatsuki_places / akatsuki_climate_points rows (home and office coordinates).
--   Those stay live-only; read them from the registry, not from git.
--
-- Edge function source: supabase/functions/akatsuki-sources/index.ts (v13).
-- ============================================================================


-- ═══ R045 · akatsuki_weather_daily ═════════════════════════════════════════
create table if not exists public.akatsuki_weather_daily (
  user_id uuid not null default auth.uid(),
  key text not null,
  date date not null,
  label text,
  place_id text,
  class text,
  tz text,
  tmax_c double precision,
  tmin_c double precision,
  rh_min_pct double precision,
  rh_mean_pct double precision,
  pressure_hpa_mean double precision,
  precip_mm double precision,
  precip_prob_pct double precision,
  wind_max_ms double precision,
  code integer,
  kind text not null default 'modelled'::text,
  source text not null,
  attribution text,
  fetched_at timestamp with time zone not null default now(),
  constraint akatsuki_weather_daily_kind_check check ((kind = any (array['modelled'::text, 'observed'::text]))),
  constraint akatsuki_weather_daily_pkey primary key (user_id, key, date),
  constraint akatsuki_weather_daily_user_id_fkey foreign key (user_id) references auth.users(id) on delete cascade
);
create index if not exists akatsuki_weather_daily_user_id_date_idx on public.akatsuki_weather_daily using btree (user_id, date);
alter table public.akatsuki_weather_daily enable row level security;
drop policy if exists akatsuki_weather_daily_read on public.akatsuki_weather_daily;
create policy akatsuki_weather_daily_read on public.akatsuki_weather_daily
  for select using ((user_id = auth.uid()));
-- Written only by akatsuki-sources (service role).  R050 hub rule: no anon grants.
revoke all on public.akatsuki_weather_daily from anon;

select cron.schedule('akatsuki-weather-history', '30 7 * * *', $$
  select net.http_post(
    url     := 'https://wylxvmkcrexwfpjpbhyy.supabase.co/functions/v1/akatsuki-sources',
    headers := jsonb_build_object('Content-Type','application/json',
                 'Authorization','Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'akatsuki_tts_cron')),
    body    := '{"source":"weather_history"}'::jsonb,
    timeout_milliseconds := 60000);
$$);


-- ═══ R046 · akatsuki_weather gains seasons ═════════════════════════════════
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
    payload ->> 'attribution'::text AS attribution,
    payload -> 'seasons'::text AS seasons
   FROM akatsuki_cache c
  WHERE source = 'weather'::text AND (expires_at IS NULL OR expires_at > now());


-- ═══ R047 · Food Department's dish → ingredients, for Health Log ══════════
-- Reads food_department_* (Food Department owns them); those tables must exist first.
create or replace view public.akatsuki_food_dish_ingredients with (security_invoker = true) as
 SELECT di.user_id,
    d.id AS dish_id,
    d.name AS dish_name,
    i.id AS ingredient_id,
    i.name AS ingredient_name,
    i.emoji,
    di.qty,
    di.recipe_unit
   FROM food_department_dish_ingredients di
     JOIN food_department_dishes d ON d.id = di.dish_id AND d.user_id = di.user_id
     JOIN food_department_ingredients i ON i.id = di.ingredient_id AND i.user_id = di.user_id;
revoke all on public.akatsuki_food_dish_ingredients from anon, authenticated;
grant select on public.akatsuki_food_dish_ingredients to authenticated;


-- akatsuki_visit_points is defined in sql/akatsuki_visit_points_R051.sql (Setu, 2026-10-24).
