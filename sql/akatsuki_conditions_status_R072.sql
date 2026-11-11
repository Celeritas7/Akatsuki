-- Phase 3: shared status and shown receipts respect conditions.
create or replace view public.akatsuki_task_status with(security_invoker=true) as
 select t.*,coalesce(b.title,r.title,t.title) as display_title,
 case when b.state='paused' then 'paused'
      when b.state='scheduled' and b.snoozed_until>now() then 'snoozed'
      when b.state='scheduled' and b.show_at<=now() and not coalesce(public.akatsuki_broadcast_eligible(b.id),false) then 'waiting_for_conditions'
      when b.state='scheduled' and b.show_at<=now() then 'pending'
      when b.state='scheduled' then 'scheduled'
      when r.state='active' then 'waiting_for_arrival'
      when b.state is not null then b.state
      when r.state='cancelled' then 'cancelled'
      when r.state='fired' then 'triggered'
      else 'registered' end as status,
 b.id as occurrence_id,b.show_at as next_show_at,
 latest.state as last_result,latest.done_at as last_completed_at,
 greatest(t.updated_at,b.updated_at,r.updated_at,latest.updated_at) as status_updated_at
 from public.akatsuki_tasks t
 left join lateral(select * from public.akatsuki_broadcasts x where x.user_id=t.user_id and x.task_id=t.id
   order by (x.state in ('scheduled','paused')) desc,x.updated_at desc,x.created_at desc,x.id limit 1) b on true
 left join lateral(select * from public.akatsuki_broadcast_rules x where x.user_id=t.user_id and x.task_id=t.id
   order by (x.state='active') desc,x.updated_at desc limit 1) r on true
 left join lateral(select * from public.akatsuki_broadcasts x where x.user_id=t.user_id and x.task_id=t.id and x.state in ('done','skipped','cancelled')
   order by x.updated_at desc,x.id limit 1) latest on true;
revoke all on public.akatsuki_task_status from anon,authenticated;
grant select on public.akatsuki_task_status to authenticated;

create or replace function public.akatsuki_broadcast_shown(p_id uuid,p_show_at timestamptz,p_app text default null)
returns void language plpgsql security definer set search_path=public as $$
declare r akatsuki_broadcasts;
begin
 if auth.uid() is null then raise exception 'Sign in first' using errcode='42501'; end if;
 select * into r from akatsuki_broadcasts where id=p_id and user_id=auth.uid() and state='scheduled' and show_at=p_show_at and show_at<=now() and public.akatsuki_broadcast_eligible(id);
 if not found then return; end if;
 insert into akatsuki_task_events(user_id,task_id,occurrence_id,event_type,app,details,dedupe_key)
 values(r.user_id,r.task_id,r.id,'shown',left(p_app,120),jsonb_build_object('title',r.title,'category',r.category,'show_at',r.show_at),
 'shown:'||r.id||':'||extract(epoch from r.show_at)::text||':'||coalesce(left(p_app,120),'')) on conflict(user_id,dedupe_key) do nothing;
end $$;


notify pgrst,'reload schema';
