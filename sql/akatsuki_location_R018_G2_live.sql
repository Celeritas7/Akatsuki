-- R018 · G2 live (Oct 5) — Cost v50: create, rename, add spot, merge, delete (retire) all verified by the user on test areas.
-- Keep/Drop untested (no learned spots yet) — same RPC as the others; not a blocker.
-- Run whole file once.  Deletes nothing.

update akatsuki_routes
   set state = 'live',
       note = 'LIVE Oct 5 — Cost v50 reads akatsuki_cost_areas/_area_points; create/rename/add-spot/merge/retire verified live by user. Keep/Drop pending first learned spot. ' || note
 where from_app = 'hub' and to_app = 'cost' and kind = 'areas' and state <> 'live';

-- Lists match (Cost's two queries).  Empty = hub and Cost agree on the 9 areas / 11 points copied Oct 5.
-- Test areas the user created in the hub since then show here as c.id null — expected, not drift.
select coalesce(c.id::text, h.id) id, c.name cost_name, h.name hub_name, c.region c_reg, h.region h_reg,
       case when c.id is null then 'hub-only (new)' when h.id is null then 'cost-only (MISSING)' else 'differs' end why
  from cost_management_areas c full join akatsuki_cost_areas h on h.id = c.id::text
 where c.id is null or h.id is null or c.name is distinct from h.name or c.lat is distinct from h.lat
    or c.lng is distinct from h.lng or c.radius_m is distinct from h.radius_m or c.region is distinct from h.region;

select coalesce(c.id::text, h.id) id, c.label, h.label hub_label, h.shop_name, c.confirmed, h.confirmed hub_conf,
       case when c.id is null then 'hub-only (new)' when h.id is null then 'cost-only (MISSING or retired)' else 'differs' end why
  from cost_management_area_points c full join akatsuki_cost_area_points h on h.id = c.id::text
 where c.id is null or h.id is null or c.area_id::text is distinct from h.area_id or c.radius_m is distinct from h.radius_m
    or c.confirmed is distinct from h.confirmed or c.label is distinct from h.label;
