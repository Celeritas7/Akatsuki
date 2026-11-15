-- Staging-only! Requires A1A + A1B migrations. Entire test rolls back.
-- SQL editor role must be able to SET LOCAL ROLE authenticated for simulation.
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);

do $$
declare result jsonb;
begin
  result := public.akatsuki_contract_register('app',
    '{"app_key":"pilot-app","name":"Pilot App","offline_capable":true,"identity_realms":["example-auth"]}');
  if result->>'status' <> 'created' then raise exception 'first registration failed'; end if;
  result := public.akatsuki_contract_register('app',
    '{"app_key":"pilot-app","name":"Changed title"}');
  if result->>'status' <> 'already_registered' then raise exception 'retry not idempotent'; end if;
  result := public.akatsuki_contract_register('service',
    '{"service_key":"pilot-service","name":"Pilot Service"}');
  if result->>'status' <> 'created' then raise exception 'service registration failed'; end if;
  begin
    perform public.akatsuki_contract_register('service',
      '{"service_key":"bad-service","name":"Bad","service_role_key":"secret"}');
    raise exception 'unapproved field accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.akatsuki_contract_register('app',
      '{"app_key":"bad-app","name":"Bad","identity_realms":[{"unexpected":"object"}]}');
    raise exception 'object realm accepted';
  exception when invalid_parameter_value then null;
  end;
end $$;

do $$
declare n integer;
begin
  select count(*) into n from public.akatsuki_contract_apps where app_key='pilot-app' and name='Pilot App';
  if n <> 1 then raise exception 'registration changed existing metadata'; end if;
end $$;

select set_config('request.jwt.claim.sub','22222222-2222-4222-8222-222222222222',true);
do $$
declare n integer;
begin
  select count(*) into n from public.akatsuki_contract_apps where app_key='pilot-app';
  if n <> 0 then raise exception 'cross-user app leaked'; end if;
  select count(*) into n from public.akatsuki_contract_services where service_key='pilot-service';
  if n <> 0 then raise exception 'cross-user service leaked'; end if;
end $$;

rollback;
