-- ============================================================================
-- Akatsuki R013 — Sukkiri → Cost purchase requests leave localStorage.
-- Run after R010 (needs reply_seq + akatsuki_reply).  Idempotent.
--
-- The hub needed no new function.  Sukkiri already emits purchase_request, Cost
-- already accepts it, and the route has been 'defect' (not 'retired') since R010,
-- so akatsuki_publish passes today.  What was wrong was the adapters:
--
--   · sukkiri-adapter watchReplies saved r.seq as its cursor but paged on
--     reply_seq → every reply re-read on every poll.  Fixed: cursor = reply_seq.
--   · cost-adapter resolved by seq via akatsuki_ack, and the approval list lived
--     in localStorage → a request consumed on one device was invisible on another.
--     Fixed: Cost's open list IS the hub rows (purchaseInbox), resolved by address
--     via akatsuki_reply, so approved → logged is two replies on one row.
--
--   A. vocab, flags, notes.  Run now.
--   B. route → live.  Run after the round trip (see bottom).
-- ============================================================================

do $$
begin
  if not exists (select 1 from pg_proc where proname = 'akatsuki_reply') then
    raise exception 'akatsuki: run R010 first';
  end if;
end $$;

-- ═══ A ════════════════════════════════════════════════════════════════════
do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
begin

  update akatsuki_vocab set meta = coalesce(meta, '{}') || jsonb_build_object(
      'src_addr',        '{id} · Sukkiri request id req<epoch><rand>, client-minted (survives offline)',
      'src_clock',       'requestedAt · client-set — recorded, never ordered by',
      'idempotency_key', 'sukkiri:<id> — published ONCE per request. No edit/cancel kind; none is minted until Sukkiri needs one.',
      'r013',            'Cost''s pending list is these rows (to_app=cost, reply null or pending) — no local copy.')
   where user_id = u and ns = 'kind' and id = 'purchase_request';

  update akatsuki_vocab set
    schema = '{"required":["id","status"],"optional":["expense_ids","amount","currency","at"]}',
    meta   = coalesce(meta, '{}') || jsonb_build_object(
      'rides',   'the purchase_request row''s reply column — never its own row',
      'writer',  'Cost via akatsuki_reply(''cost'',''sukkiri'',''purchase_request'', src_addr, reply). By address, not seq; may be written more than once (approved → logged), each write takes a new reply_seq.',
      'reader',  'Sukkiri hub.replies(''purchase_request'', since) — cursor is max reply_seq seen, NOT seq.',
      'types',   '{"status":"enum purchase_status","expense_ids":"bigint[]","at":"iso"}'::jsonb)
   where user_id = u and ns = 'kind' and id = 'purchase_reply';

  update akatsuki_routes set note = case kind
      when 'purchase_request' then
        'R013 — adapters fixed; waiting on both apps to wire them. Sukkiri sendToCostApp → skHub.sendPurchaseRequest (key sukkiri:<id>). Cost reads costHub.purchaseInbox(); consume only acks delivered. Old path: localStorage sukkiri_cost_requests / cost_management_purchase_requests + paste.'
      when 'purchase_reply' then
        'R013 — rides the request row. Cost: costHub.purchaseResolved(row, status, expenseIds) → akatsuki_reply by src_addr. Sukkiri: watchReplies pages on reply_seq.'
    end
   where user_id = u and kind in ('purchase_request','purchase_reply')
     and ((from_app = 'sukkiri' and to_app = 'cost') or (from_app = 'cost' and to_app = 'sukkiri'));

  update akatsuki_apps set flags = array(
    select f from unnest(flags) f
    where f not like 'purchase_reply: Cost writes status back, but Sukkiri has NO read path%'
      and f not like 'R013%')
  || array['R013 — purchase_reply read path: watchReplies(onStatus) pages on reply_seq; cursor akatsuki_replyseq_sukkiri. Delete the sukkiri_cost_requests localStorage push once sendPurchaseRequest is wired.']
  where user_id = u and id = 'sukkiri';

  update akatsuki_apps set flags = array(
    select f from unnest(flags) f where f not like 'R013%')
  || array[
    'R013 — purchase inbox = hub rows (purchaseInbox), not localStorage: visible on every device. Resolve with purchaseResolved(row,…) — by address. Delete mergePurchaseRequests (:335) and both localStorage keys once wired.',
    'R013 CUTOVER — requests that arrived by paste have no hub row; akatsuki_reply raises for them. Finish them in the old UI before deleting mergePurchaseRequests, or re-send from Sukkiri (same id → same key → one row).',
    'R013 — no akatsuki_links row for purchase_request: Cost has no row of its own until logging, and expense_ids ride in the reply. Acceptable; revisit if anything needs the pair.']
  where user_id = u and id = 'cost';

end $$;

-- ═══ B · after the round trip ═══════════════════════════════════════════
-- Bar for live: Sukkiri sends → shows in Cost's inbox on a SECOND device →
-- Cost approves → Sukkiri shows approved → Cost logs → Sukkiri shows logged
-- (two replies, one row, each seen once).
--
-- do $$
-- declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
-- begin
--   update akatsuki_routes set state = 'live', note = replace(note, 'R013 — adapters fixed; waiting on both apps to wire them.', 'LIVE R013.')
--    where user_id = u and kind in ('purchase_request','purchase_reply')
--      and ((from_app = 'sukkiri' and to_app = 'cost') or (from_app = 'cost' and to_app = 'sukkiri'));
--   update akatsuki_apps set flags = array_replace(flags,
--     'R012: Cost publishes request.created / request.changed through akatsuki_publish (live). purchase_request from Sukkiri STILL arrives via localStorage — that leg remains defect.',
--     'R013: every Cost link runs through the hub. No localStorage path remains.')
--    where user_id = u and id = 'cost';
-- end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Verify
-- ─────────────────────────────────────────────────────────────────────────────
-- select from_app, to_app, kind, state, note from akatsuki_routes where kind like 'purchase_%';
-- select id, schema, meta from akatsuki_vocab where id in ('purchase_request','purchase_reply');
-- select seq, status, src_addr, reply_seq, reply from akatsuki_requests where kind = 'purchase_request' order by seq desc limit 5;
