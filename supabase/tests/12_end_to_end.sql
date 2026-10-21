-- 12: end to end (migration 0024 and everything before it). Runs last, so it sees every
-- migration and every helper of the earlier test files. It drives the newer flows one after the
-- other: a public request through 0019 to a confirmed, paid booking; documents; handover, a
-- calendar extension (priced by 0019), return, statement and Deposit through 0020; a charge line
-- added by hand; a toll charged through 0021; a calendar change and a renter's change request on
-- a confirmed booking (one flow, 0019's change requests); an owner application and a published
-- listing through 0022. Then the notification layer processes every event, and each business
-- action must have produced exactly one email per intended recipient, with no duplicate across
-- the emitters of 0019 to 0023. Last, the scheduled jobs of 0024.
--
-- Every fixture label starts with "e2".
select test.suite('12 end to end');

-- ------------------------------------------------------------------ helpers and fixture
create or replace function test.at(p_local text) returns timestamptz
language sql immutable as $$ select p_local::timestamp at time zone 'America/Toronto' $$;
create function test.e2_local(p_at timestamptz) returns text
language sql immutable as $$ select to_char(p_at at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI') $$;
create table test.e2_ids (k text primary key, id uuid);
create function test.e2(p_key text) returns uuid language sql stable as $$ select id from test.e2_ids where k = p_key $$;
create function test.e2_put(p_key text, p_id uuid) returns uuid language sql as $$
  insert into test.e2_ids values (p_key, p_id) on conflict (k) do update set id = excluded.id returning id
$$;
-- the first event of the flows below (everything earlier is processed first)
create table test.e2_base (ev bigint);
-- outbox rows of the flows, one line per code and recipient kind, with the count
create function test.e2_mail(p_booking uuid) returns text language sql stable as $$
  select string_agg(code || '=' || n, ' ' order by code)
    from (select o.code, count(*) as n from notification_outbox o join app_events e on e.id = o.event_id
           where e.id > (select ev from test.e2_base) and o.booking_id = p_booking and o.audience = 'renter'
           group by o.code) x
$$;
grant select on test.e2_ids, test.e2_base to authenticated, anon;
grant execute on all functions in schema test to authenticated, anon;

select test.mk_user('e2_admin', 'admin');
select test.mk_user('e2_cs', 'va', 'cs');
select test.mk_user('e2_fin', 'va', 'finance');
select test.mk_user('e2_fleet', 'va', 'fleet');
select test.mk_user('e2_ann', 'owner');            -- applies through the website
select test.mk_owner('e2_owen');
select test.mk_vehicle(v, 'e2_owen') from unnest(array['E2A', 'E2B', 'E2L', 'E2T']) v;
insert into vehicle_listings (vehicle_id, slug, headline, seats, transmission, status, published_at)
select test.id('vehicle:' || v), 'e2-' || lower(v), 'Mercedes C 300 ' || v, 5, 'automatic', 'published', now()
  from unnest(array['E2A', 'E2B']) v;
select test.mk_renter('e2_tom');
insert into documents (id, kind, title, storage_bucket, storage_path) values
  (test.id('doc:e2-receipt'), 'other', 'Cleaning invoice', 'claims', 'e2/cleaning.pdf'),
  (test.id('doc:e2-receipt2'), 'other', 'Key replacement invoice', 'claims', 'e2/key.pdf');

-- everything earlier files left unprocessed goes through the layer first
select app.process_events(100000);
insert into test.e2_base select coalesce(max(id), 0) from app_events;

-- ================================================================== A. request to book (0019)
select test.ba_new('e2:1', 'eve.end@example.test', 'E2A', test.soon('4 days'), test.soon('6 days'),
  jsonb_build_object('renter', jsonb_build_object('date_of_birth', test.dob(23))));
select test.eq('A the public request is accepted and is a request',
  (select (v ->> 'ok') || '/' || (v ->> 'created') from test.out('new:e2:1') v) || '/' || test.ba_st('e2:1'), 'true/true/requested');
select test.ba_offer('e2:1');
select test.ba_open('e2:1');
select test.ba_sign('e2:1');
select test.ba_pay('e2:1');
select test.eq('A offered, approved, signed and paid: confirmed', test.ba_st('e2:1'), 'confirmed');
-- identity and coverage
select test.ba_up('e2:1', 'renter', k, test.ba_user('eve.end@example.test')) from unnest(array['licence_front', 'licence_back', 'selfie']) k;
select app.review_verification_upload(test.ba_upload('e2:1', 'renter', k), test.id('e2_cs'), true) from unnest(array['licence_front', 'licence_back', 'selfie']) k;
select app.submit_card_coverage(test.ba('e2:1'), test.ba_user('eve.end@example.test'), true);
select app.register_verification_upload(test.ba('e2:1'), test.ba_user('eve.end@example.test'), 'coverage_proof', null, 'bookings/e2/coverage.pdf',
  test.sha('e2cov'), 'application/pdf', '{"coverage_option": 2, "card_issuer": "Big Bank", "card_last4": "4242"}');
select app.review_verification_upload(test.ba_upload('e2:1', null, 'coverage_proof'), test.id('e2_cs'), true);
select test.eq('A every driver verified and the coverage confirmed: only the Deposit and the pickup report remain',
  (select v ->> 'missing' from app.booking_readiness(test.ba('e2:1')) v), '["deposit", "pickup_condition_report"]');

-- ================================================================== B. handover, calendar extension, return (0020, 0019)
insert into test.rq_ids values ('e2:1', test.ba('e2:1'));
select test.op_handover('e2:1', 'e2_fleet', test.e2_local((select pickup_at from bookings where id = test.ba('e2:1'))));
select test.eq('B handed over', test.ba_st('e2:1'), 'on_rent');
create table test.e2_ext as
  select app.calendar_apply_change(b.id, test.id('e2_cs'), jsonb_build_object('return_at', b.return_at + interval '1 day'), 'the renter keeps the car a day') as r
    from bookings b where b.id = test.ba('e2:1');
select test.e2_put('ext', (select (r ->> 'extension_id')::uuid from test.e2_ext));
select test.eq('B (item 4) a calendar extension is priced by 0019: rental and the young driver fee for the added day, with HST; the preview showed the same total',
  (select status || '/' || previous_days || '>' || new_days || '/' || (rental_difference_cents > 0) || '/' || (fees_difference_cents > 0) || '/'
          || (total_cents = rental_difference_cents + fees_difference_cents + hst_cents) || '/'
          || (select string_agg(l ->> 'charge_type', ',' order by l ->> 'charge_type') from jsonb_array_elements(lines) l)
     from booking_extensions where id = test.e2('ext'))
  || '/' || (select ((r ->> 'difference_cents')::bigint = (select total_cents from booking_extensions where id = test.e2('ext')))::text from test.e2_ext),
  'requested/2>3/true/true/true/rental_charge,young_driver_21_25/true');
select app.approve_extension(test.e2('ext'), test.id('e2_cs'));
create table test.e2_extpaid as select app.confirm_extension_payment(test.e2('ext'), '{"payment_id": "pi_e2x", "charge_id": "ch_e2x"}',
                                                          (select total_cents from booking_extensions where id = test.e2('ext'))) as r;
select test.eq('B the extension is paid before the return time and the booking moves',
  (select r ->> 'ok' from test.e2_extpaid) || '/' || (select billable_days from bookings where id = test.ba('e2:1')), 'true/3');
select test.op_return('e2:1', 'e2_fleet', test.e2_local((select return_at from bookings where id = test.ba('e2:1'))), 20100);
select app.submit_return_findings(test.ba('e2:1'), test.id('e2_fleet'));
select app.assess_check_in(test.ba('e2:1'), '{}', test.id('e2_fin'));
select test.e2_put('st1', app.issue_booking_statement(test.ba('e2:1'), test.id('e2_fin'), (select return_at + interval '2 hours' from bookings where id = test.ba('e2:1'))));
select app.settle_deposit(test.ba('e2:1'), test.id('e2_admin'), '{}', (select return_at + interval '3 hours' from bookings where id = test.ba('e2:1')));
select test.eq('B returned on time, nothing to charge: the Check-in statement is issued, the Deposit released and the booking closed',
  (select kind || '/' || charges_cents from booking_statements where id = test.e2('st1')) || '/' || test.ba_st('e2:1'), 'check_in/0/closed');

-- ================================================================== C. charge lines added by hand (item 2)
insert into booking_line_items (booking_id, charge_type, description, quantity, unit_amount_cents, amount_cents, hst_applies, hst_cents,
                                revenue_class, stage, supporting_document_id, created_by)
select b.id, f.code, 'Cleaning: sand under the seats, found after the return', 1, 7500, 7500, f.hst_applies,
       case when f.hst_applies then public.calc_hst(7500, b.hst_bps) else 0 end, f.revenue_class, 'after_return', test.id('doc:e2-receipt'), test.id('e2_fin')
  from fee_types f, bookings b where f.code = 'cleaning' and b.id = test.ba('e2:1');
select test.e2_put('line1', (select id from booking_line_items where booking_id = test.ba('e2:1') and supporting_document_id = test.id('doc:e2-receipt')));
-- a second line typed without its invoice: told when the invoice is attached, once
insert into booking_line_items (booking_id, charge_type, description, quantity, unit_amount_cents, amount_cents, hst_applies, hst_cents,
                                revenue_class, stage, created_by)
select b.id, f.code, 'Replacement key', 1, 25000, 25000, f.hst_applies,
       case when f.hst_applies then public.calc_hst(25000, b.hst_bps) else 0 end, f.revenue_class, 'after_return', test.id('e2_fin')
  from fee_types f, bookings b where f.code = 'lost_key_cost' and b.id = test.ba('e2:1');
select test.e2_put('line2', (select id from booking_line_items where booking_id = test.ba('e2:1') and description = 'Replacement key'));
select test.eq('C a hand-added line without its supporting record is not emailed yet',
  (select count(*) from app_events where code = 'renter_extra_charge' and entity_id = test.e2('line2')), 0::bigint);
update booking_line_items set supporting_document_id = test.id('doc:e2-receipt2') where id = test.e2('line2');
update booking_line_items set description = 'Replacement key (fob)' where id = test.e2('line2');
update booking_line_items set supporting_document_id = test.id('doc:e2-receipt2') where id = test.e2('line2');
select test.eq('C each hand-added line emits renter_extra_charge once, keyed "renter_extra_charge:<line>:manual"',
  (select string_agg((dedupe_key = 'renter_extra_charge:' || entity_id || ':manual') || ':' || entity || ':' || (payload ->> 'charge_kind'), ' ' order by id)
     from app_events where code = 'renter_extra_charge' and entity_id in (test.e2('line1'), test.e2('line2'))),
  'true:booking_line_item:manual true:booking_line_item:manual');

-- ================================================================== D. a toll charged through 0021 (a closed booking of September)
select test.mk_booking('E2T1', 'E2T', 'e2_tom', '2026-09-20 10:00', '2026-09-23 10:00', 'closed', 30000, 'standard', null, '2026-09-10 10:00');
insert into booking_statements (booking_id, statement_number, kind, issued_at) values (test.id('booking:E2T1'), 'RS-E2T1', 'check_in', test.at('2026-09-23 12:00'));
insert into deposits (booking_id, amount_cents, method, status, captured_cents, applied_cents, released_cents, release_approved_by)
values (test.id('booking:E2T1'), 100000, 'card_hold', 'settled', 0, 0, 100000, test.id('e2_admin'));
select test.tz_log('e2toll', 'E2T', '2026-09-21 14:00', 640);
select test.eq('D the notice is matched to the booking automatically', (select status || '/' || match_confidence from toll_tickets where notice_number = 'N-e2toll'), 'matched/high');
create table test.e2_toll as select app.charge_toll_ticket(array[(test.tz_t('e2toll')).id], test.id('e2_fin'), test.at('2026-10-01 10:00')) as r;
select test.eq('D charged on a later-charge statement; the toll lines are not taken for hand-added ones',
  (select string_agg(x ->> 'result', ',') from test.e2_toll, jsonb_array_elements(r) x)
  || '/' || (select count(*) from app_events where code = 'renter_extra_charge' and (payload ->> 'booking_id')::uuid = test.id('booking:E2T1'))
  || '/' || (select min(entity) || ':' || min(payload ->> 'charge_kind') from app_events where code = 'renter_extra_charge' and (payload ->> 'booking_id')::uuid = test.id('booking:E2T1')),
  'charged/1/booking_statement:toll_invoice');

-- ================================================================== E. changing a confirmed booking: one flow (item 4)
select test.ba_confirmed('e2:2', 'cal.end@example.test', 'E2B', test.soon('10 days'), test.soon('12 days'));
create table test.e2_cal as select app.calendar_apply_change(test.ba('e2:2'), test.id('e2_cs'), jsonb_build_object('return_at', test.soon('13 days')),
                                                             'the renter asked for one more day') as r;
select test.e2_put('cal', (select (r ->> 'change_request_id')::uuid from test.e2_cal));
select test.eq('E a calendar resize of a confirmed booking is a change request from the calendar, proposed and priced by 0019, with the task to obtain the agreement',
  (select (r ->> 'applied') || '/' || (r ->> 'flow') from test.e2_cal)
  || '/' || (select status || ':' || source || ':' || requested_by_role || ':' || (total_difference_cents = (select (r ->> 'difference_cents')::bigint from test.e2_cal))
               from booking_change_requests where id = test.e2('cal'))
  || '/' || (select count(*) || ':' || min(status) || ':' || bool_and(related_id = test.e2('cal')) from tasks where booking_id = test.ba('e2:2') and task_type = 'booking_change_approval')
  || '/' || (select (return_at = test.soon('12 days'))::text from bookings where id = test.ba('e2:2')),
  'false/change_request/proposed:staff_calendar:staff:true/1:open:true/true');
select app.agree_booking_change(test.e2('cal'), test.ba_user('cal.end@example.test'), inet '203.0.113.12', 'test phone');
select app.apply_booking_change(test.e2('cal'), test.ba_user('cal.end@example.test'),
  '{"payment_id": "pi_e2cal", "charge_id": "ch_e2cal"}', (select total_difference_cents from booking_change_requests where id = test.e2('cal')));
select test.eq('E the renter agrees and pays online; applied by 0019: the booking moves, the payment is the difference, the task closes, the history has each step',
  (select (return_at = test.soon('13 days')) || ':' || billable_days from bookings where id = test.ba('e2:2'))
  || '/' || (select c.status || ':' || (p.amount_cents = c.total_difference_cents) || ':' || p.status from booking_change_requests c join payments p on p.id = c.payment_id where c.id = test.e2('cal'))
  || '/' || (select string_agg(distinct status, ',') from tasks where booking_id = test.ba('e2:2') and task_type = 'booking_change_approval')
  || '/' || (select string_agg(details ->> 'step', ',' order by id) from booking_events where booking_id = test.ba('e2:2') and kind = 'booking_change'),
  'true:3/applied:true:succeeded/done/proposed,agreed,applied');
-- the renter asks for a later pickup the same day: approved by customer service at no cost, applied
select test.e2_put('ch', app.request_booking_change(test.ba('e2:2'), test.ba_user('cal.end@example.test'),
  -- two hours later, or less when that would cross midnight in Toronto (another day can have another rate)
  jsonb_build_object('pickup_at', test.soon('10 days') + least(interval '2 hours',
    date_trunc('day', test.soon('10 days') at time zone 'America/Toronto') + interval '1 day' - (test.soon('10 days') at time zone 'America/Toronto') - interval '10 minutes')),
  'My flight lands later'));
select app.approve_booking_change(test.e2('ch'), test.id('e2_cs'));
select test.eq('E the renter''s request costs nothing more: approved counts as agreed, and it is applied',
  (select (app.apply_booking_change(test.e2('ch'), test.id('e2_cs')) ->> 'status'))
  || '/' || (select total_difference_cents from booking_change_requests where id = test.e2('ch')), 'applied/0');

-- ================================================================== F. an owner application and a listing (0022)
create table test.e2_app as select app.submit_owner_application(jsonb_build_object(
  'owner', jsonb_build_object('owner_type', 'individual', 'legal_name', 'Ann Endtoend', 'first_name', 'Ann', 'last_name', 'Endtoend',
                              'address_line1', '9 Owner Road', 'city', 'Toronto', 'province', 'on', 'postal_code', 'm4m1a2',
                              'email', 'e2_ann@example.test', 'phone', '4165550122', 'licence_number', 'E1234-56789-01234',
                              'date_of_birth', '1984-02-02'),
  'vehicles', jsonb_build_array(
    jsonb_build_object('vin', '1HGCM82633A200001', 'plate', 'E2E001', 'year', 2022, 'make', 'Toyota', 'model', 'Camry', 'colour', 'Black',
                       'odometer_km', 15000, 'body_type', 'Sedan', 'title_status', 'owned_outright', 'management_mode', 'managed',
                       'onboarding_method', 'transfer', 'current_insurer', 'Insurer A'))), test.id('e2_ann')) as r;
select test.e2_put('ann_vehicle', (select ((r -> 'vehicles' -> 0) ->> 'vehicle_id')::uuid from test.e2_app));
select test.eq('F one application, one vehicle in onboarding',
  (select jsonb_array_length(r -> 'vehicles') from test.e2_app) || '/' || (select status from vehicles where id = test.e2('ann_vehicle')), '1/onboarding');
create table test.e2_list as select test.ofl_list(test.id('vehicle:E2L'), test.id('e2_admin'), 'Black') as r;
select test.eq('F the listing pipeline publishes the car an Admin started', (select status from vehicle_listings where vehicle_id = test.id('vehicle:E2L')), 'published');

-- ================================================================== X. the notification layer: one email per recipient per action
select app.process_events(100000);
select test.eq('X every event of the flows is processed',
  (select count(*) from app_events where id > (select ev from test.e2_base) and processed_at is null), 0::bigint);
select test.eq('X no two events of the flows describe the same thing: one event per code, entity and kind (one emitter each; identity and coverage reviews are two actions)',
  (select count(*) from (select code, entity_id from app_events where id > (select ev from test.e2_base)
                           group by code, entity_id, coalesce(payload ->> 'kind', '') having count(*) > 1) d), 0::bigint);
select test.eq('X no recipient has two outbox rows for one code and entity',
  (select count(*) from (select 1 from notification_outbox o join app_events e on e.id = o.event_id where e.id > (select ev from test.e2_base)
                           group by o.code, o.entity_id, coalesce(o.recipient_user_id::text, lower(o.to_address)) having count(*) > 1) d), 0::bigint);
select test.eq('X no recipient has two staff digest lines for one code and entity',
  (select count(*) from (select 1 from staff_digest_items s join app_events e on e.id = s.event_id where e.id > (select ev from test.e2_base)
                           group by s.code, s.entity_id, s.role, coalesce(e.payload ->> 'kind', '') having count(*) > 1) d), 0::bigint);
select test.eq('X no email of the flows is missing a variable',
  (select coalesce(string_agg(distinct o.code, ','), 'none') from notification_outbox o join app_events e on e.id = o.event_id
    where e.id > (select ev from test.e2_base) and o.missing_variables <> '{}'), 'none');
select test.eq('X the renter of the first booking: one email per action, from request to the charges added by hand (two lines, two emails; the extension payment has its receipt, as the catalogue says)',
  test.e2_mail(test.ba('e2:1')),
  'renter_agreement_signed=1 renter_booking_confirmed=1 renter_extension_approved=1 renter_extension_confirmed=1 '
  || 'renter_extension_requested=1 renter_extra_charge=2 renter_identity_approved=1 renter_offer_ready=1 renter_payment_receipt=1 renter_rental_started=1 '
  || 'renter_request_received=1 renter_return_complete=1');
select test.eq('X the renter of the second booking: the calendar change and their own request each give one email per step, never two',
  test.e2_mail(test.ba('e2:2')),
  'renter_agreement_signed=1 renter_booking_confirmed=1 renter_change_applied=2 renter_change_proposed=1 renter_change_request_approved=1 '
  || 'renter_change_request_received=1 renter_offer_ready=1 renter_payment_receipt=1 renter_request_received=1');
select test.eq('X the toll: one email to the renter, with the statement',
  test.e2_mail(test.id('booking:E2T1')), 'renter_extra_charge=1');
select test.eq('X the hand-added charge emails carry the line, its HST and the total',
  (select string_agg((payload ->> 'charge_type') || ':' || (payload ->> 'charge_total') || ':' || jsonb_array_length(payload -> 'charge_lines'), ' ' order by o.created_at, o.payload ->> 'charge_total')
     from notification_outbox o where o.code = 'renter_extra_charge' and o.entity_id in (test.e2('line1'), test.e2('line2'))),
  'Lost key or fob: replacement cost:$282.50:2 Cleaning:$84.75:2');
select test.eq('X each staff notice of the request reached each customer service assistant once (one per person)',
  (select (count(*) = count(distinct o.recipient_user_id))::text || '/'
          || (count(distinct o.recipient_user_id) = (select count(*) from staff_profiles sp join users u on u.id = sp.user_id
                                                      where sp.va_function = 'cs' and sp.is_active and u.status = 'active'))::text
     from notification_outbox o join app_events e on e.id = o.event_id
    where e.id > (select ev from test.e2_base) and o.code = 'staff_booking_request_new' and o.booking_id = test.ba('e2:1')), 'true/true');
select test.eq('X the owner application: the applicant once, the sales assistants once each',
  (select count(*) filter (where o.code = 'owner_application_received') || '/'
          || (count(*) filter (where o.code = 'staff_owner_application_received') = count(distinct o.recipient_user_id) filter (where o.code = 'staff_owner_application_received'))::text
     from notification_outbox o join app_events e on e.id = o.event_id
    where e.id > (select ev from test.e2_base) and o.code in ('owner_application_received', 'staff_owner_application_received')
      and e.entity_id in (select id from vehicle_onboardings where vehicle_id = test.e2('ann_vehicle'))), '1/true');
select test.eq('X the listing: the owner is told once',
  (select count(*) from notification_outbox o join app_events e on e.id = o.event_id
    where e.id > (select ev from test.e2_base) and o.code = 'owner_vehicle_listed' and o.vehicle_id = test.id('vehicle:E2L')), 1::bigint);
create table test.e2_x as select (select count(*) from notification_outbox) as before_n, (select count(*) from staff_digest_items) as before_d;
create table test.e2_x2 as select app.process_events(100000) as processed;
select test.eq('X running the layer again writes nothing new',
  (select processed from test.e2_x2) || '/' || ((select count(*) from notification_outbox) = (select before_n from test.e2_x))
  || '/' || ((select count(*) from staff_digest_items) = (select before_d from test.e2_x)), '0/true/true');

-- ================================================================== J. the scheduled jobs of 0024 (item 1)
-- rate limit counters
insert into app.rate_limit_hits (key, window_start, window_length, hits) values ('e2:old', now() - interval '10 days', interval '1 hour', 3);
create table test.e2_j1 as select app.job_rate_limit_purge(test.at('2031-03-03 02:10')) || '/' || app.job_rate_limit_purge(test.at('2031-03-03 03:10'))
  || '/' || app.job_rate_limit_purge(test.at('2031-03-03 09:10')) as r;
select test.eq('J rate-limit purge: not before the housekeeping hour, then once a day, removing old counters',
  (select r from test.e2_j1) || '/' || (select count(*) from app.rate_limit_hits where key = 'e2:old'), 'not_due/succeeded/already_run/0');
-- form drafts
insert into form_drafts (form_code, token_hashes, data, expires_at) values ('contact', array['e2'], '{}', now() - interval '1 day');
create table test.e2_j2 as select app.job_form_drafts_purge(test.at('2031-03-03 03:20')) || '/' || app.job_form_drafts_purge(test.at('2031-03-03 04:20')) as r;
select test.eq('J form-drafts purge: once a day, expired drafts removed',
  (select r from test.e2_j2) || '/' || (select count(*) from form_drafts where token_hashes = array['e2']), 'succeeded/already_run/0');
-- extensions not paid by the return time (the request of 09 on booking opW, whose return was July 12, 2031)
create table test.e2_j3 as select app.job_lapse_extensions(test.at('2031-07-12 10:16')) || '/' || app.job_lapse_extensions(test.at('2031-07-12 10:29'))
  || '/' || app.job_lapse_extensions(test.at('2031-07-12 10:31')) as r;
select test.eq('J lapse-extensions: every 15 minutes, once per slot; an unpaid extension past the return time lapses',
  (select r from test.e2_j3)
  || '/' || (select status from booking_extensions where booking_id = test.b('opW') order by seq desc limit 1), 'succeeded/already_run/succeeded/lapsed');
-- the listing queue: a job a worker claimed and never finished goes back to the queue
update listing_jobs set status = 'running', locked_at = now() - interval '2 hours', locked_by = 'gone-worker', attempts = 1, max_attempts = 3,
       finished_at = null
 where id = (select j.id from listing_jobs j join listing_intakes i on i.id = j.intake_id where i.vehicle_id = test.id('vehicle:E2L') and j.kind = 'draft_copy' limit 1);
create table test.e2_j4 as select app.job_listing_sweep(now()) || '/' || app.job_listing_sweep(now()) as r;
select test.eq('J listing sweep: a stuck job is queued again and counted as due; once per 10-minute slot',
  (select r from test.e2_j4)
  || '/' || (select status || ':' || coalesce(locked_by, 'unlocked') from listing_jobs j join listing_intakes i on i.id = j.intake_id
              where i.vehicle_id = test.id('vehicle:E2L') and j.kind = 'draft_copy'),
  'succeeded/already_run/queued:unlocked');
select test.eq('J the sweep reports what is due for the worker',
  (select (summary ->> 'requeued') || '/' || ((summary ->> 'due')::integer >= 1) from job_runs where job_name = 'listing-sweep' order by started_at desc limit 1), '1/true');
update listing_jobs set status = 'cancelled', finished_at = now()
 where id in (select j.id from listing_jobs j join listing_intakes i on i.id = j.intake_id where i.vehicle_id = test.id('vehicle:E2L') and j.status = 'queued');
-- publish later
select app.unlist_listing(test.id('vehicle:E2L'), test.id('e2_admin'), 'photos to redo');
select test.throws('J only an Admin or a customer service or fleet assistant schedules a listing',
  format($$select app.schedule_listing_publish(%L, %L, now() + interval '1 hour')$$, test.id('e2_fin'), test.id('vehicle:E2L')), 'schedules a listing');
select test.throws('J a time in the past is refused',
  format($$select app.schedule_listing_publish(%L, %L, now() - interval '1 hour')$$, test.id('e2_cs'), test.id('vehicle:E2L')), 'in the future');
select app.schedule_listing_publish(test.id('e2_cs'), test.id('vehicle:E2L'), now() + interval '1 hour');
select app.schedule_listing_publish(test.id('e2_cs'), test.id('vehicle:E2T'), now() + interval '1 hour');
create table test.e2_j5 as select app.job_publish_listings(now() + interval '30 minutes') as r;
select test.eq('J publish-listings: nothing before the time',
  (select r from test.e2_j5) || '/' || (select status from vehicle_listings where vehicle_id = test.id('vehicle:E2L')), 'not_due/unpublished');
-- (since 0070 only the basics block a listing: E2T is kept off by a missing model for this check)
update vehicles set model = '' where id = test.id('vehicle:E2T');
create table test.e2_j6 as select app.job_publish_listings(now() + interval '61 minutes') as r;
update vehicles set model = 'C 300 E2T' where id = test.id('vehicle:E2T');
select test.eq('J at the time the car is published in the scheduler''s name; a car that cannot be published keeps the reason and Fleet gets the task',
  (select r from test.e2_j6)
  || '/' || (select status || ':' || (published_by = test.id('e2_cs')) || ':' || coalesce(publish_at::text, 'cleared') from vehicle_listings where vehicle_id = test.id('vehicle:E2L'))
  || '/' || (select (publish_error like 'Cannot publish%') || ':' || coalesce(publish_at::text, 'cleared') from vehicle_listings where vehicle_id = test.id('vehicle:E2T'))
  || '/' || (select count(*) || ':' || min(queue) from tasks where vehicle_id = test.id('vehicle:E2T') and task_type = 'listing_failed'),
  'succeeded/published:true:cleared/true:cleared/1:fleet');
select test.eq('J every new job is recorded in job_runs under its own name',
  (select string_agg(distinct job_name, ',' order by job_name) from job_runs
    where job_name in ('rate-limit-purge', 'form-drafts-purge', 'lapse-extensions', 'listing-sweep', 'listings-publish')),
  'form-drafts-purge,lapse-extensions,listing-sweep,listings-publish,rate-limit-purge');

-- ================================================================== 5. the owner portal order (the flaky test of 0022)
select test.eq('5 the owner portal lists vehicles created in one transaction in the order they were added',
  (select string_agg(x ->> 'plate', ',' order by o) from jsonb_array_elements(app.owner_portal_vehicles(test.id('ofl_omar'))) with ordinality t(x, o)),
  (select string_agg(plate, ',' order by created_seq) from vehicles where owner_id = (select id from owners where user_id = test.id('ofl_omar'))));
