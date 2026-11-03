-- ============================================================================
-- Akatsuki R060 · mail → cost: Yahoo!ショッピング as a purchase source — 2026-11-03.  Idempotent.
-- Asked for by Cost (feasibility check, 2026-11-03; Cost v70 already shows the new fields).
--
--   1. enum purchase_source gets 'yahoo_shopping' (a sales channel like 'amazon', not a shop name).
--   2. purchase.detected gets three optional fields:
--        store    the selling store's name, ≤ 60 chars (Yahoo!ショッピング is a marketplace)
--        payment  card | konbini | paypay | bank | cod, or the raw text ≤ 30 chars
--        pay_by   konbini payment deadline, ISO date
--      Only additions: Amazon payloads and Cost's handlers are unchanged.  store is NOT purged after
--      30 days (akatsuki_purchase_purge clears items and email_id only, as before).
--   3. supabase/functions/akatsuki-mail accepts source 'yahoo_shopping' and passes the three fields.
--
-- The Gmail parser for Yahoo emails is NOT part of this: it waits for a real order email.
-- Idempotency stays <source>:<order_id>:<kind>, i.e. yahoo_shopping:<order_id>:detected.
-- ============================================================================

do $$
declare u uuid := 'e91a5f37-e63a-4fd0-8488-4d7a51d56822';
begin
  update akatsuki_vocab
     set schema = jsonb_set(schema, '{values}',
                   (select jsonb_agg(distinct x order by x) from jsonb_array_elements_text(schema->'values' || '["yahoo_shopping"]') x)),
         meta = meta || '{"yahoo_shopping":"Yahoo!ショッピング order emails (R060). Parser waits for a real email."}',
         version = greatest(version, 2)
   where user_id = u and ns = 'enum' and id = 'purchase_source';

  update akatsuki_vocab
     set schema = jsonb_set(schema, '{optional}',
                   (select jsonb_agg(distinct x order by x) from jsonb_array_elements_text(schema->'optional' || '["store","payment","pay_by"]') x)),
         meta = meta || '{"store":"selling store name ≤60 chars — marketplaces only (yahoo_shopping); kept after the 30-day purge",
                          "payment":"card | konbini | paypay | bank | cod, or the raw text ≤30 chars",
                          "pay_by":"konbini payment deadline, ISO date (YYYY-MM-DD)"}',
         version = greatest(version, 2)
   where user_id = u and ns = 'kind' and id = 'purchase.detected';
end $$;
