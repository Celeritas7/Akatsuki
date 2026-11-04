// setu-map-link — turn a pasted Google / Apple Maps link into { name, lat, lng }.  Setu-owned.
// Short share links (maps.app.goo.gl/…, goo.gl/maps/…) are redirects a web page can't follow (CORS), so this
// follows them server-side, then reads the name and coordinates from the full URL. No API key, no Places quota.
// Signed-in users only: the caller's JWT is checked. Only map hosts are fetched (no open proxy).
// v2: dropped pins (/maps/search/<lat>,<lng>, /maps/place/35°50'39.6"N…, /maps/dir/…/<lat>,<lng>) are read too.
// 2026-11-04 (Akatsuki hub, key migration): the user check uses the new publishable key, falling back to the
// legacy anon key, so it keeps working after the legacy JWT keys are disabled.  Nothing else changed.
// 2026-11-04 (later): deployed with Verify JWT OFF (supabase functions deploy setu-map-link --no-verify-jwt), for the
// JWT signing-key migration: the gateway check only understands the legacy JWT secret. The getUser() check is the gate.
import { createClient } from 'npm:@supabase/supabase-js@2';

// Keys (2026-10-28 key migration): publishable key, legacy anon fallback.
const PUBLIC_KEY = (() => { try { return JSON.parse(Deno.env.get('SUPABASE_PUBLISHABLE_KEYS') || '{}').default; } catch { return null; } })() || Deno.env.get('SUPABASE_ANON_KEY')!;

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-akatsuki-app',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Content-Type': 'application/json',
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: cors });

// hosts we will fetch (redirect hops must stay on these too)
const FETCHABLE = /^(maps\.app\.goo\.gl|goo\.gl|g\.co|(www\.|maps\.)?google\.[a-z.]+|consent\.google\.[a-z.]+|maps\.apple\.com)$/i;

const num = (s: string | null | undefined) => { const n = Number(s); return Number.isFinite(n) ? n : null; };
const okLat = (lat: number | null, lng: number | null) => lat != null && lng != null && Math.abs(lat) <= 90 && Math.abs(lng) <= 180 && !(lat === 0 && lng === 0);
// "35.8443, 139.6472" or 35°50'39.6"N 139°38'50.0"E → [lat, lng]
const DEC = /^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*$/;
const DMS = /^\s*(\d+)°\s*(\d+)['′]\s*([\d.]+)["″]?\s*([NS])[\s,]+(\d+)°\s*(\d+)['′]\s*([\d.]+)["″]?\s*([EW])\s*$/i;
export const coordsOf = (s: string | null): [number, number] | null => { if (!s) return null; let m = s.match(DEC); if (m) return [num(m[1])!, num(m[2])!];
  m = s.match(DMS); if (m) { const v = (d: string, mi: string, se: string, h: string) => (+d + +mi / 60 + +se / 3600) * (/[SW]/i.test(h) ? -1 : 1); return [v(m[1], m[2], m[3], m[4]), v(m[5], m[6], m[7], m[8])]; } return null; };
export function parseMapUrl(raw: string): { name: string | null; lat: number | null; lng: number | null; precise: boolean } {
  let u: URL; try { u = new URL(raw); } catch { return { name: null, lat: null, lng: null, precise: false }; }
  if (/^consent\./i.test(u.hostname) && u.searchParams.get('continue')) return parseMapUrl(u.searchParams.get('continue')!);
  let name: string | null = null, lat: number | null = null, lng: number | null = null, precise = false;
  const path = decodeURIComponent(u.pathname.replace(/\+/g, ' '));
  const place = path.match(/\/maps\/place\/([^/]+)/); if (place) name = place[1].trim();
  // !3d<lat>!4d<lng> is the place itself; @lat,lng is only the camera
  const d = raw.match(/!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)/);
  if (d) { lat = num(d[1]); lng = num(d[2]); precise = true; }
  // a dropped pin: /maps/search/<lat>,<lng>, /maps/place/<lat>,<lng>, /maps/dir/<from>/<lat>,<lng> (decimal or 35°50'39.6"N …)
  if (!okLat(lat, lng)) { const seg = path.match(/\/maps\/(?:search|place|dir\/[^/]*)\/([^/@]+)/); const c = seg && coordsOf(seg[1]);
    if (c) { [lat, lng] = c; precise = true; } }
  if (!okLat(lat, lng)) { const at = path.match(/@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)/); if (at) { lat = num(at[1]); lng = num(at[2]); precise = !!name; } }
  for (const k of ['q', 'query', 'll', 'daddr', 'destination', 'sll']) {
    const v = u.searchParams.get(k); if (!v) continue;
    const c = coordsOf(v);
    if (c) { if (!okLat(lat, lng)) { [lat, lng] = c; precise = true; } }
    else if (!name && (k === 'q' || k === 'query' || k === 'daddr' || k === 'destination')) name = v.trim();
  }
  if (name && coordsOf(name)) name = null;   // a dropped pin's "name" is just its coordinates
  if (!okLat(lat, lng)) { lat = null; lng = null; precise = false; }
  return { name, lat, lng, precise };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { status: 200, headers: cors });
  const auth = req.headers.get('Authorization') || req.headers.get('authorization') || '';
  const sb = createClient(Deno.env.get('SUPABASE_URL')!, PUBLIC_KEY, {
    global: { headers: { Authorization: auth } }, auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: { user } } = await sb.auth.getUser(auth.replace(/^Bearer\s+/i, ''));
  if (!user) return json({ status: 'error', reason: 'not signed in' }, 401);

  let body: any; try { body = await req.json(); } catch { return json({ status: 'error', reason: 'body must be JSON {url}' }, 400); }
  let url = String(body?.url || '').trim();
  const m = url.match(/https?:\/\/\S+/); if (m) url = m[0];   // pasted share text often has words around the link
  let u: URL; try { u = new URL(url); } catch { return json({ status: 'error', reason: 'not a link' }, 400); }
  if (!FETCHABLE.test(u.hostname)) return json({ status: 'error', reason: 'not a Google or Apple Maps link' }, 400);

  // follow redirects ourselves, at most 6 hops, staying on map hosts
  const hops: string[] = [];
  let current = u.toString();
  for (let i = 0; i < 6; i++) {
    const parsed = parseMapUrl(current);
    if (parsed.lat != null || (parsed.name && !/goo\.gl|g\.co$/.test(new URL(current).hostname))) {
      return json({ status: parsed.lat != null ? 'ok' : 'name_only', final_url: current, hops, ...parsed });
    }
    const res = await fetch(current, { redirect: 'manual', headers: { 'User-Agent': 'Mozilla/5.0 (Setu map-link resolver)', 'Accept-Language': 'ja,en' } });
    const loc = res.headers.get('location');
    if (!loc || res.status < 300 || res.status >= 400) {
      // some short links answer 200 with the target in a <meta refresh> or canonical link
      const html = res.status === 200 ? (await res.text()).slice(0, 200000) : '';
      const target = html.match(/<meta[^>]+http-equiv=["']refresh["'][^>]+url=([^"'>]+)/i)?.[1] || html.match(/<link[^>]+rel=["']canonical["'][^>]+href=["']([^"']+)/i)?.[1];
      if (target) { const next = new URL(target.replace(/&amp;/g, '&'), current); if (FETCHABLE.test(next.hostname)) { hops.push(next.toString()); current = next.toString(); continue; } }
      const parsed2 = parseMapUrl(current);
      return json({ status: parsed2.lat != null ? 'ok' : (parsed2.name ? 'name_only' : 'unresolved'), final_url: current, hops, ...parsed2 });
    }
    const next = new URL(loc, current);
    if (!FETCHABLE.test(next.hostname)) return json({ status: 'error', reason: 'redirected off map hosts', final_url: next.toString(), hops }, 400);
    hops.push(next.toString());
    current = next.toString();
  }
  return json({ status: 'unresolved', reason: 'too many redirects', final_url: current, hops });
});
