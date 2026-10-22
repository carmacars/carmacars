-- 52: the investor deck (migration 0083). The settings record (one row, defaults, checks, audited), who reads the deck
-- (an Admin always; an investor only while "Show the deck to investors" is on; nobody else), the Admin's save, and the
-- figures: public prices only, the sample 3-day rental and its split by supply type. Fixtures start with "dk".
select test.suite('52 investor deck');

select test.mk_user('dk_admin', 'admin');
select test.mk_user('dk_cs', 'va', 'cs');
select test.mk_user('dk_field', 'field');
select test.mk_owner('dk_own');
select test.mk_renter('dk_rita');
select test.mk_user('dk_inv', 'renter');
insert into investors (id, user_id, legal_name, investor_type, status, email)
values (test.id('inv:dk_inv'), test.id('dk_inv'), 'Dana Deck', 'individual', 'active', 'dk_inv@example.test');
select test.mk_user('dk_prospect', 'renter');
insert into investors (id, user_id, legal_name, investor_type, status, email)
values (test.id('inv:dk_prospect'), test.id('dk_prospect'), 'Pat Prospect', 'individual', 'prospect', 'dk_prospect@example.test');

-- ================================================================ 1. the settings record
select test.eq('one settings row', (select count(*) from deck_settings), 1::bigint);
select test.eq('defaults: shown to investors (the lawyer approved), 3.2x, 30% a year',
  (select show_to_investors || '/' || deck_multiplier || '/' || deck_return_bps from deck_settings), 'true/3.20/3000');
select test.throws('a second row is refused', $$insert into deck_settings (id) values (true)$$, 'duplicate key');
select test.throws('the multiplier must be above zero', $$update deck_settings set deck_multiplier = 0$$, 'check');
select test.throws('the yearly percentage is at most 100%', $$update deck_settings set deck_return_bps = 10001$$, 'check');
select test.ok('row-level security, the admin policy and the audit trigger',
  (select relrowsecurity from pg_class where oid = 'deck_settings'::regclass)
  and exists (select 1 from pg_policies where tablename = 'deck_settings' and policyname = 'admin_all')
  and exists (select 1 from pg_trigger where tgrelid = 'deck_settings'::regclass and tgname = 'audit_deck_settings'));
select test.ok('the deck functions are for the service role only',
  not has_function_privilege('authenticated', 'app.deck_figures()', 'execute') and not has_function_privilege('anon', 'app.deck_read(uuid, text)', 'execute')
  and has_function_privilege('service_role', 'app.deck_settings_save(uuid, jsonb)', 'execute'));

-- ================================================================ 2. who reads it
select test.eq('an investor reads the deck while it is shown',
  public.door(test.id('dk_inv'), null, 'investor_read', 'deck') ->> 'viewer', 'investor');
select test.eq('the investor portal knows it is shown', (public.door(test.id('dk_inv'), null, 'investor_read', 'deck_visible') ->> 'visible')::boolean, true);
select test.eq('an Admin reads it', public.door(test.id('dk_admin'), 'aal2', 'admin_read', 'investor_deck') ->> 'viewer', 'admin');
select test.throws('a renter does not', format($$select public.door(%L, null, 'investor_read', 'deck')$$, test.id('dk_rita')), 'for investors');
select test.throws('an owner does not', format($$select public.door(%L, null, 'investor_read', 'deck')$$, test.id('owner:dk_own')), 'for investors');
select test.throws('an assistant does not', format($$select public.door(%L, 'aal2', 'investor_read', 'deck')$$, test.id('dk_cs')), 'for investors');
select test.throws('field staff do not', format($$select public.door(%L, 'aal2', 'investor_read', 'deck')$$, test.id('dk_field')), 'for investors');
select test.throws('an assistant does not get the Admin preview', format($$select public.door(%L, 'aal2', 'admin_read', 'investor_deck')$$, test.id('dk_cs')), 'Only an Admin');
select test.throws('an investor does not get the Admin preview', format($$select public.door(%L, null, 'admin_read', 'investor_deck')$$, test.id('dk_inv')), 'Only an Admin');
select test.throws('a prospect who was not invited to sign does not', format($$select public.door(%L, null, 'investor_read', 'deck')$$, test.id('dk_prospect')), 'for investors');

-- the switch off: investors no longer see it, the Admin still does
select test.eq('the Admin turns it off', (public.door(test.id('dk_admin'), 'aal2', 'admin_do', 'deck_settings_save', '{"show_to_investors": false}') ->> 'show_to_investors')::boolean, false);
select test.throws('off: the investor is refused', format($$select public.door(%L, null, 'investor_read', 'deck')$$, test.id('dk_inv')), 'not open yet');
select test.eq('off: the portal hides the link', (public.door(test.id('dk_inv'), null, 'investor_read', 'deck_visible') ->> 'visible')::boolean, false);
select test.eq('off: the Admin still previews it', public.door(test.id('dk_admin'), 'aal2', 'admin_read', 'investor_deck') #>> '{settings,show_to_investors}', 'false');
select test.ok('the change is audited with who made it',
  (select updated_by = test.id('dk_admin') from deck_settings) and exists (select 1 from audit_log a where a.entity_table = 'deck_settings'));

-- ================================================================ 3. the Admin's save
select test.eq('the multiplier and the yearly percentage are saved',
  (select r ->> 'deck_multiplier' || '/' || (r ->> 'deck_return_bps') from public.door(test.id('dk_admin'), 'aal2', 'admin_do', 'deck_settings_save',
     '{"deck_multiplier": 2.75, "deck_return_bps": 2400}') r), '2.75/2400');
select test.throws('a multiplier that is not a number', format($$select public.door(%L, 'aal2', 'admin_do', 'deck_settings_save', '{"deck_multiplier": "lots"}')$$, test.id('dk_admin')), 'Enter the multiplier');
select test.throws('a yearly percentage over 100%', format($$select public.door(%L, 'aal2', 'admin_do', 'deck_settings_save', '{"deck_return_bps": 20000}')$$, test.id('dk_admin')), 'yearly percentage');
select test.throws('the switch must be yes or no', format($$select public.door(%L, 'aal2', 'admin_do', 'deck_settings_save', '{"show_to_investors": "maybe"}')$$, test.id('dk_admin')), 'Choose whether');
select test.throws('an investor cannot change it', format($$select public.door(%L, null, 'admin_do', 'deck_settings_save', '{"show_to_investors": true}')$$, test.id('dk_inv')), 'Only an Admin');
select test.throws('an assistant cannot change it', format($$select public.door(%L, 'aal2', 'admin_do', 'deck_settings_save', '{"show_to_investors": true}')$$, test.id('dk_cs')), 'Only an Admin');
select public.door(test.id('dk_admin'), 'aal2', 'admin_do', 'deck_settings_save', '{"show_to_investors": true, "deck_multiplier": 3.2, "deck_return_bps": 3000}');
select test.eq('back on, 3.2x and 30%', (select show_to_investors || '/' || deck_multiplier || '/' || deck_return_bps from deck_settings), 'true/3.20/3000');

-- ================================================================ 4. the figures
select test.eq('the median of public prices: the lower middle for an even count', app.deck_median(array[5000, 7000, 5500, 6000]::bigint[]), 5500::bigint);
select test.eq('the median of an odd count', app.deck_median(array[8000, 5000, 6000]::bigint[]), 6000::bigint);
select test.eq('no prices, no median', app.deck_median(array[]::bigint[]), null::bigint);

create temp table dk_f as select app.deck_figures() f;
grant all on dk_f to public;
select test.eq('the settings shown', (select f #>> '{settings,deck_multiplier}' || '/' || (f #>> '{settings,deck_return_bps}') from dk_f), '3.20/3000');
select test.eq('the investment terms from Program settings',
  (select (f #>> '{investment,min_cents}') || '/' || (f #>> '{investment,lockup_months}') || '/' || (f #>> '{investment,redemption_notice_months}') || '/' || (f #>> '{investment,payment_day}') from dk_f),
  (select investor_min_cents || '/' || investor_lockup_months || '/' || investor_redemption_notice_months || '/' || investor_payment_day from program_settings order by effective_from desc limit 1));
select test.eq('the owner tiers are the fee grid in effect',
  (select jsonb_array_length(f -> 'owner_tiers') from dk_f)::bigint,
  (select count(*) from owner_fee_grid g where g.effective_from = (select max(effective_from) from owner_fee_grid where effective_from <= app.today())));
select test.ok('each tier''s monthly fees are its insurance and tracker fees',
  (select bool_and((t ->> 'monthly_fees_cents')::bigint = (t ->> 'insurance_fee_cents')::bigint + (t ->> 'tracker_fee_cents')::bigint) from dk_f, jsonb_array_elements(f -> 'owner_tiers') t));
select test.eq('the partner commission is Program settings''', (select (f ->> 'partner_commission_bps')::int from dk_f), (select partner_commission_bps from program_settings order by effective_from desc limit 1));
select test.eq('the sample rate is the median of the real cars'' public daily rates (sample cars left out)',
  (select (f #>> '{sample,daily_rate_cents}')::bigint from dk_f),
  coalesce(app.deck_median(array(select p.daily_rate_cents::bigint from public_vehicle_listings p join vehicles v on v.id = p.vehicle_id where not v.is_sample and p.daily_rate_cents > 0)),
           (select (listing_default_daily_rate_cents ->> 'standard')::bigint from program_settings order by effective_from desc limit 1)));
select test.ok('the sample: three days at that rate, plus delivery, one add-on and the young driver fee, all adding up',
  (select (f #>> '{sample,rental_cents}')::bigint = 3 * (f #>> '{sample,daily_rate_cents}')::bigint
      and (f #>> '{sample,company_only_cents}')::bigint = (f #>> '{sample,delivery_cents}')::bigint + (f #>> '{sample,addon_cents}')::bigint + (f #>> '{sample,young_driver_cents}')::bigint
      and (f #>> '{sample,total_cents}')::bigint = (f #>> '{sample,rental_cents}')::bigint + (f #>> '{sample,company_only_cents}')::bigint from dk_f));
select test.eq('the add-on is the first per-day add-on of the catalogue, within its cap',
  (select (f #>> '{sample,addon_cents}')::bigint from dk_f),
  coalesce((select least(a.price_cents * 3, coalesce(a.cap_cents, a.price_cents * 3)) from addons a where a.active and a.pricing_unit = 'per_day' and a.price_cents > 0 order by a.sort_order, a.name limit 1), 0));
select test.eq('splits: one per owner tier, a company car and a partner car',
  (select jsonb_array_length(f #> '{sample,splits}') from dk_f), (select jsonb_array_length(f -> 'owner_tiers') + 2 from dk_f));
select test.ok('each split: the share of the rental charge plus every company-only line; the owner keeps the rest of the rental charge',
  (select bool_and((x ->> 'company_rental_cents')::bigint = round((f #>> '{sample,rental_cents}')::bigint * (x ->> 'share_bps')::numeric / 10000)
                   and (x ->> 'company_rental_cents')::bigint + (x ->> 'owner_cents')::bigint = (f #>> '{sample,rental_cents}')::bigint
                   and (x ->> 'company_cents')::bigint = (x ->> 'company_rental_cents')::bigint + (f #>> '{sample,company_only_cents}')::bigint)
     from dk_f, jsonb_array_elements(f #> '{sample,splits}') x));
select test.eq('a company car keeps the whole rental charge',
  (select (x ->> 'company_rental_cents')::bigint from dk_f, jsonb_array_elements(f #> '{sample,splits}') x where x ->> 'kind' = 'company'),
  (select (f #>> '{sample,rental_cents}')::bigint from dk_f));
select test.eq('the automated emails counted from the catalogue', (select (f ->> 'emails')::bigint from dk_f),
  (select count(*) from notification_catalogue where has_email and is_enabled));
select test.ok('no internal cost, fleet count or utilization in the figures',
  (select not (f ? 'fleet' or f ? 'utilization' or f ? 'costs' or f ? 'staff' or f ? 'premium') and f::text !~* 'utiliz|premium|wage|salary' from dk_f));
select test.ok('the brand is CarmaCars and no numbered company name appears', (select f #>> '{brand,name}' = 'CarmaCars' and f::text !~ '\d{6,} Canada' from dk_f));
