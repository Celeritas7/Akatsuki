-- ============================================================================
-- Akatsuki R008 — the clock question, answered.  Run after R007.  Idempotent.
--
-- CLAUDE.md said, until today: "WF's subtasks[].u ... do not move on flag
-- changes — proven Sep 21."  R001 carried the same claim as a card flag.  WF's
-- own card (R006) said the opposite.  The hub cannot hold both.
--
-- MEASURED 2026-09-22.  subtasks[].latAt is stamped from the same Date.now() as
-- the park.  If parking bumps u, u == latAt.  If it does not, u is older.
--
--   7 parked subtasks across 4 items.  ms_gap (latAt − u) = 0 on all 7.
--
-- Verdict: u moves on park.  The card is right; the founding note was wrong,
-- or true of a build that no longer runs (the card itself names an Attempt_29
-- copy on a different port).  CLAUDE.md is corrected in the same commit.
--
-- What this does and does not prove:
--   PROVEN    lat flip bumps u.  (board_id, item_key, sub_id, u) is a sound
--             dedupe key for parks.
--   ACCEPTED  del flip bumps u — same patch() funnel, card says so, but del has
--             no timestamp sibling so it cannot be measured from data.  If it
--             ever matters, the live test is: snapshot u, delete in the app,
--             re-read.
--   UNCHANGED no app clock is ordered by.  akatsuki_seq is the clock.  The rule
--             never depended on the example.
--
-- Method note, worth keeping: the first test proposed (u vs row updated_at)
-- would have given the wrong answer.  Every row in the sample carried
-- updated_at = 2026-09-21 11:31 against u values from early August — a mass
-- no-op republish stamped them all.  Compare a field to its sibling stamped
-- in the same write, never to the row clock.
-- ============================================================================

do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
begin

  -- Swap the contradiction flag for the finding; every other WF flag stays.
  update akatsuki_apps set flags = array_replace(
    flags,
    'CLOCK CONTRADICTION — card says done/del/lat/urg/tag bump subtasks[].u; CLAUDE.md and R001''s flag say u does NOT move on flag changes (proven Sep 21). Run R006 part A1. If u lags, every incremental pull has been dropping parks and deletes.',
    'RESOLVED R008 — subtasks[].u DOES move on park: 7/7 parked subtasks have u == latAt to the millisecond (measured 2026-09-22). CLAUDE.md''s Sep 21 claim was wrong and is corrected. del accepted on the card''s word (no timestamp to measure). Dedupe key (board_id, item_key, sub_id, u) is sound.')
   where user_id = u and id = 'wf';

  -- R001's original flag on the same point, if it survived R006's rewrite.
  update akatsuki_apps set flags = array_remove(
    flags,
    'del / lat flip without bumping u — park and delete are invisible incrementally')
   where user_id = u and id = 'wf';

  -- The route note hedged on part A1.  It no longer needs to.
  update akatsuki_routes
     set note = 'WF → RM live for study prefix only. Four WF event names (upserted/completed/deleted/parked) collapse onto this kind. Dedupe (board_id,item_key,sub_id,u) verified sound for parks R008.'
   where user_id = u and from_app = 'wf' and to_app = 'rm' and kind = 'task.upsert';

  -- The kind's meta pointed at the open question.
  update akatsuki_vocab
     set meta = meta || '{"rev":"subtasks[].u — client ms epoch, bumps on every real change INCLUDING lat (R008 measured) and del (card)"}'::jsonb
   where user_id = u and ns = 'kind' and id = 'task.upsert';

  -- Clock trust on the card stays ''client''.  That was always the point.

end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Verify
-- ─────────────────────────────────────────────────────────────────────────────
-- select unnest(flags) from akatsuki_apps where id = 'wf';
-- select note from akatsuki_routes where from_app = 'wf' and to_app = 'rm';
--
-- The WF adapter is no longer blocked on its clock.  It is still blocked on:
--   1 · the owner of subtasks[].when — WF and Calendar both claim it.
--   2 · Command Centre's card.
-- Neither is a query.  Both are a decision.
