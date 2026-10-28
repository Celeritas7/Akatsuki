// akatsuki-sources — the hub's fetcher for keyless public sources.  R040b · Oct 18 · R045 Oct 24
// Deploy:  supabase functions deploy akatsuki-sources   (JWT verify on; caller must be service role)
// Invoked by pg_cron (R040b) or by hand: curl -X POST .../akatsuki-sources -H "Authorization: Bearer <service_role>" -d '{"source":"fx","force":true}'
// Writes akatsuki_cache (+ akatsuki_weather_daily for weather_history).  Never called by a page.
//   fx       open.er-api.com (ExchangeRate-API open access, no key, daily).  Keys JPY:<date> + JPY:latest.
//   climate  Open-Meteo historical archive (ERA5, no key).  10 full years → monthly normals per point.  Key = point id.
//   forecast Open-Meteo, Setu day trips (R042).   weather  Open-Meteo now + 7 days, here + pinned places + plan (R044; R045 rh/pressure/wind; R046 risk/seasons/plan).
//   weather_history  Open-Meteo past_days → akatsuki_weather_daily, one row per point per completed local day (R045).
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
// R045 · each day also carries rh_min_pct, rh_mean_pct, pressure_hpa_mean (surface) and wind_max_ms (Health Log warnings). Additive.
const r2 = (x: number) => Math.round(x * 100) / 100;
const r1n = (x: any) => (x == null || !isFinite(Number(x)) ? null : Math.round(Number(x) * 10) / 10);
// R046 · health-risk weather (Calendar request Oct 23). Additive to weather.now:
//   day: feels_max_c, gust_max_ms, uv_max, pressure_d24_hpa, change{…}, risk[{id, level, reason}]
//   top-level: seasons[{id, label, from, to}] — Kantō sickness-prone periods overlapping the 7 days (tz Asia/Tokyo only)
//   key plan: where you will be each day — Mon–Fri place:office, Sat/Sun place:home, today = here when live.
const SEASONS: { id: string; label: string; from: string; to: string }[] = [
  { id: 'dry_flu', label: '乾燥 · flu season · heat shock', from: '12-01', to: '02-28' },
  { id: 'cedar_pollen', label: 'Cedar / cypress pollen', from: '02-01', to: '05-31' },
  { id: 'spring_swings', label: '寒暖差 · spring temperature swings', from: '02-20', to: '04-30' },
  { id: 'gogatsu', label: '五月病 · May swings', from: '05-01', to: '05-31' },
  { id: 'tsuyu', label: '梅雨 · rainy season (pressure, damp, food, mould)', from: '06-05', to: '07-20' },
  { id: 'heat', label: '熱中症 · 夏バテ · heat', from: '07-15', to: '08-31' },
  { id: 'zansho', label: '残暑 · typhoons (sharp pressure drops)', from: '09-01', to: '09-30' },
  { id: 'autumn', label: '秋の寒暖差 · ragweed · dry air begins', from: '09-20', to: '11-30' },
];
function seasonsFor(dates: string[]) {
  if (!dates.length) return [];
  const first = dates[0], last = dates[dates.length - 1], y = Number(first.slice(0, 4));
  const out: { id: string; label: string; from: string; to: string }[] = [];
  for (const s of SEASONS) {
    for (const yy of [y - 1, y, y + 1]) {
      const wraps = s.to < s.from;
      const from = `${yy}-${s.from}`, to = `${wraps ? yy + 1 : yy}-${s.to}`;
      if (from <= last && to >= first) { out.push({ id: s.id, label: s.label, from, to }); break; }
    }
  }
  return out;
}
const kmBetween = (a: { lat: number; lng: number }, b: { lat: number; lng: number }) => {
  const R = 6371, t = (d: number) => (d * Math.PI) / 180;
  const h = Math.sin(t(b.lat - a.lat) / 2) ** 2 + Math.cos(t(a.lat)) * Math.cos(t(b.lat)) * Math.sin(t(b.lng - a.lng) / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
};
// Monthly normals → a day's normal by linear interpolation between mid-months.
function normalFor(months: any[], date: string) {
  const m = Number(date.slice(5, 7)) - 1, d = Number(date.slice(8, 10));
  const cur = months[m], other = d >= 15 ? months[(m + 1) % 12] : months[(m + 11) % 12];
  if (!cur || !other) return null;
  const w = Math.abs(d - 15) / 30;
  const mix = (k: string) => cur[k] * (1 - w) + other[k] * w;
  return { tmax: mix('tmax_c'), tmin: mix('tmin_c') };
}
function riskOf(day: any, normal: { tmax: number; tmin: number } | null) {
  const r: { id: string; level: 'watch' | 'high'; reason: string }[] = [];
  const f1 = (x: number) => (x > 0 ? '+' : '') + (Math.round(x * 10) / 10);
  const c = day.change || {};
  const sw = [c.d_tmax_c, c.d_tmin_c].filter((x) => x != null) as number[];
  const big = sw.length ? sw.reduce((a, b) => (Math.abs(b) > Math.abs(a) ? b : a)) : null;
  if (big != null && Math.abs(big) >= 5) r.push({ id: 'temp_swing', level: Math.abs(big) >= 7 ? 'high' : 'watch', reason: `Temperature ${f1(big)} °C vs the day before` });
  if (day.tmax_c != null && day.tmin_c != null && day.tmax_c - day.tmin_c >= 10) r.push({ id: 'day_night', level: 'watch', reason: `Day–night range ${Math.round((day.tmax_c - day.tmin_c) * 10) / 10} °C` });
  if (day.pressure_d24_hpa != null && day.pressure_d24_hpa <= -6) r.push({ id: 'pressure_fall', level: day.pressure_d24_hpa <= -10 ? 'high' : 'watch', reason: `Pressure ${f1(day.pressure_d24_hpa)} hPa vs the day before` });
  if (day.rh_mean_pct != null && day.rh_mean_pct < 40) r.push({ id: 'dry', level: 'watch', reason: `Dry air (mean humidity ${day.rh_mean_pct}%)` });
  if (day.rh_mean_pct != null && day.rh_mean_pct >= 80 && day.tmax_c != null && day.tmax_c >= 25) r.push({ id: 'muggy', level: 'watch', reason: `Muggy (${day.rh_mean_pct}% at ${day.tmax_c} °C)` });
  if (day.feels_max_c != null && day.feels_max_c >= 31) r.push({ id: 'heat', level: day.feels_max_c >= 35 ? 'high' : 'watch', reason: `Feels like ${day.feels_max_c} °C` });
  if (day.tmin_c != null && day.tmin_c >= 25) r.push({ id: 'tropical_night', level: 'watch', reason: `Tropical night (min ${day.tmin_c} °C)` });
  if (normal && day.tmax_c != null && day.tmin_c != null) {
    const mean = (day.tmax_c + day.tmin_c) / 2, nm = (normal.tmax + normal.tmin) / 2;
    if (mean <= nm - 3) r.push({ id: 'cold_snap', level: 'watch', reason: `${Math.round((nm - mean) * 10) / 10} °C below normal for the date` });
  }
  if (day.code != null && day.code >= 95) r.push({ id: 'storm', level: 'high', reason: 'Thunderstorm' });
  else if (day.precip_mm != null && day.precip_mm >= 30) r.push({ id: 'storm', level: 'watch', reason: `Heavy rain (${day.precip_mm} mm)` });
  return r;
}
function changeOf(cur: any, prev: any) {
  const d = (k: string) => (cur[k] == null || prev[k] == null ? null : Math.round((cur[k] - prev[k]) * 10) / 10);
  const ch = { d_tmax_c: d('tmax_c'), d_tmin_c: d('tmin_c'), d_pressure_hpa: d('pressure_hpa_mean'), d_rh_mean_pct: d('rh_mean_pct'), summary: '' };
  const parts: string[] = [];
  if (ch.d_tmax_c != null && Math.abs(ch.d_tmax_c) >= 3) parts.push(ch.d_tmax_c > 0 ? `warmer +${ch.d_tmax_c} °C` : `cooler ${ch.d_tmax_c} °C`);
  if (ch.d_pressure_hpa != null && Math.abs(ch.d_pressure_hpa) >= 4) parts.push(`pressure ${ch.d_pressure_hpa > 0 ? '+' : ''}${ch.d_pressure_hpa} hPa`);
  if (ch.d_rh_mean_pct != null && Math.abs(ch.d_rh_mean_pct) >= 15) parts.push(ch.d_rh_mean_pct < 0 ? 'drier' : 'more humid');
  ch.summary = parts.length ? parts.join(' · ') : 'similar to the day before';
  return ch;
}

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
  const done: string[] = [];
  if (pts.length) {
    // R046 · monthly normals from the nearest climate point ≤ 50 km (for cold_snap)
    const { data: clim } = await sb.from('akatsuki_cache').select('payload').eq('user_id', user_id).eq('source', 'climate');
    const climPts = (clim || []).map((c: any) => c.payload).filter((c: any) => c && c.lat != null && Array.isArray(c.months));
    const nearestNormals = (pt: { lat: number; lng: number }) => {
      let best: any = null, bd = 50;
      for (const c of climPts) { const d = kmBetween(pt, c); if (d <= bd) { bd = d; best = c; } }
      return best ? best.months : null;
    };
    const url = `https://api.open-meteo.com/v1/forecast?latitude=${pts.map((p) => p.lat).join(',')}&longitude=${pts.map((p) => p.lng).join(',')}` +
      `&timezone=auto&past_days=2&forecast_days=7&current=temperature_2m,apparent_temperature,weather_code,precipitation,wind_speed_10m,is_day` +
      `&hourly=weather_code,precipitation_probability,precipitation` +
      `&daily=temperature_2m_max,temperature_2m_min,precipitation_sum,relative_humidity_2m_min,relative_humidity_2m_mean,surface_pressure_mean,wind_speed_10m_max` +
      `,apparent_temperature_max,wind_gusts_10m_max,uv_index_max`;
    const res = await fetch(url);
    if (!res.ok) throw new Error(`open-meteo ${res.status}`);
    const body = await res.json();
    const list = Array.isArray(body) ? body : [body];
    for (let i = 0; i < pts.length; i++) {
      const pt = pts[i], d = list[i]; if (!d || !d.current) { done.push(pt.key + ':empty'); continue; }
      const c = d.current, dy = d.daily || {}, hr = d.hourly || { weather_code: [], precipitation_probability: [], precipitation: [] };
      const nowH = Number(String(c.time).slice(11, 13)) || 0;
      // R046 · past_days=2 → daily/hourly arrays start 2 days back. P = index of today; days[] still starts today.
      const P = Math.max(0, (dy.time || []).indexOf(String(c.time).slice(0, 10)));
      // R044d · rain is judged by expected mm, not by %: the % is a coarse 27 km ensemble and the code flags 0.1 mm traces.
      //   Day mm = hours still ahead (today) or the whole day.  < 2 mm → no rain icon (rain codes read as overcast).
      //   ≥ 2 mm → the heaviest code among hours with ≥ 0.5 mm (a 6 mm storm hour shows ⛈, like Google).
      const WET = (x: number) => (x >= 51 && x <= 67) || (x >= 80 && x <= 82) || x >= 95;
      const dry = (x: number) => (WET(x) ? 3 : x);
      const dayOf = (j: number) => {
        const base = (j + P) * 24;
        const from = j === 0 ? nowH : 0, H = (k: string) => (hr as any)[k].slice(base + from, base + 24);
        const mmH: number[] = H('precipitation').map((x: any) => x ?? 0), codesH: number[] = H('weather_code');
        const mm = Math.round(mmH.reduce((a, b) => a + b, 0) * 10) / 10;
        let code: number | null = null;
        if (mm >= 2) { code = Math.max(...codesH.filter((_, i) => mmH[i] >= 0.5).filter(WET), ...codesH.filter(WET).slice(0, 1)); if (!isFinite(code)) code = 61; }
        if (code == null) {
          const day = hr.weather_code.slice(base + 8, base + 20).filter((x: any) => x != null).map(dry);
          const n: Record<number, number> = {}; day.forEach((x: number) => { n[x] = (n[x] || 0) + 1; });
          code = day.length ? Number(Object.keys(n).sort((a, b) => n[Number(b)] - n[Number(a)] || Number(a) - Number(b))[0]) : null;
        }
        const probs = hr.precipitation_probability.slice(base + (j === 0 ? nowH : 6), base + (j === 0 ? 24 : 22)).filter((x: any) => x != null);
        return { code, precip_mm: mm, precip_prob_pct: probs.length ? Math.max(...probs) : null };
      };
      const g = (k: string, jd: number) => (dy[k] || [])[jd];
      const raw = (jd: number) => ({   // whole-day model values (also for the day before today)
        tmax_c: g('temperature_2m_max', jd), tmin_c: g('temperature_2m_min', jd),
        rh_min_pct: r1n(g('relative_humidity_2m_min', jd)), rh_mean_pct: r1n(g('relative_humidity_2m_mean', jd)),
        pressure_hpa_mean: r1n(g('surface_pressure_mean', jd)),
        wind_max_ms: g('wind_speed_10m_max', jd) == null ? null : r1n(g('wind_speed_10m_max', jd) / 3.6),   // daily unit is km/h (now.wind_kmh stays km/h)
        feels_max_c: r1n(g('apparent_temperature_max', jd)),
        gust_max_ms: g('wind_gusts_10m_max', jd) == null ? null : r1n(g('wind_gusts_10m_max', jd) / 3.6),
        uv_max: r1n(g('uv_index_max', jd)),
      });
      const months = nearestNormals(pt);
      const nDays = Math.max(0, Math.min(7, (dy.time || []).length - P));
      const days = Array.from({ length: nDays }, (_, j) => {
        const jd = j + P, cur = raw(jd), prev = jd > 0 ? raw(jd - 1) : null;
        const day: any = { date: dy.time[jd], ...dayOf(j), ...cur,
          pressure_d24_hpa: prev && cur.pressure_hpa_mean != null && prev.pressure_hpa_mean != null ? r1n(cur.pressure_hpa_mean - prev.pressure_hpa_mean) : null };
        day.change = prev ? changeOf(cur, prev) : null;
        day.risk = riskOf(day, months ? normalFor(months, day.date) : null);
        return day;
      });
      const payload = { key: pt.key, label: pt.label, place_id: pt.place_id, class: pt.class, tz: d.timezone,
        now: { temp_c: c.temperature_2m, feels_c: c.apparent_temperature, code: (c.precipitation ?? 0) >= 0.1 ? c.weather_code : dry(c.weather_code), precip_mm: c.precipitation,
               precip_prob_pct: hr.precipitation_probability[P * 24 + nowH] ?? null, wind_kmh: c.wind_speed_10m, is_day: c.is_day === 1, at: c.time },
        days,
        seasons: d.timezone === 'Asia/Tokyo' ? seasonsFor(days.map((x: any) => x.date)) : [],
        normals_from: months ? 'Open-Meteo ERA5 2015–2024 monthly normals, nearest climate point ≤ 50 km' : null,
        kind: 'published', source: 'Open-Meteo forecast', attribution: 'Weather data by Open-Meteo.com (CC BY 4.0)' };
      await put(user_id, 'weather', pt.key, payload, new Date(Date.now() + pt.ttl_h * 3600e3).toISOString());
      done.push(pt.key);
    }
  }
  const plan = await buildPlan(user_id);
  if (!pts.length) return 'skip (no live visit, places fresh)' + plan;
  return `ok ${done.join(' ')}` + (here ? '' : ' · no live visit (here not refreshed)') + plan;
}

// R046 · key plan — "where will I be on date D". Mon–Fri → place:office, Sat/Sun → place:home, today → here when live.
//   Built every run from the cache rows (no extra API call). Each day carries at: here | office | home.
//   Not handled yet: Japanese public holidays, Calendar away-days (no hub source for either).
async function buildPlan(user_id: string) {
  const { data } = await sb.from('akatsuki_cache').select('key,payload,expires_at').eq('user_id', user_id).eq('source', 'weather').in('key', ['here', 'place:home', 'place:office']);
  const live = (k: string) => (data || []).find((r: any) => r.key === k && (!r.expires_at || r.expires_at > new Date().toISOString()))?.payload;
  const home = live('place:home'), office = live('place:office'), here = live('here');
  const base = home || office; if (!base) return ' · plan skipped (no home/office row)';
  const today = (base.days[0] || {}).date;
  const pick = (src: any, date: string) => src && (src.days || []).find((x: any) => x.date === date);
  const days = (base.days || []).map((b: any) => {
    const wd = new Date(b.date + 'T00:00:00Z').getUTCDay(), weekday = wd >= 1 && wd <= 5;
    if (b.date === today && pick(here, b.date)) return { ...pick(here, b.date), at: 'here' };
    if (weekday && pick(office, b.date)) return { ...pick(office, b.date), at: 'office' };
    return { ...(pick(home, b.date) || b), at: home ? 'home' : 'office' };
  });
  const nowSrc = here || (days[0] && days[0].at === 'office' ? office : home) || base;
  const payload = { key: 'plan', label: 'Plan', place_id: null, class: null, tz: base.tz, now: nowSrc.now, days, seasons: base.seasons || [],
    rule: 'Mon–Fri office, Sat/Sun home, today = here when live. Holidays and Calendar away-days not applied yet.',
    kind: 'published', source: 'Open-Meteo forecast (assembled by the hub)', attribution: 'Weather data by Open-Meteo.com (CC BY 4.0)' };
  await put(user_id, 'weather', 'plan', payload, new Date(Date.now() + 1.5 * 3600e3).toISOString());
  return ' · plan ' + days.map((x: any) => x.at[0]).join('');
}

// R045 · weather_history — one row per point per COMPLETED local day into akatsuki_weather_daily. ONE Open-Meteo call.
//   place:<id>: live pinned places with coords (≤ 12).
//   here: per local day, the 2-dp grid cell where visits spent the most time (dwell = until|last_seen − since, dated by since).
//         No visit that day → no here row. Cells are used for the call only; no coordinates are written (the waist).
//   Window: last 7 days (rows re-written as the model settles); first run, or body.start, backfills from that date (≤ 92 days).
//   kind = modelled: Open-Meteo past_days best_match series, not a station observation.
const HISTORY_START = '2026-10-01';
async function weather_history(user_id: string, force: boolean, body: any = {}) {
  const { count } = await sb.from('akatsuki_weather_daily').select('date', { count: 'exact', head: true }).eq('user_id', user_id);
  const start: string | null = body.start || (!count || force ? HISTORY_START : null);
  const pastDays = start ? Math.min(92, Math.ceil((Date.now() - Date.parse(start + 'T00:00:00Z')) / 864e5) + 1) : 7;
  const since = new Date(Date.now() - (pastDays + 1) * 864e5).toISOString();

  type Pt = { key: string; label: string; place_id: string | null; class: string | null; lat: number; lng: number };
  const pts: Pt[] = [];
  const { data: places } = await sb.from('akatsuki_places').select('id,label,class,lat,lng').eq('user_id', user_id)
    .is('retired_at', null).not('lat', 'is', null).order('ord').limit(12);
  const placeById = new Map((places || []).map((p: any) => [p.id, p]));
  for (const p of places || []) pts.push({ key: `place:${p.id}`, label: p.label, place_id: p.id, class: p.class, lat: r2(p.lat), lng: r2(p.lng) });

  // here: visit cells in the window, heaviest dwell first, ≤ 40 cells
  const { data: vis } = await sb.from('akatsuki_visits').select('since,until,last_seen_at,lat,lng,place_id')
    .eq('user_id', user_id).is('merged_into', null).not('lat', 'is', null).gte('since', since).limit(5000);
  const cellOf = (v: any) => `${r2(v.lat)},${r2(v.lng)}`;
  const dwell = (v: any) => Math.max(0, Date.parse(v.until || v.last_seen_at || v.since) - Date.parse(v.since));
  const cellTotal = new Map<string, number>();
  for (const v of vis || []) cellTotal.set(cellOf(v), (cellTotal.get(cellOf(v)) || 0) + dwell(v));
  const cells = [...cellTotal.entries()].sort((a, b) => b[1] - a[1]).slice(0, 40).map(([c]) => c);
  const cellIdx = new Map<string, number>();
  for (const c of cells) { cellIdx.set(c, pts.length); const [la, lo] = c.split(',').map(Number); pts.push({ key: `cell:${c}`, label: 'Here', place_id: null, class: null, lat: la, lng: lo }); }
  if (!pts.length) return 'skip (no places with coordinates, no visits)';

  const url = `https://api.open-meteo.com/v1/forecast?latitude=${pts.map((p) => p.lat).join(',')}&longitude=${pts.map((p) => p.lng).join(',')}` +
    `&timezone=auto&past_days=${pastDays}&forecast_days=1&wind_speed_unit=ms` +
    `&daily=weather_code,temperature_2m_max,temperature_2m_min,relative_humidity_2m_min,relative_humidity_2m_mean,surface_pressure_mean,precipitation_sum,wind_speed_10m_max`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`open-meteo ${res.status} ${(await res.text()).slice(0, 120)}`);
  const raw = await res.json();
  const list: any[] = Array.isArray(raw) ? raw : [raw];

  const SRC = 'Open-Meteo forecast API · past_days · best_match model (not a station observation)';
  const ATTR = 'Weather data by Open-Meteo.com (CC BY 4.0)';
  const dayRow = (d: any, j: number) => {
    const dy = d.daily; const g = (k: string) => (dy[k] || [])[j];
    return { tmax_c: r1n(g('temperature_2m_max')), tmin_c: r1n(g('temperature_2m_min')), rh_min_pct: r1n(g('relative_humidity_2m_min')),
      rh_mean_pct: r1n(g('relative_humidity_2m_mean')), pressure_hpa_mean: r1n(g('surface_pressure_mean')), precip_mm: r1n(g('precipitation_sum')),
      precip_prob_pct: null, wind_max_ms: r1n(g('wind_speed_10m_max')), code: g('weather_code') == null ? null : Number(g('weather_code')) };
  };
  const localToday = (d: any) => new Date(Date.now() + (d.utc_offset_seconds || 0) * 1000).toISOString().slice(0, 10);
  const minDate = start || '0000-00-00';
  const rows: any[] = [];
  const fetched_at = new Date().toISOString();

  // places
  pts.forEach((pt, i) => {
    if (!pt.key.startsWith('place:')) return;
    const d = list[i]; if (!d || !d.daily) return;
    const today = localToday(d);
    (d.daily.time || []).forEach((t: string, j: number) => {
      if (t >= today || t < minDate) return;
      rows.push({ user_id, key: pt.key, date: t, label: pt.label, place_id: pt.place_id, class: pt.class, tz: d.timezone, ...dayRow(d, j),
        kind: 'modelled', source: SRC, attribution: ATTR, fetched_at });
    });
  });

  // here: dominant cell per local day (local date from that cell's own offset)
  const perDay = new Map<string, Map<string, { ms: number; place: Map<string, number> }>>();
  for (const v of vis || []) {
    const c = cellOf(v), idx = cellIdx.get(c); if (idx == null) continue;
    const d = list[idx]; if (!d || !d.daily) continue;
    const date = new Date(Date.parse(v.since) + (d.utc_offset_seconds || 0) * 1000).toISOString().slice(0, 10);
    const day = perDay.get(date) || new Map(); perDay.set(date, day);
    const e = day.get(c) || { ms: 0, place: new Map<string, number>() }; day.set(c, e);
    e.ms += dwell(v); if (v.place_id) e.place.set(v.place_id, (e.place.get(v.place_id) || 0) + dwell(v));
  }
  for (const [date, day] of perDay) {
    const [c, e] = [...day.entries()].sort((a, b) => b[1].ms - a[1].ms)[0];
    const d = list[cellIdx.get(c)!]; const j = (d.daily.time || []).indexOf(date);
    if (j < 0 || date >= localToday(d) || date < minDate) continue;
    const pid = [...e.place.entries()].sort((a, b) => b[1] - a[1])[0]?.[0] ?? null;
    const p: any = pid ? placeById.get(pid) : null;
    rows.push({ user_id, key: 'here', date, label: p ? p.label : 'Here', place_id: pid, class: p ? p.class : null, tz: d.timezone, ...dayRow(d, j),
      kind: 'modelled', source: SRC, attribution: ATTR, fetched_at });
  }

  if (!rows.length) return `skip (no completed days in ${pastDays} d window)`;
  for (let k = 0; k < rows.length; k += 500) {
    const { error } = await sb.from('akatsuki_weather_daily').upsert(rows.slice(k, k + 500), { onConflict: 'user_id,key,date' });
    if (error) throw new Error('history ' + error.message);
  }
  const nHere = rows.filter((r) => r.key === 'here').length;
  return `ok ${rows.length} rows · ${pastDays} d · places ${(places || []).length} · here ${nHere} days`;
}

const RUN: Record<string, (u: string, f: boolean, b?: any) => Promise<string>> = { fx, climate, forecast, weather, weather_history };

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
    try { out[r.id] = await RUN[r.id](r.user_id, !!body.force, body); }
    catch (e) { out[r.id] = 'error ' + (e as Error).message; }
    await mark(r.user_id, r.id, out[r.id]);
  }
  console.log('[akatsuki-sources]', out);
  return json(out);
});
