-- 99: release 33 part H (docs/changes/2026-11-07-r33-finishing.md): check-in and check-out wording (0740), expired offers become renter leads (0741),
-- change your own email (0742). Fixtures start with "h3".
select test.suite('99 r33 finishing');

select test.mk_user('h3_sales', 'va', 'sales');
select test.mk_owner('h3_o');
select test.mk_vehicle('H3V', 'h3_o');
select test.mk_renter('h3_a');
select test.mk_renter('h3_b');
select test.mk_renter('h3_c');
select test.mk_renter('h3_d');
create function test.h3_t(p interval) returns text language sql stable as $$
  select to_char((now() + p) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI') $$;

-- ---------------------------------------------------------------- 1. the wording
select test.ok('wording: the settlement waits for the Check-out statement (the return)',
  position('the Check-out statement' in pg_get_functiondef('app.charge_after_rental(uuid, uuid, timestamp with time zone)'::regprocedure)) > 0);
select test.ok('wording: the pickup is the check-in in the history of a pickup recorded later',
  position('case p_kind when ''pickup'' then ''Check-in'' else ''Check-out'' end' in pg_get_functiondef('app.handover_details_complete(uuid, text, uuid, jsonb, uuid, timestamp with time zone)'::regprocedure)) > 0);
select test.ok('wording: a licence checked face to face keeps its words',
  position('checked in person at the check-in by' in pg_get_functiondef('app.field_identity_in_person(uuid, jsonb)'::regprocedure)) > 0);
select test.eq('wording: the return is the check-out in the status history',
  (select note from status_transitions where entity = 'booking' and from_status = 'on_rent' and to_status = 'returned'), 'Check-out');
select test.ok('wording: the return job notice reads "Check-out (return)"',
  exists (select 1 from pg_proc p where p.proname = 'ntf_payload_base' and position('Check-out (return)' in pg_get_functiondef(p.oid)) > 0));
select test.ok('wording: no task rule says the return is the check-in',
  not exists (select 1 from task_rules where description ~* 'within 7 business days of check-in'));
select test.eq('wording: the mid-trip text is not called a check-in',
  (select label from sms_templates where code = 'renter_trip_checkin'), 'Mid-trip check');
select test.ok('wording: the return email says checked out',
  (select preheader from notification_catalogue where code = 'renter_return_complete') like 'Checked out at%');
select test.ok('wording: the review request follows the check-out',
  (select timing from notification_catalogue where code = 'renter_review_ask') like '%after the check-out%');

-- ---------------------------------------------------------------- 2. expired offers become leads
select test.mk_booking('H3-1', 'H3V', 'h3_a', test.h3_t(interval '9 days'), test.h3_t(interval '11 days'), 'expired');
select test.mk_booking('H3-2', 'H3V', 'h3_b', test.h3_t(interval '9 days'), test.h3_t(interval '11 days'), 'expired');
select test.mk_booking('H3-3', 'H3V', 'h3_c', test.h3_t(interval '9 days'), test.h3_t(interval '11 days'), 'expired');
select test.mk_booking('H3-4', 'H3V', 'h3_d', test.h3_t(interval '9 days'), test.h3_t(interval '11 days'), 'expired');
insert into booking_events (booking_id, kind, from_status, to_status, actor_type, created_at)
select test.id('booking:' || n), 'offer_expired', 'offered', 'expired', 'system', now() - d
  from (values ('H3-1', interval '8 days'), ('H3-2', interval '3 days'), ('H3-3', interval '9 days'), ('H3-4', interval '10 days')) v(n, d);
update renters set is_blocked = true, blocked_reason = 'test' where id = test.id('renter:h3_c');
-- h3_d booked a car after the offer expired
select test.mk_booking('H3-5', 'H3V', 'h3_d', test.h3_t(interval '-20 days'), test.h3_t(interval '-18 days'), 'closed');
update bookings set created_at = now() - interval '2 days' where id = test.id('booking:H3-5');

select test.eq('leads: the job makes one lead for the offer expired 8 days ago, none for 3 days, a blocked renter or a renter who booked anyway',
  (select app.expired_offers_to_leads(now())), 1);
select test.eq('leads: it is the renter of H3-1, source expired_offer, with the car and the dates wanted',
  (select concat_ws('/', kind, source, email, vehicle_text is not null, payload ->> 'booking_number', payload ->> 'form', status)
     from leads where source = 'expired_offer' and payload ->> 'booking_id' = test.id('booking:H3-1')::text),
  'contact/expired_offer/h3_a@example.test/t/H3-1/expired_offer/new');
select test.ok('leads: the message names the car and the dates',
  (select message like '%Mercedes-Benz C 300 H3V%expired on%' from leads where source = 'expired_offer' and payload ->> 'booking_id' = test.id('booking:H3-1')::text));
select test.eq('leads: a follow-up To do for Sales, once',
  (select count(*) from tasks where task_type = 'expired_offer_lead' and related_id = (select id from leads where source = 'expired_offer' and payload ->> 'booking_id' = test.id('booking:H3-1')::text))::integer, 1);
select test.eq('leads: the To do is in the Sales queue',
  (select queue from tasks where task_type = 'expired_offer_lead' limit 1), 'sales');
select test.eq('leads: once per booking (a second run makes none)', (select app.expired_offers_to_leads(now())), 0);
select test.eq('leads: the unique index also refuses a second lead for a booking',
  (select count(*) from leads where source = 'expired_offer')::integer, 1);
select test.throws('leads: a second lead for the same booking is refused by the database',
  format($$insert into leads (kind, email, source, payload) values ('contact', 'x@example.test', 'expired_offer', jsonb_build_object('booking_id', %L))$$, test.id('booking:H3-1')::text), 'leads_expired_offer_once');
select test.eq('leads: five days later the offer expired 3 days ago is a lead too', (select app.expired_offers_to_leads(now() + interval '5 days')), 1);
select test.ok('leads: the scheduled job runs it (job_capture, or a step it wraps)', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'app' and p.proname like 'job_capture%' and position('expired_offers_to_leads' in pg_get_functiondef(p.oid)) > 0));
select test.ok('leads: only the server job runs it', not has_function_privilege('authenticated', 'app.expired_offers_to_leads(timestamp with time zone)', 'execute'));
select test.ok('leads: a booking staff reopened is not a lead',
  (select app.expired_offers_to_leads(now() + interval '30 days')) >= 0
  and not exists (select 1 from leads where source = 'expired_offer' and payload ->> 'booking_id' = test.id('booking:H3-3')::text)
  and not exists (select 1 from leads where source = 'expired_offer' and payload ->> 'booking_id' = test.id('booking:H3-4')::text));

-- ---------------------------------------------------------------- 3. change your own email
create function test.h3_chk(p_user text, p_email text) returns jsonb language sql as $$
  select public.server_account_email_change_check(test.id(p_user), p_email) $$;
select test.eq('email: a new address can be asked for', (select test.h3_chk('h3_a', 'h3-new@example.test') ->> 'ok'), 'true');
select test.eq('email: a bad address is refused', (select test.h3_chk('h3_a', 'nope') ->> 'error'), 'invalid');
select test.eq('email: the same address is refused', (select test.h3_chk('h3_a', 'H3_A@example.test') ->> 'error'), 'same');
select test.eq('email: another account''s address is refused', (select test.h3_chk('h3_a', 'h3_b@example.test') ->> 'error'), 'email_taken');
select test.eq('email: nothing changes before the link is opened',
  (select email from users where id = test.id('h3_a')) || '/' || (select email from renters where id = test.id('renter:h3_a')), 'h3_a@example.test/h3_a@example.test');
select test.eq('email: once confirmed, the account follows', (select public.server_account_email_changed(test.id('h3_a'), 'h3-new@example.test') ->> 'changed'), 'true');
select test.eq('email: the account, renter and account-holder driver records hold the new address',
  (select email from users where id = test.id('h3_a')) || '/' || (select email from renters where id = test.id('renter:h3_a')) || '/'
  || (select email from drivers where id = test.id('driver:h3_a')), 'h3-new@example.test/h3-new@example.test/h3-new@example.test');
select test.ok('email: the new address counts as confirmed', (select email_verified_at is not null from users where id = test.id('h3_a')));
select test.eq('email: asking again for the same address changes nothing', (select public.server_account_email_changed(test.id('h3_a'), 'h3-new@example.test') ->> 'changed'), 'false');
select test.eq('email: an address of another account is not taken over', (select public.server_account_email_changed(test.id('h3_a'), 'h3_b@example.test') ->> 'reason'), 'email_taken');
select test.eq('email: a staff member''s account changes too (the account alone)',
  (select public.server_account_email_changed(test.id('h3_sales'), 'h3-sales2@example.test') ->> 'changed'), 'true');
select test.eq('email: ... and holds it', (select email from users where id = test.id('h3_sales')), 'h3-sales2@example.test');
select test.ok('email: only the server calls these',
  not has_function_privilege('authenticated', 'public.server_account_email_changed(uuid, text)', 'execute')
  and not has_function_privilege('anon', 'public.server_account_email_change_check(uuid, text)', 'execute')
  and not has_function_privilege('authenticated', 'app.account_email_changed(uuid, text)', 'execute'));
select test.ok('email: the first-email rule points to the profile',
  position('use Change my email on your profile' in pg_get_functiondef('app.account_set_email(uuid, text)'::regprocedure)) > 0);
