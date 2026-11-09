-- R065: folder task/rule management. Apply before the R065 client.
alter table public.akatsuki_broadcasts drop constraint akatsuki_broadcasts_state_check;
alter table public.akatsuki_broadcasts add constraint akatsuki_broadcasts_state_check
  check (state in ('scheduled','paused','done','cancelled','skipped'));
drop index public.akatsuki_broadcast_pending_unique;
create unique index akatsuki_broadcast_pending_unique on public.akatsuki_broadcasts(user_id,series_id)
  where state in ('scheduled','paused') and series_id is not null;

create or replace function public.akatsuki_broadcast_manage(p_id uuid,p_action text,
  p_title text default null,p_body text default null,p_due_at timestamptz default null,p_repeat_days integer default null)
returns void language plpgsql security definer set search_path=public as $$
declare r public.akatsuki_broadcasts%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode='42501'; end if;
  select * into r from akatsuki_broadcasts where id=p_id and user_id=auth.uid()
    and state in ('scheduled','paused') for update;
  if not found then raise exception 'This task has changed or is unavailable. Reopen the folder.'; end if;
  if p_action='pause' then
    update akatsuki_broadcasts set state='paused',updated_at=now() where id=r.id;
  elsif p_action='resume' then
    update akatsuki_broadcasts set state='scheduled',updated_at=now() where id=r.id;
  elsif p_action='delete' then
    update akatsuki_broadcasts set state='cancelled',updated_at=now() where id=r.id;
  elsif p_action='edit' then
    if p_title is null or length(btrim(p_title)) not between 1 and 120 then raise exception 'Title must be 1–120 characters'; end if;
    if length(coalesce(p_body,''))>1000 then raise exception 'Message must be at most 1000 characters'; end if;
    if p_repeat_days is null or p_repeat_days not between 0 and 3650 then raise exception 'Repeat interval must be 0–3650 days'; end if;
    if p_due_at is null or not isfinite(p_due_at) then raise exception 'Choose a due time'; end if;
    if p_due_at<>r.due_at and (p_due_at<now()-interval '1 minute' or p_due_at>now()+interval '400 days') then
      raise exception 'Choose a future time within 400 days';
    end if;
    update akatsuki_broadcasts set title=btrim(p_title),body=nullif(p_body,''),due_at=p_due_at,repeat_days=p_repeat_days,
      series_id=case when p_repeat_days>0 then coalesce(r.series_id,r.id) else r.series_id end,
      snoozed_until=case when p_due_at=r.due_at then r.snoozed_until end,
      pushed_for=case when p_due_at=r.due_at then r.pushed_for end,
      push_note=case when p_due_at=r.due_at then r.push_note end,
      updated_at=now() where id=r.id;
  else raise exception 'Invalid action';
  end if;
end $$;
revoke all on function public.akatsuki_broadcast_manage(uuid,text,text,text,timestamptz,integer) from public,anon;
grant execute on function public.akatsuki_broadcast_manage(uuid,text,text,text,timestamptz,integer) to authenticated;
notify pgrst,'reload schema';
