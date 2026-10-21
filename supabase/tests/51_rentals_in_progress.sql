-- 51: rentals added by hand in three cases from the dates (migration 0074): upcoming, in progress (written on trip at the
-- pickup entered, the handover gates turned into tasks) and past (completed). The clash check of a rental in progress,
-- each role, the cars it may be added on, signing, payment (other way, link, saved card, unpaid), the return, the
-- owner's revenue and commissions. Fixtures start with "ip".
select test.suite('51 rentals in progress');

select test.mk_user('ip_admin', 'admin');
select test.mk_user('ip_cs', 'va', 'cs');
select test.mk_user('ip_sales', 'va', 'sales');
select test.mk_user('ip_field', 'field', null, null, 'IPFIELD');
update staff_profiles set single_limit_cents = 500000 where user_id in (test.id('ip_cs'), test.id('ip_sales'));
select test.mk_owner('ip_olive');
select test.mk_vehicle('ip_malibu', 'ip_olive');
select test.mk_vehicle('ip_closed', 'ip_olive');
select test.mk_vehicle('ip_onb', 'ip_olive');
select test.mk_vehicle('ip_old', 'ip_olive');
select test.mk_vehicle('ip_sold', 'ip_olive');
select test.mk_vehicle('ip_new', 'ip_olive');
select test.mk_renter('ip_rita');
insert into payment_method_secrets (payment_method_id, processor, processor_customer_id, processor_method_id)
values (test.id('card:ip_rita'), 'stripe', 'cus_ip_rita', 'pm_ip_rita');
select test.mk_renter('ip_ron');
select test.mk_renter('ip_rhea');

create temp table ip as select null::text as k, null::jsonb as v limit 0;
create or replace function test.ip(p_k text) returns jsonb language sql stable as $$ select v from pg_temp.ip where k = p_k $$;
create or replace function test.ipb(p_k text) returns bookings language sql stable as $$ select * from bookings where id = (test.ip(p_k) ->> 'booking_id')::uuid $$;
create or replace function test.ipv(p text) returns uuid language sql stable as $$ select test.id('vehicle:' || p) $$;
-- a rental spec, hours from the top of this hour
create or replace function test.ipr(p_vehicle text, p_from interval, p_to interval, p jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select jsonb_build_object('vehicle_id', test.ipv(p_vehicle), 'pickup_at', date_trunc('hour', now()) + p_from, 'return_at', date_trunc('hour', now()) + p_to,
                            'source', 'phone', 'coverage_option', 1, 'renter_id', test.id('renter:ip_rita'), 'payment', jsonb_build_object('mode', 'other_way', 'method', 'cash')) || p $$;
create or replace function test.iptasks(p_k text) returns text language sql stable as $$
  select coalesce(string_agg(task_type || ':' || queue || ':' || priority, ',' order by task_type), '') from tasks
   where booking_id = (test.ipb(p_k)).id and task_type like 'live_rental_%' and status in ('open', 'in_progress', 'waiting') $$;

-- ================================================================ 1. the case comes from the dates
select test.eq('case: pickup ahead is upcoming, pickup passed and return ahead is in progress, return passed is past',
  app.manual_rental_phase(now() + interval '1 hour', now() + interval '2 days') || '/' || app.manual_rental_phase(now() - interval '1 day', now() + interval '6 days')
  || '/' || app.manual_rental_phase(now() - interval '3 days', now() - interval '1 hour'), 'upcoming/in_progress/past');
select test.ok('case: none without both dates', app.manual_rental_phase(null, now()) is null);

-- the quote says which case it is, before anything is added
insert into ip select 'q_live', app.manual_rental_quote(test.id('ip_admin'), test.ipr('ip_malibu', interval '-1 day', interval '6 days'));
select test.eq('quote: in progress, free, with the note for the form', (test.ip('q_live') ->> 'phase') || '/' || (test.ip('q_live') ->> 'free')
  || '/' || (test.ip('q_live') ->> 'phase_note' like 'This rental is already underway: it will be recorded as on trip%'), 'in_progress/true/true');
select test.ok('quote: a rental in progress may be paid by link or card', (test.ip('q_live') -> 'payment_modes') ?& array['link', 'card', 'other_way', 'unpaid']);
select test.eq('quote: upcoming and past say so too',
  (app.manual_rental_quote(test.id('ip_admin'), test.ipr('ip_malibu', interval '20 days', interval '21 days')) ->> 'phase') || '/'
  || (app.manual_rental_quote(test.id('ip_admin'), test.ipr('ip_malibu', interval '-20 days', interval '-18 days')) ->> 'phase'), 'upcoming/past');
select test.ok('quote: a past rental is paid another way or unpaid only',
  (app.manual_rental_quote(test.id('ip_admin'), test.ipr('ip_malibu', interval '-20 days', interval '-18 days')) -> 'payment_modes') = '["other_way", "unpaid"]'::jsonb);

-- ================================================================ 2. in progress: on trip from the pickup entered
-- the owner's case: the car went out yesterday, back next week, entered by an Admin and paid another way
insert into ip select 'live', app.manual_rental_create(test.id('ip_admin'), test.ipr('ip_malibu', interval '-1 day', interval '6 days',
  '{"payment": {"mode": "other_way", "method": "e_transfer", "reference": "ET-IP-1"}}'));
select test.eq('in progress: on trip, handed over at the pickup entered, by the staff member who added it',
  (select status || '/' || (handed_over_at = pickup_at) || '/' || (checked_in_at is null) || '/' || added_mode || '/' || (created_by = test.id('ip_admin'))
            || '/' || (confirmed_at is not null) || '/' || blocks_calendar from test.ipb('live')), 'on_rent/true/true/in_progress/true/true/true');
select test.eq('in progress: the result says the case', test.ip('live') ->> 'phase', 'in_progress');
select test.eq('in progress: the car is out (its status follows, as at a handover)', (select status::text from vehicles where id = test.ipv('ip_malibu')), 'on_rent');
select test.ok('in progress: the owner''s tracker controls are held during the managed rental',
  exists (select 1 from tracker_access_blocks t where t.booking_id = (test.ipb('live')).id and t.ends_at is null and t.starts_at = (test.ipb('live')).pickup_at));
select test.eq('in progress: what a handover checks and is missing is a task, never a block',
  test.iptasks('live'), 'live_rental_agreement:cs:high,live_rental_condition:fleet:normal,live_rental_coverage:cs:high,live_rental_deposit:finance:normal,live_rental_identity:cs:high');
select test.ok('in progress: the coverage task names it plainly', exists (select 1 from tasks t where t.booking_id = (test.ipb('live')).id
  and t.title = 'Coverage proof missing for an active rental: ' || (test.ipb('live')).booking_number));
select test.ok('in progress: the payment received is recorded and pays the charges',
  exists (select 1 from payments p where p.booking_id = (test.ipb('live')).id and p.status = 'succeeded' and p.method = 'e_transfer')
  and not exists (select 1 from booking_line_items l where l.booking_id = (test.ipb('live')).id and l.stage = 'booking' and l.charged_to_renter and l.voided_at is null and l.payment_id is null));
select test.ok('in progress: the renter gets the rental-added email (it has started: sign now), the owner the notice',
  exists (select 1 from app_events e where e.code = 'renter_rental_added' and e.entity_id = (test.ipb('live')).id)
  and exists (select 1 from app_events e where e.code = 'owner_new_booking' and e.entity_id = (test.ipb('live')).id));
select test.ok('in progress: no pickup or trip-start emails (the car is already out)',
  not exists (select 1 from app_events e where e.entity_id = (test.ipb('live')).id
               and e.code in ('renter_rental_started', 'renter_booking_confirmed', 'renter_offer_ready', 'renter_pickup_reminder', 'staff_offer_approved_paid')));
select test.eq('in progress: the email''s lines say it has started',
  app.notification_payload('renter_rental_added', (select e from app_events e where e.code = 'renter_rental_added' and e.entity_id = (test.ipb('live')).id limit 1), '{}'::jsonb) ->> 'sign_line',
  'Your rental has already started. Please read and sign your rental agreement now.');
select test.ok('in progress: the return reminder and the overdue check see it (on trip, return ahead)',
  exists (select 1 from bookings b where b.id = (test.ipb('live')).id and b.status = 'on_rent' and b.return_at > now()));

-- the calendar: blocked for the remaining dates, free after the return and its turnaround
select test.ok('calendar: the car is taken for the remaining dates', not app.vehicle_is_available(test.ipv('ip_malibu'), now() + interval '2 days', now() + interval '3 days'));
select test.ok('calendar: free again after the return and the turnaround',
  app.vehicle_is_available(test.ipv('ip_malibu'), (test.ipb('live')).return_at + interval '3 hours', (test.ipb('live')).return_at + interval '2 days'));
select test.throws('calendar: an upcoming rental over the remaining dates is refused, with what to do',
  format($$select app.manual_rental_create(%L, test.ipr('ip_malibu', interval '3 days', interval '4 days', '{"payment": {"mode": "link"}}'))$$, test.id('ip_cs')),
  'Press Check the calendar and the price to see what, then choose other dates or another car');
select test.throws('calendar: a second rental in progress over it is refused too',
  format($$select app.manual_rental_create(%L, test.ipr('ip_malibu', interval '-2 hours', interval '2 days', '{"payment": {"mode": "unpaid"}}'))$$, test.id('ip_admin')),
  'give the reason to add it over the clash');
select test.ok('calendar: the quote names the rental in the way',
  (app.manual_rental_quote(test.id('ip_admin'), test.ipr('ip_malibu', interval '-2 hours', interval '2 days')) -> 'clashes') @> jsonb_build_array(jsonb_build_object('booking_number', (test.ipb('live')).booking_number)));

-- ================================================================ 3. the clash check of a rental in progress: the past part as it happened
-- a rental recorded on the "old" car: picked up 6 days ago, checked in 2 days ago
insert into ip select 'hist', app.manual_rental_create(test.id('ip_admin'), test.ipr('ip_old', interval '-6 days', interval '-2 days', '{"renter_id": null}'::jsonb
  || jsonb_build_object('renter_id', test.id('renter:ip_ron'))));
select test.eq('past: kept as completed', (test.ipb('hist')).status::text || '/' || (test.ipb('hist')).added_mode, 'closed/past');
select test.eq('clash: one hour after the earlier rental''s check-in: free',
  jsonb_array_length(app.manual_rental_live_clashes(test.ipv('ip_old'), (test.ipb('hist')).checked_in_at + interval '1 hour', now() + interval '3 days')), 0);
select test.eq('clash: overlapping the earlier rental as it happened: named',
  (app.manual_rental_live_clashes(test.ipv('ip_old'), (test.ipb('hist')).checked_in_at - interval '1 day', now() + interval '3 days') -> 0 ->> 'booking_number'),
  (test.ipb('hist')).booking_number);
-- a calendar block that ended before now is history; one ahead is in the way
insert into vehicle_calendar_blocks (vehicle_id, starts_at, ends_at, reason, created_by)
values (test.ipv('ip_old'), now() - interval '30 hours', now() - interval '26 hours', 'owner_unavailable', test.id('ip_admin')),
       (test.ipv('ip_old'), now() + interval '5 days', now() + interval '6 days', 'owner_unavailable', test.id('ip_admin'));
select test.eq('clash: a calendar block that already ended is not in the way of a rental in progress',
  jsonb_array_length(app.manual_rental_live_clashes(test.ipv('ip_old'), (test.ipb('hist')).checked_in_at + interval '1 hour', now() + interval '3 days')), 0);
select test.eq('clash: a calendar block still ahead is', (app.manual_rental_live_clashes(test.ipv('ip_old'), (test.ipb('hist')).checked_in_at + interval '1 hour', now() + interval '5 days 12 hours') -> 0 ->> 'kind'), 'block');
insert into ip select 'after_hist', app.manual_rental_create(test.id('ip_cs'), test.ipr('ip_old', interval '-1 day', interval '3 days', jsonb_build_object('renter_id', test.id('renter:ip_ron'),
  'payment', jsonb_build_object('mode', 'link'))));
select test.eq('clash: added after the earlier rental, on trip', (test.ipb('after_hist')).status::text, 'on_rent');

-- ================================================================ 4. each role
-- customer service: a rental in progress with a payment link (on trip at once; the renter signs, then pays online)
select test.eq('assistant: adds a rental in progress (payment link): on trip, no offer, waiting for the online payment',
  (select b.status || '/' || (b.current_offer_version is null) || '/' || app.booking_link_due(b) || '/' || b.added_mode from test.ipb('after_hist') b), 'on_rent/true/true/in_progress');
select test.ok('assistant: no offer email for it (the rental-added email carries the signing and the payment)',
  not exists (select 1 from app_events e where e.code = 'renter_offer_ready' and e.entity_id = (test.ipb('after_hist')).id)
  and exists (select 1 from app_events e where e.code = 'renter_rental_added' and e.entity_id = (test.ipb('after_hist')).id));
select test.eq('assistant: the email says sign, then pay online',
  app.notification_payload('renter_rental_added', (select e from app_events e where e.code = 'renter_rental_added' and e.entity_id = (test.ipb('after_hist')).id limit 1), '{}'::jsonb) ->> 'payment_line',
  'Pay online after you sign: the Pay now button is on your booking.');
select test.ok('payment facts: waiting for the online payment, no free-car check (the car is out)',
  (public.server_booking_payment_facts((test.ipb('after_hist')).id) ->> 'link_due')::boolean and (public.server_booking_payment_facts((test.ipb('after_hist')).id) ->> 'vehicle_free')::boolean);
-- the renter signs in the portal, then pays: recorded, still on trip
select app.open_rental_agreement((test.ipb('after_hist')).id, test.id('ip_ron'), 'ra-test-1', repeat('a', 64), 'bookings/ip/agreement.pdf');
select test.ok('signing: the agreement opens on the rental in progress, as on a confirmed rental added by hand',
  exists (select 1 from rental_agreements a where a.booking_id = (test.ipb('after_hist')).id and a.status = 'open' and a.offer_version is null)
  and app.booking_awaiting_signature((test.ipb('after_hist')).id));
select app.record_signature((test.ipb('after_hist')).signature_request_id,
  (select g.id from rental_agreement_signers g join rental_agreements a on a.id = g.agreement_id where a.booking_id = (test.ipb('after_hist')).id and g.signer_role = 'renter'),
  'Ip Ron', null, null, 'test', 'I agree', repeat('a', 64), null);
select test.eq('signing: the renter signs, CarmaCars countersigns at once, the task closes',
  (select a.status from rental_agreements a where a.booking_id = (test.ipb('after_hist')).id and a.status <> 'voided') || '/'
  || app.booking_awaiting_signature((test.ipb('after_hist')).id) || '/'
  || (select t.status from tasks t where t.booking_id = (test.ipb('after_hist')).id and t.task_type = 'live_rental_agreement'), 'completed/false/done');
insert into ip select 'paid_online', app.record_booking_payment((test.ipb('after_hist')).id,
  '{"processor": "stripe", "payment_id": "pi_ip_live", "charge_id": "ch_ip_live", "customer_id": "cus_ip_ron", "method_id": "pm_ip_ron"}'::jsonb,
  (test.ipb('after_hist')).renter_due_at_booking_cents, null,
  '{"brand": "visa", "last4": "4444", "cardholder_name": "Ip Ron", "exp_month": 12, "exp_year": 2031, "is_credit": true, "funding": "credit"}'::jsonb, 'evt_ip_live', test.id('ip_ron'));
select test.eq('payment link: the online payment is recorded and captured, the rental stays on trip',
  (test.ip('paid_online') ->> 'ok') || '/' || (test.ip('paid_online') ->> 'action') || '/' || (test.ipb('after_hist')).status || '/' || app.booking_link_due(test.ipb('after_hist'))
  || '/' || ((test.ipb('after_hist')).card_on_file_id is not null), 'true/capture/on_rent/false/true');
select test.eq('payment link: the same payment reported again is not recorded twice',
  (app.record_booking_payment((test.ipb('after_hist')).id, '{"processor": "stripe", "payment_id": "pi_ip_live"}'::jsonb, (test.ipb('after_hist')).renter_due_at_booking_cents,
     null, null, 'evt_ip_live', test.id('ip_ron')) ->> 'ok')
  || '/' || (select count(*) from payments p where p.booking_id = (test.ipb('after_hist')).id and p.status = 'succeeded'), 'true/1');

-- Sales, through the door: "I sourced this client", the saved card charged when the renter signs
update vehicles set bookings_enabled = false where id = test.ipv('ip_closed');
insert into ip select 'sales_live', app.door(test.id('ip_sales'), 'aal2', 'ops_do', 'manual_rental_create', test.ipr('ip_closed', interval '-3 hours', interval '4 days',
  '{"sales_choice": "sourced", "payment": {"mode": "card"}}'));
select test.eq('Sales: adds a rental in progress on a car closed to public bookings, sourced by them',
  (test.ipb('sales_live')).status::text || '/' || (test.ipb('sales_live')).sales_sourced || '/' || ((test.ipb('sales_live')).sales_staff_id = test.id('ip_sales')), 'on_rent/true/true');
select test.eq('Sales: the saved card is charged when the renter signs (the rental in progress included)',
  (app.manual_rental_sign_charge((test.ipb('sales_live')).id, test.id('ip_rita')) ->> 'amount_cents')::bigint, (test.ipb('sales_live')).renter_due_at_booking_cents);
select test.eq('Sales: the commission accrues on the rental in progress', (select c.status from staff_commissions c where c.booking_id = (test.ipb('sales_live')).id and c.kind = 'commission'), 'accruing');
select test.throws('upcoming: the same car closed to public bookings says why and what to do',
  format($$select app.manual_rental_create(%L, test.ipr('ip_closed', interval '10 days', interval '11 days', '{"payment": {"mode": "link"}}'))$$, test.id('ip_cs')),
  'bookings are turned off for this car). Choose another car, or ask an Admin to open it for bookings');

-- field staff: a payment link, typed renter
insert into ip select 'field_live', app.manual_rental_create(test.id('ip_field'), test.ipr('ip_onb', interval '-5 hours', interval '2 days',
  jsonb_build_object('renter_id', null, 'payment', jsonb_build_object('mode', 'link'),
                     'renter', jsonb_build_object('full_name', 'Ip Fiona Field', 'email', 'ip.fiona@example.test', 'mobile', '+14165550111', 'date_of_birth', '1991-02-03'))));
select test.eq('field staff: add a rental in progress (payment link)', (test.ipb('field_live')).status::text || '/' || (test.ipb('field_live')).payment_mode, 'on_rent/link');
select test.throws('field staff: no payment taken themselves, in progress too',
  format($$select app.manual_rental_create(%L, test.ipr('ip_onb', interval '3 days', interval '4 days', '{"payment": {"mode": "other_way", "method": "cash"}}'))$$, test.id('ip_field')),
  'Choose one of the ways shown under Payment');

-- the past stays an Admin's
select test.throws('assistant: a rental that has already ended is an Admin''s, said plainly',
  format($$select app.manual_rental_create(%L, test.ipr('ip_malibu', interval '-12 days', interval '-10 days'))$$, test.id('ip_cs')),
  'Only an Admin can record a rental that has already ended');
select test.throws('field staff: the same', format($$select app.manual_rental_create(%L, test.ipr('ip_malibu', interval '-12 days', interval '-10 days', '{"payment": {"mode": "link"}}'))$$, test.id('ip_field')),
  'Only an Admin can record a rental that has already ended');
select test.throws('assistant: the quote says it too', format($$select app.manual_rental_quote(%L, test.ipr('ip_malibu', interval '-12 days', interval '-10 days'))$$, test.id('ip_cs')),
  'Only an Admin can record a rental that has already ended');
select test.throws('a renter adds no rental', format($$select app.manual_rental_create(%L, test.ipr('ip_malibu', interval '-1 hour', interval '2 days'))$$, test.id('ip_rita')),
  'Only CarmaCars staff can add a rental');

-- ================================================================ 5. the cars
-- a car still in onboarding (not on the policy): the rental is added, with the insurance and the status tasks
-- (the car's status set straight, as an enrolment left in progress would leave it)
set session_replication_role = replica;
update vehicles set status = 'onboarding', on_fleet_policy = false where id = test.ipv('ip_new');
set session_replication_role = default;
insert into ip select 'onb_car', jsonb_build_object('vehicle_id', test.ipv('ip_new'));
insert into ip select 'onb_live', app.manual_rental_create(test.id('ip_cs'), jsonb_build_object('vehicle_id', test.ip('onb_car') ->> 'vehicle_id',
  'pickup_at', date_trunc('hour', now()) - interval '1 day', 'return_at', date_trunc('hour', now()) + interval '2 days', 'source', 'phone', 'coverage_option', 1,
  'renter_id', test.id('renter:ip_rhea'), 'payment', jsonb_build_object('mode', 'link')));
select test.eq('onboarding car: added on trip, the insurance task urgent for an Admin, the car''s status a task for fleet',
  (test.ipb('onb_live')).status::text || '|' || (select string_agg(task_type || ':' || queue || ':' || priority, ',' order by task_type) from tasks t
     where t.booking_id = (test.ipb('onb_live')).id and task_type in ('live_rental_insurance', 'live_rental_car_status')),
  'on_rent|live_rental_car_status:fleet:high,live_rental_insurance:admin:urgent');
insert into ip select 'ret_car', app.vehicle_add(test.id('ip_admin'), '{"supply_type": "company", "vin": "1HPRETXRED0000001", "plate": "IPRE001", "year": 2020, "make": "Kia", "model": "Rio", "rates": {"daily": 5000}}');
update vehicles set retired_at = now() where id = (test.ip('ret_car') ->> 'vehicle_id')::uuid;
select test.throws('a retired car takes no rental in progress, said plainly',
  format($$select app.manual_rental_create(%L, jsonb_build_object('vehicle_id', %L, 'pickup_at', now() - interval '1 day', 'return_at', now() + interval '1 day', 'coverage_option', 1, 'renter_id', %L, 'payment', '{"mode": "unpaid"}'::jsonb))$$,
         test.id('ip_admin'), test.ip('ret_car') ->> 'vehicle_id', test.id('renter:ip_rita')), 'is retired and takes no rentals. Choose another car');
select test.throws('the quote refuses it too', format($$select app.manual_rental_quote(%L, jsonb_build_object('vehicle_id', %L, 'pickup_at', now() - interval '1 day', 'return_at', now() + interval '1 day'))$$,
         test.id('ip_admin'), test.ip('ret_car') ->> 'vehicle_id'), 'is retired');
select test.ok('Add a rental lists a car closed to public bookings to assistants (for a rental already underway)',
  exists (select 1 from jsonb_array_elements(app.manual_rental_vehicles(test.id('ip_cs'))) x where (x ->> 'id')::uuid = test.ipv('ip_closed') and not (x ->> 'bookable')::boolean));

-- ================================================================ 6. the past: the wording, the limits
select test.throws('past: "past" with a return still ahead says the return must already have happened',
  format($$select app.manual_rental_create(%L, test.ipr('ip_malibu', interval '-1 day', interval '1 day', '{"past": true}'))$$, test.id('ip_admin')),
  'For a past rental, the return must already have happened');
select test.throws('past: not a payment link, said with what to choose',
  format($$select app.manual_rental_create(%L, test.ipr('ip_malibu', interval '-12 days', interval '-10 days', '{"payment": {"mode": "link"}}'))$$, test.id('ip_admin')),
  'Choose Paid another way or Unpaid');
select test.throws('past: at most the setting''s days back', format($$select app.manual_rental_create(%L, test.ipr('ip_malibu', interval '-400 days', interval '-398 days'))$$, test.id('ip_admin')),
  'can go back at most');
select test.throws('dates: the return before the pickup', format($$select app.manual_rental_create(%L, test.ipr('ip_malibu', interval '3 days', interval '2 days'))$$, test.id('ip_admin')),
  'The return must be after the pickup: check both dates and times');

-- ================================================================ 7. the return, the owner's revenue, the commission
select app.complete_return((test.ipb('live')).id, test.id('ip_admin'),
  jsonb_build_object('odometer_km', 30000, 'fuel_pct', 100, 'keys_count', 2, 'cleanliness', 'clean', 'renter_signature_ref', 'sig/renter-in',
                     'staff_signature_ref', 'sig/staff-in', 'photos', test.op_photos('return')));
select test.eq('return: checked in at the end of the trip like any rental (the return flow)', (test.ipb('live')).status::text || '/' || ((test.ipb('live')).checked_in_at is not null), 'returned/true');
select test.ok('return: the car goes to cleaning, the tracker controls come back to the owner',
  (select status::text from vehicles where id = test.ipv('ip_malibu')) in ('cleaning', 'available')
  and not exists (select 1 from tracker_access_blocks t where t.booking_id = (test.ipb('live')).id and t.ends_at is null));
select test.ok('return: the owner''s revenue is split as for any rental',
  exists (select 1 from booking_splits s where s.booking_id = (test.ipb('live')).id and s.owner_revenue_cents > 0 and s.company_share_bps = 3500));
-- a Sales rental in progress, sourced and paid in full: its commission is earned at the return, as for any rental
insert into ip select 'sold', app.door(test.id('ip_sales'), 'aal2', 'ops_do', 'manual_rental_create', test.ipr('ip_sold', interval '-2 days', interval '2 days',
  '{"sales_choice": "sourced", "payment": {"mode": "other_way", "method": "cash"}}'));
select test.eq('commission: accruing while the car is out', (select c.status from staff_commissions c where c.booking_id = (test.ipb('sold')).id and c.kind = 'commission'), 'accruing');
select app.complete_return((test.ipb('sold')).id, test.id('ip_admin'),
  jsonb_build_object('odometer_km', 30000, 'fuel_pct', 100, 'keys_count', 2, 'cleanliness', 'clean', 'renter_signature_ref', 'sig/renter-in',
                     'staff_signature_ref', 'sig/staff-in', 'photos', test.op_photos('return')));
select test.eq('commission: earned at the return, paid in full (waiting for an Admin''s approval)',
  (select c.status || '/' || (c.base_cents > 0) from staff_commissions c where c.booking_id = (test.ipb('sold')).id and c.kind = 'commission'), 'pending_approval/true');

-- ================================================================ 8. documents and checks while the car is out
select test.ok('documents: licence photos and coverage proof may still be sent for a rental in progress', app.booking_docs_open(test.ipb('after_hist'))
  and not app.booking_docs_open(test.ipb('hist')));
select app.verify_driver_in_person(test.id('ip_admin'), jsonb_build_object('booking_driver_id',
  (select d.id from booking_drivers d where d.booking_id = (test.ipb('sales_live')).id and d.role = 'renter'), 'note', 'Licence seen at the counter'));
select test.eq('verified in person while out: the identity task closes',
  (select t.status from tasks t where t.booking_id = (test.ipb('sales_live')).id and t.task_type = 'live_rental_identity'), 'done');

-- ================================================================ 9. upcoming is unchanged
insert into ip select 'up', app.manual_rental_create(test.id('ip_admin'), test.ipr('ip_malibu', interval '20 days', interval '22 days'));
select test.eq('upcoming: confirmed, not handed over, added as future', (test.ipb('up')).status::text || '/' || ((test.ipb('up')).handed_over_at is null) || '/' || (test.ipb('up')).added_mode,
  'confirmed/true/future');
select test.eq('upcoming: no in-progress tasks', test.iptasks('up'), '');
