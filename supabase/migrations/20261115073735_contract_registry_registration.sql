-- A1B: tightly scoped metadata registration. Requires A1A first.
-- Registration is a DECLARATION, never proof of app identity, a service grant,
-- or permission to access another Supabase project.
-- Existing entries are immutable until A2's audited review/edit workflow.

create function public.akatsuki_contract_register(p_kind text, p_metadata jsonb)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_owner uuid := auth.uid();
  v_key text;
  v_name text;
  v_realms jsonb;
  v_realm jsonb;
  v_unexpected text;
  v_created integer;
begin
  if v_owner is null then
    raise exception 'Authentication required' using errcode='28000';
  end if;
  if p_kind not in ('app','service') or p_kind is null then
    raise exception 'Expected app or service' using errcode='22023';
  end if;
  if p_metadata is null or jsonb_typeof(p_metadata) <> 'object'
     or octet_length(p_metadata::text) > 4000 then
    raise exception 'Invalid registration metadata' using errcode='22023';
  end if;

  select k into v_unexpected from jsonb_object_keys(p_metadata) as k
    where not (case when p_kind='app' then
      k = any(array['app_key','name','repository_url','home_url','identity_realms','offline_capable'])
      else k = any(array['service_key','name','maintainer','discovery_url','endpoint_url','identity_realms']) end)
    limit 1;
  if v_unexpected is not null then
    raise exception 'Unsupported registration field: %',v_unexpected using errcode='22023';
  end if;

  v_key := case when p_kind='app' then p_metadata->>'app_key' else p_metadata->>'service_key' end;
  v_name := btrim(p_metadata->>'name');
  if v_key is null or v_key !~ '^[a-z0-9][a-z0-9_-]{1,63}$'
     or v_name is null or length(v_name) not between 1 and 120 then
    raise exception 'Invalid registration key or name' using errcode='22023';
  end if;

  v_realms := coalesce(p_metadata->'identity_realms','[]'::jsonb);
  if jsonb_typeof(v_realms) <> 'array' then
    raise exception 'identity_realms must be an array' using errcode='22023';
  end if;
  if jsonb_array_length(v_realms) > 16 then
    raise exception 'Too many identity realms' using errcode='22023';
  end if;
  for v_realm in select value from jsonb_array_elements(v_realms) loop
    if jsonb_typeof(v_realm) <> 'string' or length(v_realm #>> '{}') not between 1 and 100 then
      raise exception 'Invalid identity realm' using errcode='22023';
    end if;
  end loop;

  if p_kind = 'app' then
    if p_metadata ? 'offline_capable' and jsonb_typeof(p_metadata->'offline_capable') <> 'boolean' then
      raise exception 'offline_capable must be boolean' using errcode='22023';
    end if;
    insert into public.akatsuki_contract_apps
      (user_id,app_key,name,repository_url,home_url,identity_realms,offline_capable)
    values (v_owner,v_key,v_name,p_metadata->>'repository_url',p_metadata->>'home_url',v_realms,
            coalesce((p_metadata->>'offline_capable')::boolean,false))
    on conflict (user_id,app_key) do nothing;
  else
    insert into public.akatsuki_contract_services
      (user_id,service_key,name,maintainer,discovery_url,endpoint_url,identity_realms)
    values (v_owner,v_key,v_name,p_metadata->>'maintainer',
            p_metadata->>'discovery_url',p_metadata->>'endpoint_url',v_realms)
    on conflict (user_id,service_key) do nothing;
  end if;

  get diagnostics v_created = row_count;
  return jsonb_build_object('kind',p_kind,'key',v_key,
                            'status',case when v_created=1 then 'created' else 'already_registered' end);
end;
$$;

-- SECURITY DEFINER is necessary because browser roles intentionally have no
-- table writes. The function only inserts a proposed row for auth.uid(), has
-- a fixed search_path and rejects all unknown/privileged metadata fields.
revoke all on function public.akatsuki_contract_register(text,jsonb) from public, anon, authenticated;
grant execute on function public.akatsuki_contract_register(text,jsonb) to authenticated;
