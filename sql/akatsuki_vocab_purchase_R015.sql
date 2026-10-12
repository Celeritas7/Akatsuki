-- ============================================================================
-- Akatsuki R015 — purchase_request carries shop + category when the sender knows.
-- Run after R014.  Idempotent.  Optional fields only — no publisher breaks.
-- Cost v37 reads: shop ← preferred_shop | shop | items[].shop, else location spot;
-- category ← items[].category | payload.category, else the shop's saved category.
-- ============================================================================

do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
begin

  update akatsuki_vocab set
    schema = '{"required":["id","items"],"optional":["totalYen","requestedAt","source","note","preferred_shop","category"]}',
    meta = coalesce(meta, '{}') || jsonb_build_object(
      'items',          '[{name, qty?, yen?, shop?, category?}] — per-item wins over payload-level',
      'preferred_shop', 'shop display name as the sender knows it. Send when known; Cost falls back to location.',
      'category',       'Cost category name. Send when known; Cost falls back to the shop''s saved category, else empty — never ''Other''.',
      'source',         'enum request_source (own|sukkiri|food_dept). NEVER a shop.',
      'r015',           'shop + category optional at both levels (payload and items[]).')
  where user_id = u and ns = 'kind' and id = 'purchase_request';

  update akatsuki_apps set flags = array(select f from unnest(flags) f where f not like 'R015%') || array[
    'R015 — Cost v37: purchase inbox from every sender, replies to row.from_app by src_addr, shop/category from payload with location fallback. mergePurchaseRequests kept until Sukkiri publishes (old pasted requests still open).']
  where user_id = u and id = 'cost';

  update akatsuki_apps set flags = array(select f from unnest(flags) f where f not like 'R015%') || array[
    'R015 — a request.created publish is still firing somewhere besides the ¥ path and is rejected. Find it and drop it; request.created is Cost''s kind (Cost→WF).']
  where user_id = u and id = 'wf';

end $$;

-- select schema, meta->'items', meta->'r015' from akatsuki_vocab where id = 'purchase_request';
