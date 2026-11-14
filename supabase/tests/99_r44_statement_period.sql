-- 99: migration 2783 (release 44): an owner's first statement period starts at the first booking they see or their car's
-- program start, never at a booking hidden from them; a statement shorter than a full period is flagged as a partial month
-- for the page, the owner portal and the PDF. Fixtures start with "osx"; every address is example.test.
select test.suite('99 r44 statement period (2783)');

select test.mk_user('osx_admin', 'admin');
select test.mk_owner('osx_sala');
select test.mk_vehicle('OSX1', 'osx_sala');
update vehicles set enrollment_date = date '2026-10-24' where id = test.id('vehicle:OSX1');
select test.mk_renter('osx_r1', false); select test.mk_renter('osx_r2', false);

-- a hidden insurer replacement in September (the owner never sees it), a visible rental from October 25
select test.mk_booking('OSX-H1', 'OSX1', 'osx_r1', '2026-09-02 10:00', '2026-09-05 10:00', 'closed', 30000);
update bookings set owner_visibility = 'never' where id = test.id('booking:OSX-H1');
select test.mk_booking('OSX-V1', 'OSX1', 'osx_r2', '2026-10-25 10:00', '2026-10-28 10:00', 'closed', 30000);
-- the owner's revenue rows, as a closed booking has them before any statement is built
select app.compute_booking_split(id) from bookings where id in (test.id('booking:OSX-H1'), test.id('booking:OSX-V1'));

select test.ok('the hidden booking is not visible to the owner', not app.booking_visible_to_owner((select b from bookings b where b.id = test.id('booking:OSX-H1'))));
select test.eq('the first period starts at the first booking the owner sees, not at the hidden one (the program start is only used without one)',
  app.statement_period_start(test.id('owner:osx_sala'), date '2026-10-01'), date '2026-10-25');
update vehicles set enrollment_date = null where id = test.id('vehicle:OSX1');
select test.eq('without a program start: the first booking the owner sees', app.statement_period_start(test.id('owner:osx_sala'), date '2026-10-01'), date '2026-10-25');
update bookings set owner_visibility = 'shown' where id = test.id('booking:OSX-H1');
select app.compute_booking_split(test.id('booking:OSX-H1'));
select test.eq('a booking shown to the owner still sets it (as before)', app.statement_period_start(test.id('owner:osx_sala'), date '2026-10-01'), date '2026-09-02');
update bookings set owner_visibility = 'never' where id = test.id('booking:OSX-H1');
select app.compute_booking_split(test.id('booking:OSX-H1'));
update vehicles set enrollment_date = date '2026-10-24' where id = test.id('vehicle:OSX1');

select app.build_owner_statement(test.id('owner:osx_sala'), date '2026-10-01');
create temp view osx_st as select * from owner_statements where owner_id = test.id('owner:osx_sala') and status <> 'void';
select test.eq('the statement reads Oct 25 to Nov 7', (select period_starts_on || '/' || period_ends_on from osx_st where statement_month = date '2026-10-01'), '2026-10-25/2026-11-07');
select test.ok('it is a partial month', app.owner_statement_partial((select id from osx_st where statement_month = date '2026-10-01')));
select test.ok('the statement for Admin and the PDF carry the flag and the period',
  (select (b ->> 'partial_month')::boolean and b ->> 'period_starts_on' = '2026-10-25' and b ->> 'period_ends_on' = '2026-11-07'
     from (select app.owner_statement_breakdown(id, test.id('osx_admin')) b from osx_st where statement_month = date '2026-10-01') x));
select test.ok('the PDF facts carry it', (select (app.pdf_facts('owner_statement', id::text, test.id('osx_admin')) ->> 'partial_month')::boolean from osx_st where statement_month = date '2026-10-01'));

-- approved, the next period is a full one
select app.approve_owner_statement((select id from osx_st where statement_month = date '2026-10-01'), test.id('osx_admin'));
-- the owner sees an approved statement only
select test.ok('the owner portal''s statement carries it',
  (select (app.owner_portal_statement(test.id('osx_sala'), id) ->> 'partial_month')::boolean from osx_st where statement_month = date '2026-10-01'));
select app.build_owner_statement(test.id('owner:osx_sala'), date '2026-11-01');
select test.eq('the next statement starts the day after: Nov 8 to Dec 7', (select period_starts_on || '/' || period_ends_on from osx_st where statement_month = date '2026-11-01'), '2026-11-08/2026-12-07');
select test.ok('a full period is not a partial month', not app.owner_statement_partial((select id from osx_st where statement_month = date '2026-11-01')));
select test.ok('server only', not has_function_privilege('authenticated', 'app.owner_statement_partial(uuid)', 'execute')
  and not has_function_privilege('anon', 'app.booking_visible_to_owner(bookings)', 'execute')
  and has_function_privilege('service_role', 'app.owner_statement_breakdown(uuid, uuid)', 'execute') and not has_function_privilege('authenticated', 'app.owner_statement_breakdown(uuid, uuid)', 'execute'));
