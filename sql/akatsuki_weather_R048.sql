-- R048 · akatsuki_weather privacy fix (applied 2026-10-24 03:12 UTC)
-- Renumbered from R047: R047 is akatsuki_r047_food_dish_ingredients_view (03:08 UTC).
-- schema_migrations keeps the applied name akatsuki_weather_R047_security_invoker
-- (version 20261024031221); same change, not renamed.
-- The view ran as its owner (postgres), bypassing akatsuki_cache RLS, and anon
-- had SELECT: the public anon key could read `here`, `plan` and every place row.
-- With security_invoker the akatsuki_cache_owner policy (user_id = auth.uid())
-- applies to the caller. healthlog_warnings_run (SECURITY DEFINER, postgres) is
-- unaffected.

alter view public.akatsuki_weather set (security_invoker = on);
revoke select on public.akatsuki_weather from anon;

-- Undo:
-- alter view public.akatsuki_weather reset (security_invoker);
-- grant select on public.akatsuki_weather to anon;
