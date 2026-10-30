-- 36: the owner's decisions of October 18, 2026 (migration 0057): the first reply target (5 minutes, one Program setting),
-- staff agreement defaults by function, and sales tracking (who a booking is credited to, My sales, the team's month, an
-- Admin's reassignment, booked revenue). Fixtures start with "st".
select test.suite('36 sales tracking');

select test.mk_user('st_admin', 'admin');
select test.mk_user('st_sales', 'va', 'sales');
select test.mk_user('st_cs', 'va', 'cs');
select test.mk_user('st_fin', 'va', 'finance');
select test.mk_user('st_fleet', 'va', 'fleet');
select test.mk_user('st_field', 'field');
select test.mk_renter('st_rita');
select test.mk_renter('st_ron');
-- Sales records a payment received at the counter within its own limit
update staff_profiles set single_limit_cents = 100000 where user_id = test.id('st_sales');

create temp table s36 as select null::text as k, null::jsonb as v limit 0;
create or replace function test.s36(p_k text) returns jsonb language sql stable as $$ select v from pg_temp.s36 where k = p_k $$;
create or replace function test.s36b(p_k text) returns bookings language sql stable as $$
  select * from bookings where id = coalesce((test.s36(p_k) ->> 'booking_id')::uuid, (test.s36(p_k) ->> 'id')::uuid) $$;

-- a CarmaCars-owned car with rates (an assistant's list shows only cars with rates)
insert into s36 select 'car', app.vehicle_add(test.id('st_admin'), '{"supply_type": "company", "vin": "1STSALES000000001", "plate": "STSA001",
  "year": 2024, "make": "Toyota", "model": "Camry", "rates": {"daily": 10000, "weekend": 12000, "weekly": 56000, "monthly": 180000, "deposit": 30000}}');
create or replace function test.s36v() returns uuid language sql stable as $$ select (test.s36('car') ->> 'vehicle_id')::uuid $$;

-- ================================================================ 1. the first reply target
select test.eq('target: 5 minutes by default (the owner''s decision)', (app.settings()).request_response_target_minutes, 5);
select test.eq('target: in words for staff', app.minutes_words(app.first_reply_minutes()), '5 minutes');
select test.eq('words: one minute, hours', app.minutes_words(1) || ' / ' || app.minutes_words(60) || ' / ' || app.minutes_words(120) || ' / ' || app.minutes_words(90),
  '1 minute / 1 hour / 2 hours / 90 minutes');
select test.eq('task rules: booking requests, enquiries, offer changes and renter messages take the target',
  (select string_agg(task_type, ',' order by task_type) from task_rules where due_kind = 'first_reply'), 'booking_request,enquiry,offer_change_requested,renter_message');
select test.eq('task rules: a re-offer keeps its own 30 minutes', (select due_kind || ' ' || due_amount from task_rules where task_type = 'reoffer_booking'), 'opening_minutes 30');
select test.eq('customer promise unchanged: renters are told "within 2 hours"', (select reply_wording from site_settings), 'within 2 hours');
select test.eq('the late-request staff alert unchanged (2 hours)', (app.settings()).notify_request_waiting_minutes, 120);

-- a website request raises its task due 5 opening minutes after it came in (the business is always open)
insert into s36 select 'web1', jsonb_build_object('id', app.request_booking(test.id('renter:st_rita'), test.s36v(), date_trunc('hour', now()) + interval '6 days',
  date_trunc('hour', now()) + interval '9 days', 'standard', null, 'web', test.id('st_rita')));
select test.ok('task due: 5 minutes after the request, the countdown 5',
  (select t.due_at = app.add_opening_minutes(t.created_at, 5) and t.sla_minutes = 5 from tasks t where t.booking_id = (test.s36b('web1')).id and t.task_type = 'booking_request'));
-- an enquiry from the contact form
select test.lives('enquiry: raised', $$select app.raise_task('enquiry', p_detail => 'St asks about long-term rentals', p_dedupe => 'st:enquiry')$$);
select test.ok('enquiry: due in 5 minutes (it was 1 business day)',
  (select t.due_at = app.add_opening_minutes(t.created_at, 5) from tasks t where t.dedupe_key = 'st:enquiry'));

-- an Admin changes the target: a new dated row from today; new tasks follow it
select app.admin_save(test.id('st_admin'), 'program_settings', '{"key": "current", "values": {"request_response_target_minutes": 10}}');
select test.eq('setting: an Admin may change it (a new dated row)', app.first_reply_minutes(), 10);
select test.lives('a renter message after the change', $$select app.raise_task('renter_message', p_title => 'St replied', p_dedupe => 'st:msg')$$);
select test.ok('renter message: due 10 minutes later, the countdown 10',
  (select t.due_at = app.add_opening_minutes(t.created_at, 10) and t.sla_minutes = 10 from tasks t where t.dedupe_key = 'st:msg'));
select test.throws('setting: at least 1 minute', $$select app.admin_save(test.id('st_admin'), 'program_settings', '{"key": "current", "values": {"request_response_target_minutes": 0}}')$$, 'check');
select app.admin_save(test.id('st_admin'), 'program_settings', '{"key": "current", "values": {"request_response_target_minutes": 5}}');

-- the scorecard reads the target
select test.eq('scorecard, customer service: first reply in 5 minutes',
  (select m ->> 'target' from jsonb_array_elements(app.staff_scorecard(test.id('st_cs'), 1) #> '{weeks,0,measures}') m where m ->> 'name' = 'First reply in opening hours'), '5 minutes');
select test.eq('scorecard, Sales: quote sent in 5 minutes; owner leads their own measure',
  (select string_agg((m ->> 'name') || ': ' || (m ->> 'target'), '; ') from jsonb_array_elements(app.staff_scorecard(test.id('st_sales'), 1) #> '{weeks,0,measures}') m),
  'Quote sent: 5 minutes; Tentative holds followed up: Before the expiry; Owner leads answered: 1 business day');
select test.eq('staff screens: the target through the door', app.door(test.id('st_cs'), 'aal2', 'ops_read', 'reply_target', '{}') ->> 'words', '5 minutes');
select test.throws('staff screens: not for a renter', $$select app.door(test.id('st_rita'), '', 'ops_read', 'reply_target', '{}')$$, 'Not permitted');

-- ================================================================ 2. staff agreement defaults by function
create or replace function test.s36d(p_user text) returns jsonb language sql stable as $$
  select app.staff_agreement_prepare(test.id('st_admin'), test.id(p_user)) -> 'defaults' $$;
select test.eq('customer service: US$350 a month, full time, 6 days, 10 hours a day',
  (select d ->> 'pay_basis' || ' ' || (d ->> 'rate') || ' ' || (d ->> 'currency') || ' ' || (d ->> 'schedule') || ' ' || (d ->> 'days_per_week') || ' ' || (d ->> 'hours_per_day') from test.s36d('st_cs') d),
  'monthly 350.00 USD full_time 6 10');
select test.eq('fleet: US$400 a month, full time, 6 days, 10 hours a day',
  (select d ->> 'pay_basis' || ' ' || (d ->> 'rate') || ' ' || (d ->> 'schedule') || ' ' || (d ->> 'days_per_week') || ' ' || (d ->> 'hours_per_day') from test.s36d('st_fleet') d),
  'monthly 400.00 full_time 6 10');
select test.eq('finance: US$200 a month, part time, 3 days, 9 hours a day',
  (select d ->> 'pay_basis' || ' ' || (d ->> 'rate') || ' ' || (d ->> 'schedule') || ' ' || (d ->> 'days_per_week') || ' ' || (d ->> 'hours_per_day') from test.s36d('st_fin') d),
  'monthly 200.00 part_time 3 9');
-- 0197: in person (the default for Sales) the in-person staff agreement and its defaults; remote, the VA agreement's
select test.eq('sales in person: the in-person agreement, with its defaults (0197)',
  (select (r #>> '{staff,agreement}') || ' ' || (r #>> '{defaults,wage}') from app.staff_agreement_prepare(test.id('st_admin'), test.id('st_sales')) r), 'in_person 18.00');
update staff_profiles set sales_work_mode = 'remote' where user_id = test.id('st_sales');
select test.eq('sales: no rate, commission only (0059)', (select coalesce(d ->> 'rate', 'x') || '|' || coalesce(d ->> 'pay_basis', 'x') from test.s36d('st_sales') d), '|commission');
select test.ok('assistants: the common values with the function''s (country, platform, trial)',
  (select d ->> 'country' = 'Philippines' and d ->> 'platform' = 'OnlineJobs.ph' and d ->> 'trial_days' = '30' and not d ? 'by_function' from test.s36d('st_sales') d));
select test.eq('field staff: CA$18.00 an hour, paid every two weeks',
  (select d ->> 'wage' || ' ' || (d ->> 'currency') || ' ' || (d ->> 'pay_dates') from test.s36d('st_field') d), '18.00 CAD every two weeks');
select test.throws('defaults: an Admin prepares agreements', $$select app.staff_agreement_prepare(test.id('st_cs'), test.id('st_sales'))$$, 'admin');

-- ================================================================ 3. who a booking is credited to
-- a quote Sales takes on the phone: credited to Sales from the start
insert into s36 select 'q1', app.staff_quote_request(test.id('st_sales'), jsonb_build_object('vehicle_id', test.s36v(), 'source', 'phone',
  'pickup_at', date_trunc('hour', now()) + interval '20 days', 'return_at', date_trunc('hour', now()) + interval '23 days',
  'full_name', 'Quinn Caller', 'email', 'quinn.st@example.test', 'mobile', '4165550111', 'date_of_birth', '1985-03-04'));
select test.eq('quote: credited to the staff member who took it', (select sales_staff_id::text || ' ' || sales_source || ' ' || (sales_attributed_by = test.id('st_sales'))
  from test.s36b('q1')), test.id('st_sales')::text || ' quote true');
-- customer service sends the offer on Sales' quote: the credit stays with Sales
select app.send_offer((test.s36b('q1')).id, test.id('st_cs'));
select test.eq('quote: an offer by someone else does not move the credit', (test.s36b('q1')).sales_staff_id, test.id('st_sales'));

-- a website request nobody is credited with: the first offer's sender gets it, a later offer does not change it
select test.ok('website request: nobody credited until an offer goes', (test.s36b('web1')).sales_staff_id is null and (test.s36b('web1')).sales_source is null);
select app.send_offer((test.s36b('web1')).id, test.id('st_cs'));
select test.eq('website request: credited to who sent the first offer', (select sales_staff_id::text || ' ' || sales_source from test.s36b('web1')), test.id('st_cs')::text || ' offer');
select app.withdraw_offer((test.s36b('web1')).id, test.id('st_admin'), 'St edit');
select app.send_offer((test.s36b('web1')).id, test.id('st_sales'));
select test.eq('website request: a second offer by another does not change it', (test.s36b('web1')).sales_staff_id, test.id('st_cs'));

-- an Owner Booking or a request made on the website by a staff member for themselves is never credited
insert into s36 select 'web2', jsonb_build_object('id', app.request_booking(test.id('renter:st_ron'), test.s36v(), date_trunc('hour', now()) + interval '40 days',
  date_trunc('hour', now()) + interval '42 days', 'standard', null, 'web', test.id('st_sales')));
select test.ok('a website request typed by a staff member is not their quote', (test.s36b('web2')).sales_staff_id is null);

-- Sales adds a rental by hand within its limits (the rate-sheet price, a payment link): credited as a rental added
insert into s36 select 'm1', app.manual_rental_create(test.id('st_sales'), jsonb_build_object('vehicle_id', test.s36v(),
  'pickup_at', date_trunc('hour', now()) + interval '30 days', 'return_at', date_trunc('hour', now()) + interval '33 days',
  'source', 'phone', 'coverage_option', 1, 'renter_id', test.id('renter:st_ron'), 'payment', jsonb_build_object('mode', 'other_way', 'method', 'cash', 'note', 'Paid at the counter')));
select test.eq('rental added by Sales: confirmed at once, credited as a rental added',
  (select status || ' ' || added_by_staff || ' ' || sales_source || ' ' || (sales_staff_id = test.id('st_sales')) from test.s36b('m1')), 'confirmed true manual_rental true');
select test.throws('Sales: a price typed by hand needs its reason (0058)', format($$select app.manual_rental_create(%L, %L)$$, test.id('st_sales'), jsonb_build_object('vehicle_id', test.s36v(),
  'pickup_at', date_trunc('hour', now()) + interval '50 days', 'return_at', date_trunc('hour', now()) + interval '52 days', 'source', 'phone', 'coverage_option', 1,
  'renter_id', test.id('renter:st_ron'), 'rental_charge_cents', 100, 'payment', jsonb_build_object('mode', 'link'))), 'needs its reason');
select test.throws('Sales: never over a clash', format($$select app.manual_rental_create(%L, %L)$$, test.id('st_sales'), jsonb_build_object('vehicle_id', test.s36v(),
  'pickup_at', date_trunc('hour', now()) + interval '31 days', 'return_at', date_trunc('hour', now()) + interval '32 days', 'source', 'phone', 'coverage_option', 1,
  'renter_id', test.id('renter:st_rita'), 'payment', jsonb_build_object('mode', 'link'))), null);
select test.throws('Finance adds rentals too (0058), choosing at the door', format($$select app.door(%L, 'aal2', 'ops_do', 'manual_rental_create', %L)$$, test.id('st_fin'), jsonb_build_object('vehicle_id', test.s36v(),
  'pickup_at', date_trunc('hour', now()) + interval '60 days', 'return_at', date_trunc('hour', now()) + interval '62 days', 'source', 'phone',
  'renter_id', test.id('renter:st_ron'), 'payment', jsonb_build_object('mode', 'link'))), 'I sourced this client');

-- the credit is the server's: a browser session that is not an Admin cannot change it
do $$
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', test.id('st_cs'))::text, true);
  update bookings set sales_staff_id = test.id('st_cs') where id = (test.s36b('m1')).id;
exception when others then null;
end $$;
reset role;
select test.eq('credit: unchanged', (test.s36b('m1')).sales_staff_id, test.id('st_sales'));

-- ================================================================ 4. an Admin reassigns
select test.throws('reassign: an Admin only', format($$select app.sales_reassign(%L, %L)$$, test.id('st_sales'),
  jsonb_build_object('booking', (test.s36b('web1')).booking_number, 'staff', test.id('st_sales'), 'reason', 'x')), 'admin');
select test.throws('reassign: a reason is needed', format($$select app.sales_reassign(%L, %L)$$, test.id('st_admin'),
  jsonb_build_object('booking', (test.s36b('web1')).booking_number, 'staff', test.id('st_sales'))), 'Say why');
select test.throws('reassign: to an active staff member', format($$select app.sales_reassign(%L, %L)$$, test.id('st_admin'),
  jsonb_build_object('booking', (test.s36b('web1')).booking_number, 'staff', test.id('st_rita'), 'reason', 'x')), 'active staff');
insert into s36 select 'web1_at', jsonb_build_object('at', (test.s36b('web1')).sales_attributed_at);
select app.sales_reassign(test.id('st_admin'), jsonb_build_object('booking', (test.s36b('web1')).booking_number, 'staff', test.id('st_sales'),
  'reason', 'Sales handled the calls'));
select test.eq('reassign: credited to Sales by an Admin', (select sales_staff_id::text || ' ' || sales_source || ' ' || (sales_attributed_by = test.id('st_admin')) from test.s36b('web1')),
  test.id('st_sales')::text || ' admin true');
select test.ok('reassign: the deal stays in its week', (test.s36b('web1')).sales_attributed_at = (test.s36('web1_at') ->> 'at')::timestamptz);
select test.ok('reassign: in the booking''s history with the reason',
  exists (select 1 from booking_events e where e.booking_id = (test.s36b('web1')).id and e.kind = 'sales_credit'
           and e.note = 'Sales credit: St Cs to St Sales (entered for CarmaCars). Sales handled the calls'));
select test.ok('reassign: in the audit log', exists (select 1 from audit_log a where a.entity_id = (test.s36b('web1')).id::text and a.entity_table = 'bookings'
  and a.after ->> 'sales_source' = 'admin' and a.before ->> 'sales_source' = 'offer'));
-- to nobody: a later offer does not credit anyone
insert into s36 select 'web3', jsonb_build_object('id', app.request_booking(test.id('renter:st_rita'), test.s36v(), date_trunc('hour', now()) + interval '70 days',
  date_trunc('hour', now()) + interval '72 days', 'standard', null, 'web', test.id('st_rita')));
select app.sales_reassign(test.id('st_admin'), jsonb_build_object('booking', (test.s36b('web3')).booking_number, 'staff', '', 'reason', 'A walk-in nobody took'));
select app.send_offer((test.s36b('web3')).id, test.id('st_cs'));
select test.ok('reassigned to nobody: a later offer credits nobody', (test.s36b('web3')).sales_staff_id is null and (test.s36b('web3')).sales_source = 'admin');

-- ================================================================ 5. booked revenue
select test.eq('revenue: none before confirmation', app.sales_revenue_cents((test.s36b('q1')).id), 0::bigint);
select test.eq('revenue: the rental charge before tax, less discounts', app.sales_revenue_cents((test.s36b('m1')).id),
  (select rental_charge_cents - discount_cents - staff_discount_cents - promo_discount_cents from test.s36b('m1')));
-- a goodwill refund paid on it (HST included) comes off before tax
insert into refunds (booking_id, reason, amount_cents, status, requested_by, approved_by, approved_at)
values ((test.s36b('m1')).id, 'goodwill', 11300, 'approved', test.id('st_admin'), test.id('st_admin'), now());
select test.eq('revenue: a goodwill refund of $113.00 takes $100.00 off', app.sales_revenue_cents((test.s36b('m1')).id),
  (select rental_charge_cents - discount_cents - 10000 from test.s36b('m1')));
-- a second rental by Sales, then cancelled: only the share kept counts
insert into s36 select 'm2', app.manual_rental_create(test.id('st_sales'), jsonb_build_object('vehicle_id', test.s36v(),
  'pickup_at', date_trunc('hour', now()) + interval '80 days', 'return_at', date_trunc('hour', now()) + interval '82 days',
  'source', 'phone', 'coverage_option', 1, 'renter_id', test.id('renter:st_rita'), 'payment', jsonb_build_object('mode', 'other_way', 'method', 'cash', 'note', 'Counter')));
insert into s36 select 'm2_net', to_jsonb(app.sales_revenue_cents((test.s36b('m2')).id));
select app.cancel_booking((test.s36b('m2')).id, test.id('st_admin'), 'renter_request', 'St changed plans', 'email');
select test.eq('revenue: a cancelled booking counts the share of the rental kept',
  app.sales_revenue_cents((test.s36b('m2')).id),
  (select round((test.s36('m2_net'))::text::bigint * (10000 - c.refund_bps) / 10000.0)::bigint from booking_cancellations c where c.booking_id = (test.s36b('m2')).id));

-- ================================================================ 6. My sales and the team's month
select test.ok('My sales: for every staff function since 0058 (commissions)', (app.door(test.id('st_cs'), 'aal2', 'va_read', 'my_sales', '{}') -> 'commissions') is not null);
select test.throws('My sales: only their own (an assistant cannot read another''s)', format($$select app.staff_sales(%L, %L)$$, test.id('st_sales'), test.id('st_cs')), 'your own');
insert into s36 select 'mine', app.door(test.id('st_sales'), 'aal2', 'va_read', 'my_sales', '{"period": "week", "count": 2}');
select test.eq('My sales: this week first, two weeks', (select jsonb_array_length(test.s36('mine') -> 'periods') || ' ' || (test.s36('mine') #>> '{periods,0,current}')), '2 true');
create or replace function test.s36w(p_f text) returns text language sql stable as $$ select test.s36('mine') #>> array['periods', '0', p_f] $$;
select test.eq('My sales: quotes created this week', test.s36w('quotes'), '1');
select test.eq('My sales: rentals added this week', test.s36w('rentals_added'), '2');
select test.eq('My sales: offers sent this week (the second offer on the website request)', test.s36w('offers_sent'), '1');
select test.eq('My sales: bookings confirmed this week (both rentals, one since cancelled)', test.s36w('confirmed') || ' ' || test.s36w('cancelled'), '2 1');
select test.eq('My sales: deals credited this week (quote, two rentals, the reassigned request) and won', test.s36w('deals') || ' ' || test.s36w('won'), '4 2');
select test.eq('My sales: conversion 50%', test.s36w('conversion_bps'), '5000');
select test.eq('My sales: booked revenue, net of the refund and the cancellation', test.s36w('revenue_cents')::bigint,
  app.sales_revenue_cents((test.s36b('m1')).id) + app.sales_revenue_cents((test.s36b('m2')).id));
select test.eq('My sales: follow-ups due (the quote with its offer out, the reassigned request)',
  (select string_agg(f ->> 'booking_number', ',' order by f ->> 'booking_number') from jsonb_array_elements(test.s36('mine') -> 'follow_ups') f),
  (select string_agg(booking_number, ',' order by booking_number) from bookings where id in ((test.s36b('q1')).id, (test.s36b('web1')).id)));
select test.ok('My sales: each follow-up says what to do', (select bool_and(f ->> 'step' <> '') from jsonb_array_elements(test.s36('mine') -> 'follow_ups') f));
select test.ok('My sales: the deal list, with what Sales may open (not a confirmed booking from someone else)',
  (select bool_and(case d ->> 'booking_number'
                     when (test.s36b('m1')).booking_number then (d ->> 'va_can_open')::boolean and (d ->> 'how') = 'manual_rental'
                     when (test.s36b('q1')).booking_number then (d ->> 'va_can_open')::boolean and (d ->> 'how') = 'quote'
                     else true end) from jsonb_array_elements(test.s36('mine') -> 'deals') d)
  and jsonb_array_length(test.s36('mine') -> 'deals') >= 4);
select test.ok('My sales: renters by first name only', (select bool_and(position(' ' in coalesce(d ->> 'renter', '')) = 0) from jsonb_array_elements(test.s36('mine') -> 'deals') d));
select test.eq('My sales: by month too', (app.door(test.id('st_sales'), 'aal2', 'va_read', 'my_sales', '{"period": "month"}') #>> '{periods,0,quotes}'), '1');

-- customer service: its offer credit shows to an Admin
select test.eq('Admin > Staff > Sales: anyone''s figures (customer service: two offers, no deal left after the reassignment)',
  (select (x #>> '{periods,0,offers_sent}') || ' ' || (x #>> '{periods,0,deals}') from app.door(test.id('st_admin'), 'aal2', 'admin_read', 'staff_sales',
     jsonb_build_object('staff', test.id('st_cs'))) x), '3 0');
select test.throws('Admin > Staff > Sales: an Admin only', format($$select app.door(%L, 'aal2', 'admin_read', 'staff_sales', %L)$$, test.id('st_cs'),
  jsonb_build_object('staff', test.id('st_sales'))), 'admin');

insert into s36 select 'team', app.door(test.id('st_admin'), 'aal2', 'admin_read', 'team_sales', '{}');
select test.ok('team: Sales listed with its month, in Sales',
  exists (select 1 from jsonb_array_elements(test.s36('team') -> 'rows') r where r ->> 'staff_id' = test.id('st_sales')::text and (r ->> 'in_sales')::boolean
          and (r ->> 'quotes')::integer = 1 and (r ->> 'confirmed')::integer = 2));
select test.ok('team: customer service listed for its offers', exists (select 1 from jsonb_array_elements(test.s36('team') -> 'rows') r where r ->> 'staff_id' = test.id('st_cs')::text));
select test.ok('team: fleet, with nothing this month, not listed', not exists (select 1 from jsonb_array_elements(test.s36('team') -> 'rows') r where r ->> 'staff_id' = test.id('st_fleet')::text));
select test.ok('team: totals add up', (test.s36('team') #>> '{totals,revenue_cents}')::bigint = (select sum((r ->> 'revenue_cents')::bigint) from jsonb_array_elements(test.s36('team') -> 'rows') r));
select test.eq('team: twelve months to choose from', jsonb_array_length(test.s36('team') -> 'months'), 12);
select test.throws('team: an Admin only', $$select app.team_sales(test.id('st_sales'))$$, 'admin');
select test.ok('booking page: the credit and who may get it', (select x ->> 'staff_id' = test.id('st_sales')::text and jsonb_array_length(x -> 'options') >= 4
  from app.door(test.id('st_admin'), 'aal2', 'admin_read', 'booking_sales', jsonb_build_object('booking', (test.s36b('m1')).booking_number)) x));
select test.lives('reassign through the door', format($$select app.door(%L, 'aal2', 'admin_do', 'sales_reassign', %L)$$, test.id('st_admin'),
  jsonb_build_object('booking', (test.s36b('m1')).booking_number, 'staff', test.id('st_cs'), 'reason', 'Customer service closed it')));
select test.eq('reassign through the door: the revenue moves with it', (app.staff_sales(test.id('st_admin'), test.id('st_cs')) #>> '{periods,0,revenue_cents}')::bigint,
  app.sales_revenue_cents((test.s36b('m1')).id));

-- privileges: the new functions are the server's
select test.throws('privileges: a browser session cannot read sales', $$set local role authenticated; select app.staff_sales(gen_random_uuid(), gen_random_uuid())$$, 'permission denied');
select test.throws('privileges: nor reassign', $$set local role authenticated; select app.sales_reassign(gen_random_uuid(), '{}')$$, 'permission denied');
