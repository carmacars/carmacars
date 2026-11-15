-- 99: the coverage of a booking said once (migration 2920): the staff count ("Approve all (n)"), what Approve all approves,
-- the readiness and the renter's checklist agree, and an unmet step says exactly what is missing with a link to that upload.
-- Fixtures "rr"; example.test only.
select test.suite('99 r48 readiness');

select test.mk_user('rr_admin', 'admin');
select test.mk_owner('rr_o');
select test.mk_vehicle('RRA', 'rr_o');
select test.mk_vehicle('RRB', 'rr_o');
select test.mk_renter('rr_rena');
select test.mk_renter('rr_paul');

create function test.rr_item(p_number text, p_key text) returns jsonb language sql stable as $$
  select i from jsonb_array_elements(app.renter_still_needed(test.id('booking:' || p_number)) -> 'items') i where i ->> 'key' = p_key $$;
create function test.rr_review(p_number text) returns jsonb language sql as $$
  select app.doc_review_read(test.id('rr_admin'), jsonb_build_object('booking', p_number)) $$;
create function test.rr_page(p_number text, p_kind text) returns uuid language sql as $$
  select app.register_verification_upload(test.id('booking:' || p_number), (select r.user_id from renters r where r.id = test.id('renter:rr_rena')), 'coverage_proof', null,
    'renters/rr/' || p_number || '-' || coalesce(p_kind, 'policy') || '-' || gen_random_uuid() || '.jpg', repeat('a', 64), 'image/jpeg',
    jsonb_build_object('coverage_option', '1', 'page_kind', p_kind, 'insurer_name', 'Example Insurance Co.', 'policy_number', 'EX-000-TEST',
                       'policy_expiry', (now() + interval '1 year')::date), 'documents') $$;

-- a paid booking on OPCF 27: nothing sent yet
select test.mk_booking('CC-RR1', 'RRA', 'rr_rena', to_char(now() at time zone 'America/Toronto' + interval '9 days', 'YYYY-MM-DD 10:00'),
  to_char(now() at time zone 'America/Toronto' + interval '12 days', 'YYYY-MM-DD 10:00'), 'confirmed');
update bookings set coverage_option = 1 where id = test.id('booking:CC-RR1');
insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, age_at_pickup, age_band)
values (test.id('booking:CC-RR1'), test.id('driver:rr_rena'), 'renter', 'Rr Rena', date '1990-05-05', 36, '26_plus');

select test.eq('nothing sent: both pages needed', (select string_agg(n ->> 'page_kind', ',') from jsonb_array_elements(app.coverage_state(test.id('booking:CC-RR1')) -> 'needs') n), 'pink_slip,endorsement');
select test.eq('the renter''s step: missing, both named, the link opens the pink slip upload',
  (select (i ->> 'status') || '|' || (i #>> '{action,path}') from test.rr_item('CC-RR1', 'coverage') i), 'missing|verify?need=pink_slip#cov-pink_slip');
select test.ok('the step says what is missing', (select i ->> 'reason' like '%pink slip%' and i ->> 'reason' like '%OPCF 27 endorsement page%' from test.rr_item('CC-RR1', 'coverage') i));
select test.eq('the licence step links straight to the licence front upload of that driver',
  (select i #>> '{action,path}' from test.rr_item('CC-RR1', 'licence:' || test.id('driver:rr_rena')) i), 'verify#up-licence_front-' || test.id('driver:rr_rena'));
select test.eq('the selfie step links straight to its upload',
  (select i #>> '{action,path}' from test.rr_item('CC-RR1', 'selfie:' || test.id('driver:rr_rena')) i), 'verify#up-selfie-' || test.id('driver:rr_rena'));

-- the owner's report: one page sent (the endorsement page); nothing staff can approve yet
select test.rr_page('CC-RR1', 'endorsement');
select test.eq('one page sent: the proof is not waiting for us', (app.coverage_state(test.id('booking:CC-RR1')) ->> 'proof_waiting'), 'false');
select test.eq('the review counts nothing to approve', (test.rr_review('CC-RR1') ->> 'waiting')::int, 0);
select test.eq('the review says the pink slip is missing', (select string_agg(n ->> 'page_kind', ',') from jsonb_array_elements(test.rr_review('CC-RR1') #> '{coverage,needs}') n), 'pink_slip');
select test.eq('the review''s proof is not waiting', test.rr_review('CC-RR1') #>> '{coverage,proof_waiting}', 'false');
select test.eq('the renter''s step: missing (not Under review), the pink slip named, the link opens the pink slip upload',
  (select (i ->> 'status') || '|' || (i #>> '{action,label}') || '|' || (i #>> '{action,path}') from test.rr_item('CC-RR1', 'coverage') i),
  'missing|Upload the pink slip|verify?need=pink_slip#cov-pink_slip');
select test.ok('the step says what is in and what is missing', (select i ->> 'reason' like 'We have your OPCF 27 endorsement page.%' and i ->> 'reason' like '%pink slip%' from test.rr_item('CC-RR1', 'coverage') i));
select test.eq('the readiness names the missing page', app.booking_readiness(test.id('booking:CC-RR1')) -> 'coverage_needs', '["your pink slip (the insurance card for your own car)"]'::jsonb);
select test.eq('Approve all approves nothing and refuses nothing', (select (r ->> 'approved') || '/' || jsonb_array_length(r -> 'refused')
  from app.doc_review_approve_all(test.id('rr_admin'), jsonb_build_object('booking', 'CC-RR1')) r), '0/0');

-- the pink slip comes: now it waits for us, counted once, approved by Approve all
select test.rr_page('CC-RR1', 'pink_slip');
select test.eq('both pages: waiting for us', app.coverage_state(test.id('booking:CC-RR1')) ->> 'proof_waiting', 'true');
select test.eq('the review counts it once', (test.rr_review('CC-RR1') ->> 'waiting')::int, 1);
select test.eq('the renter''s step: under review, no action', (select (i ->> 'status') || '|' || coalesce(i #>> '{action,path}', 'none') from test.rr_item('CC-RR1', 'coverage') i), 'review|none');
select test.eq('the readiness: nothing to send, waiting for us', (select (r -> 'coverage_needs')::text || '|' || (r ->> 'coverage_waiting') from app.booking_readiness(test.id('booking:CC-RR1')) r), '[]|true');
select test.eq('Approve all approves exactly what it counted', (select (r ->> 'approved') || '/' || jsonb_array_length(r -> 'refused')
  from app.doc_review_approve_all(test.id('rr_admin'), jsonb_build_object('booking', 'CC-RR1')) r), '1/0');
select test.eq('confirmed: the step is done, the count is 0', (select i ->> 'status' from test.rr_item('CC-RR1', 'coverage') i) || '|' || (test.rr_review('CC-RR1') ->> 'waiting'), 'done|0');

-- the Protection Plan on a booking not paid yet is not counted (Approve all cannot confirm it); once paid it is
select test.mk_booking('CC-RR2', 'RRB', 'rr_paul', to_char(now() at time zone 'America/Toronto' + interval '20 days', 'YYYY-MM-DD 10:00'),
  to_char(now() at time zone 'America/Toronto' + interval '22 days', 'YYYY-MM-DD 10:00'), 'pending_payment');
update bookings set coverage_option = 3 where id = test.id('booking:CC-RR2');
select test.mk_line('CC-RR2', 'coverage_sold', 3000);
select test.eq('not paid: the plan is not counted', (test.rr_review('CC-RR2') ->> 'waiting')::int || '|' || (test.rr_review('CC-RR2') #>> '{coverage,plan_waiting}'), '0|false');
select test.mk_booking('CC-RR3', 'RRB', 'rr_paul', to_char(now() at time zone 'America/Toronto' + interval '30 days', 'YYYY-MM-DD 10:00'),
  to_char(now() at time zone 'America/Toronto' + interval '32 days', 'YYYY-MM-DD 10:00'), 'confirmed');
update bookings set coverage_option = 3 where id = test.id('booking:CC-RR3');
select test.mk_line('CC-RR3', 'coverage_sold', 3000);
select test.eq('paid: counted once, and Approve all confirms it', (test.rr_review('CC-RR3') ->> 'waiting') || '|' || (select r ->> 'approved' from app.doc_review_approve_all(test.id('rr_admin'), jsonb_build_object('booking', 'CC-RR3')) r), '1|1');

select test.ok('the renter''s coverage read carries the same needs', app.renter_coverage(test.id('booking:CC-RR1')) ? 'needs');
