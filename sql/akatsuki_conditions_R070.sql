-- Phase 3: task conditions shared by the overlay, push worker and window sweep.
create table public.akatsuki_task_conditions(
 user_id uuid not null, task_id uuid primary key,
 mode text not null check(mode in ('time','presence','arrival')),
 place_id text, area_id text,
 window_start time not null, window_end time not null check(window_end<>window_start),
 weekdays integer[] not null default array[1,2,3,4,5,6,7] check(cardinality(weekdays)>0 and weekdays <@ array[1,2,3,4,5,6,7]),
 timezone text not null default 'Asia/Tokyo', updated_at timestamptz not null default now(),
 foreign key(user_id,task_id) references public.akatsuki_tasks(user_id,id),
 check((mode='time' and place_id is null and area_id is null) or (mode<>'time' and ((place_id is null)<>(area_id is null))))
);
alter table public.akatsuki_task_conditions enable row level security;
create policy conditions_owner on public.akatsuki_task_conditions for select to authenticated using(user_id=(select auth.uid()));
revoke all on public.akatsuki_task_conditions from anon,authenticated;
grant select on public.akatsuki_task_conditions to authenticated;
alter table public.akatsuki_broadcasts add column condition_arrived_at timestamptz, add column last_auto_window_end timestamptz;

-- A window is anchored to its START day; Friday 22:00–02:00 includes Saturday 01:00.
create function public.akatsuki_condition_window(c public.akatsuki_task_conditions,p_at timestamptz)
returns table(starts_at timestamptz,ends_at timestamptz) language sql stable security invoker set search_path=public as $$
 select (d+c.window_start) at time zone c.timezone,
        (d+c.window_end+case when c.window_end<c.window_start then interval '1 day' else interval '0' end) at time zone c.timezone
 from (select (p_at at time zone c.timezone)::date-offset_days as d from generate_series(0,8) offset_days) dates
 where extract(isodow from d)::integer=any(c.weekdays)
 order by d desc
$$;
revoke all on function public.akatsuki_condition_window(public.akatsuki_task_conditions,timestamptz) from public,anon;
grant execute on function public.akatsuki_condition_window(public.akatsuki_task_conditions,timestamptz) to authenticated;

create function public.akatsuki_condition_visit(c public.akatsuki_task_conditions,p_at timestamptz)
returns timestamptz language plpgsql stable security invoker set search_path=public as $$
declare v akatsuki_visits; matches boolean;
begin
 select * into v from akatsuki_visits where user_id=c.user_id and merged_into is null and since<=p_at
 order by last_seen_at desc,since desc limit 1;
 if not found or v.until is not null or v.last_seen_at<p_at-interval '5 minutes' or v.last_seen_at>p_at+interval '1 minute' then return null; end if;
 if c.place_id is not null then
  select exists(select 1 from akatsuki_places p where p.user_id=c.user_id and p.id=c.place_id and p.retired_at is null
   and (v.place_id=p.id or (v.lat is not null and p.lat is not null and coalesce(v.acc_m,99999)<=coalesce(p.radius_m,100)
     and akatsuki_distance_m(v.lat,v.lng,p.lat,p.lng)<=coalesce(p.radius_m,100)))) into matches;
 else
  select exists(select 1 from akatsuki_areas a where a.user_id=c.user_id and a.id=c.area_id and a.retired_at is null
   and v.lat is not null and a.lat is not null and coalesce(v.acc_m,99999)<=coalesce(a.radius_m,500)
   and akatsuki_distance_m(v.lat,v.lng,a.lat,a.lng)<=coalesce(a.radius_m,500)) into matches;
 end if;
 if matches then return v.since; end if;
 return null;
end $$;
revoke all on function public.akatsuki_condition_visit(public.akatsuki_task_conditions,timestamptz) from public,anon;
grant execute on function public.akatsuki_condition_visit(public.akatsuki_task_conditions,timestamptz) to authenticated;

create function public.akatsuki_broadcast_eligible(p_id uuid,p_at timestamptz default now())
returns boolean language plpgsql stable security invoker set search_path=public as $$
declare b akatsuki_broadcasts; c akatsuki_task_conditions; start_at timestamptz; visit_at timestamptz;
begin
 select * into b from akatsuki_broadcasts where id=p_id;
 if not found or b.state<>'scheduled' or b.show_at>p_at then return false; end if;
 select * into c from akatsuki_task_conditions where task_id=b.task_id and user_id=b.user_id;
 if not found then return true; end if;
 select starts_at into start_at from akatsuki_condition_window(c,p_at) where starts_at<=p_at and ends_at>p_at limit 1;
 if start_at is null then return false; end if;
 if c.mode='time' then return true; end if;
 visit_at:=akatsuki_condition_visit(c,p_at);
 if visit_at is null then return false; end if;
 if c.mode='presence' then return true; end if;
 return b.condition_arrived_at>=start_at or visit_at>=greatest(start_at,b.show_at,c.updated_at);
end $$;
revoke all on function public.akatsuki_broadcast_eligible(uuid,timestamptz) from public,anon;
grant execute on function public.akatsuki_broadcast_eligible(uuid,timestamptz) to authenticated;

-- Internal evaluator: cron processes every owner; the page wrapper only its owner.
create function public.akatsuki_conditions_sweep(p_user uuid default null,p_at timestamptz default now())
returns void language plpgsql security definer set search_path=public as $$
declare b akatsuki_broadcasts; c akatsuki_task_conditions; closed_at timestamptz; start_at timestamptz; visit_at timestamptz; minutes integer;
begin
 for b in select x.* from akatsuki_broadcasts x join akatsuki_task_conditions q on q.task_id=x.task_id and q.user_id=x.user_id
  where x.state='scheduled' and x.show_at<=p_at and (p_user is null or x.user_id=p_user) for update of x skip locked loop
  select * into c from akatsuki_task_conditions where task_id=b.task_id;
  select max(ends_at) into closed_at from akatsuki_condition_window(c,p_at)
   where ends_at<=p_at and ends_at>=b.show_at and ends_at>coalesce(b.last_auto_window_end,'-infinity'::timestamptz) and ends_at>=c.updated_at;
  if closed_at is not null then
   select default_snooze_minutes into minutes from akatsuki_reminder_settings where user_id=b.user_id;
   perform set_config('akatsuki.action_kind','automatic_window_snooze',true);
   perform set_config('akatsuki.action_app','akatsuki',true);
   update akatsuki_broadcasts set snoozed_until=p_at+make_interval(mins=>coalesce(minutes,60)),snoozes=snoozes+1,
    last_auto_window_end=closed_at,condition_arrived_at=null,updated_at=p_at where id=b.id;
   perform set_config('akatsuki.action_kind','',true); perform set_config('akatsuki.action_app','',true);
   continue;
  end if;
  if c.mode='arrival' then
   select starts_at into start_at from akatsuki_condition_window(c,p_at) where starts_at<=p_at and ends_at>p_at limit 1;
   visit_at:=akatsuki_condition_visit(c,p_at);
   if start_at is not null and visit_at>=greatest(start_at,b.show_at,c.updated_at) and b.condition_arrived_at is null then
    update akatsuki_broadcasts set condition_arrived_at=visit_at where id=b.id;
   end if;
  end if;
 end loop;
end $$;
revoke all on function public.akatsuki_conditions_sweep(uuid,timestamptz) from public,anon,authenticated;

create function public.akatsuki_broadcast_feed() returns setof public.akatsuki_broadcasts
language plpgsql security definer set search_path=public as $$
begin
 if auth.uid() is null then return; end if;
 perform akatsuki_conditions_sweep(auth.uid());
 return query select b.* from akatsuki_broadcasts b where b.user_id=auth.uid() and akatsuki_broadcast_eligible(b.id)
 order by b.show_at limit 50;
end $$;
revoke all on function public.akatsuki_broadcast_feed() from public,anon;
grant execute on function public.akatsuki_broadcast_feed() to authenticated;

create or replace function public.akatsuki_broadcast_push_claim()
returns table(id uuid,user_id uuid,title text,body text,show_at timestamptz)
language plpgsql security definer set search_path=public as $$
begin
 perform akatsuki_conditions_sweep();
 return query with due as(select b.id from akatsuki_broadcasts b
  where b.state='scheduled' and b.show_at<=now() and b.pushed_for is distinct from b.show_at and akatsuki_broadcast_eligible(b.id)
  for update skip locked)
 update akatsuki_broadcasts b set pushed_for=b.show_at from due where b.id=due.id
 returning b.id,b.user_id,b.title,b.body,b.show_at;
end $$;

create function public.akatsuki_conditioned_save(p_id uuid,p_arrival_id uuid,p_title text,p_body text,p_due_at timestamptz,
 p_category text,p_repeat_days integer,p_timezone text,p_app text,p_request_id uuid,p_conditions jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
declare v uuid; t uuid; mode_value text; place text; area text; start_time time; end_time time; days integer[];
begin
 if auth.uid() is null then raise exception 'Sign in first' using errcode='42501'; end if;
 if p_id is not null and p_arrival_id is not null then raise exception 'Choose one existing reminder'; end if;
 if p_id is null then
  select id into v from akatsuki_broadcasts where user_id=auth.uid() and request_id=coalesce(p_arrival_id,p_request_id);
  if found then return v; end if;
 end if;
 if p_conditions is not null then
  mode_value:=p_conditions->>'mode';place:=nullif(p_conditions->>'place_id','');area:=nullif(p_conditions->>'area_id','');
  start_time:=(p_conditions->>'window_start')::time;end_time:=(p_conditions->>'window_end')::time;
  select array_agg(value::integer) into days from jsonb_array_elements_text(p_conditions->'weekdays');
  if mode_value is null or mode_value not in ('time','presence','arrival') or start_time is null or end_time is null or start_time=end_time then raise exception 'Choose a valid mode and a time window with different start/end times'; end if;
  if days is null or cardinality(days)=0 or not(days <@ array[1,2,3,4,5,6,7]) then raise exception 'Choose at least one weekday'; end if;
  if not exists(select 1 from pg_timezone_names where name=p_timezone) then raise exception 'Invalid timezone'; end if;
  if mode_value='time' then place:=null;area:=null;
  else
   if (place is null)=(area is null) then raise exception 'Choose one place or area'; end if;
   if place is not null and not exists(select 1 from akatsuki_places where user_id=auth.uid() and id=place and retired_at is null and lat is not null and lng is not null) then raise exception 'Place unavailable'; end if;
   if area is not null and not exists(select 1 from akatsuki_areas where user_id=auth.uid() and id=area and retired_at is null and lat is not null and lng is not null) then raise exception 'Area unavailable'; end if;
  end if;
 end if;
 if p_arrival_id is not null then v:=akatsuki_broadcast_rule_to_time(p_arrival_id,p_title,p_body,p_due_at,p_repeat_days,p_timezone,p_app);
 elsif p_id is not null then
  perform akatsuki_broadcast_manage(p_id,'edit',p_title,p_body,p_due_at,p_repeat_days);v:=p_id;
 else v:=akatsuki_broadcast_create(p_title,p_body,p_due_at,p_category,p_repeat_days,p_timezone,p_app,p_request_id);
 end if;
 select task_id into t from akatsuki_broadcasts where id=v and user_id=auth.uid() for update;
 if p_conditions is null then delete from akatsuki_task_conditions where task_id=t and user_id=auth.uid();
 else
  insert into akatsuki_task_conditions(user_id,task_id,mode,place_id,area_id,window_start,window_end,weekdays,timezone)
  values(auth.uid(),t,mode_value,place,area,start_time,end_time,days,p_timezone)
  on conflict(task_id) do update set mode=excluded.mode,place_id=excluded.place_id,area_id=excluded.area_id,
   window_start=excluded.window_start,window_end=excluded.window_end,weekdays=excluded.weekdays,timezone=excluded.timezone,updated_at=now();
 end if;
 update akatsuki_broadcasts set condition_arrived_at=null,last_auto_window_end=null,pushed_for=null where id=v and user_id=auth.uid();
 insert into akatsuki_task_events(user_id,task_id,occurrence_id,event_type,app,details)
 values(auth.uid(),t,v,'edited',p_app,jsonb_build_object('title',p_title,'category',p_category,'conditions',p_conditions));
 return v;
end $$;
revoke all on function public.akatsuki_conditioned_save(uuid,uuid,text,text,timestamptz,text,integer,text,text,uuid,jsonb) from public,anon;
grant execute on function public.akatsuki_conditioned_save(uuid,uuid,text,text,timestamptz,text,integer,text,text,uuid,jsonb) to authenticated;
-- Minute sweep runs even when no app is open. No location tracking is invented.
select cron.schedule('akatsuki-condition-windows','* * * * *','select public.akatsuki_conditions_sweep()');
notify pgrst,'reload schema';
