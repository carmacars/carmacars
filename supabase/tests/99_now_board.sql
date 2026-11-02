-- 99: Bookings > Now (0330): out now, going out, coming back, money due and free cars in one read, with the payment plan
-- of each rental. docs/changes/2026-11-06-bookings-now.md. Fixtures start with "bn" and use example.test only.
-- The board is read at noon Toronto time today (app.fleet_board takes the time), so "today" and "tomorrow" never depend
-- on when the suite runs. It runs after 99_live_map (its file name sorts later): the Live map's suite counts every pin.
select test.suite('99 bookings now');
-- earlier suites switch the automatic field jobs on; the deposit is placed the morning of the pickup day (0261's default)
update program_settings set field_jobs_auto = false, deposit_timing = 'pickup_day' where id = (app.settings()).id;

select test.mk_user('bn_admin', 'admin');
select test.mk_user('bn_fleet', 'va', 'fleet');
select test.mk_user('bn_cs', 'va', 'cs');
select test.mk_user('bn_sales', 'va', 'sales');
select test.mk_user('bn_field', 'field');
select test.mk_owner('bn_olive');
select test.mk_vehicle('bn_week', 'bn_olive');
select test.mk_vehicle('bn_biwk', 'bn_olive');
select test.mk_vehicle('bn_late', 'bn_olive');
select test.mk_vehicle('bn_ins', 'bn_olive');
select test.mk_vehicle('bn_place', 'bn_olive');
select test.mk_vehicle('bn_back', 'bn_olive');
select test.mk_vehicle('bn_long', 'bn_olive');
select test.mk_vehicle('bn_go', 'bn_olive');
select test.mk_vehicle('bn_free', 'bn_olive');
select test.mk_vehicle('bn_shop', 'bn_olive');
select test.mk_vehicle('bn_unrec', 'bn_olive');
select test.mk_vehicle('bn_stale', 'bn_olive');
select test.mk_renter('bn_rita');
select test.mk_renter('bn_ivan');
insert into insurers (id, name, billing_email) values (test.id('insurer:bn'), 'Example Insurance', 'claims@example.test');

create or replace function test.bn_now() returns timestamptz language sql stable as $$
  select (((now() at time zone 'America/Toronto')::date + time '12:00') at time zone 'America/Toronto')
$$;
create or replace function test.bnt(p interval) returns text language sql stable as $$
  select to_char((test.bn_now() + p) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI')
$$;
-- a rental with a known total and a known amount paid
create or replace function test.bn_set(p_number text, p_total bigint, p_paid bigint, p_every text default null) returns void language sql as $$
  update bookings set total_due_at_booking_cents = p_total, pay_every = p_every where id = test.id('booking:' || p_number);
  update payments set amount_cents = greatest(p_paid, 1), status = case when p_paid > 0 then 'succeeded' else 'failed' end
   where id = test.id('payment:' || p_number);
$$;
create temp table bn as select null::text as k, null::jsonb as v limit 0;
create or replace function test.bn(p_k text) returns jsonb language sql stable as $$ select v from pg_temp.bn where k = p_k $$;
-- one booking's card in a section of the board
create or replace function test.bnc(p_section text, p_number text) returns jsonb language sql stable as $$
  select x from jsonb_array_elements(test.bn('board') -> p_section) x where x ->> 'number' = p_number
$$;

-- ================================================================ the rentals
-- weekly: 28 days picked up 10 days ago, two weeks paid; the third week is due in 4 days
select test.mk_booking('BN-WEEK', 'bn_week', 'bn_rita', test.bnt(interval '-10 days'), test.bnt(interval '18 days'), 'on_rent');
select test.bn_set('BN-WEEK', 280000, 140000, 'weekly');
-- biweekly: 28 days picked up 12 days ago, the first two weeks paid; the second instalment is due in 2 days
select test.mk_booking('BN-BIWK', 'bn_biwk', 'bn_rita', test.bnt(interval '-12 days'), test.bnt(interval '16 days'), 'on_rent');
select test.bn_set('BN-BIWK', 280000, 140000, 'biweekly');
-- an overdue return, paid in full
select test.mk_booking('BN-LATE', 'bn_late', 'bn_ivan', test.bnt(interval '-5 days'), test.bnt(interval '-3 hours'), 'on_rent');
select test.bn_set('BN-LATE', 60000, 60000);
-- insurer-billed: nothing for the renter
select test.mk_booking('BN-INS', 'bn_ins', 'bn_ivan', test.bnt(interval '-3 days'), test.bnt(interval '1 day 2 hours'), 'on_rent');
select test.bn_set('BN-INS', 50000, 0);
update bookings set bill_to = 'insurer', insurer_id = test.id('insurer:bn'), insurer_claim_number = 'CLM-BN-1', insurer_share_cents = 44248, insurer_hst_cents = 5752
 where id = test.id('booking:BN-INS');
-- a placeholder over tomorrow, never on the board
select test.mk_booking('BN-PLACE', 'bn_place', 'bn_ivan', test.bnt(interval '1 day'), test.bnt(interval '4 days'), 'confirmed');
select test.bn_set('BN-PLACE', 30000, 0);
update bookings set is_placeholder = true, placeholder_reason = 'Insurer hold', blocks_calendar = false,
       blocks_calendar_changed_by = test.id('bn_admin'), blocks_calendar_reason = 'Placeholder' where id = test.id('booking:BN-PLACE');
-- backdated: entered as already under way, picked up 20 days ago, weekly, only the first week paid
select test.mk_booking('BN-BACK', 'bn_back', 'bn_rita', test.bnt(interval '-20 days'), test.bnt(interval '8 days'), 'on_rent');
select test.bn_set('BN-BACK', 280000, 70000, 'weekly');
update bookings set added_mode = 'in_progress', added_by_staff = true where id = test.id('booking:BN-BACK');
-- a long rental: 90 days in three monthly periods, two paid; the third starts in 20 days
select test.mk_booking('BN-LONG', 'bn_long', 'bn_ivan', test.bnt(interval '-40 days'), test.bnt(interval '50 days'), 'on_rent');
select test.bn_set('BN-LONG', 540000, 360000);
select app.booking_periods_sync(test.id('booking:BN-LONG'));
-- going out tomorrow afternoon by delivery, paid, the licence and the agreement not done yet
select test.mk_booking('BN-GO', 'bn_go', 'bn_rita', test.bnt(interval '1 day 3 hours'), test.bnt(interval '5 days'), 'confirmed');
select test.bn_set('BN-GO', 50000, 50000);
update bookings set pickup_location_kind = 'delivery', pickup_place = '1 Example Street, Toronto' where id = test.id('booking:BN-GO');
-- confirmed, picked up 2 hours before the board's noon, no check-out recorded: out, "pickup not recorded"
select test.mk_booking('BN-UNREC', 'bn_unrec', 'bn_ivan', test.bnt(interval '-2 hours'), test.bnt(interval '3 days'), 'confirmed');
select test.bn_set('BN-UNREC', 40000, 40000);
-- ended, never closed: confirmed for 6 to 4 days ago, no check-out, and the same car went out again 3 days ago
select test.mk_booking('BN-STALE', 'bn_stale', 'bn_rita', test.bnt(interval '-6 days'), test.bnt(interval '-4 days'), 'confirmed');
select test.bn_set('BN-STALE', 20000, 20000);
select test.mk_booking('BN-AGAIN', 'bn_stale', 'bn_ivan', test.bnt(interval '-3 days'), test.bnt(interval '2 days'), 'on_rent');
select test.bn_set('BN-AGAIN', 50000, 50000);
update bookings set bill_to = 'split', insurer_id = test.id('insurer:bn'), insurer_share_cents = 20000, insurer_hst_cents = 2600 where id = test.id('booking:BN-AGAIN');
-- a car in the shop
update vehicles set status = 'out_of_service' where id = test.id('vehicle:bn_shop');

insert into bn select 'board', app.fleet_board(test.bn_now());

-- ================================================================ out now and the plans
select test.ok('out now: every rental on rent, not the placeholder or the confirmed one',
  test.bnc('out', 'BN-WEEK') is not null and test.bnc('out', 'BN-LATE') is not null and test.bnc('out', 'BN-INS') is not null
  and test.bnc('out', 'BN-BACK') is not null and test.bnc('out', 'BN-LONG') is not null
  and test.bnc('out', 'BN-PLACE') is null and test.bnc('out', 'BN-GO') is null);
select test.eq('out now: the car and the renter',
  (select (x #>> '{car,code}' is not distinct from (select car_code from vehicles where id = test.id('vehicle:bn_week'))) || '/' || (x #>> '{car,plate}') || '/' || (x #>> '{renter,name}') || '/' || (x #>> '{renter,phone}')
     from test.bnc('out', 'BN-WEEK') x),
  'true/' || (select plate from vehicles where id = test.id('vehicle:bn_week')) || '/Bn Rita/647-555-0199');
select test.eq('weekly: four instalments of $700, the third due in 4 days for $700, upcoming',
  (select (x #>> '{pay,plan}') || '/' || (x #>> '{pay,count}') || '/' || (x #>> '{pay,per_cents}') || '/' || (x #>> '{pay,next,seq}') || '/' || (x #>> '{pay,next,cents}') || '/' || (x #>> '{pay,state}')
     from test.bnc('out', 'BN-WEEK') x), 'weekly/4/70000/3/70000/upcoming');
select test.eq('weekly: the next payment is 14 days after the pickup',
  (select (x #>> '{pay,next,due_at}')::timestamptz from test.bnc('out', 'BN-WEEK') x), (select pickup_at + interval '14 days' from bookings where id = test.id('booking:BN-WEEK')));
select test.eq('biweekly: two instalments of $1,400, the second due in 2 days, soon',
  (select (x #>> '{pay,plan}') || '/' || (x #>> '{pay,count}') || '/' || (x #>> '{pay,next,seq}') || '/' || (x #>> '{pay,next,cents}') || '/' || (x #>> '{pay,state}')
     from test.bnc('out', 'BN-BIWK') x), 'biweekly/2/2/140000/soon');
select test.eq('biweekly: the next payment is 14 days after the pickup',
  (select (x #>> '{pay,next,due_at}')::timestamptz from test.bnc('out', 'BN-BIWK') x), (select pickup_at + interval '14 days' from bookings where id = test.id('booking:BN-BIWK')));
select test.eq('overdue return: red with the minutes late, paid in full',
  (select (x ->> 'due') || '/' || (x ->> 'minutes_late') || '/' || (x #>> '{pay,plan}') || '/' || (x #>> '{pay,state}') from test.bnc('out', 'BN-LATE') x), 'overdue/180/whole/paid');
select test.eq('insurer-billed: the plan is the insurer, nothing for the renter, the insurer named with its share',
  (select (x #>> '{pay,plan}') || '/' || (x #>> '{pay,state}') || '/' || (x #>> '{pay,owed_cents}') || '/' || (x #>> '{pay,insurer,name}') || '/' || (x #>> '{pay,insurer,share_cents}') || '/' || (x #>> '{pay,insurer,claim}')
     from test.bnc('out', 'BN-INS') x), 'insurer/none/0/Example Insurance/50000/CLM-BN-1');
select test.eq('backdated: two weekly instalments behind, $1,400 overdue, marked backdated',
  (select (x #>> '{pay,state}') || '/' || (x #>> '{pay,overdue_count}') || '/' || (x #>> '{pay,next,seq}') || '/' || (x #>> '{pay,next,cents}') || '/' || (x ->> 'backdated')
     from test.bnc('out', 'BN-BACK') x), 'overdue/2/2/140000/true');
select test.eq('long rental: monthly from its periods without being set, the third of $1,800 in 20 days',
  (select (x #>> '{pay,plan}') || '/' || (x #>> '{pay,set}') || '/' || (x #>> '{pay,count}') || '/' || (x #>> '{pay,next,seq}') || '/' || (x #>> '{pay,next,cents}') || '/' || (x #>> '{pay,state}')
     from test.bnc('out', 'BN-LONG') x), 'monthly/false/3/3/180000/upcoming');
select test.eq('long rental: the next payment is when the third period starts',
  (select (x #>> '{pay,next,due_at}')::timestamptz from test.bnc('out', 'BN-LONG') x),
  (select starts_at from booking_periods where booking_id = test.id('booking:BN-LONG') and seq = 3));

select test.ok('out now: a confirmed booking past its pickup time with no check-out counts as out, marked unrecorded',
  (select (x ->> 'unrecorded')::boolean and x ->> 'status' = 'confirmed' from test.bnc('out', 'BN-UNREC') x)
  and test.bnc('going', 'BN-UNREC') is null
  and (select (x ->> 'unrecorded')::boolean = false from test.bnc('out', 'BN-WEEK') x));
select test.ok('out now: overdue returns first',
  (select bool_and(n < (select min(n2) from jsonb_array_elements(test.bn('board') -> 'out') with ordinality t2(x2, n2) where x2 ->> 'due' <> 'overdue'))
     from jsonb_array_elements(test.bn('board') -> 'out') with ordinality t(x, n) where x ->> 'due' = 'overdue'));
select test.ok('free cars: the car out without a recorded pickup is not free',
  not exists (select 1 from jsonb_array_elements(test.bn('board') -> 'cars') x where x ->> 'id' = test.id('vehicle:bn_unrec')::text));
select test.ok('summary: the unrecorded pickups are counted', ((test.bn('board') -> 'summary') ->> 'unrecorded')::int >= 1);

select test.ok('ended, never closed: listed apart, not out, not overdue',
  test.bnc('stale', 'BN-STALE') is not null and test.bnc('out', 'BN-STALE') is null and test.bnc('back', 'BN-STALE') is null
  and test.bnc('out', 'BN-AGAIN') is not null and ((test.bn('board') -> 'summary') ->> 'stale')::int >= 1);
select test.eq('bill to: each rental says who is billed', (select (select x ->> 'bill_to' from test.bnc('out', 'BN-AGAIN') x) || '/' || (select x ->> 'bill_to' from test.bnc('out', 'BN-INS') x) || '/' || (select x ->> 'bill_to' from test.bnc('out', 'BN-WEEK') x)),
  'split/insurer/renter');

-- ================================================================ coming back, going out, money, free cars
select test.ok('coming back: the overdue one and tomorrow''s, not next week''s',
  test.bnc('back', 'BN-LATE') is not null and test.bnc('back', 'BN-INS') is not null and test.bnc('back', 'BN-WEEK') is null);
select test.eq('coming back: tomorrow''s is marked tomorrow', (select x ->> 'due' from test.bnc('back', 'BN-INS') x), 'tomorrow');
select test.ok('going out: the confirmed pickup tomorrow, not the placeholder', test.bnc('going', 'BN-GO') is not null and test.bnc('going', 'BN-PLACE') is null);
select test.eq('going out: delivery, and the readiness ticks (deposit scheduled for the pickup morning)',
  (select (x ->> 'pickup_kind') || '/' || (x #>> '{ready,licence}') || '/' || (x #>> '{ready,agreement}') || '/' || (x #>> '{ready,paid}') || '/' || (x #>> '{ready,deposit}') || '/' || (x #>> '{ready,photos}')
     from test.bnc('going', 'BN-GO') x), 'delivery/false/false/true/scheduled/false');
select test.ok('money due: the biweekly (soon), the weekly (in 4 days) and the backdated (overdue); not the long rental, the insurer or the paid ones',
  test.bnc('money', 'BN-BIWK') is not null and test.bnc('money', 'BN-WEEK') is not null and test.bnc('money', 'BN-BACK') is not null
  and test.bnc('money', 'BN-LONG') is null and test.bnc('money', 'BN-INS') is null and test.bnc('money', 'BN-LATE') is null and test.bnc('money', 'BN-GO') is null);
select test.ok('money due: the overdue one first', (select (x ->> 'number') = 'BN-BACK' from jsonb_array_elements(test.bn('board') -> 'money') with ordinality t(x, n)
   where x ->> 'number' like 'BN-%' order by n limit 1));
select test.ok('free cars: the idle car is free, the car in the shop is in maintenance, the cars out and booked are not listed',
  exists (select 1 from jsonb_array_elements(test.bn('board') -> 'cars') x where x ->> 'id' = test.id('vehicle:bn_free')::text and x ->> 'state' = 'free')
  and exists (select 1 from jsonb_array_elements(test.bn('board') -> 'cars') x where x ->> 'id' = test.id('vehicle:bn_shop')::text and x ->> 'state' = 'maintenance' and x ->> 'why' = 'out_of_service')
  and not exists (select 1 from jsonb_array_elements(test.bn('board') -> 'cars') x where x ->> 'id' in (test.id('vehicle:bn_week')::text, test.id('vehicle:bn_late')::text)));
select test.ok('free cars: the placeholder''s car is free, with the placeholder not shown as its next booking',
  exists (select 1 from jsonb_array_elements(test.bn('board') -> 'cars') x where x ->> 'id' = test.id('vehicle:bn_place')::text and x ->> 'state' = 'free' and x -> 'next' = 'null'::jsonb));
select test.ok('free cars: the car going out tomorrow is free now with its next pickup',
  exists (select 1 from jsonb_array_elements(test.bn('board') -> 'cars') x where x ->> 'id' = test.id('vehicle:bn_go')::text and x #>> '{next,number}' = 'BN-GO'));
select test.ok('summary: the counts match the lists',
  (select (s ->> 'out')::int = jsonb_array_length(test.bn('board') -> 'out') and (s ->> 'going')::int = jsonb_array_length(test.bn('board') -> 'going')
      and (s ->> 'overdue')::int >= 1 and (s ->> 'money_cents')::bigint >= 70000 + 140000 + 140000
     from (select test.bn('board') -> 'summary' as s) z));

-- ================================================================ who reads it
insert into bn select 'cs', app.door(test.id('bn_cs'), 'aal2', 'ops_read', 'bookings_now', '{"_va": "cs"}');
select test.ok('customer service: the whole board with the money', test.bn('cs') ->> 'scope' = 'full' and test.bn('cs') ? 'money');
select test.ok('fleet: the whole board', app.door(test.id('bn_fleet'), 'aal2', 'ops_read', 'bookings_now', '{"_va": "fleet"}') ->> 'scope' = 'full');
select test.ok('Admin: the whole board', app.door(test.id('bn_admin'), 'aal2', 'ops_read', 'bookings_now', '{}') ->> 'scope' = 'full');
select test.throws('sales: not on the board', format($$select app.door(%L, 'aal2', 'ops_read', 'bookings_now', '{"_va": "sales"}')$$, test.id('bn_sales')), 'only');
insert into field_jobs (kind, booking_id, vehicle_id, assigned_to, scheduled_at, status)
values ('handover', test.id('booking:BN-GO'), test.id('vehicle:bn_go'), test.id('bn_field'), (select pickup_at from bookings where id = test.id('booking:BN-GO')), 'scheduled');
insert into bn select 'field', app.door(test.id('bn_field'), 'aal2', 'field_read', 'bookings_now', '{}');
select test.ok('field staff: the cars, no money and no plans',
  test.bn('field') ->> 'scope' = 'field' and not test.bn('field') ? 'money' and not (test.bn('field') -> 'summary') ? 'money_cents'
  and not exists (select 1 from jsonb_array_elements(test.bn('field') -> 'out') x where x ? 'pay' or x ? 'deposit'));
select test.ok('field staff: the renter''s phone only on their own job',
  (select x #>> '{renter,phone}' from jsonb_array_elements(test.bn('field') -> 'going') x where x ->> 'number' = 'BN-GO') = '647-555-0199'
  and (select not (x -> 'renter') ? 'phone' from jsonb_array_elements(test.bn('field') -> 'out') x where x ->> 'number' = 'BN-WEEK'));

-- ================================================================ setting the plan
select test.throws('the plan: not fleet', format($$select app.door(%L, 'aal2', 'ops_do', 'booking_pay_every', '{"_va": "fleet", "booking": "%s", "pay_every": "weekly"}')$$,
  test.id('bn_fleet'), test.id('booking:BN-BIWK')), 'only');
select test.throws('the plan: only the four choices', format($$select app.door(%L, 'aal2', 'ops_do', 'booking_pay_every', '{"_va": "cs", "booking": "%s", "pay_every": "daily"}')$$,
  test.id('bn_cs'), test.id('booking:BN-BIWK')), 'Choose');
insert into bn select 'set', app.door(test.id('bn_cs'), 'aal2', 'ops_do', 'booking_pay_every',
  jsonb_build_object('_va', 'cs', 'booking', test.id('booking:BN-BIWK'), 'pay_every', 'weekly'));
select test.eq('the plan: customer service moves the biweekly rental to weekly', test.bn('set') #>> '{pay,plan}', 'weekly');
select test.ok('the plan: the change is in the booking history',
  exists (select 1 from booking_events e where e.booking_id = test.id('booking:BN-BIWK') and e.kind = 'adjusted' and e.details #>> '{pay_every,after}' = 'weekly'));
insert into bn select 'auto', app.door(test.id('bn_admin'), 'aal2', 'admin_do', 'booking_pay_every',
  jsonb_build_object('booking', test.id('booking:BN-LONG'), 'pay_every', 'auto'));
select test.eq('the plan: automatic keeps a long rental monthly', test.bn('auto') #>> '{pay,plan}', 'monthly');
select test.eq('the booking page: the plan by the booking number, finance may change it',
  (select (x ->> 'plan') || '/' || (x ->> 'count') || '/' || (x ->> 'may_change')
     from (select app.door(test.id('bn_admin'), 'aal2', 'ops_read', 'booking_pay_plan', '{"booking": "BN-WEEK"}') x) z), 'weekly/4/true');
select test.eq('the booking page: fleet reads the plan and may not change it',
  app.door(test.id('bn_fleet'), 'aal2', 'ops_read', 'booking_pay_plan', '{"booking": "BN-WEEK", "_va": "fleet"}') ->> 'may_change', 'false');

-- ================================================================ Mark picked up: the record-now path of 0195 at the booked pickup time
select test.throws('mark picked up: the deposit guard holds (not taken, no Admin waiver)',
  format($$select app.door(%L, 'aal2', 'ops_do', 'handover_record_now', '{"_va": "fleet", "booking": "BN-UNREC", "kind": "pickup", "reason": "Marked picked up from Bookings > Now"}')$$,
    test.id('bn_fleet')), 'deposit');
-- the renter's identity is verified (the database still refuses a release without it, as it should)
insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, age_at_pickup, age_band, identity_method, identity_verified_on)
values (test.id('booking:BN-UNREC'), test.id('driver:bn_ivan'), 'renter', 'Bn Ivan', date '1990-05-05', 36, '26_plus', 'staff_review', current_date);
insert into coverage_proofs (booking_id, coverage_option, status, card_issuer, card_last4, confirmed_at)
values (test.id('booking:BN-UNREC'), 2, 'confirmed', 'Bank', '4242', now());
update bookings set coverage_option = 2, coverage_confirmed_at = now() where id = test.id('booking:BN-UNREC');
insert into bn select 'mark', app.door(test.id('bn_admin'), 'aal2', 'ops_do', 'handover_record_now', jsonb_build_object(
  'booking', 'BN-UNREC', 'kind', 'pickup', 'at', (select pickup_at from bookings where id = test.id('booking:BN-UNREC')),
  'reason', 'Marked picked up from Bookings > Now', 'deposit_waiver_reason', 'Cash deposit taken at the counter',
  'signature_override_reason', 'Signed on paper at the counter'));
select test.eq('mark picked up: on rent, handed over at the booked pickup time',
  (select status::text || '/' || (handed_over_at = pickup_at) from bookings where id = test.id('booking:BN-UNREC')), 'on_rent/true');
select test.ok('mark picked up: Fleet has the task to add the photos and readings',
  exists (select 1 from tasks t where t.booking_id = test.id('booking:BN-UNREC') and t.task_type = 'handover_details' and t.status = 'open'));
select test.ok('mark picked up: still out, no longer marked unrecorded',
  (select not (x ->> 'unrecorded')::boolean and x ->> 'status' = 'on_rent' from jsonb_array_elements(app.fleet_board(test.bn_now()) -> 'out') x where x ->> 'number' = 'BN-UNREC'));

-- ================================================================ Close: an ended booking recorded through the same path
select test.throws('close: only a booking that ended without a check-out', format($$select app.door(%L, 'aal2', 'ops_do', 'booking_close_ended', '{"booking": "BN-GO"}')$$, test.id('bn_admin')), 'has not ended');
insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, age_at_pickup, age_band, identity_method, identity_verified_on)
values (test.id('booking:BN-STALE'), test.id('driver:bn_rita'), 'renter', 'Bn Rita', date '1990-05-05', 36, '26_plus', 'staff_review', current_date);
insert into coverage_proofs (booking_id, coverage_option, status, card_issuer, card_last4, confirmed_at)
values (test.id('booking:BN-STALE'), 2, 'confirmed', 'Bank', '4242', now());
update bookings set coverage_option = 2, coverage_confirmed_at = now() where id = test.id('booking:BN-STALE');
insert into bn select 'close', app.door(test.id('bn_admin'), 'aal2', 'ops_do', 'booking_close_ended', jsonb_build_object('booking', 'BN-STALE',
  'deposit_waiver_reason', 'Deposit settled outside the platform', 'signature_override_reason', 'Signed on paper at the counter'));
select test.eq('close: the pickup and the return recorded at the booked times',
  (select status::text || '/' || (handed_over_at = pickup_at) || '/' || (checked_in_at = return_at) from bookings where id = test.id('booking:BN-STALE')), 'returned/true/true');
select test.ok('close: no longer on the board', not exists (select 1 from jsonb_array_elements(app.fleet_board(test.bn_now()) -> 'stale') x where x ->> 'number' = 'BN-STALE'));

-- ================================================================ 0332: the rows of Requests and offers, All bookings and the Calendar
insert into bn select 'cards', app.door(test.id('bn_cs'), 'aal2', 'ops_read', 'booking_cards',
  jsonb_build_object('_va', 'cs', 'ids', jsonb_build_array(test.id('booking:BN-WEEK'), test.id('booking:BN-INS'), 'not-a-uuid')));
select test.eq('booking cards: the car, the mobile, the licence and the money of each row',
  (select (x #>> '{car,code}' is not null) || '/' || (x ->> 'phone') || '/' || (x ->> 'licence') || '/' || (x #>> '{money,state}') || '/' || (x ->> 'bill_to')
     from (select test.bn('cards') -> test.id('booking:BN-WEEK')::text x) z), 'true/647-555-0199/verified/upcoming/renter');
select test.eq('booking cards: an insurer-billed rental says so', test.bn('cards') #>> array[test.id('booking:BN-INS')::text, 'money', 'state'], 'none');
select test.throws('booking cards: not for field staff', format($$select app.door(%L, 'aal2', 'ops_read', 'booking_cards', '{"ids": []}')$$, test.id('bn_field')), 'office staff');
select test.ok('car thumbs: field staff read the calendar''s car rows',
  app.door(test.id('bn_field'), 'aal2', 'ops_read', 'car_thumbs', jsonb_build_object('ids', jsonb_build_array(test.id('vehicle:bn_week')))) ? test.id('vehicle:bn_week')::text);
-- my bookings: a staff member's own (here: added by them)
update bookings set created_by = test.id('bn_sales') where id = test.id('booking:BN-WEEK');
insert into bn select 'mine', app.door(test.id('bn_sales'), 'aal2', 'ops_read', 'my_bookings', '{"_va": "sales"}');
select test.ok('my bookings: Sales see the bookings they added, with how',
  exists (select 1 from jsonb_array_elements(test.bn('mine')) x where x ->> 'booking_number' = 'BN-WEEK' and x ->> 'how' = 'added')
  and not exists (select 1 from jsonb_array_elements(test.bn('mine')) x where x ->> 'booking_number' = 'BN-LATE'));
select test.throws('my bookings: office staff only', format($$select app.door(%L, 'aal2', 'ops_read', 'my_bookings', '{}')$$, test.id('bn_field')), 'Office staff');
-- an offer still out when its pickup time passes expires by itself
select test.mk_vehicle('bn_offer', 'bn_olive');
select test.mk_booking('BN-OFFER', 'bn_offer', 'bn_ivan', test.bnt(interval '-30 hours'), test.bnt(interval '3 days'), 'offered');
update bookings set offer_expires_at = now() + interval '1 day' where id = test.id('booking:BN-OFFER');
select app.expire_offers(now());
select test.eq('offers: one still out past its pickup time expires', (select status::text from bookings where id = test.id('booking:BN-OFFER')), 'expired');
select test.ok('offers: the expiry time is on its row for the quiet Expired filter',
  (app.booking_cards(test.id('bn_admin'), jsonb_build_object('ids', jsonb_build_array(test.id('booking:BN-OFFER')))) #>> array[test.id('booking:BN-OFFER')::text, 'expired_at']) is not null);
