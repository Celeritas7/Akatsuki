// cross-check — proxies one prompt to the Anthropic Messages API and returns the text.
// Not a hub function: kept here because the hub locked it down (2026-10-28 audit).
// Deploy:  supabase functions deploy cross-check        (Verify JWT ON, and the user is checked in code)
//
// Before 2026-10-28 it was deployed --no-verify-jwt with no check at all: anyone with the URL could run
// Claude on the project's ANTHROPIC_API_KEY.  Now a signed-in user is required — the public key alone gets 401.
// No app in this account was found calling it (Code_sensei uses claude-proxy).  A caller must use
// supabase.functions.invoke('cross-check', { body: { prompt } }) from a signed-in client.
//
//   body:    { prompt: "..." }   (≤ 12 000 characters)
//   returns: { text: "..." }

import { createClient } from 'npm:@supabase/supabase-js@2';

const ANTHROPIC_API_KEY = Deno.env.get('ANTHROPIC_API_KEY');
const MODEL = 'claude-haiku-4-5';
const MAX_TOKENS = 1024;
// Keys (2026-10-28 key migration): publishable key, legacy anon fallback.
const PUBLIC_KEY = (() => { try { return JSON.parse(Deno.env.get('SUPABASE_PUBLISHABLE_KEYS') || '{}').default; } catch { return null; } })() || Deno.env.get('SUPABASE_ANON_KEY')!;

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-akatsuki-app',
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405);

  // A real signed-in user, not just a valid project JWT (the public anon key is one).
  const jwt = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '').trim();
  if (!jwt || jwt.startsWith('sb_')) return json({ error: 'sign in first' }, 401);
  const { data: { user } } = await createClient(Deno.env.get('SUPABASE_URL')!, PUBLIC_KEY, { auth: { persistSession: false } }).auth.getUser(jwt);
  if (!user) return json({ error: 'sign in first' }, 401);

  if (!ANTHROPIC_API_KEY) return json({ error: 'ANTHROPIC_API_KEY not configured' }, 500);
  let body: { prompt?: string };
  try { body = await req.json(); } catch { return json({ error: 'invalid JSON body' }, 400); }
  const prompt = (body.prompt ?? '').trim();
  if (!prompt) return json({ error: 'prompt required' }, 400);
  if (prompt.length > 12_000) return json({ error: 'prompt too long' }, 413);

  try {
    const resp = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-api-key': ANTHROPIC_API_KEY, 'anthropic-version': '2023-06-01' },
      body: JSON.stringify({ model: MODEL, max_tokens: MAX_TOKENS, messages: [{ role: 'user', content: prompt }] }),
    });
    if (!resp.ok) return json({ error: `anthropic ${resp.status}`, detail: await resp.text() }, 502);
    const data = await resp.json();
    const text = (data?.content ?? []).filter((b: any) => b.type === 'text').map((b: any) => b.text).join('\n');
    return json({ text });
  } catch (e) {
    return json({ error: 'proxy failed', detail: String((e as Error)?.message ?? e) }, 500);
  }
});
