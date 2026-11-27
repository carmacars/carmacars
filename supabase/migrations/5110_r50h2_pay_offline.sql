-- 5110 (r50 hotfix2; docs/changes/2026-11-27-r50-hotfix2.md): no card processor is live (Stripe closed the account), yet
-- renters still tried to pay by card. Card payments are off in Program settings (an Admin set it; app.card_payments_state,
-- 3650, is the one answer), so every pay page, pay link, offer and the renter portal offer e-Transfer and cash only.
-- Invoices and pay pages also show direct deposit next to e-Transfer: app.card_payments_state() now returns
-- direct_deposit from the Program settings an Admin types under "Invoices: how to pay CarmaCars" (cc_pay_*, 1108), null
-- while the account number is empty. No account detail is in this repository.

create or replace function app.card_payments_state() returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  s program_settings;
  c card_processor_state;
  v_set boolean;
  v_proc boolean;
begin
  s := app.settings();
  select * into c from card_processor_state where provider = coalesce(s.card_provider, 'stripe');
  v_set := coalesce(s.card_payments, true);
  v_proc := coalesce(c.charges_enabled, true);
  return jsonb_build_object(
    'on', v_set and v_proc,
    'provider', case when v_set and v_proc then coalesce(s.card_provider, 'stripe') else 'off' end,
    'configured_provider', coalesce(s.card_provider, 'stripe'),
    'setting_on', v_set,
    'reason', case when not v_set then 'setting' when not v_proc then 'processor' end,
    'processor', jsonb_build_object('charges_enabled', v_proc, 'payouts_enabled', coalesce(c.payouts_enabled, true),
                                    'disabled_reason', c.disabled_reason, 'checked_at', c.checked_at, 'paused_since', c.paused_since),
    'e_transfer_email', coalesce(nullif(btrim(s.e_transfer_email), ''), (select nullif(btrim(ss.public_email), '') from site_settings ss limit 1)),
    'direct_deposit', case when nullif(btrim(coalesce(s.cc_pay_account_number, '')), '') is not null then jsonb_build_object(
        'account_name', coalesce(nullif(btrim(s.cc_pay_account_name), ''), (select coalesce(nullif(btrim(ss.business_name), ''), ss.brand_name) from site_settings ss limit 1)),
        'bank', nullif(btrim(s.cc_pay_institution), ''), 'institution', s.cc_pay_institution_number, 'transit', s.cc_pay_transit_number, 'account', s.cc_pay_account_number) end);
end $$;
