-- ============================================================================
-- Akatsuki R020 — Japanese Study (jlpt) files its card · the first DUAL-SESSION app.
-- Run after R019.  Idempotent.  Source: the app's reply, 2026-09-26 (cards/jlpt.md).
--
-- The app lives in ANOTHER project (ulgrfumbwjovbjzjiems).  It joins the hub with a
-- second client signed in to wylxvmkcrexwfpjpbhyy as the same Google account.
-- Its own data stays where it is.  Standard v3.3.
--
-- Found on the card, fix first:
--   · rmSession.js POSTs roadmap_complete_session with the hub ANON KEY and no user
--     JWT.  If that works today, the function is callable by anon — anyone with the
--     public key can write Roadmap's session ledger.  Part A measures it.
--
--   A. Trust test on roadmap_complete_session (reads only).  Paste results back.
--   B. The card, vocab, routes, credentials.
--   C. Close the anon hole.  Run ONLY after the app ships step 1 (JWT on the call).
-- ============================================================================

-- ═══ A · trust test ══════════════════════════════════════════════════════════
select p.proname, p.prosecdef, p.proconfig, pg_get_function_arguments(p.oid) args
  from pg_proc p where p.proname = 'roadmap_complete_session';
select grantee, privilege_type from information_schema.routine_privileges
 where routine_name = 'roadmap_complete_session' order by 1;
select pg_get_functiondef('roadmap_complete_session'::regproc);
-- How the ledger is keyed (idempotent on task+day?) and whether user_id comes from auth.uid():
select column_name, data_type from information_schema.columns
 where table_name in (select unnest(array['roadmap_sessions','roadmap_session_days','roadmap_study_sessions'])) order by table_name, ordinal_position;

-- ═══ B · card ════════════════════════════════════════════════════════════════
do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
begin
  insert into akatsuki_apps (
    user_id, id, name, role, pattern, address_shape, clock_field, clock_trust,
    emits, accepts, deletes, private_fields, session, reach, payload_map, owned_paths, flags
  ) values (
    u, 'jlpt', 'Japanese Study', 'app', 'stream',
    'session = {task_id uuid (Roadmap''s), day_key YYYY-MM-DD (4 AM reset)} · no local row · daily = japanese_daily_activity(user_id, activity_date)',
    'none on sessions · japanese_daily_activity.updated_at client-set (activity.js:14) · japanese_user_markings.updated_at/marked_at client-set, move on every marking change',
    'client',
    '{session.completed}', '{}', 'hard',
    '{japanese_scripts.content,japanese_scripts.question,japanese_unified_words.hint,japanese_story_alerts.*,japanese_word_alerts.*,japanese_anime_words.*,japanese_user_markings.*,japanese_user_reviews.*,admin uuid,both anon keys}',
    'jwt',
    'DUAL — own project ulgrfumbwjovbjzjiems (window.sb, Google OAuth, default storageKey) + hub client storageKey akatsuki_hub_auth signed in via hub-login.html · :5180 (run-jlpt-local.bat) / :8000 · celeritas7.github.io/Japanese_study_app_advanced · 5 pages, 5 createClient calls · entry js/app.js · hub scripts js/ · no service worker · window.app',
    '{"session.completed":{"task_id":"rm-handshake.task","day_key":"rm-handshake.day | rmDayKey()","duration":"(now-t0)/60000 min 1","mode":"studySubTab | srs","words":"studyWords.length | srsWords.length","level":"selectedLevel","correct":"srsAnswers.correct count (srs only)","test_type":"srsConfig.testType (srs only)","source":"japanese-study-app-advanced"}}',
    '{japanese_daily_activity.*,japanese_user_markings.*,japanese_group_study_log.*}',
    '{
      "R020 — first dual-session app: own project + hub, same Google account. Hub client is NEVER window.sb; detectSessionInUrl false on the hub client, sign-in only through hub-login.html.",
      "R020 DEFECT — rmSession.js calls roadmap_complete_session in the hub project with the anon key and no JWT (rmSession.js:15-16, 112-122). Step 1: same call through the hub client (user JWT). Then part C revokes anon.",
      "R020 — session.completed today = RPC (Roadmap''s own function). It becomes a hub stream once Roadmap consumes; until then the row is published AND the RPC is called. Roadmap''s consumer must be idempotent on (task_id, day_key) — the RPC already is (re-send reuses the same pair).",
      "guest mode sets user.id d469efb7-… with no session — the hub is skipped entirely in guest mode.",
      "?? testType enum conflict: code says kanji|reading|writing (config.js TEST_TYPES), Version_9 SQL comment says kanji_write|reading|meaning. Code wins until the app says otherwise.",
      "?? japanese_daily_activity / japanese_group_study_log DDL and RLS live in sql/setup.sql, not in the repo. Trust unverified for those two.",
      "?? content tables have open UPDATE USING (true) — any signed-in user can edit shared content. Not a hub concern; noted.",
      "streak.day → rm/wf not minted: no consumer has asked. Accepts: nothing declared — the app asked which hub items should land where; that is the user''s call, not the card''s."
    }'
  )
  on conflict (user_id, id) do update set
    name = excluded.name, role = excluded.role, pattern = excluded.pattern,
    address_shape = excluded.address_shape, clock_field = excluded.clock_field, clock_trust = excluded.clock_trust,
    emits = excluded.emits, accepts = excluded.accepts, deletes = excluded.deletes,
    private_fields = excluded.private_fields, session = excluded.session, reach = excluded.reach,
    payload_map = excluded.payload_map, owned_paths = excluded.owned_paths, flags = excluded.flags,
    updated_at = now();

  -- Roadmap accepts it (it already does, by RPC).
  update akatsuki_apps set accepts = array(select distinct x from unnest(accepts || '{session.completed}') x), updated_at = now()
   where user_id = u and id = 'rm';

  insert into akatsuki_vocab (user_id, ns, id, schema, meta) values
  (u, 'kind', 'session.completed',
     '{"required":["task_id","day_key","duration","mode"],"optional":["words","level","correct","test_type","source"]}',
     '{"emitted_by":"jlpt","accepted_by":"rm","on":"finishStudy() results screen or last SRS answer — only when launched with rm_task",
       "src_addr":"{task_id, day_key}","idempotency_key":"jlpt:session:<task_id>:<day_key> — one per task per day; a second session the same day is the same key (skipped), as the RPC behaves today",
       "types":{"task_id":"uuid","day_key":"YYYY-MM-DD","duration":"int minutes ≥1","mode":"enum jlpt_mode","level":"enum jlpt_level | null","test_type":"enum jlpt_test_type"},
       "today":"Roadmap RPC roadmap_complete_session(p_task_id,p_source,p_day_key,p_duration,p_feedback,p_verification)"}'),
  (u, 'enum', 'jlpt_mode',      '{"values":["goi","kanji","self_study","srs"]}', '{"owner":"jlpt","source":"app.js:1242, :1520"}'),
  (u, 'enum', 'jlpt_level',     '{"values":["N1","N2","N3","ALL"]}', '{"owner":"jlpt","source":"config.js LEVEL_COLORS"}'),
  (u, 'enum', 'jlpt_test_type', '{"values":["kanji","reading","writing"]}', '{"owner":"jlpt","source":"config.js TEST_TYPES","note":"?? Version_9 comment disagrees (kanji_write|reading|meaning)"}'),
  (u, 'enum', 'jlpt_marking',   '{"values":[0,1,2,3,4,5,6],"labels":["Not Marked","Monthly Review","Can''t Converse","Can''t Write","Can''t Use","Don''t Know","Deep Study"]}', '{"owner":"jlpt","source":"config.js MARKING_CATEGORIES","note":"private today; listed so no consumer invents a copy"}')
  on conflict (user_id, ns, id) do update set schema = excluded.schema, meta = excluded.meta;

  insert into akatsuki_routes (user_id, from_app, to_app, kind, access, state, note) values
  (u, 'jlpt', 'rm', 'session.completed', 'direct', 'defect',
     'R020 — anon-key RPC roadmap_complete_session, no JWT. Step 1: same RPC via the hub client (JWT) + publish. → half when Roadmap consumes the stream; live when the RPC call is deleted.'),
  (u, 'rm', 'jlpt', 'task.launch', 'view', 'live',
     'R020 — URL handshake ?rm_task=<uuid>&rm_day=<YYYY-MM-DD>&rm_ret=<url>, held in sessionStorage rm-handshake. Ids only, nothing stored, no hub row. Fine as is.')
  on conflict (user_id, from_app, to_app, kind) do update set access = excluded.access, state = excluded.state, note = excluded.note;

  update akatsuki_credentials set consumers = array(select distinct x from unnest(consumers || '{jlpt}') x)
   where user_id = u and name = 'supabase_anon';
  insert into akatsuki_credentials (user_id, name, scope, location, consumers, rotated_at) values
  (u, 'jlpt_own_anon', 'Other project ulgrfumbwjovbjzjiems anon key (js/config.js:5 + 4 page copies). Not the hub''s; listed so the dual session is countable.', 'client_bundle', '{jlpt}', null)
  on conflict (user_id, name) do update set scope = excluded.scope;
end $$;

-- ═══ C · close the anon hole — AFTER the app ships step 1 ════════════════════
-- Part A (Sep 26): SECURITY DEFINER, search_path public, no auth check, never sets
-- user_id, upserts on (task_id, day_key) across ALL users.  So with the public key
-- and a task uuid, anyone can write or overwrite a session, and RLS never runs.
--
-- C0 · read-only, run now: what anon calls have left behind.
select count(*) filter (where user_id is null) null_owner, count(*) total from roadmap_study_sessions;
select column_default, is_nullable from information_schema.columns
 where table_name = 'roadmap_study_sessions' and column_name = 'user_id';
select column_name from information_schema.columns
 where table_name = 'roadmap_tasks' and column_name = 'user_id';   -- the owner check below needs it
--
-- C1 · RAN 2026-09-26 (as sql/akatsuki_card_jlpt_R020_C1.sql), ahead of the app's step 1.  Same signature,
-- same return, same upsert — plus: signed-in only, own tasks only, user_id set.
-- Rows with user_id null are claimed by the task's owner on their next write.
-- create or replace function public.roadmap_complete_session(p_task_id uuid, p_source text,
--   p_day_key text default null, p_duration integer default null, p_feedback jsonb default '{}'::jsonb,
--   p_verification text default 'app')
-- returns uuid language plpgsql security definer set search_path = public, pg_temp as $f$
-- declare
--   v_uid uuid := auth.uid();
--   v_day text := coalesce(p_day_key, to_char(now() - interval '4 hours', 'YYYY-MM-DD'));
--   v_id uuid;
-- begin
--   if v_uid is null then raise exception using errcode = '42501', message = 'roadmap_complete_session: sign-in required'; end if;
--   if p_verification not in ('app','api','manual') then raise exception 'bad verification: %', p_verification; end if;
--   if not exists (select 1 from roadmap_tasks t where t.id = p_task_id and t.user_id = v_uid) then
--     raise exception using errcode = '42501', message = 'roadmap_complete_session: not your task';
--   end if;
--   insert into roadmap_study_sessions (user_id, task_id, day_key, source, completed_at, duration_min, feedback, verification)
--   values (v_uid, p_task_id, v_day, p_source, now(), p_duration, p_feedback, p_verification)
--   on conflict (task_id, day_key) do update
--     set user_id      = v_uid,
--         completed_at = now(),
--         duration_min = coalesce(excluded.duration_min, roadmap_study_sessions.duration_min),
--         feedback     = roadmap_study_sessions.feedback || excluded.feedback,
--         source       = excluded.source,
--         verification = excluded.verification
--     where roadmap_study_sessions.user_id = v_uid or roadmap_study_sessions.user_id is null
--   returning id into v_id;
--   return v_id;
-- end $f$;
-- revoke execute on function public.roadmap_complete_session(uuid, text, text, integer, jsonb, text) from public, anon;
-- grant  execute on function public.roadmap_complete_session(uuid, text, text, integer, jsonb, text) to authenticated;
--
-- Check after C1 — anon must now fail, a signed-in own-task call must succeed:
-- select grantee from information_schema.routine_privileges where routine_name = 'roadmap_complete_session';

-- ─────────────────────────────────────────────────────────────────────────────
-- Verify
-- ─────────────────────────────────────────────────────────────────────────────
-- select * from akatsuki_contract where from_app = 'jlpt';
-- select from_app, to_app, kind, access, state from akatsuki_routes where 'jlpt' in (from_app, to_app);
