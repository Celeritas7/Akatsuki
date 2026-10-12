-- R018 · G4 comparison — Cost's own stops vs the hub's visits, side by side.  Read-only.
-- Run after a few days of normal use with Cost v51+.  One query at a time; paste each.

-- K1 · totals since the hub detector started
select 'hub visits' what, count(*), min(since), max(since) from akatsuki_visits
union all
select 'cost stops', count(*), min(started_at), max(started_at) from cost_management_stops
 where started_at >= (select min(since) from akatsuki_visits);

-- K2 · each Cost stop → the hub visit that overlaps it (within 150 m).  hub_since null = hub missed it.
select c.id, c.started_at, c.ended_at, c.ended_at - c.started_at cost_dur, c.shop, c.near,
       h.since hub_since, h.until hub_until, h.until - h.since hub_dur, h.end_reason
  from cost_management_stops c
  left join lateral (
    select v.* from akatsuki_visits v
     where v.since <= coalesce(c.ended_at, c.started_at) + interval '5 min'
       and coalesce(v.until, v.last_seen_at) >= c.started_at - interval '5 min'
       and akatsuki_distance_m(v.lat, v.lng, c.lat, c.lng) <= 150
     order by abs(extract(epoch from v.since - c.started_at)) limit 1) h on true
 where c.started_at >= (select min(since) from akatsuki_visits)
 order by c.started_at;

-- K3 · hub visits with no Cost stop (expected: home/office, and categories Cost switches off)
select v.since, v.until, v.until - v.since dur, v.end_reason, n.label anchor
  from akatsuki_visits v left join akatsuki_anchors n on n.user_id = v.user_id and n.id = v.anchor_id
 where not exists (select 1 from cost_management_stops c
                    where c.started_at <= coalesce(v.until, v.last_seen_at) + interval '5 min'
                      and coalesce(c.ended_at, c.started_at) >= v.since - interval '5 min'
                      and akatsuki_distance_m(v.lat, v.lng, c.lat, c.lng) <= 150)
 order by v.since;

-- K4 · coverage: when was the hub watching, and the gaps between
select c.device, c.since, c.until, c.until - c.since as watched,
       c.since - lag(c.until) over (partition by c.device order by c.since) as gap_before
  from akatsuki_location_coverage c order by c.device, c.since;
