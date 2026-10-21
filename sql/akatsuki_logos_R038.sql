-- ============================================================================
-- Akatsuki R038 — one shared place for every app's logo.  After R037.  Idempotent.
-- Project wylxvmkcrexwfpjpbhyy.  Source: WF's request + AKATSUKI-REPLY-wf-app-logos.md.
--
--   A. Bucket akatsuki-logos: public read by URL, png/webp, ≤ 64 KB.  Owner
--      writes under <uid>/.  No anon listing.
--   B. akatsuki_app_identity (one row per app per user) + view akatsuki_app_logos.
--      Written only through the RPC (people) or akatsuki-logo-sync (service role).
--   C. akatsuki_app_identity_upsert(p jsonb) — one object or an array (≤ 100).
--   D. app_key → akatsuki_apps.id map, and the hub's own row ('akatsuki').
--   E. pg_cron: akatsuki-logo-sync daily.
--
-- Ownership (blocking, not warn-mode — new table, one write path):
--   name / home_url : owner_app.  Creator owns; an app publishing its OWN key
--                     (x-akatsuki-app = app_key or its akatsuki_app_id) takes it over.
--   logo            : owner, the app itself, or wf (the curator).  upload/emoji is
--                     the person's choice — the sync never touches it, and an app's
--                     self-publish cannot replace it.  'site' hands it back to the sync.
--   delete          : none.  retired = true hides the row.
-- ============================================================================

do $$
begin
  if to_regprocedure('public.akatsuki_publish_ingest(text,jsonb)') is null then
    raise exception 'akatsuki: run R037 first';
  end if;
end $$;


-- ═══ A · bucket ════════════════════════════════════════════════════════════
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('akatsuki-logos', 'akatsuki-logos', true, 65536, '{image/png,image/webp}')
on conflict (id) do update set public = true, file_size_limit = 65536, allowed_mime_types = '{image/png,image/webp}';

-- Public bucket: reads go through the public URL and need no policy.  These are
-- for the signed-in owner's own folder only — anon gets no policy, so it can't list.
drop policy if exists akatsuki_logos_owner_read   on storage.objects;
drop policy if exists akatsuki_logos_owner_insert on storage.objects;
drop policy if exists akatsuki_logos_owner_update on storage.objects;
drop policy if exists akatsuki_logos_owner_delete on storage.objects;
create policy akatsuki_logos_owner_read on storage.objects for select to authenticated
  using (bucket_id = 'akatsuki-logos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy akatsuki_logos_owner_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'akatsuki-logos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy akatsuki_logos_owner_update on storage.objects for update to authenticated
  using (bucket_id = 'akatsuki-logos' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'akatsuki-logos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy akatsuki_logos_owner_delete on storage.objects for delete to authenticated
  using (bucket_id = 'akatsuki-logos' and (storage.foldername(name))[1] = auth.uid()::text);


-- ═══ B · table + view ══════════════════════════════════════════════════════
create table if not exists public.akatsuki_app_identity (
  user_id         uuid not null default auth.uid(),
  app_key         text not null check (app_key ~ '^[a-z0-9][a-z0-9_-]{1,63}$'),
  name            text not null check (length(name) between 1 and 80),
  home_url        text check (home_url ~ '^https://' and length(home_url) <= 300),
  logo_path       text,
  logo_source     text check (logo_source in ('site', 'upload', 'emoji')),
  emoji           text check (length(emoji) <= 16),
  logo_hash       text,
  akatsuki_app_id text,
  owner_app       text not null,
  sync_status     text,                 -- last akatsuki-logo-sync outcome for this row
  synced_at       timestamptz,
  retired_at      timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  updated_by      text,
  primary key (user_id, app_key)
);
alter table public.akatsuki_app_identity enable row level security;
drop policy if exists akatsuki_app_identity_owner_read on public.akatsuki_app_identity;
create policy akatsuki_app_identity_owner_read on public.akatsuki_app_identity
  for select to authenticated using (user_id = auth.uid());
revoke all on public.akatsuki_app_identity from anon, authenticated;
grant select on public.akatsuki_app_identity to authenticated;   -- writes: RPC or service role only

create or replace view public.akatsuki_app_logos with (security_invoker = on) as
select i.user_id, i.app_key, i.name, i.home_url,
       case when i.logo_path is not null
            then 'https://wylxvmkcrexwfpjpbhyy.supabase.co/storage/v1/object/public/akatsuki-logos/' || i.logo_path end as logo_url,
       i.logo_source, i.emoji, i.akatsuki_app_id, i.owner_app, i.sync_status, i.synced_at, i.updated_at
  from public.akatsuki_app_identity i
 where i.retired_at is null;
revoke all on public.akatsuki_app_logos from anon;
grant select on public.akatsuki_app_logos to authenticated;


-- ═══ C · the write path ════════════════════════════════════════════════════
create or replace function public.akatsuki_app_identity_upsert(p jsonb)
 returns table (app_key text, status text, reason text)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
#variable_conflict use_column
declare
  u uuid := auth.uid();
  v_actor text := akatsuki_actor();
  v_map jsonb := coalesce((select v.schema->'values' from akatsuki_vocab v
                            where v.user_id = auth.uid() and v.ns = 'enum' and v.id = 'app_key_map'), '{}');
  x jsonb; r akatsuki_app_identity; k text; v_self boolean; v_owner boolean; v_logo_ok boolean;
  v_name text; v_url text; v_src text; v_emoji text; v_path text; v_ret boolean; v_changed boolean;
begin
  if u is null then perform akatsuki_fail('42501', 'not_signed_in', 'app identity needs a signed-in user'); end if;
  if jsonb_typeof(p) = 'object' then p := jsonb_build_array(p);
  elsif jsonb_typeof(p) is distinct from 'array' then perform akatsuki_fail('AK106', 'bad_input', 'p must be an object or an array'); end if;
  if jsonb_array_length(p) > 100 then perform akatsuki_fail('AK106', 'bad_input', 'at most 100 apps per call'); end if;

  for x in select * from jsonb_array_elements(p) loop
    k := lower(trim(x->>'app_key'));
    if k is null or k !~ '^[a-z0-9][a-z0-9_-]{1,63}$' then
      app_key := k; status := 'refused'; reason := 'app_key must match ^[a-z0-9][a-z0-9_-]{1,63}$'; return next; continue;
    end if;
    select * into r from akatsuki_app_identity i where i.user_id = u and i.app_key = k;

    v_name := nullif(trim(x->>'name'), '');
    v_url  := nullif(trim(x->>'home_url'), '');
    v_src  := nullif(x->>'logo_source', '');
    v_emoji := nullif(trim(x->>'emoji'), '');
    v_path := nullif(x->>'logo_path', '');
    v_ret  := (x->>'retired')::boolean;

    -- field checks (refuse the row, never abort the batch)
    if v_name is not null and length(v_name) > 80 then app_key := k; status := 'refused'; reason := 'name longer than 80'; return next; continue; end if;
    if v_url is not null and (v_url !~ '^https://' or length(v_url) > 300) then
      app_key := k; status := 'refused'; reason := 'home_url must be https:// and ≤ 300 chars'; return next; continue; end if;
    if v_src is not null and v_src not in ('site', 'upload', 'emoji') then
      app_key := k; status := 'refused'; reason := 'logo_source must be site, upload or emoji'; return next; continue; end if;
    if v_src = 'emoji' and (v_emoji is null or length(v_emoji) > 16) then
      app_key := k; status := 'refused'; reason := 'emoji required (≤ 16 chars) when logo_source = emoji'; return next; continue; end if;
    if v_src = 'upload' and (v_path is null or v_path !~ ('^' || u::text || '/' || k || '/[0-9a-f]{16}\.(png|webp)$')) then
      app_key := k; status := 'refused'; reason := format('logo_path must be %s/%s/<16 hex>.png|webp', u, k); return next; continue; end if;

    if r.app_key is null then
      -- create: the caller owns name/home_url
      insert into akatsuki_app_identity (user_id, app_key, name, home_url, logo_source, emoji, logo_path, akatsuki_app_id,
                                         owner_app, retired_at, updated_by)
      values (u, k, coalesce(v_name, k), v_url,
              coalesce(v_src, case when v_url is not null then 'site' end),
              case when v_src = 'emoji' then v_emoji end,
              case when v_src = 'upload' then v_path end,
              v_map->>k, v_actor, case when v_ret then now() end, v_actor);
      app_key := k; status := 'created'; reason := null; return next; continue;
    end if;

    v_self  := coalesce(v_actor = k or v_actor = r.akatsuki_app_id, false);   -- NULL akatsuki_app_id must not mean 'maybe'
    v_owner := coalesce(v_actor = r.owner_app, false);
    v_changed := false;

    -- name / home_url
    if (v_name is not null and v_name is distinct from r.name) or (v_url is not null and v_url is distinct from r.home_url) then
      if not (v_owner or v_self) then
        app_key := k; status := 'refused'; reason := format('name/home_url are owned by %s', r.owner_app); return next; continue;
      end if;
      r.name := coalesce(v_name, r.name); r.home_url := coalesce(v_url, r.home_url);
      if v_self then r.owner_app := v_actor; end if;     -- the app itself takes ownership
      v_changed := true;
    end if;

    -- logo
    if v_src is not null and (v_src is distinct from r.logo_source
                              or (v_src = 'emoji' and v_emoji is distinct from r.emoji)
                              or (v_src = 'upload' and v_path is distinct from r.logo_path)) then
      v_logo_ok := v_owner or v_self or v_actor = 'wf';
      if v_logo_ok and v_self and not v_owner and v_actor <> 'wf' and r.logo_source in ('upload', 'emoji') then
        v_logo_ok := false;                               -- an app can't replace the person's choice
      end if;
      if not v_logo_ok then
        app_key := k; status := 'refused'; reason := format('logo is %s and not yours to change', coalesce(r.logo_source, 'unset')); return next; continue;
      end if;
      r.logo_source := v_src;
      r.emoji := case when v_src = 'emoji' then v_emoji end;
      if v_src = 'upload' then r.logo_path := v_path; r.logo_hash := substr(v_path, length(u::text || '/' || k || '/') + 1, 16); end if;
      if v_src = 'site'   then r.logo_hash := null; end if;   -- next sync re-fetches
      v_changed := true;
    end if;

    -- retire / restore
    if v_ret is not null and v_ret is distinct from (r.retired_at is not null) then
      if not (v_owner or v_self or v_actor = 'wf') then
        app_key := k; status := 'refused'; reason := format('only the owner (%s), the app itself or wf may retire it', r.owner_app); return next; continue;
      end if;
      r.retired_at := case when v_ret then now() end; v_changed := true;
    end if;

    if v_changed then
      update akatsuki_app_identity i
         set name = r.name, home_url = r.home_url, owner_app = r.owner_app, logo_source = r.logo_source, emoji = r.emoji,
             logo_path = r.logo_path, logo_hash = r.logo_hash, retired_at = r.retired_at,
             akatsuki_app_id = coalesce(i.akatsuki_app_id, v_map->>k), updated_at = now(), updated_by = v_actor
       where i.user_id = u and i.app_key = k;
      app_key := k; status := 'updated'; reason := null;
    else
      app_key := k; status := 'unchanged'; reason := null;
    end if;
    return next;
  end loop;
end $function$;
revoke execute on function public.akatsuki_app_identity_upsert(jsonb) from public, anon;
grant  execute on function public.akatsuki_app_identity_upsert(jsonb) to authenticated;


-- ═══ D · key map + the hub's own row ═══════════════════════════════════════
do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
begin
  -- app_key (Pages repo, lower-cased) → akatsuki_apps.id.  Only pairs the hub is sure of.
  insert into akatsuki_vocab (user_id, ns, id, schema, meta) values
  (u, 'enum', 'app_key_map',
   '{"values":{"akatsuki":"hub","weekly_focus":"wf","cost_management":"cost","calender_app":"cal","sukkiri":"sukkiri",
               "chatak":"chatak","scriptura_app":"scriptura","roadmap_advanced":"rm"}}',
   '{"owner":"akatsuki","r038":"app_key → akatsuki_apps.id; sets akatsuki_app_identity.akatsuki_app_id on create. Add a pair when an app files its card."}')
  on conflict (user_id, ns, id) do update set schema = excluded.schema, meta = excluded.meta;

  insert into akatsuki_app_identity (user_id, app_key, name, home_url, logo_source, akatsuki_app_id, owner_app, updated_by)
  values (u, 'akatsuki', 'Akatsuki', 'https://celeritas7.github.io/Akatsuki/', 'site', 'hub', 'akatsuki', 'akatsuki')
  on conflict (user_id, app_key) do update set name = excluded.name, home_url = excluded.home_url, owner_app = 'akatsuki',
    akatsuki_app_id = 'hub', retired_at = null, updated_at = now(), updated_by = 'akatsuki';

  -- rows created earlier than the map: fill the link
  update akatsuki_app_identity i set akatsuki_app_id = m.value
    from jsonb_each_text((select schema->'values' from akatsuki_vocab where user_id = u and ns = 'enum' and id = 'app_key_map')) m
   where i.user_id = u and i.app_key = m.key and i.akatsuki_app_id is null;
end $$;


-- ═══ E · daily sync ════════════════════════════════════════════════════════
select cron.schedule('akatsuki-logo-sync', '50 17 * * *', $$
  select net.http_post(
    url     := 'https://wylxvmkcrexwfpjpbhyy.supabase.co/functions/v1/akatsuki-logo-sync',
    headers := jsonb_build_object('Content-Type','application/json',
                 'Authorization','Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'akatsuki_tts_cron')),
    body    := '{}'::jsonb,
    timeout_milliseconds := 60000);
$$);

-- Checks:
--   select app_key, owner_app, logo_source, logo_url, sync_status from akatsuki_app_logos;   -- signed in, or:
--   select app_key, owner_app, logo_source, logo_path, sync_status from akatsuki_app_identity;
