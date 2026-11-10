-- Atomically replace an arrival rule with a timed reminder.
-- The original rule ID is the idempotency key: retrying cannot duplicate reminders.
create or replace function public.akatsuki_broadcast_rule_to_time(
 p_id uuid,p_title text,p_body text,p_due_at timestamptz,
 p_repeat_days integer default 0,p_timezone text default 'Asia/Tokyo',p_app text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare r public.akatsuki_broadcast_rules%rowtype; v uuid;
begin
 if auth.uid() is null then raise exception 'Sign in first' using errcode='42501'; end if;
 select * into r from akatsuki_broadcast_rules where id=p_id and user_id=auth.uid() for update;
 if not found then raise exception 'Rule is unavailable'; end if;
 select id into v from akatsuki_broadcasts where user_id=auth.uid() and request_id=p_id;
 if found then return v; end if;
 if r.state<>'active' then raise exception 'Rule is no longer active'; end if;
 v:=akatsuki_broadcast_create(p_title,p_body,p_due_at,'general',p_repeat_days,p_timezone,p_app,p_id);
 update akatsuki_broadcast_rules set state='cancelled',updated_at=now() where id=p_id and user_id=auth.uid();
 update akatsuki_broadcasts set state='cancelled',updated_at=now()
 where rule_id=p_id and user_id=auth.uid() and state in ('scheduled','paused');
 return v;
end $$;
revoke all on function public.akatsuki_broadcast_rule_to_time(uuid,text,text,timestamptz,integer,text,text) from public,anon;
grant execute on function public.akatsuki_broadcast_rule_to_time(uuid,text,text,timestamptz,integer,text,text) to authenticated;
notify pgrst,'reload schema';
