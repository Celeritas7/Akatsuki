-- ============================================================================
-- Akatsuki R016 — Sukkiri → Cost, with WF planning the shop.  Run after R015.
-- Idempotent.
--
-- Decided with the user 2026-09-24:
--   · Sukkiri sends purchase_request straight to Cost (R013 path, unchanged).
--   · WF SHOWS every purchase request in its Wishlist — read-only view, no relay.
--   · WF owns ONE field: the planned shop.  Document pattern, doc 'purchase_plan',
--     path 'shop', item_key '<from_app>:<payload.id>', owner 'wf'.  The state trigger
--     rejects any other writer.  Sukkiri keeps item / qty / price.
--   · Cost owns the shop list (akatsuki_shops view).  WF picks only from it.
--   · Cost decides the real shop at logging.  Order: WF plan → items[].shop →
--     preferred_shop → location.  The logged shop rides the reply; WF's box follows
--     it by DISPLAY (no write back — never write what you didn't just read).
--   · Only Cost closes a request.  WF delete = hide locally.  No withdraw kind.
--   · Sukkiri sees status only.
--   · Server-side reply cursors: deferred.
-- ============================================================================

do $$
begin
  if not exists (select 1 from pg_proc where proname = 'akatsuki_reply') then
    raise exception 'akatsuki: run R010 first';
  end if;
end $$;

-- ═══ A · the board: every purchase request to Cost, with WF's planned shop ═══
create or replace view akatsuki_purchases with (security_invoker = on) as
select r.seq, r.user_id, r.from_app, r.src_addr, r.payload, r.reply, r.reply_seq, r.created_at,
       r.from_app || ':' || (r.payload->>'id')   as plan_key,
       s.value->>'shop'                          as plan_shop,
       s.seq                                     as plan_seq
from akatsuki_requests r
left join akatsuki_state s
  on s.user_id = r.user_id and s.doc = 'purchase_plan' and s.path = 'shop'
 and s.item_key = r.from_app || ':' || (r.payload->>'id') and s.deleted_at is null
where r.to_app = 'cost' and r.kind = 'purchase_request';

-- ═══ B · the shop list, owned by Cost ════════════════════════════════════════
-- cost_management_shops predates the migrations (R002 ??-flag), so build the view
-- from the columns that actually exist.  `name` is required.
do $$
declare cols text := 'user_id, name';
begin
  if not exists (select 1 from information_schema.columns
                 where table_name = 'cost_management_shops' and column_name = 'name') then
    raise exception 'akatsuki R016: cost_management_shops.name not found — send Cost''s shop columns to Akatsuki';
  end if;
  if exists (select 1 from information_schema.columns where table_name = 'cost_management_shops' and column_name = 'id')
    then cols := 'id, ' || cols; end if;
  if exists (select 1 from information_schema.columns where table_name = 'cost_management_shops' and column_name = 'category')
    then cols := cols || ', category'; end if;
  if exists (select 1 from information_schema.columns where table_name = 'cost_management_shops' and column_name = 'is_favorite')
    then cols := cols || ', is_favorite'; end if;
  execute 'create or replace view akatsuki_shops with (security_invoker = on) as select '
       || cols || ' from cost_management_shops';
end $$;

grant select on akatsuki_purchases, akatsuki_shops to authenticated;

-- ═══ C · vocab, cards, routes ════════════════════════════════════════════════
do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
begin

  update akatsuki_vocab set
    schema = '{"required":["id","status"],"optional":["expense_ids","amount","currency","at","shop","category"]}',
    meta = coalesce(meta, '{}') || jsonb_build_object(
      'statuses', '["pending","approved","rejected","logged"]'::jsonb,
      'statuses_note', 'approved is optional — Cost may go straight to logged. Only Cost closes (rejected | logged). No withdraw.',
      'shop', 'the shop the expense was LOGGED at (Cost''s choice). WF moves its box to it by display; Sukkiri ignores it.',
      'r016', 'shop + category ride the logged reply.')
  where user_id = u and ns = 'kind' and id = 'purchase_reply';

  update akatsuki_vocab set meta = coalesce(meta, '{}') || jsonb_build_object(
      'plan', 'WF may plan a shop: akatsuki_state doc=purchase_plan path=shop item_key=<from_app>:<payload.id> value={shop,at}. Read via akatsuki_purchases.plan_shop.',
      'shop_order', 'Cost at logging: plan_shop → items[].shop → preferred_shop → location. Cost may override any of them.')
  where user_id = u and ns = 'kind' and id = 'purchase_request';

  update akatsuki_apps set
    owned_paths = array(select distinct e from unnest(owned_paths || '{purchase_plan.shop}'::text[]) e),
    flags = array(select f from unnest(flags) f where f not like 'R016%') || array[
      'R016 — Wishlist reads akatsuki_purchases (all senders, read-only). WF owns ONLY purchase_plan.shop; pick from akatsuki_shops, never a typed name. Sukkiri items: no edit of item/qty/price, delete = hide locally. When reply.status=logged, show the box at reply.shop — display only, do not rewrite the plan.']
  where user_id = u and id = 'wf';

  update akatsuki_apps set flags = array(select f from unnest(flags) f where f not like 'R016%') || array[
    'R016 — purchaseInbox reads akatsuki_purchases (adds plan_shop). Shop at logging: plan_shop → items[].shop → preferred_shop → location; Cost may override. Reply logged with {shop, category}. akatsuki_shops exposes cost_management_shops read-only.']
  where user_id = u and id = 'cost';

  update akatsuki_apps set flags = array(select f from unnest(flags) f where f not like 'R016%') || array[
    'R016 — Sukkiri shows status only. WF may plan a shop for Sukkiri requests; Sukkiri never reads it.']
  where user_id = u and id = 'sukkiri';

  insert into akatsuki_routes (user_id, from_app, to_app, kind, access, state, note) values
  (u, 'cost', 'wf', 'purchase.board', 'view', 'half',
     'R016 — WF reads akatsuki_purchases: every purchase_request to Cost + reply + plan_shop. Read-only.'),
  (u, 'cost', 'wf', 'shop.list', 'view', 'half',
     'R016 — WF reads akatsuki_shops (Cost owns). WF shop boxes pick from it only.'),
  (u, 'wf', 'cost', 'purchase.plan', 'view', 'half',
     'R016 — WF owns purchase_plan.shop in akatsuki_state; Cost reads it via akatsuki_purchases.plan_shop. First choice at logging, Cost may override.')
  on conflict (user_id, from_app, to_app, kind) do update set access = excluded.access, state = excluded.state, note = excluded.note;

end $$;

-- ═══ D · after the round trip ════════════════════════════════════════════════
-- Bar: Sukkiri sends → WF Wishlist shows it → WF puts it in a shop box → Cost's
-- inbox shows that shop → Cost logs (same or other shop) → WF box shows the logged
-- shop → Sukkiri shows logged.
-- do $$
-- declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
-- begin
--   update akatsuki_routes set state = 'live', note = 'LIVE R016. ' || note
--    where user_id = u and kind in ('purchase.board','shop.list','purchase.plan');
-- end $$;

-- Verify
-- select seq, from_app, payload->>'id', plan_key, plan_shop, reply->>'status', reply->>'shop' from akatsuki_purchases order by seq desc limit 10;
-- select * from akatsuki_shops limit 10;
-- select from_app, to_app, kind, access, state from akatsuki_routes where kind in ('purchase.board','shop.list','purchase.plan','purchase_request','purchase_reply') order by 1,2;
