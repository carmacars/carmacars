-- 99: placeholder bookings kept apart from the real rental (0283) and conflicting dates on one car (0284).
-- docs/changes/2026-11-05-placeholder-bookings.md. Fixtures start with "ph" and use example.test only.
select test.suite('99 placeholders and conflicting dates');

select test.mk_user('ph_admin', 'admin');
select test.mk_user('ph_cs', 'va', 'cs');
select test.mk_user('ph_sales', 'va', 'sales');
select test.mk_owner('ph_olive');
select test.mk_vehicle('ph_car', 'ph_olive');
select test.mk_vehicle('ph_toll', 'ph_olive');
select test.mk_renter('ph_rita');
select test.mk_renter('ph_ins');
insert into payment_method_secrets (payment_method_id, processor, processor_customer_id, processor_method_id)
values (test.id('card:ph_rita'), 'stripe', 'cus_ph_rita', 'pm_ph_rita'), (test.id('card:ph_ins'), 'stripe', 'cus_ph_ins', 'pm_ph_ins');
update program_settings set field_jobs_auto = true where id = (app.settings()).id;

create temp table ph as select null::text as k, null::jsonb as v limit 0;
create or replace function test.ph(p_k text) returns jsonb language sql stable as $$ select v from pg_temp.ph where k = p_k $$;
create or replace function test.phb(p text) returns bookings language sql stable as $$ select * from bookings where id = (test.ph(p) ->> 'booking_id')::uuid $$;
create or replace function test.phr(p_renter text, p_from interval, p_to interval, p jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select jsonb_build_object('vehicle_id', test.id('vehicle:ph_car'), 'pickup_at', date_trunc('hour', now()) + p_from, 'return_at', date_trunc('hour', now()) + p_to,
                            'source', 'phone', 'coverage_option', 1, 'renter_id', test.id('renter:' || p_renter)) || p
$$;

-- ================================================================ 1. Add a rental: a placeholder from the start
select test.throws('placeholder: an Admin only',
  format($$select app.manual_rental_create(%L, test.phr('ph_ins', interval '3 days', interval '9 days', '{"placeholder": true, "payment": {"mode": "unpaid"}}'))$$, test.id('ph_cs')),
  'Admin');
select test.throws('placeholder: never a past rental',
  format($$select app.manual_rental_create(%L, test.phr('ph_ins', interval '-9 days', interval '-3 days', '{"placeholder": true, "past": true, "payment": {"mode": "unpaid"}}'))$$, test.id('ph_admin')),
  'never a past rental');
insert into ph select 'place', app.manual_rental_create(test.id('ph_admin'), test.phr('ph_ins', interval '3 days', interval '9 days',
  '{"placeholder": true, "placeholder_reason": "Insurer hold", "source": "other", "source_note": "Placeholder booking (insurance or a hold)", "payment": {"mode": "unpaid"}}'));
select test.eq('placeholder: added, not blocking, no emails, marked with its reason',
  (select status || '/' || blocks_calendar || '/' || do_not_email || '/' || is_placeholder || '/' || placeholder_reason from test.phb('place')),
  'confirmed/false/true/true/Insurer hold');
select test.ok('placeholder: the history says so', exists (select 1 from booking_events e where e.booking_id = (test.phb('place')).id and e.kind = 'placeholder'));
select test.ok('placeholder: app.booking_is_placeholder', app.booking_is_placeholder((test.phb('place')).id));
select test.eq('placeholder: no field job is made for it', (select count(*) from field_jobs j where j.booking_id = (test.phb('place')).id and j.status <> 'cancelled'), 0::bigint);

-- the real rental over the same days goes in as usual and blocks the car
insert into ph select 'real', app.manual_rental_create(test.id('ph_admin'), test.phr('ph_rita', interval '4 days', interval '7 days',
  '{"payment": {"mode": "other_way", "method": "e_transfer", "reference": "PH-1"}}'));
select test.eq('real rental: entered over the placeholder, confirmed and blocking', (select status || '/' || blocks_calendar || '/' || is_placeholder from test.phb('real')), 'confirmed/true/false');
select test.ok('real rental: its field jobs are made', exists (select 1 from field_jobs j where j.booking_id = (test.phb('real')).id and j.status <> 'cancelled'));
select test.ok('availability: the real rental holds the car, the placeholder does not',
  not app.vehicle_is_available(test.id('vehicle:ph_car'), (test.phb('real')).pickup_at, (test.phb('real')).return_at, null)
  and app.vehicle_is_available(test.id('vehicle:ph_car'), (test.phb('place')).return_at - interval '1 day', (test.phb('place')).return_at, null));
select app.set_blocks_calendar((test.phb('place')).id, true, test.id('ph_admin'), 'try to block');
select test.eq('placeholder: the calendar switch stays off', (select blocks_calendar from test.phb('place')), false);
select test.throws('placeholder: never handed over', format($$update bookings set status = 'on_rent', handed_over_at = now() where id = %L$$, (test.phb('place')).id),
  'never handed over');

-- ================================================================ 2. no renter work, no commission
select test.ok('tasks: a renter task for a placeholder is not raised',
  app.raise_task(p_type => 'take_deposit', p_booking => (test.phb('place')).id) is null
  and not exists (select 1 from tasks t where t.booking_id = (test.phb('place')).id and t.task_type = 'take_deposit'));
select test.ok('tasks: the same task for the real rental is raised', app.raise_task(p_type => 'take_deposit', p_booking => (test.phb('real')).id) is not null);
select test.ok('tasks: other work about the car still reaches staff',
  app.raise_task(p_type => 'staff_task', p_title => 'Check the placeholder', p_queue => 'fleet', p_booking => (test.phb('place')).id) is not null);
select test.eq('commission: none on a placeholder', app.commission_own_reason((test.phb('place')).id, test.id('ph_sales')), 'Placeholder booking');

-- ================================================================ 3. conflicting dates: the booking page and the calendar
insert into ph select 'c_real', app.booking_date_conflicts((test.phb('real')).id);
select test.eq('conflicts of the real rental: the placeholder, which holds nothing',
  (select string_agg((x ->> 'kind') || ':' || (x ->> 'holds'), ',') from jsonb_array_elements(test.ph('c_real')) x where x ->> 'type' = 'booking'), 'placeholder:false');
insert into ph select 'c_place', app.booking_date_conflicts((test.phb('place')).id);
select test.eq('conflicts of the placeholder: the real rental, booked, and nothing holds against a placeholder',
  (select string_agg((x ->> 'kind') || ':' || (x ->> 'holds'), ',') from jsonb_array_elements(test.ph('c_place')) x where x ->> 'type' = 'booking'), 'booked:false');
-- a renter's request for the real rental's days
select test.mk_booking('PH-REQ', 'ph_car', 'ph_rita', to_char((test.phb('real')).pickup_at at time zone 'America/Toronto' + interval '1 day', 'YYYY-MM-DD HH24:MI'),
  to_char((test.phb('real')).pickup_at at time zone 'America/Toronto' + interval '2 days', 'YYYY-MM-DD HH24:MI'), 'requested');
insert into ph select 'c_req', app.booking_date_conflicts(test.id('booking:PH-REQ'));
select test.eq('conflicts of a request: the real rental holds it, the placeholder does not',
  (select string_agg((x ->> 'kind') || ':' || (x ->> 'holds'), ',' order by x ->> 'kind') from jsonb_array_elements(test.ph('c_req')) x where x ->> 'type' = 'booking'),
  'booked:true,placeholder:false');
select test.ok('booking page: Competing for these dates, with the kinds',
  (select jsonb_array_length(d -> 'competing') >= 2 and d #>> '{placeholder,on}' = 'false' from (select app.admin_booking_detail(test.id('booking:PH-REQ')) d) s)
  and (select d #>> '{placeholder,on}' = 'true' and d #>> '{placeholder,reason}' = 'Insurer hold' from (select app.admin_booking_detail((test.phb('place')).id) d) s));
insert into ph select 'cal', app.door(test.id('ph_admin'), 'aal2', 'admin_read', 'calendar',
  jsonb_build_object('from', now(), 'to', now() + interval '14 days', 'vehicle', test.id('vehicle:ph_car')));
create or replace function test.phe(p_number text) returns jsonb language sql stable as $$
  select e from jsonb_array_elements(test.ph('cal') -> 'vehicles') v, jsonb_array_elements(v -> 'entries') e where e ->> 'booking_number' = p_number limit 1 $$;
select test.eq('calendar: the placeholder says so and clashes with nothing', (select (x ->> 'placeholder') || '/' || jsonb_array_length(x -> 'clash') from test.phe((test.phb('place')).booking_number) x), 'true/0');
select test.eq('calendar: the request clashes with the real rental only', (select x -> 'clash' from test.phe('PH-REQ') x), jsonb_build_array((test.phb('real')).booking_number));
select test.eq('calendar: the real rental clashes with nothing', (select jsonb_array_length(x -> 'clash') from test.phe((test.phb('real')).booking_number) x), 0);

-- ================================================================ 4. the Live map leaves the placeholder out
insert into ph select 'map', app.live_map(test.id('ph_admin'), jsonb_build_object('who', jsonb_build_array(test.id('renter:ph_ins'), test.id('renter:ph_rita'))));
select test.ok('Live map: no pin for the placeholder, one for the real rental',
  not exists (select 1 from jsonb_array_elements(test.ph('map') -> 'pins') x where x ->> 'booking_number' = (test.phb('place')).booking_number)
  and exists (select 1 from jsonb_array_elements(test.ph('map') -> 'pins') x where x ->> 'booking_number' = (test.phb('real')).booking_number));

-- ================================================================ 5. marking and unmarking
select test.throws('mark: an Admin only', format($$select app.set_booking_placeholder(%L, %L, true, 'x')$$, test.id('ph_cs'), (test.phb('real')).id), 'Admin');
insert into payments (booking_id, kind, purpose, status, amount_cents, processed_at)
values ((test.phb('real')).id, 'charge', 'booking_total', 'succeeded', 10000, now());
select test.throws('mark: refused when money was taken', format($$select app.set_booking_placeholder(%L, %L, true, 'x')$$, test.id('ph_admin'), (test.phb('real')).id), 'Money was taken');
select test.mk_booking('PH-OUT', 'ph_car', 'ph_rita', '2026-08-01 10:00', '2026-08-03 10:00', 'closed');
select test.throws('mark: refused once handed over', format($$select app.set_booking_placeholder(%L, %L, true, 'x')$$, test.id('ph_admin'), test.id('booking:PH-OUT')), 'handed over');
-- a confirmed blocking booking with a renter task becomes a placeholder: the switch goes off, the owner sees the dates only, the task closes
select test.mk_booking('PH-HOLD', 'ph_car', 'ph_ins', to_char(now() at time zone 'America/Toronto' + interval '20 days', 'YYYY-MM-DD 10:00'),
  to_char(now() at time zone 'America/Toronto' + interval '23 days', 'YYYY-MM-DD 10:00'), 'confirmed', 0);
select app.raise_task(p_type => 'take_deposit', p_booking => test.id('booking:PH-HOLD'));
insert into ph select 'mark', app.set_booking_placeholder(test.id('ph_admin'), test.id('booking:PH-HOLD'), true, 'Insurer asked for a hold');
select test.eq('mark: placeholder, not blocking, hidden from the owner, its renter task closed',
  (select is_placeholder || '/' || blocks_calendar || '/' || owner_visibility || '/' || do_not_email || '/'
          || (select count(*) from tasks t where t.booking_id = b.id and t.task_type = 'take_deposit' and t.status in ('open', 'in_progress', 'waiting'))
     from bookings b where b.id = test.id('booking:PH-HOLD')), 'true/false/never/true/0');
select test.ok('mark: the calendar switch change names who and why',
  (select blocks_calendar_changed_by = test.id('ph_admin') and blocks_calendar_reason like 'Placeholder booking%' from bookings where id = test.id('booking:PH-HOLD')));
select app.set_booking_placeholder(test.id('ph_admin'), test.id('booking:PH-HOLD'), false, 'It is the real rental after all');
select test.eq('unmark: a real booking again, the switch left for staff to turn on', (select is_placeholder || '/' || blocks_calendar from bookings where id = test.id('booking:PH-HOLD')), 'false/false');
select test.ok('mark and unmark: both in the history', (select count(*) from booking_events e where e.booking_id = test.id('booking:PH-HOLD') and e.kind = 'placeholder') = 2);
select test.ok('door: admin_do booking_placeholder', (app.door(test.id('ph_admin'), 'aal2', 'admin_do', 'booking_placeholder',
  jsonb_build_object('booking', test.id('booking:PH-HOLD'), 'on', true, 'reason', 'Hold')) ->> 'is_placeholder')::boolean);

-- ================================================================ 6. tolls and tickets go to the real renter
select test.mk_booking('PH-REAL-T', 'ph_toll', 'ph_rita', '2026-09-10 10:00', '2026-09-14 10:00', 'closed');
-- a placeholder over the same days that was even recorded as returned (the import path): still never the renter
insert into bookings (booking_number, booking_type, status, vehicle_id, renter_id, booked_at, pickup_at, return_at, original_return_at, billable_days,
    handed_over_at, checked_in_at, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, rate_applied, rental_charge_cents,
    km_allowance_per_day, km_allowance_total, overage_cents_per_km, deposit_cents, blocks_calendar, is_placeholder, placeholder_reason, created_by)
values ('PH-PLACE-T', 'standard', 'closed', test.id('vehicle:ph_toll'), test.id('renter:ph_ins'), now(), '2026-09-09 10:00 America/Toronto',
        '2026-09-20 10:00 America/Toronto', '2026-09-20 10:00 America/Toronto', 11, '2026-09-09 10:00 America/Toronto', '2026-09-20 10:00 America/Toronto',
        10000, 12000, 56000, 180000, 'daily', 0, 200, 2200, 35, 0, true, true, 'Insurer hold', test.id('ph_admin'));
select test.eq('placeholder: never blocks, even written straight in', (select blocks_calendar from bookings where booking_number = 'PH-PLACE-T'), false);
insert into ph select 'm1', app.match_toll_candidates(test.id('vehicle:ph_toll'), timestamptz '2026-09-12 14:00 America/Toronto', false);
select test.eq('toll: only the real rental is a candidate, matched automatically',
  (test.ph('m1') ->> 'decision') || '/' || (test.ph('m1') -> 'suggested' ->> 'booking_number') || '/' || jsonb_array_length(test.ph('m1') -> 'candidates'), 'auto/PH-REAL-T/1');
insert into toll_tickets (id, kind, authority, plate, vehicle_id, occurred_at, amount_cents)
values (test.id('toll:ph1'), 'parking', 'City of Toronto', (select plate from vehicles where id = test.id('vehicle:ph_toll')), test.id('vehicle:ph_toll'),
        '2026-09-12 14:00 America/Toronto', 3000);
select app.run_toll_match(test.id('toll:ph1'));
select test.eq('ticket: matched to the real renter', (select matched_to || '/' || (select booking_number from bookings where id = t.booking_id) from toll_tickets t where t.id = test.id('toll:ph1')),
  'renter/PH-REAL-T');
select test.throws('ticket: the placeholder cannot be chosen by hand',
  format($$select app.apply_toll_match(%L, jsonb_build_object('kind', 'renter', 'booking_id', %L), %L, 'manual')$$, test.id('toll:ph1'),
         (select id from bookings where booking_number = 'PH-PLACE-T'), test.id('ph_admin')), null);
