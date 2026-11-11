-- r35 gaps: the Fund a car sheet's default daily rate is a Program setting ($80 a day), and an investor reads it with the sheet terms.
alter table program_settings
  add column if not exists investor_sheet_daily_rate_cents integer not null default 8000 check (investor_sheet_daily_rate_cents between 0 and 1000000);

create or replace function app.investor_model_terms(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  i investors := app.investor_of(p_user);
  s program_settings := app.settings();
begin
  return jsonb_build_object('legal_name', i.legal_name, 'min_cents', s.investor_min_cents, 'lockup_months', s.investor_lockup_months, 'payment_day', s.investor_payment_day,
    'offer_bps', coalesce(i.offered_yearly_bps, (select d.deck_return_bps from deck_settings d limit 1)),
    'multiplier', (select d.deck_multiplier from deck_settings d limit 1),
    'company', s.company_legal_name,
    'sheet_daily_rate_cents', s.investor_sheet_daily_rate_cents,
    'today', app.today());
end $$;
