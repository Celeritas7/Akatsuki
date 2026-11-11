-- Phase 2: owner-readable action log and shared default snooze.
create table public.akatsuki_reminder_settings(
 user_id uuid primary key references auth.users(id) on delete cascade,
 default_snooze_minutes integer not null default 60 check(default_snooze_minutes between 1 and 10080),
 updated_at timestamptz not null default now()
);
alter table public.akatsuki_reminder_settings enable row level security;
create policy reminder_settings_read on public.akatsuki_reminder_settings for select to authenticated using(user_id=(select auth.uid()));
revoke all on public.akatsuki_reminder_settings from anon,authenticated;
grant select on public.akatsuki_reminder_settings to authenticated;
create table public.akatsuki_task_events(
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 task_id uuid not null,
 occurrence_id uuid,
 event_type text not null check(event_type in ('scheduled','shown','snoozed','rescheduled','done','skipped','cancelled','paused','resumed','edited','rule_created','rule_edited','rule_cancelled','rule_fired')),
 happened_at timestamptz not null default now(),
 app text,
 details jsonb not null default '{}'::jsonb,
 dedupe_key text,
 foreign key(user_id,task_id) references public.akatsuki_tasks(user_id,id),
 unique(user_id,dedupe_key)
);
create index akatsuki_task_events_owner_time on public.akatsuki_task_events(user_id,happened_at desc);
create index akatsuki_task_events_task_time on public.akatsuki_task_events(user_id,task_id,happened_at desc);
alter table public.akatsuki_task_events enable row level security;
create policy task_events_read on public.akatsuki_task_events for select to authenticated using(user_id=(select auth.uid()));
revoke all on public.akatsuki_task_events from anon,authenticated;
grant select on public.akatsuki_task_events to authenticated;

create function public.akatsuki_reminder_settings_set(p_minutes integer) returns void
language plpgsql security definer set search_path=public as $$
begin
 if auth.uid() is null then raise exception 'Sign in first' using errcode='42501'; end if;
 if p_minutes is null or p_minutes not between 1 and 10080 then raise exception 'Choose 1–10080 minutes'; end if;
 insert into akatsuki_reminder_settings(user_id,default_snooze_minutes) values(auth.uid(),p_minutes)
 on conflict(user_id) do update set default_snooze_minutes=excluded.default_snooze_minutes,updated_at=now();
end $$;

create function public.akatsuki_broadcast_snooze_default(p_id uuid,p_expected_show_at timestamptz,p_app text default null)
returns timestamptz language plpgsql security definer set search_path=public as $$
declare v timestamptz; minutes integer;
begin
 if auth.uid() is null then raise exception 'Sign in first' using errcode='42501'; end if;
 select default_snooze_minutes into minutes from akatsuki_reminder_settings where user_id=auth.uid();
 minutes:=coalesce(minutes,60);
 -- Compare-and-set prevents two devices or a retried request snoozing twice.
 perform set_config('akatsuki.action_app',left(coalesce(p_app,''),120),true);
 perform set_config('akatsuki.action_kind','default_snooze',true);
 update akatsuki_broadcasts set snoozed_until=now()+make_interval(mins=>minutes),snoozes=snoozes+1,updated_at=now()
 where id=p_id and user_id=auth.uid() and state='scheduled' and show_at=p_expected_show_at
 returning snoozed_until into v;
 perform set_config('akatsuki.action_kind','',true);
 perform set_config('akatsuki.action_app','',true);
 return v;
end $$;

-- A shown receipt means the client rendered it, not that a push was delivered.
create function public.akatsuki_broadcast_shown(p_id uuid,p_show_at timestamptz,p_app text default null)
returns void language plpgsql security definer set search_path=public as $$
declare r akatsuki_broadcasts;
begin
 if auth.uid() is null then raise exception 'Sign in first' using errcode='42501'; end if;
 select * into r from akatsuki_broadcasts where id=p_id and user_id=auth.uid() and state='scheduled' and show_at=p_show_at and show_at<=now();
 if not found then return; end if;
 insert into akatsuki_task_events(user_id,task_id,occurrence_id,event_type,app,details,dedupe_key)
 values(r.user_id,r.task_id,r.id,'shown',left(p_app,120),jsonb_build_object('title',r.title,'category',r.category,'show_at',r.show_at),
 'shown:'||r.id||':'||extract(epoch from r.show_at)::text||':'||coalesce(left(p_app,120),'')) on conflict(user_id,dedupe_key) do nothing;
end $$;

create function public.akatsuki_log_broadcast_action() returns trigger
language plpgsql security definer set search_path=public as $$
declare kind text; actor text;
begin
 -- Conversion changes the provisional task ID; preserve log ownership and avoid
 -- blocking Phase 1's cleanup of that provisional identity.
 if tg_op='UPDATE' and old.task_id is distinct from new.task_id then
  update akatsuki_task_events set task_id=new.task_id where user_id=new.user_id and occurrence_id=new.id;
 end if;
 if tg_op='INSERT' then kind:='scheduled';
 elsif old.state is distinct from new.state then
  kind:=case new.state when 'scheduled' then 'resumed' else new.state end;
 elsif old.snoozed_until is distinct from new.snoozed_until and new.snoozed_until is not null then kind:='snoozed';
 elsif old.due_at is distinct from new.due_at then kind:='rescheduled';
 elsif (old.title,old.body,old.repeat_days,old.category) is distinct from (new.title,new.body,new.repeat_days,new.category) then kind:='edited';
 else return new;
 end if;
 actor:=coalesce(nullif(current_setting('akatsuki.action_app',true),''),case when kind in ('done','skipped') then new.done_by end);
 insert into akatsuki_task_events(user_id,task_id,occurrence_id,event_type,app,details)
 values(new.user_id,new.task_id,new.id,kind,actor,jsonb_build_object('title',new.title,'category',new.category,'show_at',new.show_at,'state',new.state,
 'snooze_mode',nullif(current_setting('akatsuki.action_kind',true),'')));
 return new;
end $$;
-- Alphabetical order: run before cleanup_converted_identity and recurrence.
create trigger aa_log_broadcast_action after insert or update on public.akatsuki_broadcasts
 for each row execute function public.akatsuki_log_broadcast_action();

create function public.akatsuki_log_rule_action() returns trigger
language plpgsql security definer set search_path=public as $$
declare kind text;
begin
 if tg_op='INSERT' then kind:='rule_created';
 elsif old.state is distinct from new.state and new.state='cancelled' then kind:='rule_cancelled';
 elsif old.fired_count is distinct from new.fired_count then kind:='rule_fired';
 elsif (old.title,old.body,old.mode,old.place_id,old.area_id) is distinct from (new.title,new.body,new.mode,new.place_id,new.area_id) then kind:='rule_edited';
 else return new;
 end if;
 insert into akatsuki_task_events(user_id,task_id,event_type,details)
 values(new.user_id,new.task_id,kind,jsonb_build_object('title',new.title,'category','general','rule_id',new.id,'place_id',new.place_id,'area_id',new.area_id,'mode',new.mode));
 return new;
end $$;
create trigger log_rule_action after insert or update on public.akatsuki_broadcast_rules for each row execute function public.akatsuki_log_rule_action();
revoke all on function public.akatsuki_log_broadcast_action(),public.akatsuki_log_rule_action() from public,anon,authenticated;
revoke all on function public.akatsuki_reminder_settings_set(integer),public.akatsuki_broadcast_snooze_default(uuid,timestamptz,text),public.akatsuki_broadcast_shown(uuid,timestamptz,text) from public,anon;
grant execute on function public.akatsuki_reminder_settings_set(integer),public.akatsuki_broadcast_snooze_default(uuid,timestamptz,text),public.akatsuki_broadcast_shown(uuid,timestamptz,text) to authenticated;
notify pgrst,'reload schema';
