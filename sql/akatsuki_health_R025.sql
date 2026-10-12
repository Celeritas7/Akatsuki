-- ============================================================================
-- Akatsuki R025 — data health checks + daily backups (standard v3.5).  Oct 11.  Idempotent.
-- Run whole file once in the SQL editor.  Then run the Verify block.
--
-- Why: the WF Vault data-loss report (Sep).  The standard covered how apps talk, not whether
-- what they store survives.  The hub can only check and back up what it can read:
--   · its own akatsuki_* tables      — full checks, daily snapshot, restore (akatsuki_state)
--   · app tables behind an akatsuki_* view — counts + snapshot, warn only, never writes back
--   · anything else (WF's vault blob, apps in another Supabase project) — unseen.  The app
--     sends a health.report, or the hub logs AK405 "unchecked" weekly until it does.
-- Findings → akatsuki_violations (action 'warned', new column code).  The Board shows them.
--
-- Codes (new family AK4xx, storage):
--   AK401 shrink        a collection lost ≥ 30 % and ≥ 5 rows since the last check
--   AK402 stuck_pending requests pending > 7 days (target not consuming)
--   AK403 backup_stale  no snapshot for 2 days
--   AK404 app_reported  an app's own health.report has a failed check
--   AK405 unchecked     app has no checked view and sent no health.report in 2 days
--
-- Limits, said plainly:
--   · Snapshots live in the same database.  They survive a bad write, not a lost project —
--     Supabase's own project backups cover that.
--   · akatsuki_task_tags excludes WF's `__*` rows, so the vault is NOT covered by the view.
--   · Restore exists for akatsuki_state only, by doc/path, SQL editor only.  Rows added after
--     the snapshot are left alone.  R009 logs the restore as actor 'unknown' — expected.
-- ============================================================================

create extension if not exists pg_cron;

-- ═══ A · codes, card lines, violation code ═══════════════════════════════════
alter table akatsuki_violations add column if not exists code text;
create index if not exists akatsuki_violations_code on akatsuki_violations (user_id, code, at desc) where code is not null;

alter table akatsuki_apps add column if not exists health text;   -- card line 12: 'view:<akatsuki_view>' | 'report' | 'none'
alter table akatsuki_apps add column if not exists backup text;   -- card line 13: 'hub:<akatsuki_view>' | 'app:<how>' | 'none'

do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822'; a text;
begin
  insert into akatsuki_vocab (user_id, ns, id, schema, meta) values
  (u, 'error', 'AK401', null, '{"name":"shrink","class":"storage","by":"akatsuki_health_check","fix":"a collection lost ≥30% and ≥5 rows since the last check. Check the app''s last writes; if the loss is real, restore from akatsuki_backup."}'),
  (u, 'error', 'AK402', null, '{"name":"stuck_pending","class":"storage","by":"akatsuki_health_check","fix":"requests pending > 7 days: the target is not consuming. Check its cursor and readiness condition."}'),
  (u, 'error', 'AK403', null, '{"name":"backup_stale","class":"storage","by":"akatsuki_health_check","fix":"no snapshot in 2 days: check cron job akatsuki-backup (cron.job_run_details)."}'),
  (u, 'error', 'AK404', null, '{"name":"app_reported","class":"storage","by":"health.report","fix":"the app''s own check failed; after_val has the check. Fix in the app, then re-report."}'),
  (u, 'error', 'AK405', null, '{"name":"unchecked","class":"storage","by":"akatsuki_health_check","fix":"no akatsuki_* view and no health.report in 2 days: the hub cannot see this app''s storage. Expose a view or send health.report daily."}'),
  (u, 'kind', 'health.report',
     '{"type":"object","required":["checks"],"properties":{"build":{"type":"string"},"device":{"type":"string"},"checks":{"type":"array","items":{"type":"object","required":["id","ok"],"properties":{"id":{"type":"string"},"ok":{"type":"boolean"},"n":{"type":"number"},"prev":{"type":"number"},"note":{"type":"string"}}}}}}',
     '{"owner":"hub","direction":"any app → hub","reply":"none — status delivered = applied","when":"once a day per device, after the app''s state has loaded","idempotency":"health-<device>-<YYYY-MM-DD>","suggested_checks":["count per collection vs last good push (shrink)","last successful pull","history depth (versions kept)","pending outbox size"]}')
  on conflict (user_id, ns, id) do update set schema = excluded.schema, meta = excluded.meta;

  for a in select id from akatsuki_apps where user_id = u and role = 'app' loop
    insert into akatsuki_routes (user_id, from_app, to_app, kind, access, state, note) values
    (u, a, 'hub', 'health.report', 'stream', 'proposed',
     'R025 — daily self-check. Live on the first report. Needed when the app''s storage has no akatsuki_* view.')
    on conflict (user_id, from_app, to_app, kind) do update set note = excluded.note;
  end loop;

  update akatsuki_apps set health = coalesce(health, 'none'), backup = coalesce(backup, 'none') where user_id = u;
  update akatsuki_apps set health = 'view:akatsuki_task_tags', backup = 'hub:akatsuki_task_tags · vault: none'
   where user_id = u and id = 'wf';
  update akatsuki_apps set flags = flags || array[
    'R025 — vault blob unseen by the hub (task_tags skips __* rows). Needs: one row per record, save only what changed, delete = marker, reject saves from a stale copy, pull before first push, refuse a sudden empty, keep versions — or a daily health.report until then.']::text[]
   where user_id = u and id = 'wf' and not exists (select 1 from unnest(flags) f where f like 'R025 —%');
end $$;

-- ═══ B · what the hub checks beyond its own tables ═══════════════════════════
-- Hub-maintained (select-only for apps): relation must be an akatsuki_* view with user_id.
create table if not exists akatsuki_health_targets (
  user_id    uuid not null default auth.uid(),
  id         text not null,                      -- 'wf.task_tags'
  app        text not null,
  relation   text not null check (relation like 'akatsuki\_%'),
  group_cols text[] not null default '{}',       -- counted per group; '{}' = one total
  backup     boolean not null default false,     -- snapshot it daily too
  primary key (user_id, id)
);
alter table akatsuki_health_targets enable row level security;
drop policy if exists own_rows_read on akatsuki_health_targets;
create policy own_rows_read on akatsuki_health_targets for select to authenticated using (user_id = auth.uid());
revoke insert, update, delete on akatsuki_health_targets from authenticated, anon;
grant select on akatsuki_health_targets to authenticated;

insert into akatsuki_health_targets (user_id, id, app, relation, group_cols, backup) values
('e91a5f37-e63a-4fd0-8488-4d7a51d56822', 'wf.task_tags', 'wf', 'akatsuki_task_tags', '{board_id}', true)
on conflict (user_id, id) do update set relation = excluded.relation, group_cols = excluded.group_cols, backup = excluded.backup;

-- Last counts, one row per (target, group).  Replaced each run.
create table if not exists akatsuki_health_counts (
  user_id uuid not null,
  target  text not null,
  grp     text not null,
  app     text not null,
  n       int  not null,
  at      timestamptz not null default now(),
  primary key (user_id, target, grp)
);
alter table akatsuki_health_counts enable row level security;
drop policy if exists own_rows_read on akatsuki_health_counts;
create policy own_rows_read on akatsuki_health_counts for select to authenticated using (user_id = auth.uid());
grant select on akatsuki_health_counts to authenticated;

-- ═══ C · backups ═══════════════════════════════════════════════════════════
create table if not exists akatsuki_backup (
  user_id uuid not null,
  day     date not null,
  tbl     text not null,                         -- 'akatsuki_state' · 'view:akatsuki_task_tags'
  n       int  not null,
  rows    jsonb not null,
  at      timestamptz not null default now(),
  primary key (user_id, day, tbl)
);
alter table akatsuki_backup enable row level security;
drop policy if exists own_rows_read on akatsuki_backup;
create policy own_rows_read on akatsuki_backup for select to authenticated using (user_id = auth.uid());
grant select on akatsuki_backup to authenticated;

create or replace function akatsuki_backup_run()
returns int language plpgsql security definer set search_path = public as $$
declare t text; r record; k int; n int := 0;
begin
  foreach t in array array['akatsuki_apps','akatsuki_vocab','akatsuki_routes','akatsuki_state',
                           'akatsuki_requests','akatsuki_links','akatsuki_cursors','akatsuki_places','akatsuki_visits'] loop
    if to_regclass('public.' || t) is null then continue; end if;
    execute format($f$
      insert into akatsuki_backup (user_id, day, tbl, n, rows)
      select x.user_id, current_date, %L, count(*), jsonb_agg(to_jsonb(x)) from %I x group by x.user_id
      on conflict (user_id, day, tbl) do update set n = excluded.n, rows = excluded.rows, at = now()$f$, t, t);
    get diagnostics k = row_count; n := n + k;
  end loop;
  for r in select * from akatsuki_health_targets where backup loop
    begin
      execute format($f$
        insert into akatsuki_backup (user_id, day, tbl, n, rows)
        select %L::uuid, current_date, %L, count(*), coalesce(jsonb_agg(to_jsonb(x)), '[]') from %I x where x.user_id = %L::uuid
        on conflict (user_id, day, tbl) do update set n = excluded.n, rows = excluded.rows, at = now()$f$,
        r.user_id, 'view:' || r.relation, r.relation, r.user_id);
      n := n + 1;
    exception when others then
      raise warning '[ak] backup % failed: %', r.relation, sqlerrm;
    end;
  end loop;
  delete from akatsuki_backup where day < current_date - 30;
  return n;
end $$;

-- Restore document rows from a snapshot.  SQL editor only.  p_path null = whole doc.
create or replace function akatsuki_restore_state(p_user uuid, p_day date, p_doc text, p_path text default null)
returns int language plpgsql security definer set search_path = public as $$
declare k int;
begin
  insert into akatsuki_state (user_id, doc, path, item_key, owner_app, value, seq, updated_by, deleted_at, updated_at)
  select s.user_id, s.doc, s.path, s.item_key, s.owner_app, s.value, nextval('akatsuki_seq'),
         'hub:restore R025 ' || p_day, s.deleted_at, now()
    from akatsuki_backup b
    cross join lateral jsonb_populate_recordset(null::akatsuki_state, b.rows) s
   where b.user_id = p_user and b.day = p_day and b.tbl = 'akatsuki_state'
     and s.doc = p_doc and (p_path is null or s.path = p_path)
  on conflict (user_id, doc, path, item_key) do update
     set value = excluded.value, owner_app = excluded.owner_app, seq = excluded.seq,
         updated_by = excluded.updated_by, deleted_at = excluded.deleted_at, updated_at = excluded.updated_at;
  get diagnostics k = row_count;
  return k;
end $$;

-- ═══ D · the check ═════════════════════════════════════════════════════════
create or replace function akatsuki_health_flag(p_user uuid, p_code text, p_app text, p_table text, p_path text,
                                                p_before jsonb, p_after jsonb, p_quiet interval default null)
returns int language plpgsql security definer set search_path = public as $$
begin
  if p_quiet is not null and exists (
       select 1 from akatsuki_violations v
        where v.user_id = p_user and v.code = p_code and v.actor = p_app and v.path = p_path and v.at > now() - p_quiet) then
    return 0;
  end if;
  insert into akatsuki_violations (user_id, actor, table_name, path, owner_app, addr, before_val, after_val, action, code)
  values (p_user, p_app, p_table, p_path, p_app, jsonb_build_object('code', p_code), p_before, p_after, 'warned', p_code);
  return 1;
end $$;

create or replace function akatsuki_health_check()
returns int language plpgsql security definer set search_path = public as $$
declare t record; r record; k int; total int := 0; grp_sql text;
begin
  create temp table if not exists _ak_now (user_id uuid, target text, grp text, app text, n int) on commit drop;
  create temp table if not exists _ak_ran (user_id uuid, target text) on commit drop;
  truncate _ak_now; truncate _ak_ran;

  -- hub tables
  insert into _ak_now select s.user_id, 'akatsuki_state', s.doc || '/' || s.path, max(s.owner_app), count(*)
    from akatsuki_state s where s.deleted_at is null group by s.user_id, s.doc, s.path;
  insert into _ak_now select l.user_id, 'akatsuki_links', l.kind, 'hub', count(*)
    from akatsuki_links l where l.orphaned_at is null group by l.user_id, l.kind;
  insert into _ak_ran select distinct a.user_id, x from akatsuki_apps a, unnest(array['akatsuki_state','akatsuki_links']) x;

  -- app tables behind akatsuki_* views
  for t in select * from akatsuki_health_targets loop
    grp_sql := case when cardinality(t.group_cols) = 0 then '''*'''
                    else 'concat_ws(''/'', ' || (select string_agg(format('%I::text', c), ', ') from unnest(t.group_cols) c) || ')' end;
    begin
      execute format('insert into _ak_now select %L::uuid, %L, %s, %L, count(*)::int from %I x where x.user_id = %L::uuid group by 3',
                     t.user_id, t.id, grp_sql, t.app, t.relation, t.user_id);
      insert into _ak_ran values (t.user_id, t.id);
    exception when others then
      total := total + akatsuki_health_flag(t.user_id, 'AK405', t.app, t.relation, t.id, null,
                                    jsonb_build_object('error', sqlerrm), interval '7 days');
    end;
  end loop;

  -- AK401 shrink: compare with last counts (a group that vanished counts as 0)
  select coalesce(sum(akatsuki_health_flag(p.user_id, 'AK401', p.app, p.target, p.grp,
           jsonb_build_object('n', p.n, 'at', p.at), jsonb_build_object('n', coalesce(c.n, 0)))), 0) into k
    from akatsuki_health_counts p
    join _ak_ran ran on ran.user_id = p.user_id and ran.target = p.target
    left join _ak_now c on c.user_id = p.user_id and c.target = p.target and c.grp = p.grp
   where p.n >= 5 and coalesce(c.n, 0) <= p.n * 0.7;
  total := total + k;

  delete from akatsuki_health_counts p using _ak_ran ran where ran.user_id = p.user_id and ran.target = p.target;
  insert into akatsuki_health_counts (user_id, target, grp, app, n) select user_id, target, grp, app, n from _ak_now;

  -- AK402 stuck pending (weekly per target)
  select coalesce(sum(akatsuki_health_flag(q.user_id, 'AK402', q.to_app, 'akatsuki_requests', q.to_app, null,
           jsonb_build_object('pending', q.c, 'oldest', q.oldest), interval '7 days')), 0) into k
    from (select user_id, to_app, count(*) c, min(created_at) oldest from akatsuki_requests
           where status = 'pending' and created_at < now() - interval '7 days' group by user_id, to_app) q;
  total := total + k;

  -- AK404 app reports: apply pending health.report rows, flag failed checks
  for r in select * from akatsuki_requests where to_app = 'hub' and kind = 'health.report' and status = 'pending' order by seq loop
    select coalesce(sum(akatsuki_health_flag(r.user_id, 'AK404', r.from_app, 'health.report', c->>'id',
             null, c || jsonb_build_object('build', r.payload->>'build', 'device', r.payload->>'device', 'seq', r.seq))), 0) into k
      from jsonb_array_elements(coalesce(r.payload->'checks', '[]')) c
     where (c->>'ok')::boolean is not true;
    total := total + k;
    update akatsuki_requests set status = 'delivered', delivered_at = now() where seq = r.seq;
  end loop;
  update akatsuki_routes ro set state = 'live', note = 'LIVE R025 — first report applied. ' || ro.note
   where ro.kind = 'health.report' and ro.to_app = 'hub' and ro.state = 'proposed'
     and exists (select 1 from akatsuki_requests q where q.user_id = ro.user_id and q.from_app = ro.from_app
                  and q.kind = 'health.report' and q.status = 'delivered');

  -- AK403 backup stale (daily)
  select coalesce(sum(akatsuki_health_flag(u.user_id, 'AK403', 'hub', 'akatsuki_backup', 'daily', null,
           jsonb_build_object('last', (select max(day) from akatsuki_backup b where b.user_id = u.user_id)), interval '20 hours')), 0) into k
    from (select distinct user_id from akatsuki_apps) u
   where coalesce((select max(day) from akatsuki_backup b where b.user_id = u.user_id), '1970-01-01') < current_date - 1;
  total := total + k;

  -- AK405 unchecked: no target and no report in 2 days (weekly)
  select coalesce(sum(akatsuki_health_flag(a.user_id, 'AK405', a.id, 'akatsuki_apps', 'storage', null,
           jsonb_build_object('health', a.health, 'backup', a.backup), interval '7 days')), 0) into k
    from akatsuki_apps a
   where a.role = 'app'
     and not exists (select 1 from akatsuki_health_targets ht where ht.user_id = a.user_id and ht.app = a.id)
     and not exists (select 1 from akatsuki_requests q where q.user_id = a.user_id and q.from_app = a.id
                      and q.kind = 'health.report' and q.created_at > now() - interval '2 days');
  total := total + k;

  return total;
end $$;

revoke execute on function akatsuki_backup_run() from public, anon, authenticated;
revoke execute on function akatsuki_restore_state(uuid, date, text, text) from public, anon, authenticated;
revoke execute on function akatsuki_health_flag(uuid, text, text, text, text, jsonb, jsonb, interval) from public, anon, authenticated;
revoke execute on function akatsuki_health_check() from public, anon, authenticated;

-- ═══ E · schedule (UTC; 02:30 and 03:00 JST) ═════════════════════════════════
select cron.unschedule('akatsuki-backup') where exists (select 1 from cron.job where jobname = 'akatsuki-backup');
select cron.schedule('akatsuki-backup', '30 17 * * *', $$ select akatsuki_backup_run(); $$);
select cron.unschedule('akatsuki-health') where exists (select 1 from cron.job where jobname = 'akatsuki-health');
select cron.schedule('akatsuki-health', '0 18 * * *', $$ select akatsuki_health_check(); $$);

-- ═══ Verify — run now, paste all results ════════════════════════════════════
-- V1 first backup + first check.  Expect backup > 0; check = number of AK405 (apps with no view/report).
select akatsuki_backup_run() backed_up, akatsuki_health_check() findings;
-- V2 what was flagged
select code, actor, table_name, path, after_val from akatsuki_violations where code like 'AK4%' order by seq desc limit 30;
-- V3 snapshot sizes (watch akatsuki_requests)
select tbl, n, pg_size_pretty(pg_column_size(rows)::bigint) size from akatsuki_backup where day = current_date order by tbl;
-- V4 baseline counts (tomorrow's shrink check compares with these)
select target, grp, app, n from akatsuki_health_counts order by target, grp;
-- V5 jobs
select jobname, schedule, active from cron.job where jobname in ('akatsuki-backup', 'akatsuki-health');
-- Restore, when needed — preview first:
-- select s.path, count(*) from akatsuki_backup b, jsonb_populate_recordset(null::akatsuki_state, b.rows) s
--  where b.day = '2026-10-11' and b.tbl = 'akatsuki_state' and s.doc = '<doc>' group by 1;
-- select akatsuki_restore_state('e91a5f37-e63a-4fd0-8488-4d7a51d56822', '2026-10-11', '<doc>', '<path or null>');
