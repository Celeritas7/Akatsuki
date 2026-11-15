-- A1A: independent, metadata-only shared application contract registry.
-- Additive only: no existing Akatsuki tables, reminders, routes or functions altered.
-- This migration must be reviewed and applied to staging before production.
-- app/service keys are tenant-local; cross-project identities are NOT inferred
-- from coincidentally matching Supabase auth UUIDs.

create table public.akatsuki_contract_apps (
  user_id uuid not null default auth.uid(),
  app_key text not null check (app_key ~ '^[a-z0-9][a-z0-9_-]{1,63}$'),
  name text not null check (length(btrim(name)) between 1 and 120),
  repository_url text check (repository_url is null or (repository_url ~ '^https://' and length(repository_url) <= 500)),
  home_url text check (home_url is null or (home_url ~ '^https://' and length(home_url) <= 500)),
  legacy_app_id text, -- descriptive cross-reference only; not a foreign key or permission
  identity_realms jsonb not null default '[]'::jsonb check (jsonb_typeof(identity_realms) = 'array'),
  offline_capable boolean not null default false,
  lifecycle text not null default 'proposed' check (lifecycle in ('proposed','active','retired')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, app_key)
);

create table public.akatsuki_contract_services (
  user_id uuid not null default auth.uid(),
  service_key text not null check (service_key ~ '^[a-z0-9][a-z0-9_-]{1,63}$'),
  name text not null check (length(btrim(name)) between 1 and 120),
  maintainer text,
  discovery_url text check (discovery_url is null or (discovery_url ~ '^https://' and length(discovery_url) <= 500)),
  endpoint_url text check (endpoint_url is null or (endpoint_url ~ '^https://' and length(endpoint_url) <= 500)),
  identity_realms jsonb not null default '[]'::jsonb check (jsonb_typeof(identity_realms) = 'array'),
  lifecycle text not null default 'proposed' check (lifecycle in ('proposed','active','retired')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, service_key)
);

create table public.akatsuki_contract_versions (
  user_id uuid not null default auth.uid(),
  service_key text not null,
  contract_key text not null check (contract_key ~ '^[a-z0-9][a-z0-9_-]{1,63}$'),
  version text not null check (version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'),
  specification jsonb not null check (jsonb_typeof(specification) = 'object'),
  specification_sha256 text check (specification_sha256 is null or specification_sha256 ~ '^[0-9a-f]{64}$'),
  lifecycle text not null default 'draft' check (lifecycle in ('draft','published','deprecated','retired')),
  published_at timestamptz,
  deprecated_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, service_key, contract_key, version),
  foreign key (user_id, service_key)
    references public.akatsuki_contract_services (user_id, service_key)
    on update restrict on delete restrict,
  check (lifecycle = 'draft' or (published_at is not null and specification_sha256 is not null))
);

comment on table public.akatsuki_contract_apps is 'A1A: application identities and declared auth realms; registration does not grant permissions';
comment on table public.akatsuki_contract_services is 'A1A: independently hosted services; no proxy or credential material';
comment on table public.akatsuki_contract_versions is 'A1A: versioned service API metadata; publication workflow and immutability enforcement are A2';

-- Default-deny writes. A1B/A2 will introduce narrowly scoped, audited write
-- RPCs. Do not grant INSERT/UPDATE/DELETE to browser roles in this migration.
alter table public.akatsuki_contract_apps enable row level security;
alter table public.akatsuki_contract_services enable row level security;
alter table public.akatsuki_contract_versions enable row level security;

revoke all on public.akatsuki_contract_apps from public, anon, authenticated;
revoke all on public.akatsuki_contract_services from public, anon, authenticated;
revoke all on public.akatsuki_contract_versions from public, anon, authenticated;

create policy akatsuki_contract_apps_owner_read
  on public.akatsuki_contract_apps for select to authenticated
  using (user_id = (select auth.uid()));
create policy akatsuki_contract_services_owner_read
  on public.akatsuki_contract_services for select to authenticated
  using (user_id = (select auth.uid()));
create policy akatsuki_contract_versions_owner_read
  on public.akatsuki_contract_versions for select to authenticated
  using (user_id = (select auth.uid()));

grant select on public.akatsuki_contract_apps to authenticated;
grant select on public.akatsuki_contract_services to authenticated;
grant select on public.akatsuki_contract_versions to authenticated;
