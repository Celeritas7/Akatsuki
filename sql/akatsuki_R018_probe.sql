-- R018 · probe · run in the SQL editor (project wylxvmkcrexwfpjpbhyy), ONE query at a time, paste each result.
-- From Cost's STEP0 reply A5.  Read-only.

-- Q1 · which location tables exist
select table_name from information_schema.tables where table_schema='public'
 and table_name in ('cost_management_areas','cost_management_area_points','cost_management_shop_locations',
 'cost_management_stops','cost_management_stop_blocks','cost_management_stop_settings',
 'cost_management_places_usage','cost_management_places_cache','cost_management_triggers');

-- Q2 · RLS + policies as applied
select c.relname, c.relrowsecurity, p.policyname, p.cmd, p.roles, p.qual, p.with_check
 from pg_class c left join pg_policies p on p.tablename=c.relname
 where c.relname like 'cost_management_%' and c.relkind='r' order by 1;

-- Q3 · live columns
select table_name, column_name, data_type, column_default, is_nullable from information_schema.columns
 where table_name in ('cost_management_areas','cost_management_area_points','cost_management_shop_locations') order by 1, ordinal_position;

-- Q4 · counts + oldest.  If Q1 lacks a table, delete its line before running.
select 'areas' t, count(*), min(created_at) from cost_management_areas
union all select 'area_points', count(*), min(created_at) from cost_management_area_points
union all select 'shop_locations', count(*), min(created_at) from cost_management_shop_locations
union all select 'triggers', count(*), min(updated_at) from cost_management_triggers
union all select 'stops', count(*), min(started_at) from cost_management_stops
union all select 'stop_blocks', count(*), min(created_at) from cost_management_stop_blocks
union all select 'places_cache', count(*), min(created_at) from cost_management_places_cache
union all select 'places_usage', count(*), min(updated_at) from cost_management_places_usage;

-- Q5 · Google usage by month (skip if places_usage missing)
select month, calls from cost_management_places_usage order by month desc;

-- Q6 · bug #1a: long visits (skip if stops missing)
select id, started_at, ended_at, ended_at-started_at dur, shop, near from cost_management_stops
 where ended_at-started_at > interval '45 min' order by dur desc limit 20;

-- Q7 · bug #1b: near-duplicate visits
select a.id, b.id, a.started_at, b.started_at,
 round((6371000*2*asin(sqrt(power(sin(radians(b.lat-a.lat)/2),2)+cos(radians(a.lat))*cos(radians(b.lat))*power(sin(radians(b.lng-a.lng)/2),2))))::numeric) d_m
 from cost_management_stops a join cost_management_stops b on a.id<b.id
 and abs(extract(epoch from b.started_at-a.started_at))<3600
 where 6371000*2*asin(sqrt(power(sin(radians(b.lat-a.lat)/2),2)+cos(radians(a.lat))*cos(radians(b.lat))*power(sin(radians(b.lng-a.lng)/2),2)))<150 limit 20;

-- Q8 · bug #2: pinned spots within 150 m of a block
select bl.label block, ap.label spot,
 round((6371000*2*asin(sqrt(power(sin(radians(ap.lat-bl.lat)/2),2)+cos(radians(bl.lat))*cos(radians(ap.lat))*power(sin(radians(ap.lng-bl.lng)/2),2))))::numeric) d_m
 from cost_management_stop_blocks bl, cost_management_area_points ap
 where 6371000*2*asin(sqrt(power(sin(radians(ap.lat-bl.lat)/2),2)+cos(radians(bl.lat))*cos(radians(ap.lat))*power(sin(radians(ap.lng-bl.lng)/2),2)))<150 order by d_m;

-- If Q1 shows no stops tables: in the Cost PWA console run  JSON.parse(localStorage.cm_stops)  and paste that instead of Q6/Q7.
