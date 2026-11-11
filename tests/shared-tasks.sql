-- Run after R068. Test rows/actions are rolled back. Requires an existing user.
begin;
do $$
declare u uuid; a uuid; b uuid; c uuid; t uuid; v uuid; p text;
begin
 select user_id into u from public.akatsuki_broadcasts limit 1;
 if u is null then raise exception 'An existing reminder owner is required'; end if;
 perform set_config('request.jwt.claim.sub',u::text,true);
 a:=public.akatsuki_task_register('phase1-test','item-1','Test task','check','https://example.com/task');
 b:=public.akatsuki_task_register('phase1-test','item-1','Updated task','check','https://example.com/task');
 if a<>b then raise exception 'Duplicate registration'; end if;
 b:=public.akatsuki_broadcast_create('Repeat test',null,now()+interval '1 hour','general',7,'Asia/Tokyo','phase1-test');
 select task_id into t from public.akatsuki_broadcasts where id=b;
 perform public.akatsuki_task_register('phase1-test','repeat-1','Repeat test','do',null,t);
 perform public.akatsuki_broadcast_manage(b,'pause');
 if (select status from public.akatsuki_task_status where id=t)<>'paused' then raise exception 'Pause status'; end if;
 perform public.akatsuki_broadcast_manage(b,'resume');
 perform public.akatsuki_broadcast_reschedule(b,now()+interval '2 hours');
 if (select status from public.akatsuki_task_status where id=t)<>'snoozed' then raise exception 'Snooze status'; end if;
 perform public.akatsuki_broadcast_skip(b,'phase1-test');
 if not exists(select 1 from public.akatsuki_broadcasts where series_id=b and state='scheduled' and task_id=t) then raise exception 'Recurrence identity'; end if;
 if (select last_result from public.akatsuki_task_status where id=t)<>'skipped' then raise exception 'Last outcome'; end if;
 select id into p from public.akatsuki_places where user_id=u and retired_at is null and lat is not null and lng is not null limit 1;
 if p is not null then
  c:=public.akatsuki_broadcast_rule_add(p,'Arrival test',null,'daily_first','phase1-test');
  select task_id into t from public.akatsuki_broadcast_rules where id=c;
  v:=public.akatsuki_broadcast_rule_to_time(c,'Converted test',null,now()+interval '1 hour',7);
  if (select task_id from public.akatsuki_broadcasts where id=v)<>t then raise exception 'Conversion identity'; end if;
  if exists(select 1 from public.akatsuki_tasks where id=v) then raise exception 'Unused conversion identity'; end if;
 end if;
 perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
 begin
  perform public.akatsuki_task_register('phase1-test','stolen','No','other',null,a);
  raise exception 'Owner guard failed';
 exception when raise_exception then if sqlerrm='Owner guard failed' then raise; end if; end;
end $$;
set local role authenticated;
do $$ begin
 if exists(select 1 from public.akatsuki_task_status where user_id<>auth.uid()) then raise exception 'RLS leak'; end if;
end $$;
rollback;
