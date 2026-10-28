-- R051 (filed as R048 in Akatsuki#1; renumbered 2026-10-28 — R048 is the mail migration. Live migration
--       record keeps its name akatsuki_r048_visit_points; live strings may say R048.)
-- R051 · akatsuki_visit_points — the user's own stays WITH coordinates, for Setu (route hub → setu visit.points, view).
-- Asked by Setu on 2026-10-24, approved by the user ("Akatsuki is there to support everyone").
-- Why: Setu pins a spot from where the user stood, shows "last here" per spot and a "Right now" fallback when the phone
-- won't share location. akatsuki_visits_recent stays coordinate-free (waist rule) for every other consumer;
-- Neurology / HealthLog keep reading place_id + class + timing only. Only Setu has a route to this view.
-- Same RLS as the table (security_invoker): each signed-in user sees only their own rows; anon gets nothing.
-- Idempotent.

create or replace view akatsuki_visit_points with (security_invoker = on) as
select v.seq, v.device, v.since, v.until, v.last_seen_at, coalesce(v.until, v.last_seen_at) - v.since as dur,
       v.lat, v.lng, v.radius_m, v.acc_m, v.place_id, p.label as place_label, p.class
  from akatsuki_visits v
  left join akatsuki_places p on p.user_id = v.user_id and p.id = v.place_id
 where v.merged_into is null and v.since > now() - interval '90 days' and v.lat is not null and v.lng is not null;

revoke all on akatsuki_visit_points from anon, authenticated;   -- drop Supabase's default write grants too
grant select on akatsuki_visit_points to authenticated;

comment on view akatsuki_visit_points is
  'R048 · own stays with lat/lng, last 90 days. Consumer: Setu only (route hub→setu visit.points). Other apps use akatsuki_visits_recent (no coordinates).';

-- registry
insert into akatsuki_routes (user_id, from_app, to_app, kind, access, state, note) values
  ('e91a5f37-e63a-4fd0-8488-4d7a51d56822', 'hub', 'setu', 'visit.points', 'view', 'proposed',
   'R048 — akatsuki_visit_points (own stays + lat/lng, 90 d). Pin from a stay, last-here per spot, Right now fallback. Live when Setu pins a spot from a stay.')
on conflict (user_id, from_app, to_app, kind) do update set access = excluded.access, note = excluded.note;
