-- R018 · G3 live (Oct 5) — Cost v50 tap: fetched · 5 candidates · place_id on each · calls 1 · via akatsuki-places-nearby.
-- Run whole file once.  Deletes nothing.

update akatsuki_routes
   set state = 'live',
       note = 'LIVE Oct 5 — Cost v50: first hub tap fetched 5 candidates with place_id, usage 1/1000, no fallback. ' || note
 where from_app = 'cost' and to_app = 'hub' and kind = 'place.nearby' and state <> 'live';

update akatsuki_credentials
   set scope = 'GOOGLE_PLACES_API_KEY — Supabase Edge secret, read by akatsuki-places-nearby (hub, LIVE Oct 5). Cost places-nearby: no caller since v50, retire when user says.',
       consumers = '{hub}'
 where name = 'google_places';

-- Check: one usage row this month, one cache row
select source, key, payload->'calls' calls, jsonb_array_length(payload->'candidates') n, expires_at
  from akatsuki_cache where source in ('places_usage','places_nearby') order by source, key;
