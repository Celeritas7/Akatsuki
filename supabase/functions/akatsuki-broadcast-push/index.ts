// akatsuki-broadcast-push — the phone half of broadcasts.  R054 · Oct 28
// Deploy:  supabase functions deploy akatsuki-broadcast-push --no-verify-jwt   (callers checked in code)
// Callers: pg_cron every minute when a broadcast is due (secret key on apikey) → POST {}
//          the hub page, signed in → POST {test: true}: one test notification to the caller's own devices
// VAPID:   the key pair lives in Vault (akatsuki_vapid_public / _private).  The first run makes it; the
//          private key never leaves the server.  Pages read the public half with rpc akatsuki_vapid_public().
// A tapped notification opens the hub, where the overlay is waiting.  The overlay, not the push, is the record:
// a push that fails or never arrives still leaves the broadcast covering every app until Done.
import { createClient } from 'npm:@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';

const URL_ = Deno.env.get('SUPABASE_URL')!;
const SECRET_KEYS: string[] = (() => { try { return Object.values(JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') || '{}')).map(String); } catch { return []; } })();
const ADMIN_KEY = (() => { try { return JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') || '{}').default; } catch { return null; } })() || Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const sb = createClient(URL_, ADMIN_KEY, { auth: { persistSession: false } });
const HUB_URL = 'https://celeritas7.github.io/Akatsuki/#broadcast';
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-akatsuki-app',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Content-Type': 'application/json',
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: cors });

async function isService(req: Request): Promise<boolean> {
  const apikey = (req.headers.get('apikey') || '').trim();
  const bearer = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '').trim();
  return (!!apikey && SECRET_KEYS.includes(apikey)) || (!!bearer && SECRET_KEYS.includes(bearer));
}

// Read the pair, or make it once (first writer wins in akatsuki_vapid_init).
let vapidReady = false;
async function vapid(): Promise<string> {
  const { data, error } = await sb.rpc('akatsuki_vapid_keys');
  if (error) throw new Error('vapid read ' + error.message);
  let row = Array.isArray(data) ? data[0] : data;
  if (!row?.public_key || !row?.private_key) {
    const k = webpush.generateVAPIDKeys();
    const { error: e2 } = await sb.rpc('akatsuki_vapid_init', { p_public: k.publicKey, p_private: k.privateKey });
    if (e2) throw new Error('vapid init ' + e2.message);
    const again = await sb.rpc('akatsuki_vapid_keys');
    row = Array.isArray(again.data) ? again.data[0] : again.data;
  }
  if (!vapidReady) { webpush.setVapidDetails('https://celeritas7.github.io/Akatsuki/', row.public_key, row.private_key); vapidReady = true; }
  return row.public_key;
}

type Sub = { id: string; endpoint: string; p256dh: string; auth: string };
async function deliver(subs: Sub[], message: Record<string, unknown>) {
  let ok = 0; const errors: string[] = [];
  for (const s of subs) {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, JSON.stringify(message), { TTL: 60 * 60 * 24, urgency: 'high' });
      ok++;
      await sb.from('akatsuki_push_subscriptions').update({ last_ok_at: new Date().toISOString(), last_error: null }).eq('id', s.id);
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) { await sb.from('akatsuki_push_subscriptions').delete().eq('id', s.id); errors.push(`gone ${code}`); }
      else { const m = `${code ?? ''} ${(e as Error).message}`.trim().slice(0, 160); errors.push(m); await sb.from('akatsuki_push_subscriptions').update({ last_error: m }).eq('id', s.id); }
    }
  }
  return { ok, errors };
}
const subsOf = async (user_id: string): Promise<Sub[]> =>
  (await sb.from('akatsuki_push_subscriptions').select('id,endpoint,p256dh,auth').eq('user_id', user_id)).data || [];

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);
  const body = await req.json().catch(() => ({}));

  if (await isService(req)) {
    const pub = await vapid();
    const { data: due, error } = await sb.rpc('akatsuki_broadcast_push_claim');
    if (error) return json({ error: error.message }, 500);
    const out: { id: string; note: string }[] = [];
    for (const b of due || []) {
      const subs = await subsOf(b.user_id);
      let note = 'no device switched on for push';
      if (subs.length) {
        const r = await deliver(subs, { title: '🌑 ' + b.title, body: b.body || 'Due now. Open any app to answer.', url: HUB_URL, tag: 'ak-bc-' + b.id, broadcast_id: b.id });
        note = `pushed ${r.ok}/${subs.length}` + (r.errors.length ? ' · ' + r.errors.join('; ') : '');
      }
      await sb.rpc('akatsuki_broadcast_push_note', { p_id: b.id, p_note: note + ' · ' + new Date().toISOString().slice(0, 16) + 'Z' });
      out.push({ id: b.id, note });
    }
    console.log('[akatsuki-broadcast-push]', JSON.stringify(out));
    return json({ vapid: pub ? 'ready' : 'missing', claimed: out.length, out });
  }

  // Signed-in user: test notification to their own devices.
  const bearer = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '').trim();
  if (!bearer || bearer.startsWith('sb_')) return json({ error: 'sign in first' }, 401);
  const { data: u } = await sb.auth.getUser(bearer);
  if (!u?.user) return json({ error: 'sign in first' }, 401);
  if (!body?.test) return json({ error: 'only {test:true} is open to pages' }, 400);
  await vapid();
  const subs = await subsOf(u.user.id);
  if (!subs.length) return json({ error: 'no device switched on for push' }, 404);
  const r = await deliver(subs, { title: '🌑 Akatsuki broadcasts are on', body: 'This is how a due broadcast arrives on this phone.', url: HUB_URL, tag: 'ak-bc-test' });
  return json({ devices: subs.length, delivered: r.ok, errors: r.errors });
});
