-- 25: the operations gaps (migration 0040): staff proposals to change a confirmed booking and the amendment the
-- renter signs, the cleaning block after each trip, the listing similarity check, earlier requests on a verified
-- sign-in, the additional driver's link, Forms C and D, the doors and the emails. Fixtures start with "og".
select test.suite('25 operations gaps');
create table test.og (k text primary key, v uuid);
grant select on test.og to service_role, authenticated;
create or replace function test.og(p text) returns uuid language sql stable as $$ select v from test.og where k = p $$;
create or replace function test.og_at(p text) returns timestamptz language sql immutable as $$ select (p::timestamp at time zone 'America/Toronto') $$;
grant execute on function test.og(text), test.og_at(text) to service_role, authenticated;

select test.mk_user('og_admin', 'admin');
select test.mk_user('og_cs', 'va', 'cs');
select test.mk_user('og_fleet', 'va', 'fleet');
select test.mk_user('og_fin', 'va', 'finance');
select test.mk_owner('og_olive');
select test.mk_owner('og_oscar');
select test.mk_vehicle('OGA', 'og_olive');
select test.mk_vehicle('OGB', 'og_olive');
select test.mk_vehicle('OGC', 'og_oscar');
select test.mk_renter('og_rita');
select test.mk_renter('og_ray');
-- a confirmed booking next March, Mon 10:00 to Thu 10:00
select test.mk_booking('OG-1', 'OGA', 'og_rita', '2027-03-08 10:00', '2027-03-11 10:00', 'confirmed');
select test.mk_booking('OG-2', 'OGB', 'og_ray', '2027-04-05 10:00', '2027-04-07 10:00', 'confirmed');

-- ---------------------------------------------------------------- 1. settings
select test.eq('settings: 48 hours to accept, a reminder 12 hours before, 2 hours before pickup at the latest, links for 72 hours, a 120-minute cleaning block, copy 60% alike',
  (select booking_change_accept_hours || '/' || booking_change_reminder_hours || '/' || booking_change_lead_hours || '/' || booking_driver_link_hours || '/'
          || turnaround_block_enabled || '/' || turnaround_block_minutes || '/' || listing_similarity_enabled || '/' || listing_similarity_copy_bps from app.settings()),
  '48/12/2/72/true/120/true/6000');

-- ---------------------------------------------------------------- 2. the cleaning block after a trip
select test.eq('cleaning: a confirmed booking has its block from the return, for the minutes in settings',
  (select reason || '/' || source || '/' || (starts_at = test.og_at('2027-03-11 10:00')) || '/' || ((ends_at - starts_at) = interval '120 minutes')
     from vehicle_calendar_blocks where booking_id = test.id('booking:OG-1')), 'cleaning/turnaround/true/true');
select test.eq('cleaning: the car is not free during the block, free right after it',
  app.vehicle_is_available(test.id('vehicle:OGA'), test.og_at('2027-03-11 11:00'), test.og_at('2027-03-12 10:00')) || '/' ||
  app.vehicle_is_available(test.id('vehicle:OGA'), test.og_at('2027-03-11 12:00'), test.og_at('2027-03-12 10:00')), 'false/true');
select test.eq('cleaning: the booking''s own block never stands in its own way', app.vehicle_is_available(test.id('vehicle:OGA'), test.og_at('2027-03-08 10:00'), test.og_at('2027-03-11 12:30'), test.id('booking:OG-1')), true);
select app.set_vehicle_turnaround(test.id('og_fleet'), test.id('vehicle:OGA'), 240);
select test.eq('cleaning: a car''s own minutes (Fleet) move its blocks', (select (ends_at - starts_at)::text from vehicle_calendar_blocks where booking_id = test.id('booking:OG-1')), '04:00:00');
select test.throws('cleaning: customer service does not set a car''s cleaning time', format('select app.set_vehicle_turnaround(%L, %L, 30)', test.id('og_cs'), test.id('vehicle:OGA')), 'Fleet or an Admin');
select app.set_vehicle_turnaround(test.id('og_admin'), test.id('vehicle:OGA'), null);
select test.mk_booking('OG-3', 'OGA', 'og_ray', '2027-03-11 13:00', '2027-03-12 10:00', 'confirmed');
select test.eq('cleaning: a block made later never covers another confirmed booking (it stops at the next pickup)',
  (select (ends_at <= test.og_at('2027-03-11 13:00'))::text from vehicle_calendar_blocks where booking_id = test.id('booking:OG-1')), 'true');
select app.cancel_booking(test.id('booking:OG-3'), test.id('og_admin'), 'renter_request', 'Test: the renter cancelled', 'email', now());
select test.eq('cleaning: a cancelled booking loses its block', (select count(*) from vehicle_calendar_blocks where booking_id = test.id('booking:OG-3')), 0::bigint);
select test.throws('cleaning: removing needs a reason', format('select app.remove_turnaround_block(%L, %L, %L)', test.id('og_fleet'),
  (select id from vehicle_calendar_blocks where booking_id = test.id('booking:OG-2')), ''), 'reason');
select test.throws('cleaning: Finance does not remove a block', format('select app.remove_turnaround_block(%L, %L, %L)', test.id('og_fin'),
  (select id from vehicle_calendar_blocks where booking_id = test.id('booking:OG-2')), 'not needed'), 'Fleet');
select app.remove_turnaround_block(test.id('og_fleet'), (select id from vehicle_calendar_blocks where booking_id = test.id('booking:OG-2')), 'Car cleaned at the return');
update bookings set return_at = test.og_at('2027-04-07 12:00'), original_return_at = test.og_at('2027-04-07 12:00'),
       billable_days = public.calc_billable_days(pickup_at, test.og_at('2027-04-07 12:00')),
       km_allowance_total = km_allowance_per_day * public.calc_billable_days(pickup_at, test.og_at('2027-04-07 12:00')) where id = test.id('booking:OG-2');
select test.eq('cleaning: a block staff removed is not put back when the booking moves',
  (select (removed_at is not null) || '/' || removed_reason from vehicle_calendar_blocks where booking_id = test.id('booking:OG-2')), 'true/Car cleaned at the return');
select test.eq('cleaning: the master calendar shows the block with its reason and the booking it follows',
  (select count(*) from jsonb_array_elements(app.admin_read(test.id('og_admin'), 'calendar', jsonb_build_object('from', '2027-03-01', 'to', '2027-03-31')) -> 'vehicles') v
     cross join jsonb_array_elements(v -> 'entries') x
    where (v ->> 'id')::uuid = test.id('vehicle:OGA') and x ->> 'type' = 'block' and x ->> 'reason' = 'cleaning' and x ->> 'note' = 'Cleaning after booking OG-1'), 1::bigint);

-- ---------------------------------------------------------------- 3. a change staff propose
select test.throws('propose: a renter does not propose a new rental charge',
  format('select public.renter_request_booking_change(%L, %L, %L)', test.id('booking:OG-1'), test.id('og_rita'), '{"rental_charge_cents": 1000}'), 'rental charge');
select test.throws('propose: Finance does not propose changes',
  format('select app.propose_booking_change(%L, %L)', test.id('og_fin'), jsonb_build_object('booking', 'OG-1', 'return_at', test.og_at('2027-03-12 10:00'), 'note', 'x')), 'customer service');
select test.throws('propose: the renter reads the reason, so it is needed',
  format('select app.propose_booking_change(%L, %L)', test.id('og_cs'), jsonb_build_object('booking', 'OG-1', 'return_at', test.og_at('2027-03-12 10:00'))), 'reason');
select test.throws('propose: something must change',
  format('select app.propose_booking_change(%L, %L)', test.id('og_cs'), jsonb_build_object('booking', 'OG-1', 'note', 'Nothing')), 'Nothing would change');
select test.eq('preview: the rows the form shows (return, days, total) and the difference',
  (select (v -> 'rows' -> 0 ->> 'label') || '/' || jsonb_array_length(v -> 'rows') || '/' || ((v ->> 'total_difference_cents')::bigint > 0)
     from app.propose_preview(test.id('og_cs'), jsonb_build_object('booking', 'OG-1', 'return_at', test.og_at('2027-03-12 10:00'))) v), 'Return/4/true');
insert into test.og select 'c1', (app.propose_booking_change(test.id('og_cs'), jsonb_build_object('booking', 'OG-1', 'return_at', test.og_at('2027-03-12 10:00'),
  'note', 'The car you booked needs a service on Thursday morning; we can keep you in it one more day.')) ->> 'id')::uuid;
select test.eq('propose: a proposal from staff, waiting for the renter, with its deadline (48 hours, before the pickup)',
  (select status || '/' || requested_by_role || '/' || (accept_by between now() + interval '47 hours' and now() + interval '49 hours') from booking_change_requests where id = test.og('c1')),
  'proposed/staff/true');
select test.eq('propose: the calendar does not move before the renter accepts', (select return_at = test.og_at('2027-03-11 10:00') from bookings where id = test.id('booking:OG-1')), true);
select test.eq('propose: customer service has a task to follow it',
  (select count(*) from tasks where task_type = 'booking_change_approval' and booking_id = test.id('booking:OG-1') and status = 'open'), 1::bigint);
select test.eq('propose: the renter is emailed once the proposal is saved', (select count(*) from app_events where code = 'renter_change_proposed' and entity_id = test.og('c1')), 1::bigint);
select app.process_events(100000);
select test.eq('email: the proposal names the change, the reason, the extra to pay and the deadline',
  (select (payload -> 'change_rows' -> 0 ->> 'label') || '/' || (payload ->> 'difference_label') || '/' || (payload ->> 'change_reason' like 'The car you booked%')
          || '/' || (payload ->> 'accept_by' <> '') || '/' || (payload ->> 'booking_number')
     from notification_outbox where code = 'renter_change_proposed' and entity_id = test.og('c1')), 'Return/Extra to pay/true/true/OG-1');
select test.eq('email: it goes to the renter', (select to_address from notification_outbox where code = 'renter_change_proposed' and entity_id = test.og('c1')), 'og_rita@example.test');

-- the amendment, then the money, then the calendar
select test.throws('amendment: only the renter opens it', format('select app.open_booking_amendment(%L, %L, %L, %L, %L)', test.og('c1'), test.id('og_ray'),
  repeat('a', 64), 'bookings/x/amend.pdf', 'amend-v1'), 'renter of the booking');
insert into test.og select 'a1', (app.open_booking_amendment(test.og('c1'), test.id('og_rita'), repeat('a', 64), 'bookings/og1/amendment-1.pdf', 'amend-v1') ->> 'id')::uuid;
select test.eq('amendment: numbered after the booking, open, with its document and a signature request',
  (select a.amendment_number || '/' || a.status || '/' || d.kind || '/' || d.storage_bucket || '/' || sr.provider
     from booking_amendments a join documents d on d.id = a.document_id join signature_requests sr on sr.id = a.signature_request_id where a.id = test.og('a1')),
  'OG-1-A1/open/rental_amendment/agreements/builtin');
select test.eq('amendment: the same document again returns the same amendment',
  (app.open_booking_amendment(test.og('c1'), test.id('og_rita'), repeat('a', 64), 'bookings/og1/amendment-1.pdf', 'amend-v1') ->> 'id')::uuid, test.og('a1'));
select test.throws('amendment: applying before signing is refused', format('select app.accept_booking_change_apply(%L, %L)', test.og('c1'), test.id('og_rita')), 'Sign the amendment first');
select test.throws('amendment: a typed name must be the renter''s legal name', format('select app.sign_booking_amendment(%L, %L, %L, %L, %L)', test.og('a1'), test.id('og_rita'),
  'I agree to this amendment.', repeat('a', 64), 'Someone Else'), 'legal name');
select test.throws('amendment: the document signed must be the one opened', format('select app.sign_booking_amendment(%L, %L, %L, %L, %L)', test.og('a1'), test.id('og_rita'),
  'I agree to this amendment.', repeat('b', 64), 'Og Rita'), 'changed after it was opened');
select app.sign_booking_amendment(test.og('a1'), test.id('og_rita'), 'I agree to this amendment.', repeat('a', 64), 'Og Rita', null, '203.0.113.9', 'test browser');
select test.eq('amendment: signed (typed), the signature record keeps the statement, the address and the document; the change is agreed',
  (select a.status || '/' || r.method || '/' || r.consent_text || '/' || host(r.ip_address) || '/' || (r.document_sha256 = a.document_sha256) || '/' || (c.renter_agreed_at is not null) || '/' || c.status
     from booking_amendments a join signature_records r on r.id = a.signature_record_id join booking_change_requests c on c.id = a.change_request_id where a.id = test.og('a1')),
  'signed/typed/I agree to this amendment./203.0.113.9/true/true/approved');
select test.eq('amendment (0053): countersigned automatically when the renter signed, by the signing officer with the approved wording; the staff member is "Proposed by"',
  (select r.signer_role || '/' || r.method || '/' || r.signer_name || '/' || (r.signed_at = s.signed_at) || '/' || (r.document_sha256 = a.document_sha256) || '/'
          || (r.consent_text = app.corporate_signature_text()) || '/' || r.staff_attribution
     from booking_amendments a join signature_records r on r.id = a.countersignature_record_id join signature_records s on s.id = a.signature_record_id where a.id = test.og('a1')),
  'carmacars/automatic/' || (select coalesce(signing_officer_name, 'CarmaCars') from app.settings()) || '/true/true/true/Proposed by: Og Cs');
select test.eq('amendment (0053): the facts name the signing officer; the record the server renders carries both signatures and "Proposed by"',
  (app.booking_change_facts(test.og('c1'), test.id('og_rita')) #>> '{countersigner,name}') || '/' || (public.server_amendment_record(test.og('a1')) #>> '{countersign,method}')
  || '/' || (public.server_amendment_record(test.og('a1')) #>> '{record,method}') || '/' || (public.server_amendment_record(test.og('a1')) #>> '{countersign,staff_attribution}'),
  (select coalesce(signing_officer_name, 'CarmaCars') from app.settings()) || '/automatic/typed/Proposed by: Og Cs');
select test.throws('apply: a change that costs more needs a payment of exactly the difference', format('select app.accept_booking_change_apply(%L, %L)', test.og('c1'), test.id('og_rita')), 'needs a payment of exactly');
select app.accept_booking_change_apply(test.og('c1'), test.id('og_rita'), jsonb_build_object('processor', 'stripe', 'payment_id', 'pi_og_c1', 'charge_id', 'ch_og_c1'),
  (select total_difference_cents from booking_change_requests where id = test.og('c1')));
select test.eq('apply: the booking has the new return, the change is applied, the extra payment is recorded with its PaymentIntent',
  (select (b.return_at = test.og_at('2027-03-12 10:00')) || '/' || c.status || '/' || p.status || '/' || (p.amount_cents = c.total_difference_cents) || '/' || d.processor_payment_id
     from booking_change_requests c join bookings b on b.id = c.booking_id join payments p on p.id = c.payment_id
     join payment_processor_details d on d.payment_id = p.id where c.id = test.og('c1')), 'true/applied/succeeded/true/pi_og_c1');
select test.eq('apply: the cleaning block follows the new return', (select starts_at = test.og_at('2027-03-12 10:00') from vehicle_calendar_blocks where booking_id = test.id('booking:OG-1')), true);
select test.eq('apply: the renter, the owner and customer service each get their email (the owner one, for the car that stayed)',
  (select string_agg(code, ',' order by code) from app_events where entity_id = test.og('c1') and code in ('renter_change_applied', 'owner_booking_changed', 'staff_change_proposal_answered')),
  'owner_booking_changed,renter_change_applied,staff_change_proposal_answered');
-- the web server's own calls run as the service role: it reads the facts and the signature record it renders
select test.og('a1') as og_a1, test.og('c1') as og_c1, test.id('og_rita') as og_rita \gset
set role service_role;
create temp table og_rec as select public.server_amendment_record(:'og_a1'::uuid) r, public.server_change_facts(:'og_c1'::uuid, :'og_rita'::uuid) f;
reset role;
select test.eq('service role: the server reads the signed amendment, its signature record and the change',
  (select (r #>> '{record,method}') || '/' || (r #>> '{amendment,status}') || '/' || (f #>> '{amendment,status}') from og_rec), 'typed/signed/signed');
select app.attach_signed_amendment(test.og('a1'), 'bookings/og1/amendment-1-signed.pdf', repeat('c', 64));
select test.eq('signed copy: stored as its own document, the signature request completed',
  (select d.title || '/' || sr.status || '/' || (sr.signed_document_id = a.signed_document_id) from booking_amendments a join documents d on d.id = a.signed_document_id
     join signature_requests sr on sr.id = a.signature_request_id where a.id = test.og('a1')), 'Signed booking amendment OG-1-A1/completed/true');
select test.eq('signed copy: a second attach returns the first', app.attach_signed_amendment(test.og('a1'), 'x.pdf', repeat('d', 64)) = (select signed_document_id from booking_amendments where id = test.og('a1')), true);
select test.login(test.id('og_rita'));
select test.eq('renter: the amendment and its signed copy are among her documents (row-level security)',
  test.visible($$select * from documents where kind::text = 'rental_amendment'$$), 2::bigint);
select test.logout();
select app.process_events(100000);
select test.eq('email: the renter''s confirmation says what was charged and links the signed amendment',
  (select (o.payload ->> 'money_text' like 'We charged $%') || '/' || (o.payload ->> 'amendment_number') || '/' || (app.outbox_file_refs(o.id) #>> '{signed_agreement_url,k}')
     from notification_outbox o where o.code = 'renter_change_applied' and o.entity_id = test.og('c1')), 'true/OG-1-A1/document');
select test.eq('email: the owner sees what their car earns before and after',
  (select (payload ->> 'income_changed') || '/' || (payload ->> 'income_after' <> payload ->> 'income_before') || '/' || to_address
     from notification_outbox where code = 'owner_booking_changed' and entity_id = test.og('c1')), 'true/true/og_olive@example.test');
select test.eq('email: customer service hears it was accepted, in their next digest',
  (select count(*) from staff_digest_items where code = 'staff_change_proposal_answered' and entity_id = test.og('c1') and role = 'va_cs'), 1::bigint);
select test.eq('email: the line says the renter accepted', app.notification_payload('staff_change_proposal_answered',
  (select e from app_events e where e.code = 'staff_change_proposal_answered' and e.entity_id = test.og('c1')), '{"audience": "staff_va_cs"}') ->> 'outcome_title', 'accepted');
select test.eq('history: the task is closed and the booking''s history has each step',
  (select count(*) from tasks where task_type = 'booking_change_approval' and booking_id = test.id('booking:OG-1') and status = 'open') || '/' ||
  (select string_agg(details ->> 'step', ',' order by id) from booking_events where booking_id = test.id('booking:OG-1') and kind = 'booking_change'), '0/proposed,agreed,applied');

-- a cheaper change to another car of the same owner: a refund waits for approval, both cars' owner is told once
insert into test.og select 'c2', (app.propose_booking_change(test.id('og_admin'), jsonb_build_object('booking', 'OG-1', 'vehicle_id', test.id('vehicle:OGB'),
  'rental_charge_cents', 20000, 'note', 'We are moving you to the twin car at a lower price.')) ->> 'id')::uuid;
select test.eq('price: staff propose a new rental charge with the car', (select (after ->> 'rental_charge_cents') || '/' || (total_difference_cents < 0) from booking_change_requests where id = test.og('c2')), '20000/true');
insert into test.og select 'a2', (app.open_booking_amendment(test.og('c2'), test.id('og_rita'), repeat('e', 64), 'bookings/og1/amendment-2.pdf', 'amend-v1') ->> 'id')::uuid;
select app.sign_booking_amendment(test.og('a2'), test.id('og_rita'), 'I agree to this amendment.', repeat('e', 64), null, 'bookings/og1/sig.png');
select app.accept_booking_change_apply(test.og('c2'), test.id('og_rita'));
select test.eq('price: applied on the other car, the rental charge as proposed, a refund waiting for an Admin, numbered A2',
  (select (b.vehicle_id = test.id('vehicle:OGB')) || '/' || b.rental_charge_cents || '/' || r.status || '/' || (r.amount_cents = -c.total_difference_cents) || '/' || a.amendment_number
     from booking_change_requests c join bookings b on b.id = c.booking_id join refunds r on r.id = c.refund_id join booking_amendments a on a.id = test.og('a2') where c.id = test.og('c2')),
  'true/20000/pending_approval/true/OG-1-A2');
select app.process_events(100000);
select test.eq('price: the renter is told the difference goes back to their card', (select payload ->> 'money_text' like '%goes back to your card%' from notification_outbox where code = 'renter_change_applied' and entity_id = test.og('c2')), true);

-- the renter says no
insert into test.og select 'c3', (app.propose_booking_change(test.id('og_cs'), jsonb_build_object('booking', 'OG-2', 'pickup_at', test.og_at('2027-04-05 14:00'), 'note', 'Can we hand over at 2 pm?')) ->> 'id')::uuid;
insert into test.og select 'a3', (app.open_booking_amendment(test.og('c3'), test.id('og_ray'), repeat('f', 64), 'bookings/og2/amendment-1.pdf', 'amend-v1') ->> 'id')::uuid;
select test.throws('decline: only the renter declines', format('select app.renter_decline_booking_change(%L, %L, %L)', test.og('c3'), test.id('og_rita'), 'no'), 'Only the renter');
select app.renter_decline_booking_change(test.og('c3'), test.id('og_ray'), 'I need the morning pickup');
select test.eq('decline: the change is declined with the renter''s words, the booking stays, the open amendment is voided, customer service hears',
  (select c.status || '/' || c.decline_reason || '/' || (b.pickup_at = test.og_at('2027-04-05 10:00')) || '/' || a.status || '/' ||
          (select count(*) from app_events e where e.code = 'staff_change_proposal_answered' and e.entity_id = c.id)
     from booking_change_requests c join bookings b on b.id = c.booking_id join booking_amendments a on a.id = test.og('a3') where c.id = test.og('c3')),
  'declined/Declined by the renter: I need the morning pickup/true/voided/1');

-- a proposal not answered: a reminder, then it expires
insert into test.og select 'c4', (app.propose_booking_change(test.id('og_cs'), jsonb_build_object('booking', 'OG-2', 'return_at', test.og_at('2027-04-08 10:00'), 'note', 'One more day at no charge?', 'rental_charge_cents', 20000)) ->> 'id')::uuid;
update booking_change_requests set created_at = now() - interval '40 hours', accept_by = now() + interval '8 hours' where id = test.og('c4');
select test.eq('sweep: inside the reminder window the renter is reminded once', (app.booking_change_sweep(now()) ->> 'reminded')::int, 1);
select test.eq('sweep: not twice', (app.booking_change_sweep(now()) ->> 'reminded')::int, 0);
select test.eq('sweep: the reminder email is queued', (select count(*) from app_events where code = 'renter_change_proposal_reminder' and entity_id = test.og('c4')), 1::bigint);
select test.eq('sweep: after the deadline the change expires', (app.booking_change_sweep(now() + interval '9 hours') ->> 'expired')::int, 1);
select test.eq('sweep: the booking stays as it was', (select status from booking_change_requests where id = test.og('c4'))
  || '/' || (select return_at = test.og_at('2027-04-07 12:00') from bookings where id = test.id('booking:OG-2')), 'expired/true');
select test.eq('sweep: the renter and customer service are told; the task is closed',
  (select count(*) from app_events where entity_id = test.og('c4') and code in ('renter_change_proposal_expired', 'staff_change_proposal_answered')) || '/' ||
  (select count(*) from tasks where task_type = 'booking_change_approval' and booking_id = test.id('booking:OG-2') and status = 'open'), '2/0');
select test.eq('job: the wrapper runs once per slot', app.job_booking_changes(now()) in ('succeeded', 'not_due'), true);
select test.throws('expired: nothing to sign', format('select app.open_booking_amendment(%L, %L, %L, %L, %L)', test.og('c4'), test.id('og_ray'), repeat('a', 64), 'x.pdf', 'v'), 'no longer waiting');

-- the calendar's "agreed by phone" path: applied at once, no proposal email, the amendment recorded
select app.calendar_apply_change(test.id('booking:OG-2'), test.id('og_admin'), jsonb_build_object('pickup_at', test.og_at('2027-04-05 09:00')), 'Renter called to come an hour early', true);
select test.eq('phone: applied, the amendment recorded without a document, no proposal email',
  (select c.status || '/' || a.status || '/' || (a.document_id is null) || '/' || (select count(*) from app_events e where e.code = 'renter_change_proposed' and e.entity_id = c.id)
     from booking_change_requests c join booking_amendments a on a.change_request_id = c.id where c.booking_id = test.id('booking:OG-2') and c.status = 'applied'),
  'applied/recorded/true/0');

-- ---------------------------------------------------------------- 4. the listing similarity check
insert into vehicles (id, owner_id, fleet_number, year, make, model, colour, vin, plate, class, status, management_mode, onboarding_method)
values (test.id('vehicle:OGP'), test.id('owner:og_oscar'), 'F-OGP', 2022, 'Kia', 'Soul', 'Grey', upper(substr(md5('OGP'), 1, 16)) || 'Z',
        (select plate from vehicles where id = test.id('vehicle:OGA')), 'standard', 'onboarding', 'managed', 'transfer');
select test.eq('similar: the same plate as a car on file is a flag that stops publishing, and Fleet has a task',
  (select f.kind || '/' || f.blocking || '/' || f.status || '/' || (f.other_vehicle_id = test.id('vehicle:OGA')) || '/' ||
          (select count(*) from tasks t where t.task_type = 'listing_similarity' and t.vehicle_id = f.vehicle_id and t.status = 'open')
     from listing_similarity_flags f where f.vehicle_id = test.id('vehicle:OGP') and f.kind = 'plate'), 'plate/true/open/true/1');
update vehicles set vin = '1M8GDM9AXKP042788' where id = test.id('vehicle:OGC');  -- a real VIN (its check digit is right)
insert into vehicles (id, owner_id, fleet_number, year, make, model, colour, vin, plate, class, status, management_mode, onboarding_method)
values (test.id('vehicle:OGV'), test.id('owner:og_oscar'), 'F-OGV', 2021, 'Ford', 'Escape', 'Blue', overlay((select vin from vehicles where id = test.id('vehicle:OGC')) placing 'X' from 17 for 1),
        'OGVPLT1', 'standard', 'onboarding', 'managed', 'transfer');
select test.eq('similar: a VIN one character from another is flagged', (select count(*) from listing_similarity_flags where vehicle_id = test.id('vehicle:OGV') and kind = 'vin' and blocking), 1::bigint);
select test.eq('similar: placeholder VINs one character apart are not (neither has a right check digit); a real VIN is recognised',
  app.vin_near('SAMPLE01XXXXXXXXX', 'SAMPLE02XXXXXXXXX') || '/' || app.vin_near('SAMPLE01XXXXXXXXX', 'SAMPLE01XXXXXXXXX') || '/' || app.vin_check_ok('1M8GDM9AXKP042788') || '/' || app.vin_check_ok('1M8GDM9AXKP042789'), 'false/true/true/false');
-- 0041: sample cars (placeholders) are never compared, even with VINs one character from a real one
insert into vehicles (id, owner_id, fleet_number, year, make, model, colour, vin, plate, class, status, management_mode, onboarding_method, is_sample)
values (test.id('vehicle:OGS1'), test.id('owner:og_oscar'), 'F-OGS1', 2020, 'Kia', 'Rio', 'Teal', '11111111111111111', 'OGSMP01', 'standard', 'onboarding', 'managed', 'transfer', true),
       (test.id('vehicle:OGS2'), test.id('owner:og_oscar'), 'F-OGS2', 2020, 'Kia', 'Rio', 'Teal', '11111111111111112', 'OGSMP02', 'standard', 'onboarding', 'managed', 'transfer', true);
select test.eq('similar: sample cars are not compared (0041)',
  (select count(*) from listing_similarity_flags where test.id('vehicle:OGS1') in (vehicle_id, other_vehicle_id) or test.id('vehicle:OGS2') in (vehicle_id, other_vehicle_id)), 0::bigint);
update vehicles set year = 2023, make = 'Mercedes-Benz', model = 'C 300 OGA', colour = 'Black' where id in (test.id('vehicle:OGA'));
insert into vehicles (id, owner_id, fleet_number, year, make, model, colour, vin, plate, class, status, management_mode, onboarding_method)
values (test.id('vehicle:OGS'), test.id('owner:og_olive'), 'F-OGS', 2023, 'Mercedes-Benz', 'C 300 OGA', 'Black', upper(substr(md5('OGS-x'), 1, 17)), 'OGSPLT1', 'premium', 'onboarding', 'managed', 'transfer'),
       (test.id('vehicle:OGT'), test.id('owner:og_oscar'), 'F-OGT', 2023, 'Mercedes-Benz', 'C 300 OGA', 'Black', upper(substr(md5('OGT-x'), 1, 17)), 'OGTPLT1', 'premium', 'onboarding', 'managed', 'transfer');
select test.eq('similar: same year, make, model and colour is shown to the reviewer without stopping publishing (a fleet may hold twins), whoever the owner',
  (select blocking::text from listing_similarity_flags where vehicle_id = test.id('vehicle:OGS') and kind = 'specs' and other_vehicle_id = test.id('vehicle:OGA')) || '/' ||
  (select blocking::text from listing_similarity_flags where vehicle_id = test.id('vehicle:OGT') and kind = 'specs' and other_vehicle_id = test.id('vehicle:OGA')), 'false/false');
-- copy: a listed car and a new draft almost the same
select app.ensure_listing(test.id('vehicle:OGC'));
update vehicle_listings set status = 'published', slug = 'og-ford-escape', headline = 'Roomy Ford Escape for city and highway',
       description = 'This Ford Escape seats five with room for luggage, heated seats, Apple CarPlay and a quiet ride on the highway. Pickup in Toronto or delivery to your door.'
 where vehicle_id = test.id('vehicle:OGC');
insert into listing_drafts (vehicle_id, source, headline, description) values (test.id('vehicle:OGV'), 'ai', 'Roomy Ford Escape for city and highway',
  'This Ford Escape seats five with room for luggage, heated seats, Apple CarPlay and a quiet ride on the highway. Pickup in Toronto or delivery to your door today.');
select test.eq('similar: drafted copy almost the same as a listed car is flagged with its score',
  (select kind || '/' || blocking || '/' || (score_bps >= 6000) from listing_similarity_flags where vehicle_id = test.id('vehicle:OGV') and kind = 'copy'), 'copy/true/true');
select test.eq('similar: unrelated copy is not', app.jaccard_bps(app.copy_shingles('A small red hatchback for weekend trips'), app.copy_shingles('Seven seat van with sliding doors and big trunk')), 0);
-- photo: the same image as a listed car's photo
insert into vehicle_photos (vehicle_id, angle, original_path, status, content_sha256) values (test.id('vehicle:OGC'), 'front', 'vehicles/ogc/front.jpg', 'approved', repeat('9', 64));
insert into vehicle_photos (vehicle_id, angle, original_path, status, content_sha256) values (test.id('vehicle:OGS'), 'front', 'vehicles/ogs/front.jpg', 'uploaded', repeat('9', 64));
select test.eq('similar: the same photo as a listed car''s is flagged', (select count(*) from listing_similarity_flags where vehicle_id = test.id('vehicle:OGS') and kind = 'photo' and blocking), 1::bigint);
select test.ok('publish: an open flag is a warning since 0070 (only a confirmed duplicate keeps a car off)', (select bool_or(x ->> 'code' = 'similar') from jsonb_array_elements(app.vehicle_listing_warnings(test.id('vehicle:OGV'))) x));
select test.throws('decide: a note is needed', format('select app.decide_similarity(%L, %L, %L, %L)', test.id('og_fleet'),
  (select id from listing_similarity_flags where vehicle_id = test.id('vehicle:OGV') and kind = 'vin'), 'cleared', ''), 'what you checked');
select test.throws('decide: Finance does not decide', format('select app.decide_similarity(%L, %L, %L, %L)', test.id('og_fin'),
  (select id from listing_similarity_flags where vehicle_id = test.id('vehicle:OGV') and kind = 'vin'), 'cleared', 'checked'), 'Fleet');
select app.decide_similarity(test.id('og_fleet'), id, 'cleared', 'Different cars: checked both permits') from listing_similarity_flags where vehicle_id = test.id('vehicle:OGV') and status = 'open';
select test.eq('decide: cleared flags stay cleared when the car is checked again', app.check_listing_similarity(test.id('vehicle:OGV'), 'all'), 0);
select test.eq('decide: the task closes once no flag stops publishing',
  (select count(*) from tasks where task_type = 'listing_similarity' and vehicle_id = test.id('vehicle:OGV') and status = 'open'), 0::bigint);
do $$
begin
  perform app.publish_listing(test.id('vehicle:OGV'), test.id('og_admin'));
  perform test.ok('publish: with the flags cleared the duplicate check passes', true);
exception when others then
  perform test.ok('publish: with the flags cleared the duplicate check passes (the next refusal is the listing''s own)', sqlerrm not ilike '%duplicate%', sqlerrm);
end $$;
select test.eq('read: the vehicle''s flags with the other car''s name', (select count(*) from jsonb_array_elements(app.vehicle_similarity(test.id('vehicle:OGP'))) x where x ->> 'other_vehicle_name' like '%C 300%'), 1::bigint);
select test.eq('email: Fleet is told about a new possible duplicate', (select count(*) from app_events where code = 'staff_listing_similarity') >= 3, true);

-- ---------------------------------------------------------------- 5. earlier requests on a verified sign-in
select test.mk_renter('og_nora', false);
select test.mk_booking('OG-5', 'OGC', 'og_nora', '2027-05-03 10:00', '2027-05-05 10:00', 'requested');
insert into users (id, email, full_name) values (test.id('og_nora_login'), 'og_nora@example.test', 'Og Nora');
select test.throws('link: nothing is attached before the address is verified', format('select app.account_link_earlier(%L)', test.id('og_nora_login')), 'Confirm your email');
select test.eq('link: a confirmation for another address does nothing', app.account_email_verified(test.id('og_nora_login'), 'someone@example.test') ->> 'reason', 'email_mismatch');
select test.eq('link: once verified, the earlier renter record and its request are attached',
  (select (v ->> 'renter_records') || '/' || (v ->> 'bookings') from app.account_email_verified(test.id('og_nora_login'), 'OG_Nora@example.test') v), '1/1');
select test.eq('link: the renter record is this sign-in''s now, with the renter role',
  (select (r.user_id = test.id('og_nora_login')) || '/' || exists (select 1 from user_roles x where x.user_id = r.user_id and x.role = 'renter') from renters r where r.id = test.id('renter:og_nora')), 'true/true');
select test.eq('link: the portal lists the request that was added', jsonb_array_length(app.my_account_links(test.id('og_nora_login')) -> 'new'), 1);
select test.eq('link: marked seen (the record and the request)', app.seen_account_links(test.id('og_nora_login')), 2);
select test.eq('link: and not listed again', jsonb_array_length(app.my_account_links(test.id('og_nora_login')) -> 'new'), 0);
select test.eq('link: a second verification attaches nothing new', (app.account_email_verified(test.id('og_nora_login'), 'og_nora@example.test') ->> 'bookings')::int, 0);
-- an additional driver on someone else's booking signs up later
insert into drivers (id, renter_id, is_account_holder, full_name, date_of_birth, licence_class, licence_issuer, email)
values (test.id('driver:og_dina'), test.id('renter:og_rita'), false, 'Og Dina', date '1991-01-01', 'G', 'ON', 'og_dina@example.test');
insert into users (id, email, full_name, email_verified_at) values (test.id('og_dina_login'), 'og_dina@example.test', 'Og Dina', now());
select test.eq('link: the driver place is attached to the driver''s sign-in', (app.account_link_earlier(test.id('og_dina_login')) ->> 'drivers')::int, 1);
-- a sign-in with its own renter record and an older one under the same address: customer service decides
select test.mk_renter('og_twin', true);
insert into renters (id, legal_name, email) values (test.id('renter:og_twin_old'), 'Og Twin', 'og_twin@example.test');
update users set email_verified_at = now() where id = test.id('og_twin');
select test.eq('link: two records for one address go to customer service', (app.account_link_earlier(test.id('og_twin')) ->> 'needs_staff'), '1');
select test.eq('link: with a task to check them', (select count(*) from tasks where task_type = 'account_link_review' and renter_id = test.id('renter:og_twin_old')), 1::bigint);

-- ---------------------------------------------------------------- 6. the additional driver's link
insert into documents (id, kind, title, storage_bucket, storage_path, sha256) values (test.id('doc:og_ra'), 'rental_agreement', 'RA', 'agreements', 'bookings/og2/ra.pdf', repeat('1', 64));
insert into signature_requests (id, document_id, provider, status) values (test.id('sr:og_ra'), test.id('doc:og_ra'), 'builtin', 'completed');
insert into rental_agreements (id, booking_id, agreement_number, template_version, document_id, document_sha256, signature_request_id, status, countersigner_name, renter_signed_at, completed_at)
values (test.id('ra:og2'), test.id('booking:OG-2'), 'RA-OG-2', 'rental-test', test.id('doc:og_ra'), repeat('1', 64), test.id('sr:og_ra'), 'completed', 'Og Cs', now(), now());
insert into drivers (id, renter_id, is_account_holder, full_name, date_of_birth, licence_class, licence_issuer, email)
values (test.id('driver:og_dan'), test.id('renter:og_ray'), false, 'Og Dan', date '1992-02-02', 'G', 'ON', 'og_dan@example.test');
insert into rental_agreement_signers (id, agreement_id, signer_role, driver_id, signer_name, signer_email)
values (test.id('signer:og_dan'), test.id('ra:og2'), 'additional_driver', test.id('driver:og_dan'), 'Og Dan', 'og_dan@example.test'),
       (test.id('signer:og_ray'), test.id('ra:og2'), 'renter', null, 'Og Ray', 'og_ray@example.test');
select test.eq('driver link: version 1, valid for the hours in settings',
  (select link_version || '/' || (link_expires_at between now() + interval '71 hours' and now() + interval '73 hours') from rental_agreement_signers where id = test.id('signer:og_dan')), '1/true');
select test.eq('driver link: a version 1 token is valid, another is not', app.driver_link_valid(test.id('signer:og_dan'), 1) || '/' || app.driver_link_valid(test.id('signer:og_dan'), 2), 'true/false');
select test.throws('driver link: another renter cannot renew it', format('select app.driver_link_renew(%L, %L)', test.id('signer:og_dan'), test.id('og_rita')), 'Only the renter');
select test.throws('driver link: Fleet cannot either', format('select app.driver_link_renew(%L, %L)', test.id('signer:og_dan'), test.id('og_fleet')), 'Only the renter');
select test.eq('driver link: the renter makes a new one', (app.driver_link_renew(test.id('signer:og_dan'), test.id('og_ray')) ->> 'version'), '2');
select test.eq('driver link: the old link stops working', app.driver_link_valid(test.id('signer:og_dan'), 1) || '/' || app.driver_link_valid(test.id('signer:og_dan'), 2), 'false/true');
select test.throws('driver link: an older version is not sent', format('select app.driver_link_send(%L, %L, 1, %L)', test.id('signer:og_dan'), test.id('og_ray'), 'https://carmacars.ca/sign/driver/abc.def'), 'newer link');
select test.throws('driver link: only a signing link is sent', format('select app.driver_link_send(%L, %L, 2, %L)', test.id('signer:og_dan'), test.id('og_ray'), 'https://evil.example/x'), 'not a signing link');
select app.driver_link_send(test.id('signer:og_dan'), test.id('og_cs'), 2, 'https://carmacars.ca/sign/driver/abc.def');
select test.eq('driver link: customer service sent it; counted; the email goes to the driver with the link',
  (select link_sent_count || '/' || (link_sent_by = test.id('og_cs')) from rental_agreement_signers where id = test.id('signer:og_dan')) || '/' ||
  (select count(*) from app_events where code = 'renter_driver_link' and entity_id = test.id('signer:og_dan')), '1/true/1');
select app.process_events(100000);
select test.eq('driver link: the email is to the driver, by first name, with the link and its expiry',
  (select to_address || '/' || (payload ->> 'first_name') || '/' || (payload ->> 'sign_url') || '/' || (payload ->> 'link_expires' <> '') from notification_outbox where code = 'renter_driver_link' and to_address = 'og_dan@example.test'),
  'og_dan@example.test/Og/https://carmacars.ca/sign/driver/abc.def/true');
update rental_agreement_signers set link_expires_at = now() - interval '1 minute' where id = test.id('signer:og_dan');
select test.eq('driver link: an expired link is not valid', app.driver_link_valid(test.id('signer:og_dan'), 2), false);
select test.eq('driver links: the booking''s list shows it expired', (select (x ->> 'expired') from jsonb_array_elements(app.booking_driver_links(test.id('booking:OG-2'))) x), 'true');
select app.emit_event('renter_agreement_ready', 'rental_agreement', test.id('ra:og2'),
  jsonb_build_object('booking_id', test.id('booking:OG-2'), 'signers', jsonb_build_array(
    jsonb_build_object('signer_role', 'renter', 'signer_email', 'og_ray@example.test', 'signer_name', 'Og Ray'),
    jsonb_build_object('signer_role', 'additional_driver', 'signer_email', 'og_dan@example.test', 'signer_name', 'Og Dan'))), 'renter_agreement_ready:og2:test');
select app.process_events(100000);
select test.eq('driver link: the "agreement ready" email goes to the renter only (the driver signs through their link)',
  (select string_agg(to_address, ',') from notification_outbox where code = 'renter_agreement_ready' and entity_id = test.id('ra:og2')), 'og_ray@example.test');

-- ---------------------------------------------------------------- 7. Forms C and D
select test.mk_vehicle('OGF', 'og_oscar');
insert into vehicle_onboardings (vehicle_id, status) values (test.id('vehicle:OGF'), 'terms_set');
update vehicle_schedules set title_status = 'financed', finance_party_name = 'Test Bank', finance_party_account = '1234', finance_permission = 'attached'
 where vehicle_id = test.id('vehicle:OGF');
select test.eq('forms: Oscar needs one Form D and a Form C for the financed car',
  (select string_agg(x ->> 'code' || ':' || (x ->> 'status'), ',' order by x ->> 'code') from jsonb_array_elements(public.owner_witnessed_forms(test.id('og_oscar'))) x), 'C:needed,D1:needed');
select test.eq('forms: the checklist shows them as the owner''s step',
  (select status || '/' || waits_on || '/' || next_action from app.onboarding_checklist(test.id('vehicle:OGF')) where code = 'witnessed_forms'), 'open/owner/Upload Form D and Form C');
select test.throws('forms: Form D needs both witnesses', format('select app.owner_upload_witnessed_form(%L, %L)', test.id('og_oscar'),
  jsonb_build_object('code', 'D1', 'witness_1_name', 'Wendy Witness', 'path', 'owners/x/d.pdf', 'sha256', repeat('2', 64), 'mime', 'application/pdf')), 'both witnesses');
select test.throws('forms: a form that is not needed is refused', format('select app.owner_upload_witnessed_form(%L, %L)', test.id('og_oscar'),
  jsonb_build_object('code', 'C', 'vehicle_id', test.id('vehicle:OGC'), 'witness_1_name', 'W', 'path', 'x.pdf', 'sha256', repeat('2', 64), 'mime', 'application/pdf')), 'not needed');
insert into test.og select 'fd', (app.owner_upload_witnessed_form(test.id('og_oscar'), jsonb_build_object('code', 'D1', 'witness_1_name', 'Wendy Witness', 'witness_2_name', 'Will Witness',
  'path', 'owners/og/d1.pdf', 'sha256', repeat('2', 64), 'mime', 'application/pdf')) ->> 'id')::uuid;
insert into test.og select 'fc', (app.owner_upload_witnessed_form(test.id('og_oscar'), jsonb_build_object('code', 'C', 'vehicle_id', test.id('vehicle:OGF'), 'witness_1_name', 'Wendy Witness',
  'path', 'owners/og/c.jpg', 'sha256', repeat('3', 64), 'mime', 'image/jpeg')) ->> 'id')::uuid;
select test.eq('forms: uploaded, kept with the document and the witnesses, a review task each, customer service told',
  (select string_agg(f.status || ':' || d.kind || ':' || coalesce(f.witness_2_name, '-'), ',' order by f.form_code) from owner_agreement_forms f join documents d on d.id = f.document_id
    where f.id in (test.og('fd'), test.og('fc'))) || '/' ||
  (select count(*) from tasks where task_type = 'owner_form_review' and status = 'open' and related_id in (test.og('fd'), test.og('fc'))) || '/' ||
  (select count(*) from app_events where code = 'staff_owner_form_uploaded' and entity_id in (test.og('fd'), test.og('fc'))),
  'uploaded:form_c_finance_permission_ack:-,uploaded:form_d_power_of_attorney:Will Witness/2/2');
select test.eq('forms: the checklist now waits on CarmaCars', (select waits_on || '/' || next_action from app.onboarding_checklist(test.id('vehicle:OGF')) where code = 'witnessed_forms'), 'carmacars/Review the uploaded forms');
select test.throws('review: Fleet does not review', format('select app.review_witnessed_form(%L, %L, true)', test.id('og_fleet'), test.og('fc')), 'customer service or an Admin');
select test.throws('review: sending back needs the reason', format('select app.review_witnessed_form(%L, %L, false, %L)', test.id('og_cs'), test.og('fc'), ''), 'what to fix');
select app.review_witnessed_form(test.id('og_cs'), test.og('fc'), false, 'The witness did not sign next to the third initials.');
select app.review_witnessed_form(test.id('og_admin'), test.og('fd'), true);
select test.eq('review: one sent back with its reason, one approved; the owner sees both; emails each way',
  (select string_agg(x ->> 'code' || ':' || (x ->> 'status') || ':' || coalesce(x ->> 'reject_reason', '-'), ',' order by x ->> 'code') from jsonb_array_elements(public.owner_witnessed_forms(test.id('og_oscar'))) x)
  || '/' || (select count(*) from app_events where code in ('owner_form_approved', 'owner_form_rejected') and entity_id in (test.og('fd'), test.og('fc'))),
  'C:rejected:The witness did not sign next to the third initials.,D1:approved:-/2');
insert into test.og select 'fc2', (app.owner_upload_witnessed_form(test.id('og_oscar'), jsonb_build_object('code', 'C', 'vehicle_id', test.id('vehicle:OGF'), 'witness_1_name', 'Wendy Witness',
  'path', 'owners/og/c2.jpg', 'sha256', repeat('4', 64), 'mime', 'image/jpeg')) ->> 'id')::uuid;
select app.review_witnessed_form(test.id('og_cs'), test.og('fc2'), true);
select test.eq('review: uploaded again and approved, the checklist item is done', (select status from app.onboarding_checklist(test.id('vehicle:OGF')) where code = 'witnessed_forms'), 'done');
select test.throws('review: an approved form is not reviewed again', format('select app.review_witnessed_form(%L, %L, true)', test.id('og_cs'), test.og('fc2')), 'not waiting');
select app.process_events(100000);
select test.eq('email: the owner reads the reason', (select payload ->> 'reject_reason' from notification_outbox where code = 'owner_form_rejected' and entity_id = test.og('fc')), 'The witness did not sign next to the third initials.');
select test.eq('facts: the pre-filled Form C names the car, its lender and the company',
  (select (v -> 'vehicles' -> 0 ->> 'finance_party') || '/' || jsonb_array_length(v -> 'vehicles') || '/' || (v -> 'company' ? 'legal_name')
     from public.server_witnessed_form_facts(test.id('og_oscar'), 'C', test.id('vehicle:OGF')) v), 'Test Bank/1/true');
select test.eq('queue: staff see the forms, the latest first', (select count(*) from jsonb_array_elements(app.witnessed_forms_queue()) x where x ->> 'owner_name' = 'Og Oscar'), 3::bigint);

-- ---------------------------------------------------------------- 8. the doors
select test.eq('door: customer service previews and proposes through the door',
  (app.door(test.id('og_cs'), 'aal1', 'va_read', 'change_preview', jsonb_build_object('booking', 'OG-2', 'return_at', test.og_at('2027-04-08 10:00'))) ->> 'ok'), 'true');
select test.eq('door: an Admin reads the similar cars', jsonb_array_length(app.door(test.id('og_admin'), 'aal1', 'admin_read', 'similar_cars', '{}')) >= 3, true);
select test.throws('door: an assistant cannot use the Admin door', format('select app.door(%L, %L, %L, %L, %L)', test.id('og_cs'), 'aal1', 'admin_read', 'similar_cars', '{}'), 'Admin');
select test.throws('door: Finance cannot review forms', format('select app.door(%L, %L, %L, %L, %L)', test.id('og_fin'), 'aal1', 'va_read', 'owner_forms_queue', '{}'), 'Not permitted');
select test.eq('door: Fleet removes a cleaning block through the door',
  (app.door(test.id('og_fleet'), 'aal1', 'va_do', 'turnaround_block_remove', jsonb_build_object('block', (select id from vehicle_calendar_blocks where booking_id = test.id('booking:OG-1')),
     'reason', 'Car was detailed early')) ->> 'removed'), 'true');
select test.eq('door: the other calls still go to the doors before', (app.door(test.id('og_admin'), 'aal1', 'roles', null, '{}') ->> 'admin'), 'true');

-- ---------------------------------------------------------------- 9. emails and privileges
select test.eq('catalogue: the eleven emails of 0040 are in the catalogue with their templates',
  (select count(*) from notification_catalogue where code in ('renter_change_proposed', 'renter_change_proposal_reminder', 'renter_change_proposal_expired', 'renter_change_applied',
     'owner_booking_changed', 'staff_change_proposal_answered', 'renter_driver_link', 'staff_listing_similarity', 'staff_owner_form_uploaded', 'owner_form_approved', 'owner_form_rejected')
     and template_html is not null and emitted_by is not null), 11::bigint);
select test.eq('privileges: the server functions are not open to a browser',
  (select bool_or(has_function_privilege(r, f, 'execute')) from unnest(array['anon', 'authenticated']) r,
     unnest(array['public.server_change_facts(uuid,uuid)', 'public.renter_sign_amendment(uuid,uuid,text,text,text,text,inet,text)', 'public.server_account_email_verified(uuid,text)',
                  'public.server_driver_link_send(uuid,uuid,integer,text)', 'public.owner_upload_witnessed_form(uuid,jsonb)', 'app.propose_booking_change(uuid,jsonb)',
                  'app.door(uuid,text,text,text,jsonb)', 'app.publish_listing(uuid,uuid)']::regprocedure[]) f), false);
select test.eq('rls: every new table has row-level security',
  (select bool_and(c.relrowsecurity) from pg_class c where c.relname in ('booking_amendments', 'listing_similarity_flags', 'account_links') and c.relnamespace = 'public'::regnamespace), true);
select test.login(test.id('og_rita'));
select test.eq('rls: a renter reads their own amendments', test.visible(format('select 1 from booking_amendments where booking_id = %L', test.id('booking:OG-1'))), 2::bigint);
select test.logout();
select test.login(test.id('og_ray'));
select test.eq('rls: and not another renter''s', test.visible(format('select 1 from booking_amendments where booking_id = %L', test.id('booking:OG-1'))), 0::bigint);
select test.logout();
