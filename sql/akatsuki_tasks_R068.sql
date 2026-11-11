-- Phase 1: shared identity and read contract; scheduling behaviour is unchanged.
create table public.akatsuki_tasks (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 source_app text not null check(length(btrim(source_app)) between 1 and 120),
 source_task_id text not null check(length(source_task_id) between 1 and 500),
 task_type text not null default 'other' check(length(btrim(task_type)) between 1 and 80),
 title text not null check(length(btrim(title)) between 1 and 120),
 source_url text check(source_url is null or (length(source_url)<=2048 and source_url ~ '^https?://')),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(user_id,source_app,source_task_id), unique(user_id,id)
);
alter table public.akatsuki_tasks enable row level security;
create policy tasks_owner_read on public.akatsuki_tasks for select to authenticated using(user_id=(select auth.uid()));
revoke all on public.akatsuki_tasks from anon,authenticated;
grant select on public.akatsuki_tasks to authenticated;
alter table public.akatsuki_broadcast_rules add column task_id uuid;
alter table public.akatsuki_broadcasts add column task_id uuid;

-- Arrival rules, their emitted messages and converted timed reminders share one ID.
insert into public.akatsuki_tasks(id,user_id,source_app,source_task_id,title,created_at)
 select id,user_id,coalesce(nullif(created_by,''),'akatsuki'),'legacy-rule:'||id,title,created_at from public.akatsuki_broadcast_rules;
insert into public.akatsuki_tasks(id,user_id,source_app,source_task_id,title,created_at)
 select distinct on (b.user_id,coalesce(b.series_id,b.id)) coalesce(b.series_id,b.id),b.user_id,
 coalesce(nullif(b.created_by,''),'akatsuki'),'legacy-broadcast:'||coalesce(b.series_id,b.id),b.title,b.created_at
 from public.akatsuki_broadcasts b
 where b.rule_id is null and not exists(select 1 from public.akatsuki_broadcast_rules r where r.id=coalesce(b.series_id,b.id) or r.id=b.request_id)
 order by b.user_id,coalesce(b.series_id,b.id),b.created_at;
update public.akatsuki_broadcast_rules set task_id=id;
update public.akatsuki_broadcasts b set task_id=coalesce(b.rule_id,
 (select r.id from public.akatsuki_broadcast_rules r where r.id=b.request_id and r.user_id=b.user_id),
 (select root.task_id from public.akatsuki_broadcasts root where root.id=b.series_id and root.user_id=b.user_id),b.series_id,b.id);
-- A converted reminder's descendants may precede the root in the update above.
update public.akatsuki_broadcasts b set task_id=root.task_id from public.akatsuki_broadcasts root
 where b.series_id=root.id and b.user_id=root.user_id and b.task_id is distinct from root.task_id;
-- Remove unused identities from conversion descendants, without touching any reminder.
delete from public.akatsuki_tasks t where not exists(select 1 from public.akatsuki_broadcasts b where b.task_id=t.id)
 and not exists(select 1 from public.akatsuki_broadcast_rules r where r.task_id=t.id);
alter table public.akatsuki_broadcast_rules alter column task_id set not null;
alter table public.akatsuki_broadcasts alter column task_id set not null;
alter table public.akatsuki_broadcast_rules add foreign key(user_id,task_id) references public.akatsuki_tasks(user_id,id);
alter table public.akatsuki_broadcasts add foreign key(user_id,task_id) references public.akatsuki_tasks(user_id,id);
create index akatsuki_broadcast_task_idx on public.akatsuki_broadcasts(user_id,task_id);
create index akatsuki_rule_task_idx on public.akatsuki_broadcast_rules(user_id,task_id);

create function public.akatsuki_assign_task() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if new.task_id is null and tg_table_name='akatsuki_broadcasts' then
   if new.rule_id is not null then select task_id into new.task_id from akatsuki_broadcast_rules where id=new.rule_id and user_id=new.user_id; end if;
   if new.task_id is null and new.series_id is not null then select task_id into new.task_id from akatsuki_broadcasts where id=new.series_id and user_id=new.user_id; end if;
 end if;
 if new.task_id is null then
   new.task_id:=new.id;
   insert into akatsuki_tasks(id,user_id,source_app,source_task_id,title)
   values(new.task_id,new.user_id,coalesce(nullif(new.created_by,''),'akatsuki'),
     case when tg_table_name='akatsuki_broadcast_rules' then 'legacy-rule:' else 'legacy-broadcast:' end||new.id,new.title);
 end if;
 return new;
end $$;
create trigger assign_shared_task before insert on public.akatsuki_broadcast_rules for each row execute function public.akatsuki_assign_task();
create trigger assign_shared_task before insert on public.akatsuki_broadcasts for each row execute function public.akatsuki_assign_task();
revoke all on function public.akatsuki_assign_task() from public,anon,authenticated;

-- Conversion calls the existing creator before setting request_id. Link that row
-- to its original arrival identity when the creator sets the conversion key.
create function public.akatsuki_link_converted_task() returns trigger language plpgsql security definer set search_path=public as $$
declare linked uuid;
begin
 select task_id into linked from akatsuki_broadcast_rules where id=new.request_id and user_id=new.user_id;
 if linked is not null then new.task_id:=linked; end if;
 return new;
end $$;
create trigger link_converted_task before update of request_id on public.akatsuki_broadcasts for each row execute function public.akatsuki_link_converted_task();
revoke all on function public.akatsuki_link_converted_task() from public,anon,authenticated;

-- Registering the same originating task updates metadata, never creates duplicates
-- or overwrites completion/snooze state. App identifiers are labels, not auth roles.
create function public.akatsuki_task_register(p_source_app text,p_source_task_id text,p_title text,
 p_task_type text default 'other',p_source_url text default null,p_task_id uuid default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v uuid;
begin
 if auth.uid() is null then raise exception 'Sign in first' using errcode='42501'; end if;
 if p_task_id is not null then
   update akatsuki_tasks set source_app=btrim(p_source_app),source_task_id=p_source_task_id,title=btrim(p_title),task_type=btrim(p_task_type),source_url=p_source_url,updated_at=now() where id=p_task_id and user_id=auth.uid() returning id into v;
   if not found then raise exception 'Task is unavailable'; end if;
   return v;
 end if;
 insert into akatsuki_tasks(user_id,source_app,source_task_id,title,task_type,source_url)
 values(auth.uid(),btrim(p_source_app),p_source_task_id,btrim(p_title),btrim(p_task_type),p_source_url)
 on conflict(user_id,source_app,source_task_id) do update set title=excluded.title,task_type=excluded.task_type,source_url=excluded.source_url,updated_at=now()
 returning id into v;
 return v;
end $$;
revoke all on function public.akatsuki_task_register(text,text,text,text,text,uuid) from public,anon;
grant execute on function public.akatsuki_task_register(text,text,text,text,text,uuid) to authenticated;

create view public.akatsuki_task_status with(security_invoker=true) as
 select t.*,coalesce(b.title,r.title,t.title) as display_title,
 case when b.state='paused' then 'paused'
      when b.state='scheduled' and b.snoozed_until>now() then 'snoozed'
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
notify pgrst,'reload schema';

create function public.akatsuki_cleanup_converted_identity() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if old.task_id is distinct from new.task_id then
   delete from akatsuki_tasks t where t.id=old.task_id and t.user_id=new.user_id
    and t.source_task_id='legacy-broadcast:'||new.id
    and not exists(select 1 from akatsuki_broadcasts b where b.task_id=t.id)
    and not exists(select 1 from akatsuki_broadcast_rules r where r.task_id=t.id);
 end if;
 return new;
end $$;
create trigger cleanup_converted_identity after update of request_id on public.akatsuki_broadcasts for each row execute function public.akatsuki_cleanup_converted_identity();
revoke all on function public.akatsuki_cleanup_converted_identity() from public,anon,authenticated;
