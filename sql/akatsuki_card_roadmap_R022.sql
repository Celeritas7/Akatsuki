-- ============================================================================
-- Akatsuki R022 — Roadmap (rm) files its card · Roadmap ↔ WF link · the banner.
-- Run after R021.  Idempotent.  Source: Celeritas7/Roadmap_advanced@main (read
-- 2026-10-03) + the user's answers (cards/roadmap.md).
--
--   A. Read-only checks.  RUN FIRST, paste results back.  Nothing below A runs
--      until A is read: it decides two flags and whether step 1 is bigger.
--   B. The card, vocab, routes, the shared tags view, the when-split decision.
--   C. Flip routes live — commented, run after the adapters ship and the gate passes.
-- ============================================================================

-- ═══ A · checks (reads only) ═════════════════════════════════════════════════
-- A1 · V2-D: was any of it applied?  Expect both null.
select to_regclass('public.task_links') task_links, to_regclass('public.roadmap_contexts_map') contexts_map;

-- A2 · Does WF already publish task.upsert to rm (route is 'half' since R001)?  Any rows?
select kind, status, count(*), min(created_at), max(created_at)
  from akatsuki_requests where from_app = 'wf' and to_app = 'rm' group by 1, 2 order by 1, 2;

-- A3 · Is anything from Roadmap writing WF rows today?  (actor 'rm' or 'unknown' on wf paths)
select * from akatsuki_violations limit 40;

-- A4 · Roadmap trust: owners and RLS.  The repo says RLS is off and there is no sign-in.
select count(*) total, count(*) filter (where user_id is null) no_owner, count(distinct user_id) owners from roadmap_tasks;
select relname, relrowsecurity rls_on from pg_class
 where relkind = 'r' and relname like 'roadmap\_%' order by 1;

-- A5 · The rm card as it stands (from R001) and every route touching rm.
select id, name, pattern, emits, accepts, session, reach, flags from akatsuki_apps where id = 'rm';
select from_app, to_app, kind, access, state, note from akatsuki_routes where 'rm' in (from_app, to_app) order by 1, 2, 3;

-- A6 · Contexts: the one list.  Roadmap's seed has 9 (home train office audio-only keyboard
--      short-burst deep-focus auto-interview daily-routine); WF hardcodes 7 (var CTX).
select id, meta from akatsuki_vocab where ns = 'context' order by id;
select pg_get_constraintdef(oid) vocab_ns_check from pg_constraint
 where conrelid = 'akatsuki_vocab'::regclass and contype = 'c';

-- A7 · One real WF subtask, for the view in B (expect t, done, u, ctx, urg, dl, lat, latAt, when, del, id).
select board_id, item_key, payload->'subtasks'->0 first_subtask
  from weekly_focus_entries
 where jsonb_typeof(payload->'subtasks') = 'array' and jsonb_array_length(payload->'subtasks') > 0
 limit 1;

-- A8 · Added Oct 3 after A1/A4 contradicted the repo: V2-D tables EXIST and RLS is ON.
-- A8a · Is V2-D in use?  Rows in task_links = the wfLink sync ran at least once.
select (select count(*) from task_links) link_rows,
       (select count(*) from roadmap_contexts_map) ctx_rows,
       to_regclass('public.weekly_focus_tasks') wf_tasks_table;
select column_name, data_type from information_schema.columns where table_name = 'task_links' order by ordinal_position;
-- A8b · The RLS policies Roadmap actually runs under.  using (true) = RLS on in name only.
select tablename, policyname, cmd, roles, qual, with_check from pg_policies where tablename like 'roadmap\_%' order by 1, 2;
-- A8c · Owners (the first A4 query, not yet pasted).
select count(*) total, count(*) filter (where user_id is null) no_owner, count(distinct user_id) owners from roadmap_tasks;
-- A8d · The live schema vs the repo: tables the repo's migration does not know.
select table_name from information_schema.tables where table_schema = 'public' and table_name like 'roadmap\_%' order by 1;

-- ═══ B · card ════════════════════════════════════════════════════════════════
do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
        a text;
begin
  -- B1 · Roadmap's card.
  insert into akatsuki_apps (
    user_id, id, name, role, pattern, address_shape, clock_field, clock_trust,
    emits, accepts, deletes, private_fields, session, reach, payload_map, owned_paths, flags
  ) values (
    u, 'rm', 'Roadmap', 'app', 'stream',
    'roadmap_tasks.id uuid (user_id DB default) · a WF mirror is addressed by WF''s word {board_id,item_key,sub_id}; the pair lives in akatsuki_links (a=wf,b=rm), no Roadmap column',
    'roadmap_tasks.updated_at — trigger roadmap_touch_updated_at, server-set, moves on every update incl. done · roadmap_study_sessions: none',
    'trigger',
    '{task.done,task.skipped}',
    '{task.upsert,suggestion.answered,session.completed}',
    'hard',
    '{roadmap_daily_logs.notes,roadmap_suggestions.*,roadmap_user_settings.*}',
    'guest',
    'SINGLE session, same project, main client · TODAY NO SIGN-IN (bare anon key, RLS off) → step 1 adds Supabase Auth (Google OAuth or magic link) + header x-akatsuki-app: rm; flip session to jwt then · Vite :5173 · GitHub Pages · entry index.html → src/main.tsx · hub scripts public/akatsuki/ · no service worker · window.rm.hub · reach: WF tasks = stream task.upsert · WF tags = view akatsuki_task_tags · contexts/places = vocab · mood/energy/device = private',
    '{"task.upsert (in)":{"title":"subtasks[].t","done":"subtasks[].done","ctx":"subtasks[].ctx","parked":"subtasks[].lat","deleted":"subtasks[].del","date":"subtasks[].when (date part)","addr":"{board_id,item_key,sub_id}","mirror":"roadmap_tasks row, kind task, tags [''wf'', project by item_key prefix]"},
      "task.done (out)":{"board_id":"links.a_addr.board_id","item_key":"links.a_addr.item_key","sub_id":"links.a_addr.sub_id","at":"now() iso","suggestion_id":"roadmap_suggestions.id | null"},
      "task.skipped (out)":{"addr":"same three","reason":"user text, required","suggestion_id":"roadmap_suggestions.id","at":"now() iso"},
      "roadmap_now.suggestion (doc)":{"id":"roadmap_suggestions.id","task":"{board_id,item_key,sub_id} | {rm_id}","title":"text","level":"enum level","say":"the line to show","tone_step":"0..5","until":"iso — banner hides after","made_at":"iso"},
      "task_tags.rm/<addr> (doc)":{"type":"enum task_type","effort":"enum effort","level":"enum level","guessed":"bool — true until the user corrects"}}',
    '{roadmap_now.suggestion,task_tags.rm/*,roadmap_tasks.*,roadmap_daily_logs.*,roadmap_user_settings.*,roadmap_study_sessions.*,roadmap_suggestions.*}',
    '{
      "R022 DEFECT — RLS DISABLED on every roadmap_* table (migration 0001, single-user mode). Hub rule: RLS on every table, user_id = auth.uid(). Step 1 enables it; A4 measures owners first.",
      "R022 DEFECT — NO SIGN-IN: src/lib/supabase.ts creates the client on the anon key and no code path calls signIn*. Every hub RPC needs auth.uid(). Step 1 adds Supabase Auth on the main client (same user as the other apps) + header x-akatsuki-app: rm.",
      "R022 — V2-D (docs/v2d-wf-link) RETIRED unapplied: direct writes to weekly_focus_entries, last-write-wins on client clocks, task_links table. A1 confirms nothing was created. Replaced by stream + reply + akatsuki_links.",
      "R022 — the suggester runs ONLY while Roadmap is open (nothing records while no connected app is open). Banners in other apps show the last suggestion with its until; after that they say open Roadmap. No push channel.",
      "R022 — contexts: vocab ns=context is the one list. Roadmap drops its seed CONTEXTS constant for the vocab read; WF drops var CTX (R006 flag). roadmap_contexts_map is never created.",
      "R022 — level = role: attackers/FWD → attacker · midplayers/MID → midplayer · defenders/DEF → defender. A WF mirror takes its folder project''s role; task_tags.rm/<addr>.level overrides.",
      "R022 — energy low: Attacker weight × 0.4, escalation paused (tone capped at current step, softer copy). Never hides a task.",
      "R022 — tone: 5 steps, +1 per miss, reset to 0 on a done. Miss = until passed with no answer, or skip with empty reason. Weekly miss log Friday 18:00 local, Roadmap-private.",
      "?? Vite dev port assumed 5173 (vite.config.ts not read for server.port). Confirm in step 1 reply."
    }'
  )
  on conflict (user_id, id) do update set
    name = excluded.name, role = excluded.role, pattern = excluded.pattern,
    address_shape = excluded.address_shape, clock_field = excluded.clock_field, clock_trust = excluded.clock_trust,
    emits = excluded.emits, accepts = excluded.accepts, deletes = excluded.deletes,
    private_fields = excluded.private_fields, session = excluded.session, reach = excluded.reach,
    payload_map = excluded.payload_map, owned_paths = excluded.owned_paths, flags = excluded.flags,
    updated_at = now();

  -- B2 · WF accepts the two new kinds; every connected app emits suggestion.answered.
  update akatsuki_apps set accepts = array(select distinct x from unnest(accepts || '{task.done,task.skipped}') x), updated_at = now()
   where user_id = u and id = 'wf';
  foreach a in array array['wf','cost','sukkiri','cal','scriptura','jlpt','cc'] loop
    update akatsuki_apps set emits = array(select distinct x from unnest(emits || '{suggestion.answered}') x), updated_at = now()
     where user_id = u and id = a;
  end loop;

  -- B3 · The when-split decision lands on both cards (open since R008).
  update akatsuki_apps set flags = flags || array[
    'R022 DECIDED — subtasks[].when: WF owns the DATE. Calendar owns the TIME SLOT, which moves to its own path calapp_wf.slot/<board_id>/<item_key>/<sub_id> on Calendar''s next touch. Until then Calendar''s write to .when is a defect route (R004).'::text],
    updated_at = now()
   where user_id = u and id in ('wf','cal')
     and not exists (select 1 from unnest(flags) f where f like 'R022 DECIDED — subtasks[].when%');

  -- B4 · Vocab: kinds.
  insert into akatsuki_vocab (user_id, ns, id, schema, meta) values
  (u, 'kind', 'task.done',
     '{"required":["board_id","item_key","sub_id","at"],"optional":["suggestion_id"]}',
     '{"emitted_by":"rm","accepted_by":"wf","on":"user ticks a WF mirror in Roadmap, or Done on a suggestion",
       "src_addr":"{board_id,item_key,sub_id}","idempotency_key":"rm:done:<board_id>/<item_key>/<sub_id>:<day_key> — one per task per logical day (4 AM reset)",
       "reply_statuses":"enum wf_apply_status","closed_statuses":["applied","already","unknown"],
       "wf_applies":"subtasks[].done=true, u=Date.now(); already if done; unknown if no such subtask; stale if del"}'),
  (u, 'kind', 'task.skipped',
     '{"required":["board_id","item_key","sub_id","reason","at"],"optional":["suggestion_id"]}',
     '{"emitted_by":"rm","accepted_by":"wf","on":"Skip with a reason in Roadmap or a banner",
       "src_addr":"{board_id,item_key,sub_id}","idempotency_key":"rm:skip:<board_id>/<item_key>/<sub_id>:<suggestion_id>",
       "reply_statuses":"enum wf_apply_status","closed_statuses":["applied","already","unknown"],
       "wf_applies":"subtasks[].lat=true, latAt=u=Date.now(); the reason is NOT stored in WF (Roadmap-private)"}'),
  (u, 'kind', 'suggestion.answered',
     '{"required":["suggestion_id","action","at","app"],"optional":["reason"]}',
     '{"emitted_by":"wf cost sukkiri cal scriptura jlpt cc","accepted_by":"rm","on":"a banner button",
       "src_addr":"{suggestion_id}","idempotency_key":"<app>:ans:<suggestion_id> — one answer per app per suggestion",
       "types":{"action":"enum answer_action","reason":"text — required when action=skip or the skip counts as a miss"},
       "no_reply":true,"note":"lands when Roadmap next opens; the banner marks the suggestion answered locally the moment it publishes"}')
  on conflict (user_id, ns, id) do update set schema = excluded.schema, meta = excluded.meta;

  -- B5 · Vocab: shared enums.  Apps read these; nobody keeps a copy.
  insert into akatsuki_vocab (user_id, ns, id, schema, meta) values
  (u, 'enum', 'task_type',       '{"values":["writing","screenshots","review","coding","reading","admin","errand","practice"]}', '{"owner":"rm","guessed_from":"title + WF tag; user corrects in Roadmap"}'),
  (u, 'enum', 'effort',          '{"values":["quick","medium","deep"]}',                       '{"owner":"rm","guessed_from":"title; ctx @short-burst → quick, @deep-focus → deep"}'),
  (u, 'enum', 'level',           '{"values":["defender","midplayer","attacker"]}',             '{"owner":"rm","from":"role: defenders → defender, midplayers → midplayer, attackers → attacker"}'),
  (u, 'enum', 'device',          '{"values":["phone","laptop","either"]}',                     '{"owner":"rm","from":"ctx @phone-only → phone, @keyboard → laptop, else either; the device in hand is asked in Roadmap"}'),
  (u, 'enum', 'place',           '{"values":["anywhere","home","office","cafe","transit"]}',   '{"owner":"hub","from":"ctx @home/@office/@train(→transit); Roadmap Location any→anywhere, train→transit","until":"R018 visits replace the manual pick"}'),
  (u, 'enum', 'energy',          '{"values":["low","mid","high"]}',                            '{"owner":"rm","asked":"energy × mood grid, only when > 3 h since the last answer"}'),
  (u, 'enum', 'mood',            '{"values":["down","flat","good"]}',                          '{"owner":"rm"}'),
  (u, 'enum', 'answer_action',   '{"values":["start","skip","dismiss"]}',                      '{"owner":"rm","miss":"dismiss, or skip with an empty reason, or until passed unanswered"}'),
  (u, 'enum', 'wf_apply_status', '{"values":["applied","already","unknown","stale"]}',         '{"owner":"wf","on":"task.done, task.skipped"}')
  on conflict (user_id, ns, id) do update set schema = excluded.schema, meta = excluded.meta;

  -- B6 · Routes.
  insert into akatsuki_routes (user_id, from_app, to_app, kind, access, state, note) values
  (u, 'rm', 'wf', 'task.done',    'stream', 'proposed', 'R022 — reply pattern; WF owns done and applies. Live when WF consumes + replies and Roadmap reads replies.'),
  (u, 'rm', 'wf', 'task.skipped', 'stream', 'proposed', 'R022 — reply pattern; WF parks (lat). Reason stays in Roadmap.'),
  (u, 'rm', 'wf', 'task.upsert',  'direct', 'retired',  'R022 — V2-D wfLink.ts never shipped (A1). Replaced by task.done / task.skipped.'),
  (u, 'rm', 'wf', 'context.vocab','view',   'retired',  'R022 — roadmap_contexts_map is not created. akatsuki_vocab ns=context is the one list for both.')
  on conflict (user_id, from_app, to_app, kind) do update set access = excluded.access, state = excluded.state, note = excluded.note;
  update akatsuki_routes set note = 'R022 — WF → RM for every item_key prefix (study, app, office). Roadmap mirrors into roadmap_tasks via akatsuki_links. Live when Roadmap consumes and the first real pass lands.', state = 'half'
   where user_id = u and from_app = 'wf' and to_app = 'rm' and kind = 'task.upsert';
  foreach a in array array['wf','cost','sukkiri','cal','scriptura','jlpt','cc'] loop
    insert into akatsuki_routes (user_id, from_app, to_app, kind, access, state, note) values
    (u, a, 'rm', 'suggestion.answered', 'stream', 'proposed', 'R022 — banner answer. Live when the app loads akatsuki-banner.js.'),
    (u, 'rm', a, 'suggestion.now',      'view',   'proposed', 'R022 — the app reads doc roadmap_now (akatsuki_docs) for its banner. Zero copy.')
    on conflict (user_id, from_app, to_app, kind) do update set access = excluded.access, state = excluded.state, note = excluded.note;
  end loop;
  insert into akatsuki_routes (user_id, from_app, to_app, kind, access, state, note) values
  (u, 'wf', 'rm', 'task.tags', 'view', 'proposed', 'R022 — view akatsuki_task_tags: WF''s ctx/urg/dl joined with Roadmap''s type/effort/level. Read-only for both.')
  on conflict (user_id, from_app, to_app, kind) do update set access = excluded.access, state = excluded.state, note = excluded.note;

  update akatsuki_credentials set consumers = array(select distinct x from unnest(consumers || '{rm}') x)
   where user_id = u and name = 'supabase_anon';
end $$;

-- B7 · The shared tag store: one view, two owners, zero copy.
--      A7 (Oct 3): urg and dl are booleans when unset (false), when is '' — normalised to bool / null below.
--      WF's side comes from weekly_focus_entries; Roadmap's from akatsuki_state (doc task_tags, path rm).
--      security_invoker: each reader sees only their own rows once Roadmap's RLS is on.
create or replace view akatsuki_task_tags with (security_invoker = on) as
select e.user_id, e.board_id, e.item_key, s->>'id' as sub_id,
       e.board_id || '/' || e.item_key || '/' || (s->>'id') as addr_key,
       s->>'t' as title,
       coalesce((s->>'done')::bool, false) as done,
       coalesce((s->>'lat')::bool, false)  as parked,
       coalesce((s->>'del')::bool, false)  as deleted,
       s->'ctx'  as ctx,
       coalesce(s->>'urg', 'false') not in ('false', '', '0') as urg,
       nullif(nullif(s->>'dl', 'false'), '') as dl,
       nullif(s->>'when', '') as when_date,
       t.value->>'type'   as type,
       t.value->>'effort' as effort,
       t.value->>'level'  as level,
       coalesce((t.value->>'guessed')::bool, true) as guessed,
       e.updated_at as wf_updated_at, t.seq as rm_seq
  from weekly_focus_entries e
  cross join lateral jsonb_array_elements(case when jsonb_typeof(e.payload->'subtasks') = 'array' then e.payload->'subtasks' else '[]'::jsonb end) s
  left join akatsuki_state t
    on t.user_id = e.user_id and t.doc = 'task_tags' and t.path = 'rm' and t.deleted_at is null
   and t.item_key = e.board_id || '/' || e.item_key || '/' || (s->>'id')
 where e.item_key not like '\_\_%';
comment on view akatsuki_task_tags is 'R022 — WF owns ctx/urg/dl/when; Roadmap owns type/effort/level (akatsuki_state doc task_tags). Read-only.';
grant select on akatsuki_task_tags to authenticated;

-- ═══ D · corrections after A8 (Oct 3) — idempotent, run once ════════════════
-- A8 showed: RLS ON with user_id = auth.uid() on every roadmap_* table · 128 tasks, 0 unowned,
-- 2 OWNERS · task_links EXISTS in a newer shape than V2-D (wf_board_id, wf_item_key, wf_sub_id,
-- wf_u, rm_seen_at, orphaned_at) · roadmap_contexts_map exists (read-only policy) · extra tables
-- roadmap_session_days, roadmap_task_resources.  So: the repo's main is STALE; the live build
-- signs in, has RLS, and already runs a WF link that writes WF rows directly.
do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
begin
  update akatsuki_apps set
    session = 'jwt',
    flags = array(select f from unnest(flags) f where f not like 'R022 DEFECT — RLS DISABLED%' and f not like 'R022 DEFECT — NO SIGN-IN%' and f not like 'R022 — V2-D (docs/v2d-wf-link) RETIRED unapplied%')
         || array[
    'R022 CORRECTED (A8) — repo main is STALE vs the live DB: live has RLS user_id = auth.uid() on all roadmap_* tables, sign-in, roadmap_session_days, roadmap_task_resources. Card facts come from the DB; step 1 asks for the live code to be pushed to main.',
    'R022 DEFECT (A8) — task_links EXISTS (wf_board_id, wf_item_key, wf_sub_id, rm_task_id, wf_u, rm_seen_at, orphaned_at, source, last_synced_at): a live wfLink that reads and WRITES weekly_focus_entries directly — the foreign writer in WF''s R006 flag. Step 1: delete the WF write path, consume task.upsert instead, migrate task_links → akatsuki_links, then drop the table.',
    'R022 (A8) — roadmap_contexts_map exists with a read-only policy. The one list is akatsuki_vocab ns=context; Roadmap reads vocab, then the table is dropped.',
    '?? R022 (A8) — roadmap_tasks has 2 distinct user_id values (128 rows, 0 null). Which is the second account? Measure before RLS is trusted for the hub pass: select user_id, count(*) from roadmap_tasks group by 1.'
    ]::text[],
    updated_at = now()
   where user_id = u and id = 'rm'
     and not exists (select 1 from unnest(flags) f where f like 'R022 CORRECTED (A8)%');

  -- The direct writer is live, not retired.  Back to defect until step 1 deletes it.
  update akatsuki_routes set access = 'direct', state = 'defect',
    note = 'R022 (A8) — live wfLink writes weekly_focus_entries via task_links. Defect until Roadmap step 1 deletes the write path; then retired. Replaced by task.done / task.skipped.'
   where user_id = u and from_app = 'rm' and to_app = 'wf' and kind = 'task.upsert';
end $$;
-- A8e · the second owner
select user_id, count(*) from roadmap_tasks group by 1 order by 2 desc;
-- A8a (not yet pasted) · is the live link in use?
-- A8a result (Oct 3): link_rows 12 · orphaned 0 · last_sync 2026-09-21 07:52Z · ctx_rows 7.
-- The wfLink has not run since Sep 21 (the duplicate-folder race). Dead, not live: step 1 deletes it and migrates 12 pairs.
select (select count(*) from task_links) link_rows, (select count(*) from task_links where orphaned_at is not null) orphaned,
       (select max(last_synced_at) from task_links) last_sync, (select count(*) from roadmap_contexts_map) ctx_rows;

-- ═══ E · merge the second account (Oct 3) — run ONCE, after signing Roadmap out of it ═══
-- A8e: 849deb74-2dac-4910-b043-a92b698fe16f = anikettelexistence@gmail.com (google), the user's
-- other address — 46 tasks, last sign-in 2026-10-03 03:19Z.  The hub user is e91a5f37… =
-- mangaonkaraniket@gmail.com.  Every connected app signs in as the hub user; rows move to it.
do $$
declare hub_u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
        old_u uuid := '849deb74-2dac-4910-b043-a92b698fe16f';
begin
  update roadmap_tasks           set user_id = hub_u where user_id = old_u;
  update roadmap_daily_logs      set user_id = hub_u where user_id = old_u;
  update roadmap_study_sessions  set user_id = hub_u where user_id = old_u;
  update roadmap_task_resources  set user_id = hub_u where user_id = old_u;
  -- session_days: only if it has a user_id column
  if exists (select 1 from information_schema.columns where table_name = 'roadmap_session_days' and column_name = 'user_id') then
    execute 'update roadmap_session_days set user_id = $1 where user_id = $2' using hub_u, old_u;
  end if;
  -- settings is one row per user: keep the hub user's, drop the stray
  delete from roadmap_user_settings where user_id = old_u and exists (select 1 from roadmap_user_settings where user_id = hub_u);
  update roadmap_user_settings set user_id = hub_u where user_id = old_u;
  -- task_links / roadmap_contexts_map have no user_id (A8a columns) — nothing to move.
  update akatsuki_apps set flags = array(select f from unnest(flags) f where f not like '?? R022 (A8) — roadmap_tasks has 2 distinct user_id%')
       || array['R022 (A8e) — second owner 849deb74… = the user''s other Google address (anikettelexistence@). 46 tasks + logs/sessions/resources moved to the hub user e91a5f37… on Oct 3. Roadmap must sign in as mangaonkaraniket@ only.']::text[],
    updated_at = now()
   where user_id = hub_u and id = 'rm' and not exists (select 1 from unnest(flags) f where f like 'R022 (A8e)%');
end $$;
-- Verify: one owner.
select count(*) total, count(distinct user_id) owners from roadmap_tasks;

-- ═══ F · seed akatsuki_links from the 12 pre-hub pairs (Oct 3, Roadmap step-1 point 3) ═══
-- Idempotent (unique user_id, a_app, a_addr, b_app).  After this Roadmap drops task_links.
insert into akatsuki_links (user_id, a_app, a_addr, a_clock, b_app, b_addr, kind, source, orphaned_at, last_synced_at)
select 'e91a5f37-e63a-4fd0-8488-4d7a51d56822',
       'wf', jsonb_build_object('board_id', t.wf_board_id, 'item_key', t.wf_item_key, 'sub_id', t.wf_sub_id), t.wf_u::text,
       'rm', jsonb_build_object('id', t.rm_task_id), 'task.upsert', 'migrated:task_links', t.orphaned_at, coalesce(t.last_synced_at, now())
  from task_links t
 where exists (select 1 from roadmap_tasks r where r.id = t.rm_task_id)
on conflict (user_id, a_app, a_addr, b_app) do nothing;
-- Verify: 12 (minus pairs whose roadmap_tasks row is gone).
select count(*) pairs, count(*) filter (where source = 'migrated:task_links') migrated from akatsuki_links where a_app = 'wf' and b_app = 'rm';

-- ═══ G · context labels + order (Oct 4, WF + Roadmap replies) — idempotent ══════
-- meta was null on every ns=context row (R001 seeded ids only).  One list for both apps:
-- WF's 7 + Roadmap's seed.  @deep-focus is Roadmap's word for @deep-work: kept as an alias.
do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
begin
  insert into akatsuki_vocab (user_id, ns, id, meta) values
  (u, 'context', '@home',              '{"label":"Home","ord":10,"family":"place"}'),
  (u, 'context', '@office',            '{"label":"Office","ord":20,"family":"place"}'),
  (u, 'context', '@train',             '{"label":"Train","ord":30,"family":"place"}'),
  (u, 'context', '@phone-only',        '{"label":"Phone only","ord":40,"family":"device"}'),
  (u, 'context', '@keyboard',          '{"label":"Keyboard","ord":50,"family":"device"}'),
  (u, 'context', '@needs-claude-code', '{"label":"Needs Claude Code","ord":60,"family":"device"}'),
  (u, 'context', '@claude-chat-only',  '{"label":"Claude chat only","ord":70,"family":"device"}'),
  (u, 'context', '@audio-only',        '{"label":"Audio only","ord":80,"family":"mode"}'),
  (u, 'context', '@short-burst',       '{"label":"Short burst","ord":90,"family":"effort"}'),
  (u, 'context', '@deep-work',         '{"label":"Deep work","ord":100,"family":"effort"}'),
  (u, 'context', '@deep-focus',        '{"label":"Deep work","ord":101,"family":"effort","alias_of":"@deep-work"}'),
  (u, 'context', '@auto-interview',    '{"label":"Auto interview","ord":110,"family":"mode"}'),
  (u, 'context', '@daily-routine',     '{"label":"Daily routine","ord":120,"family":"mode"}')
  on conflict (user_id, ns, id) do update set meta = excluded.meta;
end $$;
select id, meta->>'label' label, (meta->>'ord')::int ord, meta->>'family' family from akatsuki_vocab where ns = 'context' order by 3;

-- ═══ Gate · run each, paste (Oct 4) ═══════════════════════════════════════════
-- G1 · links (expect ≥ WF's open subtasks; 12 migrated + new ones from v97's publish)
select count(*) links, count(*) filter (where orphaned_at is not null) orphaned from akatsuki_links where a_app = 'wf' and b_app = 'rm';
-- G2 · banner answers that landed, per app
select from_app, status, count(*) from akatsuki_requests where kind = 'suggestion.answered' group by 1, 2 order by 1, 2;
-- G3 · anything stuck or blocked on the two apps
select * from akatsuki_contract where to_app in ('rm','wf') and (blocker is not null or deferred > 0);
-- G4 · the round trip (Roadmap's seq 215)
select seq, kind, status, reply->>'status' reply, reply_seq from akatsuki_requests where seq in (215, 216);

-- ═══ C · flip live (Oct 4) — gate G1–G4 pasted ═══════════════════════════════
-- G4: seq 215 task.done → applied, reply 216 ✓ · G2: wf suggestion.answered delivered 1 ✓ · G1: 12 links, 0 orphaned —
-- all migrated, NONE from v97's publish yet (see C2) · G3: AK101 rows are views (not kinds) — expected; cc→rm unbuilt — expected.
do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
begin
  update akatsuki_apps set session = 'jwt', updated_at = now() where user_id = u and id = 'rm' and session <> 'jwt';
  -- C1 · passed
  update akatsuki_routes set state = 'live', note = 'LIVE Oct 4 — round trip seq 215 → applied (reply 216). ' || note
   where user_id = u and from_app = 'rm' and to_app = 'wf' and kind in ('task.done','task.skipped') and state <> 'live';
  update akatsuki_routes set state = 'live', note = 'LIVE Oct 4 — first answer delivered (G2). ' || note
   where user_id = u and from_app = 'wf' and to_app = 'rm' and kind = 'suggestion.answered' and state <> 'live';
  update akatsuki_routes set state = 'live', note = 'LIVE Oct 4 — WF banner showed the next suggestion within the minute (Roadmap §3). ' || note
   where user_id = u and from_app = 'rm' and to_app = 'wf' and kind = 'suggestion.now' and state <> 'live';
  update akatsuki_routes set state = 'live', note = 'LIVE Oct 4 — view in place, Roadmap reads it (rmHub.tags). ' || note
   where user_id = u and from_app = 'wf' and to_app = 'rm' and kind = 'task.tags' and state <> 'live';
  -- the direct writer is gone (Roadmap §4: wfLink.ts deleted, no weekly_focus_ code)
  update akatsuki_routes set state = 'retired', note = 'RETIRED Oct 4 — wfLink.ts/wfConfig.ts deleted, no weekly_focus_ code in src (Roadmap §4). ' || note
   where user_id = u and from_app = 'rm' and to_app = 'wf' and kind = 'task.upsert' and state = 'defect';
  update akatsuki_apps set flags = array(select f from unnest(flags) f where f not like 'R022 DEFECT (A8) — task_links EXISTS%')
       || array['R022 (Oct 4) — direct WF writer deleted (wfLink.ts, wfConfig.ts). task_links still read as boot fallback; Roadmap drops it after one clean run.']::text[], updated_at = now()
   where user_id = u and id = 'rm' and exists (select 1 from unnest(flags) f where f like 'R022 DEFECT (A8) — task_links EXISTS%');
end $$;
-- C2 · wf → rm task.upsert stays HALF until a link appears that v97 made (not migrated).  Check:
select count(*) new_links, max(last_synced_at) from akatsuki_links where a_app = 'wf' and b_app = 'rm' and source <> 'migrated:task_links';
select count(*) upserts, max(created_at) from akatsuki_requests where from_app = 'wf' and to_app = 'rm' and kind = 'task.upsert';
-- when new_links > 0:
-- update akatsuki_routes set state = 'live', note = 'LIVE — first v97 publish consumed by Roadmap. ' || note
--  where from_app = 'wf' and to_app = 'rm' and kind = 'task.upsert';
-- per app, as each loads the banner:
-- update akatsuki_routes set state = 'live' where kind in ('suggestion.answered','suggestion.now') and 'cost' in (from_app, to_app);

-- ─────────────────────────────────────────────────────────────────────────────
-- Verify
-- ─────────────────────────────────────────────────────────────────────────────
-- select * from akatsuki_contract where 'rm' in (from_app, to_app) order by from_app, to_app, kind;
-- select * from akatsuki_task_tags limit 5;
-- select id, schema->'values' from akatsuki_vocab where ns = 'enum' and id in ('task_type','effort','level','device','place','energy','mood','answer_action','wf_apply_status');
