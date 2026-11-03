-- ============================================================================
-- Akatsuki R059 · roadmap_contexts_map → owner-only, like every other roadmap_* table — 2026-11-03.
-- Idempotent.  Applied live 2026-11-03 (hub session, on the person's go — handover open item 8).
--
-- Before: any signed-in user could read all 7 rows (policy roadmap_contexts_map_read, qual true),
-- and anon/authenticated still held every table grant (RLS stopped the writes).
-- The table had no owner column, so it gets one: user_id default auth.uid(), the 7 rows → the owner.
--
-- Nothing reads it today: Roadmap_advanced's code does not touch it (only its migration 0002 made it),
-- and the contexts live in akatsuki_vocab (ns = 'context', same 7 ids).  Roadmap's STEP1-join plan
-- is to drop this table; until then it is owner-only.
-- ============================================================================

alter table public.roadmap_contexts_map add column if not exists user_id uuid default auth.uid() references auth.users(id) on delete cascade;
update public.roadmap_contexts_map set user_id = 'e91a5f37-e63a-4fd0-8488-4d7a51d56822' where user_id is null;
alter table public.roadmap_contexts_map alter column user_id set not null;

alter table public.roadmap_contexts_map enable row level security;
drop policy if exists roadmap_contexts_map_read  on public.roadmap_contexts_map;
drop policy if exists roadmap_contexts_map_owner on public.roadmap_contexts_map;
create policy roadmap_contexts_map_owner on public.roadmap_contexts_map for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

revoke all on public.roadmap_contexts_map from anon;
revoke truncate, references, trigger on public.roadmap_contexts_map from authenticated;
