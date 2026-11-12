-- 99: a renter who may book at once chooses Send request or Book now (migration 2430, release 40). Fixtures start with "r40b".
select test.suite('99 r40 book now choice');
select test.mk_owner('r40b_o');
select test.mk_renter('r40b_gold');
select test.mk_renter('r40b_new');
select test.mk_vehicle('R40B', 'r40b_o');
select test.mk_booking('R40B-1', 'R40B', 'r40b_gold', '2026-01-05 10:00', '2026-01-08 10:00');
insert into reward_ledger (renter_id, points, kind, action, source_key, reason) values (test.id('renter:r40b_gold'), 1000, 'earn', 'adjust', 'r40b_gold', 'Test: Gold');

select test.eq('Book now is offered to a verified Gold renter, not to a new one, not to nobody',
  public.server_instant_book_available(test.id('r40b_gold'))::text || '/' || public.server_instant_book_available(test.id('r40b_new'))::text || '/' || coalesce(public.server_instant_book_available(null)::text, 'null'),
  'true/false/false');
select test.eq('only the website (service role) asks', (select count(*) from information_schema.routine_privileges where routine_name = 'server_instant_book_available' and grantee in ('anon', 'authenticated', 'PUBLIC'))::int, 0);

-- a request from the Gold renter stays a request until Book now: server_instant_book is not called by Send request
select test.rq_new('r40bq', 'r40b_gold', 'R40B', test.ho_local(interval '40 days'), test.ho_local(interval '42 days'));
select test.eq('Send request: the Gold renter''s request stays a request, no payment up front', test.st('r40bq'), 'requested');
select test.eq('Book now: the same request books at once (waiting for payment)',
  (public.server_instant_book((select booking_number from bookings where id = test.b('r40bq')), test.id('r40b_gold')) ->> 'instant') || '/' || test.st('r40bq'), 'true/pending_payment');
update program_settings set instant_book_repeat_enabled = false;
select test.eq('switched off in the Program settings: no Book now', public.server_instant_book_available(test.id('r40b_gold')), false);
update program_settings set instant_book_repeat_enabled = true;
