-- ============================================================================
-- Akatsuki R048 — mail joins the hub (Amazon orders → Cost), plus hardening.
-- (Written as R037 in this branch; renumbered 2026-10-24 — R037–R047 were already
--  used by migrations run from the design chat.  Live strings may still say R037.)
-- Project wylxvmkcrexwfpjpbhyy.  Run after the 2026-10-21 snapshot.  Idempotent.
--
-- Contract agreed with Cost (AKATSUKI-REPLY-cost-amazon-orders.md + reply 2;
-- Cost side built in v62):
--   purchase.detected   mail → cost   addr {source, order_id}
--   purchase.cancelled  mail → cost   addr {source, order_id}
--   Cost resolves by akatsuki_ack on the detected row:
--     reply {order_id, status logged|dismissed|flagged, at, ...}
--
--   A. Hardening: anon loses every grant on akatsuki_* tables.
--   B. Ingest tokens get a scope.  akatsuki_ping accepts owntracks tokens only.
--   C. Vocab: two kinds + the purchase_source enum.
--   D. The mail card, Cost's accepts, both routes (proposed).
--   E. akatsuki_publish_ingest — headless publish for a scoped token.
--   F. 30-day purge of item names / email ids after Cost resolves.
--   G. pg_cron: the purge, and akatsuki-tts moved to Vault.
--
-- After running: mint the mail token (see bottom), deploy
-- supabase/functions/akatsuki-mail, install tools/gmail-amazon-orders.gs.
-- ============================================================================

do $$
begin
  if to_regclass('public.akatsuki_ingest_tokens') is null then
    raise exception 'akatsuki: run sql/akatsuki_live_snapshot_2026-10-21.sql first';
  end if;
end $$;


-- ═══ A · anon loses every grant on hub tables ══════════════════════════════
-- Every hub policy is TO authenticated, so anon already sees nothing through
-- RLS.  This removes the default grants (incl. TRUNCATE) underneath, per R007.
do $$
declare t text;
begin
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind in ('r','p') and c.relname like 'akatsuki\_%'
  loop
    execute format('revoke all on public.%I from anon', t);
  end loop;
end $$;


-- ═══ B · scoped ingest tokens ══════════════════════════════════════════════
-- Before this migration any live token was accepted by akatsuki_ping, so a mail token
-- could have posted locations.  Existing tokens are OwnTracks tokens.
alter table akatsuki_ingest_tokens add column if not exists scope text not null default 'owntracks';
alter table akatsuki_ingest_tokens drop constraint if exists akatsuki_ingest_tokens_scope_check;
alter table akatsuki_ingest_tokens add constraint akatsuki_ingest_tokens_scope_check
  check (scope in ('owntracks', 'mail'));

drop function if exists akatsuki_ingest_token_new(text);
create or replace function akatsuki_ingest_token_new(p_label text, p_scope text default 'owntracks')
 returns text
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_tok text;
begin
  if auth.uid() is null then perform akatsuki_fail('42501', 'not_signed_in', 'token needs a signed-in user'); end if;
  if coalesce(trim(p_label), '') = '' then perform akatsuki_fail('AK102', 'missing_field', 'label is required'); end if;
  if p_scope not in ('owntracks', 'mail') then perform akatsuki_fail('AK102', 'missing_field', 'scope must be owntracks or mail'); end if;
  v_tok := encode(extensions.gen_random_bytes(24), 'hex');
  insert into akatsuki_ingest_tokens (user_id, id, token_hash, scope) values (auth.uid(), p_label, extensions.digest(v_tok, 'sha256'), p_scope)
  on conflict (user_id, id) do update set token_hash = excluded.token_hash, scope = excluded.scope,
                                          created_at = now(), revoked_at = null, last_used_at = null;
  return v_tok;   -- copy it now (OwnTracks password / Apps Script property); it is not readable again
end $function$;
revoke execute on function akatsuki_ingest_token_new(text, text) from public, anon;
grant  execute on function akatsuki_ingest_token_new(text, text) to authenticated;

-- akatsuki_ping: unchanged except the token lookup now requires scope = 'owntracks'.
CREATE OR REPLACE FUNCTION public.akatsuki_ping(p_token text, p_lat double precision, p_lng double precision, p_acc_m integer, p_t timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  u uuid; dev text; s akatsuki_stop_settings; st akatsuki_ingest_state; r4lat numeric; r4lng numeric;
  d double precision; v_anchor text; v_place text; v_other bigint; out jsonb := '{}'::jsonb; src constant text := 'owntracks';
begin
  select user_id, id into u, dev from akatsuki_ingest_tokens
   where token_hash = extensions.digest(coalesce(p_token, ''), 'sha256') and revoked_at is null and scope = 'owntracks';
  if u is null then perform akatsuki_fail('42501', 'bad_token', 'unknown or revoked token'); end if;
  dev := 'ot:' || dev;
  update akatsuki_ingest_tokens set last_used_at = now() where user_id = u and id = substr(dev, 4);
  select * into s from akatsuki_stop_settings where user_id = u;
  if s.user_id is null then insert into akatsuki_stop_settings (user_id) values (u) returning * into s; end if;
  if not s.enabled then return jsonb_build_object('status', 'disabled'); end if;
  if p_lat is null or p_lng is null or p_t is null then perform akatsuki_fail('AK102', 'missing_field', 'lat, lng, t'); end if;
  if p_t > now() + interval '5 minutes' or p_t < now() - interval '1 day' then return jsonb_build_object('status', 'ignored', 'why', 'time'); end if;

  insert into akatsuki_devices (user_id, id, app, label, last_seen_at) values (u, dev, src, substr(dev, 4), now())
  on conflict (user_id, id) do update set last_seen_at = now();
  insert into akatsuki_ingest_state (user_id, device) values (u, dev) on conflict do nothing;
  select * into st from akatsuki_ingest_state where user_id = u and device = dev for update;

  -- gap: silence longer than ingest_gap_s ⇒ the open visit ends at last fix inside (D1); coverage splits
  if st.last_ping is not null and p_t - st.last_ping > make_interval(secs => s.ingest_gap_s) then
    if st.open then
      update akatsuki_visits set until = greatest(since, st.last_in), last_seen_at = greatest(last_seen_at, st.last_in),
             end_reason = 'gap', updated_seq = nextval('akatsuki_seq')
       where user_id = u and device = dev and since = st.since and until is null;
      out := out || jsonb_build_object('closed', 'gap');
    end if;
    if st.cov_since is not null then
      insert into akatsuki_location_coverage (user_id, device, app, since, until) values (u, dev, src, st.cov_since, st.last_ping)
      on conflict (user_id, device, since) do update set until = greatest(akatsuki_location_coverage.until, excluded.until), seq = nextval('akatsuki_seq');
    end if;
    st.anchor_lat := null; st.open := false; st.misses := 0; st.cov_since := null;
  end if;
  st.cov_since := coalesce(st.cov_since, p_t);
  insert into akatsuki_location_coverage (user_id, device, app, since, until) values (u, dev, src, st.cov_since, p_t)
  on conflict (user_id, device, since) do update set until = greatest(akatsuki_location_coverage.until, excluded.until), seq = nextval('akatsuki_seq');
  st.last_ping := p_t;

  if p_acc_m is not null and p_acc_m > s.accuracy_max_m then
    update akatsuki_ingest_state set last_ping = st.last_ping, cov_since = st.cov_since, anchor_lat = st.anchor_lat, open = st.open, misses = st.misses, updated_at = now()
     where user_id = u and device = dev;
    return out || jsonb_build_object('status', 'ignored', 'why', 'accuracy');
  end if;

  if st.anchor_lat is null then
    st.anchor_lat := p_lat; st.anchor_lng := p_lng; st.since := p_t; st.last_in := p_t; st.misses := 0; st.open := false;
    out := out || jsonb_build_object('status', 'anchored');
  else
    d := akatsuki_distance_m(st.anchor_lat, st.anchor_lng, p_lat, p_lng);
    if d - coalesce(p_acc_m, 0) > s.radius_m then                       -- clearly outside
      st.misses := st.misses + 1;
      if st.misses >= 2 then
        if st.open then
          update akatsuki_visits set until = greatest(since, st.last_in), last_seen_at = greatest(last_seen_at, st.last_in),
                 end_reason = 'left', updated_seq = nextval('akatsuki_seq')
           where user_id = u and device = dev and since = st.since and until is null
          returning lat, lng into r4lat, r4lng;
          -- hub-merge with another device's overlapping stay (same step as akatsuki_visit_close)
          select o.seq into v_other from akatsuki_visits o
           where o.user_id = u and o.device <> dev and o.merged_into is null
             and o.since <= st.since and coalesce(o.until, o.last_seen_at) >= st.since
             and akatsuki_distance_m(o.lat, o.lng, r4lat, r4lng) <= 100
           order by o.since limit 1;
          if v_other is not null then update akatsuki_visits set merged_into = v_other where user_id = u and device = dev and since = st.since; end if;
          out := out || jsonb_build_object('closed', 'left');
        end if;
        st.anchor_lat := p_lat; st.anchor_lng := p_lng; st.since := p_t; st.last_in := p_t; st.misses := 0; st.open := false;
        out := out || jsonb_build_object('status', 'anchored');
      else
        out := out || jsonb_build_object('status', 'miss');
      end if;
    elsif d > s.radius_m then
      out := out || jsonb_build_object('status', 'fuzzy');                -- neither in nor out: moves nothing
    else
      st.misses := 0; st.last_in := p_t;
      st.anchor_lat := st.anchor_lat * 0.8 + p_lat * 0.2; st.anchor_lng := st.anchor_lng * 0.8 + p_lng * 0.2;
      if not st.open and extract(epoch from p_t - st.since) >= s.dwell_s then
        r4lat := round(st.anchor_lat::numeric, 4); r4lng := round(st.anchor_lng::numeric, 4);
        select id, place_id into v_anchor, v_place from akatsuki_anchors
         where user_id = u and retired_at is null and akatsuki_distance_m(lat, lng, st.anchor_lat, st.anchor_lng) <= radius_m
         order by akatsuki_distance_m(lat, lng, st.anchor_lat, st.anchor_lng) limit 1;
        if v_place is null then
          select id into v_place from akatsuki_places
           where user_id = u and retired_at is null and lat is not null and radius_m is not null
             and akatsuki_distance_m(lat, lng, st.anchor_lat, st.anchor_lng) <= radius_m
           order by akatsuki_distance_m(lat, lng, st.anchor_lat, st.anchor_lng) limit 1;
        end if;
        update akatsuki_visits set until = last_seen_at, end_reason = 'superseded', updated_seq = nextval('akatsuki_seq')
         where user_id = u and device = dev and until is null and since <> st.since;
        insert into akatsuki_visits (user_id, device, since, last_seen_at, lat, lng, radius_m, acc_m, anchor_id, place_id, source_app)
        values (u, dev, st.since, st.last_in, r4lat, r4lng, s.radius_m, p_acc_m, v_anchor, v_place, src)
        on conflict (user_id, device, since) do nothing;
        st.open := true;
        out := out || jsonb_build_object('status', 'opened', 'place_id', v_place);
      elsif st.open then
        update akatsuki_visits set last_seen_at = greatest(last_seen_at, p_t),
               acc_m = least(coalesce(acc_m, p_acc_m), coalesce(p_acc_m, acc_m)), updated_seq = nextval('akatsuki_seq')
         where user_id = u and device = dev and since = st.since and until is null;
        out := out || jsonb_build_object('status', 'seen');
      else
        out := out || jsonb_build_object('status', 'dwelling', 'for_s', extract(epoch from p_t - st.since)::int);
      end if;
    end if;
  end if;

  update akatsuki_ingest_state
     set anchor_lat = st.anchor_lat, anchor_lng = st.anchor_lng, since = st.since, last_in = st.last_in, last_ping = st.last_ping,
         open = st.open, misses = st.misses, cov_since = st.cov_since, updated_at = now()
   where user_id = u and device = dev;
  return out;
end $function$;


-- ═══ C · vocab ═════════════════════════════════════════════════════════════
do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
begin
  insert into akatsuki_vocab (user_id, ns, id, schema, meta) values
  (u, 'kind', 'purchase.detected',
   '{"required":["source","order_id","ordered_at","total","currency"],"optional":["items","email_id","backfill"]}',
   '{"emitted_by":"mail (R037)","accepted_by":"cost",
     "src_addr":"{source, order_id}",
     "idempotency_key":"<source>:<order_id>:detected — one row per order; a corrected email is skipped (AK201), never re-inserted",
     "items":"[{name ≤60 chars, qty?, price?}] — nulled 30 days after Cost resolves (akatsuki_purchase_purge)",
     "email_id":"Gmail message id — nulled with items",
     "reply":"Cost acks this row: {order_id, status logged|dismissed|flagged, at, expense_ids?, category?, amount?, reason?, seen?}",
     "closed_statuses":["logged","dismissed"],
     "differs_from":"purchase_request = intent awaiting approval; purchase.detected = a charge that already happened"}'),
  (u, 'kind', 'purchase.cancelled',
   '{"required":["source","order_id"],"optional":["refund_total","cancelled_at","email_id"]}',
   '{"emitted_by":"mail (R037)","accepted_by":"cost",
     "src_addr":"{source, order_id} — same addr as the detected row it cancels",
     "idempotency_key":"<source>:<order_id>:cancelled",
     "cost_does":"unresolved detected row → dismissed (reason cancelled); logged → flagged, never deletes the expense"}'),
  (u, 'enum', 'purchase_source', '{"values":["amazon"]}',
   '{"owner":"mail","note":"add rakuten, card, ... when a producer exists. NEVER a shop name."}')
  on conflict (user_id, ns, id) do update set schema = excluded.schema, meta = excluded.meta;
end $$;


-- ═══ D · the mail card, Cost's accepts, routes ═════════════════════════════
do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
begin
  insert into akatsuki_apps (user_id, id, name, role, pattern, address_shape, clock_field, clock_trust,
                             emits, accepts, deletes, private_fields, session, reach, payload_map, owned_paths, flags,
                             health, backup, writes)
  values (u, 'mail', 'Mail (Gmail producer)', 'api', 'stream', '{source, order_id}', 'ordered_at / cancelled_at · from the email', 'none',
          '{purchase.detected,purchase.cancelled}', '{}', 'never', '{purchase.detected.items,purchase.detected.email_id}', 'service',
          'Google Apps Script (owner''s Gmail, 15 min) → edge function akatsuki-mail → akatsuki_publish_ingest. Scoped ingest token; no Supabase key in Apps Script.',
          '{"order no.":"order_id","order date":"ordered_at","order total":"total","items":"items[].name"}', '{}',
          '{"R037 — headless producer. Owns no tables; publishes only. Token scope mail; revoke with akatsuki_ingest_token_revoke(label)."}',
          'none', 'none', 'record')
  on conflict (user_id, id) do update set
    name = excluded.name, role = excluded.role, pattern = excluded.pattern, address_shape = excluded.address_shape,
    clock_field = excluded.clock_field, clock_trust = excluded.clock_trust, emits = excluded.emits, accepts = excluded.accepts,
    deletes = excluded.deletes, private_fields = excluded.private_fields, session = excluded.session, reach = excluded.reach,
    payload_map = excluded.payload_map, flags = excluded.flags, health = excluded.health, backup = excluded.backup, writes = excluded.writes;

  -- Append, never overwrite: Cost already accepts purchase_request.
  update akatsuki_apps
     set accepts = array(select distinct x from unnest(accepts || '{purchase.detected,purchase.cancelled}'::text[]) x order by 1)
   where user_id = u and id = 'cost';

  -- Both legs together: without cancelled, a logged-then-cancelled order is never flagged.
  -- 'proposed' does NOT hold traffic back (publish only rejects 'retired'); the gate is the token.
  insert into akatsuki_routes (user_id, from_app, to_app, kind, access, state, note) values
  (u, 'mail', 'cost', 'purchase.detected',  'stream', 'proposed', 'R037 — Amazon order emails. Live after the first round trip.'),
  (u, 'mail', 'cost', 'purchase.cancelled', 'stream', 'proposed', 'R037 — goes live together with purchase.detected, never alone.')
  on conflict (user_id, from_app, to_app, kind) do update set access = excluded.access, note = excluded.note;
end $$;


-- ═══ E · akatsuki_publish_ingest ═══════════════════════════════════════════
-- Called only by edge function akatsuki-mail (service role).  Resolves a
-- scope='mail' token to its owner, makes auth.uid() return that owner for this
-- transaction, forces from_app, then runs the normal akatsuki_publish so every
-- check (vocab, required fields, emits/accepts, route, lock, idempotency) holds.
create or replace function akatsuki_publish_ingest(p_token text, p jsonb)
 returns table (seq bigint, status text, code text, delivery text, reply jsonb)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare u uuid; v_label text; v_scope text; v_p jsonb;
begin
  select t.user_id, t.id, t.scope into u, v_label, v_scope from akatsuki_ingest_tokens t
   where t.token_hash = extensions.digest(coalesce(p_token, ''), 'sha256') and t.revoked_at is null and t.scope <> 'owntracks';
  if u is null then perform akatsuki_fail('42501', 'bad_token', 'unknown or revoked token'); end if;
  if p is null or jsonb_typeof(p) <> 'object' then perform akatsuki_fail('AK106', 'bad_input', 'p must be an object'); end if;
  if octet_length(p::text) > 16384 then perform akatsuki_fail('AK106', 'bad_input', 'publish larger than 16 KB'); end if;

  -- auth.uid() reads these; is_local = true keeps them to this transaction.
  perform set_config('request.jwt.claim.sub', u::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  perform set_config('akatsuki.app', v_scope, true);   -- akatsuki_actor()

  update akatsuki_ingest_tokens set last_used_at = now() where user_id = u and id = v_label;
  v_p := p || jsonb_build_object('from_app', v_scope);   -- the token decides who is speaking, never the body
  return query select * from akatsuki_publish(v_p);
end $function$;
revoke execute on function akatsuki_publish_ingest(text, jsonb) from public, anon, authenticated;
grant  execute on function akatsuki_publish_ingest(text, jsonb) to service_role;


-- ═══ F · purge ═════════════════════════════════════════════════════════════
-- Agreed in reply 2: 30 days after Cost resolves, keep id / date / total / reply,
-- drop item names and the Gmail id.  Clock = reply.at (reply_seq is not a time).
-- Flagged rows wait until the person has acknowledged them (seen = true).
create or replace function akatsuki_purchase_purge()
 returns integer
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare n int; m int;
begin
  update akatsuki_requests r
     set payload = r.payload - 'items' - 'email_id'
   where r.kind = 'purchase.detected'
     and (r.payload ? 'items' or r.payload ? 'email_id')
     and (r.reply->>'status' in ('logged', 'dismissed')
          or (r.reply->>'status' = 'flagged' and coalesce(r.reply->>'seen', 'false') = 'true'))
     and coalesce(case when r.reply->>'at' ~ '^\d{4}-\d{2}-\d{2}' then (r.reply->>'at')::timestamptz end,
                  r.delivered_at, r.created_at) < now() - interval '30 days';
  get diagnostics n = row_count;

  update akatsuki_requests r
     set payload = r.payload - 'email_id'
   where r.kind = 'purchase.cancelled' and r.payload ? 'email_id'
     and r.status = 'delivered' and coalesce(r.delivered_at, r.created_at) < now() - interval '30 days';
  get diagnostics m = row_count;
  return n + m;
end $function$;
revoke execute on function akatsuki_purchase_purge() from public, anon, authenticated;


-- ═══ G · pg_cron ═══════════════════════════════════════════════════════════
select cron.schedule('akatsuki-purchase-purge', '40 17 * * *', $$ select akatsuki_purchase_purge(); $$);

-- akatsuki-tts read the service-role JWT from its own command text.  Same job,
-- now reading Vault like every other akatsuki job.  ROTATE the service-role key
-- afterwards (Dashboard → Settings → API) and update Vault secret akatsuki_tts_cron.
select cron.schedule('akatsuki-tts', '* * * * *', $$
  select net.http_post(
    url     := 'https://wylxvmkcrexwfpjpbhyy.supabase.co/functions/v1/akatsuki-tts',
    headers := jsonb_build_object('Content-Type','application/json',
                 'Authorization','Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'akatsuki_tts_cron')),
    body    := '{}'::jsonb)
  where exists (select 1 from akatsuki_audio where status = 'wanted'
                   or (status = 'making' and claimed_at < now() - interval '10 minutes'));
$$);


-- ═══ After running ═════════════════════════════════════════════════════════
-- 1 · Checks (expect: 0 anon grants · owntracks token still scope owntracks · both routes).
--   select count(*) from information_schema.role_table_grants where grantee = 'anon' and table_name like 'akatsuki%';
--   select id, scope, revoked_at from akatsuki_ingest_tokens;
--   select * from akatsuki_contract where from_app = 'mail';
-- 2 · Mint the mail token SIGNED IN (Hub page, or supabase-js as you), NOT in the
--     SQL editor (auth.uid() is null there):
--       await supabase.rpc('akatsuki_ingest_token_new', { p_label: 'gmail', p_scope: 'mail' })
--     Put the returned value in Apps Script → Project Settings → Script properties → AKATSUKI_TOKEN.
-- 3 · After the first real order reaches Cost's inbox and is resolved:
--   update akatsuki_routes set state = 'live' where from_app = 'mail' and to_app = 'cost';
