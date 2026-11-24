-- A1E registry permission audit. STAGING ONLY, after applying A1A then A1B.
-- Read-only catalog inspection; does not register apps, insert rows or deploy SQL.
-- Requires the built-in Supabase anon and authenticated roles.
-- Run from a disposable staging database, NEVER as a substitute for an isolated
-- restore drill or as permission to apply any migration to production.
begin;

do $a1e$
declare
  v_table text;
  v_fnoid oid;
  v_relid oid;
begin
  v_fnoid := to_regprocedure('public.akatsuki_contract_register(text,jsonb)')::oid;
  if v_fnoid is null then
    raise exception 'A1B registration RPC missing: apply A1A then A1B to staging only';
  end if;
  if not exists (
    select 1 from pg_proc p
    where p.oid = v_fnoid
      and p.prosecdef
      and pg_get_functiondef(p.oid) ilike '%auth.uid()%'
      and exists (
        select 1 from unnest(p.proconfig) as setting
        where setting like 'search_path=%'
          and setting not ilike '%public%'
          and setting not ilike '%pg_temp%'
      )
  ) then
    raise exception 'A1B RPC requires scoped auth check, SECURITY DEFINER and fixed safe search_path';
  end if;

  if has_function_privilege('anon', v_fnoid, 'EXECUTE') then
    raise exception 'A1B RPC executable anonymously';
  end if;
  if not has_function_privilege('authenticated', v_fnoid, 'EXECUTE') then
    raise exception 'A1B RPC not executable by authenticated';
  end if;

  foreach v_table in array array[
    'akatsuki_contract_apps',
    'akatsuki_contract_services',
    'akatsuki_contract_versions'
  ] loop
    v_relid := to_regclass(format('public.%I', v_table))::oid;
    if v_relid is null then
      raise exception 'A1A table missing: %', v_table;
    end if;
    if not exists (select 1 from pg_class c where c.oid = v_relid and c.relrowsecurity) then
      raise exception 'RLS disabled on %', v_table;
    end if;
    if has_table_privilege('anon', v_relid, 'SELECT')
       or has_table_privilege('anon', v_relid, 'INSERT')
       or has_table_privilege('anon', v_relid, 'UPDATE')
       or has_table_privilege('anon', v_relid, 'DELETE') then
      raise exception 'Anonymous browser table privilege on %', v_table;
    end if;
    if not has_table_privilege('authenticated', v_relid, 'SELECT') then
      raise exception 'Authenticated owner-read grant missing on %', v_table;
    end if;
    if has_table_privilege('authenticated', v_relid, 'INSERT')
       or has_table_privilege('authenticated', v_relid, 'UPDATE')
       or has_table_privilege('authenticated', v_relid, 'DELETE') then
      raise exception 'Authenticated browser table write privilege on %', v_table;
    end if;
    if not exists (
      select 1 from pg_policies policy
      where policy.schemaname = 'public'
        and policy.tablename = v_table
        and policy.cmd = 'SELECT'
        and 'authenticated' = any(policy.roles)
        and policy.qual ilike '%auth.uid()%'
        and policy.qual ilike '%user_id%'
    ) then
      raise exception 'Owner-based authenticated SELECT RLS policy missing on %', v_table;
    end if;
  end loop;

  raise notice 'A1E PASS: registry role grants, owner RLS policy shape and RPC configuration';
end;
$a1e$;

rollback;
