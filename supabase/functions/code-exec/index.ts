// code-exec — server-side proxy to Judge0 CE (RapidAPI).
//
// Why this exists: the public Piston endpoint went whitelist-only on
// 2026-02-15, so code execution moved to Judge0 CE. The RapidAPI key must
// never reach the browser, so it lives here as the JUDGE0_RAPIDAPI_KEY
// secret and this function is the only thing that talks to Judge0.
//
// Auth: a valid Supabase *user* JWT is required. The browser's anon key is
// itself a valid project JWT, so verify_jwt alone is not enough — we call
// auth.getUser() and reject anything without a real signed-in user, so the
// RapidAPI quota can't be burned by anonymous callers.
//
// 2026-11-04 (Akatsuki hub, key migration): the user check now uses the new
// publishable key, falling back to the legacy anon key, so it keeps working
// after the legacy JWT keys are disabled.  Nothing else changed.
//
// Contract with the client (cpp_playground.html):
//   request : { source_code: string, stdin?: string }
//   response: { status:{id,description}, stdout, stderr, compile_output,
//               message, exit_code, time, memory }
// stdout/stderr/compile_output/message are already base64-DECODED here, so
// the browser gets plain text.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const JUDGE0_URL =
  "https://judge0-ce.p.rapidapi.com/submissions?base64_encoded=true&wait=true";
const JUDGE0_HOST = "judge0-ce.p.rapidapi.com";
const CPP_LANGUAGE_ID = 54; // C++ (GCC) in Judge0 CE

// Keys (2026-10-28 key migration): publishable key, legacy anon fallback.
const PUBLIC_KEY = (() => { try { return JSON.parse(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS") || "{}").default; } catch { return null; } })() || Deno.env.get("SUPABASE_ANON_KEY")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// UTF-8 safe base64 (btoa/atob alone only handle latin1).
function b64encode(str: string): string {
  const bytes = new TextEncoder().encode(str);
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}
function b64decode(b64: string | null | undefined): string {
  if (!b64) return "";
  const bin = atob(b64);
  const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
  return new TextDecoder().decode(bytes);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  // --- require a valid signed-in Supabase user ---
  const authHeader = req.headers.get("Authorization") || "";
  if (!authHeader.startsWith("Bearer ")) {
    return json({ error: "Sign in to run code." }, 401);
  }
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    PUBLIC_KEY,
    { global: { headers: { Authorization: authHeader } } },
  );
  const { data: { user }, error: authError } = await supabase.auth.getUser();
  if (authError || !user) {
    return json({ error: "Sign in to run code." }, 401);
  }

  const apiKey = Deno.env.get("JUDGE0_RAPIDAPI_KEY");
  if (!apiKey) return json({ error: "Execution service is not configured." }, 500);

  // --- parse client request ---
  let payload: { source_code?: string; stdin?: string };
  try {
    payload = await req.json();
  } catch {
    return json({ error: "Invalid request body." }, 400);
  }
  const source = payload.source_code ?? "";
  const stdin = payload.stdin ?? "";
  if (!source.trim()) return json({ error: "No source code provided." }, 400);

  // --- call Judge0 ---
  let j0: Response;
  try {
    j0 = await fetch(JUDGE0_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-rapidapi-key": apiKey,
        "x-rapidapi-host": JUDGE0_HOST,
      },
      body: JSON.stringify({
        language_id: CPP_LANGUAGE_ID,
        source_code: b64encode(source),
        stdin: stdin ? b64encode(stdin) : "",
      }),
    });
  } catch (e) {
    return json({ error: "Could not reach the execution service. " + e.message }, 502);
  }

  if (!j0.ok) {
    const detail = await j0.text().catch(() => "");
    return json(
      { error: "Execution service error (" + j0.status + "). " + detail },
      502,
    );
  }

  const r = await j0.json();
  return json({
    status: r.status ?? { id: 0, description: "Unknown" },
    stdout: b64decode(r.stdout),
    stderr: b64decode(r.stderr),
    compile_output: b64decode(r.compile_output),
    message: b64decode(r.message),
    exit_code: typeof r.exit_code === "number" ? r.exit_code : null,
    time: r.time ?? null,
    memory: r.memory ?? null,
  });
});
