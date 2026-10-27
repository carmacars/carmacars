-- 0175_tax_included_prices.sql
-- Amounts typed after tax (docs/changes/2026-10-27-tax-included-prices.md). The owner: "It should be easier to put
-- after-tax values without having to do that math." Staff now type the amounts the renter paid, HST included, on Add a
-- rental, Send an offer and Edit the offer (the screens work each line back to its amount before tax, and the rental
-- charge travels with price_tax 'included' as 0112 made it). For the screen's total to be the total that is saved, Add a
-- rental's check (app.manual_rental_quote) must price the rental charge typed, which it never did: it priced the rate
-- sheet's rental charge whatever was typed (the screen showed $303.05 while the booking saved was $320.00).
--
-- 1. app.price_lines also returns rate_sheet_rental_cents: the rental charge the rates give, beside the one priced (the
--    same as rental_charge_cents unless a rental charge was set for the booking). Nothing else changes in its result.
-- 2. app.price_quote takes three staff-only options (honoured only in a staff session, app.staff_pricing = 'on', as the
--    fee lines set by hand of 0132): staff_rental_charge_cents (the rental charge before tax), staff_price_tax ('plus' or
--    'included') and staff_rental_with_tax_cents (tax included: the amount typed). They reach app.price_lines as the
--    booking's own rental_charge_cents, price_tax and rental_charge_with_tax_cents do, so the rental charge line, its HST
--    (tax included: the amount typed less the amount before tax, to the cent), its name and every line that follows the
--    rental charge (the non-refundable discount, a promo code) are priced exactly as the booking will be. A visitor's
--    quote never takes them.
-- 3. Add a rental's check passes the rental charge typed (before tax, as 0112 already works it out) with its choice and,
--    tax included, the amount typed; its rate_sheet_cents stays the rate sheet's rental charge (the screen compares the
--    price typed with it and flags it as before).
-- No applied migration is edited. No table changes. The guides' text changes are listed in the change record (## Guides),
-- republished by the next guides migration.

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0175: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the rate sheet's rental charge beside the one priced
select pg_temp.patch_fn('app.price_lines(jsonb)'::regprocedure,
  $o$    'rate_rule', v_rule, 'rate_capped', v_capped, 'rental_charge_cents', v_rental,$o$,
  $n$    'rate_rule', v_rule, 'rate_capped', v_capped, 'rental_charge_cents', v_rental, 'rate_sheet_rental_cents', r.rental_charge_cents,$n$);

-- ================================================================ 2. a staff quote prices the rental charge typed
select pg_temp.patch_fn('app.price_quote(uuid,timestamptz,timestamptz,jsonb)'::regprocedure,
  $o$    'line_overrides', case when coalesce(current_setting('app.staff_pricing', true), '') = 'on' then o -> 'line_overrides' end));$o$,
  $n$    'line_overrides', case when coalesce(current_setting('app.staff_pricing', true), '') = 'on' then o -> 'line_overrides' end,
    -- 0175: the rental charge staff typed (before tax), plus tax or tax included, priced as the booking will be
    'rental_charge_cents', case when coalesce(current_setting('app.staff_pricing', true), '') = 'on' then nullif(o ->> 'staff_rental_charge_cents', '')::bigint end,
    'price_tax', case when coalesce(current_setting('app.staff_pricing', true), '') = 'on' and nullif(o ->> 'staff_rental_charge_cents', '') is not null
                      and o ->> 'staff_price_tax' in ('plus', 'included') then o ->> 'staff_price_tax' end,
    'rental_charge_with_tax_cents', case when coalesce(current_setting('app.staff_pricing', true), '') = 'on' and nullif(o ->> 'staff_rental_charge_cents', '') is not null
                      and o ->> 'staff_price_tax' = 'included' then nullif(o ->> 'staff_rental_with_tax_cents', '')::bigint end));$n$);

-- ================================================================ 3. Add a rental's check
-- 0112's layer (now app.manual_rental_quote_pre0132) keeps the choice and the amount typed for the layers under it
select pg_temp.patch_fn('app.manual_rental_quote_pre0132(uuid,jsonb)'::regprocedure,
  $o$  return app.manual_rental_quote_pre0112(p_by, p - 'price_tax') || jsonb_build_object('price_tax', app.price_tax_split(v_typed, v_tax, v_hst));$o$,
  $n$  return app.manual_rental_quote_pre0112(p_by, (p - 'price_tax' - 'quote_price_tax' - 'quote_with_tax_cents')
           || case when v_typed is not null then jsonb_build_object('quote_price_tax', v_tax, 'quote_with_tax_cents', case when v_tax = 'included' then v_typed end) else '{}'::jsonb end)
         || jsonb_build_object('price_tax', app.price_tax_split(v_typed, v_tax, v_hst));$n$);
-- 0058's quote prices it, and its rate sheet stays the rate sheet's
select pg_temp.patch_fn('app.manual_rental_quote_0058(uuid,jsonb)'::regprocedure,
  $o$               'line_overrides', case when app.may_edit_fees(p_by) and jsonb_typeof(p -> 'line_overrides') = 'object' then p -> 'line_overrides' end));$o$,
  $n$               'line_overrides', case when app.may_edit_fees(p_by) and jsonb_typeof(p -> 'line_overrides') = 'object' then p -> 'line_overrides' end,
               'staff_rental_charge_cents', nullif(p ->> 'rental_charge_cents', ''),
               'staff_price_tax', coalesce(nullif(p ->> 'quote_price_tax', ''), 'plus'),
               'staff_rental_with_tax_cents', nullif(p ->> 'quote_with_tax_cents', '')));$n$);
select pg_temp.patch_fn('app.manual_rental_quote_0058(uuid,jsonb)'::regprocedure,
  $o$'rate_sheet_cents', (v_quote ->> 'rental_charge_cents')::bigint,$o$,
  $n$'rate_sheet_cents', coalesce((v_quote ->> 'rate_sheet_rental_cents')::bigint, (v_quote ->> 'rental_charge_cents')::bigint),$n$);
