-- ============================================================================
-- Akatsuki R058 · broadcasts: record who added one, refuse due times in the past — 2026-11-03.
-- Idempotent.  Runs after akatsuki_broadcast_R054.sql.  Applied live 2026-11-03 (hub session, person said go).
--
--   1. akatsuki_broadcast_add gets p_app (optional, like akatsuki_broadcast_done):
--        rpc('akatsuki_broadcast_add', { p_title, p_body, p_due_at, p_app: 'roadmap' })
--      created_by = p_app, else the x-akatsuki-app header, else 'unknown'.  Old 3-argument
--      calls keep working (p_app defaults to null).  The hub's 📣 panel sends 'akatsuki'.
--   2. A due time more than 1 minute in the past is refused (AK102 bad_due).  The minute of
--      grace covers a clock that runs a little fast, and "now" picked in a datetime field.
--   3. The 2 test broadcasts the panel added before this have created_by 'unknown' → 'akatsuki'.
--
-- Order: run this BEFORE the hub page that sends p_app goes live (build R058); a page sending
-- p_app to the old 3-argument function gets "function not found".
-- ============================================================================

-- ═══ A · the RPC (drop the 3-argument one: two overloads would make PostgREST's 3-name call ambiguous)
drop function if exists public.akatsuki_broadcast_add(text, text, timestamptz);

create or replace function public.akatsuki_broadcast_add(p_title text, p_body text, p_due_at timestamptz, p_app text default null)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare v uuid;
begin
  if auth.uid() is null then perform akatsuki_fail('42501', 'not_signed_in', 'sign in first'); end if;
  if char_length(btrim(coalesce(p_title, ''))) not between 1 and 120 then perform akatsuki_fail('AK102', 'bad_title', 'title must be 1–120 characters'); end if;
  if char_length(coalesce(p_body, '')) > 1000 then perform akatsuki_fail('AK102', 'bad_body', 'body must be at most 1000 characters'); end if;
  if p_due_at is null or p_due_at > now() + interval '400 days' then perform akatsuki_fail('AK102', 'bad_due', 'due time is required and within 400 days'); end if;
  if p_due_at < now() - interval '1 minute' then perform akatsuki_fail('AK102', 'bad_due', 'that due time has already passed'); end if;
  insert into akatsuki_broadcasts (user_id, title, body, due_at, created_by)
  values (auth.uid(), btrim(p_title), nullif(btrim(coalesce(p_body, '')), ''), p_due_at,
          left(coalesce(nullif(btrim(p_app), ''), akatsuki_actor()), 40))
  returning id into v;
  return v;
end $$;

revoke execute on function public.akatsuki_broadcast_add(text, text, timestamptz, text) from public, anon;
grant execute on function public.akatsuki_broadcast_add(text, text, timestamptz, text) to authenticated;

-- ═══ B · the two earlier test rows (added from the hub's 📣 panel, the only add path until now)
update public.akatsuki_broadcasts set created_by = 'akatsuki' where created_by = 'unknown';

notify pgrst, 'reload schema';
