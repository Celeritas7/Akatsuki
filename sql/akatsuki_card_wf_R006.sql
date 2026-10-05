-- ============================================================================
-- Akatsuki R006 — Weekly Focus files.  Run after R005.  Idempotent.
--
-- Card source: WF's own reply, 2026-09-22.  Port 5070 (?? 5073 / 5170).
--
-- READ PART A.  This card is the most complete one filed so far and it breaks
-- three things that were treated as settled:
--
--  1 · THE CLOCK RULE IN CLAUDE.md IS CONTRADICTED.
--      Founding rules say: "WF's subtasks[].u ... do not move on flag changes
--      — proven Sep 21."  R001's card flag says the same: "del / lat flip
--      without bumping u — park and delete are invisible incrementally."
--      The card says the opposite: done/del/lat/urg/tag "also bump
--      subtasks[].u".  One of these is wrong and the answer decides whether
--      every incremental WF→RM pull has been silently dropping parks and
--      deletes for a year.  Part A tests it against live data.
--
--  2 · A DECLARED SOLE-OWNER PATH IS ALREADY BEING WRITTEN BY CALENDAR.
--      WF claims sole writer on subtasks[].when.  Calendar's card (R004)
--      declares it writes subtasks[].done AND .when.  WF's contended list
--      names Roadmap and the CC bridge — not Calendar.  Neither app knows the
--      other is there.  That is exactly the "owner declared per shared path
--      before the first write" rule failing in production.
--
--  3 · PLAINTEXT CREDENTIALS AT REST IN THE SHARED PROJECT.
--      __board.payload.meta.cvault[] holds bank / card / login / password
--      records as plaintext jsonb, guarded by RLS plus a SHA-256 PIN kept in
--      localStorage — a client-side lock on server-side data.  RLS is correct
--      here, so this is not an exposure, but it is a secret living outside
--      Vault in a project whose anon key ships in five bundles.
--
-- WF passes the TRUST question on its own two tables: RLS on, per-command
-- policies TO authenticated with auth.uid() = user_id, anon revoked.  Better
-- than Calendar was.  The open TRUST risk is the command_centre_* tables it
-- also writes — the bridge comments claim USING(true) and nobody has checked.
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A · Two diagnostics.  Both write NOTHING.  Read both before part B.
-- ─────────────────────────────────────────────────────────────────────────────

-- A1 · The clock question.  For every tombstoned or parked subtask, how far
-- behind the row's own updated_at is that subtask's u?
--
-- If u_lag is near zero            → the card is right, u bumps on flag flips,
--                                    and R001's flag + CLAUDE.md are stale.
-- If u_lag is large and positive   → u did NOT move when del/lat was set.
--                                    CLAUDE.md is right, the card is aspirational,
--                                    and (board_id,item_key,sub_id,u) is NOT a
--                                    sufficient idempotency key for deletes.
select e.item_key,
       s->>'id'                                             as sub_id,
       coalesce((s->>'del')::boolean, false)                as del,
       coalesce((s->>'lat')::boolean, false)                as parked,
       to_timestamp(((s->>'u')::bigint) / 1000.0)           as sub_u,
       e.updated_at,
       e.updated_at - to_timestamp(((s->>'u')::bigint) / 1000.0) as u_lag
  from weekly_focus_entries e
  cross join lateral jsonb_array_elements(coalesce(e.payload->'subtasks', '[]'::jsonb)) s
 where coalesce((s->>'del')::boolean, false)
    or coalesce((s->>'lat')::boolean, false)
 order by u_lag desc nulls last
 limit 25;

-- A2 · The TRUST question for the three Command Centre tables WF writes but
-- whose DDL is in neither repo.  Expect rls_enabled = true and
-- suspect_policies = 0.  Anything else and WF is writing into an open table.
select c.relname                                as table_name,
       c.relrowsecurity                         as rls_enabled,
       (select count(*) from pg_policies p
         where p.schemaname = 'public' and p.tablename = c.relname) as policies,
       (select count(*) from pg_policies p
         where p.schemaname = 'public' and p.tablename = c.relname
           and (p.roles::text[] <> array['authenticated']
                or p.qual is null or p.qual = 'true'))             as suspect_policies,
       (select data_type from information_schema.columns
         where table_name = c.relname and column_name = 'user_id')  as user_id_type
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relkind = 'r'
   and c.relname like 'command_centre_%'
 order by 1;

-- ─────────────────────────────────────────────────────────────────────────────
-- B · The hub learns Weekly Focus.
-- ─────────────────────────────────────────────────────────────────────────────
do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
begin

  -- B1 · Kinds.  WF names four outbound task events; the hub keeps ONE kind and
  -- records the four as triggers (edges flexible, core rigid).  R001's routes
  -- already ride task.upsert and stay valid.
  insert into akatsuki_vocab (user_id, ns, id, schema, meta) values
  (u, 'kind', 'task.upsert',
     '{"required":["title","done"],"optional":["ctx","due","when","deleted","parked","parkedAt","rev","sub_id","board_id","item_key"]}',
     '{"emitted_by":"wf,rm","wf_event_names":["task.upserted (t or ctx changed)","task.completed (done flip)","task.deleted (del false→true)","task.parked (lat false→true)"],"addr":"(board_id,item_key,subtasks[].id)","rev":"subtasks[].u — client ms epoch, see R006 part A1"}'),
  (u, 'kind', 'focus.changed',
     '{"required":["board","the_five"],"optional":["active"]}',
     '{"emitted_by":"wf","to":"cc","on":"__board.payload.targetOrder array change","note":"the_five[] max 5, rank = array index; target is command_centre_brain_settings.value where key=''wf_focus''"}'),
  (u, 'kind', 'target.cleared',
     '{"required":["board","item_key","done"]}',
     '{"emitted_by":"wf","to":"cc","on":"item payload.targetDone flip"}'),
  (u, 'kind', 'item.active.changed',
     '{"required":["board","item_key","active"]}',
     '{"emitted_by":"wf","to":"cc","on":"item payload.active flip (This Week on/off)"}'),
  (u, 'kind', 'inventory.changed',
     '{"required":["board","lists"],"optional":["updated_at"]}',
     '{"emitted_by":"wf","to":"rm","on":"add/rename/regroup/delete in weekly_focus_inventory.apps|study|office","note":"supplies display names for item_keys"}'),
  (u, 'kind', 'team.switched',
     '{"required":["active_team"],"optional":["base_team"]}',
     '{"emitted_by":"cc","to":"wf","maps_to":"weekly_focus_entries.payload.ccActive = (squadFor(item_key) = active_team)","note":"CC bridge runs on a 60s timer, independent of user action"}')
  on conflict (user_id, ns, id) do update set schema = excluded.schema, meta = excluded.meta;

  -- B2 · Enums.  WF is the owner of its own vocabulary; contexts already exist
  -- as ns=context from R001 and are NOT duplicated here.
  insert into akatsuki_vocab (user_id, ns, id, schema, meta) values
  (u, 'enum', 'wf_item_prefix', '{"values":["app","study","office"]}',
     '{"owner":"wf","was":"kindOf() in js/weekly-focus-app.js","synthetic_rows":["__board","__timeline","__inbox"]}'),
  (u, 'enum', 'wf_priority',    '{"values":["H","M","L"]}', '{"owner":"wf","was":"PRI_RANK, payload.pri"}'),
  (u, 'enum', 'wf_sub_mode',    '{"values":["b","p","o"]}', '{"owner":"wf","was":"subtasks[].md, subModeOk()","default":"b","note":"b=both p=personal o=office"}'),
  (u, 'enum', 'cc_squad',       '{"values":["coding","language_study","work"]}', '{"owner":"cc","was":"PREFIX_TO_SQUAD in js/wf-cc-bridge-v2.js","derived_from":"item_key prefix"}'),
  (u, 'enum', 'wf_app_cat',     '{"values":["General Purpose","Mechanical","Language Study","Other"]}', '{"owner":"wf","was":"APP_CATS","lives_in":"inventory.apps[].group"}'),
  (u, 'enum', 'wf_gen_tag',     '{"values":["Claude AI","Claude Design","Cowork"]}', '{"owner":"wf","was":"GEN_TAGS","lives_in":"inventory.apps[].gen"}'),
  (u, 'enum', 'rm_task_kind',   '{"values":["task","group"]}', '{"owner":"rm","was":"roadmap_tasks.kind check"}'),
  (u, 'enum', 'link_source',    '{"values":["wf","rm"]}', '{"owner":"rm","was":"task_links.source check","note":"superseded by akatsuki_links.source once WF v65 lands"}')
  on conflict (user_id, ns, id) do update set schema = excluded.schema, meta = excluded.meta;

  -- Calendar guessed WF's item vocabulary in R004 and guessed wrong.  Correct it
  -- rather than delete it, so the guess is visible.
  update akatsuki_vocab
     set schema = '{"values":["app","study","office"]}',
         meta = '{"owner":"wf","superseded":"R004 minted this as {sub,note,inbox} from Calendar''s inference while WF had no card. WF''s real item prefixes are app/study/office; sub/note/inbox were never WF vocabulary. Kept as an alias row — cal''s adapter must read wf_item_prefix."}'
   where user_id = u and ns = 'enum' and id = 'wf_item_kind';

  -- B3 · The card.  Replaces R001's inferred row wholesale.
  insert into akatsuki_apps (
    user_id, id, name, role, pattern, address_shape, clock_field, clock_trust,
    emits, accepts, deletes, private_fields, session, reach, payload_map, owned_paths, flags
  ) values (
    u, 'wf', 'Weekly Focus', 'app', 'stream',
    'weekly_focus_entries PK (user_id, board_id, item_key) · weekly_focus_inventory PK (user_id, board_id) · a TASK IS NOT A ROW: element of payload.subtasks[] addressed by (board_id, item_key, subtasks[].id) · board_id in use: my_week · item_key literals app:<uid|Name> / study:<DOM>/<path>/<Leaf> / office:<uid> + synthetic __board, __timeline, __inbox',
    'row: updated_at client-set in cloudPushEntry/cloudPushInv/cloudPushBoard, NO trigger · task: payload.subtasks[].u client ms epoch · board: __board.payload.u',
    'client',
    '{task.upsert,note,focus.changed,target.cleared,item.active.changed,inventory.changed}',
    '{task.upsert,team.switched}',
    'mixed',
    '{__board.payload.meta.cvault,__board.payload.meta.cchats,__board.payload.meta.medit,__board.payload.meta.wish,__board.payload.meta.wishFlow,__board.payload.meta.places,__board.payload.meta.links,entries.payload.notes,subtasks[].rv,subtasks[].loc,inventory.apps[].links,localStorage.wf_vault_pin}',
    'jwt',
    ':5070 (run-weekly-focus.bat, python http.server) · shared project wylxvmkcrexwfpjpbhyy · Supabase Auth email 6-digit OTP + Google OAuth · session storageKey wf2_sb_auth · app-enforced 30-day cap via localStorage.wf_login_at · no server, no edge function',
    '{"title":"payload.subtasks[].t","done":"payload.subtasks[].done","ctx":"payload.subtasks[].ctx","rev":"payload.subtasks[].u","deleted":"payload.subtasks[].del","parked":"payload.subtasks[].lat","parkedAt":"payload.subtasks[].latAt","when":"payload.subtasks[].when","board_id":"board_id","item_key":"item_key","sub_id":"payload.subtasks[].id"}',
    '{weekly_focus_entries.payload.subtasks[].md,weekly_focus_entries.payload.subtasks[].urg,weekly_focus_entries.payload.subtasks[].dl,weekly_focus_entries.payload.subtasks[].loc,weekly_focus_entries.payload.subtasks[].tag,weekly_focus_entries.payload.subtasks[].lat,weekly_focus_entries.payload.subtasks[].latAt,weekly_focus_entries.payload.subtasks[].rv,weekly_focus_entries.payload.subtasks[].when,weekly_focus_entries.payload.active,weekly_focus_entries.payload.pri,weekly_focus_entries.payload.rank,weekly_focus_entries.payload.ord,weekly_focus_entries.payload.spord,weekly_focus_entries.payload.arch,weekly_focus_entries.payload.upd,weekly_focus_entries.payload.objective,weekly_focus_entries.payload.notes,weekly_focus_entries.payload.targetDone,weekly_focus_entries.payload.holdUntil,weekly_focus_entries.payload.holdStar,weekly_focus_entries.payload.holdRank,__board.payload.targetOrder,__board.payload.meta.*,__board.payload.u,weekly_focus_inventory.apps,weekly_focus_inventory.study,weekly_focus_inventory.office}',
    '{"CONTESTED OWNERSHIP — subtasks[].when: WF declares itself SOLE writer, Calendar''s card (R004) declares it writes subtasks[].done AND .when. WF''s contended list names only Roadmap and the CC bridge. Two apps claim one path and neither knows. Declare an owner before either adapter ships.",
      "CONTESTED OWNERSHIP — subtasks[].done has THREE writers: WF (own toggles), Roadmap (wfLink.ts whole-row upsert), Calendar (foreign write into the payload). Last writer wins with no revision.",
      "CLOCK CONTRADICTION — card says done/del/lat/urg/tag bump subtasks[].u; CLAUDE.md and R001''s flag say u does NOT move on flag changes (proven Sep 21). Run R006 part A1. If u lags, every incremental pull has been dropping parks and deletes.",
      "SECRET AT REST — __board.payload.meta.cvault[] stores bank/card/login/password records as PLAINTEXT jsonb in the shared project. Guarded by RLS (correct) plus localStorage.wf_vault_pin, a SHA-256 client-side PIN that protects nothing server-side. Belongs in Vault, not in a payload.",
      "MERGE HAZARD — no per-row revision integer. Two edits in the same millisecond collapse, and mergeSubs resolves equal-u collisions by FIELD-WISE OR (truthy wins). Un-completing a task can therefore never win a collision: done=true always beats done=false.",
      "NO-OP REPUBLISH — the convergence path (cloudPullEntries → subsDiffer → cloudPushEntry) re-pushes and stamps a fresh updated_at with nothing changed. Violates ''publish on real change only''; the adapter must hash-gate or two apps ping-pong.",
      "KEYSTROKE WRITES — payload.objective and payload.notes are written on every keystroke with no debounce. Not publishable as-is; WF''s own card says so.",
      "LOCAL ENUM COPY — WF hardcodes the 7 contexts as var CTX and never reads roadmap_contexts_map. Founding rules require shared enums be read from vocab, never a local copy. Re-home to akatsuki_vocab ns=context.",
      "CHILD DELETE LEAVES NO TOMBSTONE — item delete is a hard row delete, so every subtask under it vanishes with no del flag. Roadmap only sees the triple disappear. Per founding rules the hub must set orphaned_at, never cascade.",
      "PATTERN IS SPLIT — tasks are addressable items (stream), but __board.payload.meta.* and inventory are one shared document written whole. Registered as stream; the document half needs akatsuki_state shredding like calapp_sukkiri.",
      "?? command_centre_* tables (active_team, brain_settings, alerts) are written by WF but their DDL is in neither repo, and bridge comments claim permissive USING(true) policies. Run R006 part A2.",
      "?? port disagreement: run-weekly-focus.bat serves 5070, its own fallback message prints 5073, the Attempt_29/ copy serves 5170."
    }'
  )
  on conflict (user_id, id) do update set
    name = excluded.name, pattern = excluded.pattern, address_shape = excluded.address_shape,
    clock_field = excluded.clock_field, clock_trust = excluded.clock_trust, emits = excluded.emits,
    accepts = excluded.accepts, deletes = excluded.deletes, private_fields = excluded.private_fields,
    session = excluded.session, reach = excluded.reach, payload_map = excluded.payload_map,
    owned_paths = excluded.owned_paths, flags = excluded.flags;

  -- B4 · Command Centre is now a named counterparty on four legs.  Stub it so
  -- the routes have a real target; its own card replaces this.
  insert into akatsuki_apps (user_id, id, name, role, pattern, address_shape, emits, accepts, session, flags) values
  (u, 'cc', 'Command Centre', 'app', 'document',
   'command_centre_active_team id=''singleton'' · command_centre_brain_settings (key, value jsonb) keys wf_focus + wf_cc_bridge_map · command_centre_alerts (id)',
   '{team.switched}', '{focus.changed,target.cleared,item.active.changed}', 'unknown',
   '{"stub — no card filed. Known only through WF''s wf-cc-bridge-v2.js, which ships INSIDE WF and writes CC''s tables directly on a 60s timer.",
     "?? DDL absent from both repos; bridge comments claim permissive USING(true) policies. R006 part A2 is the test.",
     "send card-request-prompt.md — this is the last unregistered counterparty."}')
  on conflict (user_id, id) do update set
    address_shape = excluded.address_shape, emits = excluded.emits, accepts = excluded.accepts;

  -- B5 · Routes.  Every leg WF's card describes, stated at its real quality.
  insert into akatsuki_routes (user_id, from_app, to_app, kind, access, state, note) values
  (u, 'wf', 'rm', 'task.upsert',         'stream', 'half',     'WF → RM live for study prefix only. Four WF event names (upserted/completed/deleted/parked) collapse onto this kind. Dedupe (board_id,item_key,sub_id,u) — sound ONLY if part A1 shows no lag.'),
  (u, 'rm', 'wf', 'task.upsert',         'direct', 'defect',   'Roadmap''s wfLink.ts flush upserts WHOLE weekly_focus_entries rows — a foreign writer on WF''s contended paths. Re-home to akatsuki_requests; WF accepts read-modify-write patching t/done/ctx/u only.'),
  (u, 'wf', 'rm', 'inventory.changed',   'stream', 'proposed', 'supplies display names for item_keys. Blocked: RM has not declared it accepts inventory.changed.'),
  (u, 'wf', 'cc', 'focus.changed',       'direct', 'defect',   'WF''s own bridge writes command_centre_brain_settings key=wf_focus. Re-home to stream once CC files.'),
  (u, 'wf', 'cc', 'target.cleared',      'direct', 'defect',   'same bridge, same setting row.'),
  (u, 'wf', 'cc', 'item.active.changed', 'direct', 'defect',   'same bridge, same setting row.'),
  (u, 'cc', 'wf', 'team.switched',       'direct', 'defect',   'bridge step 4 writes payload.ccActive on every mapped item row, on a 60s timer with no user action. Bumps updated_at on rows nobody touched.'),
  (u, 'rm', 'wf', 'context.vocab',       'view',   'proposed', 'roadmap_contexts_map → read-only reference data, zero conflict. WF must drop its hardcoded CTX copy and read this.')
  on conflict (user_id, from_app, to_app, kind) do update set
    access = excluded.access, state = excluded.state, note = excluded.note;

  -- R001 recorded wf→cal as a defect on Calendar's side of the read.  WF's card
  -- confirms the direction and R004 named the reverse write; restate both now
  -- that the counterparty is real rather than a stub.
  update akatsuki_routes
     set note = 'Calendar reads weekly_focus_entries + inventory directly. WF''s card confirms no server and no view. Re-home to a view (reference read, no conflict).'
   where user_id = u and from_app = 'wf' and to_app = 'cal' and kind = 'task.upsert';

  update akatsuki_routes
     set note = 'Calendar writes subtasks[].done/.when into WF''s payload. WF''s card declares itself SOLE owner of .when and does not list Calendar as a contender. Owner must be declared before either adapter ships — see wf flags.'
   where user_id = u and from_app = 'cal' and to_app = 'wf' and kind = 'task.done';

  -- The vault is a secret living outside Vault.  Name it so it is countable.
  insert into akatsuki_credentials (user_id, name, scope, location, consumers, rotated_at) values
  (u, 'wf_vault_records', 'Bank/card/login/password records stored as PLAINTEXT jsonb in weekly_focus_entries.__board.payload.meta.cvault[]. RLS-gated, but not encrypted and not in Vault. Client lock is localStorage.wf_vault_pin (SHA-256 of a 6-digit PIN) which has no server-side effect.', 'client_bundle', '{wf}', null)
  on conflict (user_id, name) do update set scope = excluded.scope, location = excluded.location;

end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C · Verify
-- ─────────────────────────────────────────────────────────────────────────────
-- select id, pattern, clock_trust, session, cardinality(flags) open from akatsuki_apps order by id;
-- select unnest(flags) from akatsuki_apps where id = 'wf';
-- select from_app, to_app, kind, access, state from akatsuki_routes order by 1,2,3;
-- select count(*) filter (where access = 'direct') as defect_direct_legs from akatsuki_routes;
--
-- Every app now holds a card except Command Centre, which exists only as a
-- bridge file living inside Weekly Focus.  Two things outrank writing any
-- adapter: part A1 (is the task clock real?) and the subtasks[].when owner.
