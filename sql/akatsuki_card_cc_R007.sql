-- ============================================================================
-- Akatsuki R007 — the first real security finding, and Command Centre's stub
-- gets teeth.  Run after R006.  Idempotent.
--
-- Sequence of events, 2026-09-22, recorded because the hub was wrong twice and
-- the wrongness is the useful part:
--
--   R004 flagged Calendar as a data-exposure risk on a reading of its schema
--   files.  R005 proved that wrong: Calendar's RLS was never off, its defect
--   was a TEXT tenant column that could not match auth.uid().  Repaired.
--
--   R006 part A2 then tested a ?? nobody had followed up — the command_centre_*
--   tables that Weekly Focus writes but whose DDL is in neither repo.  Result:
--
--     · FIVE tables, not three.  command_centre_blockers and
--       command_centre_gps_locations were not even known to be in scope.
--     · NO user_id column on any of them.  RLS was ON, which looked safe in a
--       summary, but a policy cannot scope rows by an owner that does not
--       exist — so the single policy on each table was open by construction.
--     · anon held DELETE, INSERT, SELECT, UPDATE and TRUNCATE on all five.
--
--   The anon key is DESIGNED to be public and ships in five client bundles.
--   So for the lifetime of those tables, anyone holding it could read, rewrite
--   or truncate the Command Centre — including command_centre_gps_locations,
--   which is location history.
--
--   REPAIRED 2026-09-22 (CC-side DDL, applied by hand):  user_id uuid added to
--   all five, backfilled to the owner uuid, set not null + default auth.uid();
--   every pre-existing policy dropped by discovered name; own_rows created FOR
--   ALL TO authenticated using/with check (user_id = auth.uid()); anon revoked;
--   authenticated granted select/insert/update/delete.
--
-- What cannot be repaired: the exposure window is history.  Any row that was
-- read while the grant stood was read.  GPS history is the one worth treating
-- as compromised rather than merely fixed.
--
-- Lesson for the hub, worth more than the fix: 'rls_enabled = true' is not an
-- answer to the TRUST question.  A table with RLS on, one policy, and no tenant
-- column is open.  R006's part A2 asks for suspect_policies and user_id_type
-- precisely because the boolean alone lied.  Every future card is tested that
-- way before an adapter is written.
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A · Verify the repair.  Writes nothing.
--     Expect on all five: rls_enabled true · policies 1 · suspect 0 · uuid
--     and NO anon row in the grants result.
-- ─────────────────────────────────────────────────────────────────────────────
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
 where n.nspname = 'public' and c.relkind = 'r' and c.relname like 'command_centre_%'
 order by 1;

select table_name, grantee, string_agg(privilege_type, ',' order by privilege_type) privs
  from information_schema.role_table_grants
 where table_schema = 'public' and table_name like 'command_centre_%'
   and grantee in ('anon','authenticated')
 group by 1, 2 order by 1, 2;

-- ─────────────────────────────────────────────────────────────────────────────
-- B · The hub records it.
-- ─────────────────────────────────────────────────────────────────────────────
do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
begin

  update akatsuki_apps set
    address_shape = 'command_centre_active_team id=''singleton'' (active_team, base_team, interrupt_stack) · command_centre_brain_settings (key, value jsonb) keys wf_focus + wf_cc_bridge_map · command_centre_alerts (id, type, renderer, title, message, data, active, dismissed_at) · command_centre_blockers · command_centre_gps_locations · all five now carry user_id uuid default auth.uid()',
    clock_field = 'updated_at on active_team and brain_settings · created_at / dismissed_at on alerts',
    clock_trust = 'unknown',
    session = 'unknown',
    private_fields = '{command_centre_gps_locations.*,command_centre_brain_settings.value,command_centre_blockers.*}',
    flags = '{
      "RESOLVED 2026-09-22 — was publicly readable, writable and TRUNCATE-able. Five command_centre_* tables had RLS ON but NO user_id column, so their single policy could not scope rows, and anon held full DML. The anon key ships in five client bundles. Repaired CC-side: user_id uuid added + backfilled + not null + default auth.uid(), open policies dropped, own_rows FOR ALL TO authenticated created, anon revoked.",
      "EXPOSURE WINDOW IS HISTORY — the repair closes the hole, it does not un-read the rows. command_centre_gps_locations is location history and should be treated as compromised, not merely fixed. Consider whether those rows need deleting rather than protecting.",
      "TWO TABLES WERE UNKNOWN — command_centre_blockers and command_centre_gps_locations appeared only when part A2 listed command_centre_% rather than the three tables WF''s card named. An app''s card describes what it writes; it does not enumerate what the counterparty owns. Never scope a TRUST check to the tables a card mentions.",
      "stub — no card filed. CC is known only through wf-cc-bridge-v2.js, which ships INSIDE Weekly Focus and writes CC''s tables directly on a 60s timer, independent of user action.",
      "?? does CC authenticate at all? The anon revoke breaks any unauthenticated client. If CC has no sign-in it is now dark and needs a login before it works again.",
      "?? no DDL in either repo — every column above is inferred from WF''s bridge calls. The card must confirm them.",
      "send card-request-prompt.md — last unregistered counterparty."
    }'
   where user_id = u and id = 'cc';

  -- WF's ?? on those tables is answered; keep the full flag set and swap that
  -- one line so nothing else on the card is lost.
  update akatsuki_apps set flags = array_replace(
    flags,
    '?? command_centre_* tables (active_team, brain_settings, alerts) are written by WF but their DDL is in neither repo, and bridge comments claim permissive USING(true) policies. Run R006 part A2.',
    'ANSWERED R007 — the command_centre_* tables WF writes were publicly writable (RLS on, no tenant column, anon granted full DML). Repaired 2026-09-22. WF''s bridge was pushing focus state into an open table; it now requires a JWT, which WF already has. Two further tables (blockers, gps_locations) were found that WF''s card did not name.')
   where user_id = u and id = 'wf';

  -- The four WF ⇄ CC legs were blocked on a missing card. They are now blocked
  -- on a missing card AND a verified-repaired counterparty — different note.
  update akatsuki_routes
     set note = note || ' · counterparty table was publicly writable until R007; repaired, still direct — re-home once CC files.'
   where user_id = u
     and ((from_app = 'wf' and to_app = 'cc') or (from_app = 'cc' and to_app = 'wf'))
     and note not like '%until R007%';

  -- The anon key's scope claim, third revision. It was aspirational in R001,
  -- true for calendar_app_* in R005, and is now true project-wide.
  update akatsuki_credentials
     set scope = 'Shared project, RLS-gated. Verified 2026-09-22 across akatsuki_*, calendar_app_*, weekly_focus_* and command_centre_*: every policy TO authenticated with user_id = auth.uid(), anon revoked on the WF and CC tables. Two repairs were needed to make this sentence true (R005 Calendar, R007 Command Centre).',
         rotated_at = '2026-09-21'
   where user_id = u and name = 'supabase_anon';

end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C · Verify
-- ─────────────────────────────────────────────────────────────────────────────
-- select id, name, pattern, clock_trust, session, cardinality(flags) open from akatsuki_apps order by id;
-- select unnest(flags) from akatsuki_apps where id = 'cc';
-- select count(*) filter (where state = 'defect') as defects,
--        count(*) filter (where access = 'direct') as direct_legs from akatsuki_routes;
--
-- STILL OPEN, and it now outranks everything — R006 part A1 was never answered.
-- Does subtasks[].u move when del / lat flip?  CLAUDE.md says no and calls it
-- proven; WF's card says yes.  Until that is settled, (board_id, item_key,
-- sub_id, u) cannot be trusted as an idempotency key, and no WF adapter should
-- be written.  Run A1 and paste the u_lag column.
--
-- After that, in order:
--   1 · declare the owner of subtasks[].when — WF and Calendar both claim it.
--   2 · send card-request-prompt.md to Command Centre.
--   3 · decide whether command_centre_gps_locations rows should be deleted.
--   4 · then, and only then, build the first adapter (cal ⇄ sukkiri document
--       shred — R003/R004 already seeded its owned akatsuki_state rows).
