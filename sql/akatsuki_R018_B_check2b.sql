-- R018 · step 2b checks (Oct 10).  Read-only.  One query at a time; paste each.

-- C1 · Cost's Q2: what happened to the Home visit opened 07:54 after the 08:03 reload?
--      Expected: one row, until null, last_seen_at moving past 08:03 (resumed) —
--      or until = last_seen_at with end_reason 'gap' (closed cleanly).  Two open rows = bug.
select device, since, until, last_seen_at, end_reason, anchor_id, source_app, merged_into
  from akatsuki_visits
 where since >= '2026-10-10 07:50+00' order by since;

-- C2 · no device may hold two open visits
select device, count(*) open_rows from akatsuki_visits
 where until is null and merged_into is null group by device having count(*) > 1;

-- C3 · coverage vs visits: every visit should sit inside a watched window (K4 shape)
select device, since, until, until - since watched from akatsuki_location_coverage
 where since >= '2026-10-09' order by device, since;

-- Then run K1–K4 in akatsuki_location_R018_B_compare.sql.
