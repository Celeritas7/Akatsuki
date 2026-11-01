-- ============================================================================
-- Akatsuki R057 · akatsuki_addresses — Tapal's addresses for other apps (WF's Vault first).
-- 2026-11-01.  Idempotent.  Applied live 2026-11-01 with Part A, on the person's go (asked for by WF's session).
--
-- Tapal owns the addresses.  This is a read-only view; no app writes Tapal's tables through it.
-- WF keeps a COPY in its Vault tagged src {app:'tapal', id, u} ("Import / Update from Tapal") and never
-- writes back.  Compare updated_at to know when a copy is stale.
--
--   key         'tapal_address:<id>' | 'tapal_sender:<id>'  — stable; use it as the copy's src id
--   source      'tapal_address' | 'tapal_sender'
--   label, name, phone, line, city, district, state, pin, country
--   country     senders: as stored; addresses: null (Tapal does not store it — infer from pin/state)
--   retired     addresses: archived; senders: false
--   updated_at  addresses: updated_at; senders: created_at (senders have no updated_at — R011 B, never run)
--
-- Left out on purpose: notes (free text, stays in Tapal), shipments, tapal_settings (legacy single sender).
-- Scoped to the caller's own rows (user_id = auth.uid()) — Tapal's own read policy is role-based
-- (tapal_my_role() is not null), so without this filter any Tapal role would see every row.
--
-- PART A (one-time, Tapal's data): 4 of 5 tapal_addresses rows have user_id NULL (pre-auth legacy rows).
-- They are invisible through this view until they get an owner.  The person said yes to A (2026-11-01).
-- ============================================================================

-- ═══ A · give the legacy addresses their owner (the hub user) ═════════════════
update public.tapal_addresses set user_id = 'e91a5f37-e63a-4fd0-8488-4d7a51d56822' where user_id is null;

-- ═══ B · the view ════════════════════════════════════════════════════════════
create or replace view public.akatsuki_addresses with (security_invoker = on) as
  select 'tapal_address:' || a.id   as key,
         'tapal_address'::text      as source,
         a.id                       as source_id,
         a.user_id,
         a.label, a.name, a.phone, a.line, a.city, a.district, a.state,
         btrim(a.pin::text)         as pin,
         null::text                 as country,
         coalesce(a.archived, false) as retired,
         coalesce(a.updated_at, a.created_at) as updated_at
    from public.tapal_addresses a
   where a.user_id = auth.uid()
  union all
  select 'tapal_sender:' || s.id, 'tapal_sender', s.id, s.user_id,
         s.label, s.name, s.phone, s.line, s.city, s.district, s.state,
         btrim(s.pin), s.country, false, s.created_at
    from public.tapal_senders s
   where s.user_id = auth.uid();
revoke all on public.akatsuki_addresses from anon, authenticated;
grant select on public.akatsuki_addresses to authenticated;

-- ═══ C · registry: Tapal's minimal card + the route ══════════════════════════
do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
begin
  if not exists (select 1 from auth.users where id = u) then return; end if;
  insert into akatsuki_apps (user_id, id, name, role, pattern, emits, accepts, deletes, session)
  values (u, 'tapal', 'Tapal', 'app', 'document', '{address}', '{}', 'soft', 'jwt')
  on conflict (user_id, id) do nothing;   -- the full card is R011's, still waiting on Tapal
  insert into akatsuki_routes (user_id, from_app, to_app, kind, access, state, note)
  values (u, 'tapal', 'wf', 'address', 'view', 'proposed',
          'R057 — view akatsuki_addresses. WF copies into its Vault (src app tapal), never writes back. Live when WF''s import ships.')
  on conflict (user_id, from_app, to_app, kind) do update set access = excluded.access, note = excluded.note;
end $$;
