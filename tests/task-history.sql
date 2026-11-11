-- Run after R069. All test settings, reminders and logs roll back.
begin;
do $$
declare u uuid; b uuid; t uuid; at_time timestamptz; snoozed timestamptz; n integer; r uuid; place text;
begin
 select user_id into u from public.akatsuki_broadcasts limit 1;
 if u is null then raise exception 'Existing reminder owner required'; end if;
 perform set_config('request.jwt.claim.sub',u::text,true);
 perform public.akatsuki_reminder_settings_set(90);
 b:=public.akatsuki_broadcast_create('History test',null,now(),'general',7,'Asia/Tokyo','test');
 select task_id,show_at into t,at_time from public.akatsuki_broadcasts where id=b;
 perform public.akatsuki_broadcast_shown(b,at_time,'test');
 perform public.akatsuki_broadcast_shown(b,at_time,'test');
 if (select count(*) from public.akatsuki_task_events where occurrence_id=b and event_type='shown')<>1 then raise exception 'Duplicate shown receipt'; end if;
 snoozed:=public.akatsuki_broadcast_snooze_default(b,at_time,'test');
 if abs(extract(epoch from (snoozed-now()))-5400)>1 then raise exception 'Wrong default duration'; end if;
 perform public.akatsuki_broadcast_snooze_default(b,at_time,'test');
 if (select snoozes from public.akatsuki_broadcasts where id=b)<>1 then raise exception 'Retry snoozed twice'; end if;
 if (select count(*) from public.akatsuki_task_events where occurrence_id=b and event_type='snoozed')<>1 then raise exception 'Snooze history'; end if;
 perform public.akatsuki_broadcast_manage(b,'pause');
 perform public.akatsuki_broadcast_manage(b,'resume');
 perform public.akatsuki_broadcast_done(b,'test');
 perform public.akatsuki_broadcast_done(b,'test');
 if (select count(*) from public.akatsuki_task_events where occurrence_id=b and event_type='done')<>1 then raise exception 'Done history duplicate'; end if;
 if (select count(*) from public.akatsuki_broadcasts where task_id=t and state='scheduled')<>1 then raise exception 'Recurrence duplication'; end if;
 select id into b from public.akatsuki_broadcasts where task_id=t and state='scheduled';
 perform public.akatsuki_broadcast_skip(b,'test');
 if not exists(select 1 from public.akatsuki_task_events where task_id=t and event_type='skipped') then raise exception 'Missing skip history'; end if;
 select id into place from public.akatsuki_places where user_id=u and retired_at is null and lat is not null and lng is not null limit 1;
 if place is not null then
  r:=public.akatsuki_broadcast_rule_add(place,'Conversion history',null,'daily_first','test');
  select task_id into t from public.akatsuki_broadcast_rules where id=r;
  b:=public.akatsuki_broadcast_rule_to_time(r,'Converted history',null,now()+interval '1 hour',7);
  if exists(select 1 from public.akatsuki_task_events where occurrence_id=b and task_id<>t) then raise exception 'Conversion history identity'; end if;
  if exists(select 1 from public.akatsuki_tasks where id=b) then raise exception 'Conversion cleanup blocked'; end if;
 end if;
 perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
 if public.akatsuki_broadcast_snooze_default(b,now(),'test') is not null then raise exception 'Owner snooze guard'; end if;
end $$;
set local role authenticated;
do $$ begin
 if exists(select 1 from public.akatsuki_task_events where user_id<>auth.uid()) then raise exception 'History RLS leak'; end if;
 if exists(select 1 from public.akatsuki_reminder_settings where user_id<>auth.uid()) then raise exception 'Settings RLS leak'; end if;
end $$;
rollback;
