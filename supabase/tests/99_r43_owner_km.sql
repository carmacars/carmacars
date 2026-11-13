-- 99: release 43 (migration 2740). A. The owner reads the car's current kilometres (latest odometer reading) with its date and the next
-- service with its status through the existing owner read (maint_owner): own cars only. B. Add a rental: the renter's email is
-- optional when the rental already ended, is billed to an insurer, or "Do not email the renter" is ticked; an upcoming rental that is
-- none of those still needs a phone or an email. Fixtures start with "rq43k_".
select test.suite('99 r43 owner kilometres and optional renter email');
select set_config('app.paper_fixture', 'on', false);

select test.mk_user('rq43k_admin', 'admin');
select test.mk_owner('rq43k_olga');
select test.mk_owner('rq43k_other');
select test.mk_vehicle('rq43k_car', 'rq43k_olga');
create function test.k43v() returns uuid language sql stable as $$ select test.id('vehicle:rq43k_car') $$;
create function test.k43read(p_user text) returns jsonb language sql as $$
  select app.door(test.id(p_user), 'aal2', 'ops_read', 'maint_owner', jsonb_build_object('vehicle_id', test.k43v())) $$;

-- ================================================================ A. kilometres and next service
insert into vehicle_odometer_readings (vehicle_id, read_at, km, source) values (test.k43v(), now() - interval '40 days', 41000, 'manual'), (test.k43v(), now() - interval '2 days', 42310, 'return');
select app.door(test.id('rq43k_admin'), 'aal2', 'ops_do', 'maint_record', jsonb_build_object('vehicle_id', test.k43v(), 'done_on', app.today() - 30, 'odometer_km', 41000,
  'items', jsonb_build_array('oil_filter'), 'payer', 'none'));
select test.eq('the owner sees the current kilometres: the latest reading', (test.k43read('rq43k_olga') ->> 'km')::integer, 42310);
select test.eq('and the day it was read', test.k43read('rq43k_olga') ->> 'km_on', app.local_date(now() - interval '2 days')::text);
select test.eq('the next service: oil and filter, the km left (8,000 km interval from 41,000) and its status',
  (test.k43read('rq43k_olga') -> 'next' ->> 'label') || '|' || (test.k43read('rq43k_olga') -> 'next' ->> 'km_left') || '|' || (test.k43read('rq43k_olga') -> 'next' ->> 'status'), 'Oil and filter|6690|ok');
select app.maint_add_reading(test.k43v(), 48500, now(), 'manual');
select test.eq('after 48,500 km the oil change is due soon or overdue, never ok', (test.k43read('rq43k_olga') -> 'next' ->> 'status') in ('due_soon', 'overdue'), true);
select test.eq('the owner''s current km follows the newest reading', (test.k43read('rq43k_olga') ->> 'km')::integer, 48500);
select test.ok('the Admin reads it too', (test.k43read('rq43k_admin') ->> 'km') is not null);
select test.throws('another owner cannot read the car', $$select test.k43read('rq43k_other')$$, 'Not permitted');

-- ================================================================ B. Add a rental: the renter's email is optional
create table test.k43 (k text primary key, v jsonb);
insert into insurers (name, billing_email) values ('Rq43k Example Mutual', 'claims.rq43k@example.test');
create function test.k43mr(p jsonb, p_start integer default 2) returns jsonb language sql stable as $$
  select jsonb_build_object('vehicle_id', test.k43v(), 'pickup_at', date_trunc('hour', now()) + make_interval(days => p_start), 'return_at', date_trunc('hour', now()) + make_interval(days => p_start + 3),
    'coverage_option', 1, 'source', 'phone', 'sales_choice', 'for_carmacars', 'agreement', 'send',
    'renter', jsonb_build_object('full_name', 'Kay Rq43k', 'date_of_birth', '1980-01-01', 'mobile', '4165550143'),
    'payment', jsonb_build_object('mode', 'other_way', 'method', 'cash', 'reference', 'k43'), 'deposit', jsonb_build_object('method', 'cash')) || p $$;
create function test.k43b(p text) returns bookings language sql stable security definer as $$ select * from bookings where id = (select (v ->> 'booking_id')::uuid from test.k43 where k = p) $$;

-- upcoming, no tick, no insurer: the email is still needed
select test.throws('upcoming, billed to the renter, no "Do not email": the email is still needed', $$ select app.door(test.id('rq43k_admin'), 'aal2', 'ops_do', 'manual_rental_create', test.k43mr('{}'::jsonb, 2)) $$, '%renter''s email%');
-- "Do not email the renter", upcoming, phone only: saves; a task asks for the email
insert into test.k43 select 'ph', app.door(test.id('rq43k_admin'), 'aal2', 'ops_do', 'manual_rental_create', test.k43mr(jsonb_build_object('do_not_email', true), 2));
select test.ok('upcoming, "Do not email", phone only: saved with no email', (test.k43b('ph')).id is not null and (select email is null and user_id is null from renters where id = (test.k43b('ph')).renter_id));
select test.eq('a task asks staff to add the email (the agreement waits)', (select count(*) from tasks where booking_id = (test.k43b('ph')).id and task_type = 'renter_email_needed'), 1::bigint);
select test.throws('upcoming, neither phone nor email, not insurer-billed: refused', $$ select app.door(test.id('rq43k_admin'), 'aal2', 'ops_do', 'manual_rental_create',
  test.k43mr(jsonb_build_object('do_not_email', true, 'renter', jsonb_build_object('full_name', 'No Contact', 'date_of_birth', '1980-01-01')), 8)) $$, '%email address or phone%');
-- do not email: no email needed, a phone is
insert into test.k43 select 'dne', app.door(test.id('rq43k_admin'), 'aal2', 'ops_do', 'manual_rental_create',
  test.k43mr(jsonb_build_object('do_not_email', true, 'renter', jsonb_build_object('full_name', 'Dee Notemail', 'date_of_birth', '1980-01-01', 'mobile', '4165550144')), 12));
select test.ok('"Do not email the renter": saved with a phone and no email', (test.k43b('dne')).do_not_email);
select test.throws('a payment link still needs the email (insurer-billed, no email)', $$ select app.door(test.id('rq43k_admin'), 'aal2', 'ops_do', 'manual_rental_create',
  test.k43mr(jsonb_build_object('source', 'insurer', 'insurance', jsonb_build_object('insurer_id', (select id from insurers where name = 'Rq43k Example Mutual'), 'claim_number', 'K43-0', 'pays', 'insurer'),
    'payment', jsonb_build_object('mode', 'link', 'method', 'insurer')), 16)) $$, '%payment link%');
-- already ended: nothing needed but the name and date of birth
insert into test.k43 select 'past', app.door(test.id('rq43k_admin'), 'aal2', 'ops_do', 'manual_rental_create', test.k43mr(jsonb_build_object('past', true,
  'pickup_at', date_trunc('hour', now()) - interval '9 days', 'return_at', date_trunc('hour', now()) - interval '6 days',
  'renter', jsonb_build_object('full_name', 'Pat Pastk', 'date_of_birth', '1979-03-03')), 0));
select test.eq('already ended, no email or phone: recorded closed, no task for an email', ((test.k43b('past')).status::text, (select count(*) from tasks where booking_id = (test.k43b('past')).id and task_type = 'renter_email_needed'))::text, '(closed,0)');
select test.throws('a bad email is still refused', $$ select app.door(test.id('rq43k_admin'), 'aal2', 'ops_do', 'manual_rental_create',
  test.k43mr(jsonb_build_object('do_not_email', true, 'renter', jsonb_build_object('full_name', 'Bad Mail', 'date_of_birth', '1980-01-01', 'email', 'nope')), 20)) $$, '%does not look right%');
-- insurer-billed: name only, on the calendar too
insert into test.k43 select 'ins', app.door(test.id('rq43k_admin'), 'aal2', 'ops_do', 'manual_rental_create', test.k43mr(jsonb_build_object('source', 'insurer',
  'insurance', jsonb_build_object('insurer_id', (select id from insurers where name = 'Rq43k Example Mutual'), 'claim_number', 'K43-1', 'pays', 'insurer'),
  'payment', jsonb_build_object('mode', 'unpaid', 'method', 'insurer'), 'renter', jsonb_build_object('full_name', 'Ines Insurer')), 24));
select test.ok('insurer-billed, on the calendar, name only: saved', (test.k43b('ins')).bill_to = 'insurer' and (test.k43b('ins')).blocks_calendar);
-- an email and no phone on a past rental: kept as a normal renter with an account
insert into test.k43 select 'mail', app.door(test.id('rq43k_admin'), 'aal2', 'ops_do', 'manual_rental_create', test.k43mr(jsonb_build_object('past', true,
  'pickup_at', date_trunc('hour', now()) - interval '20 days', 'return_at', date_trunc('hour', now()) - interval '17 days',
  'renter', jsonb_build_object('full_name', 'Mia Mailk', 'date_of_birth', '1981-02-02', 'email', 'mia.mailk.rq43k@example.test')), 0));
select test.ok('a past rental with an email and no phone: saved, the account made', (select count(*) = 1 from users where email = 'mia.mailk.rq43k@example.test'));
