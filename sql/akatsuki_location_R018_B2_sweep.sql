-- R018 · B2 · server-side sweep for abandoned open visits (Oct 10).  Run once, whole file.
-- Why: C1 showed Home (since 07:54) still open hours later, last seen 08:00:39.  Cost reloaded at
-- 08:03, the detector never got a good fix, so akatsuki_visit_resume never ran.  The row stays open
-- until the next app start on that device, which could be days.
-- Rule: an open visit not seen for readopt_s (600 s) can't be resumed anyway → close it at last seen, 'gap' (D1).
-- Same outcome resume would reach later; resume only continues rows seen within readopt_s, so the two never fight.

create extension if not exists pg_cron;

create or replace function akatsuki_visit_sweep()
returns int language plpgsql security definer set search_path = public as $$
declare r record; v_other bigint; n int := 0;
begin
  for r in
    update akatsuki_visits v
       set until = greatest(v.since, v.last_seen_at), end_reason = 'gap', updated_seq = nextval('akatsuki_seq')
      from (select v2.user_id, v2.device, v2.since from akatsuki_visits v2
              left join akatsuki_stop_settings s on s.user_id = v2.user_id
             where v2.until is null
               and v2.last_seen_at < now() - make_interval(secs => coalesce(s.readopt_s, 600))) x
     where v.user_id = x.user_id and v.device = x.device and v.since = x.since
    returning v.user_id, v.device, v.since, v.until, v.lat, v.lng
  loop
    n := n + 1;
    -- same hub-merge step as akatsuki_visit_close, scoped to the row's own user (service caller scopes user_id itself)
    select o.seq into v_other from akatsuki_visits o
     where o.user_id = r.user_id and o.device <> r.device and o.merged_into is null
       and o.since <= r.since and coalesce(o.until, o.last_seen_at) >= r.since
       and akatsuki_distance_m(o.lat, o.lng, r.lat, r.lng) <= 100
     order by o.since limit 1;
    if v_other is not null then
      update akatsuki_visits set merged_into = v_other
       where user_id = r.user_id and device = r.device and since = r.since;
    end if;
  end loop;
  return n;
end $$;

revoke execute on function akatsuki_visit_sweep() from public, anon, authenticated;

select cron.unschedule('akatsuki-visit-sweep') where exists (select 1 from cron.job where jobname = 'akatsuki-visit-sweep');
select cron.schedule('akatsuki-visit-sweep', '*/10 * * * *', $$ select akatsuki_visit_sweep(); $$);

-- Run now, then check: expect 1 (the Home row), then no open row older than 10 min.
select akatsuki_visit_sweep() closed_now;
select device, since, until, last_seen_at, end_reason from akatsuki_visits
 where since >= '2026-10-10 07:50+00' order by since;
select jobname, schedule, active from cron.job where jobname = 'akatsuki-visit-sweep';
