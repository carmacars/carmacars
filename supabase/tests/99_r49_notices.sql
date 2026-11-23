-- r49 (3462): the four gaps of the notification map. Fixtures start with "r49n".
select test.suite('99 r49 notices: late owner, Sales at 30 minutes, overdue balances, refunds');
grant usage on schema test to service_role;
grant execute on all functions in schema test to authenticated, anon, service_role;

select test.mk_user('r49n_admin', 'admin');
select test.mk_owner('r49n_o');
select test.mk_vehicle('R49N', 'r49n_o');
select test.mk_renter('r49n_r', false);
select test.mk_booking('R49N-1', 'R49N', 'r49n_r', '2026-12-02 10:00', '2026-12-04 10:00', 'on_rent', 20000);
select test.mk_booking('R49N-2', 'R49N', 'r49n_r', '2026-12-10 10:00', '2026-12-12 10:00', 'requested', 20000);
select test.mk_booking('R49N-3', 'R49N', 'r49n_r', '2026-12-20 10:00', '2026-12-22 10:00', 'closed', 20000);

-- 4. refunds: paid and failed tell Finance and the Admins
insert into refunds (booking_id, reason, amount_cents, status, approved_by)
  values (test.id('booking:R49N-3'), 'goodwill', 12650, 'processing', test.id('r49n_admin'));
select test.eq('a refund still processing tells nobody', (select count(*) from app_events where code in ('staff_refund_issued', 'staff_refund_failed') and (payload ->> 'booking_id')::uuid = test.id('booking:R49N-3')), 0::bigint);
update refunds set status = 'paid', paid_at = now() where booking_id = test.id('booking:R49N-3');
select test.eq('a paid refund: Finance gets it, with the amount and the reason',
  (select payload ->> 'refund_amount' || '/' || (payload ->> 'refund_reason') from app_events where code = 'staff_refund_issued' and (payload ->> 'booking_id')::uuid = test.id('booking:R49N-3')), '$126.50/Goodwill');
insert into refunds (booking_id, reason, amount_cents, status, approved_by)
  values (test.id('booking:R49N-3'), 'duplicate', 5000, 'processing', test.id('r49n_admin'));
update refunds set status = 'failed' where reason = 'duplicate' and booking_id = test.id('booking:R49N-3');
select test.eq('a failed refund: Finance gets that too',
  (select count(*) from app_events where code = 'staff_refund_failed' and (payload ->> 'booking_id')::uuid = test.id('booking:R49N-3')), 1::bigint);

-- 2. Sales: a request 40 minutes old, in business hours (Wed Dec 2, 2026, 3 pm Toronto time) and out of them (7 am)
update bookings set requested_at = timestamptz '2026-12-02 15:00 America/Toronto' - interval '40 minutes' where booking_number = 'R49N-2';
select app.job_requests_open_to_sales(timestamptz '2026-12-02 07:00 America/Toronto');
select app.job_r49_notices(timestamptz '2026-12-02 07:00 America/Toronto');
select test.eq('before 8 am: no To do and no notice for Sales',
  (select count(*) from tasks where booking_id = test.id('booking:R49N-2') and task_type = 'request_open_to_sales')
  + (select count(*) from app_events where code = 'staff_request_open_to_sales' and (payload ->> 'booking_id')::uuid = test.id('booking:R49N-2')), 0::bigint);
select app.job_requests_open_to_sales(timestamptz '2026-12-02 15:00 America/Toronto');
select app.job_r49_notices(timestamptz '2026-12-02 15:00 America/Toronto');
select test.eq('in business hours: the Sales To do', (select count(*) from tasks where booking_id = test.id('booking:R49N-2') and task_type = 'request_open_to_sales'), 1::bigint);
select test.eq('in business hours: the Sales notice, once', (select count(*) from app_events where code = 'staff_request_open_to_sales' and (payload ->> 'booking_id')::uuid = test.id('booking:R49N-2')), 1::bigint);
select app.job_r49_notices(timestamptz '2026-12-02 15:05 America/Toronto');
select test.eq('the next run sends nothing more', (select count(*) from app_events where code = 'staff_request_open_to_sales' and (payload ->> 'booking_id')::uuid = test.id('booking:R49N-2')), 1::bigint);

-- 1. the owner: 2 hours late, once
update bookings set pickup_at = '2026-12-02 10:00-05', return_at = timestamptz '2026-12-04 10:00 America/Toronto' where booking_number = 'R49N-1';
select app.job_r49_notices(timestamptz '2026-12-04 11:00 America/Toronto');
select test.eq('1 hour late: the owner is not told', (select count(*) from app_events where code = 'owner_late_return' and (payload ->> 'booking_id')::uuid = test.id('booking:R49N-1')), 0::bigint);
select app.job_r49_notices(timestamptz '2026-12-04 12:10 America/Toronto');
select app.job_r49_notices(timestamptz '2026-12-04 12:20 America/Toronto');
select test.eq('2 hours late: the owner is told once', (select count(*) from app_events where code = 'owner_late_return' and (payload ->> 'booking_id')::uuid = test.id('booking:R49N-1')), 1::bigint);
select test.eq('...and it says how late', (select payload ->> 'late_by' from app_events where code = 'owner_late_return' and (payload ->> 'booking_id')::uuid = test.id('booking:R49N-1')), '2 hours');

-- 3. Finance: an overdue balance
insert into booking_statements (booking_id, statement_number, kind, issued_at, sent_at, charges_cents, hst_cents)
  values (test.id('booking:R49N-3'), 'R49N-S1', 'later_charge', timestamptz '2026-11-28 10:00 America/Toronto', timestamptz '2026-11-28 10:00 America/Toronto', 40000, 5200);
select app.job_r49_notices(timestamptz '2026-12-02 08:00 America/Toronto');
select test.eq('before 9 am: no digest', (select count(*) from app_events where dedupe_key like 'staff_balance_overdue_digest:%:2026-12-02'), 0::bigint);
select test.eq('4 days overdue: the Admin To do', (select count(*) from tasks where task_type = 'balance_overdue' and booking_id = test.id('booking:R49N-3') and status = 'open'), 1::bigint);
select app.job_r49_notices(timestamptz '2026-12-02 09:05 America/Toronto');
select app.job_r49_notices(timestamptz '2026-12-02 14:00 America/Toronto');
select test.eq('from 9 am: one digest a day', (select count(*) from app_events where dedupe_key like 'staff_balance_overdue_digest:%:2026-12-02'), 1::bigint);
select test.eq('the digest has the amount and the days of ours',
  (select (i ->> 'amount_due') || '/' || (i ->> 'days_overdue') from app_events e, jsonb_array_elements(e.payload -> 'items') i
    where e.dedupe_key like 'staff_balance_overdue_digest:%:2026-12-02' and i ->> 'booking_number' = 'R49N-3'), '$452.00/4');
select test.ok('the digest links the booking', exists (select 1 from app_events e, jsonb_array_elements(e.payload -> 'items') i
    where e.dedupe_key like 'staff_balance_overdue_digest:%:2026-12-02' and i ->> 'url' like '%/staff/bookings/R49N-3'));
update booking_statements set paid_at = now() where statement_number = 'R49N-S1';
select app.job_r49_notices(timestamptz '2026-12-02 15:00 America/Toronto');
select test.eq('paid: the To do closes', (select status from tasks where task_type = 'balance_overdue' and booking_id = test.id('booking:R49N-3')), 'done');
select app.job_r49_notices(timestamptz '2026-12-03 09:30 America/Toronto');
select test.eq('paid: ours is no longer listed the next day', (select count(*) from app_events e, jsonb_array_elements(e.payload -> 'items') i where e.dedupe_key like 'staff_balance_overdue_digest:%:2026-12-03' and i ->> 'booking_number' = 'R49N-3'), 0::bigint);
