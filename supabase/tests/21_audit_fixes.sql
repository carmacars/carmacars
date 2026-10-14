-- 21: what the handover audit fixed in the database (migration 0034): the one-click unsubscribe wrappers and
-- the renter's review of a closed booking. Every fixture label starts with "au" (and "AU" for cars).
select test.suite('21 audit fixes');

select test.mk_owner('au_o');
select test.mk_vehicle('AU1', 'au_o');
select test.mk_renter('au_r');
select test.mk_renter('au_other');
select test.mk_booking('AU-1', 'AU1', 'au_r', to_char(now() - interval '12 days', 'YYYY-MM-DD 10:00'), to_char(now() - interval '9 days', 'YYYY-MM-DD 10:00'), 'closed');
select test.mk_booking('AU-2', 'AU1', 'au_r', to_char(now() + interval '30 days', 'YYYY-MM-DD 10:00'), to_char(now() + interval '33 days', 'YYYY-MM-DD 10:00'), 'confirmed');

-- ---------------------------------------------------------------- 1. unsubscribe
select test.eq('unsubscribe: the link path is the page the website serves', (app.settings()).notify_unsubscribe_path, '/unsubscribe');
insert into notification_outbox (id, code, category, priority, audience, dedupe_key, to_address, recipient_user_id, unsubscribe_token)
values (test.id('outbox:au1'), 'renter_comeback_1w', 'marketing', 5, 'renter', 'au:comeback', 'au_r@example.test',
        (select user_id from renters where id = test.id('renter:au_r')), test.id('token:au1')),
       (test.id('outbox:au2'), 'renter_comeback_1m', 'marketing', 5, 'renter', 'au:comeback2', 'au_r@example.test',
        (select user_id from renters where id = test.id('renter:au_r')), null);

set role service_role;
select test.eq('unsubscribe: the page reads a masked address and that nothing is done yet',
  public.server_unsubscribe_info(test.id('token:au1')), '{"valid": true, "masked_email": "a***@example.test", "already_unsubscribed": false}'::jsonb);
select test.eq('unsubscribe: an unknown token is not valid', public.server_unsubscribe_info(test.id('token:nope')) ->> 'valid', 'false');
select test.ok('unsubscribe: the click is accepted', public.server_unsubscribe(test.id('token:au1')));
select test.ok('unsubscribe: a second click is accepted too (idempotent)', public.server_unsubscribe(test.id('token:au1')));
select test.ok('unsubscribe: an unknown token changes nothing', not public.server_unsubscribe(test.id('token:nope')));
select test.eq('unsubscribe: the page now says it is done', public.server_unsubscribe_info(test.id('token:au1')) ->> 'already_unsubscribed', 'true');
reset role;
select test.eq('unsubscribe: the address is on the marketing suppression list once',
  (select count(*) from email_suppressions where email = 'au_r@example.test' and scope = 'marketing' and lifted_at is null), 1::bigint);
select test.eq('unsubscribe: the waiting marketing email is not sent',
  (select status || '/' || status_reason from notification_outbox where id = test.id('outbox:au2')), 'suppressed/unsubscribed');
select test.ok('unsubscribe: the account no longer takes marketing',
  (select not marketing_opt_in and marketing_unsubscribed_at is not null from users where id = (select user_id from renters where id = test.id('renter:au_r'))));
set role anon;
select test.throws('unsubscribe: the anonymous role cannot call the wrapper',
  $$select public.server_unsubscribe('00000000-0000-0000-0000-000000000000')$$, 'permission denied');
reset role;

-- ---------------------------------------------------------------- 2. the renter's review
set role service_role;
select test.eq('review: the renter of a closed booking may review it',
  public.renter_review_state(test.id('booking:AU-1'), test.id('au_r')) ->> 'can_review', 'true');
select test.eq('review: not before the booking is closed',
  public.renter_review_state(test.id('booking:AU-2'), test.id('au_r')) ->> 'can_review', 'false');
select test.throws('review: another renter cannot read the state',
  format('select public.renter_review_state(%L, %L)', test.id('booking:AU-1'), test.id('au_other')), null);
select test.throws('review: a rating outside 1 to 5 is refused',
  format('select public.renter_submit_review(%L, %L, 6)', test.id('booking:AU-1'), test.id('au_r')), 'rating');
select test.ok('review: submitted with the consent to publish',
  public.renter_submit_review(test.id('booking:AU-1'), test.id('au_r'), 5, 'Great car', 'Clean and on time.', true) is not null);
select test.eq('review: the state shows the review, pending, with the consent',
  (select (s -> 'review' ->> 'status') || '/' || (s -> 'review' ->> 'rating') || '/' || (s -> 'review' ->> 'publish_consent') || '/' || (s ->> 'can_review')
     from public.renter_review_state(test.id('booking:AU-1'), test.id('au_r')) s), 'pending/5/true/false');
select test.throws('review: one review per booking',
  format('select public.renter_submit_review(%L, %L, 4)', test.id('booking:AU-1'), test.id('au_r')), 'already');
reset role;
select test.ok('review: the consent time is recorded on the review',
  (select publish_consent_at is not null from reviews where booking_id = test.id('booking:AU-1')));
select test.eq('review: nothing is public until staff publish it', (select count(*) from app.public_reviews(test.id('vehicle:AU1'))), 0::bigint);
set role authenticated;
select test.throws('review: the authenticated role cannot call the submit wrapper',
  format('select public.renter_submit_review(%L, %L, 5)', test.id('booking:AU-1'), test.id('au_r')), 'permission denied');
reset role;

-- ---------------------------------------------------------------- 3. the disable approval email without a booking
select test.mk_user('au_admin', 'admin');
select app.emit_event('staff_disable_approval_needed', 'tracker_command', test.id('cmd:au1'),
  jsonb_build_object('vehicle_id', test.id('vehicle:AU1'), 'booking_id', null, 'disable_ground', 'suspected_theft',
                     'requested_at', now(), 'requested_by', test.id('au_admin'), 'reason', 'tracker shows the car in a shipping yard'),
  'staff_disable_approval_needed:' || test.id('cmd:au1') || ':requested');
select app.process_events(1000);
select test.eq('disable approval: without a booking every variable is filled',
  (select string_agg(distinct array_to_string(missing_variables, ','), ';') from notification_outbox where entity_id = test.id('cmd:au1')), '');
select test.eq('disable approval: it says there is no booking and no renter',
  (select (payload ->> 'booking_number') || '/' || (payload ->> 'renter_name') from notification_outbox where entity_id = test.id('cmd:au1') limit 1), 'No booking/No renter');

-- ---------------------------------------------------------------- 4. the renter portal lists the caller's own documents
insert into documents (id, kind, title, storage_bucket, storage_path, renter_id, booking_id, retention)
values (test.id('doc:au_r'), 'renter_statement', 'Statement AU-1', 'documents', 'au/r.pdf', test.id('renter:au_r'), test.id('booking:AU-1'), 'records_7y'),
       (test.id('doc:au_other'), 'renter_statement', 'Statement other', 'documents', 'au/o.pdf', test.id('renter:au_other'), null, 'records_7y');
grant usage on schema test to authenticated;
grant execute on all functions in schema test to authenticated;
select test.login(test.id('au_r'));
select test.ok('documents: the renter sees their statement', exists (select 1 from public.my_documents() j where j ->> 'id' = test.id('doc:au_r')::text));
select test.ok('documents: not another renter''s', not exists (select 1 from public.my_documents() j where j ->> 'id' = test.id('doc:au_other')::text));
select test.logout();
select test.login(test.id('au_admin'));
select test.eq('documents: an Admin''s renter portal lists no company files', (select count(*) from public.my_documents()), 0::bigint);
select test.ok('documents: the Admin still reads the row through row-level security (admin screens)', public.my_document(test.id('doc:au_other')) is not null);
select test.logout();

-- ---------------------------------------------------------------- 5. digest lines read as words
select test.eq('digest: a status code reads as words', app.ntf_item('Incident IN-1', 'Claim_open', '') ->> 'meta', 'Claim open');
select test.eq('digest: a missing due date reads "No due date"', app.ntf_item('Task', 'Due not set', '') ->> 'meta', 'No due date');
