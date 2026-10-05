-- ============================================================================
-- Akatsuki R005 — Calendar's TRUST answer.  Run after R004.  Idempotent.
--
-- R004 part A stopped the wiring on a suspicion.  The suspicion was half right,
-- and the half that was wrong matters, so this file records what was actually
-- found rather than what was feared.
--
--   FEARED (R004 flag):  RLS dropped on all four calendar_app_* tables, anon key
--                        in a public bundle ⇒ world-readable calendar.
--   FOUND (2026-09-22):  RLS was ON, one policy (own_rows) per table.  The real
--                        break was user_id TEXT DEFAULT 'default-user' on
--                        entries / diary / birthdays / preferences — a column
--                        that cannot equal auth.uid() without a cast.
--                        calendar_app_sukkiri was already uuid + RLS.
--   REPAIRED (Calendar-side, not by Akatsuki):  0 legacy 'default-user' rows out
--                        of 35, so no backfill.  own_rows dropped, column
--                        retyped to uuid + not null, default dropped, own_rows
--                        recreated FOR ALL TO authenticated
--                        using/with check (user_id = auth.uid()).
--
-- Consequence Calendar has not absorbed yet: UID='guest' is not uuid-castable.
-- Guest writes now RAISE where they previously landed somewhere.  That is the
-- correct behaviour and a client-visible change.
--
-- What this file does NOT do: flip any cal→sukkiri leg off 'defect'.  Those legs
-- are defective because saveSukkiri() upserts the whole payload with no diff and
-- no adapter exists — a storage-security fix does not touch that.
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A · Re-verify.  Writes nothing.  Expect uuid / true / 1 on all five tables.
-- ─────────────────────────────────────────────────────────────────────────────
select c.relname                                as table_name,
       c.relrowsecurity                         as rls_enabled,
       (select count(*) from pg_policies p
         where p.schemaname = 'public' and p.tablename = c.relname) as policies,
       (select data_type from information_schema.columns
         where table_name = c.relname and column_name = 'user_id')  as user_id_type,
       (select count(*) from pg_policies p
         where p.schemaname = 'public' and p.tablename = c.relname
           and (p.roles::text[] <> array['authenticated'] or p.qual is null)) as suspect_policies
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relname like 'calendar_app_%' and c.relkind = 'r'
 order by 1;

-- ─────────────────────────────────────────────────────────────────────────────
-- B · The hub stops claiming it doesn't know.
-- ─────────────────────────────────────────────────────────────────────────────
do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
begin

  update akatsuki_apps set
    session = 'jwt',
    flags = '{
      "RESOLVED 2026-09-22 — TRUST answered. All five calendar_app_* tables: RLS on, user_id uuid not null, own_rows FOR ALL TO authenticated using/with check (user_id = auth.uid()). R004''s data-exposure flag was wrong in kind: RLS was never off, the defect was user_id TEXT DEFAULT ''default-user''. Retyped Calendar-side with 0 legacy rows to migrate.",
      "guest mode is now fail-loud, not fail-quiet: UID=''guest'' does not cast to uuid, so every cloud call in guest mode raises instead of writing. The adapter still must not publish in guest mode, and Calendar''s client must actually no-op those calls rather than swallow the error.",
      "saveSukkiri() has NO diff: every sukkiri-kind fires on any save. Same defect as Sukkiri''s pushCalCloud; the adapter hash-gates both sides.",
      "calendar_app_sukkiri is written whole-payload by BOTH apps — last writer wins. R003 + R004 shred it into owned akatsuki_state rows.",
      "Calendar writes weekly_focus_entries.payload.subtasks[].done/.when — a foreign write into WF''s document. WF has NOT filed a card, so this path has no declared owner. Flagged defect.",
      "deleting a cycle leaves its done{} and overrides{} keys orphaned in the payload forever — never pruned.",
      "?? no revision anywhere: dedupe key is user_id+entry_date+updated_at, which is not change-scoped. Unaffected by the security repair."
    }'
   where user_id = u and id = 'cal';

  -- The anon key's scope claim is now true for calendar_app_* rather than aspirational.
  update akatsuki_credentials
     set scope = 'Shared project, RLS-gated. Verified 2026-09-22 across all calendar_app_* and akatsuki_* tables; every policy TO authenticated with user_id = auth.uid().'
   where user_id = u and name = 'supabase_anon';

  -- Restate why the legs are still defective, so the reason survives the fix.
  update akatsuki_routes
     set note = note || ' · TRUST cleared R005; still defect on the no-diff whole-payload write, not on security.'
   where user_id = u and from_app = 'cal' and to_app = 'sukkiri' and state = 'defect'
     and note not like '%TRUST cleared R005%';

end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C · Verify
-- ─────────────────────────────────────────────────────────────────────────────
-- select id, session, clock_trust, cardinality(flags) open from akatsuki_apps order by id;
-- select unnest(flags) from akatsuki_apps where id = 'cal';
-- select from_app, to_app, kind, access, state from akatsuki_routes where from_app = 'cal' order by 3;
--
-- Next: Weekly Focus is still a stub with two 'direct'/'defect' legs pointing at
-- it, one of which is Calendar writing into WF's document with no declared owner.
-- Send card-request-prompt.md to WF; that card is the only thing that unblocks
-- cal→wf task.done and wf→cal task.dated.
