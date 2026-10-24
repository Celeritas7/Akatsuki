-- ============================================================================
-- Akatsuki R050 — grants say what is meant.  After R049.  Idempotent.
-- (Written as R039 in this branch; renumbered 2026-10-24.)
-- Flagged by WF's read-only check of R049 (then R038): the view akatsuki_app_logos carried
-- Supabase's default INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER for
-- authenticated.  Harmless (security_invoker view over a SELECT-only table),
-- but a grant should not promise a write that can never happen.
-- ============================================================================

revoke all on public.akatsuki_app_logos from authenticated, anon;
grant select on public.akatsuki_app_logos to authenticated;

-- Hub rule (2026-10-24): anon has no grants on any akatsuki_* table.  R048 revoked
-- them once; tables created later (akatsuki_weather_daily, R045) got Supabase's
-- defaults back.  Re-run this block after adding a hub table — and revoke anon in
-- the migration that creates it.
do $$
declare t text;
begin
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind in ('r','p') and c.relname like 'akatsuki\_%'
  loop
    execute format('revoke all on public.%I from anon', t);
  end loop;
end $$;

-- Check: expect one row, authenticated / SELECT.
--   select grantee, privilege_type from information_schema.role_table_grants
--    where table_name = 'akatsuki_app_logos' and grantee in ('anon','authenticated');
