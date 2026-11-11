begin;
do $$
declare u uuid; v uuid; t uuid; v2 uuid; req uuid:=gen_random_uuid(); src text:=gen_random_uuid()::text; at_time timestamptz:=now()+interval '1 hour';
begin
 select user_id into u from akatsuki_tasks limit 1;
 perform set_config('request.jwt.claim.sub',u::text,true);
 v:=akatsuki_app_task_save('test-app',src,'check',null,'Origin task',null,at_time,'general',7,'Asia/Tokyo',req,'{"mode":"time","window_start":"18:00","window_end":"22:00","weekdays":[1,2,3,4,5,6,7]}');
 select id into t from akatsuki_tasks where source_app='test-app' and source_task_id=src and user_id=u;
 if not exists(select 1 from akatsuki_broadcasts where id=v and task_id=t) then raise exception 'Unlinked occurrence'; end if;
 if not exists(select 1 from akatsuki_task_conditions where task_id=t) then raise exception 'Unlinked conditions'; end if;
 if exists(select 1 from akatsuki_task_events where occurrence_id=v and task_id<>t) then raise exception 'Unlinked history'; end if;
 v2:=akatsuki_app_task_save('test-app',src,'check',null,'Origin task',null,at_time,'general',7,'Asia/Tokyo',req,null);
 if v2<>v then raise exception 'Retry duplicate'; end if;
 begin
  perform akatsuki_app_task_save('test-app',src,'check',null,'Stale',null,at_time,'general',0,'Asia/Tokyo',gen_random_uuid(),null);
  raise exception 'Stale save accepted';
 exception when raise_exception then if sqlerrm='Stale save accepted' then raise;end if;end;
 perform akatsuki_app_task_save('test-app',src,'check',null,'Edited',null,at_time,'general',7,'Asia/Tokyo',gen_random_uuid(),null,v);
 perform akatsuki_broadcast_snooze_default(v,(select show_at from akatsuki_broadcasts where id=v),'other-app');
 if not exists(select 1 from akatsuki_task_status where id=t and status='snoozed') then raise exception 'Status not shared';end if;
 perform akatsuki_broadcast_skip(v,'other-app');
 if not exists(select 1 from akatsuki_broadcasts where task_id=t and state='scheduled' and id<>v) then raise exception 'Recurrence lost identity';end if;
 if not exists(select 1 from akatsuki_task_status where id=t and last_result='skipped') then raise exception 'Result not shared';end if;
 -- Finish the next occurrence without recurrence, then explicitly schedule again.
 select id into v2 from akatsuki_broadcasts where task_id=t and state='scheduled';
 perform akatsuki_app_task_save('test-app',src,'check',null,'Once',null,at_time,'general',0,'Asia/Tokyo',gen_random_uuid(),'{"mode":"time","window_start":"18:00","window_end":"22:00","weekdays":[1]}',v2);
 perform akatsuki_broadcast_skip(v2,'test-app');
 perform akatsuki_app_task_save('test-app',src,'check',null,'New schedule',null,at_time,'general',0,'Asia/Tokyo',gen_random_uuid(),null);
 if exists(select 1 from akatsuki_task_conditions where task_id=t) then raise exception 'Old conditions retained';end if;
 perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
 begin
  perform akatsuki_app_task_save('test-app',src,'check',null,'Foreign edit',null,at_time,'general',0,'Asia/Tokyo',gen_random_uuid(),null,v);
  raise exception 'Foreign edit accepted';
 exception when others then if sqlerrm='Foreign edit accepted' then raise;end if;end;
end $$;
rollback;
