-- ============================================================================
-- Akatsuki · key migration, hub side — 2026-10-28.  Idempotent.
-- Live: the cron part is applied.  The credentials-register block waits on a confirm
-- (run it from the SQL editor if it is not there yet).
--
-- Legacy anon / service_role JWT keys → the new publishable (sb_publishable_…)
-- and secret (sb_secret_…) keys.  Legacy keys keep working until the person
-- deactivates them (Dashboard → Settings → API Keys); Supabase ends them at the
-- end of 2026.  Run after every earlier file: it rewrites the cron jobs those
-- files created.
--
-- Edge functions (same day, each tested live: legacy 200 · new secret 200 · public 401):
--   akatsuki-tts, -sources, -logo-sync  Verify JWT off; isService()/callerOf() accept a
--                                       secret key on apikey/bearer, or a legacy
--                                       service_role JWT the admin API accepts.
--   akatsuki-mail, -ping                admin client prefers SUPABASE_SECRET_KEYS.default.
--   akatsuki-places-nearby              publishable key, Verify JWT off, auth.getUser in code.
--
-- Vault (values never in git):
--   akatsuki_secret_key   the project's secret key "default" — what pg_cron sends now.
--   akatsuki_tts_cron     the legacy service_role JWT — unused from today; delete it
--                         after the legacy keys are deactivated.
-- ============================================================================

-- ═══ pg_cron: every hub job that calls a function sends the secret key as apikey ═══
select cron.alter_job(jobid, command := replace(command,
  $q$'Authorization','Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'akatsuki_tts_cron')$q$,
  $q$'apikey', (select decrypted_secret from vault.decrypted_secrets where name = 'akatsuki_secret_key')$q$))
from cron.job where jobname like 'akatsuki-%' and command like '%akatsuki_tts_cron%';
-- Live after this: akatsuki-tts, -fx, -climate, -forecast, -weather, -weather-history, -logo-sync.


-- ═══ credentials register ═══════════════════════════════════════════════════
do $$
declare u uuid := (select user_id from akatsuki_credentials where name = 'akatsuki_tts_cron' limit 1);
begin
  if u is null then return; end if;
  insert into akatsuki_credentials (user_id, name, scope, location, consumers, rotated_at) values
  (u, 'akatsuki_secret_key', 'Project secret key "default" (sb_secret_…). pg_cron sends it as apikey to akatsuki-tts, -sources, -logo-sync. Edge functions read it from SUPABASE_SECRET_KEYS.', 'vault', '{tts,hub}', now()),
  (u, 'supabase_publishable', 'Project publishable key "default" (sb_publishable_…). Public by design, RLS-gated; replaces supabase_anon in every app config.', 'client_bundle', '{}', now())
  on conflict (user_id, name) do update set scope = excluded.scope, location = excluded.location;
  update akatsuki_credentials set scope = 'LEGACY service-role JWT. Unused by pg_cron since 2026-10-28 (akatsuki_secret_key replaced it). Delete from Vault once legacy keys are deactivated.'
   where user_id = u and name = 'akatsuki_tts_cron';
  update akatsuki_credentials set scope = 'LEGACY anon JWT. Shared project, RLS-gated. Being replaced by supabase_publishable app by app; deactivate when no app sends it.'
   where user_id = u and name = 'supabase_anon';
end $$;
