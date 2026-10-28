// fare-lookup — Cost's old Ekispert fare lookup.  Retires when akatsuki-fare (R052) ships.
// Deploy:  supabase functions deploy fare-lookup        (Verify JWT on, as before; the signed-in user is also checked in code)
// 2026-10-28 audit: the public key alone could spend Ekispert calls; now a signed-in user is required.
// Known bug left as is (the replacement fixes it): both ekispert() calls omit the key argument, so lookups fail.
import { createClient } from "npm:@supabase/supabase-js@2";

const PUBLIC_KEY = (() => { try { return JSON.parse(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS") || "{}").default; } catch { return null; } })() || Deno.env.get("SUPABASE_ANON_KEY")!;
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-akatsuki-app",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const fail = (reason: string) => json({ error: true, reason });

async function ekispert(path: string, params: Record<string, string>, key: string) {
  const url = new URL(`https://api.ekispert.jp/v1/json/${path}`);
  url.searchParams.set("key", key);
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
  const res = await fetch(url.toString());
  if (!res.ok) throw new Error(`ekispert ${path} HTTP ${res.status}`);
  return await res.json();
}

async function stationCode(name: string, key: string): Promise<string | null> {
  const data = await ekispert("station", { name });
  let pts = data?.ResultSet?.Point;
  if (!pts) return null;
  if (!Array.isArray(pts)) pts = [pts];
  return pts[0]?.Station?.code ?? null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "").trim();
  const { data: who } = !jwt || jwt.startsWith("sb_") ? { data: null } : await createClient(Deno.env.get("SUPABASE_URL")!, PUBLIC_KEY, { auth: { persistSession: false } }).auth.getUser(jwt);
  if (!who?.user) return json({ error: true, reason: "sign in first" }, 401);
  try {
    const key = Deno.env.get("EKISPERT_API_KEY");
    if (!key) return fail("EKISPERT_API_KEY not configured");
    const { from_station, to_station } = await req.json();
    if (!from_station || !to_station) return fail("from_station and to_station required");

    const [fromCode, toCode] = await Promise.all([
      stationCode(String(from_station), key),
      stationCode(String(to_station), key),
    ]);
    if (!fromCode) return fail(`station not found: ${from_station}`);
    if (!toCode) return fail(`station not found: ${to_station}`);

    const data = await ekispert("search/course/extreme", {
      viaList: `${fromCode}:${toCode}`,
      searchType: "plain",
      answerCount: "1",
      addOperationLinePattern: "false",
    });
    let course = data?.ResultSet?.Course;
    if (!course) return fail("no route found");
    if (Array.isArray(course)) course = course[0];

    let prices = course?.Price ?? [];
    if (!Array.isArray(prices)) prices = [prices];
    let fareTicket: number | null = null;
    let fareIC: number | null = null;
    for (const p of prices) {
      const kind = p?.kind ?? "";
      const oneway = Number(p?.Oneway);
      if (!Number.isFinite(oneway)) continue;
      if (kind === "FareSummary" && fareTicket == null) fareTicket = oneway;
      if ((kind === "FareSummaryIC" || kind === "ICFareSummary" || p?.fareKind === "ic") && fareIC == null) fareIC = oneway;
    }
    if (fareIC == null) fareIC = fareTicket;
    if (fareIC == null) return fail("fare not present in response");

    const route = course?.Route ?? {};
    let pts = route?.Point ?? [];
    if (!Array.isArray(pts)) pts = [pts];
    const via_stations = pts.slice(1, -1).map((p: { Station?: { Name?: string } }) => p?.Station?.Name).filter(Boolean);
    let lines = route?.Line ?? [];
    if (!Array.isArray(lines)) lines = [lines];
    const route_summary = lines.map((l: { Name?: string }) => l?.Name).filter(Boolean).join(" → ");
    const distance_km = route?.distance != null ? Number(route.distance) / 10 : null;
    const transfers = route?.transferCount != null ? Number(route.transferCount) : Math.max(0, lines.length - 1);

    return json({ fare_ic: fareIC, fare_ticket: fareTicket, distance_km, route_summary, transfers, via_stations });
  } catch (e) {
    return fail(e instanceof Error ? e.message : "lookup failed");
  }
});
