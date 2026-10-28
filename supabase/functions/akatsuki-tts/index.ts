// akatsuki-tts — the hub's speech generator.  R019 · Sep 26
// Deploy:  supabase functions deploy akatsuki-tts --no-verify-jwt   (service callers checked in code: isService)
// Secrets: AZURE_TTS_KEY, AZURE_TTS_REGION (e.g. japaneast), TTS_BATCH (default 20)
// Invoked by pg_cron (R019 D) or by hand with the service-role key. Never by a page.
import { createClient } from 'npm:@supabase/supabase-js@2';

// Keys (2026-10-28 key migration): prefer the new secret key, fall back to the legacy service_role key.
const URL_ = Deno.env.get('SUPABASE_URL')!;
const SECRET_KEYS: string[] = (() => { try { return Object.values(JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') || '{}')).map(String); } catch { return []; } })();
const ADMIN_KEY = (() => { try { return JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') || '{}').default; } catch { return null; } })() || Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const sb = createClient(URL_, ADMIN_KEY, { auth: { persistSession: false } });

// Service callers only (pg_cron).  Verify JWT is off at the gateway, so the check is here: a project secret key on
// apikey/bearer, or a legacy service_role JWT the admin API accepts.  Before this, any valid JWT (even the public
// anon key) could start Azure synthesis.
async function isService(req: Request): Promise<boolean> {
  const apikey = (req.headers.get('apikey') || '').trim();
  const bearer = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '').trim();
  if ((apikey && SECRET_KEYS.includes(apikey)) || (bearer && SECRET_KEYS.includes(bearer))) return true;
  if (!bearer || bearer.startsWith('sb_')) return false;
  try {
    const t = bearer.split('.')[1];
    const role = JSON.parse(atob(t.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(t.length / 4) * 4, '='))).role;
    if (role !== 'service_role') return false;
  } catch { return false; }
  const { error } = await createClient(URL_, bearer, { auth: { persistSession: false } }).auth.admin.listUsers({ page: 1, perPage: 1 });
  return !error;
}
const KEY = Deno.env.get('AZURE_TTS_KEY')!, REGION = Deno.env.get('AZURE_TTS_REGION')!;
const BATCH = Number(Deno.env.get('TTS_BATCH') || 20);
const BUCKET = 'akatsuki-audio';
const XML_LANG: Record<string, string> = {
  burmese: 'my-MM', hindi: 'hi-IN', telugu: 'te-IN', sinhala: 'si-LK', tamil: 'ta-IN',
  hiragana: 'ja-JP', katakana: 'ja-JP', korean: 'ko-KR', chinese: 'zh-CN',
};
const esc = (s: string) => s.replace(/[<>&'"]/g, (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', "'": '&apos;', '"': '&quot;' }[c]!));

async function speak(row: any): Promise<Uint8Array> {
  const lang = XML_LANG[row.lang] || row.voice.slice(0, 5);
  const ssml = `<speak version='1.0' xml:lang='${lang}'><voice name='${row.voice}'><prosody rate='${row.rate}'>${esc(row.text)}</prosody></voice></speak>`;
  const res = await fetch(`https://${REGION}.tts.speech.microsoft.com/cognitiveservices/v1`, {
    method: 'POST',
    headers: { 'Ocp-Apim-Subscription-Key': KEY, 'Content-Type': 'application/ssml+xml', 'X-Microsoft-OutputFormat': row.format, 'User-Agent': 'akatsuki-tts' },
    body: ssml,
  });
  if (res.status === 429) throw Object.assign(new Error('azure 429 — throttled'), { throttled: true });
  if (!res.ok) throw new Error(`azure ${res.status} ${(await res.text()).slice(0, 200)}`);
  return new Uint8Array(await res.arrayBuffer());
}

Deno.serve(async (req) => {
  if (!(await isService(req))) return new Response(JSON.stringify({ error: 'service only' }), { status: 401 });
  const missing = ['AZURE_TTS_KEY', 'AZURE_TTS_REGION'].filter((n) => !Deno.env.get(n));
  if (missing.length) return new Response(JSON.stringify({ error: 'missing secrets: ' + missing.join(', ') }), { status: 500 });
  const { data: rows, error } = await sb.rpc('akatsuki_audio_claim', { p_n: BATCH });
  if (error) return new Response(JSON.stringify({ error: error.message }), { status: 500 });
  const langs = new Set<string>(); let ok = 0, failed = 0, throttled = false;

  for (const row of rows || []) {
    if (throttled) { await sb.rpc('akatsuki_audio_done', { p_lang: row.lang, p_key: row.key, p_ok: false, p_error: 'throttled — retried next run' }); continue; }
    try {
      const mp3 = await speak(row);
      const up = await sb.storage.from(BUCKET).upload(row.path, mp3, { contentType: 'audio/mpeg', upsert: true, cacheControl: '31536000' });
      if (up.error) throw new Error('upload ' + up.error.message);
      await sb.rpc('akatsuki_audio_done', { p_lang: row.lang, p_key: row.key, p_ok: true, p_bytes: mp3.byteLength });
      langs.add(row.lang); ok++;
    } catch (e) {
      if ((e as any).throttled) throttled = true;
      await sb.rpc('akatsuki_audio_done', { p_lang: row.lang, p_key: row.key, p_ok: false, p_error: String((e as Error).message) });
      failed++;
    }
  }

  for (const lang of langs) {   // the learner's one read — short cache, the index moves
    const { data: idx } = await sb.rpc('akatsuki_audio_index', { p_lang: lang });
    await sb.storage.from(BUCKET).upload(`${lang}/_index.json`, new Blob([JSON.stringify(idx || {})], { type: 'application/json' }), { upsert: true, cacheControl: '60' });
  }
  const { data: settled } = await sb.rpc('akatsuki_audio_settle');
  console.log('[akatsuki-tts]', { claimed: rows?.length || 0, ok, failed, throttled, langs: [...langs], settled });
  return new Response(JSON.stringify({ claimed: rows?.length || 0, ok, failed, throttled, settled }), { headers: { 'Content-Type': 'application/json' } });
});
