-- R047 · akatsuki_weather privacy fix (applied 2026-10-24)
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
