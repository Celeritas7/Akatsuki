-- A1A staging-only post-migration verification. Run in SQL editor on a disposable
-- database/branch after installing the migration. This transaction ROLLS BACK.
-- Do not run on production merely to validate a PR.
begin;

do $$
declare t text;
begin
  foreach t in array array['akatsuki_contract_apps','akatsuki_contract_services','akatsuki_contract_versions'] loop
    if not exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
                   where n.nspname='public' and c.relname=t and c.relrowsecurity) then
      raise exception 'RLS not enabled for %', t;
    end if;
    if has_table_privilege('anon', 'public.' || t, 'SELECT')
       or has_table_privilege('authenticated', 'public.' || t, 'INSERT')
       or has_table_privilege('authenticated', 'public.' || t, 'UPDATE')
       or has_table_privilege('authenticated', 'public.' || t, 'DELETE') then
      raise exception 'unsafe browser grants for %', t;
    end if;
    if not has_table_privilege('authenticated', 'public.' || t, 'SELECT') then
      raise exception 'owner SELECT grant missing for %', t;
    end if;
  end loop;
end $$;

-- Synthetic tenant identities; never real user records.
insert into public.akatsuki_contract_apps (user_id,app_key,name)
values ('11111111-1111-4111-8111-111111111111','sample-app','Example'),
       ('22222222-2222-4222-8222-222222222222','sample-app','Other owner');
insert into public.akatsuki_contract_services (user_id,service_key,name)
values ('11111111-1111-4111-8111-111111111111','sample-service','Service');
insert into public.akatsuki_contract_versions
  (user_id,service_key,contract_key,version,specification)
values ('11111111-1111-4111-8111-111111111111','sample-service','sample-v1','1.0.0','{}');

set local role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);

do $$
declare n integer;
begin
  select count(*) into n from public.akatsuki_contract_apps where app_key='sample-app';
  if n <> 1 then raise exception 'cross-owner app visibility (found %)',n; end if;
  select count(*) into n from public.akatsuki_contract_services where service_key='sample-service';
  if n <> 1 then raise exception 'owner service invisible'; end if;
  select count(*) into n from public.akatsuki_contract_versions where contract_key='sample-v1';
  if n <> 1 then raise exception 'owner contract invisible'; end if;
  begin
    insert into public.akatsuki_contract_apps (app_key,name) values ('unauthorized','Should fail');
    raise exception 'authenticated INSERT unexpectedly allowed';
  exception when insufficient_privilege then null;
  end;
end $$;

rollback;
