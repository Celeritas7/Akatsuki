-- ============================================================================
-- Akatsuki R026 — review findings, auto-close, R009 guard fixes.  Oct 12.  Idempotent.
-- Run whole file once in the SQL editor (it ends at section E).  Then V1–V4 one at a time.
--
-- A · resolved_at on violations, AK409 "reviewed", manual resolve
-- B · akatsuki_review_file(findings, scope, run, user) — Claude Code files a code review
-- C · akatsuki_health_close() — closes AK402/403/405 once they clear; cron 03:05 JST
-- D · R009 fixes from the data-loss report (Oct 10):
--     · WF guard, block mode: subtasks without an id were dropped and order was lost → kept, in order
--     · Sukkiri shred: cycles without an id got an md5 key that changed with content → duplicates.
--       Now skipped (logged once per write), and kept as-is in the block-mode rebuild
--     · writes with no x-akatsuki-app header skipped the shred guard → now logged (never blocked)
--     Not changed: warn mode lets overwrites through by design.  Don't flip to block until V4 shows
--     no 'unknown' actor for 14 days.  Resurrected cycles: closed by hub.remove() (deleted_at),
--     not by a second delete path here — a trigger that deletes on absence is the P2 bug.
-- E · schedule
-- ============================================================================

-- ═══ A ═══════════════════════════════════════════════════════════════════════
alter table akatsuki_violations add column if not exists resolved_at timestamptz;
alter table akatsuki_violations add column if not exists resolved_by text;
create index if not exists akatsuki_violations_open on akatsuki_violations (user_id, code) where resolved_at is null and code is not null;

insert into akatsuki_vocab (user_id, ns, id, schema, meta) values
('e91a5f37-e63a-4fd0-8488-4d7a51d56822', 'error', 'AK409', null,
 '{"name":"reviewed","class":"storage","by":"akatsuki_review_file","fix":"a code review found a data-loss risk; after_val has severity, pattern (P1–P5), finding and where. Fix in the app, the next review closes it."}')
on conflict (user_id, ns, id) do update set meta = excluded.meta;

create or replace function akatsuki_violation_resolve(p_seq bigint, p_note text default null)
returns boolean language plpgsql security definer set search_path = public as $$
declare k int;
begin
  update akatsuki_violations set resolved_at = now(), resolved_by = coalesce(p_note, 'manual')
   where seq = p_seq and resolved_at is null and (auth.uid() is null or user_id = auth.uid());
  get diagnostics k = row_count;
  return k > 0;
end $$;
revoke execute on function akatsuki_violation_resolve(bigint, text) from public, anon;
grant execute on function akatsuki_violation_resolve(bigint, text) to authenticated;

-- ═══ B · file a review ═══════════════════════════════════════════════════════
-- p_findings: [{app, id, severity, pattern, finding, where}]
--   app       akatsuki_apps.id ('wf', 'cal') or the repo name for apps without a card
--   id        stable slug, same across runs ('inventory-push-before-pull'); falls back to where
--   severity  critical | high | medium | low
--   pattern   'P1' … 'P5', space-separated when several
--   where     'file.js:122-124'
-- p_scope:   apps this run reviewed.  Open AK409 for these apps that are not in p_findings are
--            closed as fixed.  Apps outside the scope are left alone.  null = apps in p_findings.
-- Returns {filed, kept, closed, run}.
create or replace function akatsuki_review_file(p_findings jsonb, p_scope text[] default null,
                                                p_run text default null, p_user uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  u uuid := coalesce(auth.uid(), p_user);
  run text := coalesce(p_run, 'review-' || to_char(now() at time zone 'Asia/Tokyo', 'YYYY-MM-DD'));
  f jsonb; key text; scope text[]; filed int := 0; kept int := 0; closed int := 0;
begin
  if u is null then raise exception 'AK102 no user: pass p_user when running as postgres' using errcode = 'AK102'; end if;
  if auth.uid() is not null and p_user is not null and p_user <> auth.uid() then
    raise exception 'AK103 p_user must be the signed-in user' using errcode = 'AK103';
  end if;
  if jsonb_typeof(p_findings) is distinct from 'array' then
    raise exception 'AK101 findings must be a JSON array' using errcode = 'AK101';
  end if;

  scope := coalesce(p_scope, array(select distinct x->>'app' from jsonb_array_elements(p_findings) x where x ? 'app'));

  for f in select x from jsonb_array_elements(p_findings) x loop
    if coalesce(f->>'app', '') = '' or coalesce(f->>'finding', '') = '' then
      raise exception 'AK101 each finding needs app and finding: %', f using errcode = 'AK101';
    end if;
    key := coalesce(nullif(f->>'id', ''), nullif(f->>'where', ''), md5(f->>'finding'));
    if exists (select 1 from akatsuki_violations v where v.user_id = u and v.code = 'AK409'
                 and v.actor = f->>'app' and v.path = key and v.resolved_at is null) then
      update akatsuki_violations v set after_val = f || jsonb_build_object('run', run)
       where v.user_id = u and v.code = 'AK409' and v.actor = f->>'app' and v.path = key and v.resolved_at is null;
      kept := kept + 1;
    else
      insert into akatsuki_violations (user_id, actor, table_name, path, owner_app, addr, after_val, action, code)
      values (u, f->>'app', 'review', key, f->>'app',
              jsonb_build_object('code', 'AK409', 'severity', lower(coalesce(f->>'severity', 'medium')), 'first_run', run),
              f || jsonb_build_object('run', run), 'warned', 'AK409');
      filed := filed + 1;
    end if;
  end loop;

  update akatsuki_violations v set resolved_at = now(), resolved_by = run
   where v.user_id = u and v.code = 'AK409' and v.resolved_at is null and v.actor = any(scope)
     and not exists (select 1 from jsonb_array_elements(p_findings) x
                      where x->>'app' = v.actor
                        and coalesce(nullif(x->>'id', ''), nullif(x->>'where', ''), md5(x->>'finding')) = v.path);
  get diagnostics closed = row_count;

  return jsonb_build_object('filed', filed, 'kept', kept, 'closed', closed, 'run', run, 'scope', to_jsonb(scope));
end $$;
revoke execute on function akatsuki_review_file(jsonb, text[], text, uuid) from public, anon;
grant execute on function akatsuki_review_file(jsonb, text[], text, uuid) to authenticated;

-- ═══ C · auto-close what has cleared ═════════════════════════════════════════
create or replace function akatsuki_health_close()
returns int language plpgsql security definer set search_path = public as $$
declare k int; total int := 0;
begin
  -- AK405: the app now has a checked view or reported in the last 2 days
  update akatsuki_violations v set resolved_at = now(), resolved_by = 'auto: now checked'
   where v.code = 'AK405' and v.resolved_at is null
     and (exists (select 1 from akatsuki_health_targets ht where ht.user_id = v.user_id and ht.app = v.actor)
          or exists (select 1 from akatsuki_requests q where q.user_id = v.user_id and q.from_app = v.actor
                      and q.kind = 'health.report' and q.created_at > now() - interval '2 days'));
  get diagnostics k = row_count; total := total + k;
  -- AK405 repeats weekly: keep only the newest open one per app
  update akatsuki_violations v set resolved_at = now(), resolved_by = 'auto: superseded'
   where v.code = 'AK405' and v.resolved_at is null
     and exists (select 1 from akatsuki_violations w where w.user_id = v.user_id and w.code = 'AK405'
                  and w.actor = v.actor and w.path = v.path and w.resolved_at is null and w.seq > v.seq);
  get diagnostics k = row_count; total := total + k;
  -- AK403: a snapshot exists for today or yesterday
  update akatsuki_violations v set resolved_at = now(), resolved_by = 'auto: backup fresh'
   where v.code = 'AK403' and v.resolved_at is null
     and exists (select 1 from akatsuki_backup b where b.user_id = v.user_id and b.day >= current_date - 1);
  get diagnostics k = row_count; total := total + k;
  -- AK402: nothing pending > 7 days for that target any more
  update akatsuki_violations v set resolved_at = now(), resolved_by = 'auto: drained'
   where v.code = 'AK402' and v.resolved_at is null
     and not exists (select 1 from akatsuki_requests q where q.user_id = v.user_id and q.to_app = v.actor
                      and q.status = 'pending' and q.created_at < now() - interval '7 days');
  get diagnostics k = row_count; total := total + k;
  -- AK401 / AK404 / AK409 need a person (or the next review) to close them.
  return total;
end $$;
revoke execute on function akatsuki_health_close() from public, anon, authenticated;

-- ═══ D · R009 guard fixes ════════════════════════════════════════════════════
create or replace function akatsuki_wf_owner_guard() returns trigger
language plpgsql security invoker as $$
declare
  actor  text := akatsuki_actor();
  mode   text := akatsuki_mode(new.user_id);
  oldsub jsonb;
  newsub jsonb;
  k      text;
  o      jsonb;
  n      jsonb;
  fixed  jsonb;
  touched boolean := false;
begin
  if actor = 'wf' then return new; end if;
  if tg_op <> 'UPDATE' then return new; end if;

  select coalesce(jsonb_object_agg(s->>'id', s), '{}'::jsonb) into oldsub
    from jsonb_array_elements(coalesce(old.payload->'subtasks','[]'::jsonb)) s where s ? 'id';
  select coalesce(jsonb_object_agg(s->>'id', s), '{}'::jsonb) into newsub
    from jsonb_array_elements(coalesce(new.payload->'subtasks','[]'::jsonb)) s where s ? 'id';

  for k in select jsonb_object_keys(newsub) loop
    o := oldsub -> k;
    n := newsub -> k;
    if o is null then continue; end if;
    foreach fixed in array array['"when"'::jsonb, '"done"'::jsonb] loop
      declare f text := fixed #>> '{}';
      begin
        if (o -> f) is distinct from (n -> f) then
          insert into akatsuki_violations
            (user_id, actor, table_name, path, owner_app, addr, before_val, after_val, action)
          values (new.user_id, actor, 'weekly_focus_entries', 'payload.subtasks[].' || f, 'wf',
                  jsonb_build_object('board_id', new.board_id, 'item_key', new.item_key, 'sub_id', k),
                  o -> f, n -> f, case when mode = 'block' then 'restored' else 'warned' end);
          if mode = 'block' then
            newsub := jsonb_set(newsub, array[k, f], coalesce(o -> f, 'null'::jsonb));
            touched := true;
          end if;
        end if;
      end;
    end loop;
  end loop;

  -- R026: rebuild in the incoming order; subtasks without an id pass through untouched
  if touched then
    new.payload := jsonb_set(new.payload, '{subtasks}',
      (select coalesce(jsonb_agg(case when s ? 'id' and newsub ? (s->>'id') then newsub -> (s->>'id') else s end order by i), '[]'::jsonb)
         from jsonb_array_elements(new.payload->'subtasks') with ordinality t(s, i)));
  end if;
  return new;
end $$;

create or replace function akatsuki_sukkiri_shred() returns trigger
language plpgsql security invoker as $$
declare
  actor text := akatsuki_actor();
  mode  text := akatsuki_mode(new.user_id);
  p     text;
  owner text;
  cur   jsonb;
  inc   jsonb;
  c     jsonb;
  ckey  text;
  rebuilt jsonb;
  noid  int := 0;
begin
  foreach p in array array['away','done','overrides','block','show','wm','garbage'] loop
    owner := akatsuki_sukkiri_owner_of(p, null);
    inc   := new.payload -> p;
    select value into cur from akatsuki_state
      where user_id = new.user_id and doc = 'calapp_sukkiri' and path = p and item_key = '';

    if actor = owner then
      if cur is distinct from inc then
        insert into akatsuki_state (user_id, doc, path, item_key, owner_app, value, updated_by, seq)
        values (new.user_id, 'calapp_sukkiri', p, '', owner, inc, actor, nextval('akatsuki_seq'))
        on conflict (user_id, doc, path, item_key) do update
          set value = excluded.value, updated_by = excluded.updated_by, seq = excluded.seq, updated_at = now();
      end if;
    elsif cur is not null and cur is distinct from inc then
      -- R026: unknown (no header) is logged too; it is never blocked
      insert into akatsuki_violations
        (user_id, actor, table_name, path, owner_app, addr, before_val, after_val, action)
      values (new.user_id, actor, 'calendar_app_sukkiri', p, owner,
              jsonb_build_object('doc','calapp_sukkiri'), cur, inc,
              case when mode = 'block' and actor <> 'unknown' then 'restored' else 'warned' end);
      if mode = 'block' and actor <> 'unknown' then
        new.payload := jsonb_set(new.payload, array[p], cur);
      end if;
    end if;
  end loop;

  if new.payload ? 'cycles' then
    for c in select value from jsonb_array_elements(coalesce(new.payload->'cycles','[]'::jsonb)) loop
      if coalesce(c->>'id', '') = '' then noid := noid + 1; continue; end if;   -- R026: no md5 keys
      ckey  := 'sk_' || (c->>'id');
      owner := akatsuki_sukkiri_owner_of('cycles', c);
      select value into cur from akatsuki_state
        where user_id = new.user_id and doc = 'calapp_sukkiri' and path = 'cycles' and item_key = ckey;

      if actor = owner and cur is distinct from c then
        insert into akatsuki_state (user_id, doc, path, item_key, owner_app, value, updated_by, seq)
        values (new.user_id, 'calapp_sukkiri', 'cycles', ckey, owner, c, actor, nextval('akatsuki_seq'))
        on conflict (user_id, doc, path, item_key) do update
          set value = excluded.value, updated_by = excluded.updated_by, seq = excluded.seq, updated_at = now();
      elsif actor <> owner and cur is not null and cur is distinct from c then
        insert into akatsuki_violations
          (user_id, actor, table_name, path, owner_app, addr, before_val, after_val, action)
        values (new.user_id, actor, 'calendar_app_sukkiri', 'cycles', owner,
                jsonb_build_object('doc','calapp_sukkiri','item_key',ckey), cur, c,
                case when mode = 'block' and actor <> 'unknown' then 'restored' else 'warned' end);
      end if;
    end loop;

    if noid > 0 then
      insert into akatsuki_violations (user_id, actor, table_name, path, owner_app, addr, after_val, action)
      values (new.user_id, actor, 'calendar_app_sukkiri', 'cycles[].id', actor,
              jsonb_build_object('doc','calapp_sukkiri'), jsonb_build_object('cycles_without_id', noid), 'warned');
    end if;

    if mode = 'block' and actor <> 'unknown' then
      select coalesce(jsonb_agg(value order by item_key), '[]'::jsonb) into rebuilt
        from akatsuki_state
       where user_id = new.user_id and doc = 'calapp_sukkiri' and path = 'cycles'
         and deleted_at is null and value is not null;
      if jsonb_array_length(rebuilt) > 0 then
        new.payload := jsonb_set(new.payload, '{cycles}', rebuilt ||
          (select coalesce(jsonb_agg(x), '[]'::jsonb) from jsonb_array_elements(new.payload->'cycles') x
            where coalesce(x->>'id', '') = ''));
      end if;
    end if;
  end if;

  return new;
end $$;

-- ═══ E · schedule (03:05 JST, after the check) ═══════════════════════════════
select cron.unschedule('akatsuki-health-close') where exists (select 1 from cron.job where jobname = 'akatsuki-health-close');
select cron.schedule('akatsuki-health-close', '5 18 * * *', $$ select akatsuki_health_close(); $$);

-- ═══ Verify — one at a time ══════════════════════════════════════════════════
-- V1 close pass.  Expect 0 (AK405s still stand: no app reports yet).
select akatsuki_health_close() closed;
-- V2 review round-trip with a dummy finding, then close it with an empty run.  Expect filed 1, then closed 1.
select akatsuki_review_file('[{"app":"test","id":"r026-smoke","severity":"low","pattern":"P5","finding":"smoke test","where":"none"}]',
                            null, 'r026-smoke', 'e91a5f37-e63a-4fd0-8488-4d7a51d56822');
select akatsuki_review_file('[]', array['test'], 'r026-smoke-close', 'e91a5f37-e63a-4fd0-8488-4d7a51d56822');
-- V3 guards replaced (both true)
select bool_or(proname = 'akatsuki_wf_owner_guard' and prosrc like '%with ordinality%') wf_fixed,
       bool_or(proname = 'akatsuki_sukkiri_shred' and prosrc like '%no md5 keys%') shred_fixed
  from pg_proc where proname in ('akatsuki_wf_owner_guard', 'akatsuki_sukkiri_shred');
-- V4 who writes foreign paths, last 14 days (block-mode readiness: no 'unknown')
select actor, table_name, path, count(*), max(at) from akatsuki_violations
 where code is null and at > now() - interval '14 days' group by 1,2,3 order by 4 desc;
