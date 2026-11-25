-- A1E isolated restore rehearsal ONLY. Do NOT use on General_apps or Technical.
-- Requires A1A followed by A1B applied to a DISPOSABLE local PostgreSQL database.
-- Name the scratch database akatsuki_a1e_... and connect only via loopback/local socket.
-- Entire synthetic-data test is wrapped in a transaction and ALWAYS ROLLS BACK.
BEGIN;

-- This guard deliberately fails before any test inserts on non-scratch databases.
DO $gate$
BEGIN
  IF current_database() !~ '^akatsuki_a1e_[a-z0-9_]+$' THEN
    RAISE EXCEPTION 'A1E refusal: database name must start akatsuki_a1e_';
  END IF;
  IF inet_server_addr() IS NOT NULL
     AND inet_server_addr() NOT IN ('127.0.0.1'::inet, '::1'::inet) THEN
    RAISE EXCEPTION 'A1E refusal: test requires local PostgreSQL via loopback';
  END IF;
  IF to_regclass('public.akatsuki_contract_apps') IS NULL
     OR to_regclass('public.akatsuki_contract_services') IS NULL
     OR to_regclass('public.akatsuki_contract_versions') IS NULL
     OR to_regprocedure('public.akatsuki_contract_register(text,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'A1E refusal: A1A and A1B must be installed in scratch database';
  END IF;
END;
$gate$;

DO $grants$
DECLARE
  tbl text;
  fn oid := to_regprocedure('public.akatsuki_contract_register(text,jsonb)');
BEGIN
  FOREACH tbl IN ARRAY ARRAY['akatsuki_contract_apps', 'akatsuki_contract_services', 'akatsuki_contract_versions'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                   WHERE n.nspname='public' AND c.relname=tbl AND c.relrowsecurity) THEN
      RAISE EXCEPTION 'RLS missing on %', tbl;
    END IF;
    IF has_table_privilege('anon', 'public.'||tbl, 'SELECT')
       OR has_table_privilege('anon', 'public.'||tbl, 'INSERT')
       OR has_table_privilege('authenticated', 'public.'||tbl, 'INSERT')
       OR has_table_privilege('authenticated', 'public.'||tbl, 'UPDATE')
       OR has_table_privilege('authenticated', 'public.'||tbl, 'DELETE') THEN
      RAISE EXCEPTION 'Browser table privileges are too broad: %', tbl;
    END IF;
    IF NOT has_table_privilege('authenticated', 'public.'||tbl, 'SELECT') THEN
      RAISE EXCEPTION 'Authenticated SELECT grant is missing on %', tbl;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies
                   WHERE schemaname='public' AND tablename=tbl
                     AND cmd='SELECT' AND 'authenticated'=ANY(roles)
                     AND qual ILIKE '%auth.uid%') THEN
      RAISE EXCEPTION 'Expected owner-only SELECT policy missing: %', tbl;
    END IF;
  END LOOP;
  IF has_function_privilege('anon', fn, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', fn, 'EXECUTE') THEN
    RAISE EXCEPTION 'Registration function EXECUTE grants unsafe';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid=fn
                 AND p.prosecdef AND 'search_path='=ANY(p.proconfig)) THEN
    RAISE EXCEPTION 'Registration function needs SECURITY DEFINER with empty search path';
  END IF;
END;
$grants$;

-- Synthetic owner A. All inserted rows must disappear at ROLLBACK.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
DO $owner_a$
DECLARE response jsonb;
BEGIN
  response := public.akatsuki_contract_register('app', '{"app_key":"a1e-smoke","name":"A1E Synthetic App"}'::jsonb);
  IF response->>'status' <> 'created' THEN RAISE EXCEPTION 'Owner A registration failed'; END IF;
  response := public.akatsuki_contract_register('app', '{"app_key":"a1e-smoke","name":"Changed title"}'::jsonb);
  IF response->>'status' <> 'already_registered' THEN RAISE EXCEPTION 'Duplicate registration not idempotent'; END IF;
  response := public.akatsuki_contract_register('service', '{"service_key":"a1e-svc","name":"A1E Synthetic Service"}'::jsonb);
  IF response->>'status' <> 'created' THEN RAISE EXCEPTION 'Owner A service registration failed'; END IF;
  IF (SELECT COUNT(*) FROM public.akatsuki_contract_apps WHERE app_key='a1e-smoke') <> 1 THEN
    RAISE EXCEPTION 'Owner A app not visible';
  END IF;
  BEGIN
    INSERT INTO public.akatsuki_contract_apps (app_key,name) VALUES ('a1e-unsafe','Should fail');
    RAISE EXCEPTION 'Authenticated table INSERT unexpectedly accepted';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.akatsuki_contract_register('app', '{"app_key":"a1e-bad","name":"Bad","service_role_key":"secret"}'::jsonb);
    RAISE EXCEPTION 'Privileged metadata unexpectedly accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
END;
$owner_a$;

-- Synthetic owner B cannot see A's metadata.
SELECT set_config('request.jwt.claim.sub','22222222-2222-4222-8222-222222222222',true);
DO $owner_b$
BEGIN
  IF (SELECT COUNT(*) FROM public.akatsuki_contract_apps WHERE app_key='a1e-smoke') <> 0 THEN
    RAISE EXCEPTION 'Cross-owner app visibility leaked';
  END IF;
  IF (SELECT COUNT(*) FROM public.akatsuki_contract_services WHERE service_key='a1e-svc') <> 0 THEN
    RAISE EXCEPTION 'Cross-owner service visibility leaked';
  END IF;
END;
$owner_b$;

-- A role without a JWT subject must not register metadata.
SELECT set_config('request.jwt.claim.sub','',true);
DO $no_subject$
BEGIN
  BEGIN
    PERFORM public.akatsuki_contract_register('app', '{"app_key":"a1e-noauth","name":"Should fail"}'::jsonb);
    RAISE EXCEPTION 'Authenticated role with no subject registered data';
  EXCEPTION WHEN SQLSTATE '28000' THEN NULL;
  END;
END;
$no_subject$;

-- Anonymous clients must not execute the SECURITY DEFINER registration RPC.
SET LOCAL ROLE anon;
DO $anonymous$
BEGIN
  BEGIN
    PERFORM public.akatsuki_contract_register('app', '{"app_key":"a1e-anon","name":"Should fail"}'::jsonb);
    RAISE EXCEPTION 'Anonymous registration unexpectedly allowed';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$anonymous$;

ROLLBACK;
-- A1E isolated security rehearsal PASS only if the script reaches ROLLBACK without error.
