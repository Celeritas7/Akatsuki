-- Bound display/push lifetime to the allowed window and location freshness.
create function public.akatsuki_condition_valid_until(p_id uuid,p_at timestamptz default now())
returns timestamptz language plpgsql stable security invoker set search_path=public as $$
declare b akatsuki_broadcasts; c akatsuki_task_conditions; expiry timestamptz; seen timestamptz;
begin
 select * into b from akatsuki_broadcasts where id=p_id;
 if not found then return null; end if;
 select * into c from akatsuki_task_conditions where task_id=b.task_id and user_id=b.user_id;
 if not found then return null; end if;
 select ends_at into expiry from akatsuki_condition_window(c,p_at) where starts_at<=p_at and ends_at>p_at limit 1;
 if expiry is null then return p_at; end if;
 if c.mode<>'time' then
  select last_seen_at into seen from akatsuki_visits where user_id=b.user_id and merged_into is null and since<=p_at order by last_seen_at desc,since desc limit 1;
  expiry:=least(expiry,coalesce(seen+interval '5 minutes',p_at));
 end if;
 return expiry;
end $$;
revoke all on function public.akatsuki_condition_valid_until(uuid,timestamptz) from public,anon;
grant execute on function public.akatsuki_condition_valid_until(uuid,timestamptz) to authenticated;
drop function public.akatsuki_broadcast_feed();
create function public.akatsuki_broadcast_feed() returns jsonb language plpgsql security definer set search_path=public as $$
declare result jsonb;
begin
 if auth.uid() is null then return '[]'::jsonb; end if;
 perform akatsuki_conditions_sweep(auth.uid());
 select coalesce(jsonb_agg(to_jsonb(b)||jsonb_build_object('condition_valid_until',akatsuki_condition_valid_until(b.id))),'[]'::jsonb) into result
 from (select x.* from akatsuki_broadcasts x where x.user_id=auth.uid() and x.state='scheduled' and x.show_at<=now()+interval '6 hours'
  and (akatsuki_broadcast_eligible(x.id) or not exists(select 1 from akatsuki_task_conditions c where c.task_id=x.task_id)) order by x.show_at limit 50) b;
 return result;
end $$;
revoke all on function public.akatsuki_broadcast_feed() from public,anon;
grant execute on function public.akatsuki_broadcast_feed() to authenticated;
-- Preserve the original RPC return contract; the worker queries expiry separately.
create function public.akatsuki_broadcast_push_validity(p_id uuid) returns jsonb
language sql stable security definer set search_path=public as $$
 select jsonb_build_object('eligible',akatsuki_broadcast_eligible(p_id),'valid_until',akatsuki_condition_valid_until(p_id))
$$;
revoke all on function public.akatsuki_broadcast_push_validity(uuid) from public,anon,authenticated;
grant execute on function public.akatsuki_broadcast_push_validity(uuid) to service_role;
notify pgrst,'reload schema';
