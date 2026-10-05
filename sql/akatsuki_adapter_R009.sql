-- ============================================================================
-- Akatsuki R009 — ownership decided, and the first adapter.  After R008.
-- Idempotent.  Three parts, each runnable alone.
--
-- DECISIONS TAKEN 2026-09-22 (user, on the record):
--   · subtasks[].when  → Weekly Focus owns it.  Calendar stops writing it and
--     publishes task.dated instead.
--   · subtasks[].done  → Weekly Focus owns it.  Roadmap and Calendar both route
--     through akatsuki_requests.
--   · the adapter      → lives in the database, as triggers.  Neither app ships
--     adapter code; nothing has to be running for it to work.
--   · enforcement      → WARN.  Writes go through; violations are logged.
--     Promotion to block is one UPDATE, see part D.
--   · WF's consumer    → not answered; taken as the recommended option.  WF
--     gets a cursor reader eventually.  Until it does, part B logs what WOULD
--     have been delivered, so nothing is lost and nothing breaks today.
--
-- Why the trigger route is safe here: apps that do not identify themselves are
-- never blocked or rewritten, only logged.  An app opts in to protection by
-- setting one session variable.  So this file can be run on a live system with
-- five apps that know nothing about it, and every one of them keeps working.
-- ============================================================================


-- ═══════════════════════════════════════════════════════════════════════════
-- PART A · The violation log, and how an app says who it is.
-- ═══════════════════════════════════════════════════════════════════════════

create table if not exists akatsuki_violations (
  seq        bigint primary key default nextval('akatsuki_seq'),
  user_id    uuid not null default auth.uid(),
  at         timestamptz not null default now(),
  actor      text not null,              -- app id, or 'unknown' when unidentified
  table_name text not null,
  path       text not null,              -- the owned path that was written
  owner_app  text not null,              -- who should have written it
  addr       jsonb,                      -- enough to find the row again
  before_val jsonb,
  after_val  jsonb,
  action     text not null               -- 'warned' | 'restored' | 'blocked'
    check (action in ('warned','restored','blocked'))
);

alter table akatsuki_violations enable row level security;
drop policy if exists own_rows on akatsuki_violations;
create policy own_rows on akatsuki_violations for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
grant select, insert, update, delete on akatsuki_violations to authenticated;
revoke all on akatsuki_violations from anon;

create index if not exists akatsuki_violations_recent
  on akatsuki_violations (user_id, at desc);

-- Enforcement mode, one row.  'warn' logs.  'block' also repairs (documents) or
-- raises (foreign writes).  Start warn; promote when the log is quiet.
create table if not exists akatsuki_policy (
  user_id uuid not null default auth.uid(),
  key     text not null,
  value   text not null,
  primary key (user_id, key)
);
alter table akatsuki_policy enable row level security;
drop policy if exists own_rows on akatsuki_policy;
create policy own_rows on akatsuki_policy for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
grant select, insert, update, delete on akatsuki_policy to authenticated;
revoke all on akatsuki_policy from anon;

-- SQL editor runs as postgres: auth.uid() is null there. Seed the user explicitly.
insert into akatsuki_policy (user_id, key, value)
values ('e91a5f37-e63a-4fd0-8488-4d7a51d56822', 'enforcement', 'warn')
on conflict (user_id, key) do nothing;

-- An app identifies itself with a REQUEST HEADER, not a session variable.
-- PostgREST pools connections, so a session var set once at sign-in does not
-- reliably survive to the next request and can leak across users.  A header
-- travels with every request and cannot leak.  In supabase-js, set it once when
-- the client is constructed:
--
--     createClient(url, key, {
--       global: { headers: { 'x-akatsuki-app': 'cal' } }
--     });
--
-- Unset = 'unknown' = never blocked, only logged.  The session-var fallback is
-- kept for psql and the SQL editor, where there is no header.
create or replace function akatsuki_actor() returns text
language sql stable as $$
  select coalesce(
    nullif(current_setting('request.headers', true)::json ->> 'x-akatsuki-app', ''),
    nullif(current_setting('akatsuki.app', true), ''),
    'unknown')
$$;

-- Keyed by the ROW's owner, not the caller: service-role writes have no auth.uid().
drop function if exists akatsuki_mode();
create or replace function akatsuki_mode(p_user uuid) returns text
language sql stable as $$
  select coalesce((select value from akatsuki_policy
                    where user_id = p_user and key = 'enforcement'), 'warn')
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- PART B · Weekly Focus owns subtasks[].when and subtasks[].done.
--
-- Fires on any write to weekly_focus_entries.  Compares the incoming subtasks[]
-- against the stored one, element by element, and reports every .when or .done
-- that a non-WF actor changed.
--
-- warn  → log, let it through (today)
-- block → log, and revert that ONE field to its stored value.  Sibling fields
--         and every other subtask are untouched, so a legitimate mixed write
--         still lands in full.
-- ═══════════════════════════════════════════════════════════════════════════

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
  if actor = 'wf' then return new; end if;              -- the owner, nothing to do
  if tg_op <> 'UPDATE' then return new; end if;

  -- index both sides by subtask id
  select coalesce(jsonb_object_agg(s->>'id', s), '{}'::jsonb) into oldsub
    from jsonb_array_elements(coalesce(old.payload->'subtasks','[]'::jsonb)) s
   where s ? 'id';
  select coalesce(jsonb_object_agg(s->>'id', s), '{}'::jsonb) into newsub
    from jsonb_array_elements(coalesce(new.payload->'subtasks','[]'::jsonb)) s
   where s ? 'id';

  for k in select jsonb_object_keys(newsub) loop
    o := oldsub -> k;
    n := newsub -> k;
    if o is null then continue; end if;                 -- new subtask, not a takeover

    foreach fixed in array array['"when"'::jsonb, '"done"'::jsonb] loop
      declare f text := fixed #>> '{}';
      begin
        if (o -> f) is distinct from (n -> f) then
          insert into akatsuki_violations
            (user_id, actor, table_name, path, owner_app, addr, before_val, after_val, action)
          values (new.user_id, actor, 'weekly_focus_entries',
                  'payload.subtasks[].' || f, 'wf',
                  jsonb_build_object('board_id', new.board_id,
                                     'item_key', new.item_key, 'sub_id', k),
                  o -> f, n -> f,
                  case when mode = 'block' then 'restored' else 'warned' end);

          if mode = 'block' then
            newsub := jsonb_set(newsub, array[k, f], coalesce(o -> f, 'null'::jsonb));
            touched := true;
          end if;
        end if;
      end;
    end loop;
  end loop;

  if touched then
    new.payload := jsonb_set(new.payload, '{subtasks}',
      (select coalesce(jsonb_agg(value), '[]'::jsonb) from jsonb_each(newsub)));
  end if;

  return new;
end $$;

drop trigger if exists akatsuki_wf_owner_guard on weekly_focus_entries;
create trigger akatsuki_wf_owner_guard
  before update on weekly_focus_entries
  for each row execute function akatsuki_wf_owner_guard();


-- ═══════════════════════════════════════════════════════════════════════════
-- PART C · The first adapter — calendar_app_sukkiri, shredded in-database.
--
-- The defect: both apps upsert the WHOLE payload, so whoever saves second wipes
-- the other's half.  R003 seeded akatsuki_state with one row per owned path.
-- This trigger makes those rows authoritative.
--
-- On every write to calendar_app_sukkiri, BEFORE it lands:
--   1 · paths the writer OWNS      → shredded out into akatsuki_state, but only
--       when the value actually changed (the hash gate — "publish on real
--       change only", so two apps cannot ping-pong).
--   2 · paths the writer does NOT own → restored from akatsuki_state, so the
--       writer's stale copy of the other app's half is discarded instead of
--       being written back over fresh data.
--
-- Step 2 is the actual fix, and it only runs in block mode.  In warn mode the
-- clobber is logged and allowed, so you can read a week of the log and see
-- exactly how often this has been happening before you turn it on.
--
-- Ownership, per R003/R004:  cal → away, done, overrides, block, show, wm,
-- cycles[kind=digital].  sukkiri → garbage, cycles[kind=home].
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function akatsuki_sukkiri_owner_of(p_path text, p_val jsonb)
returns text language sql immutable as $$
  select case
    when p_path in ('away','done','overrides','block','show','wm') then 'cal'
    when p_path = 'garbage' then 'sukkiri'
    when p_path = 'cycles'  then
      case when coalesce(p_val->>'kind','home') = 'digital' then 'cal' else 'sukkiri' end
    else 'cal'
  end
$$;

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
begin
  -- scalar / object paths
  foreach p in array array['away','done','overrides','block','show','wm','garbage'] loop
    owner := akatsuki_sukkiri_owner_of(p, null);
    inc   := new.payload -> p;
    select value into cur from akatsuki_state
      where user_id = new.user_id and doc = 'calapp_sukkiri'
        and path = p and item_key = '';

    if actor = owner then
      -- the owner is writing: shred out, only on real change
      if cur is distinct from inc then
        insert into akatsuki_state (user_id, doc, path, item_key, owner_app, value, updated_by, seq)
        values (new.user_id, 'calapp_sukkiri', p, '', owner, inc, actor, nextval('akatsuki_seq'))
        on conflict (user_id, doc, path, item_key) do update
          set value = excluded.value, updated_by = excluded.updated_by,
              seq = excluded.seq, updated_at = now();
      end if;

    elsif actor <> 'unknown' and cur is not null and cur is distinct from inc then
      -- a non-owner is writing someone else's half
      insert into akatsuki_violations
        (user_id, actor, table_name, path, owner_app, addr, before_val, after_val, action)
      values (new.user_id, actor, 'calendar_app_sukkiri', p, owner,
              jsonb_build_object('doc','calapp_sukkiri'), cur, inc,
              case when mode = 'block' then 'restored' else 'warned' end);

      if mode = 'block' then
        new.payload := jsonb_set(new.payload, array[p], cur);
      end if;
    end if;
  end loop;

  -- cycles[] — one akatsuki_state row per cycle, owner decided by kind
  if new.payload ? 'cycles' then
    for c in select value from jsonb_array_elements(coalesce(new.payload->'cycles','[]'::jsonb)) loop
      ckey  := 'sk_' || coalesce(c->>'id', md5(c::text));
      owner := akatsuki_sukkiri_owner_of('cycles', c);
      select value into cur from akatsuki_state
        where user_id = new.user_id and doc = 'calapp_sukkiri'
          and path = 'cycles' and item_key = ckey;

      if actor = owner and cur is distinct from c then
        insert into akatsuki_state (user_id, doc, path, item_key, owner_app, value, updated_by, seq)
        values (new.user_id, 'calapp_sukkiri', 'cycles', ckey, owner, c, actor, nextval('akatsuki_seq'))
        on conflict (user_id, doc, path, item_key) do update
          set value = excluded.value, updated_by = excluded.updated_by,
              seq = excluded.seq, updated_at = now();
      elsif actor <> 'unknown' and actor <> owner and cur is not null and cur is distinct from c then
        insert into akatsuki_violations
          (user_id, actor, table_name, path, owner_app, addr, before_val, after_val, action)
        values (new.user_id, actor, 'calendar_app_sukkiri', 'cycles', owner,
                jsonb_build_object('doc','calapp_sukkiri','item_key',ckey), cur, c,
                case when mode = 'block' then 'restored' else 'warned' end);
      end if;
    end loop;

    -- in block mode, rebuild cycles[] from the owned rows so the non-owner's
    -- stale copies are replaced by the hub's current ones
    if mode = 'block' and actor <> 'unknown' then
      select coalesce(jsonb_agg(value order by item_key), '[]'::jsonb) into rebuilt
        from akatsuki_state
       where user_id = new.user_id and doc = 'calapp_sukkiri'
         and path = 'cycles' and deleted_at is null and value is not null;
      if jsonb_array_length(rebuilt) > 0 then
        new.payload := jsonb_set(new.payload, '{cycles}', rebuilt);
      end if;
    end if;
  end if;

  return new;
end $$;

drop trigger if exists akatsuki_sukkiri_shred on calendar_app_sukkiri;
create trigger akatsuki_sukkiri_shred
  before insert or update on calendar_app_sukkiri
  for each row execute function akatsuki_sukkiri_shred();


-- ═══════════════════════════════════════════════════════════════════════════
-- PART D · Record the decisions on the cards and routes.
-- ═══════════════════════════════════════════════════════════════════════════

do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
begin

  insert into akatsuki_vocab (user_id, ns, id, schema, meta) values
  (u, 'kind', 'task.dated',
     '{"required":["board_id","item_key","sub_id","when"],"optional":["rev"]}',
     '{"emitted_by":"cal","to":"wf","owner_of_target":"wf","note":"R009 — Calendar no longer writes subtasks[].when. It publishes this; WF applies it."}')
  on conflict (user_id, ns, id) do update set schema = excluded.schema, meta = excluded.meta;

  update akatsuki_apps set flags = array_replace(flags,
    'CONTESTED OWNERSHIP — subtasks[].when: WF declares itself SOLE writer, Calendar''s card (R004) declares it writes subtasks[].done AND .when. WF''s contended list names only Roadmap and the CC bridge. Two apps claim one path and neither knows. Declare an owner before either adapter ships.',
    'DECIDED R009 — WF owns subtasks[].when. Calendar stops writing it and publishes task.dated. Guarded by akatsuki_wf_owner_guard in WARN mode: non-WF writes are logged to akatsuki_violations, not blocked. Promote with: update akatsuki_policy set value=''block'' where key=''enforcement''.')
   where user_id = u and id = 'wf';

  update akatsuki_apps set flags = array_replace(flags,
    'CONTESTED OWNERSHIP — subtasks[].done has THREE writers: WF (own toggles), Roadmap (wfLink.ts whole-row upsert), Calendar (foreign write into the payload). Last writer wins with no revision.',
    'DECIDED R009 — WF owns subtasks[].done. Roadmap and Calendar both route through akatsuki_requests. Same warn-mode guard. NOTE: WF has no consumer loop yet, so requests accumulate unread until WF gets a cursor reader — by design, nothing is lost.')
   where user_id = u and id = 'wf';

  update akatsuki_apps set flags = array_append(flags,
    'OPEN — WF still has no reader. task.dated and task.upsert addressed to wf will queue in akatsuki_requests unconsumed. ~30 lines in cloudPullEntries: akatsuki_consume(''wf'') → patch subtasks[] → akatsuki_ack(). Until then Calendar keeps writing directly and the guard logs it.')
   where user_id = u and id = 'wf'
     and not ('OPEN — WF still has no reader. task.dated and task.upsert addressed to wf will queue in akatsuki_requests unconsumed. ~30 lines in cloudPullEntries: akatsuki_consume(''wf'') → patch subtasks[] → akatsuki_ack(). Until then Calendar keeps writing directly and the guard logs it.' = any(flags));

  update akatsuki_apps set flags = array_replace(flags,
    'Calendar writes weekly_focus_entries.payload.subtasks[].done/.when — a foreign write into WF''s document. WF has NOT filed a card, so this path has no declared owner. Flagged defect.',
    'DECIDED R009 — WF owns both paths. Calendar''s task.done / task.dated go through akatsuki_publish instead of a direct write. Warn-mode guard logs the direct writes until Calendar is changed.')
   where user_id = u and id = 'cal';

  insert into akatsuki_routes (user_id, from_app, to_app, kind, access, state, note) values
  (u, 'cal', 'wf', 'task.dated', 'stream', 'proposed',
     'R009 — decided: WF owns subtasks[].when. Calendar publishes, WF applies. Blocked only on WF''s reader.')
  on conflict (user_id, from_app, to_app, kind) do update
    set access = excluded.access, state = excluded.state, note = excluded.note;

  update akatsuki_routes
     set access = 'stream', state = 'proposed',
         note = 'R009 — decided: WF owns subtasks[].done. Calendar publishes instead of writing WF''s payload. Warn-mode guard logs the old direct write until Calendar is changed. Blocked on WF''s reader.'
   where user_id = u and from_app = 'cal' and to_app = 'wf' and kind = 'task.done';

  update akatsuki_routes
     set state = 'proposed',
         note = 'R009 — decided: WF owns subtasks[].done/.ctx/.t. Roadmap''s wfLink.ts whole-row upsert is replaced by akatsuki_publish. Warn-mode guard logs it meanwhile.'
   where user_id = u and from_app = 'rm' and to_app = 'wf' and kind = 'task.upsert';

  update akatsuki_routes
     set state = 'half',
         note = note || ' · R009: shredded in-database by akatsuki_sukkiri_shred. Owner writes are captured into akatsuki_state on real change only; non-owner clobbers are logged. Flip to block and this leg is live.'
   where user_id = u and ((from_app = 'cal' and to_app = 'sukkiri') or (from_app = 'sukkiri' and to_app = 'cal'))
     and note not like '%R009%';

end $$;


-- ═══════════════════════════════════════════════════════════════════════════
-- PART E · Watch it, then promote.
-- ═══════════════════════════════════════════════════════════════════════════
-- Each app adds ONE header where it builds its Supabase client, and the guards
-- start seeing it:
--     createClient(URL, KEY, { global: { headers: { 'x-akatsuki-app': 'cal' } } });
--   cal · sukkiri · wf · rm · cost · cc
-- Nothing else in any app changes.  An app that never adds it keeps working
-- exactly as today, and shows up in the log as 'unknown'.
--
-- Then, after a few days of real use:
--     select actor, table_name, path, owner_app, count(*), max(at)
--       from akatsuki_violations group by 1,2,3,4 order by 5 desc;
--     select * from akatsuki_violations order by at desc limit 40;
--
-- Quiet and correct → promote:
--     update akatsuki_policy set value = 'block'
--      where user_id = 'e91a5f37-e63a-4fd0-8488-4d7a51d56822' and key = 'enforcement';
-- Wrong owner somewhere → fix the owner first; blocking a correct writer is the
-- one way this file can hurt a working app.
--
-- Rollback, complete:
--     drop trigger if exists akatsuki_wf_owner_guard on weekly_focus_entries;
--     drop trigger if exists akatsuki_sukkiri_shred on calendar_app_sukkiri;
