-- 99: stale emails are never sent (migration 0601, docs/changes/2026-11-07-outbox-stale.md): a staff alert older than 12
-- hours and an offer email whose offer is no longer open are skipped with the reason; a receipt still goes, whatever its
-- age; a renter email with no event older than 72 hours is skipped, a fresh one goes. Fixtures start with "os".
select test.suite('99 outbox stale');
select test.mk_user('os_admin', 'admin');
select test.mk_owner('os_olga');
select test.mk_vehicle('OSCAR', 'os_olga');
select test.mk_renter('os_rita');
select test.mk_booking('OS-1', 'OSCAR', 'os_rita', '2031-05-01 10:00', '2031-05-03 10:00', 'confirmed');
create or replace function test.os_mail(p_code text, p_aud text, p_key text, p_age interval, p_booking uuid default null) returns uuid language sql as $$
  insert into notification_outbox (code, category, priority, audience, booking_id, to_address, to_name, payload, dedupe_key, status, send_after, created_at)
  values (p_code, 'transactional', 1, p_aud, p_booking, p_key || '@os.example.test', 'Os', '{}'::jsonb, 'os-' || p_key, 'delayed', now() - interval '1 minute', now() - p_age)
  returning id $$;
select test.os_mail('staff_review_received', 'staff_admin', 'staff', interval '7 days');
select test.os_mail('staff_payment_failed', 'staff_admin', 'staffnew', interval '2 hours');
select test.os_mail('renter_offer_ready', 'renter', 'offer', interval '20 hours', test.id('booking:OS-1'));
select test.os_mail('renter_payment_receipt', 'renter', 'receipt', interval '8 days', test.id('booking:OS-1'));
select test.os_mail('renter_review_request', 'renter', 'old', interval '5 days');
select test.os_mail('renter_review_request', 'renter', 'fresh', interval '20 hours');
create temp table os_claim as select * from app.outbox_claim(100, now());
create or replace function test.os(p_key text) returns text language sql stable as $$
  select status || coalesce(':' || status_reason, '') from notification_outbox where dedupe_key = 'os-' || p_key $$;
select test.eq('a week-old staff alert is skipped (it is in the in-app notices)', test.os('staff'), 'skipped:stale: 7 days');
select test.ok('a fresh staff alert still goes', test.os('staffnew') !~ '^skipped');
select test.eq('an offer email for an offer no longer open is skipped', test.os('offer'), 'skipped:stale: the offer is no longer open');
select test.ok('a receipt still goes, a week old', test.os('receipt') !~ '^skipped');
select test.eq('a renter email older than 72 hours is skipped', test.os('old'), 'skipped:stale: 5 days');
select test.ok('a renter email under 72 hours still goes', test.os('fresh') !~ '^skipped');
select test.eq('the deploy''s count, by audience', (select (r -> 'by_audience' ->> 'staff_admin') || '/' || (r -> 'by_audience' ->> 'renter')
  from (select public.server_outbox_stale_report(now() - interval '1 hour') r) x) is not null, true);
select test.ok('only the service key reads it', not has_function_privilege('authenticated', 'public.server_outbox_stale_report(timestamptz)', 'execute'));
