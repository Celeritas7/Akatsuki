-- ============================================================================
-- Akatsuki R017 — hub hardening.
--
-- Project wylxvmkcrexwfpjpbhyy.  Run after R016.  Idempotent: safe to re-run.
-- Hub-side only.  Every app keeps working unchanged: error messages keep the
-- phrases today's regexes match (unknown kind · missing required · does not
-- declare · no route), and consume still returns every column adapters read.
--
--   A. Stable error codes.  AK1xx contract (raised) · AK2xx outcome (returned) ·
--      AK3xx client-side (never from the hub).  Listed in akatsuki_vocab ns 'error'.
--   B. akatsuki_publish returns status 'closed' when the target already closed the
--      request — the sender's cue to re-send as <id>-2.  Plus code / delivery / reply.
--   C. One return shape for akatsuki_consume and the new akatsuki_replies.
--      {defer}: akatsuki_defer keeps a row pending with back-off.  Consume no longer
--      trusts the cursor alone — a deferred row behind a later ack is not lost.
--   D. akatsuki_contract — one row per route: what publish would say, and the traffic.
--
-- Before B (read-only check).  Rows this returns were invisible to consume and
-- WILL be delivered once after B — handlers must be idempotent (they are: every
-- adapter keys on a deterministic id).  Expect 0.
--   select r.to_app, count(*) from akatsuki_requests r
--     join akatsuki_cursors c on c.user_id = r.user_id and c.app = r.to_app
--    where r.status = 'pending' and r.seq <= c.last_seq group by 1;
-- ============================================================================

do $$
begin
  if not exists (select 1 from pg_proc where proname = 'akatsuki_reply') then
    raise exception 'akatsuki: run R010 first';
  end if;
end $$;

-- ═══ A · error codes ═══════════════════════════════════════════════════════
-- SQLSTATE = the code, so PostgREST hands it to the client as error.code.
-- Match on the code, never the message.
create or replace function akatsuki_fail(p_code text, p_name text, p_msg text)
returns void language plpgsql as $$
begin
  raise exception using errcode = p_code, message = 'akatsuki ' || p_code || ': ' || p_msg, hint = p_name;
end $$;

alter table akatsuki_vocab drop constraint if exists akatsuki_vocab_ns_check;
alter table akatsuki_vocab add constraint akatsuki_vocab_ns_check
  check (ns in ('context','kind','icon','palette','enum','error'));

do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
begin
  insert into akatsuki_vocab (user_id, ns, id, schema, meta) values
  (u,'error','AK101',null,'{"name":"unknown_kind","class":"contract","by":"publish","fix":"add the kind to akatsuki_vocab"}'),
  (u,'error','AK102',null,'{"name":"missing_field","class":"contract","by":"publish","fix":"payload lacks a required field"}'),
  (u,'error','AK103',null,'{"name":"not_emitter","class":"contract","by":"publish","fix":"from_app does not declare it emits the kind"}'),
  (u,'error','AK104',null,'{"name":"not_acceptor","class":"contract","by":"publish","fix":"to_app does not declare it accepts the kind (route not opened yet → park)"}'),
  (u,'error','AK105',null,'{"name":"no_route","class":"contract","by":"publish","fix":"no live/half/proposed route for from → to · kind"}'),
  (u,'error','AK106',null,'{"name":"bad_input","class":"contract","by":"publish","fix":"from_app, to_app, kind, src_addr, payload are all required"}'),
  (u,'error','AK107',null,'{"name":"not_addressed","class":"contract","by":"ack · defer","fix":"seq is not addressed to this app"}'),
  (u,'error','AK108',null,'{"name":"no_request","class":"contract","by":"reply","fix":"no request of that kind from that app at that src_addr — src_addr must match word for word"}'),
  (u,'error','AK109',null,'{"name":"bad_status","class":"contract","by":"ack","fix":"ack status is delivered | rejected | skipped. Use akatsuki_defer to keep a row pending"}'),
  (u,'error','AK201',null,'{"name":"payload_differs","class":"outcome","by":"publish","fix":"key reused with a different payload; the stored row stands. A new request needs a new id"}'),
  (u,'error','AK202',null,'{"name":"closed","class":"outcome","by":"publish","fix":"target already closed this request (reply status in the kind''s closed_statuses). Re-send as <id>-2"}'),
  (u,'error','AK301',null,'{"name":"offline_queued","class":"transient","by":"client","fix":"none — flushed on reconnect"}'),
  (u,'error','AK302',null,'{"name":"transient_queued","class":"transient","by":"client","fix":"none — network or 5xx; flushed on reconnect"}')
  on conflict (user_id, ns, id) do update set schema = excluded.schema, meta = excluded.meta;

  -- Which reply statuses close a request.  Only kinds listed here can return 'closed'.
  update akatsuki_vocab
     set meta = coalesce(meta,'{}') || '{"closed_statuses":["rejected","logged"]}'::jsonb
   where user_id = u and ns = 'kind' and id = 'purchase_request';
end $$;

-- ═══ B · publish ═════════════════════════════════════════════════════════════
alter table akatsuki_requests add column if not exists attempts    int not null default 0;
alter table akatsuki_requests add column if not exists next_try_at timestamptz;

drop function if exists akatsuki_publish(jsonb);
create function akatsuki_publish(p jsonb)
returns table (seq bigint, status text, code text, delivery text, reply jsonb)
language plpgsql security invoker as $$
#variable_conflict use_column
declare
  v_from text := p->>'from_app';  v_to text := p->>'to_app';  v_kind text := p->>'kind';
  v_key  text := coalesce(p->>'idempotency_key', v_from || ':' || md5((p->'src_addr')::text || (p->'payload')::text));
  v_schema jsonb;  v_meta jsonb;  v_missing text[];  v_seq bigint;  v_row akatsuki_requests;
begin
  if v_from is null or v_to is null or v_kind is null or p->'src_addr' is null or p->'payload' is null then
    perform akatsuki_fail('AK106','bad_input','publish needs from_app, to_app, kind, src_addr, payload');
  end if;

  perform pg_advisory_xact_lock(hashtext('akatsuki:' || auth.uid()::text || ':' || v_from));

  select v.schema, v.meta into v_schema, v_meta from akatsuki_vocab v
   where v.user_id = auth.uid() and v.ns = 'kind' and v.id = v_kind;
  if not found then perform akatsuki_fail('AK101','unknown_kind', format('unknown kind %s — add it to akatsuki_vocab first', v_kind)); end if;

  select array_agg(x) into v_missing from jsonb_array_elements_text(coalesce(v_schema->'required','[]')) x where not (p->'payload') ? x;
  if v_missing is not null then perform akatsuki_fail('AK102','missing_field', format('%s payload missing required %s', v_kind, v_missing)); end if;

  if not exists (select 1 from akatsuki_apps a where a.user_id = auth.uid() and a.id = v_from and v_kind = any(a.emits)) then
    perform akatsuki_fail('AK103','not_emitter', format('%s does not declare it emits %s', v_from, v_kind)); end if;
  if not exists (select 1 from akatsuki_apps a where a.user_id = auth.uid() and a.id = v_to and v_kind = any(a.accepts)) then
    perform akatsuki_fail('AK104','not_acceptor', format('%s does not declare it accepts %s', v_to, v_kind)); end if;
  if not exists (select 1 from akatsuki_routes rt where rt.user_id = auth.uid() and rt.from_app = v_from and rt.to_app = v_to
                   and rt.kind = v_kind and rt.state <> 'retired') then
    perform akatsuki_fail('AK105','no_route', format('no route %s → %s for %s', v_from, v_to, v_kind)); end if;

  insert into akatsuki_requests (from_app, to_app, kind, src_addr, src_clock, payload, idempotency_key)
  values (v_from, v_to, v_kind, p->'src_addr', p->>'src_clock', p->'payload', v_key)
  on conflict (user_id, idempotency_key) do nothing
  returning akatsuki_requests.seq into v_seq;

  if v_seq is not null then
    seq := v_seq; status := 'pending'; delivery := 'pending'; return next; return;
  end if;

  -- Same key already there.  Failure is skipping — never an abort.
  select * into v_row from akatsuki_requests r where r.user_id = auth.uid() and r.idempotency_key = v_key;
  seq := v_row.seq; delivery := v_row.status; reply := v_row.reply;
  if v_row.reply->>'status' is not null
     and coalesce(v_meta->'closed_statuses','[]'::jsonb) ? (v_row.reply->>'status') then
    status := 'closed';  code := 'AK202';
  else
    status := 'skipped'; code := case when v_row.payload is distinct from p->'payload' then 'AK201' end;
  end if;
  return next;
end $$;

-- ═══ C · one return shape for every read ══════════════════════════════════════
-- consume and replies return the same columns.  Adding a column to
-- akatsuki_requests (R018 device, …) no longer changes what apps receive.
drop function if exists akatsuki_consume(text, int);
create function akatsuki_consume(p_app text, p_limit int default 100)
returns table (seq bigint, kind text, from_app text, to_app text, src_addr jsonb, src_clock text,
               payload jsonb, reply jsonb, reply_seq bigint, status text, attempts int, created_at timestamptz)
language sql security invoker stable as $$
  select r.seq, r.kind, r.from_app, r.to_app, r.src_addr, r.src_clock,
         r.payload, r.reply, r.reply_seq, r.status, r.attempts, r.created_at
    from akatsuki_requests r
   where r.user_id = auth.uid() and r.to_app = p_app and r.status = 'pending'
     and (r.next_try_at is null or r.next_try_at <= now())
   order by r.seq
   limit least(greatest(coalesce(p_limit, 100), 1), 500)
$$;

-- Replies to what I sent, paged by reply_seq (R010).  Same shape as consume.
create or replace function akatsuki_replies(p_app text, p_kind text default null, p_since bigint default 0, p_limit int default 200)
returns table (seq bigint, kind text, from_app text, to_app text, src_addr jsonb, src_clock text,
               payload jsonb, reply jsonb, reply_seq bigint, status text, attempts int, created_at timestamptz)
language sql security invoker stable as $$
  select r.seq, r.kind, r.from_app, r.to_app, r.src_addr, r.src_clock,
         r.payload, r.reply, r.reply_seq, r.status, r.attempts, r.created_at
    from akatsuki_requests r
   where r.user_id = auth.uid() and r.from_app = p_app and r.reply is not null
     and r.reply_seq > coalesce(p_since, 0) and (p_kind is null or r.kind = p_kind)
   order by r.reply_seq
   limit least(greatest(coalesce(p_limit, 200), 1), 1000)
$$;

-- {defer}: not applied yet, may clear up (state not loaded, parent missing).
-- Row stays pending; back-off 1, 2, 4 … 60 min.  Never auto-rejected — a long
-- defer shows in akatsuki_contract.deferred instead.
create or replace function akatsuki_defer(p_app text, p_seq bigint, p_reason text default null)
returns timestamptz
language plpgsql security invoker as $$
declare v_next timestamptz;
begin
  update akatsuki_requests r
     set attempts = r.attempts + 1, error = left(p_reason, 500),
         next_try_at = now() + make_interval(mins => least(2 ^ least(r.attempts, 6), 60)::int)
   where r.user_id = auth.uid() and r.seq = p_seq and r.to_app = p_app and r.status = 'pending'
  returning r.next_try_at into v_next;
  if v_next is null then perform akatsuki_fail('AK107','not_addressed', format('seq %s is not a pending row addressed to %s', p_seq, p_app)); end if;
  return v_next;
end $$;

-- ack: R010 body + codes + status check.  An ack means applied.
create or replace function akatsuki_ack(p_app text, p_seq bigint, p_b_addr jsonb default null, p_reply jsonb default null, p_status text default 'delivered')
returns void
language plpgsql security invoker as $$
declare r akatsuki_requests;
begin
  if p_status not in ('delivered','rejected','skipped') then
    perform akatsuki_fail('AK109','bad_status', format('ack status %s — use delivered | rejected | skipped, or akatsuki_defer', p_status));
  end if;
  update akatsuki_requests
     set status = p_status, delivered_at = now(), next_try_at = null,
         reply = coalesce(p_reply, reply),
         reply_seq = case when p_reply is not null then nextval('akatsuki_seq') else reply_seq end
   where user_id = auth.uid() and seq = p_seq and to_app = p_app
  returning * into r;
  if not found then perform akatsuki_fail('AK107','not_addressed', format('seq %s is not addressed to %s', p_seq, p_app)); end if;

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

-- reply: R010 body + code.
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
    perform akatsuki_fail('AK108','no_request', format('no %s from %s at %s addressed to %s', p_kind, p_from_app, p_src_addr, p_app));
  end if;
  return v_seq;
end $$;

-- ═══ D · akatsuki_contract ═════════════════════════════════════════════════════
-- One row per (from, to, kind): routed or not.  blocker = the code publish would
-- raise right now (null = publishable).  state 'unrouted' = traffic with no route.
create or replace view akatsuki_contract with (security_invoker = on) as
with s as (
  select user_id, from_app, to_app, kind,
         count(*) filter (where status = 'pending')                  as pending,
         count(*) filter (where status = 'pending' and attempts > 0) as deferred,
         count(*) filter (where status = 'delivered')                as delivered,
         count(*) filter (where status = 'rejected')                 as rejected,
         count(*) filter (where status = 'skipped')                  as skipped,
         min(created_at) filter (where status = 'pending')           as oldest_pending_at,
         max(seq)       as last_seq,
         max(reply_seq) as last_reply_seq
    from akatsuki_requests group by 1,2,3,4
), k as (
  select user_id, from_app, to_app, kind from akatsuki_routes
  union
  select user_id, from_app, to_app, kind from s
)
select k.user_id, k.from_app, k.to_app, k.kind,
       coalesce(rt.state, 'unrouted')                    as state,
       rt.access,
       v.id is not null                                  as kind_known,
       coalesce(v.schema->'required', '[]'::jsonb)       as required,
       coalesce(v.schema->'optional', '[]'::jsonb)       as optional,
       v.meta->'closed_statuses'                         as closed_statuses,
       v.meta->>'idempotency_key'                        as key_rule,
       coalesce(k.kind = any(fa.emits), false)           as emits_ok,
       coalesce(k.kind = any(ta.accepts), false)         as accepts_ok,
       case when v.id is null                              then 'AK101'
            when not coalesce(k.kind = any(fa.emits), false)   then 'AK103'
            when not coalesce(k.kind = any(ta.accepts), false) then 'AK104'
            when rt.state is null or rt.state = 'retired'  then 'AK105' end as blocker,
       coalesce(s.pending, 0)   as pending,
       coalesce(s.deferred, 0)  as deferred,
       coalesce(s.delivered, 0) as delivered,
       coalesce(s.rejected, 0)  as rejected,
       coalesce(s.skipped, 0)   as skipped,
       s.oldest_pending_at, s.last_seq, s.last_reply_seq,
       rt.note                  as route_note
  from k
  left join akatsuki_routes rt on rt.user_id = k.user_id and rt.from_app = k.from_app and rt.to_app = k.to_app and rt.kind = k.kind
  left join akatsuki_vocab  v  on v.user_id = k.user_id and v.ns = 'kind' and v.id = k.kind
  left join akatsuki_apps   fa on fa.user_id = k.user_id and fa.id = k.from_app
  left join akatsuki_apps   ta on ta.user_id = k.user_id and ta.id = k.to_app
  left join s                  on s.user_id = k.user_id and s.from_app = k.from_app and s.to_app = k.to_app and s.kind = k.kind;

-- ─────────────────────────────────────────────────────────────────────────────
-- Verify
-- ─────────────────────────────────────────────────────────────────────────────
-- select id, meta->>'name' name, meta->>'class' class from akatsuki_vocab where ns = 'error' order by id;
-- select from_app, to_app, kind, state, blocker, pending, deferred, rejected from akatsuki_contract order by from_app, to_app, kind;
-- select * from akatsuki_contract where blocker is not null or deferred > 0 or state in ('defect','unrouted');
-- select * from akatsuki_publish('{"from_app":"sukkiri","to_app":"cost","kind":"nope","src_addr":{},"payload":{}}'::jsonb);
--   → ERROR  akatsuki AK101: unknown kind nope …   (SQLSTATE AK101, hint unknown_kind)
-- Re-publish an answered Sukkiri request (same key) → status 'closed', code 'AK202', reply = Cost's reply.
