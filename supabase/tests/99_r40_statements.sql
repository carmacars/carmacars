-- 99: release 40 (migration 2480): a booking hidden from the owner (an insurance replacement, while only those are hidden)
-- or one that does not block the calendar (an insurer-billed rental added by hand) is not part of the owner's revenue: off
-- the statement, its payout and "not yet collected", and the owner sees the dates only. A normal booking and an insurer
-- rental that blocks the calendar stay on. Drafts of a period are rebuilt; an approved statement is never touched.
-- Fixtures start with "rst" (a period of 2031, so no other suite's draft is rebuilt here).
select test.suite('99 r40 statements: hidden and off-calendar bookings');

select test.mk_user('rst_admin', 'admin');
select test.mk_owner('rst_owen');
select test.mk_owner('rst_ann');
select test.mk_vehicle('RST1', 'rst_owen');
select test.mk_vehicle('RST2', 'rst_ann');
select test.mk_renter('rst_r1', false); select test.mk_renter('rst_r2', false); select test.mk_renter('rst_r3', false);
select test.mk_renter('rst_r4', false); select test.mk_renter('rst_r5', false); select test.mk_renter('rst_r6', false);
insert into insurers (id, name) values (test.id('insurer:rst'), 'Rst Example Insurance');
create temp table rst_prev as select owner_hide_insurance_only as io from app.settings();
update program_settings set owner_hide_insurance_only = true where id = (select id from app.settings());

-- N: a normal rental, billed to the renter, paid
select test.mk_booking('RST-N', 'RST1', 'rst_r1', '2031-03-02 10:00', '2031-03-05 10:00', 'closed', 30000);
-- H: an insurance replacement hidden from the owner (until the statement)
select test.mk_booking('RST-H', 'RST1', 'rst_r2', '2031-03-06 10:00', '2031-03-09 10:00', 'closed', 30000);
update bookings set bill_to = 'insurer', insurer_id = test.id('insurer:rst'), owner_visibility = 'until_statement' where id = test.id('booking:RST-H');
-- C: an insurer-billed rental added by hand that does not block the calendar, shown, not paid yet
select test.mk_booking('RST-C', 'RST1', 'rst_r3', '2031-03-10 10:00', '2031-03-13 10:00', 'returned', 0);
select test.mk_line('RST-C', 'rental_charge', 36000, false);
update bookings set bill_to = 'insurer', insurer_id = test.id('insurer:rst'), blocks_calendar = false,
       blocks_calendar_changed_by = test.id('rst_admin'), blocks_calendar_reason = 'Insurer rental, dates not final' where id = test.id('booking:RST-C');
-- I: an insurer-billed rental that blocks the calendar, shown, not paid yet: the owner's, and not yet collected
select test.mk_booking('RST-I', 'RST1', 'rst_r4', '2031-03-14 10:00', '2031-03-17 10:00', 'returned', 0);
select test.mk_line('RST-I', 'rental_charge', 36000, false);
update bookings set bill_to = 'insurer', insurer_id = test.id('insurer:rst') where id = test.id('booking:RST-I');
-- U: billed to the renter and marked hidden (from before 0791): the owner's rule keeps every renter-billed booking theirs
select test.mk_booking('RST-U', 'RST1', 'rst_r5', '2031-03-18 10:00', '2031-03-20 10:00', 'closed', 20000);
update bookings set owner_visibility = 'until_statement' where id = test.id('booking:RST-U');

create function pg_temp.b(p text) returns bookings language sql as $$ select * from bookings where id = test.id('booking:' || p) $$;
create function pg_temp.st(p_owner text) returns owner_statements language sql as $$
  select * from owner_statements where owner_id = test.id('owner:' || p_owner) and statement_month = date '2031-03-01' and status <> 'void' $$;
create function pg_temp.on_st(p text) returns boolean language sql as $$
  select exists (select 1 from owner_statement_lines l where l.owner_statement_id = (pg_temp.st('rst_owen')).id and l.booking_id = test.id('booking:' || p)) $$;

select test.eq('the rule: N, I and U count; H (hidden insurance replacement) and C (off the calendar) do not',
  (select string_agg(x || '=' || app.booking_counts_for_owner(pg_temp.b(x)), ' ' order by x) from unnest(array['RST-C', 'RST-H', 'RST-I', 'RST-N', 'RST-U']) x),
  'RST-C=false RST-H=false RST-I=true RST-N=true RST-U=true');

select app.build_owner_statement(test.id('owner:rst_owen'), date '2031-03-01');
select test.eq('the period ends April 7, 2031', (pg_temp.st('rst_owen')).period_ends_on, date '2031-04-07');
select test.eq('statement: the normal booking, the insurer rental on the calendar and the renter-billed one are on it',
  pg_temp.on_st('RST-N') || '/' || pg_temp.on_st('RST-I') || '/' || pg_temp.on_st('RST-U'), 'true/true/true');
select test.ok('statement: the booking hidden from the owner is not on it', not pg_temp.on_st('RST-H'));
select test.ok('statement: the insurer rental that does not block the calendar is not on it', not pg_temp.on_st('RST-C'));
select test.eq('statement: Owner Revenue is the three counted bookings only',
  (pg_temp.st('rst_owen')).owner_revenue_cents,
  (select sum(owner_revenue_cents)::bigint from booking_splits where booking_id in (test.id('booking:RST-N'), test.id('booking:RST-I'), test.id('booking:RST-U'))));
select test.eq('the split: the excluded ones pay the owner nothing and are kept off every statement month',
  (select sum(owner_payout_cents) || '/' || min(payout_month) || '/' || bool_and(company_share_cents = owner_revenue_cents)
     from booking_splits where booking_id in (test.id('booking:RST-H'), test.id('booking:RST-C'))), '0/9999-12-01/true');
select test.eq('not yet collected: only the insurer rental on the calendar (not the one off it)',
  (select (n ->> 'total_cents') || '/' || (select string_agg(e ->> 'booking_number', ',') from jsonb_array_elements(n -> 'bookings') e)
     from (select app.owner_statement_not_collected((pg_temp.st('rst_owen')).id) as n) x),
  (select sum(amount_cents)::text from owner_statement_lines where owner_statement_id = (pg_temp.st('rst_owen')).id and booking_id = test.id('booking:RST-I') and line_type = 'rental') || '/RST-I');

-- what the owner sees: the dates only, no number and no amount
select test.eq('owner view: H and C unavailable, N full',
  app.booking_owner_view(pg_temp.b('RST-H')) || '/' || app.booking_owner_view(pg_temp.b('RST-C')) || '/' || app.booking_owner_view(pg_temp.b('RST-N')), 'unavailable/unavailable/full');
select test.eq('owner portal bookings: no number and no amount for H and C',
  (select count(*) filter (where b ->> 'booking_number' is null and b ->> 'rental_charge_cents' is null and b ->> 'owner_view' = 'unavailable')
     from jsonb_array_elements(public.owner_portal_bookings(test.id('rst_owen'))) b
    where (b ->> 'booking_id')::uuid in (test.id('booking:RST-H'), test.id('booking:RST-C'))), 2::bigint);
select test.ok('the booking page says why it is not the owner''s revenue',
  (select (r ->> 'counts_for_owner') = 'false' and r ->> 'label' like '%does not block the calendar%'
     from (select app.booking_owner_visibility_read(test.id('rst_admin'), pg_temp.b('RST-C')) as r) x));

-- the owner's rule off (0156): "hidden" only delays what the owner sees; the calendar rule stays
update program_settings set owner_hide_insurance_only = false where id = (select id from app.settings());
select test.eq('rule off: the hidden insurance replacement counts again; off the calendar still does not',
  app.booking_counts_for_owner(pg_temp.b('RST-H')) || '/' || app.booking_counts_for_owner(pg_temp.b('RST-C')), 'true/false');
update program_settings set owner_hide_insurance_only = true where id = (select id from app.settings());

-- rebuild the drafts of the period: a line the old build left (the hidden booking) goes; an approved statement stays
select test.mk_booking('RST-A', 'RST2', 'rst_r6', '2031-03-02 10:00', '2031-03-05 10:00', 'closed', 30000);
select app.build_owner_statement(test.id('owner:rst_ann'), date '2031-03-01');
select app.approve_owner_statement((pg_temp.st('rst_ann')).id, test.id('rst_admin'));
create temp table rst_ann_before as select (pg_temp.st('rst_ann')).built_at, (pg_temp.st('rst_ann')).status,
  (select count(*) from owner_statement_lines where owner_statement_id = (pg_temp.st('rst_ann')).id) as n;
insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, booking_id, owner_revenue_cents, revenue_share_cents, amount_cents)
values ((pg_temp.st('rst_owen')).id, test.id('vehicle:RST1'), 'rental', 'Booking RST-H (an earlier build)', test.id('booking:RST-H'), 30000, 10500, 19500);
select test.ok('the stale line is there before the rebuild', pg_temp.on_st('RST-H'));
create temp table rst_rebuild as select app.owner_statements_rebuild_drafts(date '2031-04-07', test.id('rst_admin')) as r;
select test.eq('rebuild: the draft is rebuilt, no error', (select (r ->> 'rebuilt')::int >= 1 and r -> 'errors' = '{}'::jsonb from rst_rebuild), true);
select test.ok('rebuild: the hidden booking is off the draft again, the normal one on it', not pg_temp.on_st('RST-H') and pg_temp.on_st('RST-N'));
select test.eq('rebuild: the same draft (its number kept)', (pg_temp.st('rst_owen')).status, 'draft');
select test.eq('rebuild: the approved statement is untouched',
  (select (pg_temp.st('rst_ann')).built_at = b.built_at and (pg_temp.st('rst_ann')).status = b.status
          and (select count(*) from owner_statement_lines where owner_statement_id = (pg_temp.st('rst_ann')).id) = b.n from rst_ann_before b), true);
select test.ok('rebuild: audited', exists (select 1 from audit_log where action = 'owner_statements_rebuild_drafts' and entity_id = '2031-04-07'));

update program_settings set owner_hide_insurance_only = (select io from rst_prev) where id = (select id from app.settings());
