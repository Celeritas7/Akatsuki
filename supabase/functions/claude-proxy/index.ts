// claude-proxy — Code_sensei's Claude calls.  Not a hub function: kept here because the hub capped it (audit 2026-10-28).
// Deploy:  supabase functions deploy claude-proxy        (Verify JWT ON, as before)
//
// Gate today: the x-cs-secret header.  That secret ships in Code_sensei's public index.html, so it is NOT a real
// gate — anyone can read it.  Until Code_sensei has sign-in (then: auth.getUser, drop the secret), the damage a
// stranger can do is bounded here instead:
//   · model: Sonnet or Haiku only; anything else (or none) → DEFAULT_MODEL
//   · max_tokens ≤ 2000, no streaming, body ≤ 40 KB
//   · 200 calls/day for the whole function (akatsuki_fn_budget_take, R056; day = Asia/Tokyo) → 429 AK210 after
// If the budget check itself fails, the call is refused (fail closed).
import { createClient } from 'npm:@supabase/supabase-js@2';

const DAILY_CAP = 200;
const DEFAULT_MODEL = 'claude-sonnet-4-20250514';   // what Code_sensei asks for today
const ALLOWED = /^claude-(sonnet|haiku)-/;
const ADMIN_KEY = (() => { try { return JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') || '{}').default; } catch { return null; } })() || Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const sb = createClient(Deno.env.get('SUPABASE_URL')!, ADMIN_KEY, { auth: { persistSession: false } });

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cs-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (obj: unknown, status: number) =>
  new Response(JSON.stringify(obj), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const secret = Deno.env.get('CS_SHARED_SECRET');
  if (!secret) return json({ error: 'CS_SHARED_SECRET not configured on the server' }, 500);
  if (req.headers.get('x-cs-secret') !== secret) return json({ error: 'Forbidden' }, 403);
  const apiKey = Deno.env.get('ANTHROPIC_API_KEY');
  if (!apiKey) return json({ error: 'ANTHROPIC_API_KEY not configured on the server' }, 500);

  const raw = await req.text();
  if (raw.length > 40_000) return json({ error: 'Request too large' }, 413);
  let body: any;
  try { body = JSON.parse(raw); } catch { return json({ error: 'Body must be JSON' }, 400); }
  if (!body || !Array.isArray(body.messages)) return json({ error: 'messages required' }, 400);
  if (typeof body.model !== 'string' || !ALLOWED.test(body.model)) body.model = DEFAULT_MODEL;
  if (typeof body.max_tokens !== 'number' || body.max_tokens > 2000 || body.max_tokens < 1) body.max_tokens = 2000;
  delete body.stream;

  const { error: capErr } = await sb.rpc('akatsuki_fn_budget_take', { p_fn: 'claude-proxy', p_cap: DAILY_CAP });
  if (capErr) {
    const capped = capErr.code === 'AK210' || /AK210/.test(capErr.message);
    console.warn('[claude-proxy]', capped ? 'daily cap reached' : 'budget check failed: ' + capErr.message);
    return json({ error: capped ? `Daily limit of ${DAILY_CAP} AI calls reached. It resets at midnight (Japan time).` : 'Usage check failed; try again later.', code: capped ? 'AK210' : capErr.code }, capped ? 429 : 503);
  }

  try {
    const r = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-api-key': apiKey, 'anthropic-version': '2023-06-01' },
      body: JSON.stringify(body),
    });
    return new Response(await r.text(), { status: r.status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
  } catch (e) {
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});
