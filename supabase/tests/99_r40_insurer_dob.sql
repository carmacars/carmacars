-- 99: an insurer-billed rental needs no date of birth for the renter (migration 2510). The name is still needed; every other
-- rental still needs the date of birth. Fixtures start with "dob".
select test.suite('99 r40 insurer rentals without a date of birth');
select set_config('app.paper_fixture', 'on', false);

select test.mk_user('r40dob_admin', 'admin');
create table test.dob (k text primary key, v jsonb);
grant select on test.dob to authenticated, service_role;
create function test.dobv(p text) returns jsonb language sql stable as $$ select v from test.dob where k = p $$;
insert into insurers (name, billing_email) values ('Dob Example Mutual', 'claims.dob@example.test');
create function test.dobins() returns uuid language sql stable as $$ select id from insurers where name = 'Dob Example Mutual' $$;
insert into test.dob select 'car', app.vehicle_add(test.id('r40dob_admin'), jsonb_build_object('supply_type', 'company', 'vin', '3VWCX7BU0RM000510',
  'plate', 'DOB510', 'year', 2024, 'make', 'Volkswagen', 'model', 'Jetta', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
create function test.dobcar() returns uuid language sql stable as $$ select (test.dobv('car') ->> 'vehicle_id')::uuid $$;
-- an insurance replacement, 3 days, on the calendar, the renter with a name, an email and a phone only; p overrides
create function test.dobmr(p jsonb, p_start integer default 2) returns jsonb language sql stable as $$
  select jsonb_build_object('vehicle_id', test.dobcar(), 'pickup_at', date_trunc('hour', now()) + make_interval(days => p_start), 'return_at', date_trunc('hour', now()) + make_interval(days => p_start + 3),
    'coverage_option', 1, 'source', 'insurer', 'sales_choice', 'for_carmacars', 'agreement', 'paper',
    'renter', jsonb_build_object('full_name', 'Dana Nobirthday', 'email', 'dana.nobirthday@example.test', 'mobile', '4165550110', 'licence_number', 'N1234-56789-01234'),
    'insurance', jsonb_build_object('insurer_id', test.dobins(), 'claim_number', 'DOB-1', 'pays', 'insurer'),
    'payment', jsonb_build_object('mode', 'unpaid', 'method', 'insurer'), 'deposit', jsonb_build_object('method', 'cash')) || p $$;
create function test.dobb(p text) returns bookings language sql stable security definer as $$ select * from bookings where id = (test.dobv(p) ->> 'booking_id')::uuid $$;

-- ================================================================ 1. the case: saves with no date of birth
insert into test.dob select 'a', app.door(test.id('r40dob_admin'), 'aal2', 'ops_do', 'manual_rental_create', test.dobmr('{}'::jsonb));
select test.eq('insurer-billed: saves with no date of birth', (test.dobb('a')).bill_to::text, 'insurer');
select test.eq('the renter has no date of birth and no stand-in date is left behind',
  (select (r.date_of_birth is null, (select count(*) from drivers d where d.renter_id = r.id and d.date_of_birth is not null))::text from renters r where r.id = (test.dobb('a')).renter_id), '(t,0)');
select test.eq('the booking driver line has no date of birth, no age and no band',
  (select (d.date_of_birth is null, d.age_at_pickup is null, d.age_band is null)::text from booking_drivers d where d.booking_id = (test.dobb('a')).id and d.role = 'renter'), '(t,t,t)');
select test.eq('no young driver fee is charged', (select count(*) from booking_line_items l where l.booking_id = (test.dobb('a')).id and l.charge_type like 'young_driver%'), 0::bigint);
select test.eq('the licence number typed is kept', (select d.licence_number from drivers d where d.renter_id = (test.dobb('a')).renter_id and d.is_account_holder), 'N1234-56789-01234');
select test.ok('the booking reads for the Admin without a date of birth', app.admin_booking_json((test.dobb('a')).id) is not null);
insert into test.dob select 'inv', to_jsonb(app.draft_insurer_invoice((test.dobb('a')).id, test.id('r40dob_admin')));
select test.ok('the insurer invoice is drafted for the booking', test.dobv('inv') is not null);

-- ================================================================ 2. a date of birth typed is still kept and checked
insert into test.dob select 'b', app.door(test.id('r40dob_admin'), 'aal2', 'ops_do', 'manual_rental_create',
  test.dobmr(jsonb_build_object('renter', jsonb_build_object('full_name', 'Bo Withbirthday', 'email', 'bo.withbirthday@example.test', 'mobile', '4165550111', 'date_of_birth', '1980-01-01')), 8));
select test.eq('a date of birth typed is kept', (select (r.date_of_birth, (select d.age_band from booking_drivers d where d.booking_id = (test.dobb('b')).id and d.role = 'renter'))::text from renters r where r.id = (test.dobb('b')).renter_id), '(1980-01-01,26_plus)');
select test.throws('a renter under the minimum age is still refused', $$ select app.door(test.id('r40dob_admin'), 'aal2', 'ops_do', 'manual_rental_create',
  test.dobmr(jsonb_build_object('renter', jsonb_build_object('full_name', 'Kid Tooyoung', 'email', 'kid.tooyoung@example.test', 'mobile', '4165550112', 'date_of_birth', (current_date - interval '16 years')::date::text)), 14)) $$, '%or older at pickup%');

-- ================================================================ 3. the name is still needed; every other rental still needs the date of birth
select test.throws('the name is still needed', $$ select app.door(test.id('r40dob_admin'), 'aal2', 'ops_do', 'manual_rental_create',
  test.dobmr(jsonb_build_object('renter', jsonb_build_object('full_name', '', 'email', 'x.noname@example.test', 'mobile', '4165550113')), 20)) $$, '%full legal name%');
select test.throws('a rental billed to the renter still needs the date of birth', $$ select app.door(test.id('r40dob_admin'), 'aal2', 'ops_do', 'manual_rental_create',
  test.dobmr(jsonb_build_object('payment', jsonb_build_object('mode', 'other_way', 'method', 'cash', 'reference', 'x'), 'insurance', null,
    'renter', jsonb_build_object('full_name', 'Cash Nobirthday', 'email', 'cash.nobirthday@example.test', 'mobile', '4165550114')), 26)) $$, '%date of birth%');
select test.eq('nothing was left behind by the refused calls', (select count(*) from renters where legal_name in ('Kid Tooyoung', 'Cash Nobirthday')), 0::bigint);
select test.throws('an additional driver still needs a date of birth', $$ select app.door(test.id('r40dob_admin'), 'aal2', 'ops_do', 'manual_rental_create',
  test.dobmr(jsonb_build_object('additional_drivers', jsonb_build_array(jsonb_build_object('full_name', 'Extra Driver'))), 32)) $$, '%additional driver%');

-- ================================================================ 4. a renter added later has no date of birth: renting them to an insurer works, to themselves does not
select test.ok('a renter on file without a date of birth rents to an insurer', (select (app.door(test.id('r40dob_admin'), 'aal2', 'ops_do', 'manual_rental_create',
  test.dobmr(jsonb_build_object('renter_id', (test.dobb('a')).renter_id, 'renter', null), 38)) ->> 'booking_id') is not null));
select test.throws('...but not billed to themselves', $$ select app.door(test.id('r40dob_admin'), 'aal2', 'ops_do', 'manual_rental_create',
  test.dobmr(jsonb_build_object('renter_id', (test.dobb('a')).renter_id, 'renter', null, 'payment', jsonb_build_object('mode', 'other_way', 'method', 'cash', 'reference', 'y'), 'insurance', null), 44)) $$, '%date of birth%');
