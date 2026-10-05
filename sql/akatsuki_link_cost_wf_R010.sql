-- ============================================================================
-- Akatsuki R010 — Cost → WF request inbox.
--
-- Project wylxvmkcrexwfpjpbhyy.  Run after R009.  Idempotent: safe to re-run.
-- Source: Cost Management's R010 answers, 2026-09-23.
--
--   A. hub fix — replies get their own clock (reply_seq). Run now.
--   B. vocab, Cost's card, routes, a stale route corrected. Run now.
--   C. WF accepts + route goes half. Run ONLY after WF confirms its adapter.
--
-- Shape:
--   request.created  cost → wf   stream. WF makes a task.
--   request.changed  cost → wf   stream. Full snapshot: edit / close / cancel on Cost's side.
--   WF tick / un-tick            reply in place on the request.created row.
--   No request.done kind.  Reply only flows back to the sender, so Cost-side
--   closes travel as request.changed status=done.
-- ============================================================================

do $$
begin
  if to_regclass('public.akatsuki_violations') is null then
    raise exception 'akatsuki: run R009 first';
  end if;
end $$;

-- ═════════════════════════════════════════════════════════════════
-- PART A · Replies get their own clock.
-- ═════════════════════════════════════════════════════════════════
-- R001's reader: from_app = me, reply is not null, seq > last_seen.
-- seq is the REQUEST's position, fixed at publish.  A reply written later
-- does not move it, so:
--   · WF ticks request #40 after Cost has already seen a reply on #41 → missed.
--   · WF un-ticks #40 (second reply, same row) → never seen again.
-- Fix: every reply write takes a fresh akatsuki_seq into reply_seq, and
-- readers page on reply_seq.  Still the one clock; nothing reads an app clock.

alter table akatsuki_requests add column if not exists reply_seq bigint;
update akatsuki_requests set reply_seq = seq where reply is not null and reply_seq is null;
create index if not exists akatsuki_requests_reply_seq
  on akatsuki_requests (user_id, from_app, reply_seq) where reply_seq is not null;

create or replace function akatsuki_ack(p_app text, p_seq bigint, p_b_addr jsonb default null, p_reply jsonb default null, p_status text default 'delivered')
returns void
language plpgsql security invoker as $$
declare r akatsuki_requests;
begin
  update akatsuki_requests
     set status = p_status, delivered_at = now(),
         reply = coalesce(p_reply, reply),
         reply_seq = case when p_reply is not null then nextval('akatsuki_seq') else reply_seq end
   where user_id = auth.uid() and seq = p_seq and to_app = p_app
  returning * into r;
  if not found then raise exception 'akatsuki: seq % is not addressed to %', p_seq, p_app; end if;

  insert into akatsuki_cursors (app, last_seq) values (p_app, p_seq)
  on conflict (user_id, app) do update set last_seq = greatest(akatsuki_cursors.last_seq, excluded.last_seq), updated_at = now();

  if p_b_addr is not null then
    insert into akatsuki_links (a_app, a_addr, a_clock, b_app, b_addr, kind, seq, source)
    values (r.from_app, r.src_addr, r.src_clock, p_app, p_b_addr, r.kind, p_seq, r.from_app)
    on conflict (user_id, a_app, a_addr, b_app) do update
      set b_addr = excluded.b_addr, a_clock = excluded.a_clock, seq = excluded.seq, source = excluded.source,
          last_synced_at = now(), orphaned_at = case when (r.payload->>'deleted')::boolean then now() else null end;
  end if;
end $$;

-- Reply later, by the origin's address — the target never has to remember a seq.
-- Lands on the newest row of that kind for that address (the request.created row),
-- so tick → un-tick → tick overwrites one reply and each write gets a new reply_seq.
create or replace function akatsuki_reply(p_app text, p_from_app text, p_kind text, p_src_addr jsonb, p_reply jsonb)
returns bigint
language plpgsql security invoker as $$
declare v_seq bigint;
begin
  update akatsuki_requests
     set reply = p_reply, reply_seq = nextval('akatsuki_seq')
   where seq = (select r.seq from akatsuki_requests r
                 where r.user_id = auth.uid() and r.to_app = p_app and r.from_app = p_from_app
                   and r.kind = p_kind and r.src_addr = p_src_addr
                 order by r.seq desc limit 1)
  returning seq into v_seq;
  if v_seq is null then
    raise exception 'akatsuki: no % from % at % addressed to %', p_kind, p_from_app, p_src_addr, p_app;
  end if;
  return v_seq;
end $$;

-- ═════════════════════════════════════════════════════════════════
-- PART B · Vocab, Cost's card, routes.
-- ═════════════════════════════════════════════════════════════════
do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
begin

  insert into akatsuki_vocab (user_id, ns, id, schema, meta) values
  (u, 'kind', 'request.created',
     '{"required":["item","quantity","source"],"optional":["unit","needed_by","budget_cap","currency","preferred_shop","notes"]}',
     '{"emitted_by":"cost","to":"wf","src_addr":"{id} · cost_management_requests.id, client text id (survives offline creation)",
       "src_clock":"updated_at · client-set — recorded, never ordered by",
       "idempotency_key":"cost:request.created:<id> — pass it explicitly. Published ONCE per request; every later change is request.changed.",
       "reply":"{status: open|done|cancelled, at: iso} — written by WF via akatsuki_reply on this row. tick=done, un-tick=open, WF delete (subdel)=cancelled: a request to the owner, Cost decides.",
       "types":{"quantity":"numeric","needed_by":"date YYYY-MM-DD","budget_cap":"integer","currency":"enum currency","source":"enum request_source"}}'),
  (u, 'kind', 'request.changed',
     '{"required":["item","status","updated_at"],"optional":["quantity","source","unit","needed_by","budget_cap","currency","preferred_shop","notes","expense_id"]}',
     '{"emitted_by":"cost","to":"wf","on":"edit, close or cancel on the Cost side — full current snapshot, not a diff",
       "idempotency_key":"default (addr + payload hash). updated_at is in the payload, so each real change is a new key and a re-publish of the same state is skipped.",
       "note":"expense_id set when the request was closed by logging an expense",
       "types":{"status":"enum request_status","expense_id":"bigint"}}')
  on conflict (user_id, ns, id) do update set schema = excluded.schema, meta = excluded.meta;

  insert into akatsuki_vocab (user_id, ns, id, schema, meta) values
  (u, 'enum', 'request_status', '{"values":["open","done","cancelled"]}', '{"owner":"cost","note":"WF replies use all three: tick done, un-tick open, delete cancelled"}'),
  (u, 'enum', 'request_source', '{"values":["food_dept","sukkiri","own"]}', '{"owner":"cost"}')
  on conflict (user_id, ns, id) do update set schema = excluded.schema, meta = excluded.meta;

  update akatsuki_apps set
    emits = array(select distinct e from unnest(emits || '{request.created,request.changed}'::text[]) e),
    owned_paths = array(select distinct e from unnest(owned_paths || '{cost_management_requests.*}'::text[]) e),
    flags = array(select distinct e from unnest(flags || array[
      'R010: cost_management_requests (migration 013) — client text id; updated_at client-set',
      'R010: no akatsuki_* calls in Cost today. purchase_request still arrives via localStorage cost_management_purchase_requests / sukkiri_cost_requests'
    ]) e)
  where user_id = u and id = 'cost';

  insert into akatsuki_routes (user_id, from_app, to_app, kind, access, state, note) values
  (u, 'cost', 'wf', 'request.created', 'stream', 'proposed',
     'R010 — WF shows each request as a task; tick/un-tick replies in place via akatsuki_reply. Blocked on WF declaring accepts (part C).'),
  (u, 'cost', 'wf', 'request.changed', 'stream', 'proposed',
     'R010 — full snapshot on Cost-side edit/close/cancel. WF updates the linked task; status done/cancelled closes it.')
  on conflict (user_id, from_app, to_app, kind) do update set access = excluded.access, state = excluded.state, note = excluded.note;

  -- R002 called these live. Cost's own reply (2026-09-23): no akatsuki_* call exists.
  update akatsuki_routes set state = 'defect',
         note = 'R010 correction: NOT live. Cost has no hub calls; still localStorage + paste. Re-home when Cost adopts akatsuki-client.js.'
   where user_id = u and kind in ('purchase_request','purchase_reply')
     and ((from_app = 'sukkiri' and to_app = 'cost') or (from_app = 'cost' and to_app = 'sukkiri'))
     and state = 'live';
end $$;

-- ═════════════════════════════════════════════════════════════════
-- PART C · Open the route.  Run ONLY after WF confirms its adapter.
-- ═════════════════════════════════════════════════════════════════
-- Until this runs, akatsuki_publish rejects Cost's publishes with
-- "wf does not declare it accepts request.created" — a contract error,
-- not queued.  That is the point: no rows pile up for a reader that doesn't exist.
--
-- WF's adapter, per WF's R010 answers (2026-09-23):
--   lands     board my_week · item_key app:cost-requests (inventory.apps {id:'cost-requests',
--             name:'Requests', group:'Special'}, created on first arrival) · one subtask per
--             request, sub_id 'cost_' + src_addr.id (deterministic — re-import finds the row)
--   ack addr  {board_id:'my_week', item_key:'app:cost-requests', sub_id:'cost_<id>'} — WF's
--             address, not Cost's id echoed back
--   normSubs  (:188) keeps src:{app,id,v,t0}.  v = akatsuki seq of the last applied row —
--             NOT Cost's updated_at (client-set; nothing orders by an app clock)
--   mapping   item(+quantity ×n, unit) → t ("Milk ×2 L", no ×1) · needed_by → when on create
--             only · preferred_shop → loc · md 'b' · ctx [] · dropped: budget_cap, currency,
--             notes, source, expense_id
--   changed   apply only if r.seq > src.v; bump u only if a field moved.  done → done:true ·
--             cancelled → del:true · open → done:false (del:false only if Cost set del)
--   t owner   Cost until the user edits: overwrite only when t === src.t0, then t0 = new t
--   replies   subtoggle :1521, sub2 :3864 → done/open · subdel :1527 → cancelled.
--             Nothing arriving from Cost ever triggers a reply.
--   listen    akatsuki-client.js loaded after weekly-focus-app.js; consume after
--             cloudPullEntries() in the 15 s poll (:1889) and on focus (:1892), only when
--             syncReady().  Header x-akatsuki-app:'wf' applied first (handoff/akatsuki-header).
--
-- do $$
-- declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
-- begin
--   update akatsuki_apps set
--     accepts = array(select distinct e from unnest(accepts || '{request.created,request.changed}'::text[]) e),
--     flags = array(select distinct e from unnest(flags || array[
--       'R010: Cost requests land on my_week / app:cost-requests, sub_id cost_<id>; src:{app,id,v,t0} kept by normSubs; v = akatsuki seq'
--     ]) e)
--   where user_id = u and id = 'wf';
--   update akatsuki_routes set state = 'half', note = note || ' · C run: WF accepts.'
--    where user_id = u and from_app = 'cost' and to_app = 'wf' and kind in ('request.created','request.changed');
-- end $$;
--
-- Flip to live after the first real round trip (create → WF task → tick → Cost closes):
--   update akatsuki_routes set state = 'live'
--    where user_id = 'e91a5f37-e63a-4fd0-8488-4d7a51d56822'
--      and from_app = 'cost' and to_app = 'wf' and kind in ('request.created','request.changed');

-- ─────────────────────────────────────────────────────────────────────────────
-- Verify
-- ─────────────────────────────────────────────────────────────────────────────
-- select column_name from information_schema.columns where table_name = 'akatsuki_requests' and column_name = 'reply_seq';
-- select proname from pg_proc where proname in ('akatsuki_ack','akatsuki_reply');
-- select id, schema from akatsuki_vocab where id like 'request%';
-- select from_app, to_app, kind, state from akatsuki_routes where kind like 'request.%' or kind like 'purchase_%';
