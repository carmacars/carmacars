-- 99: the insurance-replacement rate sheet (migration 0163, docs/changes/2026-10-25-insurer-rate-sheet.md). The sheet per
-- insurer and class with its history (append-only, a change is a new row from a date, a rate ended), the caps, a car's rate
-- (its pricing class first, then its other classes), Add a rental filled from the sheet (a different rate needs a reason;
-- no sheet: as before), a booking that changes insurer follows the sheet, the share with the caps and the delivery
-- allowance, the invoice with its rate and taxes note, the billing history by class, and who may do what.
-- Fixtures start with "ir".
select test.suite('99 insurer rate sheet');

select test.mk_user('ir_admin', 'admin');
select test.mk_user('ir_cs', 'va', 'cs');
create table test.ir (k text primary key, v jsonb);
grant select on test.ir to authenticated, service_role;
create function test.irv(p text) returns jsonb language sql stable as $$ select v from test.ir where k = p $$;
insert into insurers (name, billing_email) values ('Ir Allstate Test', 'billing.allstate@example.test'), ('Ir Second Mutual', null), ('Ir No Sheet Mutual', null);
create function test.irins(p text) returns uuid language sql stable as $$ select id from insurers where name = p $$;

-- a 2024 Jetta: pricing class standard, also a sedan
insert into test.ir select 'car', app.vehicle_add(test.id('ir_admin'), jsonb_build_object('supply_type', 'company', 'vin', '3VWCX7BU0RM000163',
  'plate', 'IRJ163', 'year', 2024, 'make', 'Volkswagen', 'model', 'Jetta', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
create function test.ircar() returns uuid language sql stable as $$ select (test.irv('car') ->> 'vehicle_id')::uuid $$;
update vehicles set class = 'standard' where id = test.ircar();
insert into vehicle_class_links (vehicle_id, class_code, source) values (test.ircar(), 'sedan', 'staff') on conflict do nothing;

-- ================================================================ 1. what a rate comes to under the caps
select test.eq('no caps: rate x days', app.insurer_rate_amount(6500, null, null, 10), 65000::bigint);
select test.eq('weekly cap: a week and three days', app.insurer_rate_amount(6500, 39000, null, 10), 58500::bigint);
select test.eq('weekly cap: a part week costs no more than a week', app.insurer_rate_amount(6500, 30000, null, 6), 30000::bigint);
select test.eq('weekly cap: under the cap, rate x days', app.insurer_rate_amount(6500, 39000, null, 5), 32500::bigint);
select test.eq('monthly and weekly caps: 45 days', app.insurer_rate_amount(6500, 39000, 120000, 45), 204500::bigint);
select test.eq('no days, nothing', app.insurer_rate_amount(6500, 39000, 120000, 0), 0::bigint);

-- ================================================================ 2. the sheet: an Admin's, append-only, with its history
select test.throws('customer service cannot change the sheet', $$ select app.door(test.id('ir_cs'), 'aal2', 'admin_do', 'insurer_rate_set',
  jsonb_build_object('insurer_id', test.irins('Ir Allstate Test'), 'class_code', 'sedan', 'daily_rate_cents', 6500)) $$, '%Admin%');
select test.throws('a class is chosen', $$ select app.insurer_rate_set(test.id('ir_admin'), jsonb_build_object('insurer_id', test.irins('Ir Allstate Test'), 'daily_rate_cents', 6500)) $$, '%car class%');
select test.throws('a daily rate is typed', $$ select app.insurer_rate_set(test.id('ir_admin'), jsonb_build_object('insurer_id', test.irins('Ir Allstate Test'), 'class_code', 'sedan')) $$, '%daily rate%');
select test.throws('a weekly cap under the daily rate is refused', $$ select app.insurer_rate_set(test.id('ir_admin'), jsonb_build_object('insurer_id', test.irins('Ir Allstate Test'),
  'class_code', 'sedan', 'daily_rate_cents', 6500, 'weekly_cap_cents', 5000)) $$, '%weekly cap%');
insert into test.ir select 'r1', app.door(test.id('ir_admin'), 'aal2', 'admin_do', 'insurer_rate_set', jsonb_build_object('insurer_id', test.irins('Ir Allstate Test'),
  'class_code', 'sedan', 'daily_rate_cents', 6500, 'weekly_cap_cents', 39000, 'delivery_allowance_cents', 5000, 'km_per_day', 250,
  'taxes_note', 'HST is billed on top; Allstate HST number on file.', 'effective_from', (current_date - 30)::text, 'note', 'Agreed with the adjuster'));
select test.ok('the Allstate sedan rate is saved', (test.irv('r1') ->> 'id') is not null);
select test.throws('the same rate again: nothing changed', $$ select app.insurer_rate_set(test.id('ir_admin'), jsonb_build_object('insurer_id', test.irins('Ir Allstate Test'),
  'class_code', 'sedan', 'daily_rate_cents', 6500, 'weekly_cap_cents', 39000, 'delivery_allowance_cents', 5000, 'km_per_day', 250,
  'taxes_note', 'HST is billed on top; Allstate HST number on file.')) $$, '%Nothing changed%');
select test.throws('a rate is never changed', $$ update insurer_rates set daily_rate_cents = 1 where id = (test.irv('r1') ->> 'id')::uuid $$, '%kept as it was saved%');
select test.throws('nor deleted', $$ delete from insurer_rates where id = (test.irv('r1') ->> 'id')::uuid $$, '%kept as it was saved%');
-- a raise from a later date: a new row, the old one stays
insert into test.ir select 'r2', to_jsonb(app.insurer_rate_set(test.id('ir_admin'), jsonb_build_object('insurer_id', test.irins('Ir Allstate Test'),
  'class_code', 'sedan', 'daily_rate_cents', 6800, 'weekly_cap_cents', 40000, 'effective_from', (current_date + 10)::text)));
select test.eq('two rows for Allstate sedans', (select count(*) from insurer_rates where insurer_id = test.irins('Ir Allstate Test') and class_code = 'sedan'), 2::bigint);
select test.eq('today: $65', (app.insurer_rate_at(test.irins('Ir Allstate Test'), 'sedan', current_date)).daily_rate_cents, 6500::bigint);
select test.eq('in 10 days: $68', (app.insurer_rate_at(test.irins('Ir Allstate Test'), 'sedan', current_date + 10)).daily_rate_cents, 6800::bigint);
insert into test.ir select 'sheet', app.door(test.id('ir_admin'), 'aal2', 'admin_read', 'insurer_rate_sheet', '{}'::jsonb);
select test.eq('the grid: today''s rate', (select (i -> 'rates' -> 'sedan' -> 'now' ->> 'daily_rate_cents')::bigint from jsonb_array_elements(test.irv('sheet') -> 'insurers') i where i ->> 'name' = 'Ir Allstate Test'), 6500::bigint);
select test.eq('the grid: the next rate saved', (select (i -> 'rates' -> 'sedan' -> 'next' ->> 'daily_rate_cents')::bigint from jsonb_array_elements(test.irv('sheet') -> 'insurers') i where i ->> 'name' = 'Ir Allstate Test'), 6800::bigint);
select test.ok('the grid: the classes are the existing list', (select bool_or(c ->> 'code' = 'sedan') and bool_or(c ->> 'code' = 'suv') from jsonb_array_elements(test.irv('sheet') -> 'classes') c));
select test.throws('customer service cannot read the grid', $$ select app.door(test.id('ir_cs'), 'aal2', 'admin_read', 'insurer_rate_sheet', '{}'::jsonb) $$, '%Admin%');
-- a rate ended, then the history shows it
select app.insurer_rate_set(test.id('ir_admin'), jsonb_build_object('insurer_id', test.irins('Ir Second Mutual'), 'class_code', 'suv', 'daily_rate_cents', 9000, 'effective_from', (current_date - 5)::text));
select app.insurer_rate_set(test.id('ir_admin'), jsonb_build_object('insurer_id', test.irins('Ir Second Mutual'), 'class_code', 'suv', 'remove', true));
select test.eq('a rate ended: none today', (app.insurer_rate_at(test.irins('Ir Second Mutual'), 'suv', current_date)).daily_rate_cents, null::bigint);
select test.eq('it was there before', (app.insurer_rate_at(test.irins('Ir Second Mutual'), 'suv', current_date - 1)).daily_rate_cents, 9000::bigint);

-- ================================================================ 3. a car's rate: the pricing class first, then its other classes
select test.eq('the Jetta (standard, also a sedan): Allstate''s sedan rate', (app.insurer_rate_for(test.irins('Ir Allstate Test'), test.ircar(), current_date)).daily_rate_cents, 6500::bigint);
select app.insurer_rate_set(test.id('ir_admin'), jsonb_build_object('insurer_id', test.irins('Ir Second Mutual'), 'class_code', 'sedan', 'daily_rate_cents', 6000, 'effective_from', (current_date - 30)::text));
select app.insurer_rate_set(test.id('ir_admin'), jsonb_build_object('insurer_id', test.irins('Ir Second Mutual'), 'class_code', 'standard', 'daily_rate_cents', 5500, 'effective_from', (current_date - 30)::text));
select test.eq('its pricing class wins when it has a rate', (app.insurer_rate_for(test.irins('Ir Second Mutual'), test.ircar(), current_date)).daily_rate_cents, 5500::bigint);
select test.eq('no rate for the car: none', (app.insurer_rate_for(test.irins('Ir No Sheet Mutual'), test.ircar(), current_date)).id, null::uuid);

-- ================================================================ 4. Add a rental takes the sheet's rate
create function test.irmr(p jsonb, p_days integer default 10) returns jsonb language sql stable as $$
  select jsonb_build_object('vehicle_id', test.ircar(), 'pickup_at', date_trunc('hour', now()) + interval '1 day', 'return_at', date_trunc('hour', now()) + make_interval(days => 1 + p_days),
    'coverage_option', 3, 'source', 'insurer', 'sales_choice', 'for_carmacars', 'agreement', 'paper', 'blocks_calendar', false, 'blocks_calendar_reason', 'Insurance replacement test',
    'renter', jsonb_build_object('full_name', 'Ira Rated', 'email', 'ira.rated.' || md5(p::text) || '@example.test', 'mobile', '4165550163', 'date_of_birth', '1980-01-01', 'licence_number', 'R1234-12345-12345'),
    'payment', jsonb_build_object('mode', 'unpaid', 'method', 'insurer'), 'deposit', jsonb_build_object('method', 'cash')) || p $$;
insert into test.ir select 'quote', app.door(test.id('ir_cs'), 'aal2', 'ops_read', 'manual_rental_quote', test.irmr('{}'::jsonb));
select test.eq('the check gives Allstate''s rate for this car', (select (x ->> 'daily_rate_cents')::bigint from jsonb_array_elements(test.irv('quote') -> 'insurer_rates') x where x ->> 'insurer_name' = 'Ir Allstate Test'), 6500::bigint);
select test.eq('with its class', (select x ->> 'class_label' from jsonb_array_elements(test.irv('quote') -> 'insurer_rates') x where x ->> 'insurer_name' = 'Ir Allstate Test'), 'Sedan');
select test.ok('an insurer without a rate for the car is not listed', not exists (select 1 from jsonb_array_elements(test.irv('quote') -> 'insurer_rates') x where x ->> 'insurer_name' = 'Ir No Sheet Mutual'));

insert into test.ir select 'b1', app.door(test.id('ir_admin'), 'aal2', 'ops_do', 'manual_rental_create', test.irmr(jsonb_build_object('insurance', jsonb_build_object(
  'insurer_id', test.irins('Ir Allstate Test'), 'claim_number', 'IR-1', 'dates_provisional', true, 'pays', 'insurer'))));
create function test.irb(p text) returns bookings language sql stable security definer as $$ select * from bookings where id = (test.irv(p) ->> 'booking_id')::uuid $$;
select test.eq('no rate typed: the sheet''s $65', (test.irb('b1')).insurer_authorized_daily_rate_cents, 6500::bigint);
select test.eq('the sheet row is kept', (test.irb('b1')).insurer_rate_id, (test.irv('r1') ->> 'id')::uuid);
select test.eq('and the sheet''s rate', (test.irb('b1')).insurer_sheet_daily_rate_cents, 6500::bigint);
select test.eq('the share takes the weekly cap: a week and three days at $65, at most $390 a week', (select x.rental_share_cents from app.booking_insurer_share((test.irb('b1')).id) x), 58500::bigint);
select test.eq('the stored share follows', (test.irb('b1')).insurer_share_cents >= 58500, true);

select test.throws('a different rate without a reason is refused, with the sheet''s rate', $$ select app.door(test.id('ir_admin'), 'aal2', 'ops_do', 'manual_rental_create', test.irmr(jsonb_build_object('insurance', jsonb_build_object(
  'insurer_id', test.irins('Ir Allstate Test'), 'claim_number', 'IR-2', 'authorized_daily_rate_cents', 7000, 'pays', 'insurer')), 3)) $$, '%differs from Ir Allstate Test''s rate sheet for Sedan ($65.00)%');
insert into test.ir select 'b2', app.door(test.id('ir_admin'), 'aal2', 'ops_do', 'manual_rental_create', test.irmr(jsonb_build_object('insurance', jsonb_build_object(
  'insurer_id', test.irins('Ir Allstate Test'), 'claim_number', 'IR-2', 'authorized_daily_rate_cents', 7000, 'rate_reason', 'Adjuster approved a premium car', 'pays', 'insurer',
  'dates_provisional', true)), 3));
select test.eq('with a reason: the rate typed', (test.irb('b2')).insurer_authorized_daily_rate_cents, 7000::bigint);
select test.eq('the reason is kept', (test.irb('b2')).insurer_rate_reason, 'Adjuster approved a premium car');
insert into test.ir select 'b2read', app.door(test.id('ir_admin'), 'aal2', 'admin_read', 'booking_insurer', jsonb_build_object('booking', (test.irb('b2')).booking_number));
select test.eq('the booking card flags the difference', (test.irv('b2read') ->> 'differs')::boolean, true);
select test.eq('and says where the rate comes from', test.irv('b2read') ->> 'rate_source', 'override');

-- no sheet for the insurer: as before (0148)
insert into test.ir select 'b3', app.door(test.id('ir_admin'), 'aal2', 'ops_do', 'manual_rental_create', test.irmr(jsonb_build_object('insurance', jsonb_build_object(
  'insurer_id', test.irins('Ir No Sheet Mutual'), 'claim_number', 'IR-3', 'authorized_daily_rate_cents', 6000, 'pays', 'split')), 4));
select test.eq('no sheet: the rate typed, no reason asked', (test.irb('b3')).insurer_authorized_daily_rate_cents, 6000::bigint);
select test.eq('no sheet row', (test.irb('b3')).insurer_rate_id, null::uuid);
select test.eq('no sheet: the share as before (rate x days)', (select x.rental_share_cents from app.booking_insurer_share((test.irb('b3')).id) x),
  least((select sum(li.amount_cents) from booking_line_items li join fee_types f on f.code = li.charge_type where li.booking_id = (test.irb('b3')).id and f.family = 'rental' and li.voided_at is null and li.stage in ('booking', 'extension')), 6000 * 4));

-- ================================================================ 5. a booking that changes insurer follows the sheet; a rate set with a reason stays
update bookings set insurer_id = test.irins('Ir Second Mutual') where id = (test.irb('b1')).id;
select test.eq('another insurer: its sheet''s rate for the car (pricing class)', (test.irb('b1')).insurer_authorized_daily_rate_cents, 5500::bigint);
update bookings set pickup_at = pickup_at + interval '1 day', return_at = return_at + interval '1 day' where id = (test.irb('b2')).id;
select test.eq('new dates: a rate set with a reason stays', (test.irb('b2')).insurer_authorized_daily_rate_cents, 7000::bigint);
update bookings set pickup_at = pickup_at + interval '1 hour' where id = (test.irb('b3')).id;
select test.eq('no sheet, new pickup time: the rate typed stays', (test.irb('b3')).insurer_authorized_daily_rate_cents, 6000::bigint);
update bookings set insurer_id = test.irins('Ir Allstate Test') where id = (test.irb('b3')).id;
select test.eq('a rate typed for an insurer without a sheet gives way to the new insurer''s sheet', ((test.irb('b3')).insurer_authorized_daily_rate_cents, (test.irb('b3')).insurer_sheet_daily_rate_cents)::text, '(6500,6500)');
-- the review screen's changes carry the reason (the door keeps it for the trigger)
select test.throws('the review screen: a rate typed without a reason is refused', $$ select app.door(test.id('ir_admin'), 'aal2', 'admin_do', 'booking_save',
  jsonb_build_object('booking', (test.irb('b2')).booking_number, 'changes', jsonb_build_object('insurer_authorized_daily_rate_cents', 7200))) $$, '%give the reason%');
select app.door(test.id('ir_admin'), 'aal2', 'admin_do', 'booking_save',
  jsonb_build_object('booking', (test.irb('b2')).booking_number, 'changes', jsonb_build_object('insurer_authorized_daily_rate_cents', 7200, 'insurer_rate_reason', 'Adjuster raised it')));
select test.eq('with the reason: saved', ((test.irb('b2')).insurer_authorized_daily_rate_cents, (test.irb('b2')).insurer_rate_reason)::text, '(7200,"Adjuster raised it")');

-- ================================================================ 6. the delivery and pickup allowance
insert into booking_line_items (booking_id, charge_type, quantity, unit_amount_cents, amount_cents, hst_applies, hst_cents, revenue_class, stage)
select (test.irb('b3')).id, 'delivery', 1, 8000, 8000, true, 1040, f.revenue_class, 'booking' from fee_types f where f.code = 'delivery';
update bookings set insurer_authorized_daily_rate_cents = 6500 where id = (test.irb('b3')).id;
select test.eq('split, with the allowance: the insurer pays delivery up to $50', (select x.fees_share_cents from app.booking_insurer_share((test.irb('b3')).id) x), 5000::bigint);
update bookings set bill_to = 'insurer' where id = (test.irb('b3')).id;
select test.eq('billed wholly: delivery above the allowance is the renter''s', (select x.fees_share_cents from app.booking_insurer_share((test.irb('b3')).id) x),
  (select coalesce(sum(li.amount_cents), 0) from booking_line_items li join fee_types f on f.code = li.charge_type where li.booking_id = (test.irb('b3')).id and f.family <> 'rental'
     and li.voided_at is null and li.charged_to_renter and li.stage in ('booking', 'extension')) - 3000);

-- ================================================================ 7. the invoice says the rate and keeps it
update bookings set status = 'confirmed' where id = (test.irb('b1')).id and status not in ('confirmed', 'on_rent');
update bookings set insurer_id = test.irins('Ir Allstate Test') where id = (test.irb('b1')).id;
select test.eq('back to Allstate: the sheet''s rate again', (test.irb('b1')).insurer_authorized_daily_rate_cents, 6500::bigint);
insert into test.ir select 'inv', to_jsonb(app.draft_insurer_invoice((test.irb('b1')).id, test.id('ir_admin')));
create function test.irinv() returns insurer_invoices language sql stable security definer as $$ select * from insurer_invoices where id = (test.irv('inv') #>> '{}')::uuid $$;
select test.ok('the invoice line says the rate and the sheet', (test.irinv()).lines -> 0 ->> 'description' like '%at $65.00 a day (Ir Allstate Test rate sheet, Sedan), at most $390.00 a week%');
select test.eq('the rate is kept on the invoice', ((test.irinv()).daily_rate_cents, (test.irinv()).rate_source)::text, '(6500,sheet)');
select test.ok('the taxes note is on it', (test.irinv()).notes like '%HST is billed on top%');
select test.eq('the amount is the capped share', (test.irinv()).amount_cents, (select x.share_cents from app.booking_insurer_share((test.irb('b1')).id) x));
select test.ok('the PDF facts carry the note', app.pdf_facts('insurer_invoice', (test.irinv()).id::text, test.id('ir_admin')) ->> 'note' like '%HST is billed on top%');
-- sent and paid in 12 days
update insurer_invoices set status = 'sent', sent_at = now() - interval '12 days', sent_by = test.id('ir_admin') where id = (test.irinv()).id;
select app.record_insurer_payment((test.irinv()).id, (test.irinv()).total_cents, test.id('ir_admin'), 'bank_transfer', now(), 'EFT-163');

-- ================================================================ 8. the billing history, by class and by booking
insert into test.ir select 'bill', app.door(test.id('ir_admin'), 'aal2', 'admin_read', 'insurer_billing', jsonb_build_object('insurer', test.irins('Ir Allstate Test')));
select test.ok('the rates with their history', jsonb_array_length(test.irv('bill') -> 'rates') = 2);
select test.eq('the old rate ends the day before the new one', (select r ->> 'effective_to' from jsonb_array_elements(test.irv('bill') -> 'rates') r where (r ->> 'daily_rate_cents')::bigint = 6500), (current_date + 9)::text);
select test.ok('the bookings billed to it', (select count(*) from jsonb_array_elements(test.irv('bill') -> 'bookings')) >= 2);
select test.eq('the paid booking: billed, paid, nothing outstanding, 12 days to pay',
  (select format('%s %s %s %s', b ->> 'billed_cents' = b ->> 'paid_cents', (b ->> 'paid_cents')::bigint > 0, b ->> 'outstanding_cents', b ->> 'days_to_pay')
     from jsonb_array_elements(test.irv('bill') -> 'bookings') b where b ->> 'booking_number' = (test.irb('b1')).booking_number), 't t 0 12.0');
select test.ok('each booking links its invoices', (select jsonb_array_length(b -> 'invoices') from jsonb_array_elements(test.irv('bill') -> 'bookings') b where b ->> 'booking_number' = (test.irb('b1')).booking_number) = 1);
select test.ok('by class: the sedans', exists (select 1 from jsonb_array_elements(test.irv('bill') -> 'by_class') c where c ->> 'class_code' = 'sedan' and (c ->> 'bookings')::int >= 1 and (c ->> 'days_to_pay')::numeric = 12.0));
select test.ok('by class: days authorized and used', (select (c ->> 'days_used')::int >= 10 and (c ->> 'days_authorized')::int >= 10 from jsonb_array_elements(test.irv('bill') -> 'by_class') c where c ->> 'class_code' = 'sedan'));
select test.ok('the totals: an average rate', (test.irv('bill') #>> '{totals,average_rate_cents}')::bigint between 6000 and 7200);
select test.eq('a period with no booking: nothing', (app.insurer_billing(test.id('ir_admin'), jsonb_build_object('insurer', test.irins('Ir Allstate Test'), 'from', '2020-01-01', 'to', '2020-02-01')) #>> '{totals,bookings}'), '0');
select test.throws('customer service cannot read the billing history', $$ select app.door(test.id('ir_cs'), 'aal2', 'admin_read', 'insurer_billing', jsonb_build_object('insurer', test.irins('Ir Allstate Test'))) $$, '%Admin%');
select test.eq('the grid totals what was billed', (select (i ->> 'billed_cents')::bigint from jsonb_array_elements(app.insurer_rate_sheet(test.id('ir_admin'), '{}') -> 'insurers') i where i ->> 'name' = 'Ir Allstate Test'), (test.irinv()).total_cents);

-- ================================================================ 9. the table itself
select test.eq('row level security is on', (select relrowsecurity from pg_class where oid = 'public.insurer_rates'::regclass), true);
select test.eq('a renter''s session reads no rate', (select has_function_privilege('authenticated', 'app.insurer_rate_set(uuid,jsonb)', 'execute')), false);
select test.ok('the admin policy and the staff read policy', (select count(*) from pg_policies where tablename = 'insurer_rates' and policyname in ('admin_all', 'staff_read')) = 2);
