-- ============================================================================
-- Akatsuki — the hub.  R001: schema, RLS, RPCs, seed.
-- Every object is prefixed akatsuki_.  Apply once in the shared Supabase
-- project (General_apps) via the SQL editor.  Idempotent: safe to re-run.
--
-- Three patterns, one clock:
--   stream   → akatsuki_requests  (+ akatsuki_cursors, akatsuki_links)
--   document → akatsuki_state     (per-path rows, owner enforced by trigger)
--   reply    → akatsuki_requests.reply
-- akatsuki_seq is the only clock anyone orders by. App clocks are recorded,
-- never trusted.
-- ============================================================================

create extension if not exists pgcrypto;

-- The one monotonic clock ------------------------------------------------------
create sequence if not exists akatsuki_seq;

-- 1 · Registry — one card per app -------------------------------------------------
create table if not exists akatsuki_apps (
  user_id        uuid not null default auth.uid(),
  id             text not null,                       -- 'wf' 'rm' 'cal' 'sukkiri' 'cost' 'travel' 'weather'
  name           text not null,
  role           text not null default 'app' check (role in ('app','api')),
  pattern        text not null check (pattern in ('stream','document','reply')),
  address_shape  text,                                -- '{board_id, item_key, sub_id}'
  clock_field    text,
  clock_trust    text not null default 'unknown' check (clock_trust in ('trigger','client','none','unknown')),
  emits          text[] not null default '{}',
  accepts        text[] not null default '{}',
  deletes        text check (deletes in ('hard','soft','never')),
  private_fields text[] not null default '{}',
  session        text not null default 'unknown' check (session in ('jwt','guest','service','unknown')),
  reach          text,
  payload_map    jsonb not null default '{}',         -- {"t":"title","done":"done"}
  owned_paths    text[] not null default '{}',
  flags          text[] not null default '{}',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  primary key (user_id, id)
);

-- 2 · Vocab — agreed character for character ---------------------------------------
create table if not exists akatsuki_vocab (
  user_id  uuid not null default auth.uid(),
  ns       text not null check (ns in ('context','kind','icon','palette')),
  id       text not null,                             -- '@train' 'task.upsert' 'flame' '#c0392b'
  schema   jsonb,                                     -- kinds only: {"required":[...],"optional":[...]}
  meta     jsonb not null default '{}',
  version  int  not null default 1,
  primary key (user_id, ns, id)
);

-- 3 · Routes — what may cross, and how (lifted out of wfConfig.ts) -----------------
create table if not exists akatsuki_routes (
  user_id  uuid not null default auth.uid(),
  from_app text not null,
  to_app   text not null,
  kind     text not null,
  access   text not null default 'stream' check (access in ('stream','view','direct')),
  state    text not null default 'proposed' check (state in ('proposed','half','live','defect','retired')),
  note     text,
  primary key (user_id, from_app, to_app, kind)
);

-- 4 · Stream — the inbox ----------------------------------------------------------
create table if not exists akatsuki_requests (
  seq             bigint primary key default nextval('akatsuki_seq'),
  user_id         uuid not null default auth.uid(),
  from_app        text not null,
  to_app          text not null,
  kind            text not null,
  src_addr        jsonb not null,                     -- origin's opaque address, stored as given
  src_clock       text,                               -- origin's clock value, recorded not trusted
  payload         jsonb not null,
  idempotency_key text not null,
  status          text not null default 'pending' check (status in ('pending','delivered','rejected','skipped')),
  reply           jsonb,                              -- request/reply: target writes here, origin reads back
  error           text,
  created_at      timestamptz not null default now(),
  delivered_at    timestamptz,
  unique (user_id, idempotency_key)
);
create index if not exists akatsuki_requests_inbox on akatsuki_requests (user_id, to_app, seq) where status = 'pending';
create index if not exists akatsuki_requests_replies on akatsuki_requests (user_id, from_app, seq) where reply is not null;

-- 5 · Cursors — consuming is one query ------------------------------------------------
create table if not exists akatsuki_cursors (
  user_id    uuid not null default auth.uid(),
  app        text not null,
  last_seq   bigint not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, app)
);

-- 6 · Links — one row per mirrored pair, two opaque addresses ------------------------
create table if not exists akatsuki_links (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null default auth.uid(),
  a_app          text not null,
  a_addr         jsonb not null,
  a_clock        text,
  b_app          text not null,
  b_addr         jsonb,
  b_clock        text,
  kind           text not null,
  seq            bigint,                              -- last akatsuki_seq that touched it
  source         text,                                -- which side moved last
  orphaned_at    timestamptz,                         -- set, never deleted: the row is KEPT
  last_synced_at timestamptz not null default now(),
  unique (user_id, a_app, a_addr, b_app)
);

-- 7 · Document — a shared doc shredded into owned rows -------------------------------
create table if not exists akatsuki_state (
  user_id    uuid not null default auth.uid(),
  doc        text not null,                           -- 'calapp_sukkiri'
  path       text not null,                           -- 'cycles' 'garbage' 'away' 'done' 'block' 'show'
  item_key   text not null default '',                -- 'sk_bath' 'g_moeru' '2026-11-03' or '' for scalars
  owner_app  text not null,
  value      jsonb,
  seq        bigint not null default 0,
  updated_by text,
  deleted_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (user_id, doc, path, item_key)
);

-- 8 · Sources — APIs the hub fetches ---------------------------------------------------
create table if not exists akatsuki_sources (
  user_id         uuid not null default auth.uid(),
  id              text not null,
  name            text not null,
  kind            text,
  endpoint        text not null,
  credential      text,                               -- a NAME in akatsuki_credentials, never the secret
  fetch_policy    text,
  quota           text,
  emits           text not null,
  consumers       text[] not null default '{}',
  cache_ttl       interval,
  last_fetched_at timestamptz,
  last_status     text,
  primary key (user_id, id)
);

-- 9 · Credentials — names and where they live.  The secret itself lives in Vault. -------
create table if not exists akatsuki_credentials (
  user_id    uuid not null default auth.uid(),
  name       text not null,
  scope      text,
  location   text not null check (location in ('vault','edge_env','client_bundle')),
  consumers  text[] not null default '{}',
  rotated_at timestamptz,
  primary key (user_id, name)
);

-- 10 · Cache — one fetch, many consumers ----------------------------------------------
create table if not exists akatsuki_cache (
  user_id    uuid not null default auth.uid(),
  source     text not null,
  key        text not null,                           -- 'tokyo:2026-11-03'
  payload    jsonb not null,
  fetched_at timestamptz not null default now(),
  expires_at timestamptz,
  primary key (user_id, source, key)
);

-- ============================================================================
-- RLS — every table, one rule: user_id = auth.uid(), authenticated only.
-- No FOR ALL · TO PUBLIC · USING (true) anywhere.  Ever.
-- ============================================================================
do $$
declare t text;
begin
  foreach t in array array['akatsuki_apps','akatsuki_vocab','akatsuki_routes','akatsuki_requests','akatsuki_cursors',
                           'akatsuki_links','akatsuki_state','akatsuki_sources','akatsuki_credentials','akatsuki_cache']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists %I on %I', t || '_owner', t);
    execute format('create policy %I on %I for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid())', t || '_owner', t);
  end loop;
end $$;

-- ============================================================================
-- Triggers
-- ============================================================================

-- Document ownership is a constraint, not advice.
create or replace function akatsuki_state_guard() returns trigger language plpgsql as $$
begin
  if tg_op = 'UPDATE' and new.owner_app <> old.owner_app then
    raise exception 'akatsuki: % may not change the owner of %.%/% (owner %)', new.updated_by, new.doc, new.path, new.item_key, old.owner_app;
  end if;
  if new.updated_by is distinct from new.owner_app then
    raise exception 'akatsuki: % does not own %.%/% (owner %)', new.updated_by, new.doc, new.path, new.item_key, new.owner_app;
  end if;
  new.seq := nextval('akatsuki_seq');
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists akatsuki_state_guard on akatsuki_state;
create trigger akatsuki_state_guard before insert or update on akatsuki_state for each row execute function akatsuki_state_guard();

create or replace function akatsuki_touch() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists akatsuki_apps_touch on akatsuki_apps;
create trigger akatsuki_apps_touch before update on akatsuki_apps for each row execute function akatsuki_touch();

-- ============================================================================
-- RPCs — the whole contract an app implements is these four calls.
-- All SECURITY INVOKER: they run as the user, RLS applies.
-- ============================================================================

-- publish: one insert.  Validates kind / route / emits / accepts at the hub,
-- single-flights per (user, from_app) with an advisory lock, never aborts on
-- a duplicate — returns 'skipped' instead.
create or replace function akatsuki_publish(p jsonb)
returns table (seq bigint, status text)
language plpgsql security invoker as $$
declare
  v_from text := p->>'from_app';  v_to text := p->>'to_app';  v_kind text := p->>'kind';
  v_key  text := coalesce(p->>'idempotency_key', v_from || ':' || md5((p->'src_addr')::text || (p->'payload')::text));
  v_schema jsonb;  v_missing text[];  v_ok boolean;
begin
  perform pg_advisory_xact_lock(hashtext('akatsuki:' || auth.uid()::text || ':' || v_from));

  select v.schema into v_schema from akatsuki_vocab v where v.user_id = auth.uid() and v.ns = 'kind' and v.id = v_kind;
  if not found then raise exception 'akatsuki: unknown kind % — add it to akatsuki_vocab first', v_kind; end if;

  select array_agg(r) into v_missing from jsonb_array_elements_text(coalesce(v_schema->'required','[]')) r where not (p->'payload') ? r;
  if v_missing is not null then raise exception 'akatsuki: % payload missing required %', v_kind, v_missing; end if;

  select exists (select 1 from akatsuki_apps a where a.user_id = auth.uid() and a.id = v_from and v_kind = any(a.emits)) into v_ok;
  if not v_ok then raise exception 'akatsuki: % does not declare it emits %', v_from, v_kind; end if;
  select exists (select 1 from akatsuki_apps a where a.user_id = auth.uid() and a.id = v_to and v_kind = any(a.accepts)) into v_ok;
  if not v_ok then raise exception 'akatsuki: % does not declare it accepts %', v_to, v_kind; end if;
  select exists (select 1 from akatsuki_routes r where r.user_id = auth.uid() and r.from_app = v_from and r.to_app = v_to and r.kind = v_kind and r.state <> 'retired') into v_ok;
  if not v_ok then raise exception 'akatsuki: no route % → % for %', v_from, v_to, v_kind; end if;

  insert into akatsuki_requests (from_app, to_app, kind, src_addr, src_clock, payload, idempotency_key)
  values (v_from, v_to, v_kind, p->'src_addr', p->>'src_clock', p->'payload', v_key)
  on conflict (user_id, idempotency_key) do nothing
  returning akatsuki_requests.seq into seq;

  if seq is null then
    select r.seq into seq from akatsuki_requests r where r.user_id = auth.uid() and r.idempotency_key = v_key;
    status := 'skipped';
  else
    status := 'pending';
  end if;
  return next;
end $$;

-- consume: everything addressed to me past my cursor, in seq order.
create or replace function akatsuki_consume(p_app text, p_limit int default 100)
returns setof akatsuki_requests
language sql security invoker stable as $$
  select r.*
  from akatsuki_requests r
  left join akatsuki_cursors c on c.user_id = r.user_id and c.app = p_app
  where r.user_id = auth.uid() and r.to_app = p_app and r.status = 'pending'
    and r.seq > coalesce(c.last_seq, 0)
  order by r.seq
  limit p_limit
$$;

-- ack: mark delivered, advance the cursor, and (optionally) record the pair
-- and/or a reply.  Called once per consumed row.
create or replace function akatsuki_ack(p_app text, p_seq bigint, p_b_addr jsonb default null, p_reply jsonb default null, p_status text default 'delivered')
returns void
language plpgsql security invoker as $$
declare r akatsuki_requests;
begin
  update akatsuki_requests
     set status = p_status, delivered_at = now(), reply = coalesce(p_reply, reply)
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

-- orphan: the origin's thing is gone / parked.  Keep the link, mark it.
create or replace function akatsuki_orphan(p_a_app text, p_a_addr jsonb)
returns int language sql security invoker as $$
  with u as (update akatsuki_links set orphaned_at = coalesce(orphaned_at, now())
             where user_id = auth.uid() and a_app = p_a_app and a_addr = p_a_addr returning 1)
  select count(*)::int from u
$$;

-- ============================================================================
-- Views
-- ============================================================================

-- A shredded document, re-grouped by path.  security_invoker is NOT optional —
-- without it the view bypasses RLS (the roadmap_session_days bug of Sep 21).
create or replace view akatsuki_docs with (security_invoker = on) as
select user_id, doc, path, owner_app,
       jsonb_agg(value order by item_key) filter (where deleted_at is null and item_key <> '') as items,
       (jsonb_agg(value) filter (where item_key = '' and deleted_at is null)) -> 0            as scalar,
       max(seq) as seq
from akatsuki_state
group by user_id, doc, path, owner_app;

-- Pairs whose two clocks disagree, or that are orphaned — the reconciliation queue.
create or replace view akatsuki_disputes with (security_invoker = on) as
select l.*, a.name as a_name, b.name as b_name
from akatsuki_links l
left join akatsuki_apps a on a.user_id = l.user_id and a.id = l.a_app
left join akatsuki_apps b on b.user_id = l.user_id and b.id = l.b_app
where l.orphaned_at is not null or (l.a_clock is not null and l.b_clock is not null and l.a_clock <> l.b_clock);

-- ============================================================================
-- Seed — the current ecosystem.  auth.uid() is null in the SQL editor, so the
-- owner is named explicitly (same uuid 0003_real_gate.sql backfilled to).
-- ============================================================================
do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
begin
  -- apps
  insert into akatsuki_apps (user_id, id, name, role, pattern, address_shape, clock_field, clock_trust, emits, accepts, deletes, private_fields, session, reach, payload_map, owned_paths, flags) values
  (u, 'wf', 'Weekly Focus', 'app', 'stream', '{board_id, item_key, sub_id} · base36 / djb2, not a uuid', 'subtasks[].u · ms epoch', 'client',
     '{task.upsert,note}', '{task.upsert}', 'soft', '{when,md,urg,dl,loc,tag,lat,latAt,rv}', 'jwt', 'browser · shared Supabase project · cloud only',
     '{"t":"title","done":"done","ctx":"ctx","when":"due"}', '{subtasks[].t,done,ctx[]}',
     '{"del / lat flip without bumping u — park and delete are invisible incrementally","every write is a whole-array read-modify-write; never drop tombstones"}'),
  (u, 'rm', 'Roadmap', 'app', 'stream', '{id} · uuid', 'updated_at', 'trigger',
     '{task.upsert}', '{task.upsert}', 'hard', '{folder,road,project}', 'jwt', 'browser · shared Supabase project · cloud only',
     '{"title":"title","done":"done","ctx":"ctx"}', '{roadmap_tasks.*}',
     '{"single-owner RLS since Sep 21 — multi-tenant is a schema change, not a policy change","tab-scoped sync guard; the Sep 21 race made a duplicate folder"}'),
  (u, 'cal', 'Calendar', 'app', 'document', '{event_id} · doc paths away · done · overrides · block', 'updated_at · client-set', 'client',
     '{cycle.digital,away,done,overrides,block}', '{task.upsert,note,trip.segment,forecast,trash.pickup,holiday}', 'soft', '{entries,diary,birthdays,preferences}', 'guest', ':8080 · localStorage authoritative · offline-capable',
     '{"title":"title","starts_at":"starts_at","all_day":"all_day","kind_hint":"render rule"}', '{away,done,overrides,block,show,wm,cycles[kind:digital]}',
     '{"localStorage is truth — brokered fields are last-known-good when offline","different origin from Sukkiri: no local path exists, brokered or not"}'),
  (u, 'sukkiri', 'Sukkiri', 'app', 'document', 'sk_<cycleId> · garbage[].id', 'updated_at · client-set', 'client',
     '{trash.pickup,cycle.home,purchase_request}', '{away,overrides,done,block,holiday}', 'never', '{photos,timers,reports,sukkiri_state}', 'jwt', ':8091 · localStorage authoritative · offline-capable',
     '{"label":"label","every":"interval_days","anchor":"anchor","icon":"vocab.icon","color":"vocab.palette"}', '{garbage[],cycles[kind:home],anchor}',
     '{"whole-row upsert can clobber Calendar''s done{} — must be shredded by owner","anchor moves on every done; a stale anchor draws the wrong grid"}'),
  (u, 'cost', 'Cost', 'app', 'reply', '{id} · req<epoch><rand>', 'none · status written in place', 'none',
     '{purchase_reply}', '{purchase_request}', 'never', '{expenses,ledger}', 'jwt', 'separate project · paste-JSON fallback across origins',
     '{"items[].priceYen":"amount","currency":"JPY","status":"reply.status"}', '{reply.status}',
     '{"no change signal — origin re-reads on focus and every 15 s"}'),
  (u, 'travel', 'Travel Plan', 'app', 'stream', '{trip_id, segment_id}', null, 'unknown',
     '{trip.segment}', '{}', 'hard', '{}', 'unknown', null, '{}', '{}',
     '{"card incomplete — clock, session, reach, payload map and owners not declared"}'),
  (u, 'weather', 'Weather', 'app', 'stream', '{location, date}', 'none · relays its source', 'none',
     '{forecast}', '{}', 'never', '{}', 'service', 'server-side adapter · no client path',
     '{"daily.code":"condition","tmax":"high_c","tmin":"low_c","pop":"rain_pct"}', '{forecast.*}',
     '{"relays a forecast source — needs an active adapter (edge function or pg_cron); a table alone fetches nothing"}')
  on conflict (user_id, id) do nothing;

  -- vocab · contexts (takes over roadmap_contexts_map)
  insert into akatsuki_vocab (user_id, ns, id) select u, 'context', x from unnest(array['@train','@home','@office','@needs-claude-code','@claude-chat-only','@phone-only','@deep-work']) x
  on conflict do nothing;
  -- vocab · icons and palette (from the Calendar ⇄ Sukkiri contract; 10 glyphs, not 11)
  insert into akatsuki_vocab (user_id, ns, id) select u, 'icon', x from unnest(array['flame','recycle','bottle','can','paper','trash','leaf','box','battery','glass']) x
  on conflict do nothing;
  insert into akatsuki_vocab (user_id, ns, id) select u, 'palette', x from unnest(array['#c0392b','#e67e22','#2980b9','#27ae60','#8e44ad','#16a085','#7f8c8d']) x
  on conflict do nothing;
  -- vocab · kinds, with the payload each must carry
  insert into akatsuki_vocab (user_id, ns, id, schema) values
  (u, 'kind', 'task.upsert',      '{"required":["title","done"],"optional":["ctx","due","deleted"]}'),
  (u, 'kind', 'note',             '{"required":["title","date"],"optional":["body"]}'),
  (u, 'kind', 'trip.segment',     '{"required":["title","starts_at","ends_at"],"optional":["all_day","location","kind_hint","deleted"]}'),
  (u, 'kind', 'forecast',         '{"required":["date","location","condition"],"optional":["high_c","low_c","rain_pct"]}'),
  (u, 'kind', 'holiday',          '{"required":["date","name"],"optional":["country"]}'),
  (u, 'kind', 'trash.pickup',     '{"required":["label","days"],"optional":["weeks","icon","color","short"]}'),
  (u, 'kind', 'cycle.home',       '{"required":["id","name","every","anchor"],"optional":["color"]}'),
  (u, 'kind', 'cycle.digital',    '{"required":["id","name","every","anchor"],"optional":["color"]}'),
  (u, 'kind', 'purchase_request', '{"required":["id","totalYen","items"],"optional":["requestedAt"]}'),
  (u, 'kind', 'purchase_reply',   '{"required":["id","status"],"optional":[]}')
  on conflict do nothing;

  -- routes (was wfConfig.ts + implicit code paths)
  insert into akatsuki_routes (user_id, from_app, to_app, kind, access, state, note) values
  (u, 'wf', 'rm', 'task.upsert', 'stream', 'half', 'WF → RM live for study: prefix only; RM → WF exists in code, nothing pulls'),
  (u, 'rm', 'wf', 'task.upsert', 'stream', 'proposed', 'build WF v65 against akatsuki_requests, not task_links'),
  (u, 'wf', 'cal', 'task.upsert', 'direct', 'defect', 'Calendar reads weekly_focus_entries directly — re-home to stream'),
  (u, 'sukkiri', 'cal', 'trash.pickup', 'stream', 'defect', 'today: one shared row, whole-payload upsert both ways'),
  (u, 'sukkiri', 'cal', 'cycle.home', 'stream', 'defect', 'same row; owner-shred into akatsuki_state'),
  (u, 'cal', 'sukkiri', 'away', 'view', 'proposed', 'Sukkiri only ever reads these — a view, not a copy'),
  (u, 'sukkiri', 'cost', 'purchase_request', 'stream', 'live', 'Cost replies in place via akatsuki_ack(reply)'),
  (u, 'travel', 'cal', 'trip.segment', 'stream', 'proposed', 'waiting on Travel''s card'),
  (u, 'weather', 'cal', 'forecast', 'stream', 'proposed', 'blocked on an active adapter')
  on conflict do nothing;

  -- credentials — names only
  insert into akatsuki_credentials (user_id, name, scope, location, consumers, rotated_at) values
  (u, 'supabase_anon', 'Shared project, RLS-gated', 'client_bundle', '{wf,rm,cal,sukkiri,cost}', '2026-09-21')
  on conflict do nothing;
end $$;

-- ============================================================================
-- Migration note — task_links → akatsuki_links (run once, after verifying):
--   insert into akatsuki_links (user_id, a_app, a_addr, a_clock, b_app, b_addr, b_clock, kind, source, orphaned_at, last_synced_at)
--   select t.user_id?, 'wf', jsonb_build_object('board_id',wf_board_id,'item_key',wf_item_key,'sub_id',wf_sub_id), wf_u::text,
--          'rm', jsonb_build_object('id',rm_task_id), rm_seen_at::text, 'task.upsert', source, orphaned_at, last_synced_at
--   from task_links t;
-- task_links has no user_id — join through roadmap_tasks.user_id.  Keep task_links
-- read-only until WF v65 and RM's pull both read akatsuki_*, then drop it.
-- ============================================================================
