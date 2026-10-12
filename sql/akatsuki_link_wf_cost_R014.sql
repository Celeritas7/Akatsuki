-- ============================================================================
-- Akatsuki R014 — WF → Cost purchase requests (the ¥ button).  Run after R013 A.
-- Idempotent.
--
-- Found live 2026-09-24: WF's akPush (weekly-focus-app.js:2029) retries forever on
--   "akatsuki: wf does not declare it emits request.created".
-- Correct rejection.  request.created is COST's kind: Cost asks WF to do a task,
-- WF replies done/open/cancelled.  Sending it backwards would put WF rows under a
-- kind whose reply enum (request_status) means the opposite thing, and Cost's own
-- request.created readers would see them.
--
-- What WF actually wants is what Sukkiri already has: "please buy / log this".
-- That kind exists — purchase_request — and Cost already accepts it, replies with
-- purchase_status, and (R013) reads its inbox from hub rows.  So:
--   · WF emits purchase_request.  Route wf → cost.  Reply rides the row (purchase_reply).
--   · Cost's inbox widens from from_app='sukkiri' to any sender (cost-adapter.js R014).
--   · WF changes ONE string in akPush: kind 'request.created' → 'purchase_request',
--     and the outbox drains itself.
-- No hub function changes.
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

  -- WF card: emits purchase_request, accepts the reply.
  update akatsuki_apps set
    emits   = array(select distinct e from unnest(emits   || '{purchase_request}'::text[]) e),
    accepts = array(select distinct e from unnest(accepts || '{purchase_reply}'::text[]) e),
    flags = array(select f from unnest(flags) f where f not like 'R014%') || array[
      'R014 — ¥ button publishes purchase_request (NOT request.created — that is Cost''s kind, Cost→WF). src_addr {board_id,item_key,sub_id}; payload.id = sub_id; idempotency wf:purchase_request:<sub_id>. Status back via hub.replies(''purchase_request'', sinceReplySeq) — cursor is reply_seq.',
      'R014 — akPush retry loop (:2029) was hammering akatsuki_publish with a contract error every tick. A contract error is not transient: stop retrying on /does not declare|no route/ and surface it.']
  where user_id = u and id = 'wf';

  -- Cost card: inbox is every sender, reply goes to row.from_app.
  update akatsuki_apps set
    flags = array(select f from unnest(flags) f where f not like 'R014%') || array[
      'R014 — purchaseInbox() returns purchase_request from ANY from_app (sukkiri, wf, …); purchaseResolved(row,…) replies to row.from_app. Show the sender in the panel.']
  where user_id = u and id = 'cost';

  -- Kind: WF has no price at request time — totalYen becomes optional.  Loosening
  -- required never breaks an existing publisher.
  update akatsuki_vocab set
    schema = '{"required":["id","items"],"optional":["totalYen","requestedAt","source","note"]}',
    meta = coalesce(meta, '{}') || jsonb_build_object(
      'emitted_by', 'sukkiri, wf (R014) — any app that wants Cost to buy or log something',
      'items',      '[{name, qty?, yen?}] — Sukkiri sends priced items, WF sends names only',
      'source',     'enum request_source (own|sukkiri|food_dept) — WF sends ''own''',
      'r014',       'one kind for every "please buy this" leg. Cost''s reply is purchase_status on this row; the sender is row.from_app.')
  where user_id = u and ns = 'kind' and id = 'purchase_request';

  update akatsuki_vocab set meta = coalesce(meta, '{}') || jsonb_build_object(
      'readers', 'sukkiri, wf — each pages hub.replies(''purchase_request'', maxReplySeqSeen)')
  where user_id = u and ns = 'kind' and id = 'purchase_reply';

  -- Routes.  'half' until Cost's panel shows a WF row and replies to it.
  insert into akatsuki_routes (user_id, from_app, to_app, kind, access, state, note) values
  (u, 'wf', 'cost', 'purchase_request', 'stream', 'half',
     'R014 — WF ¥ button. Same kind as Sukkiri''s; Cost inbox reads all senders. Live once a WF item shows in Cost and its reply flips the ¥ badge.'),
  (u, 'cost', 'wf', 'purchase_reply', 'stream', 'half',
     'R014 — rides the purchase_request row. Cost purchaseResolved(row,…) → akatsuki_reply(''cost'',''wf'',''purchase_request'', row.src_addr, {id,status,expense_ids,at}). WF pages on reply_seq.')
  on conflict (user_id, from_app, to_app, kind) do update set access = excluded.access, state = excluded.state, note = excluded.note;

end $$;

-- ═══ B · after the round trip ═══════════════════════════════════════════
-- Bar: WF ¥ → row in Cost inbox → Cost approve → WF badge approved → Cost log → WF badge logged.
-- do $$
-- declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
-- begin
--   update akatsuki_routes set state = 'live', note = 'LIVE R014. ' || note
--    where user_id = u and kind in ('purchase_request','purchase_reply')
--      and ((from_app = 'wf' and to_app = 'cost') or (from_app = 'cost' and to_app = 'wf'));
-- end $$;

-- Verify
-- select from_app, to_app, kind, state from akatsuki_routes where kind like 'purchase_%' order by 1,2;
-- select id, emits, accepts from akatsuki_apps where id in ('wf','cost');
-- select seq, from_app, src_addr, payload->>'id', reply from akatsuki_requests where kind = 'purchase_request' order by seq desc limit 10;
