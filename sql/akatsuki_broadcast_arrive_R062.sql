-- ============================================================================
-- Akatsuki R062 · broadcasts on arrival at a place — 2026-11-04.  Idempotent.  Runs after R058.
-- The person's request: a message that pops up when I reach a place where I'll surely look at the phone.
-- First places: Home and Office.  Default rule: first arrival of the day.
--
--   A rule = (place, title, body, mode).  It never shows by itself.  When a visit at that place begins,
--   the rule FIRES: it inserts an ordinary akatsuki_broadcasts row due now, so the overlay, Done/Snooze
--   and the phone push work exactly as for timed broadcasts (no change to the overlay or the push function).
--     mode 'daily_first'  fires on the first arrival of each day (Asia/Tokyo date), then waits for tomorrow
--     mode 'once'         fires on the next arrival, then the rule is 'fired' (the manual one-off)
--   "Arrival" = a row in akatsuki_visits gets this place_id: OwnTracks (akatsuki_ping), an app
--   (akatsuki_visit_open) or a later naming (akatsuki_place_here).  A trigger on the table covers all three.
--   OwnTracks opens a visit after ~4 min of dwelling, so expect the message a few minutes after arriving.
--
--   Guards: only arrivals that began after the rule was made, and within the last 2 hours (an OwnTracks
--   backlog flush must not fire yesterday's arrival).  Two devices opening the same visit fire once
--   (the rule row is locked, last_fired_on checked).  The trigger never fails a visit write: any error
--   becomes a WARNING and the location data is kept.
--
-- Writes only through the RPCs.  RLS: owner reads.
-- ============================================================================

-- ═══ A · rules table ═══════════════════════════════════════════════════════
create table if not exists public.akatsuki_broadcast_rules (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null default auth.uid() references auth.users(id) on delete cascade,
  place_id       text not null,
  title          text not null check (char_length(btrim(title)) between 1 and 120),
  body           text check (body is null or char_length(body) <= 1000),
  mode           text not null default 'daily_first' check (mode in ('daily_first', 'once')),
  state          text not null default 'active' check (state in ('active', 'fired', 'cancelled')),
  last_fired_on  date,
  last_fired_at  timestamptz,
  fired_count    int not null default 0,
  created_by     text not null default akatsuki_actor(),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  foreign key (user_id, place_id) references public.akatsuki_places (user_id, id)
);
create index if not exists akatsuki_broadcast_rules_place_idx on public.akatsuki_broadcast_rules (user_id, place_id) where state = 'active';
alter table public.akatsuki_broadcast_rules enable row level security;
drop policy if exists akatsuki_broadcast_rules_read on public.akatsuki_broadcast_rules;
create policy akatsuki_broadcast_rules_read on public.akatsuki_broadcast_rules for select to authenticated using (user_id = auth.uid());
revoke all on public.akatsuki_broadcast_rules from anon, authenticated;
grant select on public.akatsuki_broadcast_rules to authenticated;

-- a fired broadcast remembers its rule
alter table public.akatsuki_broadcasts add column if not exists rule_id uuid references public.akatsuki_broadcast_rules(id) on delete set null;


-- ═══ B · RPCs for pages (signed in) ════════════════════════════════════════
create or replace function public.akatsuki_broadcast_rule_add(p_place_id text, p_title text, p_body text default null,
                                                              p_mode text default 'daily_first', p_app text default null)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare v uuid;
begin
  if auth.uid() is null then perform akatsuki_fail('42501', 'not_signed_in', 'sign in first'); end if;
  if char_length(btrim(coalesce(p_title, ''))) not between 1 and 120 then perform akatsuki_fail('AK102', 'bad_title', 'title must be 1–120 characters'); end if;
  if char_length(coalesce(p_body, '')) > 1000 then perform akatsuki_fail('AK102', 'bad_body', 'body must be at most 1000 characters'); end if;
  if coalesce(p_mode, '') not in ('daily_first', 'once') then perform akatsuki_fail('AK102', 'bad_mode', 'mode is daily_first or once'); end if;
  if not exists (select 1 from akatsuki_places pl where pl.user_id = auth.uid() and pl.id = p_place_id
                   and pl.retired_at is null and pl.lat is not null and pl.lng is not null) then
    perform akatsuki_fail('AK102', 'bad_place', 'unknown place, or the place has no coordinates');
  end if;
  insert into akatsuki_broadcast_rules (user_id, place_id, title, body, mode, created_by)
  values (auth.uid(), p_place_id, btrim(p_title), nullif(btrim(coalesce(p_body, '')), ''), p_mode,
          left(coalesce(nullif(btrim(p_app), ''), akatsuki_actor()), 40))
  returning id into v;
  return v;
end $$;

create or replace function public.akatsuki_broadcast_rule_cancel(p_id uuid)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  update akatsuki_broadcast_rules set state = 'cancelled', updated_at = now()
   where id = p_id and user_id = auth.uid() and state = 'active';
end $$;

revoke execute on function akatsuki_broadcast_rule_add(text, text, text, text, text), akatsuki_broadcast_rule_cancel(uuid) from public, anon;
grant  execute on function akatsuki_broadcast_rule_add(text, text, text, text, text), akatsuki_broadcast_rule_cancel(uuid) to authenticated;


-- ═══ C · the arrival trigger ═══════════════════════════════════════════════
create or replace function public.akatsuki_broadcast_on_arrival()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare r akatsuki_broadcast_rules; d date; v uuid;
begin
  if new.place_id is null then return new; end if;
  if tg_op = 'UPDATE' and old.place_id is not distinct from new.place_id then return new; end if;
  if new.since < now() - interval '2 hours' then return new; end if;            -- backlog, not an arrival now
  d := (new.since at time zone 'Asia/Tokyo')::date;
  begin
    for r in select * from akatsuki_broadcast_rules br
              where br.user_id = new.user_id and br.place_id = new.place_id and br.state = 'active'
                and br.created_at <= new.since
              order by br.created_at
              for update loop
      if r.mode = 'daily_first' and r.last_fired_on = d then continue; end if;
      insert into akatsuki_broadcasts (user_id, title, body, due_at, created_by, rule_id)
      values (r.user_id, r.title, r.body, now(), left('arrive:' || r.place_id, 40), r.id)
      returning id into v;
      update akatsuki_broadcast_rules
         set last_fired_on = d, last_fired_at = now(), fired_count = fired_count + 1,
             state = case when mode = 'once' then 'fired' else state end, updated_at = now()
       where id = r.id;
    end loop;
  exception when others then
    raise warning 'akatsuki_broadcast_on_arrival: % (%)', sqlerrm, sqlstate;   -- never block the visit write
  end;
  return new;
end $$;
revoke execute on function akatsuki_broadcast_on_arrival() from public, anon, authenticated;

drop trigger if exists akatsuki_visits_arrival_broadcast on public.akatsuki_visits;
create trigger akatsuki_visits_arrival_broadcast
  after insert or update of place_id on public.akatsuki_visits
  for each row execute function public.akatsuki_broadcast_on_arrival();
