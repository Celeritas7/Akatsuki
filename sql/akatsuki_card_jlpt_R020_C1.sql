-- R020 C1 — run in the hub project (wylxvmkcrexwfpjpbhyy) ONLY after the Japanese app's
-- step 1 is live (its call carries the user's JWT). Paste the whole file, Run.

create or replace function public.roadmap_complete_session(p_task_id uuid, p_source text,
  p_day_key text default null, p_duration integer default null, p_feedback jsonb default '{}'::jsonb,
  p_verification text default 'app')
returns uuid language plpgsql security definer set search_path = public, pg_temp as $f$
declare
  v_uid uuid := auth.uid();
  v_day text := coalesce(p_day_key, to_char(now() - interval '4 hours', 'YYYY-MM-DD'));
  v_id uuid;
begin
  if v_uid is null then raise exception using errcode = '42501', message = 'roadmap_complete_session: sign-in required'; end if;
  if p_verification not in ('app','api','manual') then raise exception 'bad verification: %', p_verification; end if;
  if not exists (select 1 from roadmap_tasks t where t.id = p_task_id and t.user_id = v_uid) then
    raise exception using errcode = '42501', message = 'roadmap_complete_session: not your task';
  end if;
  insert into roadmap_study_sessions (user_id, task_id, day_key, source, completed_at, duration_min, feedback, verification)
  values (v_uid, p_task_id, v_day, p_source, now(), p_duration, p_feedback, p_verification)
  on conflict (task_id, day_key) do update
    set user_id      = v_uid,
        completed_at = now(),
        duration_min = coalesce(excluded.duration_min, roadmap_study_sessions.duration_min),
        feedback     = roadmap_study_sessions.feedback || excluded.feedback,
        source       = excluded.source,
        verification = excluded.verification
    where roadmap_study_sessions.user_id = v_uid or roadmap_study_sessions.user_id is null
  returning id into v_id;
  return v_id;
end $f$;
revoke execute on function public.roadmap_complete_session(uuid, text, text, integer, jsonb, text) from public, anon;
grant  execute on function public.roadmap_complete_session(uuid, text, text, integer, jsonb, text) to authenticated;

-- Check: anon must be gone from this list.
select grantee, privilege_type from information_schema.routine_privileges where routine_name = 'roadmap_complete_session';
