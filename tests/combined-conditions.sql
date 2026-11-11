-- Rollback-only tests. No task, location or history changes are retained.
begin;
do $$
declare u uuid; b uuid; t uuid; place text; at_time timestamptz:=now()+interval '1 day'; c akatsuki_task_conditions;
 start_time text; end_time text; count_before integer; again uuid; req uuid:=gen_random_uuid();
begin
 select user_id into u from akatsuki_broadcasts limit 1;
 if u is null then raise exception 'Existing owner required'; end if;
 perform set_config('request.jwt.claim.sub',u::text,true);
 -- A window spanning the test instant, including midnight correctly.
 start_time:=to_char((at_time-interval '1 hour') at time zone 'Asia/Tokyo','HH24:MI:SS');
 end_time:=to_char((at_time+interval '1 hour') at time zone 'Asia/Tokyo','HH24:MI:SS');
 b:=akatsuki_conditioned_save(null,null,'Window test',null,at_time-interval '3 hours','general',7,'Asia/Tokyo','test',req,
 jsonb_build_object('mode','time','window_start',start_time,'window_end',end_time,'weekdays',array[1,2,3,4,5,6,7]));
 again:=akatsuki_conditioned_save(null,null,'Window test',null,at_time-interval '3 hours','general',7,'Asia/Tokyo','test',req,
 jsonb_build_object('mode','time','window_start',start_time,'window_end',end_time,'weekdays',array[1,2,3,4,5,6,7]));
 if again<>b then raise exception 'Retry duplicates'; end if;
 select task_id into t from akatsuki_broadcasts where id=b;
 update akatsuki_task_conditions set updated_at=at_time-interval '3 hours' where task_id=t;
 if not akatsuki_broadcast_eligible(b,at_time) then raise exception 'Inside time window'; end if;
 if akatsuki_broadcast_eligible(b,at_time+interval '2 hours') then raise exception 'Outside time window'; end if;
 perform akatsuki_reminder_settings_set(90);
 perform akatsuki_conditions_sweep(u,at_time+interval '2 hours');
 if not exists(select 1 from akatsuki_broadcasts where id=b and state='scheduled' and snoozes=1 and snoozed_until=at_time+interval '210 minutes') then raise exception 'Automatic snooze'; end if;
 perform akatsuki_conditions_sweep(u,at_time+interval '2 hours');
 if (select snoozes from akatsuki_broadcasts where id=b)<>1 then raise exception 'Sweep duplicate'; end if;
 if not exists(select 1 from akatsuki_task_events where occurrence_id=b and event_type='snoozed' and details->>'snooze_mode'='automatic_window_snooze') then raise exception 'Automatic history'; end if;
 -- Overnight Friday window includes Saturday 01:00 but not Saturday 03:00.
 select * into c from akatsuki_task_conditions where task_id=t;
 c.window_start:='22:00';c.window_end:='02:00';c.weekdays:=array[5];
 if not exists(select 1 from akatsuki_condition_window(c,'2026-11-14 01:00+09') where starts_at<='2026-11-14 01:00+09' and ends_at>'2026-11-14 01:00+09') then raise exception 'Overnight Friday'; end if;
 if exists(select 1 from akatsuki_condition_window(c,'2026-11-14 03:00+09') where starts_at<='2026-11-14 03:00+09' and ends_at>'2026-11-14 03:00+09') then raise exception 'Overnight end'; end if;
 -- Presence permits being there before the window, arrival does not.
 select id into place from akatsuki_places where user_id=u and retired_at is null and lat is not null and lng is not null limit 1;
 if place is null then raise exception 'Place fixture required'; end if;
 update akatsuki_broadcasts set snoozed_until=null,snoozes=0 where id=b;
 update akatsuki_task_conditions set mode='presence',place_id=place where task_id=t;
 insert into akatsuki_visits(user_id,device,since,last_seen_at,lat,lng,place_id,source_app)
 select u,'phase3-test',at_time-interval '2 hours',at_time,p.lat,p.lng,place,'test' from akatsuki_places p where p.id=place and p.user_id=u;
 if not akatsuki_broadcast_eligible(b,at_time) then raise exception 'Already present'; end if;
 update akatsuki_task_conditions set mode='arrival' where task_id=t;
 if coalesce(akatsuki_broadcast_eligible(b,at_time),false) then raise exception 'Arrival before window'; end if;
 update akatsuki_visits set since=at_time-interval '30 minutes' where user_id=u and device='phase3-test';
 if not akatsuki_broadcast_eligible(b,at_time) then raise exception 'Arrival during window'; end if;
 perform akatsuki_conditions_sweep(u,at_time);
 update akatsuki_broadcasts set snoozed_until=at_time+interval '10 minutes' where id=b;
 update akatsuki_visits set last_seen_at=at_time+interval '11 minutes' where user_id=u and device='phase3-test';
 if not akatsuki_broadcast_eligible(b,at_time+interval '11 minutes') then raise exception 'Snoozed arrival presence'; end if;
 if coalesce(akatsuki_broadcast_eligible(b,at_time+interval '20 minutes'),false) then raise exception 'Stale location'; end if;
 update akatsuki_visits set last_seen_at=at_time+interval '21 minutes',until=at_time+interval '21 minutes' where user_id=u and device='phase3-test';
 if coalesce(akatsuki_broadcast_eligible(b,at_time+interval '21 minutes'),false) then raise exception 'Departed'; end if;
 -- Recurrence keeps conditions via the shared task ID.
 perform akatsuki_broadcast_skip(b,'test');
 if not exists(select 1 from akatsuki_broadcasts x join akatsuki_task_conditions q on q.task_id=x.task_id where x.series_id=b and x.state='scheduled') then raise exception 'Lost recurring conditions'; end if;
 perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
 if akatsuki_broadcast_feed()<>'[]'::jsonb then raise exception 'Feed owner isolation'; end if;
 begin
  perform akatsuki_conditioned_save(b,null,'Unauthorized',null,at_time,'general',7,'Asia/Tokyo','test',null,null);
  raise exception 'Owner guard failed';
 exception when raise_exception then if sqlerrm='Owner guard failed' then raise; end if; end;
end $$;
rollback;
