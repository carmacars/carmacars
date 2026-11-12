-- 99: release 35 part A (migrations 1300 to 1309, docs/changes/2026-11-11-r35a-request-offers.md): the original request and
-- the offer history with "Revert to this offer", the coverage card, Book it now waiting for an Admin, the owner's own trip
-- badge and alert, the renter's secondary contact, and the rideshare documents. Uses the helpers of 06 (test.rq_new, test.b,
-- test.st) and 82 (test.ho_local). Fixtures start with "ra" and "RA".
select test.suite('99 r35a request and offers');

select test.mk_user('ra_admin', 'admin');
select test.mk_user('ra_cs', 'va', 'cs');
select test.mk_user('ra_sales', 'va', 'sales');
select test.mk_user('ra_fleet', 'va', 'fleet');
select test.mk_user('ra_fin', 'va', 'finance');
select test.mk_owner('ra_o');
select test.mk_vehicle('RAV', 'ra_o');
select test.mk_vehicle('RAW', 'ra_o');
select test.mk_renter('ra_r');
select test.mk_renter('ra_q');
create function test.ra_read(p_user text, p_name text, p jsonb) returns jsonb language sql as $$
  select public.door(test.id(p_user), 'aal2', 'ops_read', p_name, p) $$;

-- ---------------------------------------------------------------- 1. the request as sent, kept as sent
select test.rq_new('raA', 'ra_r', 'RAV', test.ho_local(interval '5 days'), test.ho_local(interval '8 days'));
-- changed after the request: the request as sent keeps what the renter sent
update bookings set request_note = 'Typed later by staff', coverage_option = 2 where id = test.b('raA');
select test.eq('request: the request as sent is kept once, with the car, the dates and the price shown',
  (select s.source || ':' || (s.vehicle_id = test.id('vehicle:RAV')) || ':' || (s.pickup_at = b.pickup_at) || ':' || ((s.price ->> 'total_cents')::bigint = b.total_due_at_booking_cents)
          || ':' || ((s.price ->> 'total_cents')::bigint > 0) || ':' || jsonb_typeof(s.price -> 'lines')
     from booking_request_snapshots s join bookings b on b.id = s.booking_id where s.booking_id = test.b('raA')),
  'request:true:true:true:true:array');
create temp table ra_t0 as select total_due_at_booking_cents t from bookings where id = test.b('raA');
-- staff change the car, the dates and the price, and send two offers
select app.adjust_booking(test.b('raA'), test.id('ra_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:RAW'), 'staff_discount_cents', 5000, 'staff_discount_reason', 'Loyal'));
select app.send_offer(test.b('raA'), test.id('ra_sales'), 'First offer');
select app.offer_revise(test.id('ra_admin'), jsonb_build_object('booking', test.b('raA'), 'changes', jsonb_build_object('vehicle_id', test.id('vehicle:RAV'), 'staff_discount_cents', 0, 'deposit_cents', 50000),
  'message', 'Second offer', 'notify', false, 'expected_version', 1));
select test.eq('request: the request as sent does not follow the offers (car and price as the renter asked)',
  (select (vehicle_id = test.id('vehicle:RAV')) || ':' || ((price ->> 'total_cents')::bigint = (select t from ra_t0)) from booking_request_snapshots where booking_id = test.b('raA')),
  'true:true');
create temp table ra_h as select test.ra_read('ra_sales', 'request_history', jsonb_build_object('booking', test.b('raA'))) h;
select test.eq('history: Sales sees the original request, both offers (newest first, who sent them, the price lines) and the coverage',
  (select (h #>> '{original,vehicle_name}' is not null)::text || ':' || coalesce(h #>> '{original,note}', 'no note') || ':' || jsonb_array_length(h -> 'offers')
          || ':' || (h #>> '{offers,0,version}') || ':' || (h #>> '{offers,0,status}') || ':' || (h #>> '{offers,0,current}') || ':' || (h #>> '{offers,1,status}')
          || ':' || (h #>> '{offers,0,sent_by_name}') || ':' || (h #>> '{offers,1,sent_by_name}') || ':' || (jsonb_array_length(h #> '{offers,1,lines}') > 0)
          || ':' || ((h #>> '{offers,1,discount_cents}')::bigint >= 5000) || ':' || (h #>> '{coverage,short}') from ra_h),
  'true:no note:2:2:sent:true:superseded:Ra Admin:Ra Sales:true:true:Credit card coverage');
select test.eq('history: customer service and Fleet see it too',
  (test.ra_read('ra_cs', 'request_history', jsonb_build_object('booking', test.b('raA'))) ->> 'booking_number') is not null
  and (test.ra_read('ra_fleet', 'request_history', jsonb_build_object('booking', test.b('raA'))) ->> 'booking_number') is not null, true);
select test.throws('history: Finance does not',
  format($$select test.ra_read('ra_fin', 'request_history', jsonb_build_object('booking', %L))$$, test.b('raA')), 'Sales or Fleet sees');
select test.throws('history: a renter does not',
  format($$select test.ra_read('ra_r', 'request_history', jsonb_build_object('booking', %L))$$, test.b('raA')), 'Sales or Fleet sees');

-- ---------------------------------------------------------------- 2. revert to an old offer: the changes, nothing applied
create temp table ra_rv as select test.ra_read('ra_cs', 'offer_revert', jsonb_build_object('booking', test.b('raA'), 'version', 1)) r;
select test.eq('revert: version 1''s car, dates, discount and deposit come back as changes to review; the booking is unchanged',
  (select (r #>> '{changes,vehicle_id}') || ':' || (r #>> '{changes,staff_discount_cents}') || ':' || (r #>> '{changes,deposit_cents}') || ':' || (r ->> 'version')
          || ':' || (r ->> 'message' like 'Back to the offer of%version 1%') from ra_rv)
  || '/' || (select current_offer_version || ':' || deposit_cents || ':' || staff_discount_cents from bookings where id = test.b('raA')),
  test.id('vehicle:RAW')::text || ':5000:100000:1:true/2:50000:0');
select test.throws('revert: the offer out now is not an old one',
  format($$select test.ra_read('ra_cs', 'offer_revert', jsonb_build_object('booking', %L, 'version', 2))$$, test.b('raA')), 'offer out now');
select test.throws('revert: a version that does not exist',
  format($$select test.ra_read('ra_cs', 'offer_revert', jsonb_build_object('booking', %L, 'version', 9))$$, test.b('raA')), 'no offer version 9');
select test.throws('revert: Fleet does not send offers',
  format($$select test.ra_read('ra_fleet', 'offer_revert', jsonb_build_object('booking', %L, 'version', 1))$$, test.b('raA')), 'sends offers');
select test.eq('revert: Fleet sees the history without the revert', (test.ra_read('ra_fleet', 'request_history', jsonb_build_object('booking', test.b('raA'))) ->> 'may_revert'), 'false');
-- applying the changes and sending makes version 3 with version 1's price
select app.offer_revise(test.id('ra_admin'), jsonb_build_object('booking', test.b('raA'), 'changes', (select r -> 'changes' from ra_rv) - 'rental_charge_cents' - 'pickup_at' - 'return_at',
  'message', (select r ->> 'message' from ra_rv), 'notify', false, 'expected_version', 2));
select test.eq('revert: sent, it is a new version with the old version''s total',
  (select version || ':' || (total_cents = (select total_cents from booking_offers where booking_id = test.b('raA') and version = 1)) from booking_offers where booking_id = test.b('raA') and version = 3),
  '3:true');
select test.mk_booking('RA-C1', 'RAV', 'ra_r', '2026-01-10 10:00', '2026-01-12 10:00', 'closed');
select test.throws('revert: a closed booking does not go back',
  format($$select test.ra_read('ra_cs', 'offer_revert', jsonb_build_object('booking', %L, 'version', 1))$$, test.id('booking:RA-C1')), 'being arranged');

-- ---------------------------------------------------------------- 3. the coverage card
select test.rq_new('raB', 'ra_q', 'RAW', test.ho_local(interval '10 days'), test.ho_local(interval '12 days'));
update bookings set coverage_option = 1 where id = test.b('raB');
select test.eq('coverage: own insurance with no proof yet', (select app.booking_coverage_card(test.b('raB')) ->> 'short') || '/' || (app.booking_coverage_card(test.b('raB')) ->> 'proof'),
  'Own insurance (OPCF 27)/missing');
insert into coverage_proofs (booking_id, coverage_option, status, insurer_name, policy_expiry) values (test.b('raB'), 1, 'submitted', 'Example Mutual', date '2030-01-01');
select test.eq('coverage: proof sent, waiting for review, with the insurer', (app.booking_coverage_card(test.b('raB')) ->> 'proof') || '/' || (app.booking_coverage_card(test.b('raB')) ->> 'detail'),
  'submitted/Example Mutual, valid to ' || app.fmt_day(date '2030-01-01'));
update coverage_proofs set status = 'rejected', rejection_reason = 'Policy expired' where booking_id = test.b('raB');
select test.eq('coverage: a rejected proof says why', app.booking_coverage_card(test.b('raB')) ->> 'proof_words', 'Proof rejected: Policy expired');
update bookings set coverage_option = 3 where id = test.b('raB');
select test.eq('coverage: the Protection Plan needs no proof', (app.booking_coverage_card(test.b('raB')) ->> 'short') || '/' || (app.booking_coverage_card(test.b('raB')) ->> 'proof'), 'Protection Plan/not_needed');

-- ---------------------------------------------------------------- 4. Book it now: staff ask, an Admin approves (0770, checked again)
select test.rq_new('raC', 'ra_q', 'RAV', test.ho_local(interval '20 days'), test.ho_local(interval '22 days'));
select app.send_offer(test.b('raC'), test.id('ra_cs'), 'Offer');
create temp table ra_bn as select app.offer_book_now(test.id('ra_sales'), test.b('raC'), 'Renter agreed by phone') r;
select test.eq('book it now: Sales asks, the booking stays an offer, an Admin has the alert and the To do',
  (select r ->> 'status' from ra_bn) || '/' || test.st('raC')
  || '/' || (select count(*) from app_events where code like 'staff_alert_%' and payload ->> 'rule' = 'override_requested' and entity_id = (select (r ->> 'id')::uuid from ra_bn))
  || '/' || (select count(*) from tasks where task_type = 'override_approve' and related_id = (select (r ->> 'id')::uuid from ra_bn) and status = 'open'),
  'requested/offered/1/1');
select test.throws('book it now: Sales does not approve it',
  format($$select public.door(%L, 'aal2', 'ops_do', 'override_decide', jsonb_build_object('id', %L, 'decision', 'approve'))$$, test.id('ra_sales'), (select r ->> 'id' from ra_bn)), 'An Admin approves');
select public.door(test.id('ra_admin'), 'aal2', 'ops_do', 'override_decide', jsonb_build_object('id', (select r ->> 'id' from ra_bn), 'decision', 'approve'));
select test.eq('book it now: approved by an Admin, it runs: waiting for payment', test.st('raC'), 'pending_payment');

-- ---------------------------------------------------------------- 5. the owner's own trip
select app.owner_book_own_vehicle(test.id('ra_o'), test.id('vehicle:RAW'), test.at(test.ho_local(interval '30 days')), test.at(test.ho_local(interval '31 days')), 'Family trip', null, null);
create temp table ra_ow as select id from bookings where vehicle_id = test.id('vehicle:RAW') and booking_type = 'owner' order by created_at desc limit 1;
select test.eq('owner trip: the staff alert says Owner''s own trip ($0); the To do too; the card carries owner_trip',
  (select count(*) from app_events where code like 'staff_alert_%' and payload ->> 'rule' = 'owner_trip_new' and entity_id = (select id from ra_ow) and payload ->> 'alert_title' like 'Owner''s own trip ($0):%')
  || '/' || (select count(*) from tasks where booking_id = (select id from ra_ow) and task_type = 'booking_request' and title like 'Owner''s own trip ($0): %')
  || '/' || (test.ra_read('ra_admin', 'booking_cards', jsonb_build_object('ids', jsonb_build_array((select id from ra_ow)))) #>> array[(select id from ra_ow)::text, 'owner_trip']),
  '1/1/true');
select test.eq('owner trip: a renter''s booking has no owner_trip and no such alert',
  coalesce(test.ra_read('ra_admin', 'booking_cards', jsonb_build_array()::jsonb || jsonb_build_object('ids', jsonb_build_array(test.b('raB')))) #>> array[test.b('raB')::text, 'owner_trip'], 'none')
  || '/' || (select count(*) from app_events where payload ->> 'rule' = 'owner_trip_new' and entity_id = test.b('raB')), 'none/0');
select test.eq('owner trip: the history and the coverage say so',
  (test.ra_read('ra_cs', 'request_history', jsonb_build_object('booking', (select id from ra_ow))) ->> 'owner_trip') || '/' || (app.booking_coverage_card((select id from ra_ow)) ->> 'proof'),
  'true/not_needed');

-- ---------------------------------------------------------------- 6. the secondary contact
select test.throws('secondary contact: a phone or an email is needed',
  format($$select public.server_secondary_contact_save(%L, '{"name": "Sam Doe", "relationship": "Brother"}'::jsonb)$$, test.id('ra_q')), 'phone number or an email');
select test.throws('secondary contact: the relationship is asked',
  format($$select public.server_secondary_contact_save(%L, '{"name": "Sam Doe", "phone": "416-555-0142"}'::jsonb)$$, test.id('ra_q')), 'related to you');
select public.server_secondary_contact_save(test.id('ra_q'), '{"name": "Sam Doe", "relationship": "Brother", "phone": "416-555-0142"}'::jsonb);
select test.eq('secondary contact: saved on the profile; staff see it on the booking, from the profile',
  (test.ra_read('ra_fin', 'secondary_contact', jsonb_build_object('booking', test.b('raB'))) ->> 'name') || '/' || (test.ra_read('ra_fin', 'secondary_contact', jsonb_build_object('booking', test.b('raB'))) ->> 'source'),
  'Sam Doe/profile');
select public.server_secondary_contact_save(test.id('ra_q'), jsonb_build_object('name', 'Alex Roe', 'relationship', 'Friend', 'email', 'alex@example.test', 'booking', test.b('raB')));
select test.eq('secondary contact: one booking''s own comes first, logged on it; the profile keeps its own',
  (test.ra_read('ra_cs', 'secondary_contact', jsonb_build_object('booking', test.b('raB'))) ->> 'name') || '/' || (test.ra_read('ra_cs', 'secondary_contact', jsonb_build_object('booking', test.b('raB'))) ->> 'source')
  || '/' || (select secondary_contact ->> 'name' from renters where id = test.id('renter:ra_q'))
  || '/' || (select count(*) from booking_events where booking_id = test.b('raB') and kind = 'secondary_contact'),
  'Alex Roe/booking/Sam Doe/1');
select test.throws('secondary contact: not on someone else''s booking',
  format($$select public.server_secondary_contact_save(%L, jsonb_build_object('name', 'X Y', 'relationship', 'Friend', 'phone', '4165550100', 'booking', %L))$$, test.id('ra_r'), test.b('raB')), 'Not permitted');
select test.throws('secondary contact: a renter does not read it through the staff door',
  format($$select test.ra_read('ra_q', 'secondary_contact', jsonb_build_object('booking', %L))$$, test.b('raB')), 'Staff only');
select public.server_secondary_contact_save(test.id('ra_q'), jsonb_build_object('name', '', 'booking', test.b('raB')));
select test.eq('secondary contact: removed from the booking, the profile''s shows again', test.ra_read('ra_cs', 'secondary_contact', jsonb_build_object('booking', test.b('raB'))) ->> 'source', 'profile');

-- ---------------------------------------------------------------- 7. the rideshare documents
select test.throws('rideshare: only for a booked trip (raB is a request)',
  format($$select public.server_rideshare_docs_request(%L, jsonb_build_object('booking', %L, 'platforms', jsonb_build_array('uber')))$$, test.id('ra_q'), test.b('raB')), 'booked trip');
-- raC is waiting for payment (Book it now above)
select test.throws('rideshare: a platform is picked',
  format($$select public.server_rideshare_docs_request(%L, jsonb_build_object('booking', %L, 'platforms', '[]'::jsonb))$$, test.id('ra_q'), test.b('raC')), 'at least one platform');
select test.throws('rideshare: "other" is named',
  format($$select public.server_rideshare_docs_request(%L, jsonb_build_object('booking', %L, 'platforms', jsonb_build_array('other')))$$, test.id('ra_q'), test.b('raC')), 'Name the other');
select test.throws('rideshare: not for someone else''s booking',
  format($$select public.server_rideshare_docs_request(%L, jsonb_build_object('booking', %L, 'platforms', jsonb_build_array('uber')))$$, test.id('ra_r'), test.b('raC')), 'Not permitted');
create temp table ra_rs as select public.server_rideshare_docs_request(test.id('ra_q'), jsonb_build_object('booking', test.b('raC'), 'platforms', jsonb_build_array('uber', 'doordash', 'other'), 'other', 'Skip')) r;
create temp table ra_rs2 as select public.server_rideshare_docs_request(test.id('ra_q'), jsonb_build_object('booking', test.b('raC'), 'platforms', jsonb_build_array('doordash', 'uber', 'other'), 'other', 'Skip')) r;
select test.eq('rideshare: one request (a double tap is the same one), logged and an alert to staff',
  (select count(*) from rideshare_doc_requests where booking_id = test.b('raC')) || '/' || (select r ->> 'again' from ra_rs2)
  || '/' || (select count(*) from booking_events where booking_id = test.b('raC') and kind = 'rideshare_docs' and note like '%DoorDash, Uber, Skip%' or (booking_id = test.b('raC') and kind = 'rideshare_docs' and note like '%Uber%'))
  || '/' || (select count(*) from app_events where payload ->> 'rule' = 'rideshare_docs_requested' and entity_id = test.b('raC')),
  '1/true/1/1');
create temp table ra_f as select public.server_rideshare_docs(test.id('ra_q'), test.b('raC')) f;
select test.eq('rideshare: the letters name only the company, with the car''s plate and VIN and the platforms',
  (select (f #>> '{company,legal_name}') = (app.settings()).company_legal_name and (f #>> '{car,plate}') is not null and (f #>> '{car,vin}') is not null
          and (f #>> '{requests,0,labels}') like '%Skip%' and f::text not like '%Ra O%' from ra_f), true);
select test.eq('rideshare: staff read the same on the booking', test.ra_read('ra_fleet', 'rideshare_docs', jsonb_build_object('booking', test.b('raC'))) #>> '{requests,0,id}', (select r ->> 'id' from ra_rs));
select test.throws('rideshare: someone else does not read the letters',
  format($$select public.server_rideshare_docs(%L, %L)$$, test.id('ra_r'), test.b('raC')), 'Not permitted');
select test.eq('rideshare: never on the owner''s own trip, even booked; a renter''s booked trip yes',
  (select app.rideshare_docs_open(jsonb_populate_record(b, '{"status": "confirmed"}')) from bookings b where b.id = (select id from ra_ow))
  || '/' || (select app.rideshare_docs_open(jsonb_populate_record(b, '{"status": "confirmed"}')) from bookings b where b.id = test.b('raB')), 'false/true');

-- ---------------------------------------------------------------- 8. instant booking for verified repeat renters
select test.mk_renter('ra_i');
select test.mk_renter('ra_n');
select test.mk_vehicle('RAX', 'ra_o');
select test.mk_booking('RA-I1', 'RAX', 'ra_i', '2026-01-05 10:00', '2026-01-08 10:00');
-- r40 (2421): Instant Book is the Gold tier's perk (1,000 points earned in 12 months)
insert into reward_ledger (renter_id, points, kind, action, source_key, reason) values (test.id('renter:ra_i'), 1000, 'earn', 'adjust', 'ra_i_gold', 'Test: Gold');
select test.eq('instant: a verified Gold renter is eligible; a renter below Gold is not, with the points in the reason',
  (app.instant_book_check(test.id('renter:ra_i')) ->> 'eligible') || '/' || (app.instant_book_check(test.id('renter:ra_n')) ->> 'reason'), 'true/Instant Book comes with a Rewards tier: 0 points earned in 12 months');
select test.rq_new('raI', 'ra_i', 'RAX', test.ho_local(interval '40 days'), test.ho_local(interval '42 days'));
create temp table ra_ib as select public.server_instant_book((select booking_number from bookings where id = test.b('raI')), test.id('ra_i')) r;
select test.eq('instant: the request becomes an accepted offer at once: waiting for payment, marked Instant, the To do closed',
  (select r ->> 'instant' from ra_ib) || '/' || test.st('raI') || '/' || (select instant_book::text from bookings where id = test.b('raI'))
  || '/' || (select count(*) from tasks where booking_id = test.b('raI') and task_type = 'booking_request' and status in ('open', 'in_progress', 'waiting'))
  || '/' || (test.ra_read('ra_cs', 'request_history', jsonb_build_object('booking', test.b('raI'))) ->> 'instant_book'),
  'true/pending_payment/true/0/true');
select test.rq_new('raN', 'ra_n', 'RAX', test.ho_local(interval '50 days'), test.ho_local(interval '52 days'));
select test.eq('instant: everyone else keeps request to book',
  (public.server_instant_book((select booking_number from bookings where id = test.b('raN')), test.id('ra_n')) ->> 'instant') || '/' || test.st('raN'), 'false/requested');
select test.throws('instant: not for someone else''s request',
  format($$select public.server_instant_book(%L, %L)$$, (select booking_number from bookings where id = test.b('raN')), test.id('ra_i')), 'Not permitted');
select test.throws('instant: only an Admin takes it away',
  format($$select public.door(%L, 'aal2', 'ops_do', 'instant_book_set', jsonb_build_object('renter', %L, 'revoke', true, 'reason', 'Late returns'))$$, test.id('ra_cs'), test.id('renter:ra_i')), 'An Admin');
select public.door(test.id('ra_admin'), 'aal2', 'ops_do', 'instant_book_set', jsonb_build_object('renter', test.id('renter:ra_i'), 'revoke', true, 'reason', 'Late returns'));
select test.eq('instant: taken away by an Admin, with why; staff see it',
  test.ra_read('ra_cs', 'instant_book_state', jsonb_build_object('renter', test.id('renter:ra_i'))) ->> 'reason', 'Taken away by an Admin: Late returns');
select public.door(test.id('ra_admin'), 'aal2', 'ops_do', 'instant_book_set', jsonb_build_object('renter', test.id('renter:ra_i'), 'revoke', false));
update reward_tiers set min_points = 1000000 where code = 'gold';
select test.eq('instant: the tier''s points are an Admin setting (Gold out of reach: not eligible)', app.instant_book_check(test.id('renter:ra_i')) ->> 'eligible', 'false');
update reward_tiers set min_points = 1000 where code = 'gold';
update program_settings set instant_book_repeat_enabled = false;
select test.eq('instant: switched off in the Program settings', app.instant_book_check(test.id('renter:ra_i')) ->> 'eligible', 'false');
update program_settings set instant_book_repeat_enabled = true;
select test.mk_line('RA-I1', 'damage_at_cost', 45000);
select test.eq('instant: a damage on a past rental ends it', app.instant_book_check(test.id('renter:ra_i')) ->> 'reason', 'A damage or claim on a past rental');

-- ---------------------------------------------------------------- 9. rewards: a photo with the review, booking again
select test.eq('rewards: the two new actions are listed with their points',
  (select string_agg(code || ':' || points, ',' order by code) from reward_actions where code in ('review_photo', 'rebook')), 'rebook:150,review_photo:100');
select test.mk_booking('RA-R1', 'RAX', 'ra_n', '2026-02-05 10:00', '2026-02-08 10:00', 'returned');
select test.mk_booking('RA-R2', 'RAX', 'ra_n', '2026-03-05 10:00', '2026-03-08 10:00', 'returned');
update bookings set status = 'closed' where id = test.id('booking:RA-R1');
update bookings set status = 'closed' where id = test.id('booking:RA-R2');
select test.eq('rewards: the first rental earns first_rental, not rebook; the second earns rebook (150) once',
  (select count(*) from reward_ledger where source_key = 'rebook:' || test.id('booking:RA-R1'))
  || '/' || (select coalesce(sum(points), 0) from reward_ledger where source_key = 'rebook:' || test.id('booking:RA-R2')),
  '0/150');
select app.rewards_on_close(test.id('booking:RA-R2'));
select test.eq('rewards: closing again does not pay twice', (select count(*) from reward_ledger where action = 'rebook' and booking_id = test.id('booking:RA-R2')), 1);
select public.renter_submit_review(test.id('booking:RA-R2'), test.id('ra_n'), 5, 'Great', 'Clean car', true);
select test.throws('rewards: a photo from somewhere else is refused',
  format($$select public.server_review_photos_set(%L, %L, '[{"path": "bookings/other/review/x.jpg"}]'::jsonb)$$, test.id('booking:RA-R2'), test.id('ra_n')), 'Not permitted');
select test.throws('rewards: not on someone else''s review',
  format($$select public.server_review_photos_set(%L, %L, '[]'::jsonb)$$, test.id('booking:RA-R2'), test.id('ra_q')), 'Not permitted');
select public.server_review_photos_set(test.id('booking:RA-R2'), test.id('ra_n'), jsonb_build_array(jsonb_build_object('path', 'bookings/' || test.id('booking:RA-R2') || '/review/a.jpg')));
select public.server_review_photos_set(test.id('booking:RA-R2'), test.id('ra_n'), jsonb_build_array(jsonb_build_object('path', 'bookings/' || test.id('booking:RA-R2') || '/review/a.jpg'), jsonb_build_object('path', 'bookings/' || test.id('booking:RA-R2') || '/review/b.jpg')));
select test.eq('rewards: a review with a photo earns review_photo (100) once, on top of the review''s points',
  (select sum(points) from reward_ledger where action = 'review_photo' and booking_id = test.id('booking:RA-R2')) || '/' || (select count(*) from reward_ledger where action = 'review_site' and booking_id = test.id('booking:RA-R2')),
  '100/1');
select test.eq('rewards: the Rewards page lists review, Google, referral, photo and rebook actions',
  (select count(*) from jsonb_array_elements(app.rewards_state(test.id('renter:ra_n')) -> 'actions') x where x ->> 'code' in ('review_site', 'referral_referrer', 'review_photo', 'rebook')), 4);
