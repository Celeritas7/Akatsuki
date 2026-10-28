-- ============================================================================
-- Akatsuki R054 · broadcasts — a due message covers every app's screen, plus a phone push.
-- 2026-10-28.  Idempotent.  Runs after akatsuki_keys_2026-10-28.sql.
--
--   A broadcast is one row: title, body, due_at.  One-off only (no repeats in v1).
--   · Every app loads js/akatsuki-broadcast.js.  From show_at (= snoozed_until or due_at)
--     until Done, the app is covered by a full-screen overlay.  The only ways out are
--     Done and Snooze — answered once, it is gone from every app (the row is shared).
--   · A device that was off at the due time shows it the next time any app opens:
--     nothing expires, so nothing is missed.
--   · Phone: pg_cron checks every minute; when a broadcast reaches show_at and has not been
--     pushed for that show_at, akatsuki-broadcast-push sends a web push to every device the
--     person switched on (akatsuki_push_subscriptions).  Snooze moves show_at → pushed again.
--   · Adding: the hub page's Broadcasts panel for now; Roadmap's section later (same RPC).
--
-- Owner: the hub.  Writes only through the RPCs below (no direct insert/update grants).
-- Web-push keys (VAPID) live in Vault: akatsuki_vapid_public / akatsuki_vapid_private.
-- akatsuki-broadcast-push creates them on its first run; the private key never leaves the server.
-- ============================================================================

-- ═══ A · tables ═════════════════════════════════════════════════════════════
create table if not exists public.akatsuki_broadcasts (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null default auth.uid() references auth.users(id) on delete cascade,
  title         text not null check (char_length(btrim(title)) between 1 and 120),
  body          text check (body is null or char_length(body) <= 1000),
  due_at        timestamptz not null,
  snoozed_until timestamptz,
  show_at       timestamptz generated always as (coalesce(snoozed_until, due_at)) stored,
  state         text not null default 'scheduled' check (state in ('scheduled', 'done', 'cancelled')),
  snoozes       int not null default 0,
  created_by    text not null default akatsuki_actor(),
  done_at       timestamptz,
  done_by       text,
  pushed_for    timestamptz,             -- the show_at last pushed; differs from show_at → push due
  push_note     text,                    -- last push result, for the hub page
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists akatsuki_broadcasts_due_idx on public.akatsuki_broadcasts (user_id, show_at) where state = 'scheduled';
alter table public.akatsuki_broadcasts enable row level security;
drop policy if exists akatsuki_broadcasts_read on public.akatsuki_broadcasts;
create policy akatsuki_broadcasts_read on public.akatsuki_broadcasts for select to authenticated using (user_id = auth.uid());
revoke all on public.akatsuki_broadcasts from anon, authenticated;
grant select on public.akatsuki_broadcasts to authenticated;

create table if not exists public.akatsuki_push_subscriptions (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  endpoint    text not null unique check (endpoint ~ '^https://'),
  p256dh      text not null,
  auth        text not null,
  device      text check (device is null or char_length(device) <= 80),
  created_at  timestamptz not null default now(),
  last_ok_at  timestamptz,
  last_error  text
);
alter table public.akatsuki_push_subscriptions enable row level security;
drop policy if exists akatsuki_push_subscriptions_own on public.akatsuki_push_subscriptions;
create policy akatsuki_push_subscriptions_own on public.akatsuki_push_subscriptions for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
revoke all on public.akatsuki_push_subscriptions from anon, authenticated;
grant select, delete on public.akatsuki_push_subscriptions to authenticated;   -- add/replace via akatsuki_push_subscribe


-- ═══ B · RPCs for pages (signed in) ═════════════════════════════════════════
create or replace function public.akatsuki_broadcast_add(p_title text, p_body text, p_due_at timestamptz)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare v uuid;
begin
  if auth.uid() is null then perform akatsuki_fail('42501', 'not_signed_in', 'sign in first'); end if;
  if char_length(btrim(coalesce(p_title, ''))) not between 1 and 120 then perform akatsuki_fail('AK102', 'bad_title', 'title must be 1–120 characters'); end if;
  if char_length(coalesce(p_body, '')) > 1000 then perform akatsuki_fail('AK102', 'bad_body', 'body must be at most 1000 characters'); end if;
  if p_due_at is null or p_due_at > now() + interval '400 days' then perform akatsuki_fail('AK102', 'bad_due', 'due time is required and within 400 days'); end if;
  insert into akatsuki_broadcasts (user_id, title, body, due_at)
  values (auth.uid(), btrim(p_title), nullif(btrim(coalesce(p_body, '')), ''), p_due_at)
  returning id into v;
  return v;
end $$;

create or replace function public.akatsuki_broadcast_done(p_id uuid, p_app text default null)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  update akatsuki_broadcasts set state = 'done', done_at = now(), done_by = left(coalesce(nullif(p_app, ''), akatsuki_actor()), 40), updated_at = now()
   where id = p_id and user_id = auth.uid() and state = 'scheduled';
  -- already done elsewhere (or cancelled) is not an error: the overlay just closes
end $$;

create or replace function public.akatsuki_broadcast_snooze(p_id uuid, p_minutes int)
returns timestamptz language plpgsql security definer set search_path to 'public' as $$
declare v timestamptz;
begin
  if p_minutes is null or p_minutes not between 1 and 1440 then perform akatsuki_fail('AK102', 'bad_snooze', 'snooze is 1–1440 minutes'); end if;
  update akatsuki_broadcasts set snoozed_until = now() + make_interval(mins => p_minutes), snoozes = snoozes + 1, updated_at = now()
   where id = p_id and user_id = auth.uid() and state = 'scheduled'
  returning snoozed_until into v;
  return v;
end $$;

create or replace function public.akatsuki_broadcast_cancel(p_id uuid)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  update akatsuki_broadcasts set state = 'cancelled', updated_at = now()
   where id = p_id and user_id = auth.uid() and state = 'scheduled';
end $$;

create or replace function public.akatsuki_push_subscribe(p_endpoint text, p_p256dh text, p_auth text, p_device text default null)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare v uuid;
begin
  if auth.uid() is null then perform akatsuki_fail('42501', 'not_signed_in', 'sign in first'); end if;
  if coalesce(p_endpoint, '') !~ '^https://' or coalesce(p_p256dh, '') = '' or coalesce(p_auth, '') = '' then
    perform akatsuki_fail('AK102', 'bad_subscription', 'endpoint, p256dh and auth are required'); end if;
  insert into akatsuki_push_subscriptions (user_id, endpoint, p256dh, auth, device)
  values (auth.uid(), p_endpoint, p_p256dh, p_auth, left(p_device, 80))
  on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth,
                                     device = excluded.device, last_error = null
  returning id into v;
  return v;
end $$;

-- The public half of the VAPID pair — pages need it to subscribe.  Null until the push function's first run.
create or replace function public.akatsuki_vapid_public()
returns text language sql stable security definer set search_path to 'public' as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'akatsuki_vapid_public' limit 1
$$;

revoke execute on function akatsuki_broadcast_add(text, text, timestamptz), akatsuki_broadcast_done(uuid, text),
  akatsuki_broadcast_snooze(uuid, int), akatsuki_broadcast_cancel(uuid), akatsuki_push_subscribe(text, text, text, text),
  akatsuki_vapid_public() from public, anon;
grant execute on function akatsuki_broadcast_add(text, text, timestamptz), akatsuki_broadcast_done(uuid, text),
  akatsuki_broadcast_snooze(uuid, int), akatsuki_broadcast_cancel(uuid), akatsuki_push_subscribe(text, text, text, text),
  akatsuki_vapid_public() to authenticated;


-- ═══ C · service-only (akatsuki-broadcast-push) ═════════════════════════════
-- VAPID pair: read, or store once.  Never callable from a page.
create or replace function public.akatsuki_vapid_keys()
returns table (public_key text, private_key text) language sql stable security definer set search_path to 'public' as $$
  select (select decrypted_secret from vault.decrypted_secrets where name = 'akatsuki_vapid_public' limit 1),
         (select decrypted_secret from vault.decrypted_secrets where name = 'akatsuki_vapid_private' limit 1)
$$;
create or replace function public.akatsuki_vapid_init(p_public text, p_private text)
returns text language plpgsql security definer set search_path to 'public' as $$
begin
  if exists (select 1 from vault.secrets where name = 'akatsuki_vapid_public') then
    return (select decrypted_secret from vault.decrypted_secrets where name = 'akatsuki_vapid_public' limit 1);   -- first writer wins
  end if;
  perform vault.create_secret(p_public, 'akatsuki_vapid_public', 'Web-push VAPID public key (R054)');
  perform vault.create_secret(p_private, 'akatsuki_vapid_private', 'Web-push VAPID private key (R054) — server only');
  return p_public;
end $$;

-- Claim every broadcast that reached show_at and has not been pushed for it.  Stamps first, so
-- overlapping runs never double-push.  An old one still pushes once: it is not done yet.
create or replace function public.akatsuki_broadcast_push_claim()
returns table (id uuid, user_id uuid, title text, body text, show_at timestamptz) language plpgsql security definer set search_path to 'public' as $$
begin
  return query
  with due as (
    select b.id from akatsuki_broadcasts b
     where b.state = 'scheduled' and b.show_at <= now() and b.pushed_for is distinct from b.show_at
     for update skip locked
  )
  update akatsuki_broadcasts b set pushed_for = b.show_at
    from due where b.id = due.id
  returning b.id, b.user_id, b.title, b.body, b.show_at;
end $$;

create or replace function public.akatsuki_broadcast_push_note(p_id uuid, p_note text)
returns void language sql security definer set search_path to 'public' as $$
  update akatsuki_broadcasts set push_note = left(p_note, 200) where id = p_id
$$;

revoke execute on function akatsuki_vapid_keys(), akatsuki_vapid_init(text, text), akatsuki_broadcast_push_claim(),
  akatsuki_broadcast_push_note(uuid, text) from public, anon, authenticated;
grant execute on function akatsuki_vapid_keys(), akatsuki_vapid_init(text, text), akatsuki_broadcast_push_claim(),
  akatsuki_broadcast_push_note(uuid, text) to service_role;


-- ═══ D · pg_cron: every minute, only when something is due ══════════════════
select cron.schedule('akatsuki-broadcast-push', '* * * * *', $$
  select net.http_post(
    url     := 'https://wylxvmkcrexwfpjpbhyy.supabase.co/functions/v1/akatsuki-broadcast-push',
    headers := jsonb_build_object('Content-Type','application/json',
                 'apikey', (select decrypted_secret from vault.decrypted_secrets where name = 'akatsuki_secret_key')),
    body    := '{}'::jsonb,
    timeout_milliseconds := 30000)
  where exists (select 1 from akatsuki_broadcasts where state = 'scheduled' and show_at <= now() and pushed_for is distinct from show_at);
$$);
