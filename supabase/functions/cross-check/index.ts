// cross-check — asks Claude to stress-test one Sigma score and returns the text.
// Deploy:  supabase functions deploy cross-check --no-verify-jwt        (the user is checked in code)
// 2026-11-04 (Akatsuki hub): Verify JWT OFF for the JWT signing-key migration (the gateway check only
// understands the legacy JWT secret). Code otherwise the same as Sigma's live v13.
//
// 2026-10-28: locked down to signed-in users (before, it ran --no-verify-jwt
// with no check, so anyone with the URL could use the ANTHROPIC_API_KEY).
// 2026-11: the client no longer sends a prompt. It sends the ids of the score
// to check, and the prompt is built here from rows read with the caller's own
// token, so row-level security limits it to the caller's own decisions and it
// can't be used as a general-purpose Claude proxy.
//
//   body:    { option_id: uuid, parameter_id: uuid }
//   returns: { text: "..." }
//
// 2026-11-04: moved from claude-haiku-4-5 to claude-opus-5-5. Opus 5.5 always
// thinks (it can't be turned off), and the thinking counts toward max_tokens,
// so max_tokens is sized for thinking plus the short reply. Effort is the
// speed/cost dial: 'low' keeps the popup quick; raise to 'medium' (the
// model's default) if the critiques feel thin. A safety decline
// (stop_reason 'refusal') is retried server-side on Anthropic's recommended
// fallback model; if the whole chain declines, the caller gets an error.

import { createClient } from 'npm:@supabase/supabase-js@2';

const ANTHROPIC_API_KEY = Deno.env.get('ANTHROPIC_API_KEY');
const MODEL = 'claude-opus-5-5';
const EFFORT = 'low';
// thinking + a 3-5 bullet reply; thinking text isn't returned but is counted
const MAX_TOKENS = 8000;
// Keys (2026-10-28 key migration): publishable key, legacy anon fallback.
const PUBLIC_KEY = (() => { try { return JSON.parse(Deno.env.get('SUPABASE_PUBLISHABLE_KEYS') || '{}').default; } catch { return null; } })() || Deno.env.get('SUPABASE_ANON_KEY')!;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-akatsuki-app',
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });

type Param = { id: string; decision_id: string; name: string; input_type: string | null; unit: string | null };
type Option = { id: string; decision_id: string; name: string };
type Score = { option_id: string; value: number | null; notes: string | null };

function buildPrompt(param: Param, option: Option, score: Score | undefined, peers: { name: string; value: number | null; raw: string | null }[]) {
  const num = (v: number | null) => (v == null ? '—' : Number(v).toFixed(1) + '/10');
  return `You are a thoughtful decision-coach helping the user stress-test their own ratings on a weighted-decision tool. Your goal is to push back when you see possible bias — anchoring, halo effect, recency, motivated reasoning — not to be agreeable.

Decision context:
- Consideration: "${param.name}" (type: ${param.input_type || 'text'}${param.unit ? `, unit: ${param.unit}` : ''})
- Option being scored: "${option.name}"
- Raw evidence the user wrote: ${score?.notes ? `"${score.notes}${param.unit ? ' ' + param.unit : ''}"` : '(none)'}
- User's score: ${score?.value != null ? `${score.value} / 10` : '(unset)'}

How the user scored peer options on this same consideration:
${peers.length === 0 ? '(no peers scored yet)' : peers.map(p => `- "${p.name}": ${num(p.value)}${p.raw ? `  (raw: "${p.raw}")` : ''}`).join('\n')}

Respond in 3-5 short bullet points, conversational, second person. Focus on:
1. Whether the score is internally consistent with the raw evidence.
2. Whether the score is consistent with peer scores (e.g. if peer has worse raw but higher score, flag it).
3. One concrete bias risk to consider.
4. Suggest a tighter score range if you'd nudge it.

Be direct, not soft. No preamble, no recap, no "great question". Use plain text, no markdown headers.`;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405);

  // A real signed-in user, not just a valid project JWT (the public anon key is one).
  const jwt = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '').trim();
  if (!jwt || jwt.startsWith('sb_')) return json({ error: 'sign in first' }, 401);
  // reads go through RLS as this user
  const db = createClient(Deno.env.get('SUPABASE_URL')!, PUBLIC_KEY, {
    auth: { persistSession: false },
    global: { headers: { Authorization: `Bearer ${jwt}` } },
  });
  const { data: { user } } = await db.auth.getUser(jwt);
  if (!user) return json({ error: 'sign in first' }, 401);

  if (!ANTHROPIC_API_KEY) return json({ error: 'ANTHROPIC_API_KEY not configured' }, 500);
  let body: { option_id?: string; parameter_id?: string };
  try { body = await req.json(); } catch { return json({ error: 'invalid JSON body' }, 400); }
  const { option_id, parameter_id } = body;
  if (!UUID.test(option_id ?? '') || !UUID.test(parameter_id ?? '')) return json({ error: 'option_id and parameter_id required' }, 400);

  const [pRes, oRes] = await Promise.all([
    db.from('sigma_parameters').select('id, decision_id, name, input_type, unit').eq('id', parameter_id).maybeSingle(),
    db.from('sigma_options').select('id, decision_id, name').eq('id', option_id).maybeSingle(),
  ]);
  if (pRes.error || oRes.error) return json({ error: 'lookup failed', detail: (pRes.error || oRes.error)!.message }, 500);
  const param = pRes.data as Param | null, option = oRes.data as Option | null;
  // not found, or not the caller's (RLS hides other users' rows)
  if (!param || !option || param.decision_id !== option.decision_id) return json({ error: 'not found' }, 404);

  const [allOpts, sRes] = await Promise.all([
    db.from('sigma_options').select('id, decision_id, name').eq('decision_id', param.decision_id),
    db.from('sigma_scores').select('option_id, value, notes').eq('parameter_id', param.id),
  ]);
  if (allOpts.error || sRes.error) return json({ error: 'lookup failed', detail: (allOpts.error || sRes.error)!.message }, 500);
  const scores = (sRes.data ?? []) as Score[];
  const score = scores.find(s => s.option_id === option.id);
  if (score?.value == null) return json({ error: 'set a score first' }, 400);
  const peers = ((allOpts.data ?? []) as Option[])
    .filter(o => o.id !== option.id)
    .map(o => { const s = scores.find(x => x.option_id === o.id); return { name: o.name, value: s?.value ?? null, raw: s?.notes ?? null }; })
    .filter(p => p.value != null || p.raw);

  try {
    const resp = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json', 'x-api-key': ANTHROPIC_API_KEY, 'anthropic-version': '2023-06-01',
        // re-run a safety decline on Anthropic's recommended fallback model
        'anthropic-beta': 'server-side-fallback-2026-07-01',
      },
      body: JSON.stringify({
        model: MODEL, max_tokens: MAX_TOKENS,
        output_config: { effort: EFFORT },
        fallbacks: 'default',
        messages: [{ role: 'user', content: buildPrompt(param, option, score, peers) }],
      }),
    });
    if (!resp.ok) return json({ error: `anthropic ${resp.status}`, detail: await resp.text() }, 502);
    const data = await resp.json();
    // check why it stopped before reading content: a refusal has no usable text
    if (data?.stop_reason === 'refusal') return json({ error: "Claude declined to review this score. Try rewording the evidence." }, 502);
    // content also holds thinking blocks (empty text) and, after a fallback, a fallback block: keep only text
    const text = (data?.content ?? []).filter((b: any) => b.type === 'text').map((b: any) => b.text).join('\n').trim();
    if (!text) return json({ error: data?.stop_reason === 'max_tokens' ? 'The answer was cut off. Try again.' : 'Claude returned no text. Try again.' }, 502);
    return json({ text });
  } catch (e) {
    return json({ error: 'proxy failed', detail: String((e as Error)?.message ?? e) }, 500);
  }
});
