-- ============================================================================
-- Akatsuki R056 · per-function daily call caps — 2026-10-28.  Idempotent.
--
-- For edge functions that spend a paid quota and cannot (yet) require a signed-in
-- user.  First user: claude-proxy (Code_sensei), cap 200 calls/day, because its
-- shared secret ships in a public page (audit 2026-10-28).
--   select akatsuki_fn_budget_take('claude-proxy', 200);   -- → calls used today, or AK210 when over
-- The day is Asia/Tokyo.  Service role only: pages never touch it.
-- ============================================================================

create table if not exists public.akatsuki_fn_budget (
  fn   text not null,
  day  date not null,
  n    int  not null default 0,
  primary key (fn, day)
);
alter table public.akatsuki_fn_budget enable row level security;   -- no policies: service role only
revoke all on public.akatsuki_fn_budget from anon, authenticated;

create or replace function public.akatsuki_fn_budget_take(p_fn text, p_cap int)
returns int language plpgsql security definer set search_path to 'public' as $$
declare v int; d date := (now() at time zone 'Asia/Tokyo')::date;
begin
  insert into akatsuki_fn_budget (fn, day, n) values (p_fn, d, 1)
  on conflict (fn, day) do update set n = akatsuki_fn_budget.n + 1
  returning n into v;
  if v > p_cap then
    raise exception using errcode = 'AK210', message = format('akatsuki AK210: %s daily cap %s reached', p_fn, p_cap), hint = 'capped';
  end if;
  return v;
end $$;
revoke execute on function akatsuki_fn_budget_take(text, int) from public, anon, authenticated;
grant execute on function akatsuki_fn_budget_take(text, int) to service_role;

-- Keep 90 days.
delete from akatsuki_fn_budget where day < current_date - 90;
