-- 99: release 44, part B (migrations 2810 to 2814, 2819): bugs found in live use on November 13, 2026.
-- A booking's total follows its lines; an Admin sets a total; the insurer's share on the Blind Spot form; an insurer
-- invoice issued is final and shows no CarmaCars address; an agreement for a rental that has ended; the Protection Plan
-- on a car with no value; deposits that say money no record shows; a person replying stops the AI; the Sales closer
-- keeps the customer. Fixtures start with "zrb"; every name and address is made up.
select test.suite('99 r44b live fixes (2810 to 2819)');
grant usage on schema test to service_role;

select test.mk_user('zrb_admin', 'admin');
select test.mk_user('zrb_cs', 'va', 'cs');
select test.mk_user('zrb_sales', 'va', 'sales');
select test.mk_owner('zrb_owner');
select test.mk_vehicle('zrb_car', 'zrb_owner');
select test.mk_renter('zrb_renter');
select test.mk_renter('zrb_quiet', false);

create function test.zrb_do(p_user text, p_name text, p jsonb, p_call text default 'ops_do') returns jsonb language sql as $$
  select app.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;

-- ================================================================ 1. a line's change moves the booking's total
-- a hand-set booking: the rental line $1,284.58 (plus HST), the total typed as $1,490.00 (other charges in it)
select test.mk_booking('ZRB-1', 'zrb_car', 'zrb_renter', '2027-03-01 10:00', '2027-03-08 10:00', 'confirmed', 128458);
update booking_line_items set payment_id = null where booking_id = test.id('booking:ZRB-1');
delete from payments where booking_id = test.id('booking:ZRB-1');
update bookings set total_due_at_booking_cents = 149000 where id = test.id('booking:ZRB-1');
create table test.zrb_before as select app.booking_part_open(test.id('booking:ZRB-1'), 'fees') as fees, app.booking_part_open(test.id('booking:ZRB-1'), 'balance') as bal;

select test.lives('line: an Admin lowers the rental line from $1,284.58 to $1,275.00',
  $$ select test.zrb_do('zrb_admin', 'line_adjust', jsonb_build_object('line', (select id from booking_line_items where booking_id = test.id('booking:ZRB-1') and charge_type = 'rental_charge'),
       'amount_cents', 127500, 'reason', 'Agreed with the renter')) $$);
select test.eq('line: the total drops by the line''s change with its HST ($9.58 + $1.25)',
  (select total_due_at_booking_cents from bookings where id = test.id('booking:ZRB-1')), 149000 - (128458 - 127500) - (public.calc_hst(128458) - public.calc_hst(127500)));
select test.eq('line: the renter''s share follows', (select renter_due_at_booking_cents from bookings where id = test.id('booking:ZRB-1')),
  (select total_due_at_booking_cents from bookings where id = test.id('booking:ZRB-1')));
select test.eq('line: the fees part is unchanged (no "rental due" nobody owes)', app.booking_part_open(test.id('booking:ZRB-1'), 'fees'), (select fees from test.zrb_before));
select test.eq('line: the balance is the new total', app.booking_part_open(test.id('booking:ZRB-1'), 'balance'),
  (select total_due_at_booking_cents from bookings where id = test.id('booking:ZRB-1')));
select test.eq('line: the rental charge on the booking is the line''s', (select rental_charge_cents from bookings where id = test.id('booking:ZRB-1')), 127500::bigint);

-- ================================================================ 2. an Admin sets the total
select test.throws('total: customer service cannot set it', $$ select test.zrb_do('zrb_cs', 'booking_total_set', jsonb_build_object('booking', 'ZRB-1', 'total_cents', 140000, 'reason', 'Price agreed')) $$, '%');
select test.throws('total: a reason is needed', $$ select test.zrb_do('zrb_admin', 'booking_total_set', jsonb_build_object('booking', 'ZRB-1', 'total_cents', 140000, 'reason', 'x')) $$, '%reason%');
select test.eq('total: an Admin sets $1,400.00', test.zrb_do('zrb_admin', 'booking_total_set', jsonb_build_object('booking', 'ZRB-1', 'total_cents', 140000, 'reason', 'Price agreed by phone')) ->> 'total_cents', '140000');
select test.eq('total: the booking says $1,400.00', (select total_due_at_booking_cents from bookings where id = test.id('booking:ZRB-1')), 140000::bigint);
select test.eq('total: the balance open is the total', app.booking_part_open(test.id('booking:ZRB-1'), 'balance'), 140000::bigint);
select test.eq('total: the fees part is still unchanged', app.booking_part_open(test.id('booking:ZRB-1'), 'fees'), (select fees from test.zrb_before));
select test.ok('total: the rental line holds the difference with its HST backed out',
  (select l.amount_cents + l.hst_cents = 140000 - ((select fees from test.zrb_before)) and l.hst_cents = l.amount_cents + l.hst_cents - app.price_before_tax(l.amount_cents + l.hst_cents, 1300)
     from booking_line_items l where l.booking_id = test.id('booking:ZRB-1') and l.charge_type = 'rental_charge' and l.voided_at is null));
select test.ok('total: it is in the booking history and the audit log',
  exists (select 1 from audit_log a where a.action = 'booking_total_set' and a.entity_id = test.id('booking:ZRB-1')::text));

-- ================================================================ 3. the insurer's share on the Blind Spot form
insert into insurers (id, name, billing_email) values (test.id('insurer:zrb'), 'Example Mutual zrb', 'claims@insurer.example.test');
select test.mk_booking('ZRB-2', 'zrb_car', 'zrb_renter', '2027-04-01 10:00', '2027-05-06 10:00', 'confirmed', 564667);
update bookings set bill_to = 'insurer', insurer_id = test.id('insurer:zrb'), insurer_authorized_daily_rate_cents = 8000, insurer_authorized_days = 35,
       insurer_claim_number = 'CLM-ZRB-1' where id = test.id('booking:ZRB-2');
create table test.zrb_bs as select app.blindspot_extra(test.id('booking:ZRB-2')) -> 'insurer' -> 'share' as s;
select test.eq('form: the insurer is billed for 35 days', (select (s ->> 'covered_days')::int from test.zrb_bs), 35);
select test.eq('form: at its authorized $80.00 a day', (select (s ->> 'daily_rate_cents')::bigint from test.zrb_bs), 8000::bigint);
select test.eq('form: the rental billed is 35 x $80.00', (select (s ->> 'rental_share_cents')::bigint from test.zrb_bs), 280000::bigint);
select test.eq('form: the share is the insurer invoice''s', (select (s ->> 'share_cents')::bigint from test.zrb_bs), (select x.share_cents from app.booking_insurer_share(test.id('booking:ZRB-2')) x));
select test.ok('form: a renter-billed booking has no insurer share', app.blindspot_extra(test.id('booking:ZRB-1')) -> 'insurer' is null or jsonb_typeof(app.blindspot_extra(test.id('booking:ZRB-1')) -> 'insurer') = 'null');

-- ================================================================ 4. the insurer invoice: issued is final, no CarmaCars address
create table test.zrb_inv as select app.draft_insurer_invoice(test.id('booking:ZRB-2'), test.id('zrb_admin')) as id;
select test.eq('invoice: a draft is not final', app.pdf_facts('insurer_invoice', (select id::text from test.zrb_inv)) ->> 'final', 'false');
select test.lives('invoice: Mark sent (no email) works', $$ select app.door(test.id('zrb_admin'), 'aal2', 'admin_do', 'insurer_invoice_send', jsonb_build_object('id', (select id from test.zrb_inv))) $$);
select test.eq('invoice: it is sent', (select status from insurer_invoices where id = (select id from test.zrb_inv)), 'sent');
select test.eq('invoice: once sent it is final (no Draft on the PDF)', app.pdf_facts('insurer_invoice', (select id::text from test.zrb_inv)) ->> 'final', 'true');
update program_settings set bs_pay_etransfer_email = 'rent@carmacars.ca';
select test.ok('invoice: a CarmaCars e-Transfer address is left out', app.pdf_facts('insurer_invoice', (select id::text from test.zrb_inv)) #>> '{pay,etransfer_email}' is null);
select test.ok('invoice: the company block names no CarmaCars', (app.pdf_facts('insurer_invoice', (select id::text from test.zrb_inv)) -> 'company')::text !~* 'carma');

-- ================================================================ 5. an agreement for a rental that has ended
select test.mk_booking('ZRB-3', 'zrb_car', 'zrb_quiet', '2026-09-01 10:00', '2026-09-05 10:00', 'closed');
insert into booking_drivers (booking_id, driver_id, role, full_name)
select test.id('booking:ZRB-3'), test.id('driver:zrb_quiet'), 'renter', 'Zrb Quiet' where not exists (select 1 from booking_drivers where booking_id = test.id('booking:ZRB-3'));
select test.throws('after trip: customer service cannot make it', $$ select test.zrb_do('zrb_cs', 'agreement_regenerate', jsonb_build_object('booking', 'ZRB-3')) $$, '%Admin%');
select test.eq('after trip: an Admin''s Make the agreements again marks it', test.zrb_do('zrb_admin', 'agreement_regenerate', jsonb_build_object('booking', 'ZRB-3')) ->> 'after_trip', 'true');
select test.ok('after trip: the booking says so', (select agreement_after_trip_at is not null from bookings where id = test.id('booking:ZRB-3')));
select test.eq('after trip: the facts say after_trip (blanks print blank)', public.server_agreement_facts(test.id('booking:ZRB-3'), test.id('zrb_admin')) #>> '{booking,after_trip}', 'true');
select test.eq('after trip: Sign on this device prepares it as staff (the renter has no account)',
  public.server_sign_now_prepare(test.id('booking:ZRB-3'), test.id('zrb_admin')) ->> 'as_staff', 'true');
select test.throws('after trip: only an Admin prepares it on Sign on this device', $$ select public.server_sign_now_prepare(test.id('booking:ZRB-3'), test.id('zrb_cs')) $$, '%Admin%');
select test.lives('after trip: staff open the agreement',
  $$ select public.server_agreement_open_staff(test.id('booking:ZRB-3'), test.id('zrb_admin'), 'test-v1', repeat('a', 64), 'bookings/' || test.id('booking:ZRB-3') || '/agreement-test.pdf') $$);
select test.eq('after trip: it is open, waiting for the renter', (select status from rental_agreements where booking_id = test.id('booking:ZRB-3') order by opened_at desc limit 1), 'open');
select test.ok('after trip: the renter signs it', exists (select 1 from rental_agreements a join rental_agreement_signers g on g.agreement_id = a.id
   where a.booking_id = test.id('booking:ZRB-3') and g.signer_role = 'renter'));
select test.eq('after trip: the sign-now page finds it ready', public.server_sign_now_prepare(test.id('booking:ZRB-3'), test.id('zrb_admin')) ->> 'ready', 'true');
select test.lives('after trip: the renter signs on this device',
  $$ select app.sign_in_person(test.id('zrb_admin'), jsonb_build_object('booking', test.id('booking:ZRB-3'),
       'signer', (select g.id from rental_agreement_signers g join rental_agreements a on a.id = g.agreement_id where a.booking_id = test.id('booking:ZRB-3') and g.signer_role = 'renter'),
       'typed_name', (select g.signer_name from rental_agreement_signers g join rental_agreements a on a.id = g.agreement_id where a.booking_id = test.id('booking:ZRB-3') and g.signer_role = 'renter'),
       'sha', repeat('a', 64), 'consent_text', 'I agree', 'identity', jsonb_build_object('name_confirmed', true, 'licence_seen', true))) $$);
select test.eq('after trip: countersigned at once: completed', (select status from rental_agreements where booking_id = test.id('booking:ZRB-3') order by opened_at desc limit 1), 'completed');
select test.eq('after trip: an open booking is not changed by it', test.zrb_do('zrb_admin', 'agreement_regenerate', jsonb_build_object('booking', 'ZRB-1')) ->> 'after_trip', null);

-- ================================================================ 6. the Protection Plan on a car with no value
select test.eq('plan: offered for a car with no value on file, by default', (select column_default from information_schema.columns
   where table_name = 'program_settings' and column_name = 'rentalcover_unknown_value_allowed'), 'true');
update vehicles set replacement_value_cents = null, black_book_value_cents = null, estimated_value_cents = null where id = test.id('vehicle:zrb_car');
update program_settings set rentalcover_unknown_value_allowed = false;
select set_config('app.settings_gen', gen_random_uuid()::text, false);
select test.ok('plan: with it off, the protection change says why at once',
  coalesce(app.protection_block((select b from bookings b where b.id = test.id('booking:ZRB-1')), 3, 'staff'), '') like '%value on file%');
update program_settings set rentalcover_unknown_value_allowed = true;
select set_config('app.settings_gen', gen_random_uuid()::text, false);
select test.ok('plan: with it on, the value is not the reason', coalesce(app.protection_block((select b from bookings b where b.id = test.id('booking:ZRB-1')), 3, 'staff'), '') not like '%value on file%');

-- ================================================================ 7. a deposit that says money no record shows
insert into deposits (booking_id, amount_cents, method, status) values (test.id('booking:ZRB-1'), 100000, 'offline', 'captured');
select test.ok('deposit: Data Health lists it for Finance', exists (select 1 from jsonb_array_elements(app.data_health() -> 'checks') c, jsonb_array_elements(c -> 'items') i
   where c ->> 'key' = 'deposit_without_money' and (i ->> 'id')::uuid = test.id('booking:ZRB-1')));
select test.ok('deposit: the check is Finance''s', 'deposit_without_money' = any (app.data_health_keys('finance')));
insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at)
values (test.id('booking:ZRB-1'), test.id('renter:zrb_renter'), 'deposit', 'charge', 'cash', 100000, 'succeeded', now());
select test.ok('deposit: with the money recorded it is not listed', not exists (select 1 from app.deposit_money_mismatch() m where m.booking_id = test.id('booking:ZRB-1')));

-- ================================================================ 8. a person replied: no automatic answer
insert into messages (direction, channel, to_address, sent_by, status, occurred_at, renter_id)
values ('outbound', 'email', 'Zrb Renter <ZRB_RENTER@example.test>', test.id('zrb_cs'), 'sent', now() - interval '5 minutes', null);
select test.ok('auto reply: a staff email to "Name <address>" counts', app.auto_reply_staff_replied('email', 'zrb_renter@example.test'));
insert into messages (direction, channel, to_address, sent_by, status, occurred_at, renter_id, booking_id)
values ('outbound', 'email', 'other@example.test', test.id('zrb_cs'), 'sent', now() - interval '5 minutes', null, test.id('booking:ZRB-3'));
select test.ok('auto reply: a staff message on the customer''s booking counts, whatever the address', app.auto_reply_staff_replied('email', 'zrb_quiet@example.test'));
select test.ok('auto reply: an hour ago does not', not app.auto_reply_staff_replied('email', 'zrb_quiet@example.test', now() + interval '1 hour'));
select test.ok('auto reply: someone else is answered', not app.auto_reply_staff_replied('email', 'nobody@example.test'));

-- ================================================================ 9. the Sales closer keeps the customer
select test.mk_renter('zrb_sold');
select test.mk_booking('ZRB-4', 'zrb_car', 'zrb_sold', '2026-03-01 10:00', '2026-03-05 10:00', 'closed');
update bookings set sales_staff_id = test.id('zrb_sales'), sales_source = 'admin', sales_attributed_at = now() - interval '250 days' where id = test.id('booking:ZRB-4');
update renters set created_at = now() - interval '300 days' where id = test.id('renter:zrb_sold');
select set_config('request.jwt.claims', jsonb_build_object('sub', test.id('zrb_sales'), 'role', 'authenticated')::text, false);
select set_config('request.jwt.claim.sub', test.id('zrb_sales')::text, false);
select test.ok('sales: the closer sees the customer past the staff window', app.va_sees_renter(test.id('renter:zrb_sold')));
select set_config('request.jwt.claims', jsonb_build_object('sub', test.id('zrb_cs'), 'role', 'authenticated')::text, false);
select set_config('request.jwt.claim.sub', test.id('zrb_cs')::text, false);
select test.ok('sales: customer service does not (past the window, no task)', not app.va_sees_renter(test.id('renter:zrb_sold')));
select set_config('request.jwt.claims', '', false);
select set_config('request.jwt.claim.sub', '', false);

-- ================================================================ 10. past check-ins and check-outs (2815)
select test.mk_user('zrb_field', 'field');
select test.mk_user('zrb_field2', 'field');
select test.mk_booking('ZRB-5', 'zrb_car', 'zrb_renter', '2026-08-01 10:00', '2026-08-04 10:00', 'closed');
create function test.zrb_missing(p_user text) returns jsonb language sql as $$
  select app.door(test.id(p_user), 'aal2', 'ops_read', 'handover_missing', '{}'::jsonb) $$;
select test.ok('missing: an Admin sees the closed booking''s missing check-in and check-out',
  (select count(*) = 2 from jsonb_array_elements(test.zrb_missing('zrb_admin')) x where x ->> 'booking_number' = 'ZRB-5'));
select test.ok('missing: a field staff member who never handled it does not', not exists (select 1 from jsonb_array_elements(test.zrb_missing('zrb_field')) x where x ->> 'booking_number' = 'ZRB-5'));
select test.throws('missing: field staff cannot open one that is not theirs',
  $$ select app.door(test.id('zrb_field'), 'aal2', 'ops_do', 'handover_open', jsonb_build_object('booking', test.id('booking:ZRB-5'), 'kind', 'return')) $$, '%not one of your jobs%');
select test.throws('assign: field staff cannot give jobs', $$ select app.door(test.id('zrb_field'), 'aal2', 'ops_do', 'handover_missing_assign',
  jsonb_build_object('booking', 'ZRB-5', 'kind', 'return', 'staff', test.id('zrb_field'))) $$, '%Admin or Fleet%');
select test.lives('assign: an Admin gives the check-out to a field staff member', $$ select app.door(test.id('zrb_admin'), 'aal2', 'ops_do', 'handover_missing_assign',
  jsonb_build_object('booking', 'ZRB-5', 'kind', 'return', 'staff', test.id('zrb_field'))) $$);
select test.ok('missing: now the field staff member sees it', exists (select 1 from jsonb_array_elements(test.zrb_missing('zrb_field')) x where x ->> 'booking_number' = 'ZRB-5' and x ->> 'kind' = 'return'));
select test.ok('missing: the other field staff member does not', not exists (select 1 from jsonb_array_elements(test.zrb_missing('zrb_field2')) x where x ->> 'booking_number' = 'ZRB-5'));
create table test.zrb_job as select (app.door(test.id('zrb_field'), 'aal2', 'ops_do', 'handover_open', jsonb_build_object('booking', test.id('booking:ZRB-5'), 'kind', 'return')) ->> 'job')::uuid as id;
select test.ok('open: the field staff member gets the job of the closed booking', (select j.assigned_to = test.id('zrb_field') and j.booking_id = test.id('booking:ZRB-5') from field_jobs j where j.id = (select id from test.zrb_job)));
select test.ok('open: a check-out report is made, waiting for its details', exists (select 1 from condition_reports c where c.booking_id = test.id('booking:ZRB-5') and c.kind = 'return' and c.details_pending));
select test.eq('open: the booking stays closed', (select status::text from bookings where id = test.id('booking:ZRB-5')), 'closed');
select test.eq('missing: it says details pending', (select x ->> 'state' from jsonb_array_elements(test.zrb_missing('zrb_admin')) x where x ->> 'booking_number' = 'ZRB-5' and x ->> 'kind' = 'return'), 'details_pending');
select test.throws('missing: renters and Sales do not read the list', $$ select test.zrb_missing('zrb_sales') $$, '%');
