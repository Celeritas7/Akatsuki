-- Phase 5: atomic origin-task scheduling. App names are labels; auth.uid owns data.
create function public.akatsuki_app_task_save(p_source_app text,p_source_task_id text,p_task_type text,p_source_url text,
 p_title text,p_body text,p_due_at timestamptz,p_category text,p_repeat_days integer,p_timezone text,
 p_request_id uuid,p_conditions jsonb,p_expected_id uuid default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare t uuid; v uuid; old_id uuid; provisional uuid;
begin
 if auth.uid() is null then raise exception 'Sign in first' using errcode='42501'; end if;
 if nullif(btrim(p_source_task_id),'') is null or p_request_id is null then raise exception 'Stable task and request IDs required'; end if;
 t:=akatsuki_task_register(p_source_app,p_source_task_id,p_title,p_task_type,p_source_url);
 -- Serialize all devices saving this originating task.
 perform 1 from akatsuki_tasks where id=t and user_id=auth.uid() for update;
 select id into v from akatsuki_broadcasts where user_id=auth.uid() and request_id=p_request_id and task_id=t;
 if found then return v; end if;
 if exists(select 1 from akatsuki_broadcasts where user_id=auth.uid() and request_id=p_request_id and task_id<>t) then raise exception 'Request ID already used by another task'; end if;
 select id into old_id from akatsuki_broadcasts where user_id=auth.uid() and task_id=t and state in ('scheduled','paused') order by created_at desc limit 1 for update;
 if old_id is distinct from p_expected_id then raise exception 'This task changed in another app. Reopen it before saving.'; end if;
 if exists(select 1 from akatsuki_broadcast_rules where user_id=auth.uid() and task_id=t and state='active') then raise exception 'Edit the active arrival rule in Akatsuki first'; end if;
 v:=akatsuki_conditioned_save(old_id,null,p_title,p_body,p_due_at,p_category,p_repeat_days,p_timezone,p_source_app,p_request_id,p_conditions);
 if old_id is null then
  select task_id into provisional from akatsuki_broadcasts where id=v and user_id=auth.uid();
  -- A request belonging to another task must never be reassigned.
  if exists(select 1 from akatsuki_tasks where id=provisional and source_task_id<>'legacy-broadcast:'||v::text) then raise exception 'Request ID already used'; end if;
  update akatsuki_broadcasts set task_id=t where id=v and user_id=auth.uid();
  update akatsuki_task_conditions set task_id=t where task_id=provisional and user_id=auth.uid();
  delete from akatsuki_tasks where id=provisional and user_id=auth.uid();
 end if;
 return v;
end $$;
revoke all on function public.akatsuki_app_task_save(text,text,text,text,text,text,timestamptz,text,integer,text,uuid,jsonb,uuid) from public,anon;
grant execute on function public.akatsuki_app_task_save(text,text,text,text,text,text,timestamptz,text,integer,text,uuid,jsonb,uuid) to authenticated;
notify pgrst,'reload schema';
