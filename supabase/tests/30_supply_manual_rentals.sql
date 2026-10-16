-- 30: vehicle supply types, partners, rentals added by hand, retiring and deleting cars, toll matching around
-- placeholder bookings (migration 0046). Fixtures start with "sm".
select test.suite('30 supply and manual rentals');

select test.mk_user('sm_admin', 'admin');
select test.mk_user('sm_cs', 'va', 'cs');
select test.mk_user('sm_sales', 'va', 'sales');
select test.mk_user('sm_fin', 'va', 'finance');
update staff_profiles set single_limit_cents = 50000 where user_id = test.id('sm_cs');
select test.mk_owner('sm_olive');
select test.mk_vehicle('sm_prog', 'sm_olive');
select test.mk_renter('sm_rita');
insert into payment_method_secrets (payment_method_id, processor, processor_customer_id, processor_method_id)
values (test.id('card:sm_rita'), 'stripe', 'cus_sm_rita', 'pm_sm_rita');
select test.mk_renter('sm_ron');

create temp table sm as select null::text as k, null::jsonb as v limit 0;
create or replace function test.sm(p_k text) returns jsonb language sql stable as $$ select v from pg_temp.sm where k = p_k $$;

-- ================================================================ 1. supply types: the company row, partners, adding cars
select app.company_owner_id();
select test.ok('company: one owners row of kind company, created when first needed', app.company_owner_id() = app.company_owner_id()
  and (select count(*) from owners where kind = 'company') = 1);
select test.throws('partner: an Admin only', $$select app.partner_save(test.id('sm_cs'), '{"business_name": "Sm Rentals Inc"}')$$, 'admin');
insert into sm select 'partner', app.partner_save(test.id('sm_admin'), '{"business_name": "Sm Rentals Inc", "email": "sm.partner@example.test",
  "contact_name": "Pat Partner", "insurance_company": "Sm Mutual", "insurance_policy": "P-1", "insurance_expiry": "2027-06-30"}');
select test.ok('partner: a partner record with its own owners row of kind partner',
  (select o.kind from owners o where o.id = (test.sm('partner') ->> 'owner_id')::uuid) = 'partner' and test.sm('partner') ->> 'partner_number' like 'PR-%');
select test.throws('partner: the same name twice is refused', $$select app.partner_save(test.id('sm_admin'), '{"business_name": "sm rentals inc"}')$$, 'already on file');
select test.eq('partner: commission from the setting by default (20%)',
  (app.partner_detail(test.id('sm_admin'), (test.sm('partner') ->> 'id')::uuid) ->> 'commission_effective_bps')::integer, 2000);

select test.throws('add a car: an Admin only', $$select app.vehicle_add(test.id('sm_cs'), '{"supply_type": "company", "vin": "1SMC0MPANY0000001"}')$$, 'admin');
insert into sm select 'company_car', app.vehicle_add(test.id('sm_admin'), '{"supply_type": "company", "vin": "1SMC0MPANY0000001", "plate": "SMCO 001",
  "year": 2024, "make": "Toyota", "model": "Corolla", "colour": "White", "rates": {"daily": 8000}}');
insert into sm select 'partner_car', app.vehicle_add(test.id('sm_admin'), jsonb_build_object('supply_type', 'partner', 'partner_id', test.sm('partner') ->> 'id',
  'vin', '1SMPARTNER0000001', 'plate', 'SMPA001', 'year', 2023, 'make', 'Honda', 'model', 'Civic', 'rates', jsonb_build_object('daily', 9000)));
create or replace function test.smv(p text) returns uuid language sql stable as $$ select (test.sm(p) ->> 'vehicle_id')::uuid $$;
select test.eq('company car: belongs to the company row, in the fleet at once',
  (select v.supply_type || '/' || o.kind || '/' || v.status from vehicles v join owners o on o.id = v.owner_id where v.id = test.smv('company_car')), 'company/company/available');
select test.eq('partner car: belongs to the partner''s row', (select o.kind from vehicles v join owners o on o.id = v.owner_id where v.id = test.smv('partner_car')), 'partner');
select test.throws('duplicate check: the same VIN is refused, naming the car and who supplies it',
  $$select app.vehicle_add(test.id('sm_admin'), jsonb_build_object('supply_type', 'partner', 'partner_id', test.sm('partner') ->> 'id', 'vin', '1smc0mpany0000001', 'year', 2024, 'make', 'X', 'model', 'Y'))$$,
  'CarmaCars-owned');
select test.throws('duplicate check: a plate on another car is refused', $$select app.vehicle_add(test.id('sm_admin'), '{"supply_type": "company", "vin": "1SMC0MPANY0000009", "plate": "smpa 001", "year": 2024, "make": "X", "model": "Y"}')$$,
  'partner rental company');
select test.throws('a program owner''s car belongs to an owner in the program', format($$update vehicles set owner_id = %L where id = %L$$,
  test.sm('partner') ->> 'owner_id', test.id('vehicle:sm_prog')), 'owner program');

-- the Revenue Share the split reads
select test.eq('terms: a company car keeps 100%', (app.vehicle_terms(test.smv('company_car'), app.today())).revenue_share_bps, 10000);
select test.eq('terms: a partner car, the setting''s commission', (app.vehicle_terms(test.smv('partner_car'), app.today())).revenue_share_bps, 2000);
select app.partner_save(test.id('sm_admin'), jsonb_build_object('id', test.sm('partner') ->> 'id', 'commission_bps', 1500));
select test.eq('terms: the partner''s own commission', (app.vehicle_terms(test.smv('partner_car'), app.today())).revenue_share_bps, 1500);
select app.vehicle_set_commission(test.id('sm_admin'), jsonb_build_object('vehicle_id', test.smv('partner_car'), 'commission_bps', 1800));
select test.eq('terms: the car''s own commission wins', (app.vehicle_terms(test.smv('partner_car'), app.today())).revenue_share_bps, 1800);
select test.eq('terms: no fees on a partner or company car', (app.vehicle_terms(test.smv('company_car'), app.today())).insurance_fee_cents
  + (app.vehicle_terms(test.smv('partner_car'), app.today())).tracker_fee_cents, 0::bigint);
select test.eq('terms: a program owner''s car as before (35%)', (app.vehicle_terms(test.id('vehicle:sm_prog'), app.today())).revenue_share_bps, 3500);
select test.ok('invoices: none for a company or partner car', app.generate_owner_invoice(test.smv('company_car'), app.month_start(app.today()), null) is null
  and app.generate_owner_invoice(test.smv('partner_car'), app.month_start(app.today()), null) is null);
select test.throws('invoices: no upfront invoice for a partner car', format($$select app.issue_upfront_invoice(%L, %L)$$, test.smv('partner_car'), test.id('sm_admin')), 'no upfront invoice');
select test.ok('Admin > Vehicles: who supplies each car, the partner''s name as its owner',
  (select bool_and(case x ->> 'id' when test.smv('company_car')::text then x ->> 'owner_name' = 'CarmaCars' and x ->> 'supply_type' = 'company'
                                   when test.smv('partner_car')::text then x ->> 'owner_name' = 'Sm Rentals Inc' else true end)
     from jsonb_array_elements(app.admin_read(test.id('sm_admin'), 'vehicles')) x));
select test.ok('Paid and signed lists owners in the owner program only',
  not exists (select 1 from jsonb_array_elements(app.owner_checklists(test.id('sm_admin'))) x
               where (x ->> 'owner_id')::uuid in ((test.sm('partner') ->> 'owner_id')::uuid, app.company_owner_id())));

-- ================================================================ 2. rentals added by hand
create or replace function test.smr(p_vehicle uuid, p_from interval, p_to interval, p jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select jsonb_build_object('vehicle_id', p_vehicle, 'pickup_at', date_trunc('hour', now()) + p_from, 'return_at', date_trunc('hour', now()) + p_to,
                            'source', 'phone', 'coverage_option', 1, 'renter_id', test.id('renter:sm_rita')) || p
$$;
-- paid another way, by an Admin, on the company car
insert into sm select 'r1', app.manual_rental_create(test.id('sm_admin'), test.smr(test.smv('company_car'), interval '2 days', interval '5 days',
  '{"payment": {"mode": "other_way", "method": "e_transfer", "reference": "CA-SM-1"}}'));
create or replace function test.smb(p text) returns bookings language sql stable as $$ select * from bookings where id = (test.sm(p) ->> 'booking_id')::uuid $$;
select test.eq('added: confirmed at once, added by staff, blocking the calendar', (select status || '/' || added_by_staff || '/' || blocks_calendar from test.smb('r1')), 'confirmed/true/true');
select test.eq('added: priced from the rate sheet (3 days at $80)', (test.smb('r1')).rental_charge_cents, 24000::bigint);
select test.ok('added: price lines and totals', (test.smb('r1')).total_due_at_booking_cents > 24000
  and exists (select 1 from booking_line_items li where li.booking_id = (test.smb('r1')).id and li.charge_type = 'rental_charge' and li.voided_at is null));
select test.ok('added: the payment received another way is recorded (payment and manual payment)',
  exists (select 1 from payments p join manual_payments m on m.payment_id = p.id where p.booking_id = (test.smb('r1')).id and p.purpose = 'booking_total'
           and p.status = 'succeeded' and p.amount_cents = (test.smb('r1')).renter_due_at_booking_cents and m.reference = 'CA-SM-1'));
select test.ok('added: the renter''s email, no owner notice for a company car',
  exists (select 1 from app_events e where e.code = 'renter_rental_added' and e.entity_id = (test.smb('r1')).id)
  and not exists (select 1 from app_events e where e.code = 'owner_new_booking' and e.entity_id = (test.smb('r1')).id));
select test.ok('added: no request emails (it is not a request)', not exists (select 1 from app_events e where e.entity_id = (test.smb('r1')).id
  and e.code in ('renter_request_received', 'staff_booking_request_new', 'renter_booking_confirmed')));
select test.ok('added: audited, and the booking history says staff added it',
  exists (select 1 from audit_log a where a.action = 'manual_rental_create' and a.entity_id = (test.smb('r1')).id::text and a.actor_user_id = test.id('sm_admin'))
  and exists (select 1 from booking_events e where e.booking_id = (test.smb('r1')).id and e.kind = 'added_by_staff'));
select set_config('request.jwt.claim.sub', test.id('sm_admin')::text, false);
select test.ok('added: on the master calendar', exists (select 1 from app.master_calendar(now(), now() + interval '10 days') m where m.booking_id = (test.smb('r1')).id and m.is_blocking));
select set_config('request.jwt.claim.sub', '', false);
select test.eq('added: the cleaning turnaround after it', (select count(*) from vehicle_calendar_blocks k where k.vehicle_id = test.smv('company_car')
  and k.reason = 'cleaning' and k.removed_at is null and k.starts_at = (test.smb('r1')).return_at), 1::bigint);

-- the calendar: a clash is refused, an Admin may add over it with a reason
select test.throws('clash: the car is not free (the turnaround included)',
  format($$select app.manual_rental_create(%L, test.smr(%L, interval '5 days 1 hour', interval '6 days', '{"payment": {"mode": "unpaid"}}'))$$, test.id('sm_admin'), test.smv('company_car')),
  'not free for these dates');
select test.throws('clash: customer service never adds over a clash',
  format($$select app.manual_rental_create(%L, test.smr(%L, interval '3 days', interval '4 days', '{"clash_reason": "VIP", "payment": {"mode": "link"}}'))$$, test.id('sm_cs'), test.smv('company_car')),
  'Admin decides on a clash');
insert into sm select 'r_clash', app.manual_rental_create(test.id('sm_admin'), test.smr(test.smv('company_car'), interval '3 days', interval '4 days',
  '{"clash_reason": "Same family, sharing the car", "payment": {"mode": "unpaid"}, "renter_id": null, "renter": {"full_name": "Sm Newcomer", "email": "sm.new@example.test", "mobile": "647-555-0111", "date_of_birth": "1985-02-02", "licence_number": "N1234-56789-01234"}}'));
select test.eq('clash: an Admin''s rental over a real overlap is stored, not blocking, with the reason',
  (select status || '/' || blocks_calendar || '/' || clash_override_reason from test.smb('r_clash')), 'confirmed/false/Same family, sharing the car');
select test.ok('new renter: made with the licence, as a driver on the booking',
  exists (select 1 from booking_drivers d join drivers dv on dv.id = d.driver_id where d.booking_id = (test.smb('r_clash')).id and d.role = 'renter' and dv.licence_number = 'N1234-56789-01234'));

-- assistants: the rate sheet, the allowed ways of payment, their single limit, no past rentals
select test.throws('assistant: no price typed by hand', format($$select app.manual_rental_create(%L, test.smr(%L, interval '10 days', interval '11 days', '{"rental_charge_cents": 100, "price_reason": "x", "payment": {"mode": "link"}}'))$$,
  test.id('sm_cs'), test.smv('partner_car')), 'rate sheet');
select test.throws('assistant: unpaid is not one of their ways (setting)', format($$select app.manual_rental_create(%L, test.smr(%L, interval '10 days', interval '11 days', '{"payment": {"mode": "unpaid"}}'))$$,
  test.id('sm_cs'), test.smv('partner_car')), 'for an Admin');
select test.throws('assistant: over the single limit, an Admin records it', format($$select app.manual_rental_create(%L, test.smr(%L, interval '10 days', interval '16 days', '{"payment": {"mode": "other_way", "method": "cash"}}'))$$,
  test.id('sm_cs'), test.smv('partner_car')), 'single limit');
select test.throws('assistant: no past rental', format($$select app.manual_rental_create(%L, test.smr(%L, interval '-10 days', interval '-9 days', '{"past": true, "payment": {"mode": "unpaid"}}'))$$,
  test.id('sm_cs'), test.smv('partner_car')), 'for an Admin');
select test.throws('finance alone does not add rentals', format($$select app.manual_rental_create(%L, test.smr(%L, interval '10 days', interval '11 days', '{"payment": {"mode": "link"}}'))$$,
  test.id('sm_fin'), test.smv('partner_car')), 'Only an Admin, customer service or Sales');
-- an assistant sends a payment link on the partner car: the standard flow (offer approved, signing and payment online)
insert into sm select 'r_link', app.manual_rental_create(test.id('sm_sales'), test.smr(test.smv('partner_car'), interval '10 days', interval '12 days', '{"payment": {"mode": "link"}}'));
select test.eq('payment link: awaiting signing and payment, the offer approved for the renter', (select status::text || '/' || (offer_approved_version is not null) from test.smb('r_link')), 'pending_payment/true');
select test.ok('payment link: the offer email carries the link', exists (select 1 from app_events e where e.code = 'renter_offer_ready' and e.entity_id = (test.smb('r_link')).id));
select test.throws('payment link: not with "do not email"', format($$select app.manual_rental_create(%L, test.smr(%L, interval '20 days', interval '21 days', '{"do_not_email": true, "payment": {"mode": "link"}}'))$$,
  test.id('sm_admin'), test.smv('partner_car')), 'Do not email');
-- the saved card
insert into sm select 'r_card', app.manual_rental_create(test.id('sm_cs'), test.smr(test.smv('partner_car'), interval '14 days', interval '15 days', '{"payment": {"mode": "card"}}'));
select test.ok('saved card: confirmed, and the server is told what to charge', (test.smb('r_card')).status = 'confirmed'
  and test.sm('r_card') -> 'charge' ->> 'method_id' = 'pm_sm_rita' and (test.sm('r_card') -> 'charge' ->> 'amount_cents')::bigint = (test.smb('r_card')).renter_due_at_booking_cents);
select app.manual_rental_card_result(test.id('sm_cs'), jsonb_build_object('booking', (test.smb('r_card')).id, 'ok', true, 'amount_cents', (test.smb('r_card')).renter_due_at_booking_cents,
  'processor', jsonb_build_object('payment_id', 'pi_sm_1', 'charge_id', 'ch_sm_1')));
select test.ok('saved card: the charge recorded once', (select count(*) from payments p where p.booking_id = (test.smb('r_card')).id and p.status = 'succeeded') = 1
  and (app.manual_rental_card_result(test.id('sm_cs'), jsonb_build_object('booking', (test.smb('r_card')).id, 'ok', true)) ->> 'repeat')::boolean);
select test.ok('partner car: the partner gets the owner notice', exists (select 1 from app_events e where e.code = 'owner_new_booking' and e.entity_id = (test.smb('r_card')).id
  and (e.payload ->> 'owner_id')::uuid = (test.sm('partner') ->> 'owner_id')::uuid));
insert into sm select 'r_decl', app.manual_rental_create(test.id('sm_admin'), test.smr(test.smv('partner_car'), interval '17 days', interval '18 days', '{"do_not_email": true, "payment": {"mode": "card"}}'));
select app.manual_rental_card_result(test.id('sm_admin'), jsonb_build_object('booking', (test.smb('r_decl')).id, 'ok', false, 'error', 'Your card was declined.'));
select test.ok('saved card declined: the failed charge and a Finance task', exists (select 1 from payments p where p.booking_id = (test.smb('r_decl')).id and p.status = 'failed')
  and exists (select 1 from tasks t where t.booking_id = (test.smb('r_decl')).id and t.task_type = 'manual_rental_unpaid' and t.queue = 'finance'));
select test.ok('do not email: no renter email', not exists (select 1 from app_events e where e.code = 'renter_rental_added' and e.entity_id = (test.smb('r_decl')).id));
-- an Admin's price
insert into sm select 'r_price', app.manual_rental_create(test.id('sm_admin'), test.smr(test.id('vehicle:sm_prog'), interval '20 days', interval '23 days',
  '{"rental_charge_cents": 25000, "price_reason": "Weekly regular", "deposit_cents": 50000, "payment": {"mode": "unpaid"}, "source": "walk_in"}'));
select test.eq('Admin price: the rental charge, the Deposit and the source as given', (select rental_charge_cents || '/' || deposit_cents || '/' || source from test.smb('r_price')), '25000/50000/walk_in');
select test.throws('Admin price: needs its reason', format($$select app.manual_rental_create(%L, test.smr(%L, interval '25 days', interval '26 days', '{"rental_charge_cents": 1000, "payment": {"mode": "unpaid"}}'))$$,
  test.id('sm_admin'), test.id('vehicle:sm_prog')), 'reason');
select test.ok('program owner''s car: the owner notice', exists (select 1 from app_events e where e.code = 'owner_new_booking' and e.entity_id = (test.smb('r_price')).id));

-- the agreement: opened on the confirmed booking, signed by the renter, countersigned at once
select app.open_rental_agreement((test.smb('r1')).id, test.id('sm_admin'), 'v2-test', repeat('a', 64), 'bookings/sm/ra.pdf');
select test.eq('agreement: opened on a confirmed rental added by hand', (select status from rental_agreements where booking_id = (test.smb('r1')).id), 'open');
select app.record_signature((select signature_request_id from rental_agreements where booking_id = (test.smb('r1')).id),
  (select g.id from rental_agreement_signers g join rental_agreements a on a.id = g.agreement_id where a.booking_id = (test.smb('r1')).id and g.signer_role = 'renter'),
  'Sm Rita', null, null, 'test', 'I sign this agreement.', repeat('a', 64), null);
select test.eq('agreement: completed when the renter signs, countersigned automatically',
  (select a.status || '/' || (select r.consent_text from signature_records r where r.signature_request_id = a.signature_request_id and r.signer_role = 'carmacars')
     from rental_agreements a where a.booking_id = (test.smb('r1')).id),
  'completed/Countersigned for CarmaCars automatically when the renter signed, in the name of the staff member who added the rental.');
-- identity checked in person
select app.verify_driver_in_person(test.id('sm_admin'), jsonb_build_object('booking_driver_id',
  (select id from booking_drivers where booking_id = (test.smb('r1')).id and role = 'renter'), 'note', 'Licence seen at the counter'));
select test.eq('in person: the driver verified by an Admin', (select identity_method || '/' || (identity_verified_on is not null) from booking_drivers where booking_id = (test.smb('r1')).id and role = 'renter'), 'in_person/true');
select test.throws('in person: an Admin only', format($$select app.verify_driver_in_person(%L, '{"booking_driver_id": "%s", "note": "x"}')$$, test.id('sm_cs'),
  (select id from booking_drivers where booking_id = (test.smb('r1')).id and role = 'renter')), 'admin');

-- a past rental on the partner car: completed, split, on the partner's statement
insert into sm select 'r_past', app.manual_rental_create(test.id('sm_admin'), test.smr(test.smv('partner_car'), interval '-20 days', interval '-17 days',
  '{"past": true, "payment": {"mode": "other_way", "method": "cash"}, "source": "turo"}'));
select test.eq('past: kept as completed, handed over and checked in at its dates', (select status || '/' || (handed_over_at = pickup_at) || '/' || (checked_in_at = return_at) from test.smb('r_past')), 'closed/true/true');
select test.eq('past: the split pays the partner what is left after the commission (18%)',
  (select s.company_share_bps || '/' || s.owner_payout_cents || '/' || (s.owner_revenue_cents - s.company_share_cents) from booking_splits s where s.booking_id = (test.smb('r_past')).id),
  (select '1800/' || (r - public.calc_bps(r, 1800)) || '/' || (r - public.calc_bps(r, 1800)) from (select (test.smb('r_past')).rental_charge_cents as r) x));
select test.throws('past: the return must be in the past', format($$select app.manual_rental_create(%L, test.smr(%L, interval '-1 day', interval '1 day', '{"past": true, "payment": {"mode": "unpaid"}}'))$$,
  test.id('sm_admin'), test.smv('partner_car')), 'return in the past');
select test.throws('past: not a payment link', format($$select app.manual_rental_create(%L, test.smr(%L, interval '-9 days', interval '-8 days', '{"past": true, "payment": {"mode": "link"}}'))$$,
  test.id('sm_admin'), test.smv('partner_car')), 'paid another way or recorded as unpaid');
-- the partner's statement for that month, and none for the company row
insert into sm select 'st_partner', to_jsonb(app.build_owner_statement((test.sm('partner') ->> 'owner_id')::uuid, app.month_start(app.local_date((test.smb('r_past')).return_at)), test.id('sm_admin')));
select test.ok('partner statement: built like an owner''s, with the rental', test.sm('st_partner') is not null
  and exists (select 1 from owner_statement_lines l where l.booking_id = (test.smb('r_past')).id and l.owner_statement_id = (test.sm('st_partner') #>> '{}')::uuid
                and l.revenue_share_cents = public.calc_bps((test.smb('r_past')).rental_charge_cents, 1800)));
select test.ok('company row: never an owner statement', app.build_owner_statement(app.company_owner_id(), app.month_start(app.today()), null) is null);
select test.ok('Bookings by supply type: the partner''s, and the rentals added by hand',
  (select count(*) from jsonb_array_elements(app.bookings_by_supply(test.id('sm_admin'), '{"supply": "partner", "added": true}')) x where x ->> 'supply_type' <> 'partner') = 0
  and jsonb_array_length(app.bookings_by_supply(test.id('sm_admin'), '{"supply": "partner", "added": true}')) >= 3);

-- ================================================================ 3. the company statement by supply type
select app.build_company_statement(app.month_start(app.local_date((test.smb('r_past')).return_at)), test.id('sm_admin'));
select test.ok('company statement: a section by supply type with the three kinds',
  exists (select 1 from company_statements cs cross join lateral jsonb_array_elements(cs.sections) s
           where cs.statement_month = app.month_start(app.local_date((test.smb('r_past')).return_at)) and s ->> 'key' = 'supply'
             and s::text like '%Program owners%' and s::text like '%CarmaCars-owned cars%' and s::text like '%Partner rental companies%'));

-- ================================================================ 4. tolls: placeholders, two rentals, company and partner time
select test.mk_vehicle('sm_toll', 'sm_olive');
select test.mk_booking('SM-REAL', 'sm_toll', 'sm_rita', '2026-09-10 10:00', '2026-09-14 10:00', 'closed');
-- the insurer's placeholder over the same days: confirmed, not blocking, never handed over
insert into bookings (booking_number, booking_type, status, vehicle_id, renter_id, booked_at, pickup_at, return_at, original_return_at, billable_days,
    daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, rate_applied, rental_charge_cents, km_allowance_per_day,
    km_allowance_total, overage_cents_per_km, deposit_cents, blocks_calendar, blocks_calendar_reason)
values ('SM-PLACE', 'standard', 'confirmed', test.id('vehicle:sm_toll'), test.id('renter:sm_ron'), now(), '2026-09-09 10:00 America/Toronto', '2026-09-20 10:00 America/Toronto',
        '2026-09-20 10:00 America/Toronto', 11, 10000, 12000, 56000, 180000, 'daily', 0, 200, 2200, 35, 0, false, 'insurer placeholder');
select test.ok('placeholder: a booking that does not block and was never handed over',
  app.booking_is_placeholder((select id from bookings where booking_number = 'SM-PLACE')) and not app.booking_is_placeholder(test.id('booking:SM-REAL')));
insert into sm select 'm1', app.match_toll_candidates(test.id('vehicle:sm_toll'), timestamptz '2026-09-12 14:00 America/Toronto', false);
select test.eq('placeholder: never a candidate; the real rental is matched automatically',
  (select (test.sm('m1') ->> 'decision') || '/' || (test.sm('m1') -> 'suggested' ->> 'booking_number') || '/' || jsonb_array_length(test.sm('m1') -> 'candidates')), 'auto/SM-REAL/1');
-- two real rentals at the same time (a booking recorded twice, for example): never charged automatically
select test.mk_booking('SM-REAL2', 'sm_toll', 'sm_ron', '2026-09-12 09:00', '2026-09-13 09:00', 'closed');
insert into sm select 'm2', app.match_toll_candidates(test.id('vehicle:sm_toll'), timestamptz '2026-09-12 14:00 America/Toronto', false);
select test.eq('two rentals: a conflict naming both, nothing suggested',
  (select (test.sm('m2') ->> 'decision') || '/' || coalesce(test.sm('m2') ->> 'suggested', 'none') || '/'
          || (test.sm('m2') ->> 'reason' like '%SM-REAL %' or test.sm('m2') ->> 'reason' like '%SM-REAL (%') || '/' || (test.sm('m2') ->> 'reason' like '%SM-REAL2%')),
  'conflict/none/true/true');
insert into toll_tickets (id, kind, authority, plate, vehicle_id, occurred_at, amount_cents)
values (test.id('toll:sm1'), 'toll_invoice', '407 ETR', (select plate from vehicles where id = test.id('vehicle:sm_toll')), test.id('vehicle:sm_toll'),
        '2026-09-12 14:00 America/Toronto', 1234);
select app.run_toll_match(test.id('toll:sm1'));
select test.eq('two rentals: the notice stays unmatched, in the two rentals bucket, with a Finance task listing both',
  (select t.status || '/' || t.matched_to || '/' || case when t.match_evidence ->> 'decision' = 'conflict'
            and pg_get_viewdef('toll_work_queue'::regclass) like '%two_rentals%' then 'two_rentals' end || '/'
          || (select count(*) from tasks k where k.related_id = t.id and k.task_type = 'toll_two_rentals' and k.detail like '%SM-REAL2%')
     from toll_tickets t where t.id = test.id('toll:sm1')), 'logged/unmatched/two_rentals/1');
select test.throws('placeholder: cannot be chosen by hand either',
  format($$select app.apply_toll_match(%L, jsonb_build_object('kind', 'renter', 'booking_id', %L), %L, 'manual')$$, test.id('toll:sm1'),
         (select id from bookings where booking_number = 'SM-PLACE'), test.id('sm_admin')), 'placeholder');
select app.apply_toll_match(test.id('toll:sm1'), jsonb_build_object('kind', 'renter', 'booking_id', test.id('booking:SM-REAL')), test.id('sm_admin'), 'manual');
select test.eq('two rentals: Finance chooses the renter; the task closes', (select matched_to || '/' || (select count(*) from tasks k where k.related_id = test.id('toll:sm1')
  and k.status in ('open', 'in_progress')) from toll_tickets where id = test.id('toll:sm1')), 'renter/0');
-- company and partner time
insert into sm select 'm3', app.match_toll_candidates(test.smv('company_car'), now() - interval '1 day', false);
select test.eq('company car outside a rental: CarmaCars, automatically', (select (test.sm('m3') ->> 'decision') || '/' || (test.sm('m3') -> 'suggested' ->> 'kind')), 'auto/company');
insert into sm select 'm4', app.match_toll_candidates(test.smv('partner_car'), now() - interval '1 day', false);
select test.eq('partner car outside a rental: the partner', (select (test.sm('m4') -> 'suggested' ->> 'kind') || '/' || (test.sm('m4') -> 'suggested' ->> 'owner_id')),
  'owner_outside_program/' || (test.sm('partner') ->> 'owner_id'));
insert into toll_tickets (id, kind, authority, plate, vehicle_id, occurred_at, amount_cents)
values (test.id('toll:sm2'), 'parking', 'City of Toronto', 'SMCO001', test.smv('company_car'), now() - interval '1 day', 3000);
update toll_tickets set notice_number = 'PN-SM-2' where id = test.id('toll:sm2');
select app.run_toll_match(test.id('toll:sm2'));
select app.mark_toll_company_paid(test.id('toll:sm2'), test.id('sm_admin'), 'REF-1');
select test.eq('company car: matched to CarmaCars and paid by CarmaCars', (select matched_to || '/' || status from toll_tickets where id = test.id('toll:sm2')), 'company/company_paid');

-- ================================================================ 5. retire, restore, delete
select test.throws('retire: an Admin only', format($$select app.vehicle_retire(%L, '{"vehicle_id": "%s", "reason": "x"}')$$, test.id('sm_cs'), test.smv('partner_car')), 'admin');
select test.throws('retire: not with confirmed bookings ahead, named', format($$select app.vehicle_retire(%L, '{"vehicle_id": "%s", "reason": "Sold"}')$$, test.id('sm_admin'), test.smv('company_car')),
  (test.smb('r1')).booking_number);
select app.vehicle_add(test.id('sm_admin'), '{"supply_type": "company", "vin": "1SMRETXRE00000001", "year": 2022, "make": "Kia", "model": "Rio", "rates": {"daily": 5000}}');
select app.vehicle_retire(test.id('sm_admin'), jsonb_build_object('vehicle_id', (select id from vehicles where vin = '1SMRETXRE00000001'), 'reason', 'Sold at auction'));
select set_config('request.jwt.claim.sub', test.id('sm_admin')::text, false);
select test.ok('retired: no new bookings, off the calendar from now on (still on it for earlier dates)',
  not app.vehicle_bookable((select id from vehicles where vin = '1SMRETXRE00000001'))
  and not exists (select 1 from app.master_calendar(now() + interval '1 day', now() + interval '2 days') m where m.vehicle_id = (select id from vehicles where vin = '1SMRETXRE00000001'))
  and exists (select 1 from app.master_calendar(now() - interval '2 days', now() + interval '2 days') m where m.vehicle_id = (select id from vehicles where vin = '1SMRETXRE00000001')));
select set_config('request.jwt.claim.sub', '', false);
select test.throws('retired: a rental is refused', format($$select app.manual_rental_create(%L, test.smr(%L, interval '2 days', interval '3 days', '{"payment": {"mode": "unpaid"}}'))$$,
  test.id('sm_admin'), (select id from vehicles where vin = '1SMRETXRE00000001')), 'retired');
select test.throws('retired: adding the same VIN says to restore it', $$select app.vehicle_add(test.id('sm_admin'), '{"supply_type": "company", "vin": "1SMRETXRE00000001", "year": 2022, "make": "Kia", "model": "Rio"}')$$, 'restore it');
select app.vehicle_restore(test.id('sm_admin'), jsonb_build_object('vehicle_id', (select id from vehicles where vin = '1SMRETXRE00000001')));
select test.ok('restored: open for bookings again', app.vehicle_bookable((select id from vehicles where vin = '1SMRETXRE00000001')));
select test.throws('delete: a car with bookings is refused, retire instead', format($$select app.vehicle_delete(%L, '{"vehicle_id": "%s", "confirm": "SMPA001"}')$$, test.id('sm_admin'), test.smv('partner_car')),
  'Retire it instead');
select test.throws('delete: typing the plate or the name confirms it', format($$select app.vehicle_delete(%L, '{"vehicle_id": "%s", "confirm": "WRONG"}')$$, test.id('sm_admin'),
  (select id from vehicles where vin = '1SMRETXRE00000001')), 'Type the plate');
insert into vehicle_photos (vehicle_id, angle, shot_type, original_path, processed_path, status, sort_order, is_public)
select id, 'front', 'front', 'vehicles/' || id || '/original/front.jpg', 'vehicles/' || id || '/front.jpg', 'approved', 0, true from vehicles where vin = '1SMRETXRE00000001';
insert into sm select 'del', app.vehicle_delete(test.id('sm_admin'), jsonb_build_object('vehicle_id', (select id from vehicles where vin = '1SMRETXRE00000001'), 'confirm', '2022 Kia Rio'));
select test.ok('delete: the car and what hangs off it are gone, its photo files listed for removal',
  not exists (select 1 from vehicles where vin = '1SMRETXRE00000001') and jsonb_array_length(test.sm('del') -> 'files') = 2
  and exists (select 1 from audit_log a where a.action = 'vehicle_delete' and a.before ->> 'vin' = '1SMRETXRE00000001'));
-- sample cars: those with nothing tied to money go, the others stay with the reason
select test.mk_vehicle('sm_sample_a', 'sm_olive');
select test.mk_vehicle('sm_sample_b', 'sm_olive');
update vehicles set is_sample = true where id in (test.id('vehicle:sm_sample_a'), test.id('vehicle:sm_sample_b'));
select test.mk_booking('SM-SAMPLE', 'sm_sample_b', 'sm_ron', '2026-09-01 10:00', '2026-09-02 10:00', 'closed');
select test.throws('sample cars: confirm by typing', $$select app.vehicles_delete_samples(test.id('sm_admin'), '{"confirm": "yes"}')$$, 'DELETE SAMPLE CARS');
insert into sm select 'samples', app.vehicles_delete_samples(test.id('sm_admin'), '{"confirm": "delete sample cars"}');
select test.ok('sample cars: a sample car with a signed sample schedule and no money goes; one with a booking stays, with why',
  not exists (select 1 from vehicles where id = test.id('vehicle:sm_sample_a')) and exists (select 1 from vehicles where id = test.id('vehicle:sm_sample_b'))
  and test.sm('samples') -> 'kept' -> 0 ->> 'why' like '%booking%');

-- ================================================================ 6. the partner agreement
select test.mk_user('sm_pat', 'owner');
update owners set user_id = test.id('sm_pat') where id = (test.sm('partner') ->> 'owner_id')::uuid;
select test.eq('partner portal: the owner portal says this is a partner', app.owner_kind_facts(app.portal_owner_id(test.id('sm_pat'))) ->> 'kind', 'partner');
select test.eq('partner agreement: filled with the commission and the cars',
  (select (f ->> 'commission_bps') || '/' || jsonb_array_length(f -> 'cars') from (select app.partner_agreement_facts((test.sm('partner') ->> 'owner_id')::uuid) f) x), '1500/1');
insert into sm select 'pa', app.partner_agreement_open(test.id('sm_pat'), repeat('b', 64), 'owners/' || (test.sm('partner') ->> 'owner_id') || '/partner/pa.pdf', 'draft-2026-10');
select test.throws('partner agreement: only a partner account opens it', format($$select app.partner_agreement_open(%L, '%s', 'owners/x/pa.pdf', 'v')$$,
  test.id('owner:sm_olive'), repeat('c', 64)), 'owner account');
select app.sign_request_sign(test.id('sm_pat'), (test.sm('pa') ->> 'id')::uuid, jsonb_build_object('typed_name', 'Pat Partner', 'consent_text', 'I sign.', 'document_sha256', repeat('b', 64)));
select test.eq('partner agreement: signed in the portal, countersigned automatically',
  (select r.agreement_status || '/' || r.agreement_method || '/' || (select x.consent_text from signature_records x where x.signature_request_id = (test.sm('pa') ->> 'signature_request_id')::uuid and x.signer_role = 'carmacars')
     from partners r where r.id = (test.sm('partner') ->> 'id')::uuid),
  'signed/typed/Countersigned for CarmaCars automatically when the partner signed.');
insert into sm select 'partner2', app.partner_save(test.id('sm_admin'), '{"business_name": "Sm Paper Rentals"}');
insert into sm select 'paper', app.record_paper_signature(test.id('sm_admin'), jsonb_build_object('doc_type', 'partner_agreement', 'target_id', test.sm('partner2') ->> 'id',
  'signer_name', 'Paula Paper', 'signed_on', app.today(), 'scan', jsonb_build_object('path', 'paper/sm/pa.pdf', 'sha256', repeat('d', 64))));
select test.eq('partner agreement on paper: recorded as signed, the scan the partner''s document',
  (select r.agreement_status || '/' || r.agreement_method || '/' || (select d.kind::text from documents d where d.id = r.agreement_document_id) from partners r where r.id = (test.sm('partner2') ->> 'id')::uuid),
  'signed/paper/partner_agreement');
select app.void_paper_signature(test.id('sm_admin'), (test.sm('paper') ->> 'id')::uuid, 'Wrong scan');
select test.eq('partner agreement on paper: a void puts it back', (select agreement_status from partners where id = (test.sm('partner2') ->> 'id')::uuid), 'not_sent');

-- ================================================================ 7. the doors and privileges
select test.throws('door: customer service does not read partners', format($$select app.door(%L, 'aal2', 'ops_read', 'partners', '{}')$$, test.id('sm_cs')), 'admin');
select test.lives('door: customer service quotes a rental', format($$select app.door(%L, 'aal2', 'ops_read', 'manual_rental_quote', %L)$$, test.id('sm_cs'),
  test.smr(test.smv('partner_car'), interval '40 days', interval '41 days')));
select test.eq('quote: an assistant may take the payment ways of the setting, no price override',
  (select (q ->> 'may_override_price') || '/' || (q -> 'payment_modes')::text from (select app.manual_rental_quote(test.id('sm_cs'), test.smr(test.smv('partner_car'), interval '40 days', interval '41 days')) q) x),
  'false/["other_way", "link", "card"]');
select test.ok('privileges: the new functions are for the server only',
  not has_function_privilege('authenticated', 'app.manual_rental_create(uuid, jsonb)', 'execute')
  and not has_function_privilege('anon', 'app.vehicle_delete(uuid, jsonb)', 'execute')
  and has_function_privilege('service_role', 'app.partner_save(uuid, jsonb)', 'execute'));
select test.ok('row-level security on partners', (select relrowsecurity from pg_class where oid = 'public.partners'::regclass));
select test.eq('catalogue: the renter''s email for a rental added by hand', (select emitted_by from notification_catalogue where code = 'renter_rental_added'), 'app.manual_rental_create (0046)');
select app.process_events(100000);
select test.eq('outbox: the renter''s email built with every variable',
  (select string_agg(o.code || ':' || (o.missing_variables = '{}'), ',') from notification_outbox o join app_events e on e.id = o.event_id
    where e.code = 'renter_rental_added' and e.entity_id = (test.smb('r1')).id), 'renter_rental_added:true');

-- ================================================================ 8. the official forms fetched by the forms-fetch workflow (0047)
select test.eq('forms: the five official forms are the current templates, each unchecked, with a draft mapping',
  (select string_agg(form_code || ':' || kind || ':' || verified || ':' || ((select count(*) from jsonb_object_keys(field_map)) > 0), ',' order by form_code)
     from pdf_templates where is_current),
  '013-0169:acroform:false:true,013-1155:acroform:false:true,ON00453:overlay:false:true,SR-LV-006:acroform:false:true,SR-LV-012:acroform:false:true');
select test.ok('forms: the laid-out form (no fillable fields) prints each value in its box',
  (select bool_and((v -> 'box' ->> 'page')::integer between 1 and 3 and jsonb_array_length(v -> 'box' -> 'rect') = 4)
     from pdf_templates t, jsonb_each(t.field_map) e(k, v) where t.form_code = 'ON00453' and t.is_current));
select test.ok('forms: what each form is for, and where it came from, is kept with it',
  (select bool_and(notes like '%https://forms.mgcs.gov.on.ca/%' and notes like '%SHA-256%') from pdf_templates where is_current));
select test.lives('forms: every draft mapping passes the mapping checks of 0042 (saved again by an Admin, not checked)',
  $$select app.form_template_map(test.id('sm_admin'), jsonb_build_object('template', t.id, 'field_map', t.field_map)) from pdf_templates t where t.is_current$$);
select test.eq('forms: still nothing in use for owners (no fetched form is checked; suite 26 checks an uploaded one of its own)',
  (select count(*) from pdf_templates where verified and notes like '%https://forms.mgcs.gov.on.ca/%'), 0::bigint);

-- ================================================================ 9. the guides get the new chapters (0048)
-- a fresh database has no guide sections when the migrations run (the seed adds every chapter, the new ones included)
select test.eq('guides: on a fresh database the migration adds nothing (the seed brings the chapters)',
  (select count(*) from guide_sections where slug in ('partners-company-cars-and-rentals-added-by-hand', 'add-a-rental-by-hand', 'for-partner-rental-companies')), 0::bigint);
-- a live guide: an Admin has published sections, one of them edited
delete from guide_section_versions where section_id in (select id from guide_sections where portal = 'va');
delete from guide_sections where portal = 'va';
insert into guide_sections (portal, kind, sort_order, slug, title, body_md, published_title, published_md, published_html, published_hidden, published_version, published_at)
values ('va', 'start', 1, 'start-here', 'Start here', 'a', 'Start here', 'a', '<p>a</p>', false, 1, now()),
       ('va', 'chapter', 2, 'sales', 'Sales', 'edited by an Admin', 'Sales', 'edited by an Admin', '<p>edited by an Admin</p>', false, 3, now()),
       ('va', 'chapter', 3, 'shared-tools', 'Shared tools', 'c', 'Shared tools', 'c', '<p>c</p>', false, 1, now()),
       ('va', 'reference', 4, 'quick-reference', 'Quick reference', 'd', 'Quick reference', 'd', '<p>d</p>', false, 1, now());
create temp table g48 as select version from guides where portal = 'va';
create temp table g48_runs as
  select app.guide_add_published_section('va', 'sales', 'add-a-rental-by-hand', 'Add a rental by hand', 'b', '## Add a rental', '<h2>Add a rental</h2>') as first;
alter table g48_runs add column second boolean;
update g48_runs set second = app.guide_add_published_section('va', 'sales', 'add-a-rental-by-hand', 'Add a rental by hand', 'b', '## Add a rental', '<h2>Add a rental</h2>');
select test.eq('guides: a live guide gets the new chapter once, published, after the chapter it follows',
  (select first::text || '/' || second::text from g48_runs) || '/' || (select string_agg(slug, ',' order by sort_order) from guide_sections where portal = 'va'),
  'true/false/start-here,sales,add-a-rental-by-hand,shared-tools,quick-reference');
select test.eq('guides: the new chapter is published with its HTML and history; the edited chapter is untouched',
  (select (published_html = '<h2>Add a rental</h2>')::text || '/' || (published_version = draft_version)::text || '/'
          || (select count(*) from guide_section_versions v where v.section_id = s.id)
     from guide_sections s where portal = 'va' and slug = 'add-a-rental-by-hand') || '/'
  || (select published_md from guide_sections where portal = 'va' and slug = 'sales'), 'true/true/2/edited by an Admin');
select test.eq('guides: the guide version goes up by one, so its stored PDF shows as older than the web guide',
  (select version from guides where portal = 'va') - (select version from g48), 1);
