// akatsuki-logo-sync — copies each app's own icon from its GitHub Pages site into akatsuki-logos.  R049 (was R038) · Oct 21
// Deploy:  supabase functions deploy akatsuki-logo-sync --no-verify-jwt   (callers checked in code: callerOf)
// Callers: pg_cron (service role, every user's rows) · a signed-in app, e.g. WF after seeding (that user's rows only).
// Body:    { app_keys?: string[], force?: boolean }
//
// Rules (AKATSUKI-REPLY-wf-app-logos.md):
//   · fetches https://celeritas7.github.io/… only; anything else is recorded as host_not_allowed and never fetched
//   · no cookies or credentials; redirects followed only while they stay on that host; page ≤ 1 MB, image ≤ 512 KB
//   · candidates: apple-touch-icon → largest manifest icon ≤ 512 px → rel=icon
//   · PNG or WebP only, ≤ 64 KB as stored (the bucket's limit).  The image is stored as served, not re-encoded:
//     the first candidate that fits wins.  SVG, ICO and JPEG are skipped.
//   · writes only rows whose logo_source is 'site' or null, and only when the content hash changed (unless force)
import { createClient } from 'npm:@supabase/supabase-js@2';

// Keys (2026-10-28 key migration): prefer the new secret key (SUPABASE_SECRET_KEYS.default), fall back to the legacy
// service_role key while it still exists.  Callers may use either; see callerOf().
const URL_ = Deno.env.get('SUPABASE_URL')!;
const SECRET_KEYS: string[] = (() => { try { return Object.values(JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') || '{}')).map(String); } catch { return []; } })();
const ADMIN_KEY = (() => { try { return JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') || '{}').default; } catch { return null; } })() || Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const sb = createClient(URL_, ADMIN_KEY, { auth: { persistSession: false } });
// CORS: browsers send a preflight OPTIONS without the JWT; the gateway lets it through to us.  The bearer JWT
// on the POST is the gate, not the origin (same rule as akatsuki-places-nearby).
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-akatsuki-app',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
const BUCKET = 'akatsuki-logos';
const HOST = 'celeritas7.github.io';
const MAX_PAGE = 1 << 20, MAX_IMAGE = 512 << 10, MAX_STORED = 64 << 10, USER_CAP = 40;

function claimsOf(token: string): any {
  const t = token.split('.')[1];
  if (!t) return null;
  try { return JSON.parse(atob(t.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(t.length / 4) * 4, '='))); } catch { return null; }
}
// Who is calling.  Verify JWT is OFF at the gateway (new keys are not JWTs), so every path is checked here.
//   service: apikey (or bearer) is one of the project's secret keys, or a legacy service_role JWT the admin API accepts
//   user:    a signed-in user's access token, confirmed by Auth (getUser)
async function callerOf(req: Request): Promise<{ service: true } | { user: string } | null> {
  const apikey = (req.headers.get('apikey') || '').trim();
  const bearer = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '').trim();
  if (apikey && SECRET_KEYS.includes(apikey)) return { service: true };
  if (bearer && SECRET_KEYS.includes(bearer)) return { service: true };
  if (!bearer || bearer.startsWith('sb_')) return null;
  const c = claimsOf(bearer);
  if (c?.role === 'service_role') {
    const probe = createClient(URL_, bearer, { auth: { persistSession: false } });
    const { error } = await probe.auth.admin.listUsers({ page: 1, perPage: 1 });
    return error ? null : { service: true };
  }
  if (c?.role === 'authenticated') {
    const { data } = await sb.auth.getUser(bearer);
    return data?.user ? { user: data.user.id } : null;
  }
  return null;
}

const onHost = (u: URL) => u.protocol === 'https:' && u.hostname === HOST;

// fetch that stays on HOST, sends nothing identifying, and stops reading at `max` bytes
async function get(url: URL, max: number): Promise<{ bytes: Uint8Array; type: string; url: URL } | string> {
  let cur = url;
  for (let hop = 0; hop < 4; hop++) {
    if (!onHost(cur)) return 'redirect_off_host';
    const res = await fetch(cur, { redirect: 'manual', credentials: 'omit', headers: { 'User-Agent': 'akatsuki-logo-sync' } });
    if (res.status >= 300 && res.status < 400) {
      const loc = res.headers.get('location'); await res.body?.cancel();
      if (!loc) return `http_${res.status}`;
      cur = new URL(loc, cur); continue;
    }
    if (!res.ok) { await res.body?.cancel(); return `http_${res.status}`; }
    const len = Number(res.headers.get('content-length') || 0);
    if (len > max) { await res.body?.cancel(); return 'too_large'; }
    const reader = res.body!.getReader(); const parts: Uint8Array[] = []; let n = 0;
    for (;;) {
      const { done, value } = await reader.read(); if (done) break;
      n += value.length; if (n > max) { await reader.cancel(); return 'too_large'; }
      parts.push(value);
    }
    const bytes = new Uint8Array(n); let o = 0; for (const p of parts) { bytes.set(p, o); o += p.length; }
    return { bytes, type: (res.headers.get('content-type') || '').split(';')[0].trim(), url: cur };
  }
  return 'too_many_redirects';
}

const attr = (tag: string, name: string) => (tag.match(new RegExp(`\\b${name}\\s*=\\s*("([^"]*)"|'([^']*)'|([^\\s>]+))`, 'i')) || [])
  .slice(2).find((x) => x != null) ?? null;
const sizeOf = (s: string | null | undefined) => Math.max(0, ...String(s || '').split(/\s+/).map((x) => Number(x.split('x')[0]) || 0));

function kind(b: Uint8Array): 'png' | 'webp' | null {
  if (b.length > 24 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return 'png';
  if (b.length > 12 && String.fromCharCode(...b.slice(0, 4)) === 'RIFF' && String.fromCharCode(...b.slice(8, 12)) === 'WEBP') return 'webp';
  return null;
}
function pngSquare(b: Uint8Array) {
  const v = new DataView(b.buffer, b.byteOffset); const w = v.getUint32(16), h = v.getUint32(20);
  return w === h && w >= 64;
}

async function candidates(home: URL): Promise<URL[] | string> {
  const page = await get(home, MAX_PAGE);
  if (typeof page === 'string') return 'page_' + page;
  const html = new TextDecoder().decode(page.bytes);
  const links = [...html.matchAll(/<link\b[^>]*>/gi)].map((m) => m[0]);
  const rel = (t: string) => (attr(t, 'rel') || '').toLowerCase().split(/\s+/);
  const abs = (h: string | null) => { try { return h ? new URL(h, page.url) : null; } catch { return null; } };
  const out: URL[] = [];
  links.filter((t) => rel(t).includes('apple-touch-icon')).sort((a, b) => sizeOf(attr(b, 'sizes')) - sizeOf(attr(a, 'sizes')))
    .forEach((t) => { const u = abs(attr(t, 'href')); if (u) out.push(u); });
  const mf = abs(attr(links.find((t) => rel(t).includes('manifest')) || '', 'href'));
  if (mf && onHost(mf)) {
    const m = await get(mf, 100 << 10);
    if (typeof m !== 'string') {
      try {
        const icons = (JSON.parse(new TextDecoder().decode(m.bytes)).icons || []) as any[];
        icons.filter((i) => sizeOf(i.sizes) <= 512 && !/svg/i.test(i.type || i.src || ''))
          .sort((a, b) => sizeOf(b.sizes) - sizeOf(a.sizes))
          .forEach((i) => { try { if (i.src) out.push(new URL(i.src, m.url)); } catch { /* bad src */ } });
      } catch { /* bad manifest: fall through to rel=icon */ }
    }
  }
  links.filter((t) => rel(t).includes('icon') && !rel(t).includes('apple-touch-icon')).sort((a, b) => sizeOf(attr(b, 'sizes')) - sizeOf(attr(a, 'sizes')))
    .forEach((t) => { const u = abs(attr(t, 'href')); if (u) out.push(u); });
  const seen = new Set<string>();
  return out.filter((u) => onHost(u) && !/\.(svg|ico)(\?|$)/i.test(u.pathname) && !seen.has(u.href) && seen.add(u.href));
}

async function syncRow(row: any, force: boolean): Promise<string> {
  let home: URL; try { home = new URL(row.home_url); } catch { return 'bad_home_url'; }
  if (!onHost(home)) return 'host_not_allowed';
  const list = await candidates(home);
  if (typeof list === 'string') return list;
  if (!list.length) return 'no_icon';
  let last = 'no_usable_icon';
  for (const u of list) {
    const img = await get(u, MAX_IMAGE);
    if (typeof img === 'string') { last = 'icon_' + img; continue; }
    const k = kind(img.bytes);
    if (!k) { last = 'not_png_or_webp'; continue; }
    if (img.bytes.length > MAX_STORED) { last = 'over_64kb'; continue; }
    if (k === 'png' && !pngSquare(img.bytes)) { last = 'not_square'; continue; }
    const hash = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', img.bytes))).map((x) => x.toString(16).padStart(2, '0')).join('').slice(0, 16);
    if (!force && hash === row.logo_hash) return 'unchanged';
    const path = `${row.user_id}/${row.app_key}/${hash}.${k}`;
    const up = await sb.storage.from(BUCKET).upload(path, img.bytes, { contentType: `image/${k}`, upsert: true, cacheControl: '31536000' });
    if (up.error) return 'upload_' + up.error.message.slice(0, 80);
    const { data: done, error } = await sb.from('akatsuki_app_identity')
      .update({ logo_path: path, logo_hash: hash, logo_source: 'site', updated_at: new Date().toISOString(), updated_by: 'akatsuki-logo-sync' })
      .eq('user_id', row.user_id).eq('app_key', row.app_key).or('logo_source.is.null,logo_source.eq.site').select('app_key');
    if (error) return 'db_' + error.message.slice(0, 80);
    if (!done?.length) { await sb.storage.from(BUCKET).remove([path]); return 'skipped_user_choice'; }   // set to upload/emoji meanwhile
    if (row.logo_path && row.logo_path !== path && row.logo_path.startsWith(`${row.user_id}/${row.app_key}/`)) await sb.storage.from(BUCKET).remove([row.logo_path]);
    return 'ok';
  }
  return last;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { status: 200, headers: CORS });
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);
  const who = await callerOf(req);
  if (!who) return json({ error: 'sign in, or call with a secret key' }, 401);
  const userId: string | null = 'user' in who ? who.user : null;

  const body = await req.json().catch(() => ({}));
  const keys = Array.isArray(body.app_keys) ? body.app_keys.filter((k: unknown) => typeof k === 'string').slice(0, 100) : null;
  let q = sb.from('akatsuki_app_identity').select('user_id,app_key,home_url,logo_path,logo_hash,logo_source')
    .is('retired_at', null).not('home_url', 'is', null).or('logo_source.is.null,logo_source.eq.site').order('app_key');
  if (userId) q = q.eq('user_id', userId).limit(USER_CAP);
  if (keys) q = q.in('app_key', keys);
  const { data: rows, error } = await q;
  if (error) return json({ error: error.message }, 500);

  const out: Record<string, string> = {};
  for (const row of rows || []) {
    let s: string;
    try { s = await syncRow(row, !!body.force); } catch (e) { s = 'error_' + String((e as Error).message).slice(0, 80); }
    out[row.app_key] = s;
    await sb.from('akatsuki_app_identity').update({ sync_status: s, synced_at: new Date().toISOString() })
      .eq('user_id', row.user_id).eq('app_key', row.app_key);
    await new Promise((r) => setTimeout(r, 300));
  }
  const counts = Object.values(out).reduce((a: Record<string, number>, s) => ((a[s] = (a[s] || 0) + 1), a), {});
  console.log('[akatsuki-logo-sync]', counts);
  return json({ rows: Object.keys(out).length, counts, apps: out });
});
