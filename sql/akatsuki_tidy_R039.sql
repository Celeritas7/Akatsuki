-- ============================================================================
-- Akatsuki R039 — grants say what is meant.  After R038.  Idempotent.
-- Flagged by WF's read-only check of R038: the view akatsuki_app_logos carried
-- Supabase's default INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER for
-- authenticated.  Harmless (security_invoker view over a SELECT-only table),
-- but a grant should not promise a write that can never happen.
-- ============================================================================

revoke all on public.akatsuki_app_logos from authenticated, anon;
grant select on public.akatsuki_app_logos to authenticated;

-- Check: expect one row, authenticated / SELECT.
--   select grantee, privilege_type from information_schema.role_table_grants
--    where table_name = 'akatsuki_app_logos' and grantee in ('anon','authenticated');
