// akatsuki-mail — headless producer: purchases found in Gmail → Cost.  R048 (was R037) · Oct 21
// Deploy:  supabase functions deploy akatsuki-mail --no-verify-jwt
//          (no Supabase JWT: Apps Script has none.  A scope='mail' token in akatsuki_ingest_tokens is the credential.)
// Auth:    Authorization: Bearer <token>
// Body:    { kind: 'purchase.detected' | 'purchase.cancelled', payload: {...} }
// Reply:   { status, seq, code }   — status pending | skipped | closed.  Payloads are never logged (item names are personal).
import { createClient } from 'npm:@supabase/supabase-js@2';

// Keys (2026-10-28 key migration): prefer the new secret key, fall back to the legacy service_role key.
const ADMIN_KEY = (() => { try { return JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') || '{}').default; } catch { return null; } })() || Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const sb = createClient(Deno.env.get('SUPABASE_URL')!, ADMIN_KEY, { auth: { persistSession: false } });
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { 'Content-Type': 'application/json' } });
const MAX_BYTES = 8192;
const SOURCES = ['amazon'];

const str = (v: unknown, max: number) => (typeof v === 'string' && v.trim() ? v.trim().slice(0, max) : undefined);
const num = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) ? v : typeof v === 'string' && v.trim() && Number.isFinite(Number(v)) ? Number(v) : undefined);
const iso = (v: unknown) => { const s = str(v, 40); return s && !Number.isNaN(Date.parse(s)) ? new Date(s).toISOString() : undefined; };
const clean = (o: Record<string, unknown>) => Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined));

// Only the contract's fields go through; anything else in the body is dropped here, not stored.
function shape(kind: string, p: any): { payload: Record<string, unknown>; clock?: string } | string {
  const source = str(p?.source, 20), order_id = str(p?.order_id, 40);
  if (!source || !SOURCES.includes(source)) return `source must be one of ${SOURCES.join(', ')}`;
  if (!order_id) return 'order_id is required';
  if (kind === 'purchase.detected') {
    const ordered_at = iso(p.ordered_at), total = num(p.total);
    if (!ordered_at || total === undefined) return 'ordered_at and total are required';
    const items = Array.isArray(p.items)
      ? p.items.slice(0, 30).map((it: any) => clean({ name: str(it?.name, 60), qty: num(it?.qty), price: num(it?.price) })).filter((it: any) => it.name)
      : undefined;
    return { clock: ordered_at, payload: clean({ source, order_id, ordered_at, total, currency: str(p.currency, 3) || 'JPY',
      items: items && items.length ? items : undefined, email_id: str(p.email_id, 64), backfill: p.backfill === true ? true : undefined }) };
  }
  const cancelled_at = iso(p.cancelled_at);
  return { clock: cancelled_at, payload: clean({ source, order_id, refund_total: num(p.refund_total), cancelled_at, email_id: str(p.email_id, 64) }) };
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);
  const token = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '').trim();
  if (!token) return json({ error: 'unauthorized' }, 401);

  const raw = await req.text();
  if (raw.length > MAX_BYTES) return json({ error: 'body too large' }, 413);
  let body: any; try { body = JSON.parse(raw); } catch { return json({ error: 'body must be JSON' }, 400); }

  const kind = body?.kind;
  if (kind !== 'purchase.detected' && kind !== 'purchase.cancelled') return json({ error: 'kind must be purchase.detected or purchase.cancelled' }, 422);
  const s = shape(kind, body.payload);
  if (typeof s === 'string') return json({ error: s }, 422);

  const { source, order_id } = s.payload as { source: string; order_id: string };
  const p = {
    to_app: 'cost', kind,
    src_addr: { source, order_id },
    src_clock: s.clock ?? null,
    payload: s.payload,
    idempotency_key: `${source}:${order_id}:${kind === 'purchase.detected' ? 'detected' : 'cancelled'}`,
  };   // from_app is set by the hub from the token's scope

  const { data, error } = await sb.rpc('akatsuki_publish_ingest', { p_token: token, p });
  if (error) {
    const unauth = error.code === '42501';
    console.warn('[akatsuki-mail]', error.code, unauth ? 'bad token' : error.message);
    if (unauth) return json({ error: 'unauthorized' }, 401);
    return json({ error: error.message, code: error.code }, /^AK1/.test(error.code || '') ? 422 : 500);
  }
  const r = Array.isArray(data) ? data[0] : data;
  console.log('[akatsuki-mail]', kind, r?.status, r?.seq, r?.code ?? '');
  return json({ status: r?.status, seq: r?.seq, code: r?.code ?? null });
});
