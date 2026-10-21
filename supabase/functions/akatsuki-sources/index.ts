// akatsuki-sources — the hub's fetcher for keyless public sources.  R040b · Oct 18
// Deploy:  supabase functions deploy akatsuki-sources   (JWT verify on; caller must be service role)
// Invoked by pg_cron (R040b) or by hand: curl -X POST .../akatsuki-sources -H "Authorization: Bearer <service_role>" -d '{"source":"fx","force":true}'
// Writes akatsuki_cache only.  Never called by a page.
//   fx       open.er-api.com (ExchangeRate-API open access, no key, daily).  Keys JPY:<date> + JPY:latest.
//   climate  Open-Meteo historical archive (ERA5, no key).  10 full years → monthly normals per point.  Key = point id.
//   forecast Open-Meteo, Setu day trips (R042).   weather  Open-Meteo now + 3 days, here + pinned places (R044).
import { createClient } from 'npm:@supabase/supabase-js@2';

const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const sb = createClient(Deno.env.get('SUPABASE_URL')!, SERVICE, { auth: { persistSession: false } });
const CLIMATE_YEARS = [2015, 2024];   // full years only; bump yearly
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { 'Content-Type': 'application/json' } });

async function put(user_id: string, source: string, key: string, payload: unknown, expires_at: string | null) {
  const { error } = await sb.from('akatsuki_cache').upsert({ user_id, source, key, payload, fetched_at: new Date().toISOString(), expires_at }, { onConflict: 'user_id,source,key' });
  if (error) throw new Error(`cache ${source}/${key}: ${error.message}`);
}
async function mark(user_id: string, id: string, status: string) {
  await sb.from('akatsuki_sources').update({ last_fetched_at: new Date().toISOString(), last_status: status.slice(0, 300) }).eq('user_id', user_id).eq('id', id);
}

async function fx(user_id: string, force: boolean) {
  const res = await fetch('https://open.er-api.com/v6/latest/JPY');
  if (!res.ok) throw new Error(`er-api ${res.status}`);
  const d = await res.json();
  if (d.result !== 'success') throw new Error(`er-api ${d['error-type'] || 'error'}`);
  const asOf = new Date(d.time_last_update_unix * 1000).toISOString();
  const key = `JPY:${asOf.slice(0, 10)}`;
  if (!force) {
    const { data } = await sb.from('akatsuki_cache').select('key').eq('user_id', user_id).eq('source', 'fx').eq('key', key).maybeSingle();
    if (data) return `skip ${key} (have it)`;
  }
  const payload = { base: 'JPY', rates: d.rates, as_of: asOf, kind: 'published', source: 'open.er-api.com',
                    attribution: 'Rates By Exchange Rate API — https://www.exchangerate-api.com' };
  // JPY:latest expires 26 h after the source's own update, not at its next one: a missed 01:10 run leaves one day of grace.
  const grace = new Date(d.time_last_update_unix * 1000 + 26 * 3600e3).toISOString();
  await put(user_id, 'fx', key, payload, null);           // dated rows kept (history)
  await put(user_id, 'fx', 'JPY:latest', payload, grace); // the one row readers take
  return `ok ${key}`;
}

function monthly(daily: any) {
  const acc = Array.from({ length: 12 }, () => ({ p: 0, wet: 0, heavy: 0, tx: 0, tn: 0, n: 0, gust: 0 }));
  const years = CLIMATE_YEARS[1] - CLIMATE_YEARS[0] + 1;
  daily.time.forEach((t: string, i: number) => {
    const a = acc[Number(t.slice(5, 7)) - 1], p = daily.precipitation_sum[i] ?? 0;
    a.p += p; if (p >= 1) a.wet++; if (p >= 50) a.heavy++;
    a.tx += daily.temperature_2m_max[i] ?? 0; a.tn += daily.temperature_2m_min[i] ?? 0; a.n++;
    a.gust = Math.max(a.gust, daily.wind_gusts_10m_max[i] ?? 0);
  });
  const r1 = (x: number) => Math.round(x * 10) / 10;
  return acc.map((a, i) => ({ month: i + 1, precip_mm: r1(a.p / years), wet_days: r1(a.wet / years), heavy_rain_days: r1(a.heavy / years),
    tmax_c: r1(a.tx / a.n), tmin_c: r1(a.tn / a.n), gust_max_kmh: r1(a.gust) }));
}

async function climate(user_id: string, force: boolean) {
  const { data: pts, error } = await sb.from('akatsuki_climate_points').select('id,label,lat,lng').eq('user_id', user_id).is('retired_at', null);
  if (error) throw new Error('points ' + error.message);
  const { data: have } = await sb.from('akatsuki_cache').select('key,expires_at').eq('user_id', user_id).eq('source', 'climate');
  const fresh = new Set((have || []).filter((h: any) => h.expires_at && h.expires_at > new Date().toISOString()).map((h: any) => h.key));
  const done: string[] = [];
  for (const pt of pts || []) {
    if (!force && fresh.has(pt.id)) continue;
    if (done.length) await new Promise((r) => setTimeout(r, 4000));   // Open-Meteo weighs 10-year pulls heavily; 8 back-to-back hit 429
    const url = `https://archive-api.open-meteo.com/v1/archive?latitude=${pt.lat}&longitude=${pt.lng}` +
      `&start_date=${CLIMATE_YEARS[0]}-01-01&end_date=${CLIMATE_YEARS[1]}-12-31` +
      `&daily=precipitation_sum,temperature_2m_max,temperature_2m_min,wind_gusts_10m_max&timezone=auto`;
    const res = await fetch(url);
    if (!res.ok) { done.push(`${pt.id}:${res.status}`); continue; }
    const d = await res.json();
    const payload = { place: pt.id, label: pt.label, lat: pt.lat, lng: pt.lng, tz: d.timezone,
      years: `${CLIMATE_YEARS[0]}–${CLIMATE_YEARS[1]}`, months: monthly(d.daily),
      kind: 'published', source: 'Open-Meteo historical archive (ERA5 reanalysis)', attribution: 'Weather data by Open-Meteo.com (CC BY 4.0)' };
    await put(user_id, 'climate', pt.id, payload, new Date(Date.now() + 365 * 864e5).toISOString());
    done.push(pt.id);
  }
  return done.length ? `ok ${done.join(' ')}` : 'skip (all fresh)';
}

// R042 · forecast (Open-Meteo, keyless) for Setu's dated day trips in the next 15 days.  Targets come from the view
// akatsuki_setu_forecast_targets (Setu owns the rows; the hub only reads coordinates + date).  Key day_trip:<id>, TTL 7 h.
async function forecast(user_id: string, _force: boolean) {
  const { data: pts, error } = await sb.from('akatsuki_setu_forecast_targets').select('id,name,date,lat,lng').eq('user_id', user_id);
  if (error) throw new Error('targets ' + error.message);
  const done: string[] = [];
  for (const pt of pts || []) {
    if (done.length) await new Promise((r) => setTimeout(r, 1000));
    const url = `https://api.open-meteo.com/v1/forecast?latitude=${pt.lat}&longitude=${pt.lng}&timezone=auto` +
      `&start_date=${pt.date}&end_date=${pt.date}` +
      `&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum,precipitation_probability_max,wind_gusts_10m_max`;
    const res = await fetch(url);
    if (!res.ok) { done.push(`${pt.id.slice(0, 8)}:${res.status}`); continue; }
    const d = (await res.json()).daily || {};
    const v = (k: string) => (d[k] || [])[0] ?? null;
    const payload = { day_trip_id: pt.id, name: pt.name, date: pt.date, lat: pt.lat, lng: pt.lng,
      weather_code: v('weather_code'), tmax_c: v('temperature_2m_max'), tmin_c: v('temperature_2m_min'),
      precip_mm: v('precipitation_sum'), precip_prob_pct: v('precipitation_probability_max'), gust_max_kmh: v('wind_gusts_10m_max'),
      as_of: new Date().toISOString(), kind: 'published', source: 'Open-Meteo forecast', attribution: 'Weather data by Open-Meteo.com (CC BY 4.0)' };
    await put(user_id, 'forecast', `day_trip:${pt.id}`, payload, new Date(Date.now() + 7 * 3600e3).toISOString());
    done.push(pt.id.slice(0, 8));
  }
  return done.length ? `ok ${done.length}: ${done.join(' ')}` : 'skip (no dated day trips with coordinates in the next 15 days)';
}

// R044 · weather now + 7 days (Hub shows 3; Calendar needs 7) for "here" and every pinned hub place.  ONE Open-Meteo call for all points.
//   here: newest live visit (seen ≤ 2 h) — coordinates rounded to 2 dp here, never written to the cache (the waist).
//   place:<id>: live akatsuki_places with lat/lng (≤ 12), refreshed when older than 170 min (or force).
const r2 = (x: number) => Math.round(x * 100) / 100;
async function weather(user_id: string, force: boolean) {
  const pts: { key: string; label: string; place_id: string | null; class: string | null; lat: number; lng: number; ttl_h: number }[] = [];
  const { data: v } = await sb.from('akatsuki_visits').select('lat,lng,place_id,anchor_id,last_seen_at')
    .eq('user_id', user_id).is('until', null).is('merged_into', null).not('lat', 'is', null)
    .gte('last_seen_at', new Date(Date.now() - 2 * 3600e3).toISOString()).order('last_seen_at', { ascending: false }).limit(1);
  const here = (v || [])[0];
  const { data: places } = await sb.from('akatsuki_places').select('id,label,class,lat,lng').eq('user_id', user_id)
    .is('retired_at', null).not('lat', 'is', null).order('ord').limit(12);
  if (here) {
    const p = (places || []).find((x: any) => x.id === here.place_id);
    pts.push({ key: 'here', label: p ? p.label : 'Here', place_id: here.place_id ?? null, class: p ? p.class : null, lat: r2(here.lat), lng: r2(here.lng), ttl_h: 1.5 });
  }
  const { data: have } = await sb.from('akatsuki_cache').select('key,fetched_at').eq('user_id', user_id).eq('source', 'weather');
  const age = new Map((have || []).map((h: any) => [h.key, Date.now() - Date.parse(h.fetched_at)]));
  for (const p of places || []) {
    const k = `place:${p.id}`;
    if (!force && (age.get(k) ?? Infinity) < 170 * 60e3) continue;
    pts.push({ key: k, label: p.label, place_id: p.id, class: p.class, lat: r2(p.lat), lng: r2(p.lng), ttl_h: 4 });
  }
  if (!pts.length) return 'skip (no live visit, places fresh)';
  const url = `https://api.open-meteo.com/v1/forecast?latitude=${pts.map((p) => p.lat).join(',')}&longitude=${pts.map((p) => p.lng).join(',')}` +
    `&timezone=auto&forecast_days=7&current=temperature_2m,apparent_temperature,weather_code,precipitation,wind_speed_10m,is_day` +
    `&hourly=weather_code,precipitation_probability,precipitation&daily=temperature_2m_max,temperature_2m_min,precipitation_sum`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`open-meteo ${res.status}`);
  const body = await res.json();
  const list = Array.isArray(body) ? body : [body];
  const done: string[] = [];
  for (let i = 0; i < pts.length; i++) {
    const pt = pts[i], d = list[i]; if (!d || !d.current) { done.push(pt.key + ':empty'); continue; }
    const c = d.current, dy = d.daily || {}, hr = d.hourly || { weather_code: [], precipitation_probability: [], precipitation: [] };
    const nowH = Number(String(c.time).slice(11, 13)) || 0;
    // R044d · rain is judged by expected mm, not by %: the % is a coarse 27 km ensemble and the code flags 0.1 mm traces.
    //   Day mm = hours still ahead (today) or the whole day.  < 2 mm → no rain icon (rain codes read as overcast).
    //   ≥ 2 mm → the heaviest code among hours with ≥ 0.5 mm (a 6 mm storm hour shows ⛈, like Google).
    const WET = (x: number) => (x >= 51 && x <= 67) || (x >= 80 && x <= 82) || x >= 95;
    const dry = (x: number) => (WET(x) ? 3 : x);
    const dayOf = (j: number) => {
      const from = j === 0 ? nowH : 0, H = (k: string) => (hr as any)[k].slice(j * 24 + from, j * 24 + 24);
      const mmH: number[] = H('precipitation').map((x: any) => x ?? 0), codesH: number[] = H('weather_code');
      const mm = Math.round(mmH.reduce((a, b) => a + b, 0) * 10) / 10;
      let code: number | null = null;
      if (mm >= 2) { code = Math.max(...codesH.filter((_, i) => mmH[i] >= 0.5).filter(WET), ...codesH.filter(WET).slice(0, 1)); if (!isFinite(code)) code = 61; }
      if (code == null) {
        const day = hr.weather_code.slice(j * 24 + 8, j * 24 + 20).filter((x: any) => x != null).map(dry);
        const n: Record<number, number> = {}; day.forEach((x: number) => { n[x] = (n[x] || 0) + 1; });
        code = day.length ? Number(Object.keys(n).sort((a, b) => n[Number(b)] - n[Number(a)] || Number(a) - Number(b))[0]) : null;
      }
      const probs = hr.precipitation_probability.slice(j * 24 + (j === 0 ? nowH : 6), j * 24 + (j === 0 ? 24 : 22)).filter((x: any) => x != null);
      return { code, precip_mm: mm, precip_prob_pct: probs.length ? Math.max(...probs) : null };
    };
    const payload = { key: pt.key, label: pt.label, place_id: pt.place_id, class: pt.class, tz: d.timezone,
      now: { temp_c: c.temperature_2m, feels_c: c.apparent_temperature, code: (c.precipitation ?? 0) >= 0.1 ? c.weather_code : dry(c.weather_code), precip_mm: c.precipitation,
             precip_prob_pct: hr.precipitation_probability[nowH] ?? null, wind_kmh: c.wind_speed_10m, is_day: c.is_day === 1, at: c.time },
      days: (dy.time || []).map((t: string, j: number) => ({ date: t, ...dayOf(j), tmax_c: dy.temperature_2m_max[j], tmin_c: dy.temperature_2m_min[j] })),
      kind: 'published', source: 'Open-Meteo forecast', attribution: 'Weather data by Open-Meteo.com (CC BY 4.0)' };
    await put(user_id, 'weather', pt.key, payload, new Date(Date.now() + pt.ttl_h * 3600e3).toISOString());
    done.push(pt.key);
  }
  return `ok ${done.join(' ')}` + (here ? '' : ' · no live visit (here not refreshed)');
}

const RUN: Record<string, (u: string, f: boolean) => Promise<string>> = { fx, climate, forecast, weather };

// VALIDATE (one-off, Oct 19) · backtest: what each model forecast ONE DAY AHEAD vs what ERA5 says fell, last 30 days, every pinned place.
//   Rain day = ≥ 1 mm.  Writes cache weather_validation/latest; returns the summary.  Changes no cards.
//   Caveat: ERA5 is ECMWF's reanalysis (~30 km) — it smooths showers and leans toward ECMWF. Fine for "rain day or not", weak for exact mm.
const VMODELS = ['best_match', 'jma_seamless', 'ecmwf_ifs025', 'gfs_seamless'];
async function validate(user_id: string, days: number) {
  const end = new Date(Date.now() - 6 * 864e5).toISOString().slice(0, 10);
  const start = new Date(Date.now() - (6 + days - 1) * 864e5).toISOString().slice(0, 10);
  const { data: places } = await sb.from('akatsuki_places').select('id,label,lat,lng').eq('user_id', user_id).is('retired_at', null).not('lat', 'is', null).order('ord');
  const rows: any[] = [], detail: any[] = [];
  for (const p of places || []) {
    const ll = `latitude=${r2(p.lat)}&longitude=${r2(p.lng)}&timezone=auto&start_date=${start}&end_date=${end}`;
    let models = VMODELS;
    let fr = await fetch(`https://previous-runs-api.open-meteo.com/v1/forecast?${ll}&hourly=precipitation_previous_day1&models=${models.join(',')}`);
    if (fr.status === 400) {   // a model the previous-runs service doesn't know → drop JMA, keep the rest
      models = VMODELS.filter((m) => m !== 'jma_seamless');
      rows.push({ place: p.label, model: 'jma_seamless', error: 'not in previous-runs API: ' + ((await fr.json().catch(() => ({}))).reason || '400') });
      fr = await fetch(`https://previous-runs-api.open-meteo.com/v1/forecast?${ll}&hourly=precipitation_previous_day1&models=${models.join(',')}`);
    }
    await new Promise((r) => setTimeout(r, 800));
    const tr = await fetch(`https://archive-api.open-meteo.com/v1/archive?${ll}&daily=precipitation_sum`);
    await new Promise((r) => setTimeout(r, 800));
    if (!fr.ok || !tr.ok) { rows.push({ place: p.label, model: '-', error: `forecast ${fr.status} · truth ${tr.status}` }); continue; }
    const f = await fr.json(), t = await tr.json();
    const obs: Record<string, number> = {};
    (t.daily?.time || []).forEach((d: string, i: number) => { if (t.daily.precipitation_sum[i] != null) obs[d] = t.daily.precipitation_sum[i]; });
    for (const m of models) {
      const arr = f.hourly?.[`precipitation_previous_day1_${m}`] || (models.length === 1 || m === 'best_match' ? f.hourly?.precipitation_previous_day1 : null);
      if (!arr) { rows.push({ place: p.label, model: m, error: 'no data' }); continue; }
      const fc: Record<string, number> = {};
      f.hourly.time.forEach((ts: string, i: number) => { if (arr[i] != null) fc[ts.slice(0, 10)] = (fc[ts.slice(0, 10)] || 0) + arr[i]; });
      let n = 0, hit = 0, miss = 0, fa = 0, dryok = 0, err = 0, wet = 0;
      for (const d of Object.keys(obs)) {
        if (fc[d] == null) continue;
        const o = obs[d] >= 1, x = fc[d] >= 1; n++; if (o) wet++;
        if (o && x) hit++; else if (o && !x) miss++; else if (!o && x) fa++; else dryok++;
        err += Math.abs(fc[d] - obs[d]);
        if (m === 'best_match') detail.push({ place: p.label, date: d, obs_mm: Math.round(obs[d] * 10) / 10, best_match_mm: Math.round(fc[d] * 10) / 10 });
      }
      rows.push({ place: p.label, model: m, days: n, rain_days: wet, hits: hit, missed: miss, false_alarms: fa, dry_right: dryok,
        right_pct: n ? Math.round(((hit + dryok) / n) * 100) : null, mae_mm: n ? Math.round((err / n) * 10) / 10 : null });
    }
  }
  await put(user_id, 'weather_validation', 'latest', { start, end, threshold_mm: 1, truth: 'ERA5 (archive-api)', rows, detail }, null);
  return { start, end, rows };
}

// The gateway (Verify JWT on) has already checked the signature; read the role claim.
// Not a string compare with SUPABASE_SERVICE_ROLE_KEY: on this project the env value differs from the dashboard's legacy JWT.
function roleOf(req: Request): string | null {
  const t = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/, '').split('.')[1];
  if (!t) return null;
  try { return JSON.parse(atob(t.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(t.length / 4) * 4, '='))).role ?? null; }
  catch { return null; }
}

Deno.serve(async (req) => {
  if (roleOf(req) !== 'service_role') return json({ error: 'service role only' }, 401);
  const body = await req.json().catch(() => ({}));
  if (body.source === 'validate') {
    const { data: w } = await sb.from('akatsuki_sources').select('user_id').eq('id', 'weather').limit(1).maybeSingle();
    if (!w) return json({ error: 'weather source row missing' }, 500);
    try { return json(await validate(w.user_id, Math.min(Number(body.days) || 30, 60))); }
    catch (e) { return json({ error: (e as Error).message }, 500); }
  }
  const ids = body.source ? [body.source] : Object.keys(RUN);
  const { data: rows, error } = await sb.from('akatsuki_sources').select('user_id,id').in('id', ids.filter((i) => RUN[i]));
  if (error) return json({ error: error.message }, 500);
  const out: Record<string, string> = {};
  for (const r of rows || []) {
    try { out[r.id] = await RUN[r.id](r.user_id, !!body.force); }
    catch (e) { out[r.id] = 'error ' + (e as Error).message; }
    await mark(r.user_id, r.id, out[r.id]);
  }
  console.log('[akatsuki-sources]', out);
  return json(out);
});
