// claude-proxy — Code_sensei's Claude calls.  Not a hub function: kept here because the hub capped it (audit 2026-10-28).
// Deploy:  supabase functions deploy claude-proxy --no-verify-jwt
// 2026-11-04: Verify JWT OFF for the JWT signing-key migration (the gateway check only understands the legacy
// JWT secret). It never was the gate: the x-cs-secret header and the daily cap below are.
//
// Gate today: the x-cs-secret header.  That secret ships in Code_sensei's public index.html, so it is NOT a real
// gate — anyone can read it.  Until Code_sensei has sign-in (then: auth.getUser, drop the secret), the damage a
// stranger can do is bounded here instead:
//   · model: always MODEL, whatever the page sends (2026-11-04: claude-sonnet-4-20250514 was retired 2026-06-15)
//   · only system / messages / max_tokens are forwarded; max_tokens ≤ 2000 (default 2000), no streaming, body ≤ 40 KB
//   · 200 calls/day for the whole function (akatsuki_fn_budget_take, R056; day = Asia/Tokyo) → 429 AK210 after
// If the budget check itself fails, the call is refused (fail closed).
//
// 2026-11-04: model → claude-sonnet-5-5, thinking off (`between_tools`, the lowest setting on Sonnet 5.5; thinking
// would otherwise count against the small max_tokens Code_sensei sends), effort low (chat). Server-side refusal
// fallback on. The reply keeps the Messages API shape, but `content` holds only text blocks, so content[0].text
// works; a refusal or an empty reply comes back as an error (502), not as an empty answer.
import { createClient } from 'npm:@supabase/supabase-js@2';

const DAILY_CAP = 200;
const MODEL = 'claude-sonnet-5-5';
const MAX_TOKENS = 2000;
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
  if (body.system != null && typeof body.system !== 'string' && !Array.isArray(body.system)) return json({ error: 'system must be text' }, 400);
  const maxTokens = typeof body.max_tokens === 'number' && body.max_tokens >= 1 && body.max_tokens <= MAX_TOKENS ? Math.floor(body.max_tokens) : MAX_TOKENS;
  // Only these fields reach Anthropic; anything else the page sends (model, thinking, temperature, tools, stream) is dropped.
  const out: Record<string, unknown> = {
    model: MODEL, max_tokens: maxTokens, messages: body.messages,
    thinking: { type: 'between_tools' }, output_config: { effort: 'low' },
    fallbacks: 'default',
  };
  if (body.system != null) out.system = body.system;

  const { error: capErr } = await sb.rpc('akatsuki_fn_budget_take', { p_fn: 'claude-proxy', p_cap: DAILY_CAP });
  if (capErr) {
    const capped = capErr.code === 'AK210' || /AK210/.test(capErr.message);
    console.warn('[claude-proxy]', capped ? 'daily cap reached' : 'budget check failed: ' + capErr.message);
    return json({ error: capped ? `Daily limit of ${DAILY_CAP} AI calls reached. It resets at midnight (Japan time).` : 'Usage check failed; try again later.', code: capped ? 'AK210' : capErr.code }, capped ? 429 : 503);
  }

  try {
    const r = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json', 'x-api-key': apiKey, 'anthropic-version': '2023-06-01',
        // a declined request is re-run server-side on Anthropic's recommended fallback model
        'anthropic-beta': 'server-side-fallback-2026-07-01',
      },
      body: JSON.stringify(out),
    });
    const text = await r.text();
    if (!r.ok) {
      console.warn('[claude-proxy] anthropic', r.status, text.slice(0, 300));
      return new Response(text, { status: r.status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }
    const data = JSON.parse(text);
    // check why it stopped before reading content: a refusal has no usable text
    if (data?.stop_reason === 'refusal') return json({ error: 'Claude declined this request. Try rewording it.', stop_reason: 'refusal' }, 502);
    // keep only text blocks (no thinking / fallback blocks), so callers can read content[0].text
    data.content = (data?.content ?? []).filter((b: any) => b?.type === 'text' && b.text);
    if (!data.content.length) return json({ error: data?.stop_reason === 'max_tokens' ? 'The answer was cut off. Try again.' : 'Claude returned no text. Try again.', stop_reason: data?.stop_reason }, 502);
    return json(data, 200);
  } catch (e) {
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});
