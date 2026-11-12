-- 99: insurer-billed rentals that do not block the calendar need no account, phone or email for the renter (migration 2310).
-- The one case: billed to an insurer AND off the calendar. Every other case still asks for the email and the phone, and
-- nothing is queued for a renter who has no way to be reached. Fixtures start with "nc".
select test.suite('99 r37 insurer rentals without renter contact');
select set_config('app.paper_fixture', 'on', false);

select test.mk_user('nc_admin', 'admin');
select test.mk_user('nc_cs', 'va', 'cs');
create table test.nc (k text primary key, v jsonb);
grant select on test.nc to authenticated, service_role;
create function test.ncv(p text) returns jsonb language sql stable as $$ select v from test.nc where k = p $$;
insert into insurers (name, billing_email) values ('Nc Example Mutual', 'claims.nc@example.test');
create function test.ncins() returns uuid language sql stable as $$ select id from insurers where name = 'Nc Example Mutual' $$;
insert into test.nc select 'car', app.vehicle_add(test.id('nc_admin'), jsonb_build_object('supply_type', 'company', 'vin', '3VWCX7BU0RM000310',
  'plate', 'NCJ310', 'year', 2024, 'make', 'Volkswagen', 'model', 'Jetta', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
create function test.nccar() returns uuid language sql stable as $$ select (test.ncv('car') ->> 'vehicle_id')::uuid $$;
-- a second car with no deposit: customer service has no limit to take one
insert into test.nc select 'car0', app.vehicle_add(test.id('nc_admin'), jsonb_build_object('supply_type', 'company', 'vin', '3VWCX7BU0RM000311',
  'plate', 'NCJ311', 'year', 2024, 'make', 'Volkswagen', 'model', 'Jetta', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 0)));
-- an insurance replacement, 3 days, off the calendar, the renter with a name and a date of birth only; p overrides
create function test.ncmr(p jsonb, p_start integer default 2) returns jsonb language sql stable as $$
  select jsonb_build_object('vehicle_id', test.nccar(), 'pickup_at', date_trunc('hour', now()) + make_interval(days => p_start), 'return_at', date_trunc('hour', now()) + make_interval(days => p_start + 3),
    'coverage_option', 1, 'source', 'insurer', 'sales_choice', 'for_carmacars', 'agreement', 'paper', 'blocks_calendar', false, 'blocks_calendar_reason', 'Dates not known yet',
    'renter', jsonb_build_object('full_name', 'Nia Contactless', 'date_of_birth', '1980-01-01'),
    'insurance', jsonb_build_object('insurer_id', test.ncins(), 'claim_number', 'NC-1', 'pays', 'insurer', 'dates_provisional', true),
    'payment', jsonb_build_object('mode', 'unpaid', 'method', 'insurer'), 'deposit', jsonb_build_object('method', 'cash')) || p $$;
create function test.ncb(p text) returns bookings language sql stable security definer as $$ select * from bookings where id = (test.ncv(p) ->> 'booking_id')::uuid $$;
create function test.ncr(p text) returns renters language sql stable security definer as $$ select * from renters where id = (test.ncv(p) ->> 'renter_id')::uuid $$;

-- ================================================================ 1. the case: saves with a name only
insert into test.nc select 'a', app.door(test.id('nc_admin'), 'aal2', 'ops_do', 'manual_rental_create', test.ncmr('{}'::jsonb));
select test.eq('insurer + off the calendar: saves with no email, phone or account',
  ((test.ncb('a')).bill_to, (test.ncb('a')).blocks_calendar, (test.ncr('a')).user_id is null, (test.ncr('a')).email is null, (test.ncr('a')).mobile is null)::text, '(insurer,f,t,t,t)');
select test.eq('the renter keeps the name and the date of birth (the driver details)', ((test.ncr('a')).legal_name, (test.ncr('a')).date_of_birth)::text, '("Nia Contactless",1980-01-01)');
select test.eq('no account was made', (select count(*) from users where full_name = 'Nia Contactless'), 0::bigint);
select test.ok('the renter counts as having no way to be reached', app.renter_is_contactless((test.ncr('a')).id));
insert into test.nc select 'cs', app.door(test.id('nc_cs'), 'aal2', 'ops_do', 'manual_rental_create',
  test.ncmr(jsonb_build_object('renter', jsonb_build_object('full_name', 'Cal Staffer', 'date_of_birth', '1985-05-05'), 'vehicle_id', (test.ncv('car0') ->> 'vehicle_id')::uuid, 'deposit', jsonb_build_object('method', 'e_transfer', 'reference', 'NC-D1')), 6));
select test.ok('customer service (a staff portal) adds it the same way', (test.ncb('cs')).bill_to = 'insurer' and not (test.ncb('cs')).blocks_calendar);
insert into test.nc select 'mail', app.door(test.id('nc_admin'), 'aal2', 'ops_do', 'manual_rental_create',
  test.ncmr(jsonb_build_object('renter', jsonb_build_object('full_name', 'Em Mailonly', 'date_of_birth', '1981-02-02', 'email', 'em.mailonly@example.test')), 10));
select test.ok('an email alone is kept (the phone is optional)', (select count(*) = 1 from users where email = 'em.mailonly@example.test') and not app.renter_is_contactless((test.ncr('mail')).id));
select test.throws('an email typed must still look like one', $$ select app.door(test.id('nc_admin'), 'aal2', 'ops_do', 'manual_rental_create',
  test.ncmr(jsonb_build_object('renter', jsonb_build_object('full_name', 'Bad Mail', 'date_of_birth', '1980-01-01', 'email', 'not-an-email')), 14)) $$, '%does not look right%');
select test.throws('the name and the date of birth are still needed', $$ select app.door(test.id('nc_admin'), 'aal2', 'ops_do', 'manual_rental_create',
  test.ncmr(jsonb_build_object('renter', jsonb_build_object('full_name', 'No Birthday')), 18)) $$, '%full legal name and date of birth%');

-- ================================================================ 2. every other case still asks for the email and the phone
select test.throws('an insurer rental that blocks the calendar: the email is needed', $$ select app.door(test.id('nc_admin'), 'aal2', 'ops_do', 'manual_rental_create',
  test.ncmr(jsonb_build_object('blocks_calendar', true), 22)) $$, '%renter''s email%');
select test.throws('a rental billed to the renter, off the calendar: the email is needed', $$ select app.door(test.id('nc_admin'), 'aal2', 'ops_do', 'manual_rental_create',
  test.ncmr(jsonb_build_object('payment', jsonb_build_object('mode', 'other_way', 'method', 'cash', 'reference', 'x'), 'insurance', null), 26)) $$, '%renter''s email%');
select test.throws('a payment link to the renter needs the email even for an insurer rental', $$ select app.door(test.id('nc_admin'), 'aal2', 'ops_do', 'manual_rental_create',
  test.ncmr(jsonb_build_object('payment', jsonb_build_object('mode', 'link', 'method', 'insurer')), 30)) $$, '%renter''s email%');
select test.throws('an email without a phone: the phone is needed when the rental is not the insurer case', $$ select app.door(test.id('nc_admin'), 'aal2', 'ops_do', 'manual_rental_create',
  test.ncmr(jsonb_build_object('blocks_calendar', true, 'renter', jsonb_build_object('full_name', 'Em Nophone', 'date_of_birth', '1980-01-01', 'email', 'em.nophone@example.test')), 34)) $$, '%renter''s phone%');
select test.eq('nothing was left behind by the refused calls', (select count(*) from renters where legal_name in ('Bad Mail', 'No Birthday', 'Em Nophone')), 0::bigint);

-- ================================================================ 3. nothing is queued without an address
select app.process_events(100000);
select test.eq('no renter email is queued for a renter with no contact (no row, no empty address)',
  (select count(*) from notification_outbox where renter_id = (test.ncr('a')).id or renter_id = (test.ncr('cs')).id or (audience = 'renter' and nullif(btrim(coalesce(to_address, '')), '') is null and booking_id in ((test.ncb('a')).id, (test.ncb('cs')).id))), 0::bigint);
select test.ok('the renter who gave an email still gets the rental-added email', exists (select 1 from notification_outbox where booking_id = (test.ncb('mail')).id and to_address = 'em.mailonly@example.test'));
select test.eq('no text row for a renter with no number', (app.phone_outbox_put(null, 'Hello', 'booking', (test.ncb('a')).id, (test.ncr('a')).id)).id, null::uuid);
select test.eq('no text row for an empty number either', (app.phone_outbox_put('  ', 'Hello', 'notify', null, (test.ncr('a')).id)).id, null::uuid);
select test.eq('and none was written', (select count(*) from phone_outbox where renter_id in ((test.ncr('a')).id, (test.ncr('cs')).id)), 0::bigint);

-- ================================================================ 4. statements and the insurer invoice still work
insert into test.nc select 'inv', to_jsonb(app.draft_insurer_invoice((test.ncb('a')).id, test.id('nc_admin')));
select test.ok('the insurer invoice is drafted for the booking', test.ncv('inv') is not null and (test.ncb('a')).insurer_id = test.ncins());
select test.ok('the booking reads for the Admin with no renter contact', app.admin_booking_json((test.ncb('a')).id) is not null);
insert into test.nc select 'past', app.door(test.id('nc_admin'), 'aal2', 'ops_do', 'manual_rental_create', test.ncmr(jsonb_build_object('past', true,
  'pickup_at', date_trunc('hour', now()) - interval '6 days', 'return_at', date_trunc('hour', now()) - interval '3 days',
  'renter', jsonb_build_object('full_name', 'Pat Pastrental', 'date_of_birth', '1979-03-03')), 0));
select test.eq('a past insurer rental with no contact is recorded closed, with its split for the statements', ((test.ncb('past')).status::text, (select count(*) > 0 from booking_splits where booking_id = (test.ncb('past')).id))::text, '(closed,t)');
