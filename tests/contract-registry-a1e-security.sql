-- A1E isolated, rollback-only registry security gate.
-- NEVER execute against General_apps production or any shared live database.
-- Apply A1A then A1B to an isolated scratch DB named akatsuki_a1e_restore_* first.
-- Synthetic IDs only; all inserts are rolled back if the file completes.
begin;

-- Fail closed before touching data if the database was not explicitly prepared.
do $guard$
begin
  if current_database() !~ '^akatsuki_a1e_restore_[a-z0-9_]+$' then
    raise exception 'A1E test requires a disposable akatsuki_a1e_restore_* database, found %',
      current_database();
  end if;
end
$guard$;

do $audit$
declare t text;
begin
  foreach t in array array[
    'akatsuki_contract_apps',
    'akatsuki_contract_services',
    'akatsuki_contract_versions'
  ] loop
    if not exists (
      select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relname = t and c.relrowsecurity
    ) then
      raise exception 'Registry table missing RLS: %', t;
    end if;
    if has_table_privilege('anon','public.' || t,'SELECT')
       or has_table_privilege('anon','public.' || t,'INSERT')
       or has_table_privilege('authenticated','public.' || t,'INSERT')
       or has_table_privilege('authenticated','public.' || t,'UPDATE')
       or has_table_privilege('authenticated','public.' || t,'DELETE') then
      raise exception 'Registry grants too broad: %', t;
    end if;
    if not has_table_privilege('authenticated','public.' || t,'SELECT') then
      raise exception 'Owner discovery SELECT grant missing: %', t;
    end if;
  end loop;
  if to_regprocedure('public.akatsuki_contract_register(text,jsonb)') is null then
    raise exception 'A1B registration RPC missing';
  end if;
  if has_function_privilege('anon','public.akatsuki_contract_register(text,jsonb)','EXECUTE')
     or not has_function_privilege('authenticated','public.akatsuki_contract_register(text,jsonb)','EXECUTE') then
    raise exception 'A1B RPC execute grants do not match design';
  end if;
end
$audit$;

-- Seed representative data under the scratch database administrator.
insert into public.akatsuki_contract_apps (user_id, app_key, name)
values ('11111111-1111-4111-8111-111111111111','a1e-owned-app','Only owner A');
insert into public.akatsuki_contract_services (user_id, service_key, name)
values ('11111111-1111-4111-8111-111111111111','a1e-owned-service','Only owner A');
insert into public.akatsuki_contract_versions
 (user_id, service_key, contract_key, version, specification)
values
 ('11111111-1111-4111-8111-111111111111','a1e-owned-service','a1e-example','1.0.0','{}');

set local role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);

do $owner_a$
declare result jsonb;
begin
  if (select count(*) from public.akatsuki_contract_apps where app_key='a1e-owned-app') <> 1
     or (select count(*) from public.akatsuki_contract_services where service_key='a1e-owned-service') <> 1
     or (select count(*) from public.akatsuki_contract_versions where contract_key='a1e-example') <> 1 then
    raise exception 'Owner A cannot see exactly its own registry records';
  end if;

  result := public.akatsuki_contract_register('app',
    '{"app_key":"a1e-fresh","name":"First name","offline_capable":true}');
  if result->>'status' <> 'created' then raise exception 'Registration did not create app'; end if;

  result := public.akatsuki_contract_register('app',
    '{"app_key":"a1e-fresh","name":"Changed name"}');
  if result->>'status' <> 'already_registered' then
    raise exception 'Registration idempotency failed';
  end if;
  if (select name from public.akatsuki_contract_apps where app_key='a1e-fresh') <> 'First name' then
    raise exception 'Duplicate registration overwrote metadata';
  end if;

  result := public.akatsuki_contract_register('service',
    '{"service_key":"a1e-fresh-service","name":"Synthetic service"}');
  if result->>'status' <> 'created' then raise exception 'Registration did not create service'; end if;

  begin
    perform public.akatsuki_contract_register('app',
      '{"app_key":"a1e-spoof","name":"Forbidden","user_id":"22222222-2222-4222-8222-222222222222"}');
    raise exception 'Unknown/privileged field was accepted';
  exception when invalid_parameter_value then null;
  end;

  begin
    insert into public.akatsuki_contract_apps (app_key,name)
      values ('a1e-direct','Disallowed browser write');
    raise exception 'Authenticated direct INSERT unexpectedly succeeded';
  exception when insufficient_privilege then null;
  end;
end
$owner_a$;

select set_config('request.jwt.claim.sub','22222222-2222-4222-8222-222222222222',true);
do $owner_b$
declare result jsonb;
begin
  if (select count(*) from public.akatsuki_contract_apps where app_key='a1e-owned-app') <> 0
     or (select count(*) from public.akatsuki_contract_services where service_key='a1e-owned-service') <> 0
     or (select count(*) from public.akatsuki_contract_versions where contract_key='a1e-example') <> 0
     or (select count(*) from public.akatsuki_contract_apps where app_key='a1e-fresh') <> 0 then
    raise exception 'Cross-tenant registry read exposed owner A records';
  end if;

  result := public.akatsuki_contract_register('app',
    '{"app_key":"a1e-fresh","name":"Owner B's independent key"}');
  if result->>'status' <> 'created' then
    raise exception 'Tenant-local app keys incorrectly collide across owners';
  end if;
end
$owner_b$;

set local role anon;
select set_config('request.jwt.claim.sub','',true);
do $anon$
begin
  if has_function_privilege('anon','public.akatsuki_contract_register(text,jsonb)','EXECUTE') then
    raise exception 'Anonymous registration was granted';
  end if;
  if has_table_privilege('anon','public.akatsuki_contract_apps','SELECT') then
    raise exception 'Anonymous registry discovery was granted';
  end if;
  begin
    perform public.akatsuki_contract_register('app','{"app_key":"anonymous","name":"No"}');
    raise exception 'Anonymous registration unexpectedly succeeded';
  exception when insufficient_privilege then null;
  end;
end
$anon$;

rollback;
-- PASS requires every assertion to complete and rollback; run psql -v ON_ERROR_STOP=1.
