-- ============================================================================
-- Akatsuki R019 — Scriptura files its card · the hub's first generator (TTS).
-- Run after R017.  Idempotent.  Source: Scriptura's card, 2026-09-26
-- (cards/scriptura.md).
--
-- Audio is a SOURCE the hub owns, not an app feature:
--   Scriptura ──audio.wanted──▶ tts   (one request per pack, ≤ 2000 items)
--   trigger    → akatsuki_audio rows 'wanted'  (the request is applied → delivered)
--   pg_cron    → Edge Function akatsuki-tts, only while rows are wanted
--   akatsuki-tts → Azure → bucket akatsuki-audio/<lang>/<key>.mp3 · row 'ready' · v+1
--                → <lang>/_index.json {key: v}  ← the only thing a learner reads
--   settle     → reply on the request row: queued | making | partial | ready
--
-- The Azure key never reaches a browser: edge_env of akatsuki-tts only.
-- Learners read public bucket objects only — no table access, works signed out.
--
--   A. The card, the tts app, vocab, routes, credentials, source.   Run now.
--   B. akatsuki_audio + enqueue / claim / done / settle.            Run now.
--   C. Bucket.                                                      Run now.
--   D. pg_cron.  Run AFTER akatsuki-tts is deployed and one manual run works.
-- ============================================================================

do $$
begin
  if not exists (select 1 from pg_proc where proname = 'akatsuki_fail') then
    raise exception 'akatsuki: run R017 first';
  end if;
end $$;

-- ═══ A · card ═══════════════════════════════════════════════════════════════
do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
begin

  insert into akatsuki_apps (
    user_id, id, name, role, pattern, address_shape, clock_field, clock_trust,
    emits, accepts, deletes, private_fields, session, reach, payload_map, owned_paths, flags
  ) values
  (u, 'scriptura', 'Scriptura', 'app', 'reply',
    '{id} = scr-audio:<lang>:<pack>:<rev> per request · clip = (lang, keyOf(text)), keyOf = NFC → lowercase hex code points joined by -',
    'none on content (scriptura_app_languages/_units/_characters/_vowels change by developer SQL only) · progress tables private',
    'none',
    '{audio.wanted}', '{}', 'hard',
    '{scriptura_app_sheet_stats.*,scriptura_app_srs.*,localStorage scriptura.ink.*,localStorage scriptura.sheet.*,localStorage scriptura.lastEmail,localStorage scriptura.azureTts}',
    'jwt',
    ':5144 (run-scriptura.bat, 5144–5159) · celeritas7.github.io/Scriptura_app · shared project wylxvmkcrexwfpjpbhyy · email magic link (implicit) + Google OAuth · entry index.html · hub scripts lib/ · no service worker · window.ScripturaCloud / ScripturaData / ScripturaSpeech',
    '{"audio.wanted":{"lang":"scriptura_app_languages.id","pack":"letters | concepts | vocab pack id","rev":"hash of the pack''s sorted texts","items[].text":"characters.char | joined units.concept.positions[].parts[].t (NFC)","items[].key":"keyOf(text)","items[].kind":"letter | word","voice":"per-lang default","rate":"-15%","format":"audio-24khz-48kbitrate-mono-mp3"},
      "clip read":{"<lang>/_index.json":"{key: v}","<lang>/<key>.mp3?v=<v>":"public bucket akatsuki-audio"}}',
    '{}',
    '{
      "R019 — publisher is a developer/admin action per pack (a tools page), never the learner app. Content changes by SQL/data.js only.",
      "R019 — learner reads bucket objects only (<lang>/_index.json, then <lang>/<key>.mp3?v=). No hub table read, no sign-in needed.",
      "R019 — fallback when a key is not in the index: device speechSynthesis. Never Azure from a page.",
      "?? tools/Generate Audio.html holds an Azure key in localStorage scriptura.azureTts and calls Azure from the page — client-side secret. Retire once akatsuki-tts has made the built-in set.",
      "?? the Supabase client (lib/store.js ScripturaCloud.init) lacks the x-akatsuki-app: scriptura header.",
      "?? scriptura_app_units.concept holds one card; multi-card units live only in data/data.js. The hub reads texts from the audio.wanted payload only, never from scriptura_app_* — so this does not block.",
      "user_id is text (auth.uid()::text) on scriptura_app_* progress tables. The hub never joins them; noted for any future link."
    }'),
  (u, 'tts', 'Speech (Azure TTS)', 'api', 'reply',
    '(lang, key) · path <lang>/<key>.mp3 in bucket akatsuki-audio',
    'akatsuki_audio.made_at · server-set by akatsuki_audio_done', 'trigger',
    '{audio_reply}', '{audio.wanted}', 'never', '{}', 'service',
    'Edge Function akatsuki-tts (service role) · pg_cron every minute while rows are wanted',
    '{}', '{akatsuki_audio.*,storage akatsuki-audio/*}',
    '{"R019 — the hub''s first generator. Accepts audio.wanted; applied by trigger at insert (status delivered), answered on the request row''s reply."}')
  on conflict (user_id, id) do update set
    name = excluded.name, role = excluded.role, pattern = excluded.pattern,
    address_shape = excluded.address_shape, clock_field = excluded.clock_field, clock_trust = excluded.clock_trust,
    emits = excluded.emits, accepts = excluded.accepts, deletes = excluded.deletes,
    private_fields = excluded.private_fields, session = excluded.session, reach = excluded.reach,
    payload_map = excluded.payload_map, owned_paths = excluded.owned_paths, flags = excluded.flags,
    updated_at = now();

  insert into akatsuki_vocab (user_id, ns, id, schema, meta) values
  (u, 'kind', 'audio.wanted',
     '{"required":["lang","pack","rev","items"],"optional":["voice","rate","format"]}',
     '{"emitted_by":"scriptura","on":"a pack''s texts change (catalogue resync, vocab import, word edit) — one request per pack, never per word",
       "src_addr":"{id} · scr-audio:<lang>:<pack>:<rev>","idempotency_key":"= src_addr.id. A re-send after the pack closed is <id>-2, -3…",
       "limit":"items ≤ 2000 per request (AK110). Split larger packs as <pack>.1, <pack>.2",
       "items":"[{text (NFC), key (keyOf), kind: letter|word}]",
       "defaults":"voice = enum tts_voice[lang].default · rate -15% · format audio-24khz-48kbitrate-mono-mp3",
       "closed_statuses":["ready"]}'),
  (u, 'kind', 'audio_reply',
     '{"required":["status","total","ready"],"optional":["failed","making","at"]}',
     '{"rides":"the audio.wanted row''s reply column — never its own row","writer":"akatsuki_audio_settle (after each akatsuki-tts run)",
       "reader":"Scriptura hub.replies(''audio.wanted'', since) — cursor = max reply_seq","types":{"status":"enum audio_status","at":"iso"}}'),
  (u, 'enum', 'audio_status', '{"values":["queued","making","partial","ready"]}',
     '{"owner":"tts","note":"reply status per request. partial = some clips failed 3× — re-send as <id>-2 to retry. Row status is wanted | making | ready | failed."}'),
  (u, 'enum', 'tts_voice',
     '{"values":{"burmese":{"default":"my-MM-NilarNeural","alt":"my-MM-ThihaNeural","xml_lang":"my-MM"},
                 "hindi":{"default":"hi-IN-SwaraNeural","alt":"hi-IN-MadhurNeural","xml_lang":"hi-IN"},
                 "telugu":{"default":"te-IN-ShrutiNeural","alt":"te-IN-MohanNeural","xml_lang":"te-IN"},
                 "sinhala":{"default":"si-LK-ThiliniNeural","alt":"si-LK-SameeraNeural","xml_lang":"si-LK"},
                 "tamil":{"default":"ta-IN-PallaviNeural","alt":"ta-IN-ValluvarNeural","xml_lang":"ta-IN"},
                 "hiragana":{"default":"ja-JP-NanamiNeural","alt":"ja-JP-KeitaNeural","xml_lang":"ja-JP"},
                 "katakana":{"default":"ja-JP-NanamiNeural","alt":"ja-JP-KeitaNeural","xml_lang":"ja-JP"},
                 "korean":{"default":"ko-KR-SunHiNeural","alt":"ko-KR-InJoonNeural","xml_lang":"ko-KR"},
                 "chinese":{"default":"zh-CN-XiaoxiaoNeural","alt":"zh-CN-YunxiNeural","xml_lang":"zh-CN"}}}',
     '{"owner":"scriptura","source":"Scriptura card 2026-09-26","note":"female default"}'),
  (u, 'enum', 'script_lang',
     '{"values":["burmese","hindi","telugu","sinhala","tamil","hiragana","katakana","korean","chinese"]}',
     '{"owner":"scriptura","source":"data/data.js languageList · scriptura_app_languages.id"}'),
  (u, 'error', 'AK110', null,
     '{"name":"too_large","class":"contract","by":"publish (audio.wanted)","fix":"items > 2000 — split the pack as <pack>.1, <pack>.2"}')
  on conflict (user_id, ns, id) do update set schema = excluded.schema, meta = excluded.meta;

  insert into akatsuki_routes (user_id, from_app, to_app, kind, access, state, note) values
  (u, 'scriptura', 'tts', 'audio.wanted', 'stream', 'half',
     'R019 — half until akatsuki-tts is deployed and the letters pack of one language round-trips (wanted → ready → index → plays signed out).'),
  (u, 'tts', 'scriptura', 'audio_reply', 'stream', 'half',
     'R019 — rides the request row. Written by akatsuki_audio_settle.')
  on conflict (user_id, from_app, to_app, kind) do update set access = excluded.access, state = excluded.state, note = excluded.note;

  insert into akatsuki_credentials (user_id, name, scope, location, consumers, rotated_at) values
  (u, 'azure_tts', 'Azure Speech key + region (AZURE_TTS_KEY, AZURE_TTS_REGION)', 'edge_env', '{tts}', null),
  (u, 'akatsuki_tts_cron', 'Service-role JWT pg_cron sends to invoke akatsuki-tts', 'vault', '{tts}', null),
  (u, 'scriptura_azure_page', 'Azure key pasted into tools/Generate Audio.html — flagged, retire after R019 D', 'client_bundle', '{scriptura}', null)
  on conflict (user_id, name) do update set scope = excluded.scope, location = excluded.location, consumers = excluded.consumers;

  insert into akatsuki_sources (user_id, id, name, kind, endpoint, credential, fetch_policy, quota, emits, consumers, cache_ttl) values
  (u, 'azure_tts', 'Azure neural TTS', 'api', 'supabase/functions/akatsuki-tts', 'azure_tts',
     'queue-driven · pg_cron each minute while akatsuki_audio has wanted rows · BATCH clips per run',
     '?? F0 free: 0.5M chars/month · S0 metered per char — ~80k words × ~6 chars ≈ 0.5M chars for the full target',
     'audio_reply', '{scriptura}', null)
  on conflict (user_id, id) do update set endpoint = excluded.endpoint, credential = excluded.credential,
    fetch_policy = excluded.fetch_policy, quota = excluded.quota, emits = excluded.emits, consumers = excluded.consumers;
end $$;

-- ═══ B · the queue ═══════════════════════════════════════════════════════════
-- One row per clip.  Shared content, but still owned: user_id = who asked first,
-- and RLS reads stay user_id = auth.uid().  Writes: security-definer functions only.
create table if not exists akatsuki_audio (
  lang       text not null,
  key        text not null,                        -- keyOf(text)
  text       text not null,                        -- NFC
  kind       text not null default 'word' check (kind in ('letter','word')),
  voice      text not null,
  rate       text not null default '-15%',
  format     text not null default 'audio-24khz-48kbitrate-mono-mp3',
  path       text generated always as (lang || '/' || key || '.mp3') stored,
  v          int  not null default 0,              -- 0 = never made · bumps on every successful make
  status     text not null default 'wanted' check (status in ('wanted','making','ready','failed')),
  attempts   int  not null default 0,
  error      text,
  bytes      int,
  user_id    uuid not null,
  req_seq    bigint,                               -- last request that wanted it (diagnosis only)
  claimed_at timestamptz,
  made_at    timestamptz,
  updated_at timestamptz not null default now(),
  primary key (lang, key)
);
create index if not exists akatsuki_audio_todo on akatsuki_audio (status, updated_at) where status in ('wanted','making');

alter table akatsuki_audio enable row level security;
drop policy if exists akatsuki_audio_read on akatsuki_audio;
create policy akatsuki_audio_read on akatsuki_audio for select to authenticated using (user_id = auth.uid());

-- Enqueue: the request is applied at insert.  Only what differs becomes wanted —
-- same text + voice + rate + format already ready is left alone (no re-spend).
create or replace function akatsuki_audio_enqueue() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_voice text; v_rate text; v_fmt text; v_n int;
begin
  if new.kind <> 'audio.wanted' or new.to_app <> 'tts' then return new; end if;
  v_n := jsonb_array_length(coalesce(new.payload->'items','[]'));
  if v_n > 2000 then perform akatsuki_fail('AK110','too_large', format('audio.wanted has %s items — max 2000 per request', v_n)); end if;

  select coalesce(new.payload->>'voice', vo.schema->'values'->(new.payload->>'lang')->>'default')
    into v_voice from akatsuki_vocab vo where vo.user_id = new.user_id and vo.ns = 'enum' and vo.id = 'tts_voice';
  if v_voice is null then perform akatsuki_fail('AK102','missing_field', format('no voice for lang %s', new.payload->>'lang')); end if;
  v_rate := coalesce(new.payload->>'rate', '-15%');
  v_fmt  := coalesce(new.payload->>'format', 'audio-24khz-48kbitrate-mono-mp3');

  insert into akatsuki_audio as a (lang, key, text, kind, voice, rate, format, user_id, req_seq)
  select new.payload->>'lang', i->>'key', normalize(i->>'text', NFC), coalesce(i->>'kind','word'), v_voice, v_rate, v_fmt, new.user_id, new.seq
    from jsonb_array_elements(new.payload->'items') i
   where coalesce(i->>'key','') <> '' and coalesce(i->>'text','') <> ''
  on conflict (lang, key) do update set
    text = excluded.text, kind = excluded.kind, voice = excluded.voice, rate = excluded.rate, format = excluded.format,
    req_seq = excluded.req_seq, status = 'wanted', attempts = 0, error = null, updated_at = now()
  where a.status = 'failed'
     or (a.text, a.voice, a.rate, a.format) is distinct from (excluded.text, excluded.voice, excluded.rate, excluded.format);

  update akatsuki_requests set status = 'delivered', delivered_at = now() where seq = new.seq;
  return new;
end $$;

drop trigger if exists akatsuki_audio_enqueue on akatsuki_requests;
create trigger akatsuki_audio_enqueue after insert on akatsuki_requests
  for each row when (new.kind = 'audio.wanted') execute function akatsuki_audio_enqueue();

-- Claim: N wanted rows, plus 'making' rows stuck > 10 min.  SKIP LOCKED — two runs never share a clip.
create or replace function akatsuki_audio_claim(p_n int default 20)
returns setof akatsuki_audio
language sql security definer set search_path = public, pg_temp as $$
  update akatsuki_audio a set status = 'making', claimed_at = now(), attempts = a.attempts + 1, updated_at = now()
   where (a.lang, a.key) in (
     select lang, key from akatsuki_audio
      where status = 'wanted' or (status = 'making' and claimed_at < now() - interval '10 minutes')
      order by updated_at limit greatest(1, least(p_n, 200))
      for update skip locked)
  returning a.*;
$$;

-- Done: one call per clip.  ok → ready, v+1.  fail → wanted again, failed after 3 attempts.
create or replace function akatsuki_audio_done(p_lang text, p_key text, p_ok boolean, p_bytes int default null, p_error text default null)
returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_v int;
begin
  update akatsuki_audio set
    status  = case when p_ok then 'ready' when attempts >= 3 then 'failed' else 'wanted' end,
    v       = case when p_ok then v + 1 else v end,
    bytes   = case when p_ok then p_bytes else bytes end,
    made_at = case when p_ok then now() else made_at end,
    error   = case when p_ok then null else left(p_error, 500) end,
    updated_at = now()
  where lang = p_lang and key = p_key and status = 'making'
  returning v into v_v;
  return v_v;
end $$;

-- Index: what a learner reads.  {key: v} for every ready clip of one language.
create or replace function akatsuki_audio_index(p_lang text)
returns jsonb
language sql security definer set search_path = public, pg_temp stable as $$
  select coalesce(jsonb_object_agg(key, v), '{}') from akatsuki_audio where lang = p_lang and status = 'ready';
$$;

-- Settle: recompute the reply for every open request.  Writes (and moves reply_seq)
-- only when the reply actually changed — never publish what did not change.
create or replace function akatsuki_audio_settle()
returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; v_new jsonb; n int := 0;
begin
  for r in
    select q.seq, q.reply, q.payload from akatsuki_requests q
     where q.kind = 'audio.wanted' and q.to_app = 'tts'
       and coalesce(q.reply->>'status','queued') <> 'ready'
  loop
    select jsonb_build_object(
      'total',  count(*),
      'ready',  count(*) filter (where a.status = 'ready'),
      'making', count(*) filter (where a.status in ('wanted','making')),
      'failed', count(*) filter (where a.status = 'failed'),
      'status', case when count(*) filter (where a.status = 'ready') = count(*) then 'ready'
                     when count(*) filter (where a.status in ('wanted','making')) = 0 then 'partial'
                     when count(*) filter (where a.status in ('ready','failed')) = 0
                          and count(*) filter (where a.status = 'making') = 0 then 'queued'
                     else 'making' end)
      into v_new
      from jsonb_array_elements(r.payload->'items') i
      join akatsuki_audio a on a.lang = r.payload->>'lang' and a.key = i->>'key';
    if (r.reply - 'at') is distinct from v_new then
      update akatsuki_requests set reply = v_new || jsonb_build_object('at', now()), reply_seq = nextval('akatsuki_seq')
       where seq = r.seq;
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

revoke all on function akatsuki_audio_claim(int), akatsuki_audio_done(text,text,boolean,int,text),
                       akatsuki_audio_index(text), akatsuki_audio_settle() from public, anon, authenticated;
grant execute on function akatsuki_audio_claim(int), akatsuki_audio_done(text,text,boolean,int,text),
                          akatsuki_audio_index(text), akatsuki_audio_settle() to service_role;

-- ═══ C · bucket ═══════════════════════════════════════════════════════════════
-- Public read (learners, signed out).  No write policy: only the service role
-- (akatsuki-tts) writes.  Hyphen, not underscore: bucket ids follow DNS rules.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('akatsuki-audio', 'akatsuki-audio', true, 1048576, '{audio/mpeg,application/json}')
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- ═══ D · schedule — AFTER deploy + one manual run ════════════════════════════
-- 1. supabase functions deploy akatsuki-tts
--    supabase secrets set AZURE_TTS_KEY=… AZURE_TTS_REGION=japaneast TTS_BATCH=20
-- 2. Manual run: curl -X POST https://wylxvmkcrexwfpjpbhyy.supabase.co/functions/v1/akatsuki-tts \
--      -H "Authorization: Bearer <service_role key>"
-- 3. Store the service-role JWT in Vault, then schedule:
--
-- select vault.create_secret('<service_role key>', 'akatsuki_tts_cron');
-- create extension if not exists pg_cron;  create extension if not exists pg_net;
-- select cron.schedule('akatsuki-tts', '* * * * *', $$
--   select net.http_post(
--     url     := 'https://wylxvmkcrexwfpjpbhyy.supabase.co/functions/v1/akatsuki-tts',
--     headers := jsonb_build_object('Content-Type','application/json',
--                  'Authorization','Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'akatsuki_tts_cron')),
--     body    := '{}'::jsonb)
--   where exists (select 1 from akatsuki_audio where status = 'wanted'
--                    or (status = 'making' and claimed_at < now() - interval '10 minutes'));
-- $$);
--
-- Live bar: Scriptura publishes letters for one language → all rows ready →
-- <lang>/_index.json lists them → a clip plays in a signed-out tab → reply 'ready'.
-- update akatsuki_routes set state = 'live' where from_app in ('scriptura','tts') and to_app in ('scriptura','tts');

-- ─────────────────────────────────────────────────────────────────────────────
-- Verify
-- ─────────────────────────────────────────────────────────────────────────────
-- select * from akatsuki_contract where from_app = 'scriptura';
-- select lang, status, count(*), max(v) from akatsuki_audio group by 1,2 order by 1,2;
-- select seq, src_addr->>'id', status, reply from akatsuki_requests where kind = 'audio.wanted' order by seq desc limit 5;
-- select id, public from storage.buckets where id = 'akatsuki-audio';
