-- 99: the renter chooses Book instantly or Request to book, recorded on the booking (migration 3900). Fixtures start with "r51b".
select test.suite('99 r50 book choice');
select test.mk_owner('r51b_o');
select test.mk_user('r51b_admin', 'admin');
select test.mk_renter('r51b_gold');
select test.mk_renter('r51b_new');
select test.mk_vehicle('R51B', 'r51b_o');
select test.mk_booking('R51B-1', 'R51B', 'r51b_gold', '2026-01-05 10:00', '2026-01-08 10:00');
insert into reward_ledger (renter_id, points, kind, action, source_key, reason) values (test.id('renter:r51b_gold'), 1000, 'earn', 'adjust', 'r51b_gold', 'Test: Gold');

-- Request to book: recorded, stays a request in the staff queue
select test.rq_new('r51bq1', 'r51b_new', 'R51B', test.ho_local(interval '40 days'), test.ho_local(interval '42 days'));
select test.eq('Request to book is recorded', public.server_book_choice((select booking_number from bookings where id = test.b('r51bq1')), 'request', test.id('r51b_new')) ->> 'choice', 'request');
select test.eq('Request to book: still a request', test.st('r51bq1'), 'requested');
select test.eq('Request to book: on the booking', (select book_choice from bookings where id = test.b('r51bq1')), 'request');
select test.ok('Request to book: the request''s To do stays open for staff',
  exists (select 1 from tasks where booking_id = test.b('r51bq1') and task_type = 'booking_request' and status in ('open', 'in_progress', 'waiting')));
select test.eq('the first choice stands', public.server_book_choice((select booking_number from bookings where id = test.b('r51bq1')), 'instant', test.id('r51b_new')) ->> 'choice', 'request');

-- Book instantly by a renter who may not: recorded, sent as a request with the reason
select test.rq_new('r51bq2', 'r51b_new', 'R51B', test.ho_local(interval '50 days'), test.ho_local(interval '52 days'));
select test.eq('Book instantly, not eligible: not instant', public.server_book_choice((select booking_number from bookings where id = test.b('r51bq2')), 'instant', test.id('r51b_new')) ->> 'instant', 'false');
select test.eq('Book instantly, not eligible: still a request', test.st('r51bq2'), 'requested');
select test.ok('Book instantly, not eligible: the reason is kept for staff', (select book_choice = 'instant' and book_choice_note like 'Asked to book instantly; sent as a request: %' from bookings where id = test.b('r51bq2')));

-- Book instantly by a Gold renter: booked at once, the "We have your request" email skipped
select test.rq_new('r51bq3', 'r51b_gold', 'R51B', test.ho_local(interval '60 days'), test.ho_local(interval '62 days'));
select test.eq('Book instantly, Gold: booked at once', public.server_book_choice((select booking_number from bookings where id = test.b('r51bq3')), 'instant', test.id('r51b_gold')) ->> 'instant', 'true');
select test.eq('Book instantly, Gold: waiting for payment', test.st('r51bq3'), 'pending_payment');
select test.ok('Book instantly, Gold: instant and the choice on the booking', (select instant_book and book_choice = 'instant' from bookings where id = test.b('r51bq3')));
select test.ok('Book instantly, Gold: no "We have your request" left to send',
  not exists (select 1 from notification_outbox where booking_id = test.b('r51bq3') and code = 'renter_request_received' and status in ('queued', 'delayed')));

-- who may record a choice
select test.eq('another renter cannot', public.server_book_choice((select booking_number from bookings where id = test.b('r51bq2')), 'request', test.id('r51b_gold')) ->> 'error', 'not_yours');
select test.eq('a visitor cannot book instantly', public.server_book_choice((select booking_number from bookings where id = test.b('r51bq2')), 'instant', null) ->> 'error', 'not_permitted');
select test.throws('a choice that is not one of the two is refused', $$ select public.server_book_choice('R51B-1', 'maybe', null) $$, 'Choose Book instantly');

-- staff see it; the audit trail has it; only the server role calls it
select test.ok('the audit log has the choice', exists (select 1 from audit_log where entity_table = 'bookings' and entity_id = test.b('r51bq2')::text and after ->> 'book_choice' = 'instant'));
select test.eq('request history carries the choice', app.request_history(test.id('r51b_admin'), jsonb_build_object('booking', test.b('r51bq2'))) ->> 'book_choice', 'instant');
select test.eq('only the website (service role) records a choice', (select count(*) from information_schema.routine_privileges where routine_name in ('server_book_choice', 'book_choice') and grantee in ('anon', 'authenticated', 'PUBLIC'))::int, 0);
select test.ok('search_path ends with pg_temp', (select bool_and(array_to_string(proconfig, ',') like '%pg_temp') from pg_proc where proname in ('server_book_choice', 'book_choice')));
