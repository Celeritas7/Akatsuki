-- Cost migration 014 (from Cost v50 reply, Oct 5) — reviewed by Akatsuki, safe to run.
-- What it does: lets Cost link shops to areas created in the hub, and gives shops a Google place_id.
-- Deletes nothing.  Safe to run twice.  Run the whole file in one go.

begin;

-- 1 · remove the rule "shop_locations.area_id must exist in cost_management_areas"
--     (new areas now live only in the hub, so that rule would block linking shops to them)
do $$
declare c text;
begin
  for c in
    select con.conname
    from pg_constraint con
    where con.conrelid = 'public.cost_management_shop_locations'::regclass
      and con.contype = 'f'
      and con.confrelid = 'public.cost_management_areas'::regclass
  loop
    execute format('alter table public.cost_management_shop_locations drop constraint if exists %I', c);
  end loop;
end $$;

-- 2 · a place for Google's id on each shop
alter table public.cost_management_shops add column if not exists place_id text;
create index if not exists shops_user_place_idx
  on public.cost_management_shops (user_id, place_id) where place_id is not null;

commit;

-- check: expect place_id listed, and 0 foreign keys from shop_locations to areas
select column_name from information_schema.columns where table_name = 'cost_management_shops' and column_name = 'place_id';
select count(*) fk_to_areas from pg_constraint
 where conrelid = 'public.cost_management_shop_locations'::regclass and contype = 'f'
   and confrelid = 'public.cost_management_areas'::regclass;
