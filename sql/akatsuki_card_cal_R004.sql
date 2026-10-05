-- ============================================================================
-- Akatsuki R004 — Calendar joins the hub.  Run after R001–R003.  Idempotent.
--
-- Card source: Calendar's own reply, 2026-09-22.  Port 5161 (not 8080).
--
-- READ PART A BEFORE RUNNING.  Calendar is the first app whose card fails the
-- TRUST question, and that outranks every link in this file.
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A · Prerequisite — diagnosis only.  This part writes NOTHING.
--
-- Calendar ships two contradictory schemas:
--   schema_R001.sql              user_id UUID = auth.uid(), RLS ON, per-op policies
--   schema_R003_rain_bday.sql    user_id TEXT DEFAULT 'default-user', NO RLS   ← latest
--
-- If R003_rain_bday is what is live, then every calendar_app_* table is
-- readable and writable by anyone holding the anon key — which ships in a
-- public bundle.  Not a hub problem; a data-exposure problem.  The founding
-- rules say RLS on every table, user_id = auth.uid(), TO authenticated.
--
-- Run this first and read the answer:
-- ─────────────────────────────────────────────────────────────────────────────
select c.relname                                as table_name,
       c.relrowsecurity                         as rls_enabled,
       (select count(*) from pg_policies p
         where p.schemaname = 'public' and p.tablename = c.relname) as policies,
       (select data_type from information_schema.columns
         where table_name = c.relname and column_name = 'user_id')  as user_id_type
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public'
   and c.relname like 'calendar_app_%'
 order by 1;

-- Expected for a safe app:  rls_enabled = true, policies >= 1, user_id_type = uuid.
--
-- If rls_enabled is false, or user_id_type is 'text', STOP and fix Calendar's
-- own schema before wiring any adapter.  The repair is Calendar-side work
-- (backfill 'default-user' rows to the real uuid, alter the column, enable RLS,
-- recreate the own_cal_* policies) and is deliberately NOT scripted here —
-- Akatsuki does not rewrite an app's private tables.  Part B records the finding
-- either way, so the hub tells the truth about the risk while it is open.

-- ─────────────────────────────────────────────────────────────────────────────
-- B · The hub learns Calendar.
-- ─────────────────────────────────────────────────────────────────────────────
do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
begin

  -- Calendar's emit names map onto kinds already minted; only the two genuinely
  -- new ones are created.  cycle.digital is the mirror of R003's cycle.home.
  insert into akatsuki_vocab (user_id, ns, id, schema, meta) values
  (u, 'kind', 'day.mark',
     '{"required":["date"],"optional":["marked","markColor","isGoal","note"]}',
     '{"emitted_by":"cal","on":"pushDay — is_marked / mark_color / is_goal / note changed for one entry_date","cleared":"all three falsy = row delete"}'),
  (u, 'kind', 'cycle.digital',
     '{"required":["id","name","every","anchor"],"optional":["color"]}',
     '{"emitted_by":"cal","doc":"calapp_sukkiri","path":"cycles","item_key":"<skId>","note":"mirror of cycle.home; Calendar owns kind=digital"}')
  on conflict (user_id, ns, id) do update set schema = excluded.schema, meta = excluded.meta;

  insert into akatsuki_vocab (user_id, ns, id, schema, meta) values
  (u, 'enum', 'mark_color',   '{"values":["red","pink","teal","cyan","orange","purple","yellow"]}', '{"owner":"cal","was":"js/app.js:117 const MC","default":"red"}'),
  (u, 'enum', 'diary_mood',   '{"values":["good","bad","neutral"]}', '{"owner":"cal","note":"encoded as + / - / ~ inside content; the mood column is never written"}'),
  (u, 'enum', 'garbage_icon', '{"values":["flame","recycle","bottle","can","paper","trash","leaf","box","battery","glass"]}', '{"owner":"cal","was":"js/sukkiri.js SK_ICONS"}'),
  (u, 'enum', 'block_flag',   '{"values":["urg","any","away","hol"]}', '{"owner":"cal"}'),
  (u, 'enum', 'wf_item_kind', '{"values":["sub","note","inbox"]}', '{"owner":"wf","note":"read by cal; wf has not filed a card"}')
  on conflict (user_id, ns, id) do update set schema = excluded.schema, meta = excluded.meta;

  insert into akatsuki_apps (
    user_id, id, name, role, pattern, address_shape, clock_field, clock_trust,
    emits, accepts, deletes, private_fields, session, reach, payload_map, owned_paths, flags
  ) values (
    u, 'cal', 'Calendar', 'app', 'document',
    'calendar_app_entries.id uuid · natural key (user_id, entry_date) · calendar_app_sukkiri.user_id PK → payload.{away[],done{},overrides{},cycles[],garbage[]}',
    'entries/diary/birthdays/preferences: updated_at server-set by update_modified_column() · calendar_app_sukkiri.updated_at client-set in saveSukkiri',
    'mixed',
    '{day.mark,cycle.digital,away,done,overrides,trash.pickup}',
    '{cycle.home,trash.pickup}',
    'hard',
    '{calendar_app_diary.content,calendar_app_diary.mood,calendar_app_entries.note,calendar_app_preferences.theme_pref,localStorage.calapp_pending,localStorage.calapp_caldata,localStorage.calapp_print_opts,localStorage.calapp_task_style}',
    'jwt',
    ':5161 (python -m http.server) · PWA with sw.js · shared project wylxvmkcrexwfpjpbhyy · email+password + Google OAuth · guest mode sets UID=guest and no-ops all cloud calls',
    '{"date":"entry_date","marked":"is_marked","markColor":"mark_color","isGoal":"is_goal","note":"note","away":"payload.away","done":"payload.done","overrides":"payload.overrides","block":"payload.block"}',
    '{calendar_app_entries.*,calendar_app_diary.*,calendar_app_birthdays.*,calendar_app_preferences.*,calapp_sukkiri.away,calapp_sukkiri.done,calapp_sukkiri.overrides,calapp_sukkiri.block,calapp_sukkiri.show,calapp_sukkiri.wm,calapp_sukkiri.cycles[kind=digital]}',
    '{"SECURITY — schema_R003_rain_bday.sql is the latest file and drops RLS on all four calendar_app_* tables, with user_id TEXT DEFAULT ''default-user''. The anon key ships in a public bundle. Run part A of R004 and fix Calendar-side before wiring anything.",
      "guest mode (UID=''guest'') no-ops every cloud call — the adapter must not publish in guest mode or it writes another user''s namespace.",
      "saveSukkiri() has NO diff: every sukkiri-kind fires on any save. Same defect as Sukkiri''s pushCalCloud; the adapter hash-gates both sides.",
      "calendar_app_sukkiri is written whole-payload by BOTH apps — last writer wins. R003 + R004 shred it into owned akatsuki_state rows.",
      "Calendar writes weekly_focus_entries.payload.subtasks[].done/.when — a foreign write into WF''s document. WF has NOT filed a card, so this path has no declared owner. Flagged defect.",
      "deleting a cycle leaves its done{} and overrides{} keys orphaned in the payload forever — never pruned.",
      "?? calendar_app_sukkiri has no DDL in the repo — shape inferred from client calls; RLS unknown.",
      "?? no revision anywhere: dedupe key is user_id+entry_date+updated_at, which is not change-scoped."
    }'
  )
  on conflict (user_id, id) do update set
    name = excluded.name, pattern = excluded.pattern, address_shape = excluded.address_shape,
    clock_field = excluded.clock_field, clock_trust = excluded.clock_trust, emits = excluded.emits,
    accepts = excluded.accepts, deletes = excluded.deletes, private_fields = excluded.private_fields,
    session = excluded.session, reach = excluded.reach, payload_map = excluded.payload_map,
    owned_paths = excluded.owned_paths, flags = excluded.flags;

  -- Weekly Focus exists only as a table Calendar reads and writes. Register it
  -- as a stub so the defect route has a real counterparty and the hub shows the
  -- gap; its card replaces this.
  insert into akatsuki_apps (user_id, id, name, role, pattern, flags) values
  (u, 'wf', 'Weekly Focus', 'app', 'document',
   '{"stub — no card filed. Calendar reads weekly_focus_entries + weekly_focus_inventory and WRITES subtasks[].done/.when directly. Send card-request-prompt.md to this app next."}')
  on conflict (user_id, id) do nothing;

  -- Routes.  R003 left cal→sukkiri as 'proposed' because Calendar had no card;
  -- it now has one, so those four become real stream legs (not views — away,
  -- done and overrides all change and must merge).
  insert into akatsuki_routes (user_id, from_app, to_app, kind, access, state, note) values
  (u, 'cal', 'sukkiri', 'away',          'stream', 'defect', 'today: whole-payload upsert of calendar_app_sukkiri. Target: hub.put(calapp_sukkiri, away, <date>)'),
  (u, 'cal', 'sukkiri', 'done',          'stream', 'defect', 'key <cycleId>|<date>. Target: hub.put(calapp_sukkiri, done, <key>)'),
  (u, 'cal', 'sukkiri', 'overrides',     'stream', 'defect', 'key <cycleId>|<date> → new date or skip'),
  (u, 'cal', 'sukkiri', 'cycle.digital', 'stream', 'defect', 'Calendar owns kind=digital; mirror of R003 cycle.home'),
  (u, 'cal', 'sukkiri', 'trash.pickup',  'stream', 'defect', 'contested: both apps write garbage[]. Calendar writes only when Sukkiri has no rules of its own'),
  (u, 'cal', 'wf',      'task.done',     'direct', 'defect', 'Calendar writes weekly_focus_entries.payload.subtasks[].done/.when — foreign write into WF''s doc, no owner declared. Blocked on WF''s card.'),
  (u, 'wf',  'cal',     'task.dated',    'direct', 'defect', 'Calendar reads weekly_focus_entries + inventory directly. Re-home to a view once WF files.')
  on conflict (user_id, from_app, to_app, kind) do update set
    access = excluded.access, state = excluded.state, note = excluded.note;

  -- R003's placeholder view rows are superseded by the stream legs above.
  delete from akatsuki_routes
   where user_id = u and from_app = 'cal' and to_app = 'sukkiri' and access = 'view';

  -- Calendar's side of the shared doc.  R003 seeded these owned by 'cal' with
  -- null values; nothing to change — this is the assertion that it stayed true.
  update akatsuki_state set owner_app = 'cal'
   where user_id = u and doc = 'calapp_sukkiri'
     and path in ('away','done','overrides','block','show','wm');

end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C · Verify
-- ─────────────────────────────────────────────────────────────────────────────
-- select id, pattern, clock_trust, cardinality(flags) open from akatsuki_apps order by id;
-- select from_app, to_app, kind, access, state from akatsuki_routes order by 1,2,3;
-- select path, item_key, owner_app from akatsuki_state where doc = 'calapp_sukkiri';
