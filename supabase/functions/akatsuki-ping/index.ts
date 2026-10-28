// akatsuki-ping — background location in.  R034 · Oct 14
// OwnTracks (HTTP mode) posts here; we hand the fix to akatsuki_ping() and drop it.  Nothing raw is stored.
// Deploy:  supabase functions deploy akatsuki-ping --no-verify-jwt
//          (no JWT: the phone has none.  The per-device token in akatsuki_ingest_tokens is the credential.)
// Auth:    Authorization: Basic base64(<anything>:<token>)   — OwnTracks "Username / Password" fields
//      or  ?token=<token>                                     — fallback for other senders (Tasker etc.)
// Reply:   always a JSON array ([]) — OwnTracks expects one and shows an error otherwise.
import { createClient } from 'npm:@supabase/supabase-js@2';

// Keys (2026-10-28 key migration): prefer the new secret key, fall back to the legacy service_role key.
const ADMIN_KEY = (() => { try { return JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') || '{}').default; } catch { return null; } })() || Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const sb = createClient(Deno.env.get('SUPABASE_URL')!, ADMIN_KEY, { auth: { persistSession: false } });

function tokenOf(req: Request): string | null {
  const auth = req.headers.get('authorization') || '';
  if (/^basic /i.test(auth)) {
    try { const [, pw] = atob(auth.slice(6)).split(/:(.*)/s); if (pw) return pw.trim(); } catch { /* fall through */ }
  }
  if (/^bearer /i.test(auth)) return auth.slice(7).trim();
  return new URL(req.url).searchParams.get('token');
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('[]', { status: 405, headers: { 'content-type': 'application/json' } });
  const token = tokenOf(req);
  if (!token) return new Response('[]', { status: 401, headers: { 'content-type': 'application/json' } });
  let body: any = null;
  try { body = await req.json(); } catch { return new Response('[]', { status: 400, headers: { 'content-type': 'application/json' } }); }

  // OwnTracks sends many _type values (lwt, waypoint, transition…).  Only a location is a fix.
  if (!body || body._type !== 'location' || typeof body.lat !== 'number' || typeof body.lon !== 'number')
    return new Response('[]', { headers: { 'content-type': 'application/json' } });

  const t = new Date((body.tst ? Number(body.tst) : Date.now() / 1000) * 1000).toISOString();
  const acc = body.acc == null ? null : Math.round(Number(body.acc));
  const { data, error } = await sb.rpc('akatsuki_ping', { p_token: token, p_lat: body.lat, p_lng: body.lon, p_acc_m: acc, p_t: t });
  if (error) {
    const unauth = error.code === '42501';
    console.warn('[akatsuki-ping]', error.code, error.message);
    return new Response('[]', { status: unauth ? 401 : 500, headers: { 'content-type': 'application/json' } });
  }
  console.log('[akatsuki-ping]', JSON.stringify(data));
  return new Response('[]', { headers: { 'content-type': 'application/json' } });
});
