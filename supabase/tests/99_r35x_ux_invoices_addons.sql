-- 99: insurer invoices as Blind Spot Car Rental with named fees and how to pay (1108), add-ons not returned (1108), and the
-- commission on add-ons (1109). docs/changes/2026-11-09-r35-ux-batch.md. Fixtures start with "ui"; every email and number
-- here is a placeholder (example.test).
select test.suite('99 r35 ux: invoices, add-ons not returned, commission on add-ons');
grant usage on schema test to service_role;
grant execute on all functions in schema test to authenticated, anon, service_role;

select test.mk_user('ui_admin', 'admin');
select test.mk_user('ui_sales', 'va', 'sales');
select test.mk_owner('ui_o');
select test.mk_vehicle('UIA', 'ui_o');
select test.mk_vehicle('UIB', 'ui_o');
select test.mk_renter('ui_r');
create function test.ui_day(p_days integer) returns text language sql stable as $$
  select to_char((now() at time zone 'America/Toronto')::date + p_days, 'YYYY-MM-DD') || ' 10:00' $$;
create function test.uib(p text) returns uuid language sql stable as $$ select test.id('booking:' || p) $$;

-- ================================================================ 1. Program settings: empty bank details, the add-on schedule
select test.eq('defaults: the Blind Spot name, no email, every bank and e-Transfer setting empty',
  (select s.bs_billing_name || '/' || coalesce(s.bs_billing_email, '-') || '/' || concat_ws(',', s.bs_pay_account_name, s.bs_pay_account_number, s.bs_pay_etransfer_email,
          s.cc_pay_account_name, s.cc_pay_institution_number, s.cc_pay_transit_number, s.cc_pay_account_number, s.cc_pay_etransfer_email) from (select (app.settings()).*) s),
  'Blind Spot Car Rental/-/');
select test.eq('defaults: charger $150, mount $75, child seat $450, booster $200, others 3 times at least $100',
  (select concat_ws('/', s.unreturned_ev_charger_cents, s.unreturned_phone_mount_cents, s.unreturned_child_seat_cents, s.unreturned_booster_seat_cents, s.unreturned_other_times, s.unreturned_other_min_cents)
     from (select (app.settings()).*) s), '15000/7500/45000/20000/3.00/10000');
select test.eq('how to pay: nothing set, every value null', (select count(*) from jsonb_each(app.invoice_pay('blindspot')) e where e.value <> 'null'::jsonb), 0::bigint);
update program_settings set cc_pay_account_name = 'CarmaCars Holdings', cc_pay_account_number = '000111', cc_pay_etransfer_email = 'pay@carmacars.example.test' where id = (app.settings()).id;
select test.eq('CarmaCars invoices: CarmaCars'' details', app.invoice_pay('carmacars') ->> 'account_number' || '/' || (app.invoice_pay('carmacars') ->> 'etransfer_email'), '000111/pay@carmacars.example.test');
select test.eq('Blind Spot falls back to CarmaCars'' details with nothing naming CarmaCars',
  coalesce(app.invoice_pay('blindspot') ->> 'account_name', '-') || '/' || (app.invoice_pay('blindspot') ->> 'account_number') || '/' || coalesce(app.invoice_pay('blindspot') ->> 'etransfer_email', '-'), '-/000111/-');
update program_settings set bs_pay_account_name = 'Blind Spot Billing', bs_pay_account_number = '000222', bs_pay_etransfer_email = 'billing@blindspot.example.test' where id = (app.settings()).id;
select test.eq('Blind Spot''s own details once entered', app.invoice_pay('blindspot') ->> 'account_name' || '/' || (app.invoice_pay('blindspot') ->> 'account_number') || '/' || (app.invoice_pay('blindspot') ->> 'etransfer_email'),
  'Blind Spot Billing/000222/billing@blindspot.example.test');

-- ================================================================ 2. the insurer invoice: Blind Spot, the named fees
insert into insurers (name, billing_contact_name, billing_email, billing_address) values ('Ui Mutual', 'Ui Adjuster', 'claims@insurer.example.test', '1 Example Street');
select test.mk_booking('UI-1', 'UIA', 'ui_r', test.ui_day(-6), test.ui_day(-2), 'returned');
update bookings set bill_to = 'insurer', insurer_id = (select id from insurers where name = 'Ui Mutual'), insurer_claim_number = 'CL-77' where id = test.uib('UI-1');
insert into booking_line_items (booking_id, charge_type, description, quantity, unit_amount_cents, amount_cents, hst_applies, hst_cents, revenue_class, stage, charged_to_renter)
select test.uib('UI-1'), f.code, x.d, 1, x.a, x.a, f.hst_applies, case when f.hst_applies then public.calc_hst(x.a, 1300) else 0 end, f.revenue_class, 'booking', true
  from (values ('coverage_sold', 'Protection Plan', 6000), ('young_driver_21_25', 'Young driver, 21 to 25', 4000), ('delivery', 'Delivery', 1700)) x(c, d, a)
  join fee_types f on f.code = x.c;
select test.eq('the fees by name (the rental charge apart)',
  (select string_agg((x ->> 'description') || '=' || (x ->> 'amount_cents'), ', ' order by x ->> 'description') from jsonb_array_elements(app.insurer_fee_items(test.uib('UI-1'))) x
    where x ->> 'description' in ('Protection Plan', 'Young driver, 21 to 25', 'Delivery')), 'Delivery=1700, Protection Plan=6000, Young driver, 21 to 25=4000');
insert into insurer_invoices (booking_id, insurer_id, claim_number, period_start, period_end, amount_cents, hst_cents, status, sent_at, sent_by, lines)
values (test.uib('UI-1'), (select id from insurers where name = 'Ui Mutual'), 'CL-77', app.today() - 6, app.today() - 2, 21700, 2821, 'sent', now(), test.id('ui_admin'),
        jsonb_build_array(jsonb_build_object('description', 'Rental charge', 'amount_cents', 10000), jsonb_build_object('description', 'Fees charged at booking', 'amount_cents', 11700)));
update program_settings set bs_billing_email = 'contact@carmacars.example.test', bs_billing_phone = '555-0100' where id = (app.settings()).id;
create table test.uif as select app.pdf_facts('insurer_invoice', (select id::text from insurer_invoices where booking_id = test.uib('UI-1'))) as f;
select test.eq('the insurer invoice: issued as Blind Spot Car Rental, the legal name kept, its file name',
  (select (f -> 'company' ->> 'brand') || '/' || ((f -> 'company' ->> 'legal_name') is not distinct from (app.settings()).company_legal_name) || '/' || (f ->> 'file_name') || '/' || (f ->> 'billed_as') from test.uif),
  'Blind Spot Car Rental/true/blindspot-invoice-' || (select invoice_number from insurer_invoices where booking_id = test.uib('UI-1')) || '.pdf/blindspot');
select test.eq('an email naming CarmaCars is never printed; the phone is', (select coalesce(f -> 'company' ->> 'email', '-') || '/' || (f -> 'company' ->> 'phone') from test.uif), '-/555-0100');
select test.ok('nothing in the company block or the file name says CarmaCars', (select (f -> 'company')::text !~* 'carma' and f ->> 'file_name' !~* 'carma' from test.uif));
select test.eq('the facts carry the named fees and how to pay', (select jsonb_array_length(f -> 'fee_items') >= 3 and f -> 'pay' ->> 'account_number' = '000222' from test.uif), true);

-- ================================================================ 3. add-ons not returned
select test.eq('which line of the schedule an add-on is', app.unreturned_kind('ev_charger', 'EV charger') || '/' || app.unreturned_kind('mount1', 'Phone mount') || '/'
  || app.unreturned_kind('child_seat', 'Child seat') || '/' || app.unreturned_kind('baby_seat', 'Baby seat (rear-facing)') || '/' || app.unreturned_kind('booster_seat', 'Booster seat')
  || '/' || app.unreturned_kind('phone_charger', 'Phone charger') || '/' || app.unreturned_kind('umbrella', 'Umbrella'), 'ev_charger/phone_mount/child_seat/child_seat/booster_seat/other/other');
select test.eq('the other rule: 3 times the rental charge, at least $100', app.unreturned_unit_cents('other', 500) || '/' || app.unreturned_unit_cents('other', 5000) || '/' || app.unreturned_unit_cents('child_seat', 1500),
  '10000/15000/45000');
select test.mk_booking('UI-2', 'UIB', 'ui_r', test.ui_day(-4), test.ui_day(-1), 'returned');
insert into booking_addons (booking_id, addon_id, name, fee_type_code, quantity, pricing_unit, unit_price_cents, hst_applies, status, added_via)
select test.uib('UI-2'), a.id, a.name, a.fee_type_code, case when a.code = 'booster_seat' then 2 else 1 end, a.pricing_unit, coalesce(a.price_cents, 0), a.hst_applies, 'confirmed', 'staff'
  from addons a where a.code in ('booster_seat', 'umbrella', 'full_tank');
select test.eq('the suggested charges: 2 boosters $400, the umbrella at the $100 minimum; prepaid fuel is not returned',
  (select string_agg((x ->> 'name') || '=' || (x ->> 'suggested_cents'), ', ' order by x ->> 'name') from jsonb_array_elements(app.unreturned_addons(test.uib('UI-2'))) x), 'Booster seat=40000, Umbrella=10000');
select test.ok('the agreement''s fine print carries the schedule on a booking with add-ons, not on one without',
  (app.agreement_extra(test.uib('UI-2')) ? 'unreturned') and not coalesce(app.agreement_extra(test.uib('UI-1')) ? 'unreturned', false));
select test.eq('the FAQ tokens come from the public facts', (public.site_facts() -> 'unreturned' ->> 'child_seat_cents'), '45000');
update program_settings set deposit_review_required = true where id = (app.settings()).id;
update bookings set deposit_cents = 50000 where id = test.uib('UI-2');
delete from deposit_reviews where booking_id = test.uib('UI-2');
select test.ok('the review is made for the returned booking', app.drr_ensure(test.uib('UI-2')));
select test.eq('the deposit review: Add-ons returned is an item of a booking with add-ons (8 items)', (app.drr_state(test.uib('UI-2')) ->> 'items')
  || '/' || (select count(*) from deposit_review_items where booking_id = test.uib('UI-2') and item = 'addons'), '8/1');
select test.eq('its facts: the suggested charge, suggested only (no line is charged)', (app.drr_facts(test.uib('UI-2')) -> 'addons' ->> 'suggested_cents') || '/'
  || (select count(*) from booking_line_items li where li.booking_id = test.uib('UI-2') and li.stage in ('check_in', 'after_return')), '50000/0');
select test.eq('its label', app.drr_item_label('addons'), 'Add-ons returned');

-- ================================================================ 4. commission on add-ons (1109)
select test.eq('the add-on part: confirmed add-ons before HST, prepaid fuel left out', app.commission_addon_cents(test.uib('UI-2')),
  coalesce((select sum(li.amount_cents) from booking_addons ba join addons a on a.id = ba.addon_id join booking_line_items li on li.id = ba.line_item_id
             where ba.booking_id = test.uib('UI-2') and ba.status = 'confirmed' and not a.prepaid_fuel), 0)::bigint);
do $$
declare
  v_car uuid := (app.vehicle_add(test.id('ui_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1UHXXMM0000000001', 'plate', 'UHX001', 'year', 2024, 'make', 'Kia', 'model', 'K5',
                  'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000))) ->> 'vehicle_id')::uuid;
  r jsonb;
begin
  r := app.manual_rental_create(test.id('ui_admin'), jsonb_build_object('vehicle_id', v_car,
         'pickup_at', app.local_midnight(app.today() - 10) + interval '10 hours', 'return_at', app.local_midnight(app.today() - 7) + interval '10 hours',
         'source', 'phone', 'coverage_option', 1, 'past', true, 'renter_id', test.id('renter:ui_r'), 'payment', jsonb_build_object('mode', 'other_way', 'method', 'cash'),
         'addons', jsonb_build_array(jsonb_build_object('code', 'umbrella'), jsonb_build_object('code', 'full_tank'))));
  create table test.uic as select coalesce((r ->> 'booking_id')::uuid, (r ->> 'id')::uuid) as booking_id;
  perform app.sales_reassign(test.id('ui_admin'), jsonb_build_object('booking', (select booking_id from test.uic), 'staff', test.id('ui_sales'), 'sourced', true, 'reason', 'Test: sold by Sales'));
end $$;
select test.eq('the commission''s base is the rental charge plus the umbrella (not the prepaid fuel), at the same rate',
  (select (c.addon_base_cents = app.commission_addon_cents(c.booking_id)) || '/' || (c.addon_base_cents > 0) || '/' || (c.base_cents = app.commission_base_cents_pre1109(c.booking_id) + c.addon_base_cents)
          || '/' || (c.amount_cents = public.calc_bps(c.base_cents, c.rate_bps))
     from staff_commissions c where c.booking_id = (select booking_id from test.uic) and c.kind = 'commission'), 'true/true/true/true');
select test.eq('the umbrella line only (the full tank is not in it)', (select c.addon_base_cents from staff_commissions c where c.booking_id = (select booking_id from test.uic) and c.kind = 'commission'),
  (select sum(li.amount_cents) from booking_addons ba join booking_line_items li on li.id = ba.line_item_id and li.voided_at is null join addons a on a.id = ba.addon_id
    where ba.booking_id = (select booking_id from test.uic) and a.code = 'umbrella')::bigint);
update booking_addons set status = 'cancelled', cancelled_at = now(), cancelled_by = test.id('ui_admin'), cancel_reason = 'Test: taken off' where booking_id = (select booking_id from test.uic) and addon_id = (select id from addons where code = 'umbrella');
select test.eq('an add-on taken off leaves the commission', (select c.addon_base_cents from staff_commissions c where c.booking_id = (select booking_id from test.uic) and c.kind = 'commission'), 0::bigint);
