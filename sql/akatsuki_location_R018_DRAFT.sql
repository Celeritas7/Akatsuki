-- ═══════════════════════════════════════════════════════════════════════════
-- R018 · DRAFT v2 · hub location schema — revised against Cost's STEP0 reply (Oct 5).
-- NOT RUN yet. Gate: probe Q1–Q8 results (for-cost/COST-REPLY-R018.md A5) + user's two decisions (§D).
-- Same Supabase project as Cost (wylxvmkcrexwfpjpbhyy): hub tables and Cost tables sit side by side.
-- Rules: CLAUDE.md v3.4 · nothing in Cost deleted until the hub runs the feature live · one feature at a time.
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── P · probe results (Oct 5) ──────────────────────────────────────────────
-- All 9 tables EXIST live, RLS owner-policy on every one (011/012 were applied).  Ids are UUID, not bigint.
-- areas 9 · area_points 11 · shop_locations 102 · triggers 5 · stops 6 (since Sep 21) · stop_blocks 3 · places_cache 0 · places_usage 0.
-- Google has NEVER been called through the shared tables → G1 (cache migration) is empty: nothing to move, hub starts clean.
-- Bug #1a confirmed: stop s1790225401098 at "Ageo office", 04:50→09:08 (4 h 18 m) = the background-swallow shape.
-- Bug #1b: one duplicate pair 5 m apart (s1789973821301 + one more within the hour).
-- Bug #2: both blocks sit ON a pinned spot of the same name (Ichikawa 5 m, Ageo office 16 m) → the user blocked home + office by tapping
--         the pin.  Under D2 these become places (class home / office), not blocks.
-- ⚠ Only 6 stops on the server; the phone's localStorage cm_stops may hold more (cap 150).  Dump it before G4's compare.

-- ─── D · two decisions for the user (Cost's proposals, adopted here unless you say otherwise) ──
-- D1 ✓ CONFIRMED by user Oct 5 · bug #1 (background inflation): a visit ENDS at the last fix seen inside, never at resume time.  A gap
--    (hidden tab, killed app, no fix for > 2 ticks) closes the open visit at last_seen_at and the detector
--    re-anchors.  Coverage is recorded separately (§2b) so "no visit" ≠ "wasn't watching".
-- D2 ✓ CONFIRMED by user Oct 5 · bug #2 (blocked anchor): the hub has NO block table.  Home/Office are places; the detector records visits
--    there like anywhere else.  Each consumer filters: Cost keeps its own "never here" list; Health/Neurology see
--    home visits.  Consequence to confirm: the hub will hold your home visits (RLS user_id = auth.uid(), as everything).

-- ─── 0 · exists already ─────────────────────────────────────────────────────
-- akatsuki_places (R023)            registry; gains lat/lng/radius_m here.  Cost's area_points that are shops → anchors, not places.
-- akatsuki_cache (R001)             Google results.  akatsuki_sources 'places_nearby' (R002).  Credential row → Edge secret.

-- ─── 1 · devices ────────────────────────────────────────────────────────────
create table if not exists akatsuki_devices (
  user_id      uuid not null default auth.uid(),
  id           text not null,                 -- minted once by akatsuki-location.js, localStorage akatsuki_device
  app          text not null,                 -- app that minted it
  label        text,
  last_seen_at timestamptz,
  created_at   timestamptz not null default now(),
  primary key (user_id, id)
);

-- ─── 2 · visits — crosses the waist; never a raw fix ─────────────────────────
-- Dropped from Cost's shape (C12): status open/logged/dismissed, shop, category, near, pinned, blocked, region.
create table if not exists akatsuki_visits (
  user_id      uuid not null default auth.uid(),
  device       text not null,
  since        timestamptz not null,          -- first accepted fix at the anchor (coords.timestamp, NOT receipt time)
  until        timestamptz,                   -- null while open.  On close = last_seen_at.  NEVER now().
  last_seen_at timestamptz not null,          -- heartbeat ≤ every 120 s
  lat          double precision not null,     -- eased anchor, rounded to 4 dp (≈ 10 m) on write
  lng          double precision not null,
  radius_m     int not null default 70,
  acc_m        int,                           -- best accuracy seen during the visit
  place_id     text,                          -- akatsuki_places.id if the anchor falls inside one
  anchor_id    text,                          -- akatsuki_anchors.id if inside a learned/declared anchor
  end_reason   text,                          -- left | gap | app_closed | merged  (null while open)
  merged_into  bigint,                        -- seq of the surviving row when two devices/apps overlapped
  source_app   text not null,
  app_times    jsonb,                         -- sender's clocks, diagnosis only
  seq          bigint not null default nextval('akatsuki_seq'),
  updated_seq  bigint not null default nextval('akatsuki_seq'),
  primary key (user_id, device, since)
);
create index if not exists akatsuki_visits_open on akatsuki_visits (user_id, device) where until is null;
create index if not exists akatsuki_visits_time on akatsuki_visits (user_id, since desc);

-- ─── 2b · coverage — when was anyone watching?  (fixes C14 #2: "no gap marker") ──
create table if not exists akatsuki_location_coverage (
  user_id    uuid not null default auth.uid(),
  device     text not null,
  app        text not null,
  since      timestamptz not null,            -- detector started (app open + watch granted)
  until      timestamptz,                     -- last tick seen; null while running
  seq        bigint not null default nextval('akatsuki_seq'),
  primary key (user_id, device, since)
);

-- ─── 3 · areas · anchors  (no blocks — D2) ───────────────────────────────────
-- area  = Cost's cost_management_areas minus `region` (a currency code).  Cost maps area → currency itself.
create table if not exists akatsuki_areas (
  user_id    uuid not null default auth.uid(),
  id         text not null,                   -- Cost's uuid as text on migration; slug for new ones
  label      text not null,
  lat        double precision,                -- nullable in Cost today
  lng        double precision,
  radius_m   int not null default 500,
  country    text,                            -- 'JP' — replaces region
  tz         text,                            -- 'Asia/Tokyo'
  added_by   text not null,
  seq        bigint not null default nextval('akatsuki_seq'),
  retired_at timestamptz,
  primary key (user_id, id)
);
-- anchor = Cost's area_points: a point you stop at (manual) or the detector learned (auto, confirmed later).
-- `entity_ref` replaces the "label == shop name" convention AND gives trigger geofences a home (C12 amendment 4).
create table if not exists akatsuki_anchors (
  user_id    uuid not null default auth.uid(),
  id         text not null,
  area_id    text,                            -- → akatsuki_areas.id
  place_id   text,                            -- → akatsuki_places.id when promoted to a named place
  label      text,
  entity_ref jsonb,                           -- {"app":"cost","kind":"shop","id":"…"} | {"app":"cost","kind":"trigger","id":"…"}
  lat        double precision not null,
  lng        double precision not null,
  radius_m   int not null default 200,
  source     text not null default 'manual',  -- manual | auto
  confirmed  boolean not null default false,
  visits     int not null default 0,
  first_seen timestamptz not null default now(),
  last_seen  timestamptz not null default now(),
  added_by   text not null,
  seq        bigint not null default nextval('akatsuki_seq'),
  retired_at timestamptz,
  primary key (user_id, id)
);

-- ─── 4 · detector settings — generic half only (C12 amendment 1).  Cost keeps perCat/cats/seed. ──
create table if not exists akatsuki_stop_settings (
  user_id        uuid primary key default auth.uid(),
  enabled        boolean not null default true,
  radius_m       int not null default 70,     -- Cost live value
  dwell_s        int not null default 240,    -- Cost defaultMinutes 4
  unknown_ok     boolean not null default true,
  accuracy_max_m int not null default 150,    -- Cost live value.  Leave decisions additionally require distance − acc > R.
  stale_s        int not null default 120,
  heartbeat_s    int not null default 120,
  readopt_s      int not null default 600,    -- re-adopt an open visit seen ≤ 10 min ago within R + acc (replaces 2 h startedAt)
  tick_s         int not null default 20,
  updated_at     timestamptz not null default now()
);

-- ─── 5 · Google Places — hub Edge Function `akatsuki-places-nearby` ─────────
-- Closes B8: verifies the user JWT, counts and caps SERVER-SIDE, one shared cap (not per device).
-- Mask adds places.id (same Pro SKU).  Request as Cost's: searchNearby · 10 · DISTANCE · 150 m.
-- Key: Supabase Edge secret GOOGLE_PLACES_API_KEY — the SAME secret Cost's function reads (same project).  Nothing moves;
--      Cost's `places-nearby` is deleted only at gate G3.
-- Cache  akatsuki_cache: source 'places_nearby', key 'g:<lat4>,<lng4>' (4 dp grid, ≈ 10 m; lookup = nearest row ≤ 100 m, as Cost)
--        payload {q:{lat,lng}, candidates:[{place_id,name,types[],lat,lng,distance_m}]}  expires_at = +30 d (+7 d when empty).
-- Usage  akatsuki_cache: source 'places_usage', key 'YYYY-MM', payload {calls, cap}.  Counted in the Edge Function, SUM not MAX.
-- Call   app → supabase.functions.invoke('akatsuki-places-nearby', {lat,lng,force}) → {status:'hit'|'fetched'|'capped'|'error', candidates}
--        Button-only today; stays synchronous because the user is waiting on a tap (not a render path).  Any detector-driven lookup later
--        MUST go through the queue (CLAUDE.md Sources).

-- ─── 6 · kinds (vocab) ──────────────────────────────────────────────────────
-- visit.open      {device, since, lat, lng, radius_m, acc_m}        req: device, since, lat, lng
-- visit.heartbeat {device, since, last_seen_at}
-- visit.close     {device, since, until, end_reason}                until = last_seen_at
-- coverage.open / coverage.close {device, since[, until]}
-- anchor.learned  {id, lat, lng, radius_m, first_seen}              detector → hub (source auto)
-- All <any app> → hub, hub-merged.  '' in a required string → AK102.

-- ─── 7 · RLS — same rule, every table ────────────────────────────────────────
-- akatsuki_devices · akatsuki_visits · akatsuki_location_coverage · akatsuki_areas · akatsuki_anchors · akatsuki_stop_settings

-- ─── 8 · views for consumers (security_invoker = on) ────────────────────────
-- akatsuki_where_now      one open visit per device → place_id, class, anchor_id, since.  null row = moving or not watched.
-- akatsuki_visits_recent  last 30 d: since, until, end_reason, place_id, class, device.  No lat/lng.
-- akatsuki_cost_areas     Cost reads areas/anchors here during G2 (view over hub tables, Cost keys shop↔area by hub area id).
-- Neurology gets place_id + class + timing only — never coordinates (waist rule).

-- ─── 9 · gates — Cost's order (C13).  Cost deletes nothing until each ✓. ────
-- G1 places cache + usage   probe: BOTH EMPTY → no migration.  Hub cache starts clean; Cost's tables stay until G3 then retire.
-- G2 areas + anchors        migrate 9 areas + 11 area_points → akatsuki_areas/anchors (uuid kept as text id); Cost's 4 write sites → hub RPCs ·
--                           ✓ ShopAreasPanel shows the same list; shop↔area re-keyed to hub ids.
-- G3 Google fetch + key     deploy akatsuki-places-nearby; Cost invokes it · ✓ one tap returns candidates with place_id; usage row increments ·
--                           then Cost's places-nearby function is removed.
-- G4 visits + detector + settings  akatsuki-location.js (A4 fixes built in) runs inside Cost next to Cost's detector for N days ·
--                           compare akatsuki_visits vs cm_stops · ✓ then Cost's sessionizer, stops, stop_blocks, stop_settings retire.

-- ─── open before finalising ─────────────────────────────────────────────────
-- · D1, D2 confirmed by the user  (probe done Oct 5 — see §P)
-- · With G1 empty, first real step = G2 (areas + anchors) + G3 (Google fn) — can be one R018 part A.
-- · Later R-step (not here): fare book / bands / JR graph as hub facts (D)
