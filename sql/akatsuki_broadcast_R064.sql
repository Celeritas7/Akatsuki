-- R064: categories and recurring broadcast occurrences. Apply before the R064 client.
-- Recurrence retains the original local time and skips elapsed slots when answered late.
alter table public.akatsuki_broadcasts
  add column category text not null default 'general' check (category in ('general','shopping','cleaning','files','daily','expenses')),
  add column repeat_days integer not null default 0 check (repeat_days between 0 and 3650),
  add column timezone text not null default 'Asia/Tokyo',
  add column series_id uuid,
  add column request_id uuid;
alter table public.akatsuki_broadcasts drop constraint akatsuki_broadcasts_state_check;
alter table public.akatsuki_broadcasts add constraint akatsuki_broadcasts_state_check check (state in ('scheduled','done','cancelled','skipped'));
create unique index akatsuki_broadcast_request_unique on public.akatsuki_broadcasts(user_id,request_id);
create unique index akatsuki_broadcast_pending_unique on public.akatsuki_broadcasts(user_id,series_id) where state='scheduled' and series_id is not null;

create or replace function public.akatsuki_broadcast_create(p_title text, p_body text, p_due_at timestamptz,
  p_category text default 'general', p_repeat_days integer default 0, p_timezone text default 'Asia/Tokyo',
  p_app text default null, p_request_id uuid default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v uuid;
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode='42501'; end if;
  if p_request_id is not null then
    perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text || p_request_id::text,0));
    select id into v from akatsuki_broadcasts where user_id=auth.uid() and request_id=p_request_id;
    if found then return v; end if;
  end if;
  if p_category is null or p_category not in ('general','shopping','cleaning','files','daily','expenses') then raise exception 'Invalid category'; end if;
  if p_repeat_days is null or p_repeat_days not between 0 and 3650 then raise exception 'Repeat interval must be 0–3650 days'; end if;
  if not exists (select 1 from pg_timezone_names where name=p_timezone) then raise exception 'Invalid timezone'; end if;
  v := akatsuki_broadcast_add(p_title,p_body,p_due_at,p_app);
  update akatsuki_broadcasts set category=p_category,repeat_days=p_repeat_days,timezone=p_timezone,
    series_id=case when p_repeat_days>0 then v end,request_id=p_request_id where id=v and user_id=auth.uid();
  return v;
end $$;

create or replace function public.akatsuki_broadcast_next_occurrence()
returns trigger language plpgsql security invoker set search_path=public as $$
declare local_due timestamp; local_now timestamp; next_due timestamptz; steps integer;
begin
  if old.state <> 'scheduled' or new.state not in ('done','skipped') or new.repeat_days=0 then return new; end if;
  local_due := new.due_at at time zone new.timezone;
  local_now := now() at time zone new.timezone;
  steps := greatest(1, floor((local_now::date-local_due::date)::numeric/new.repeat_days)::integer);
  next_due := (local_due + make_interval(days => steps*new.repeat_days)) at time zone new.timezone;
  if next_due <= now() then
    next_due := (local_due + make_interval(days => (steps+1)*new.repeat_days)) at time zone new.timezone;
  end if;
  insert into akatsuki_broadcasts(user_id,title,body,due_at,created_by,category,repeat_days,timezone,series_id)
    values(new.user_id,new.title,new.body,next_due,new.created_by,new.category,new.repeat_days,new.timezone,new.series_id);
  return new;
end $$;
create trigger akatsuki_broadcast_next after update of state on public.akatsuki_broadcasts
  for each row execute function public.akatsuki_broadcast_next_occurrence();

create or replace function public.akatsuki_broadcast_skip(p_id uuid,p_app text default null)
returns void language plpgsql security definer set search_path=public as $$
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode='42501'; end if;
  update akatsuki_broadcasts set state='skipped',done_at=now(),done_by=left(coalesce(p_app,akatsuki_actor()),40),updated_at=now()
    where id=p_id and user_id=auth.uid() and state='scheduled';
end $$;

create or replace function public.akatsuki_broadcast_reschedule(p_id uuid,p_at timestamptz)
returns void language plpgsql security definer set search_path=public as $$
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode='42501'; end if;
  if p_at is null or p_at<=now() or p_at>now()+interval '400 days' then raise exception 'Choose a future time within 400 days'; end if;
  update akatsuki_broadcasts set snoozed_until=p_at,snoozes=snoozes+1,updated_at=now()
    where id=p_id and user_id=auth.uid() and state='scheduled';
end $$;

-- Categorize existing broadcasts, including arrival-generated messages.
create or replace function public.akatsuki_broadcast_category(p_id uuid,p_category text)
returns void language plpgsql security definer set search_path=public as $$
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode='42501'; end if;
  if p_category is null or p_category not in ('general','shopping','cleaning','files','daily','expenses') then raise exception 'Invalid category'; end if;
  update akatsuki_broadcasts set category=p_category,updated_at=now() where id=p_id and user_id=auth.uid();
end $$;
revoke all on function public.akatsuki_broadcast_next_occurrence() from public,anon,authenticated;
revoke all on function public.akatsuki_broadcast_create(text,text,timestamptz,text,integer,text,text,uuid),
 public.akatsuki_broadcast_skip(uuid,text),public.akatsuki_broadcast_reschedule(uuid,timestamptz),public.akatsuki_broadcast_category(uuid,text) from public,anon;
grant execute on function public.akatsuki_broadcast_create(text,text,timestamptz,text,integer,text,text,uuid),
 public.akatsuki_broadcast_skip(uuid,text),public.akatsuki_broadcast_reschedule(uuid,timestamptz),public.akatsuki_broadcast_category(uuid,text) to authenticated;
notify pgrst,'reload schema';
