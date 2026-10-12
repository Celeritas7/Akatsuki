-- ============================================================================
-- Akatsuki R012 — Cost → WF goes live.  Run after R010 (part C need not have run).
-- Idempotent.  Source: WF's live report, 2026-09-24.
--
--   Verified on the running apps: request.created lands as a task on my_week /
--   app:cost-requests · request.changed updates it in place · reply cycle
--   done (tick) / open (un-tick) / cancelled (subdel) all arrive at Cost via
--   reply_seq.  That is the round trip R010 part C named as the bar for 'live'.
--
--   WF asked for 'open'.  There is no such route state — akatsuki_routes.state is
--   proposed | half | live | defect | retired.  'open' in WF's words means "the
--   hub stops rejecting" — which is 'live'.  The report meets the bar; live it is.
--
--   A. WF accepts + routes → live.
--   B. WF payload_map — per-kind, request mapping added.
--   C. WF u-bump flags — R008's RESOLVED note collapsed into the fact; adapter rule added.
--   D. Cost card — "no hub calls" flag is now false.
-- ============================================================================

do $$
begin
  if not exists (select 1 from pg_proc where proname = 'akatsuki_reply') then
    raise exception 'akatsuki: run R010 first';
  end if;
end $$;

do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
begin

  -- ═══ A · accepts + routes ═══════════════════════════════════════════════
  -- Part C of R010, whether or not it ran.
  update akatsuki_apps set
    accepts = array(select distinct e from unnest(accepts || '{request.created,request.changed}'::text[]) e)
  where user_id = u and id = 'wf';

  update akatsuki_routes set state = 'live',
    note = case kind
      when 'request.created' then
        'LIVE R012 (verified 2026-09-24). Cost publishes once per request, idempotency cost:request.created:<id>. WF: task on my_week / app:cost-requests, sub_id cost_<id>, src:{app,id,v,t0} kept by normSubs, v = akatsuki seq. Replies in place via akatsuki_reply: tick→done, un-tick→open, subdel→cancelled — all three confirmed.'
      when 'request.changed' then
        'LIVE R012 (verified 2026-09-24). Full snapshot on Cost-side edit/close/cancel. WF applies only if seq > src.v; done→done:true, cancelled→del:true, open→done:false. t overwritten only while t === src.t0.'
    end
  where user_id = u and from_app = 'cost' and to_app = 'wf'
    and kind in ('request.created','request.changed');

  -- ═══ B · payload_map ═══════════════════════════════════════════════════
  -- R006's map is flat and describes task.upsert only.  WF now accepts a second
  -- shape.  Keep every existing key (task.upsert readers depend on them); add the
  -- request mapping under its own kind keys, plus the src stamp the adapter keeps.
  update akatsuki_apps set payload_map = payload_map
    - 'request.created' - 'request.changed' - 'src'
    || jsonb_build_object(
      'src', jsonb_build_object(
        'app', 'payload.subtasks[].src.app',
        'id',  'payload.subtasks[].src.id  · = src_addr.id',
        'v',   'payload.subtasks[].src.v   · akatsuki seq of last applied row, NOT Cost updated_at',
        't0',  'payload.subtasks[].src.t0  · title as last written by Cost; t is Cost''s while t === t0'),
      'request.created', jsonb_build_object(
        'item + quantity + unit', 'payload.subtasks[].t  · "Milk ×2 L", ×1 omitted',
        'needed_by',       'payload.subtasks[].when  · create only',
        'preferred_shop',  'payload.subtasks[].loc',
        '_const',          'md=''b'' · ctx=[] · sub_id=''cost_''+id · item_key=''app:cost-requests'' · board_id=''my_week''',
        '_dropped',        'budget_cap, currency, notes, source'),
      'request.changed', jsonb_build_object(
        'item + quantity + unit', 'payload.subtasks[].t  · only while t === src.t0',
        'preferred_shop',  'payload.subtasks[].loc',
        'status=done',      'payload.subtasks[].done=true',
        'status=open',      'payload.subtasks[].done=false (del=false only if Cost had set del)',
        'status=cancelled', 'payload.subtasks[].del=true',
        '_guard',          'apply only if seq > src.v; then src.v = seq',
        '_dropped',        'budget_cap, currency, notes, source, expense_id, needed_by (create only)'))
  where user_id = u and id = 'wf';

  -- ═══ C · u-bump flags ══════════════════════════════════════════════════
  -- R008 left the finding phrased as a resolution of an argument.  The argument is
  -- over; state the fact.  And the adapter adds a writer of u that the card never
  -- described: applied Cost changes bump u only when a field actually moved.
  update akatsuki_apps set flags = array(
    select f from unnest(flags) f
    where f not like 'RESOLVED R008 — subtasks[].u DOES move on park%'
      and f not like 'R010: Cost requests land on my_week%'
      and f not like 'CLOCK R012%'
  ) || array[
    'CLOCK R012 — subtasks[].u bumps on every real change: t/done/ctx/del/lat/urg/tag (card), lat measured R008 (7/7 u == latAt), del exercised live R012 (subdel → cancelled reply). Dedupe key (board_id, item_key, sub_id, u) sound. Never ordered by; akatsuki_seq is the clock.',
    'CLOCK R012 — Cost-applied changes (request.changed) bump u only if a field moved; a re-delivered snapshot with nothing new leaves u alone. Ordering guard is seq > src.v, not u.',
    'R012 — Cost requests live on my_week / app:cost-requests, sub_id cost_<id>. src:{app,id,v,t0} kept by normSubs (:188). Replies: subtoggle :1521 / sub2 :3864 → done|open, subdel :1527 → cancelled. Nothing arriving from Cost triggers a reply.'
  ]
  where user_id = u and id = 'wf';

  -- MERGE HAZARD flag: still true for WF↔RM equal-u collisions.  The Cost reply
  -- cycle does not go through mergeSubs (reply is a hub row, ordered by
  -- reply_seq), which is why un-tick → open works.  Say so rather than leave a
  -- reader thinking the live route contradicts the flag.
  update akatsuki_apps set flags = array(
    select case when f like 'MERGE HAZARD — no per-row revision integer%' and f not like '%R012%'
      then f || ' Does NOT affect Cost replies: those ride akatsuki_requests.reply / reply_seq, never mergeSubs (R012).'
      else f end
    from unnest(flags) f)
  where user_id = u and id = 'wf';

  update akatsuki_vocab
     set meta = meta || '{"rev":"subtasks[].u — client ms epoch, bumps on every real change including lat (R008 measured) and del (R012 exercised live). Adapter-applied Cost changes bump u only when a field moved."}'::jsonb
   where user_id = u and ns = 'kind' and id = 'task.upsert';

  update akatsuki_vocab
     set meta = meta || '{"state":"live R012 — round trip verified 2026-09-24"}'::jsonb
   where user_id = u and ns = 'kind' and id in ('request.created','request.changed');

  -- ═══ D · Cost card ═════════════════════════════════════════════════════
  update akatsuki_apps set flags = array_replace(flags,
    'R010: no akatsuki_* calls in Cost today. purchase_request still arrives via localStorage cost_management_purchase_requests / sukkiri_cost_requests',
    'R012: Cost publishes request.created / request.changed through akatsuki_publish (live). purchase_request from Sukkiri STILL arrives via localStorage — that leg remains defect.')
  where user_id = u and id = 'cost';

end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Verify
-- ─────────────────────────────────────────────────────────────────────────────
-- select from_app, to_app, kind, state from akatsuki_routes where from_app = 'cost' and to_app = 'wf';   -- both live
-- select accepts from akatsuki_apps where id = 'wf';                                                    -- includes request.*
-- select jsonb_pretty(payload_map -> 'request.changed') from akatsuki_apps where id = 'wf';
-- select unnest(flags) from akatsuki_apps where id = 'wf' and true;                                     -- three R012 lines, no RESOLVED R008
-- select seq, reply_seq, reply->>'status' from akatsuki_requests where from_app='cost' and to_app='wf' order by reply_seq desc nulls last limit 5;
