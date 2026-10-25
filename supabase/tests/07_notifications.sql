-- 07: the notification layer (migration 0018) and its wiring (migration 0023).
-- Runs after every migration and after the earlier test files, so the events those files produced
-- (real business actions of 0016 to 0022) are processed here first and checked for duplicates.
-- Times used by this file's own fixtures are in 2031, Toronto time, so nothing collides with them.
select test.suite('07 notifications');

create or replace function test.at(p_local text) returns timestamptz
language sql immutable as $$ select p_local::timestamp at time zone 'America/Toronto' $$;
-- outbox rows of one code for one entity
create or replace function test.ob(p_code text, p_entity uuid) returns bigint
language sql stable as $$ select count(*) from notification_outbox where code = p_code and entity_id = p_entity $$;
create or replace function test.ev(p_code text, p_entity uuid) returns bigint
language sql stable as $$ select count(*) from app_events where code = p_code and entity_id = p_entity $$;
create or replace function test.flush() returns integer
language sql as $$ select app.process_events(100000) $$;

-- ================================================================== A. catalogue
select test.eq('A the catalogue holds every email of emails/catalogue.json plus the in-app notices (0043 cap, 0044 document to sign)',
  (select count(*) filter (where has_email and in_catalogue) || '/' || count(*) filter (where not has_email) from notification_catalogue), '185/4');
select test.eq('A the two emails added here are in the catalogue',
  (select string_agg(code, ',' order by code) from notification_catalogue where code in ('renter_named_to_authority', 'staff_monthly_statements_ready')),
  'renter_named_to_authority,staff_monthly_statements_ready');
select test.eq('A every path of emails/src/links.mjs is loaded', (select count(*) from notification_link_paths), 79::bigint);
select test.eq('A every email code says what emits it; only the two sign-in service emails are emitted by nobody (the sign-in link is the owner invitation''s, 0029)',
  (select string_agg(code, ',' order by code) from notification_catalogue where has_email and (emitted_by is null or emitted_by like 'not emitted%')),
  'account_password_reset,account_security_notice');
select test.eq('A no catalogue text names the numbered company',
  (select count(*) from notification_catalogue where concat(subject, preheader, trigger_text, variables::text) ~ '18122211|operated by'), 0::bigint);
select test.eq('A priority classes: customer, owner and investor, staff, digests, marketing',
  (select string_agg(distinct priority::text || ':' || case when category = 'marketing' then 'mkt' when audience like 'staff%' then 'staff' else audience end, ',')
     from notification_catalogue where code in ('renter_offer_ready', 'owner_fee_invoice', 'staff_booking_request_new', 'staff_digest_morning_admin', 'renter_comeback_1w')),
  '1:renter,2:owner,3:staff,4:staff,5:mkt');
select test.eq('A each come-back email needs express consent, the review request implied consent',
  (select string_agg(code || '=' || consent_rule, ',' order by code) from notification_catalogue where category = 'marketing'),
  'owner_recruit_outreach=express,renter_comeback_1m=express,renter_comeback_1w=express,renter_google_review_request=implied,renter_promo_expiry_1d=express,renter_promo_expiry_3d=express,renter_recovery_request=express,renter_review_ask=implied,renter_review_final=implied,renter_review_reminder=implied,renter_review_request=implied');
select test.ok('A every program setting the layer reads has a value',
  (select notify_daily_cap = 100 and notify_class_limits = array[97, 95, 90, 80, 60] and notify_comeback_1w_bps = 1000
          and notify_comeback_1m_bps = 1500 and notify_comeback_valid_days = 30 and notify_digest_morning = time '07:30'
     from app.settings()));

-- ================================================================== B. the flows of the earlier files, processed
select test.ok('B every event of the earlier test files is processed in one pass', test.flush() > 0);
select test.eq('B nothing is left unprocessed', (select count(*) from app_events where processed_at is null), 0::bigint);
select test.eq('B processing again writes nothing new', test.flush(), 0);
select test.eq('B no outbox row has a variable the database should have built',
  (select string_agg(distinct code || ':' || array_to_string(missing_variables, ','), '; ') from notification_outbox where missing_variables <> '{}'), null::text);
select test.eq('B one request is one acknowledgement to its renter',
  (select count(*) from (select e.id from app_events e left join notification_outbox o on o.event_id = e.id
                          where e.code = 'renter_request_received' group by e.id having count(o.id) <> 1) x), 0::bigint);
select test.eq('B no booking is announced as requested twice',
  (select count(*) from (select entity_id from app_events where code = 'renter_request_received' group by entity_id having count(*) > 1) x), 0::bigint);
select test.ok('B a new request reaches every active customer service assistant once, never twice',
  (select bool_and(n = (select count(*) from users u join staff_profiles sp on sp.user_id = u.id
                          where u.status = 'active' and sp.is_active and sp.va_function = 'cs') and n = d)
     from (select count(*) n, count(distinct recipient_user_id) d from notification_outbox where code = 'staff_booking_request_new' group by event_id) x));
select test.eq('B a booking that went to confirmed gets exactly one confirmation and its owner one new-booking notice',
  (select count(*) from bookings b
    where b.booking_type <> 'owner'
      and exists (select 1 from status_history h where h.entity = 'booking' and h.entity_id = b.id and h.to_status = 'confirmed' and h.from_status is not null)
      and (test.ob('renter_booking_confirmed', b.id) <> 1 or test.ob('owner_new_booking', b.id) <> 1)), 0::bigint);
select test.eq('B the payment that confirms a booking never gets a separate receipt (the confirmation carries it)',
  (select count(*) from notification_outbox o join payments p on p.id = o.entity_id where o.code = 'renter_payment_receipt' and p.purpose = 'booking_total'), 0::bigint);
select test.eq('B an extension request is acknowledged once (0019 emits it; nothing here emits it again)',
  (select count(*) from (select entity_id from notification_outbox where code = 'renter_extension_requested' group by entity_id having count(*) > 1) x), 0::bigint);
select test.eq('B no event code is emitted both by a function of 0019 to 0022 and by this layer for the same record',
  (select count(*) from (select code, entity_id, dedupe_key from app_events where dedupe_key is not null group by 1, 2, 3 having count(*) > 1) x), 0::bigint);
select test.eq('B every email of the earlier flows is queued, with its sender address',
  (select count(*) from notification_outbox o where o.status = 'queued' and o.to_address is null), 0::bigint);

-- the earlier rows are put aside so the counts below are this file's own
update notification_outbox set status = 'sent', sent_at = timestamptz '2020-01-01 12:00+00' where status in ('queued', 'delayed');
update staff_digest_items set digested_at = timestamptz '2020-01-01 12:00+00' where digested_at is null;

-- ================================================================== fixtures
-- contact details shown in every email come from the site settings (restored at the end)
create table test.nt_site as select id, phone, mailing_address, roadside_phone from site_settings;
update site_settings set phone = '647-555-0100', mailing_address = '100 Sample Street, Toronto, Ontario', roadside_phone = '1-800-555-0199';
select test.mk_user('nt_admin', 'admin');
select test.mk_user('nt_fin', 'va', 'finance');
select test.mk_user('nt_fleet', 'va', 'fleet');
select test.mk_user('nt_cs', 'va', 'cs');
select test.mk_user('nt_sales', 'va', 'sales');
select test.mk_user('nt_field', 'field');
select test.mk_owner('nt_olga');
select test.mk_vehicle('NT1', 'nt_olga');
select test.mk_renter('nt_rita');
select test.mk_renter('nt_rob');
select test.mk_renter('nt_cara');
insert into consents (user_id, consent_code, text_version, text_shown, given_at)
values (test.id('nt_rita'), 'marketing', 'v1', 'Send me offers from CarmaCars', now()),
       (test.id('nt_cara'), 'marketing', 'v1', 'Send me offers from CarmaCars', now());
-- only this file's staff are active while it runs (restored at the end), so recipients can be named
create table test.nt_suspended as select id from users where status = 'active' and (
  id in (select user_id from staff_profiles) or id in (select user_id from user_roles where role = 'admin'))
  and id <> all (array[test.id('nt_admin'), test.id('nt_fin'), test.id('nt_fleet'), test.id('nt_cs'), test.id('nt_sales'), test.id('nt_field')]);
update users set status = 'suspended' where id in (select id from test.nt_suspended);
select test.flush();
update notification_outbox set status = 'sent', sent_at = timestamptz '2020-01-01 12:00+00' where status in ('queued', 'delayed');

-- ================================================================== C. wired events: one row per recipient, to the right person
-- C1 a request
select test.mk_booking('NT-1', 'NT1', 'nt_rita', '2031-03-10 10:00', '2031-03-13 10:00', 'requested');
insert into booking_events (booking_id, kind, from_status, to_status, actor_type) values (test.id('booking:NT-1'), 'requested', null, 'requested', 'renter');
insert into booking_events (booking_id, kind, from_status, to_status, actor_type) values (test.id('booking:NT-1'), 'requested', null, 'requested', 'renter');
select test.flush();
select test.eq('C a request (logged twice) is one event, one email to the renter, one to customer service',
  (select string_agg(o.code || '>' || o.to_address, ',' order by o.code) from notification_outbox o where o.entity_id = test.id('booking:NT-1')),
  'renter_request_received>nt_rita@example.test,staff_booking_request_new>nt_cs@example.test');
select test.eq('C the renter also has the in-app notice, its title filled in, with the request link',
  (select (title not like '%{{%') || ' | ' || url from notifications where user_id = test.id('nt_rita') and code = 'renter_request_received'),
  'true | https://carmacars.ca/account/bookings/NT-1/request');

-- C2 confirmed, on rent, returned
select test.mk_booking('NT-2', 'NT1', 'nt_rita', '2031-04-07 10:00', '2031-04-10 10:00', 'pending_payment');
insert into documents (id, kind, storage_bucket, storage_path, booking_id) values (test.id('doc:NT-2'), 'rental_agreement', 'agreements', 'bookings/NT-2/agreement.pdf', test.id('booking:NT-2'));
insert into signature_requests (id, document_id, provider, provider_envelope, status, completed_at) values (test.id('sig:NT-2'), test.id('doc:NT-2'), 'esign', 'env-NT-2', 'completed', now());
update bookings set signature_request_id = test.id('sig:NT-2'), agreement_document_id = test.id('doc:NT-2') where id = test.id('booking:NT-2');
update bookings set status = 'confirmed' where id = test.id('booking:NT-2');
select test.flush();
select test.eq('C confirmation: one email to the renter, one to the owner, and a digest line for customer service and fleet (pickup is far away)',
  (select string_agg(code || '>' || to_address, ',' order by code) from notification_outbox where entity_id = test.id('booking:NT-2'))
  || ' | ' || (select string_agg(role, ',' order by role) from staff_digest_items where entity_id = test.id('booking:NT-2') and code = 'staff_offer_approved_paid'),
  'owner_new_booking>nt_olga@example.test,renter_booking_confirmed>nt_rita@example.test | va_cs,va_fleet');
select test.eq('C the owner of a managed car does not get the renter''s name or phone',
  (select payload ->> 'renter_name' || '/' || (payload ->> 'renter_phone') from notification_outbox where code = 'owner_new_booking' and entity_id = test.id('booking:NT-2')), '/');
select test.eq('C money and dates are formatted the catalogue way (Toronto time)',
  (select payload ->> 'pickup_date' || ' ' || (payload ->> 'pickup_time') || ' ' || (payload ->> 'deposit_amount') || ' ' || (payload ->> 'km_allowance')
     from notification_outbox where code = 'renter_booking_confirmed' and entity_id = test.id('booking:NT-2')),
  'Mon, Apr 7, 2031 10:00 am $1,000.00 600 km');

-- C3 cancellations: small refund to the digests, a large one to the admins at once
select test.mk_booking('NT-3', 'NT1', 'nt_rob', '2031-05-10 10:00', '2031-05-13 10:00', 'confirmed', null, 'standard', null, '2031-05-01 10:00');
insert into booking_cancellations (booking_id, received_at, cancelled_by, reason) values (test.id('booking:NT-3'), test.at('2031-05-09 09:00'), 'renter', 'renter_request');
select test.mk_booking('NT-4', 'NT1', 'nt_rob', '2031-05-20 10:00', '2031-05-23 10:00', 'confirmed', 90000, 'standard', null, '2031-05-01 10:00');
insert into booking_cancellations (booking_id, received_at, cancelled_by, reason) values (test.id('booking:NT-4'), test.at('2031-05-02 09:00'), 'carmacars', 'carmacars_no_vehicle');
select test.flush();
select test.eq('C renter cancels: the cancellation email; finance and customer service get it in their digests',
  test.ob('renter_booking_cancelled', test.id('booking:NT-3')) || '/' || test.ob('staff_cancellation_received', test.id('booking:NT-3')) || '/'
  || (select string_agg(role, ',' order by role) from staff_digest_items where code = 'staff_cancellation_received' and entity_id = test.id('booking:NT-3')),
  '1/0/va_cs,va_finance');
select test.eq('C CarmaCars cancels with a refund over the admin threshold: the by-us email, and the admins at once (no digest)',
  test.ob('renter_booking_cancelled_by_us', test.id('booking:NT-4')) || '/' || test.ob('renter_booking_cancelled', test.id('booking:NT-4')) || '/'
  || (select string_agg(audience, ',') from notification_outbox where code = 'staff_cancellation_received' and entity_id = test.id('booking:NT-4')) || '/'
  || (select count(*) from staff_digest_items where code = 'staff_cancellation_received' and entity_id = test.id('booking:NT-4')),
  '1/0/staff_admin/0');

-- C4 payments and refunds
insert into payments (id, booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at, card_brand, card_last4)
values (test.id('pay:NT-2:ext'), test.id('booking:NT-2'), test.id('renter:nt_rita'), 'extension', 'charge', 'card', 11300, 'succeeded', now(), 'visa', '4242'),
       (test.id('pay:NT-2:toll'), test.id('booking:NT-2'), test.id('renter:nt_rita'), 'toll_ticket', 'charge', 'card', 5000, 'pending', null, 'visa', '4242');
update payments set status = 'failed', decline_count = 1 where id = test.id('pay:NT-2:toll');
update payments set decline_count = 2 where id = test.id('pay:NT-2:toll');
insert into refunds (id, booking_id, reason, amount_cents, status, paid_at, approved_by, approved_at) values (test.id('ref:NT-2'), test.id('booking:NT-2'), 'goodwill', 2500, 'paid', now(), test.id('nt_admin'), now());
select test.flush();
select test.eq('C a card charge gets a receipt; each decline of a later charge a failure email and a finance digest line; a paid refund its email',
  test.ob('renter_payment_receipt', test.id('pay:NT-2:ext')) || '/' || test.ob('renter_payment_failed', test.id('pay:NT-2:toll')) || '/'
  || (select count(*) from staff_digest_items where code = 'staff_payment_failed' and entity_id = test.id('pay:NT-2:toll')) || '/'
  || test.ob('renter_refund_issued', test.id('ref:NT-2')),
  '1/2/2/1');
select test.eq('C the receipt shows the amount and the card',
  (select payload ->> 'amount' || ' ' || (payload ->> 'card_brand') || ' ' || (payload ->> 'card_last4') from notification_outbox where code = 'renter_payment_receipt'
      and entity_id = test.id('pay:NT-2:ext')), '$113.00 Visa 4242');

-- C5 owner invoices
insert into owner_invoices (id, invoice_number, owner_id, vehicle_id, kind, period_month, billing_date, payment_method, status, fees_cents, hst_cents)
values (test.id('oi:NT:1'), 'OI-NT-1', test.id('owner:nt_olga'), test.id('vehicle:NT1'), 'monthly', date '2031-03-01', date '2031-03-15', 'pre_authorized_debit', 'issued', 47500, 6175),
       (test.id('oi:NT:2'), 'OI-NT-2', test.id('owner:nt_olga'), test.id('vehicle:NT1'), 'monthly', date '2031-04-01', date '2031-04-15', 'pre_authorized_debit', 'in_arrears', 47500, 6175);
select test.flush();
select test.eq('C a monthly invoice is one fee email to its owner',
  (select string_agg(code || '>' || to_address, ',') from notification_outbox where entity_id = test.id('oi:NT:1')), 'owner_fee_invoice>nt_olga@example.test');
select test.eq('C an invoice in arrears: the owner''s email, the admins at once, finance in its digest',
  (select string_agg(code || '>' || audience, ',' order by code, audience) from notification_outbox where entity_id = test.id('oi:NT:2'))
  || ' | ' || (select string_agg(role, ',') from staff_digest_items where entity_id = test.id('oi:NT:2')),
  'owner_in_arrears>owner,staff_owner_invoice_failed>staff_admin | va_finance');

-- C6 incidents, reviews, disputes, failed jobs, fleet count
select test.mk_booking('NT-5', 'NT1', 'nt_rita', '2031-06-01 10:00', '2031-06-01 18:00', 'on_rent');
insert into incidents (id, kind, vehicle_id, booking_id, occurred_at, place, drivable, anyone_hurt)
values (test.id('inc:NT'), 'accident', test.id('vehicle:NT1'), test.id('booking:NT-5'), now(), 'Queen St W', true, false);
select test.mk_booking('NT-6', 'NT1', 'nt_rita', '2031-01-05 10:00', '2031-01-07 10:00', 'closed');
insert into reviews (id, booking_id, renter_id, vehicle_id, rating) values (test.id('rev:NT6'), test.id('booking:NT-6'), test.id('renter:nt_rita'), test.id('vehicle:NT1'), 1);
insert into disputes (id, payment_id, booking_id, amount_cents, reason) values (test.id('dis:NT'), test.id('pay:NT-2:ext'), test.id('booking:NT-2'), 11300, 'fraudulent');
insert into job_runs (id, job_name, run_key) values (test.id('jr:NT'), 'test-notify', 'k1');
select app.job_fail(test.id('jr:NT'), 'it broke');
insert into fleet_counts (counted_on, on_policy, less_exit_notice, min_required, warned_admin) values (date '2031-02-03', 11, 10, 10, true);
select test.flush();
select test.eq('C an accident on a rental: the renter''s instructions, the owner''s notice, admins and fleet at once',
  (select string_agg(code || '>' || audience, ',' order by code, audience) from notification_outbox where entity_id = test.id('inc:NT')),
  'owner_incident_opened>owner,renter_accident_instructions>renter,staff_incident_reported>staff_admin,staff_incident_reported>staff_va_fleet');
select test.eq('C a 1-star review goes at once to customer service and the admins, not to the digest',
  (select string_agg(audience, ',' order by audience) from notification_outbox where entity_id = test.id('rev:NT6'))
  || '/' || (select count(*) from staff_digest_items where entity_id = test.id('rev:NT6')), 'staff_admin,staff_va_cs/0');
select test.eq('C a dispute reaches the admins and finance at once',
  (select string_agg(audience, ',' order by audience) from notification_outbox where entity_id = test.id('dis:NT')), 'staff_admin,staff_va_finance');
select test.eq('C a failed job is one email to each admin, with its name and error',
  (select count(*) || '/' || min(payload ->> 'job_name') || '/' || min(payload ->> 'job_error') from notification_outbox where entity_id = test.id('jr:NT')), '1/test-notify/it broke');
select test.eq('C the Monday recount at the warning level warns the admins',
  (select count(*) || '/' || min(payload ->> 'fleet_count_after') from notification_outbox o join fleet_counts f on f.id = o.entity_id
    where o.code = 'staff_fleet_count_warning' and f.counted_on = date '2031-02-03'), '1/10');

-- C7 roadside dispatch, the owner hears of claim progress
insert into incidents (id, kind, vehicle_id, booking_id, place, breakdown_cause) values (test.id('inc:NT:bd'), 'breakdown', test.id('vehicle:NT1'), test.id('booking:NT-5'), 'Hwy 401 at Keele', 'flat_battery');
select app.dispatch_roadside(test.id('inc:NT:bd'), 35, test.id('nt_fleet'));
select test.throws('C roadside is dispatched by staff only', format('select app.dispatch_roadside(%L, 35, %L)', test.id('inc:NT:bd'), test.id('nt_rita')), 'Not permitted');
select test.flush();
select test.eq('C a breakdown: fleet is told at once; the renter gets the roadside email with the arrival estimate',
  (select string_agg(code || '>' || audience, ',' order by code) from notification_outbox where entity_id = test.id('inc:NT:bd'))
  || '/' || (select payload ->> 'eta_minutes' from notification_outbox where code = 'renter_breakdown_help' and entity_id = test.id('inc:NT:bd')),
  'renter_breakdown_help>renter,staff_breakdown_reported>staff_va_fleet/35');

-- ================================================================== D. time-based jobs: once, at the right Toronto time
-- D1 booking reminder, identity chase and pickup details for NT-2 (pickup Mon Apr 7 2031 10:00)
insert into field_jobs (id, kind, booking_id, vehicle_id, assigned_to, scheduled_at, place, instructions)
values (test.id('job:NT-2'), 'handover', test.id('booking:NT-2'), test.id('vehicle:NT1'), test.id('nt_field'), test.at('2031-04-07 10:00'), 'Union Station', 'Meet at the taxi stand');
select app.notify_reminders(test.at('2031-04-05 09:00'));
select test.eq('D 49 hours before pickup: nothing yet', test.ev('renter_identity_needed', test.id('booking:NT-2')) + test.ev('renter_booking_reminder', test.id('booking:NT-2')), 0::bigint);
select app.notify_reminders(test.at('2031-04-05 11:00'));
select test.eq('D 47 hours before: the identity chase (coverage proof is missing), not yet the reminder',
  test.ev('renter_identity_needed', test.id('booking:NT-2')) || '/' || test.ev('renter_booking_reminder', test.id('booking:NT-2')), '1/0');
select app.notify_reminders(test.at('2031-04-06 10:30'));
select app.notify_reminders(test.at('2031-04-06 11:00'));
select test.eq('D from 24 hours before: one booking reminder, however often the job runs',
  test.ev('renter_booking_reminder', test.id('booking:NT-2')) || '/' || test.ev('renter_identity_needed', test.id('booking:NT-2')), '1/1');
select app.notify_reminders(test.at('2031-04-07 06:30'));
select test.eq('D 3.5 hours before: no pickup details yet', test.ev('renter_pickup_details', test.id('booking:NT-2')), 0::bigint);
select app.notify_reminders(test.at('2031-04-07 07:30'));
select app.notify_reminders(test.at('2031-04-07 07:35'));
select test.eq('D 2.5 hours before: one pickup details email', test.ev('renter_pickup_details', test.id('booking:NT-2')), 1::bigint);
update field_jobs set place = 'Union Station, York St door' where id = test.id('job:NT-2');
select app.ntf_field_job_details((select j from field_jobs j where j.id = test.id('job:NT-2')), test.at('2031-04-07 08:00'));
select app.notify_reminders(test.at('2031-04-07 08:05'));
select test.eq('D the place changes after sending: sent again once, with the new place',
  test.ev('renter_pickup_details', test.id('booking:NT-2')), 2::bigint);
select test.flush();
select test.eq('D the pickup details name the field staff member and the meeting note',
  (select payload ->> 'field_staff_name' || ' / ' || (payload ->> 'meeting_note') from notification_outbox where code = 'renter_pickup_details'
    and entity_id = test.id('booking:NT-2') order by created_at desc limit 1), 'Nt / Meet at the taxi stand');

-- D2 return reminder and late returns for NT-5 (on rent, return Sun Jun 1 2031 18:00)
select app.notify_reminders(test.at('2031-05-31 17:00'));
select test.eq('D 25 hours before the return: no reminder', test.ev('renter_return_reminder', test.id('booking:NT-5')), 0::bigint);
select app.notify_reminders(test.at('2031-05-31 18:30'));
select app.notify_reminders(test.at('2031-05-31 19:00'));
select test.eq('D inside 24 hours: one return reminder', test.ev('renter_return_reminder', test.id('booking:NT-5')), 1::bigint);
select app.notify_reminders(test.at('2031-06-01 18:01'));
select app.notify_reminders(test.at('2031-06-01 18:06'));
select test.eq('D at the return time: the first late notice to the renter and the 0-minute alert to fleet, once',
  test.ev('renter_late_return_first', test.id('booking:NT-5')) || '/' || test.ev('staff_late_return_alert', test.id('booking:NT-5')) || '/'
  || test.ev('renter_late_return_final', test.id('booking:NT-5')), '1/1/0');
select app.notify_reminders(test.at('2031-06-01 18:31'));
select test.eq('D at 30 minutes: the second fleet alert', test.ev('staff_late_return_alert', test.id('booking:NT-5')), 2::bigint);
select app.notify_reminders(test.at('2031-06-01 20:01'));
select app.notify_reminders(test.at('2031-06-01 20:30'));
select test.eq('D at the final stage (late_admin_minutes): the final notice and one alert to fleet and the admins',
  test.ev('renter_late_return_final', test.id('booking:NT-5')) || '/' || test.ev('staff_late_return_alert', test.id('booking:NT-5')), '1/3');
select test.flush();
select test.eq('D the final alert goes to fleet and admins; the earlier ones to fleet only',
  (select string_agg(audience, ',' order by audience) from notification_outbox o join app_events e on e.id = o.event_id
    where e.code = 'staff_late_return_alert' and e.entity_id = test.id('booking:NT-5') and e.dedupe_key like '%:final:%'), 'staff_admin,staff_va_fleet');

-- D3 offer reminder (24-hour window: 6 hours before) and a request left waiting
select test.mk_booking('NT-7', 'NT1', 'nt_rob', '2031-07-10 10:00', '2031-07-12 10:00', 'offered');
insert into booking_offers (booking_id, version, sent_at, expires_at, vehicle_id, pickup_at, return_at, billable_days, rental_charge_cents,
                            discount_cents, deposit_cents, subtotal_cents, hst_cents, total_cents, insurer_share_cents, renter_due_cents, terms, line_items)
values (test.id('booking:NT-7'), 1, test.at('2031-07-01 10:00'), test.at('2031-07-02 10:00'), test.id('vehicle:NT1'), test.at('2031-07-10 10:00'),
        test.at('2031-07-12 10:00'), 2, 20000, 0, 100000, 20000, 2600, 22600, 0, 22600, '{}', '[]');
update bookings set current_offer_version = 1, offer_expires_at = test.at('2031-07-02 10:00') where id = test.id('booking:NT-7');
select app.notify_reminders(test.at('2031-07-02 03:30'));
select test.eq('D 6.5 hours before the offer expires: no reminder', test.ev('renter_offer_reminder', test.id('booking:NT-7')), 0::bigint);
select app.notify_reminders(test.at('2031-07-02 04:30'));
select app.notify_reminders(test.at('2031-07-02 05:00'));
select test.eq('D 5.5 hours before: one reminder, saying how long is left',
  test.ev('renter_offer_reminder', test.id('booking:NT-7')) || '/' || (select payload ->> 'time_left' from app_events where code = 'renter_offer_reminder' and entity_id = test.id('booking:NT-7')),
  '1/5 hours');
select test.mk_booking('NT-8', 'NT1', 'nt_rob', '2031-07-20 10:00', '2031-07-22 10:00', 'requested');
update bookings set requested_at = test.at('2031-07-05 10:00') where id = test.id('booking:NT-8');
select app.notify_reminders(test.at('2031-07-05 11:55'));
select test.eq('D a request 1 hour 55 minutes old is not yet waiting', test.ev('staff_request_waiting', test.id('booking:NT-8')), 0::bigint);
select app.notify_reminders(test.at('2031-07-05 12:05'));
select app.notify_reminders(test.at('2031-07-05 12:10'));
select test.flush();
select test.eq('D past 2 hours: customer service and the admins are told once',
  (select string_agg(audience, ',' order by audience) from notification_outbox where code = 'staff_request_waiting' and entity_id = test.id('booking:NT-8')),
  'staff_admin,staff_va_cs');

-- D4 follow-ups after closing: review request at 2 days, come-back offers at 7 and 30 days
select test.mk_booking('NT-9', 'NT1', 'nt_cara', '2031-08-01 10:00', '2031-08-03 10:00', 'closed');
select test.mk_booking('NT-10', 'NT1', 'nt_rob', '2031-08-04 10:00', '2031-08-06 10:00', 'closed');
insert into status_history (entity, entity_id, from_status, to_status, changed_at) values
  ('booking', test.id('booking:NT-9'), 'returned', 'closed', test.at('2031-08-05 15:00')),
  ('booking', test.id('booking:NT-10'), 'returned', 'closed', test.at('2031-08-05 15:00'));
select app.notify_followups(test.at('2031-08-06 10:00'));
select test.eq('D one day after closing: no follow-up', test.ev('renter_review_request', test.id('booking:NT-9')), 0::bigint);
select app.notify_followups(test.at('2031-08-07 10:00'));
select app.notify_followups(test.at('2031-08-07 11:00'));
select test.eq('D two days after: one review request to each renter who has not unsubscribed',
  test.ev('renter_review_request', test.id('booking:NT-9')) || '/' || test.ev('renter_review_request', test.id('booking:NT-10')), '1/1');
select app.notify_followups(test.at('2031-08-12 10:00'));
select app.notify_followups(test.at('2031-08-12 18:00'));
select test.eq('D seven days after: the 1-week offer only to the renter with marketing consent, once',
  test.ev('renter_comeback_1w', test.id('booking:NT-9')) || '/' || test.ev('renter_comeback_1w', test.id('booking:NT-10')), '1/0');
select test.eq('D the offer carries a new single-use code for that renter only, 10% for 30 days',
  (select p.source || '/' || p.percent_bps || '/' || p.max_uses || '/' || (p.renter_id = test.id('renter:nt_cara')) || '/' || (e.payload ->> 'discount_code' = p.code)
          || '/' || (e.payload ->> 'discount_percent') || '/' || (e.payload ->> 'discount_expires')
     from marketing_sends m join promo_codes p on p.id = m.promo_code_id
     join app_events e on e.code = m.code and e.entity_id = m.booking_id
    where m.code = 'renter_comeback_1w' and m.booking_id = test.id('booking:NT-9')),
  'followup_7d/1000/1/true/true/10/Thu, Sep 11, 2031');
select app.notify_followups(test.at('2031-09-04 10:00'));
select test.eq('D thirty days after: the 1-month offer at 15%, from followup_30d',
  (select p.source || '/' || p.percent_bps from marketing_sends m join promo_codes p on p.id = m.promo_code_id
    where m.code = 'renter_comeback_1m' and m.booking_id = test.id('booking:NT-9')), 'followup_30d/1500');
select test.flush();
select test.eq('D marketing emails carry a one-click unsubscribe link',
  (select bool_and(payload ->> 'unsubscribe_url' like 'https://carmacars.ca/unsubscribe?token=%' and unsubscribe_token is not null)::text
     from notification_outbox where code in ('renter_comeback_1w', 'renter_comeback_1m', 'renter_review_request') and booking_id in (test.id('booking:NT-9'), test.id('booking:NT-10'))),
  'true');
-- a renter with an open incident gets no follow-up
select test.mk_booking('NT-11', 'NT1', 'nt_rita', '2031-08-01 10:00', '2031-08-02 10:00', 'closed');
insert into status_history (entity, entity_id, from_status, to_status, changed_at) values ('booking', test.id('booking:NT-11'), 'returned', 'closed', test.at('2031-08-05 15:00'));
insert into incidents (kind, vehicle_id, booking_id) values ('damage_found_later', test.id('vehicle:NT1'), test.id('booking:NT-11'));
select app.notify_followups(test.at('2031-08-07 12:00'));
select test.eq('D a booking with an open incident gets no review request', test.ev('renter_review_request', test.id('booking:NT-11')), 0::bigint);

-- D5 balance overdue: once at 7 days, then on the 1st; the final statement when sent
insert into booking_statements (id, booking_id, statement_number, kind, issued_at, sent_at, charges_cents, hst_cents, deposit_applied_cents, held_back_cents,
                                deposit_returned_cents, charged_to_card_cents)
values (test.id('bs:NT-5'), test.id('booking:NT-5'), 'ST-NT-5', 'check_in', test.at('2031-06-02 12:00'), test.at('2031-06-02 12:00'), 30000, 3900, 0, 0, 0, 0);
select app.notify_daily_checks(test.at('2031-06-08 06:30'));
select test.eq('D six days after the statement: no overdue notice', test.ev('renter_balance_overdue', test.id('bs:NT-5')), 0::bigint);
select app.notify_daily_checks(test.at('2031-06-09 06:30'));
select app.notify_daily_checks(test.at('2031-06-10 06:30'));
select test.eq('D seven days after: one notice; the final statement went out when it was sent',
  test.ev('renter_balance_overdue', test.id('bs:NT-5')) || '/' || test.ev('renter_final_statement', test.id('bs:NT-5')), '1/1');
select app.notify_daily_checks(test.at('2031-07-01 06:30'));
select test.eq('D on the 1st, while unpaid: again', test.ev('renter_balance_overdue', test.id('bs:NT-5')), 2::bigint);

-- D6 the scheduled wrapper: each part once, at its Toronto time (Tue Feb 4, 2031)
insert into field_jobs (id, kind, booking_id, vehicle_id, assigned_to, scheduled_at, place)
values (test.id('job:NT-feb'), 'detail', null, test.id('vehicle:NT1'), test.id('nt_field'), test.at('2031-02-04 13:00'), 'Yard');
insert into reviews (id, booking_id, renter_id, vehicle_id, rating) values (test.id('rev:NT9'), test.id('booking:NT-9'), test.id('renter:nt_cara'), test.id('vehicle:NT1'), 5);
select test.flush();
select test.eq('D a 5-star review waits for the customer service and admin digests (no email of its own)',
  (select count(*) from notification_outbox where entity_id = test.id('rev:NT9')) || '/' || (select string_agg(role, ',' order by role) from staff_digest_items where entity_id = test.id('rev:NT9')),
  '0/admin,va_cs');
update staff_digest_items set created_at = test.at('2031-02-04 06:00') where entity_id = test.id('rev:NT9');
select test.eq('D 05:59: nothing is due', app.job_notify_scheduled(test.at('2031-02-04 05:59')), 'not_due');
select test.eq('D 06:01: the daily checks', app.job_notify_scheduled(test.at('2031-02-04 06:01')), 'succeeded');
select test.eq('D 07:01: the field list for today is due', app.job_notify_scheduled(test.at('2031-02-04 07:01')), 'succeeded');
select test.eq('D 07:29: nothing more', app.job_notify_scheduled(test.at('2031-02-04 07:29')), 'not_due');
select test.eq('D 07:31: the morning digests', app.job_notify_scheduled(test.at('2031-02-04 07:31')), 'succeeded');
select test.eq('D 07:45: already run', app.job_notify_scheduled(test.at('2031-02-04 07:45')), 'not_due');
select test.eq('D each part ran once for the day',
  (select string_agg(job_name || '=' || status, ',' order by job_name) from job_runs where run_key = '2031-02-04' and job_name like 'notify-%'),
  'notify-daily-checks=succeeded,notify-digest-morning=succeeded,notify-field-today=succeeded');
select test.flush();
select test.eq('D the field staff member gets today''s list with the job',
  (select count(*) || '/' || min(payload ->> 'job_count') || '/' || min(payload ->> 'first_job_time') from notification_outbox
    where code = 'staff_field_jobs_today' and recipient_user_id = test.id('nt_field') and payload ->> 'digest_date' = 'Tue, Feb 4'), '1/1/1:00 pm');
select test.eq('D every active staff member gets the morning digest of their role, once',
  (select string_agg(code || '>' || split_part(to_address, '@', 1), ',' order by code) from notification_outbox
    where code like 'staff_digest_morning_%' and payload ->> 'digest_date' = 'Tue, Feb 4'),
  'staff_digest_morning_admin>nt_admin,staff_digest_morning_va_cs>nt_cs,staff_digest_morning_va_finance>nt_fin,staff_digest_morning_va_fleet>nt_fleet,staff_digest_morning_va_sales>nt_sales');
select test.ok('D the customer service digest lists the review under the new notices; the item is marked digested',
  (select (payload -> 'sections' -> 0 ->> 'title') = 'New since the last digest' and (payload -> 'sections' -> 0 ->> 'count')::integer >= 1
     from notification_outbox where code = 'staff_digest_morning_va_cs' and payload ->> 'digest_date' = 'Tue, Feb 4')
  and (select digested_at is not null and digest_code = 'staff_digest_morning_va_cs' from staff_digest_items where entity_id = test.id('rev:NT9') and role = 'va_cs'));
select test.eq('D 18:16: the evening run is due', app.job_notify_scheduled(test.at('2031-02-04 18:16')), 'succeeded');
select test.eq('D it ran the evening digests and tomorrow''s field list (none: no job tomorrow)',
  (select string_agg(job_name, ',' order by job_name) from job_runs where run_key = '2031-02-04' and job_name in ('notify-digest-eod', 'notify-field-tomorrow')),
  'notify-digest-eod,notify-field-tomorrow');
select test.eq('D the evening digest does not repeat what the morning one carried',
  (select count(*) from app_events where code like 'staff_digest_eod_%' and payload -> 'sections' @> '[{"title": "New since the last digest"}]'
      and dedupe_key like '%' || (select id from job_runs where job_name = 'notify-digest-eod' and run_key = '2031-02-04') || '%'), 0::bigint);
-- weekly summary: Monday Feb 10, 2031 from 07:45
select app.job_notify_scheduled(test.at('2031-02-10 07:44'));
select test.eq('D Monday 07:44: no weekly summary yet', (select count(*) from job_runs where job_name = 'notify-weekly-summary' and run_key = '2031-W07'), 0::bigint);
select app.job_notify_scheduled(test.at('2031-02-10 07:46'));
select app.job_notify_scheduled(test.at('2031-02-10 09:00'));
select test.flush();
select test.eq('D Monday 07:46: one weekly summary to each admin, for the week that ended Sunday',
  (select count(*) || '/' || min(payload ->> 'week_label') from notification_outbox where code = 'staff_weekly_summary' and payload ->> 'week_label' = 'Feb 3 to 9'), '1/Feb 3 to 9');
-- payouts due on the 10th from 08:00
insert into payouts (id, payee_type, owner_id, kind, amount_cents, scheduled_for, status) values
  (test.id('po:NT'), 'owner', test.id('owner:nt_olga'), 'other', 192225, date '2031-03-10', 'draft');
select app.job_notify_scheduled(test.at('2031-03-10 07:59'));
select test.eq('D 07:59 on the 10th: not yet', (select count(*) from app_events where code = 'staff_payouts_due' and dedupe_key like '%owner:2031-03-10'), 0::bigint);
select app.job_notify_scheduled(test.at('2031-03-10 08:01'));
select app.job_notify_scheduled(test.at('2031-03-10 08:30'));
select test.eq('D 08:01: one payouts-due notice, saying the run is not approved',
  (select count(*) || '/' || min(payload ->> 'run_approved') || '/' || min(payload ->> 'payout_total') from app_events where code = 'staff_payouts_due' and dedupe_key like '%owner:2031-03-10'),
  '1/false/$1,922.25');

-- ================================================================== E. consent, suppression, preferences
select test.eq('E without consent no come-back offer is written at all; the review request (implied) is sent',
  (select count(*) from marketing_sends where booking_id = test.id('booking:NT-10') and code like 'renter_comeback%') || '/' ||
  (select status from notification_outbox where code = 'renter_review_request' and booking_id = test.id('booking:NT-10')), '0/queued');
-- an unsubscribe through the link
select test.eq('E the unsubscribe page shows a masked address before the click',
  (select valid || '/' || masked_email || '/' || already_unsubscribed from app.unsubscribe_token_info(
     (select unsubscribe_token from notification_outbox where code = 'renter_comeback_1w' and booking_id = test.id('booking:NT-9')))), 'true/n***@example.test/false');
select test.eq('E an unknown token is not valid', (select valid::text from app.unsubscribe_token_info(gen_random_uuid())), 'false');
select test.ok('E the one-click unsubscribe works', app.unsubscribe((select unsubscribe_token from notification_outbox where code = 'renter_comeback_1w' and booking_id = test.id('booking:NT-9'))));
select test.ok('E and clicking twice is harmless', app.unsubscribe((select unsubscribe_token from notification_outbox where code = 'renter_comeback_1w' and booking_id = test.id('booking:NT-9'))));
select test.eq('E it stops marketing for the account and the address; queued marketing to her is suppressed',
  (select (marketing_unsubscribed_at is not null)::text from users where id = test.id('nt_cara')) || '/' ||
  (select count(*) from consents where user_id = test.id('nt_cara') and consent_code = 'marketing' and withdrawn_at is null) || '/' ||
  (select scope || ':' || reason from email_suppressions where email = 'nt_cara@example.test' and lifted_at is null) || '/' ||
  (select string_agg(distinct status, ',') from notification_outbox where category = 'marketing' and to_address = 'nt_cara@example.test'),
  'true/0/marketing:unsubscribe/suppressed');
select test.eq('E she no longer has marketing consent, express or implied',
  app.has_marketing_consent(test.id('nt_cara'), 'express')::text || '/' || app.has_marketing_consent(test.id('nt_cara'), 'implied')::text, 'false/false');
select app.ntf_emit('renter_review_request', 'booking', test.id('booking:NT-9'), 'test', jsonb_build_object('booking_id', test.id('booking:NT-9')));
select app.ntf_emit('renter_booking_reminder', 'booking', test.id('booking:NT-9'), 'test', jsonb_build_object('booking_id', test.id('booking:NT-9')));
select test.flush();
select test.eq('E marketing to an unsubscribed address is suppressed; her transactional email still goes',
  (select status from notification_outbox where code = 'renter_review_request' and booking_id = test.id('booking:NT-9') and dedupe_key like '%:test|%') || '/' ||
  (select status from notification_outbox where code = 'renter_booking_reminder' and booking_id = test.id('booking:NT-9') and dedupe_key like '%:test|%'), 'suppressed/queued');
-- preferences
select test.login(test.id('nt_rob'));
select test.throws('E a renter cannot turn off a booking email', $$select app.set_notification_preference('renter_booking_confirmed', false, true)$$, 'cannot be turned off');
select test.lives('E a renter can turn off review requests', $$select app.set_notification_preference('renter_review_request', false, true)$$);
select test.eq('E his preferences show it', (select email_enabled::text from app.my_notification_preferences() where code = 'renter_review_request'), 'false');
select test.logout();
select test.mk_booking('NT-12', 'NT1', 'nt_rob', '2031-01-10 10:00', '2031-01-11 10:00', 'closed');
select app.ntf_emit('renter_review_request', 'booking', test.id('booking:NT-12'), 'test', jsonb_build_object('booking_id', test.id('booking:NT-12')));
select test.flush();
select test.eq('E with email turned off the review request is skipped, and the reason is kept',
  (select status || '/' || status_reason from notification_outbox where code = 'renter_review_request' and booking_id = test.id('booking:NT-12')), 'skipped/turned off in preferences');
select test.eq('E and a marketing email that is not sent leaves no in-app notice either',
  (select count(*) from notifications where code = 'renter_review_request' and entity_id = test.id('booking:NT-12')), 0::bigint);

-- ================================================================== F. sender functions and the daily cap
update notification_outbox set status = 'sent', sent_at = timestamptz '2020-01-01 12:00+00' where status in ('queued', 'delayed', 'sending');
insert into program_settings select (jsonb_populate_record(null::program_settings, to_jsonb(app.settings()) || jsonb_build_object(
  'id', gen_random_uuid(), 'effective_from', '2031-09-01', 'notify_daily_cap', 5, 'notify_class_limits', array[5, 5, 4, 4, 2]))).*;
insert into notification_outbox (code, category, priority, audience, to_address, payload, dedupe_key, created_at, send_after)
select c, case when p = 5 then 'marketing' else 'transactional' end, p, 'renter', 'cap' || p || '_' || n || '@example.test', '{}', 'captest:' || p || ':' || n,
       now() + make_interval(secs => p * 10 + n), test.at('2031-09-02 09:00')
  from (values (1, 'renter_offer_ready'), (2, 'owner_fee_invoice'), (3, 'staff_dispute_opened'), (4, 'staff_weekly_summary'), (5, 'renter_review_request')) v(p, c),
       generate_series(1, 3) n;
select test.eq('F claim at noon with a cap of 5: the three customer emails, then two owner emails; nothing else',
  (select string_agg(left(to_address, 6), ',' order by to_address) from app.outbox_claim(100, test.at('2031-09-02 12:00'))), 'cap1_1,cap1_2,cap1_3,cap2_1,cap2_2');
select test.eq('F the rest is delayed to midnight, never dropped',
  (select count(*) || '/' || bool_and(send_after = test.at('2031-09-03 00:00'))::text from notification_outbox where dedupe_key like 'captest:%' and status = 'delayed'), '10/true');
select test.eq('F the admins have one in-app notice that the cap was hit',
  (select count(*) from notifications where code = 'staff_email_cap_reached' and dedupe_key like 'staff_email_cap_reached:2031-09-02|%'), 1::bigint);
select app.outbox_mark_sent(id, 'prov-' || left(to_address, 6), 'text body', test.at('2031-09-02 12:01')) from notification_outbox where dedupe_key like 'captest:%' and status = 'sending';
select test.eq('F a second claim the same day sends nothing more', (select count(*) from app.outbox_claim(100, test.at('2031-09-02 13:00'))), 0::bigint);
select test.eq('F the cap notice is not repeated that day', (select count(*) from notifications where code = 'staff_email_cap_reached' and dedupe_key like 'staff_email_cap_reached:2031-09-02|%'), 1::bigint);
-- sending reported back
select test.eq('F sent rows keep the provider id and a permanent messages row',
  (select count(*) from notification_outbox o join messages m on m.id = o.message_id
    where o.dedupe_key like 'captest:%' and o.status = 'sent' and m.provider_ref = o.provider_id and m.channel = 'email' and m.template_code = o.code), 5::bigint);
select test.eq('F next day the order holds: the owner email left over, then staff up to their limit of 4; digests and marketing wait',
  (select string_agg(left(to_address, 6), ',' order by to_address) from app.outbox_claim(100, test.at('2031-09-03 12:00'))), 'cap2_3,cap3_1,cap3_2,cap3_3');
-- failures and backoff
select test.eq('F a failed send is retried', app.outbox_mark_failed((select id from notification_outbox where dedupe_key = 'captest:2:3'), 'timeout', false, test.at('2031-09-03 12:01')), 'retry');
select test.eq('F after the backoff of the first attempt (1 minute)',
  (select (send_after = test.at('2031-09-03 12:02'))::text || '/' || status || '/' || last_error from notification_outbox where dedupe_key = 'captest:2:3'), 'true/queued/timeout');
update notification_outbox set status = 'sending', attempts = 3 where dedupe_key = 'captest:2:3';
select test.eq('F after the last attempt the row is failed', app.outbox_mark_failed((select id from notification_outbox where dedupe_key = 'captest:2:3'), 'timeout'), 'failed');
select test.throws('F only a row being sent can be marked sent', format('select app.outbox_mark_sent(%L, %L)', (select id from notification_outbox where dedupe_key = 'captest:2:3'), 'x'), 'not sending');
-- marketing outside its hours
select test.eq('F at 08:00 no marketing email is claimed', (select count(*) from app.outbox_claim(100, test.at('2031-09-04 08:00')) where category = 'marketing'), 0::bigint);
select test.eq('F it waits for the marketing hours',
  (select string_agg(distinct status_reason, ',') || '/' || bool_and(send_after = test.at('2031-09-04 10:00')) from notification_outbox where dedupe_key like 'captest:5:%'),
  'outside the marketing hours/true');
-- a bounce
select app.outbox_mark_sent(id, 'prov-bounce', null, test.at('2031-09-03 12:01')) from notification_outbox where dedupe_key = 'captest:3:1';
insert into notification_outbox (code, category, priority, audience, to_address, payload, dedupe_key) values
  ('renter_offer_ready', 'transactional', 1, 'renter', 'cap3_1@example.test', '{}', 'captest:after-bounce');
select app.outbox_record_bounce('prov-bounce', 'bounce', 'mailbox does not exist');
select test.eq('F a hard bounce suppresses the address for every email and stops what is queued for it',
  (select scope || ':' || reason from email_suppressions where email = 'cap3_1@example.test') || '/' ||
  (select status from notification_outbox where dedupe_key = 'captest:3:1') || '/' || (select status from notification_outbox where dedupe_key = 'captest:after-bounce'),
  'all:bounce/failed/suppressed');
update notification_outbox set status = 'sending', locked_at = test.at('2031-09-05 11:00') where dedupe_key = 'captest:4:2';
select test.eq('F a stale sending lock is released to the queue and claimed again',
  (select count(*) from app.outbox_claim(100, test.at('2031-09-05 12:00')) where left(to_address, 6) = 'cap4_2'), 1::bigint);
delete from program_settings where effective_from = date '2031-09-01';

-- ================================================================== G. payload completeness: every wired code
-- Codes the flows above did not reach are emitted once against this file's records, the way their
-- triggers or jobs would, then built. Every catalogue variable must be built here or be one the
-- sender supplies (catalogue.sender_supplied).
insert into tracker_devices (id, serial_number, vehicle_id, status, installed_at, tested_at) values (test.id('trk:NT1'), 'TRK-NT1', test.id('vehicle:NT1'), 'installed', now(), now());
-- records the emitters of 0019 to 0022 read from
insert into booking_extensions (id, booking_id, seq, status, requested_at, previous_return_at, new_return_at, previous_days, new_days,
                                previous_rental_charge_cents, new_rental_charge_cents, rental_difference_cents, fees_difference_cents, hst_cents, total_cents)
values (test.id('ext:NT-5'), test.id('booking:NT-5'), 1, 'requested', now(), test.at('2031-06-01 18:00'), test.at('2031-06-02 18:00'), 1, 2, 10000, 20000, 10000, 0, 1300, 11300);
insert into toll_tickets (id, kind, notice_number, authority, plate, vehicle_id, occurred_at, place, amount_cents, due_on, received_on, booking_id)
values (test.id('tt:NT'), 'camera_offence', 'RLC-1', 'City of Toronto', 'TNT1', test.id('vehicle:NT1'), test.at('2031-06-01 12:00'), 'Dundas St W', 32500,
        date '2031-07-01', date '2031-06-10', test.id('booking:NT-5'));
insert into owner_statements (id, statement_number, owner_id, statement_month, payout_date, status, owner_revenue_cents, revenue_share_cents, payout_cents)
values (test.id('st:NT'), 'OS-NT-1', test.id('owner:nt_olga'), date '2031-05-01', date '2031-06-10', 'draft', 65000, 35000, 60000);
insert into company_statements (id, statement_month, status, version, basis_note, checks, ties_ok, finalized_by, finalized_at)
values (test.id('cs:NT'), date '2031-05-01', 'final', 1, 'test', '{}'::jsonb, true, test.id('nt_admin'), now());
insert into vehicle_exits (id, vehicle_id, initiated_by, notice_received_at, notice_ends_on, exit_date, status)
values (test.id('ex:NT'), test.id('vehicle:NT1'), 'owner', test.at('2031-06-01 09:00'), date '2031-08-01', date '2031-08-01', 'notice');
insert into vehicle_onboardings (id, vehicle_id, status) values (test.id('onb:NT'), test.id('vehicle:NT1'), 'intake');
create table test.nt_synth (code text, entity text, id uuid, payload jsonb);
insert into test.nt_synth values
  -- emitted by 0019 to 0022 (the payload as their functions build it)
  ('renter_agreement_ready', 'rental_agreement', gen_random_uuid(), jsonb_build_object('booking_id', test.id('booking:NT-2'), 'signer_role', 'renter',
     'signer_name', 'Nt Rita', 'signer_email', 'nt_rita@example.test')),
  ('renter_agreement_signed', 'rental_agreement', gen_random_uuid(), jsonb_build_object('booking_id', test.id('booking:NT-2'),
     'signers', jsonb_build_array(jsonb_build_object('signer_role', 'renter', 'signer_name', 'Nt Rita', 'signer_email', 'nt_rita@example.test'),
                                  jsonb_build_object('signer_role', 'carmacars', 'signer_name', 'Staff', 'signer_email', 'staff@example.test')))),
  ('renter_request_needs_info', 'booking_info_request', gen_random_uuid(), jsonb_build_object('booking_id', test.id('booking:NT-1'), 'info_request', 'Which terminal?', 'reply_by', now())),
  ('renter_change_request_received', 'booking_change_request', gen_random_uuid(), jsonb_build_object('booking_id', test.id('booking:NT-2'))),
  ('staff_change_request_received', 'booking_change_request', gen_random_uuid(), jsonb_build_object('booking_id', test.id('booking:NT-2'), '_immediate', true)),
  ('renter_change_request_approved', 'booking_change_request', gen_random_uuid(), jsonb_build_object('booking_id', test.id('booking:NT-2'))),
  ('renter_change_request_declined', 'booking_change_request', gen_random_uuid(), jsonb_build_object('booking_id', test.id('booking:NT-2'), 'decline_reason', 'Booked')),
  ('renter_extension_requested', 'booking_extension', test.id('ext:NT-5'), jsonb_build_object('booking_id', test.id('booking:NT-5'))),
  ('staff_extension_requested', 'booking_extension', test.id('ext:NT-5'), jsonb_build_object('booking_id', test.id('booking:NT-5'))),
  ('renter_extension_approved', 'booking_extension', test.id('ext:NT-5'), jsonb_build_object('booking_id', test.id('booking:NT-5'))),
  ('renter_extension_declined', 'booking_extension', test.id('ext:NT-5'), jsonb_build_object('booking_id', test.id('booking:NT-5'), 'decline_reason', 'Booked after you')),
  ('renter_extension_confirmed', 'booking_extension', test.id('ext:NT-5'), jsonb_build_object('booking_id', test.id('booking:NT-5'))),
  ('staff_identity_review', 'booking', test.id('booking:NT-2'), jsonb_build_object('booking_id', test.id('booking:NT-2'), 'kind', 'coverage', '_immediate', true)),
  ('renter_identity_approved', 'booking', test.id('booking:NT-2'), jsonb_build_object('booking_id', test.id('booking:NT-2'))),
  ('renter_identity_rejected', 'booking', test.id('booking:NT-2'), jsonb_build_object('booking_id', test.id('booking:NT-2'), 'kind', 'selfie', 'driver_name', 'Nt Rita')),
  ('renter_deposit_declined', 'booking', test.id('booking:NT-2'), jsonb_build_object('booking_number', 'NT-2', 'renter_id', test.id('renter:nt_rita'), 'deposit_amount_cents', 100000,
     'deposit_method', 'card_hold', 'card_brand', 'visa', 'card_last4', '4242')),
  ('staff_return_findings', 'booking', test.id('booking:NT-5'), jsonb_build_object('has_damage', false, 'deposit_amount_cents', 100000, '_immediate', true)),
  ('renter_damage_found', 'incident', test.id('inc:NT'), jsonb_build_object('booking_id', test.id('booking:NT-5'), 'renter_id', test.id('renter:nt_rita'),
     'damage_description', 'Rear bumper: scratch', 'inspection_at', now())),
  ('renter_deposit_released', 'deposit', gen_random_uuid(), jsonb_build_object('booking_id', test.id('booking:NT-5'), 'renter_id', test.id('renter:nt_rita'),
     'deposit_held_back_cents', 20000, 'holdback_applied_cents', 5000, 'release_amount_cents', 15000, 'holdback_reason', 'Pending toll')),
  ('staff_approval_needed', 'task', gen_random_uuid(), jsonb_build_object('approval_type', 'deposit_release', 'approval_subject', 'Booking NT-5', 'approval_reason', 'over limit',
     'amount_cents', 15000, 'approval_due', now(), 'requested_by', test.id('nt_fin'), 'requested_at', now(), 'booking_id', test.id('booking:NT-5'), '_immediate', true)),
  ('staff_disable_approval_needed', 'tracker_command', gen_random_uuid(), jsonb_build_object('vehicle_id', test.id('vehicle:NT1'), 'booking_id', test.id('booking:NT-5'),
     'renter_name', 'Nt Rita', 'renter_phone', '647-555-0199', 'disable_ground', 'late_return', 'final_notice_at', now(), 'requested_at', now(), 'requested_by', test.id('nt_fleet'))),
  ('owner_document_due', 'vehicle', test.id('vehicle:NT1'), jsonb_build_object('owner_id', test.id('owner:nt_olga'), 'expires_on', date '2031-07-01', 'plate_expires_on', date '2031-07-01')),
  ('staff_expiry_watch', 'job_run', gen_random_uuid(), jsonb_build_object('expiry_count', 1, 'expiry_items', jsonb_build_array(jsonb_build_object('kind', 'plate_renewal',
     'vehicle_id', test.id('vehicle:NT1'), 'label', '2023 Mercedes-Benz C 300 NT1', 'expires_on', date '2031-07-01')), '_immediate', true)),
  ('staff_toll_ticket_logged', 'toll_ticket', test.id('tt:NT'), jsonb_build_object('match_summary', 'matched to booking NT-5', '_immediate', true)),
  ('staff_toll_ticket_unmatched', 'toll_ticket', test.id('tt:NT'), jsonb_build_object('_immediate', true)),
  ('renter_extra_charge', 'booking_statement', test.id('bs:NT-5'), jsonb_build_object('booking_id', test.id('booking:NT-5'), 'charge_kind', 'toll', 'charged_from', 'card_on_file')),
  ('owner_toll_ticket', 'toll_ticket', test.id('tt:NT'), jsonb_build_object('owner_id', test.id('owner:nt_olga'), 'is_forwarded', true)),
  ('renter_named_to_authority', 'toll_ticket', test.id('tt:NT'), jsonb_build_object('booking_id', test.id('booking:NT-5'))),
  ('owner_statement_ready', 'owner_statement', test.id('st:NT'), jsonb_build_object('owner_id', test.id('owner:nt_olga'))),
  ('staff_monthly_statements_ready', 'company_statement', test.id('cs:NT'), jsonb_build_object('statement_month', date '2031-05-01')),
  ('owner_application_received', 'lead', gen_random_uuid(), jsonb_build_object('first_name', 'Lee', 'email', 'lee@example.test', 'vehicle_name', '2022 Audi A4', 'ownership_summary', 'held personally')),
  ('staff_owner_application_received', 'lead', gen_random_uuid(), jsonb_build_object('owner_name', 'Lee Lead', 'email', 'lee@example.test', 'phone', '416-555-0000', 'vehicle_name', '2022 Audi A4')),
  ('staff_listing_ready_for_review', 'listing_intake', gen_random_uuid(), jsonb_build_object('vehicle_id', test.id('vehicle:NT1'), 'decode_failed', false, 'draft_failed', false, '_immediate', true)),
  ('owner_vehicle_listed', 'vehicle', test.id('vehicle:NT1'), jsonb_build_object('owner_id', test.id('owner:nt_olga'), 'listing_path', '/cars/nt1')),
  ('owner_exit_notice_received', 'vehicle_exit', test.id('ex:NT'), jsonb_build_object('owner_id', test.id('owner:nt_olga'), 'vehicle_id', test.id('vehicle:NT1'), 'exit_date', date '2031-08-01', 'retransfer_fees_paid_by', 'owner')),
  ('staff_exit_notice_received', 'vehicle_exit', test.id('ex:NT'), jsonb_build_object('owner_id', test.id('owner:nt_olga'), 'owner_name', 'Nt Olga', 'vehicle_id', test.id('vehicle:NT1'), 'exit_date', date '2031-08-01', '_immediate', true)),
  ('owner_exit_completed', 'vehicle_exit', test.id('ex:NT'), jsonb_build_object('owner_id', test.id('owner:nt_olga'), 'vehicle_id', test.id('vehicle:NT1'), 'exit_date', date '2031-08-01', 'retransfer_fees_paid_by', 'carmacars')),
  ('owner_fee_change_notice', 'vehicle_term_change', gen_random_uuid(), jsonb_build_object('owner_id', test.id('owner:nt_olga'), 'vehicle_id', test.id('vehicle:NT1'), 'effective_from', date '2031-08-01',
     'old_insurance_fee_cents', 45000, 'new_insurance_fee_cents', 47500, 'old_tracker_fee_cents', 2500, 'new_tracker_fee_cents', 2500, 'reason', 'Policy renewal')),
  ('owner_mode_change_notice', 'vehicle_term_change', gen_random_uuid(), jsonb_build_object('owner_id', test.id('owner:nt_olga'), 'vehicle_id', test.id('vehicle:NT1'), 'vehicle_name', '2022 Audi A4', 'effective_from', date '2031-08-01',
     'needs_signature', true, 'mode_before', 'managed', 'mode_after', 'self_managed', 'reason', 'Owner request', 'summary', 'Management Mode Managed to Self-Managed',
     'changes', jsonb_build_array(jsonb_build_object('label', 'Management Mode', 'before', 'Managed', 'after', 'Self-Managed')))),
  ('owner_fee_change_cancelled', 'vehicle_term_change', gen_random_uuid(), jsonb_build_object('owner_id', test.id('owner:nt_olga'), 'vehicle_id', test.id('vehicle:NT1'), 'vehicle_name', '2022 Audi A4', 'effective_from', date '2031-08-01',
     'summary', 'Insurance Fee 450.00 to 475.00', 'changes', jsonb_build_array(jsonb_build_object('label', 'Insurance Fee', 'before', '$450.00', 'after', '$475.00')))),
  ('owner_bank_details_changed', 'owner', test.id('owner:nt_olga'), jsonb_build_object('owner_id', test.id('owner:nt_olga'), 'change_summary', 'New account ending 1234 submitted', 'changed_at', now(), 'changed_by', 'you')),
  -- emitted by this layer's triggers, for records the sections above did not create
  ('owner_agreement_ready', 'vehicle_onboarding', test.id('onb:NT'), jsonb_build_object('vehicle_id', test.id('vehicle:NT1'), 'owner_id', test.id('owner:nt_olga'))),
  ('owner_agreement_signed', 'vehicle_onboarding', test.id('onb:NT'), jsonb_build_object('vehicle_id', test.id('vehicle:NT1'), 'owner_id', test.id('owner:nt_olga'))),
  ('owner_onboarding_steps', 'vehicle_onboarding', test.id('onb:NT'), jsonb_build_object('vehicle_id', test.id('vehicle:NT1'), 'owner_id', test.id('owner:nt_olga'))),
  ('owner_registry_visit', 'vehicle_onboarding', test.id('onb:NT'), jsonb_build_object('vehicle_id', test.id('vehicle:NT1'), 'owner_id', test.id('owner:nt_olga'))),
  ('owner_vehicle_enrolled', 'vehicle_onboarding', test.id('onb:NT'), jsonb_build_object('vehicle_id', test.id('vehicle:NT1'), 'owner_id', test.id('owner:nt_olga'))),
  ('owner_application_declined', 'vehicle_onboarding', test.id('onb:NT'), jsonb_build_object('vehicle_id', test.id('vehicle:NT1'), 'owner_id', test.id('owner:nt_olga'))),
  ('owner_payout_sent', 'payout', test.id('po:NT'), jsonb_build_object('owner_id', test.id('owner:nt_olga'))),
  ('renter_vehicle_disabled', 'tracker_command', gen_random_uuid(), jsonb_build_object('booking_id', test.id('booking:NT-5'))),
  ('renter_return_details', 'booking', test.id('booking:NT-5'), jsonb_build_object('booking_id', test.id('booking:NT-5'))),
  ('renter_offer_expired', 'booking', test.id('booking:NT-7'), jsonb_build_object('booking_id', test.id('booking:NT-7'), 'offer_version', 1)),
  ('renter_offer_withdrawn', 'booking', test.id('booking:NT-7'), jsonb_build_object('booking_id', test.id('booking:NT-7'), 'kind', 'pushed_back')),
  ('renter_offer_ready', 'booking', test.id('booking:NT-7'), jsonb_build_object('booking_id', test.id('booking:NT-7'), 'offer_version', 1)),
  ('renter_request_declined', 'booking', test.id('booking:NT-8'), jsonb_build_object('booking_id', test.id('booking:NT-8'), 'note', 'No car')),
  ('renter_rental_started', 'booking', test.id('booking:NT-5'), jsonb_build_object('booking_id', test.id('booking:NT-5'))),
  ('renter_return_complete', 'booking', test.id('booking:NT-5'), jsonb_build_object('booking_id', test.id('booking:NT-5'))),
  ('owner_incident_update', 'incident', test.id('inc:NT'), jsonb_build_object('booking_id', test.id('booking:NT-5'))),
  ('staff_offer_approved_paid', 'booking', test.id('booking:NT-2'), jsonb_build_object('booking_id', test.id('booking:NT-2'), '_immediate', true)),
  ('staff_payment_failed', 'payment', test.id('pay:NT-2:toll'), jsonb_build_object('booking_id', test.id('booking:NT-2'), '_immediate', true)),
  ('staff_insurer_invoice_due', 'insurer_invoice', gen_random_uuid(), jsonb_build_object('insurer_name', 'Sample', 'invoice_number', 'II-1', 'claim_number', 'C-1',
     'invoice_total', '$1.00', 'amount_paid', '$0.00', 'balance_due', '$1.00', 'invoice_sent_at', 'Mon, Jan 6, 2031', 'days_outstanding', '30',
     'last_contact', 'None logged', 'adjuster_contact', 'On the booking', 'booking_id', test.id('booking:NT-2'), '_immediate', true)),
  ('owner_payment_received', 'owner_invoice', test.id('oi:NT:1'), jsonb_build_object('owner_id', test.id('owner:nt_olga'))),
  ('owner_payment_failed', 'owner_invoice', test.id('oi:NT:1'), jsonb_build_object('owner_id', test.id('owner:nt_olga'))),
  ('owner_upfront_invoice', 'owner_invoice', test.id('oi:NT:1'), jsonb_build_object('owner_id', test.id('owner:nt_olga'))),
  ('owner_booking_confirmed', 'booking', test.id('booking:NT-2'), jsonb_build_object('booking_id', test.id('booking:NT-2'))),
  ('staff_field_jobs_tomorrow', 'user', test.id('nt_field'), jsonb_build_object('recipient_user_id', test.id('nt_field'), 'digest_date', 'Wed, Feb 5',
     'jobs', '[]'::jsonb, 'job_count', '0', 'first_job_time', 'none', 'jobs_summary', 'None.')),
  ('investor_statement_ready', 'investment_return', (select id from investment_returns order by created_at limit 1),
     jsonb_build_object('investor_id', (select i.investor_id from investments i join investment_returns r on r.investment_id = i.id order by r.created_at limit 1))),
  ('investor_return_paid', 'investment_return', (select id from investment_returns order by created_at limit 1),
     jsonb_build_object('investor_id', (select i.investor_id from investments i join investment_returns r on r.investment_id = i.id order by r.created_at limit 1))),
  ('investor_notice_received', 'investment_election', gen_random_uuid(),
     jsonb_build_object('investor_id', (select id from investors order by created_at limit 1), 'notice_date', date '2031-06-01', 'notice_effective', 'Thu, Jul 1, 2031',
                        'notice_subject', 'Change of election: returns reinvested'));
-- each eod digest at least once (a role with nothing waiting gets none)
insert into test.nt_synth select 'staff_digest_eod_' || r, 'job_run', gen_random_uuid(), jsonb_build_object('digest_date', 'Tue, Feb 4', 'digest_count', '0',
  'digest_summary', 'Nothing is waiting.', 'has_items', false, 'sections', '[]'::jsonb, 'stat_1', '0 new', 'stat_2', '0 open')
  from unnest(array['admin', 'va_finance', 'va_fleet', 'va_cs', 'va_sales']) r;
-- the two message emails (0033): a staff reply and the renter's answer on the booking
insert into messages (id, direction, channel, subject, body, renter_id, booking_id, status)
values (test.id('msg:NT-2:out'), 'outbound', 'portal', 'Your booking NT-2', 'We added a child seat.', test.id('renter:nt_rita'), test.id('booking:NT-2'), 'delivered'),
       (test.id('msg:NT-2:in'), 'inbound', 'portal', 'Reply about booking NT-2', 'Thank you.', test.id('renter:nt_rita'), test.id('booking:NT-2'), 'received');
insert into test.nt_synth values
  ('renter_staff_message', 'message', test.id('msg:NT-2:out'), jsonb_build_object('booking_id', test.id('booking:NT-2'))),
  ('staff_renter_replied', 'message', test.id('msg:NT-2:in'), jsonb_build_object('booking_id', test.id('booking:NT-2'), '_immediate', true));
-- the owner debit and company statement emails (0037): a run of the day, an exception, a statement with its PDFs
insert into owner_debit_runs (id, run_on, kind, submitted, submitted_cents) values (test.id('nt_debit_run'), date '2031-06-15', 'debit', 1, 53675);
select app.build_company_statement(date '2031-06-01', null);
insert into test.nt_synth values
  ('owner_debit_notice', 'owner', test.id('owner:nt_olga'), jsonb_build_object('owner_id', test.id('owner:nt_olga'))),
  ('owner_debit_setup_needed', 'owner', test.id('owner:nt_olga'), jsonb_build_object('owner_id', test.id('owner:nt_olga'))),
  ('staff_owner_debit_exception', 'owner', test.id('owner:nt_olga'), jsonb_build_object('owner_id', test.id('owner:nt_olga'), 'exception', 'no_mandate')),
  ('staff_owner_debit_run', 'owner_debit_run', test.id('nt_debit_run'), '{}'::jsonb),
  ('staff_monthly_statements_pdfs', 'company_statement', (select id from company_statements where statement_month = '2031-06-01'), '{}'::jsonb);
-- the operations gaps emails (0040): a change staff proposed, a driver's link, a possible duplicate, a witnessed form
insert into booking_change_requests (id, booking_id, requested_by_role, status, note, changes, before, after, total_difference_cents, accept_by)
select test.id('nt_cr'), b.id, 'staff', 'cancelled', 'The car needs a service; one more day at the same rate.', jsonb_build_object('return_at', b.return_at + interval '1 day'),
       jsonb_build_object('vehicle_id', b.vehicle_id, 'pickup_at', b.pickup_at, 'return_at', b.return_at, 'rental_charge_cents', b.rental_charge_cents, 'total_cents', b.total_due_at_booking_cents),
       jsonb_build_object('vehicle_id', b.vehicle_id, 'pickup_at', b.pickup_at, 'return_at', b.return_at + interval '1 day', 'rental_charge_cents', b.rental_charge_cents + 10000,
                          'total_cents', b.total_due_at_booking_cents + 11300), 11300, now() + interval '1 day'
  from bookings b where b.id = test.id('booking:NT-2');
insert into listing_similarity_flags (id, vehicle_id, other_vehicle_id, kind, score_bps, blocking, detail)
select test.id('nt_flag'), test.id('vehicle:NT1'), (select v.id from vehicles v where v.id <> test.id('vehicle:NT1') order by v.created_at limit 1), 'plate', 10000, true, 'Same plate as another car'
on conflict do nothing;
insert into owner_agreement_forms (id, owner_id, form_code, status, witness_1_name, witness_2_name, reject_reason, reviewed_by, reviewed_at)
values (test.id('nt_form'), test.id('owner:nt_olga'), 'D1', 'rejected', 'Wendy Witness', 'Will Witness', 'Page 2 is missing.', test.id('nt_admin'), now());
insert into test.nt_synth values
  ('renter_change_proposed', 'booking_change_request', test.id('nt_cr'), jsonb_build_object('booking_id', test.id('booking:NT-2'))),
  ('renter_change_proposal_reminder', 'booking_change_request', test.id('nt_cr'), jsonb_build_object('booking_id', test.id('booking:NT-2'))),
  ('renter_change_proposal_expired', 'booking_change_request', test.id('nt_cr'), jsonb_build_object('booking_id', test.id('booking:NT-2'))),
  ('renter_change_applied', 'booking_change_request', test.id('nt_cr'), jsonb_build_object('booking_id', test.id('booking:NT-2'))),
  ('owner_booking_changed', 'booking_change_request', test.id('nt_cr'), jsonb_build_object('booking_id', test.id('booking:NT-2'), 'owner_id', test.id('owner:nt_olga'), 'owner_side', 'same')),
  ('staff_change_proposal_answered', 'booking_change_request', test.id('nt_cr'), jsonb_build_object('booking_id', test.id('booking:NT-2'), 'outcome', 'declined', '_immediate', true)),
  ('renter_driver_link', 'rental_agreement_signer', gen_random_uuid(), jsonb_build_object('booking_id', test.id('booking:NT-2'), 'signer_email', 'nt_driver@example.test',
     'signer_name', 'Nt Driver', 'sign_url', 'https://carmacars.ca/sign/driver/eyJzIjoibnQifQ.c2ln', 'link_expires', 'Mon, Feb 10, 2031 at 10:00 am')),
  ('staff_listing_similarity', 'listing_similarity_flag', test.id('nt_flag'), jsonb_build_object('vehicle_id', test.id('vehicle:NT1'), '_immediate', true)),
  ('staff_owner_form_uploaded', 'owner_agreement_form', test.id('nt_form'), jsonb_build_object('owner_id', test.id('owner:nt_olga'), '_immediate', true)),
  ('owner_form_approved', 'owner_agreement_form', test.id('nt_form'), jsonb_build_object('owner_id', test.id('owner:nt_olga'))),
  ('owner_form_rejected', 'owner_agreement_form', test.id('nt_form'), jsonb_build_object('owner_id', test.id('owner:nt_olga')));
-- the payments recorded by hand (0044): a receipt and a reversal
insert into payments (id, owner_id, owner_invoice_id, purpose, kind, method, amount_cents, status, processed_at)
select test.id('nt_mp_pay'), i.owner_id, i.id, 'owner_fees', 'charge', 'e_transfer', 5000, 'succeeded', now()
  from owner_invoices i where i.owner_id = test.id('owner:nt_olga') order by i.created_at limit 1;
insert into manual_payments (id, payment_id, target, owner_invoice_id, owner_id, method, amount_cents, received_on, reference, recorded_by)
select test.id('nt_mp'), p.id, 'owner_invoice', p.owner_invoice_id, p.owner_id, 'e_transfer', 5000, date '2031-06-10', 'NT-REF-1', test.id('nt_admin')
  from payments p where p.id = test.id('nt_mp_pay');
insert into test.nt_synth values
  ('owner_payment_recorded', 'manual_payment', test.id('nt_mp'), jsonb_build_object('owner_id', test.id('owner:nt_olga'))),
  ('owner_payment_reversed', 'manual_payment', test.id('nt_mp'), jsonb_build_object('owner_id', test.id('owner:nt_olga')));
-- the account welcomes (0045): sent when the address is first confirmed, no longer when a role is granted
insert into test.nt_synth values
  ('renter_account_created', 'user', test.id('nt_rita'), '{}'::jsonb),
  ('owner_account_created', 'user', test.id('nt_olga'), jsonb_build_object('owner_id', test.id('owner:nt_olga')));
-- a rental added by hand (0046): the renter's email
insert into test.nt_synth values
  ('renter_rental_added', 'booking', test.id('booking:NT-2'), jsonb_build_object('booking_id', test.id('booking:NT-2')));
-- the PAD confirmation (0051): a debit mandate that becomes active
insert into owner_payment_methods (id, owner_id, kind, status, brand_or_bank, last4, authorized_at)
values (test.id('nt_pad'), test.id('owner:nt_olga'), 'pre_authorized_debit', 'pending', 'TD Canada Trust', '6621', now());
update owner_payment_methods set status = 'active' where id = test.id('nt_pad');
insert into test.nt_synth values
  ('owner_pad_confirmed', 'owner_payment_method', test.id('nt_pad'), jsonb_build_object('owner_id', test.id('owner:nt_olga')));
-- the legal review (0053): a debit returned for another reason than insufficient funds, and an Owner of the Title
-- Schedule's own signing link
insert into owner_debit_attempts (id, owner_invoice_id, owner_id, attempt_no, debit_on, amount_cents, idempotency_key, status, failure_code, failure_message)
select test.id('nt_ret'), i.id, i.owner_id, 9, date '2031-06-15', 53675, 'nt-returned', 'failed', 'account_closed', 'the account is closed'
  from owner_invoices i where i.owner_id = test.id('owner:nt_olga') order by i.created_at limit 1;
insert into owner_cosigners (id, owner_id, name, email) values (test.id('nt_cos'), test.id('owner:nt_olga'), 'Nadia Cosigner', 'nt_cosigner@example.test');
insert into test.nt_synth values
  ('owner_debit_returned', 'owner_debit_attempt', test.id('nt_ret'), jsonb_build_object('owner_id', test.id('owner:nt_olga'))),
  ('staff_owner_debit_exception', 'owner_debit_attempt', test.id('nt_ret'), jsonb_build_object('owner_id', test.id('owner:nt_olga'), 'exception', 'returned', 'reason', 'the account is closed')),
  ('owner_cosigner_sign', 'owner_cosigner', test.id('nt_cos'), jsonb_build_object('owner_id', test.id('owner:nt_olga'), 'signer_email', 'nt_cosigner@example.test'));
-- the owner applications inbox (0054): asked for something, approved (a decline is 0023's email per car)
insert into owner_applications (id, owner_id, source, vehicle_count, requested_items, request_message, decline_reason)
values (test.id('nt_oa'), test.id('owner:nt_olga'), 'web', 1, array['ownership', 'other'], 'A full photo of the permit, please.', 'Too old for the fleet policy.');
insert into test.nt_synth select c, 'owner_application', a.id, jsonb_build_object('owner_id', a.owner_id)
  from (select id, owner_id from owner_applications where id = test.id('nt_oa')) a,
       unnest(array['owner_application_info_requested', 'owner_application_approved']) c;
-- owner terms and invoices (0067): an invoice made by hand and its void, an updated Vehicle Schedule to sign, and the
-- set-up email of a car staff entered
insert into vehicle_term_changes (id, vehicle_id, kind, status, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, previous, effective_from)
values (test.id('nt_vtc'), test.id('vehicle:NT1'), 'new_schedule', 'awaiting_signature', 40000, 2500, 3000,
        '{"schedule_number": "VS-NT1", "insurance_fee_cents": 45000, "tracker_fee_cents": 2500, "revenue_share_bps": 3500}', date '2031-07-01');
insert into test.nt_synth
select c, 'owner_invoice', i.id, jsonb_build_object('owner_id', i.owner_id)
  from (select id, owner_id from owner_invoices where owner_id = test.id('owner:nt_olga') order by created_at limit 1) i,
       unnest(array['owner_invoice_issued', 'owner_invoice_voided']) c;
insert into test.nt_synth values
  ('owner_schedule_resign', 'vehicle_term_change', test.id('nt_vtc'), jsonb_build_object('owner_id', test.id('owner:nt_olga'))),
  ('owner_car_set_up', 'owner_application', test.id('nt_oa'), jsonb_build_object('owner_id', test.id('owner:nt_olga'), 'password_url', 'https://carmacars.ca/auth/callback?token_hash=nt&type=invite'));
select count(app.ntf_emit(code, entity, id, 'completeness', payload)) from test.nt_synth;
-- the insurer invoice email (0032), sent from the admin portal
insert into insurers (id, name, billing_contact_name, billing_email) values (test.id('nt_ins'), 'Nt Mutual', 'Ivan Insurer', 'billing@ntmutual.test');
insert into insurer_invoices (id, booking_id, insurer_id, claim_number, period_start, period_end, amount_cents, hst_cents, lines)
values (test.id('nt_ii'), test.id('booking:NT-3'), test.id('nt_ins'), 'CL-1', date '2031-05-10', date '2031-05-13', 30000, 3900, '[{"label": "Rental", "amount_cents": 30000}]');
select app.send_insurer_invoice_email(test.id('nt_admin'), test.id('nt_ii'));
-- the sign-in link email (0029's owner invitation and form resume links)
select app.send_link_email('nt_link@example.test', 'Nt Link', 'https://carmacars.ca/list-your-car/apply?invite=nt', '7 days', 'nt-link');
-- the staff commission emails (0058): approved, and paid by hand
select test.mk_user('nt_seller', 'va', 'sales');
select app.emit_event('staff_commission_approved', 'user', test.id('nt_seller'), jsonb_build_object('staff_id', test.id('nt_seller'), 'ids', '[]'::jsonb), 'staff_commission_approved:nt');
insert into staff_commission_payouts (id, staff_id, method, reference, paid_on, amount_cents, recorded_by)
values (test.id('nt_cpay'), test.id('nt_seller'), 'e_transfer', 'NT-1', date '2031-05-01', 1000, test.id('nt_admin'));
select app.emit_event('staff_commission_paid', 'staff_commission_payout', test.id('nt_cpay'), jsonb_build_object('staff_id', test.id('nt_seller'), 'payout_id', test.id('nt_cpay')), 'staff_commission_paid:nt');
-- the field pay statement (0165): a paid line of an approved run
insert into field_pay_runs (id, period_start, period_end, status) values (test.id('nt_fpr'), date '2031-05-04', date '2031-05-17', 'paid');
insert into field_pay_lines (id, run_id, staff_id, rate_cents, minutes_total, minutes_regular, wage_cents, gross_cents, status, statement_number, paid_on, method, reference)
values (test.id('nt_fpl'), test.id('nt_fpr'), test.id('nt_field'), 1800, 480, 480, 14400, 14400, 'paid', 'PS-NT-1', date '2031-05-20', 'e_transfer', 'NT-PAY-1');
select app.emit_event('staff_pay_statement', 'field_pay_line', test.id('nt_fpl'), jsonb_build_object('staff_id', test.id('nt_field'), 'line_id', test.id('nt_fpl')), 'staff_pay_statement:nt');
-- live chat (0060): the transcript to the visitor's email, and the email to staff on shift who asked for it
insert into chat_conversations (id, visitor_id, name, email, human_reason) values (test.id('nt_chat'), test.id('nt_chatv'), 'Nia Chat', 'nia.chat@example.test', 'asked for a person');
insert into chat_messages (conversation_id, sender, body) values (test.id('nt_chat'), 'visitor', 'Is the car free on Friday?');
select app.chat_send_transcript(test.id('nt_chat'));
insert into chat_staff_prefs (user_id, email_when_waiting, last_seen_at) values (test.id('nt_admin'), true, now())
on conflict (user_id) do update set email_when_waiting = true, last_seen_at = now();
select app.emit_event('staff_chat_waiting', 'chat_conversation', test.id('nt_chat'), '{"reason": "asked for a person"}', 'staff_chat_waiting:nt');
-- calendar sync, booking recovery and the site check (0062): a clash, a link that fails, a site alert and its
-- recovery (to a test address, never the real Admin's), and the four recovery reminders
update program_settings set uptime_alert_email = 'nt.alerts@example.test';
insert into calendar_feeds (id, vehicle_id, platform, url, enabled, consecutive_failures, last_error, failing_since)
values (test.id('nt_feed'), test.id('vehicle:NT1'), 'turo', 'https://turo.example/ical/nt.ics', false, 3, 'The platform answered 404 (not found)', now());
insert into calendar_feed_events (id, feed_id, vehicle_id, uid, summary, starts_at, ends_at)
values (test.id('nt_fev'), test.id('nt_feed'), test.id('vehicle:NT1'), 'nt-1', 'Turo trip', timestamptz '2031-05-11 14:00Z', timestamptz '2031-05-12 14:00Z');
insert into calendar_conflicts (id, event_id, booking_id, kind, resolved_at) values (test.id('nt_cfl'), test.id('nt_fev'), test.id('booking:NT-3'), 'booking', now());
select app.emit_event('staff_calendar_conflict', 'calendar_conflict', test.id('nt_cfl'), jsonb_build_object('booking_id', test.id('booking:NT-3'), 'vehicle_id', test.id('vehicle:NT1')), 'staff_calendar_conflict:nt');
select app.emit_event('staff_calendar_feed_failing', 'calendar_feed', test.id('nt_feed'), jsonb_build_object('vehicle_id', test.id('vehicle:NT1'), 'failures', 3), 'staff_calendar_feed_failing:nt');
insert into site_alerts (id, check_key, opened_at, resolved_at, detail, failures, emailed)
values (test.id('nt_alert'), 'home', now() - interval '2 days 25 minutes', now() - interval '2 days', 'Answered 503 with Error 1102 (the web host stopped the page)', 3, true);
select app.emit_event('staff_site_alert', 'site_alert', test.id('nt_alert'), '{}', 'staff_site_alert:nt');
select app.emit_event('staff_site_recovered', 'site_alert', test.id('nt_alert'), '{}', 'staff_site_recovered:nt');
select app.emit_event('renter_recovery_offer', 'booking', test.id('booking:NT-1'), jsonb_build_object('booking_id', test.id('booking:NT-1'), 'renter_id', test.id('renter:nt_rita')), 'renter_recovery_offer:nt');
select app.emit_event('renter_recovery_pay', 'booking', test.id('booking:NT-2'), jsonb_build_object('booking_id', test.id('booking:NT-2'), 'renter_id', test.id('renter:nt_rita')), 'renter_recovery_pay:nt');
select app.emit_event('renter_recovery_change', 'booking', test.id('booking:NT-3'), jsonb_build_object('booking_id', test.id('booking:NT-3'), 'renter_id', test.id('renter:nt_rob')), 'renter_recovery_change:nt');
select app.emit_event('renter_recovery_request', 'renter', test.id('renter:nt_rita'), jsonb_build_object('renter_id', test.id('renter:nt_rita'), 'vehicle_id', test.id('vehicle:NT1')), 'renter_recovery_request:nt');
select test.flush();
-- the Google review request (0061), with the place id set as it is when it is sent
update site_settings set google_place_id = 'ChIJnt07placeid0001';
select app.emit_event('renter_google_review_request', 'booking', test.id('booking:NT-9'), '{}', 'renter_google_review_request:nt');
select test.flush();
update site_settings set google_place_id = null;
update program_settings set uptime_alert_email = 'rent@carmacars.ca';
-- the discount game code and its reminder (0069)
select app.server_game_claim(jsonb_build_object('token', (app.game_start(jsonb_build_object('vid', test.id('nt_game_vid'))) ->> 'token'),
  'first_name', 'Nora', 'email', 'nt.game@example.test'));
select app.emit_event('renter_game_code_reminder', 'game_claim', (select id from game_claims where email = 'nt.game@example.test'), '{}', 'renter_game_code_reminder:nt');
select app.emit_event('renter_game_code_reminder_3d', 'game_claim', (select id from game_claims where email = 'nt.game@example.test'), '{}', 'renter_game_code_reminder_3d:nt');
-- the promo code expiry reminders of a code made for a renter (0161); suite 99 tests when they are sent
insert into promo_codes (id, code, percent_bps, valid_from, valid_until, max_uses, renter_id, source)
values (test.id('nt_promo'), 'NTPROMO1', 1500, now() - interval '20 days', now() + interval '3 days', 1, test.id('renter:nt_rita'), 'followup_30d');
select app.ntf_emit(c, 'promo_code', test.id('nt_promo'), 'nt07', jsonb_build_object('renter_id', test.id('renter:nt_rita'))) from unnest(array['renter_promo_expiry_3d', 'renter_promo_expiry_1d']) c;
select test.flush();
delete from promo_codes where id = test.id('nt_promo');
-- the proof of coverage reminder (0070)
select app.emit_event('renter_coverage_needed', 'booking', test.id('booking:NT-9'), '{"hours": 24}', 'renter_coverage_needed:nt');
select test.flush();
-- a new version of the rental agreements and the signing code (0154)
insert into agreement_versions (id, booking_id, version_no, kind, material, status, changes, snapshot, snapshot_sha)
values (test.id('nt_agv'), test.id('booking:NT-1'), 2, 'correction', false, 'filed',
        '[{"key": "renter.address", "label": "Renter: address", "before": "1 Old Street", "after": "1 New Street", "material": false}]', '{}', 'nt');
select app.emit_event('renter_agreement_version', 'agreement_version', test.id('nt_agv'), jsonb_build_object('booking_id', test.id('booking:NT-1'), 'version_id', test.id('nt_agv'), 'needs_signature', false), 'renter_agreement_version:nt');
select app.emit_event('renter_signing_code', 'esign_session', test.id('nt_esign'), jsonb_build_object('booking_id', test.id('booking:NT-1'), 'signer_email', 'nt.signer@example.test', 'signer_name', 'Nia Signer', 'code', '482913'), 'renter_signing_code:nt');
select test.flush();
delete from agreement_versions where id = test.id('nt_agv');
-- the usage guard's alert (0080)
insert into usage_alerts (id, service, period_start, level, used, included) values (test.id('nt_usage'), 'workers_ai', app.today(), 80, 8200, 10000) on conflict do nothing;
select app.emit_event('staff_usage_alert', 'usage_alert', test.id('nt_usage'), '{}', 'staff_usage_alert:nt');
select test.flush();
delete from usage_alerts where id = test.id('nt_usage');
-- the "Continue your request" email of contact capture (0090)
select app.capture_contact(jsonb_build_object('visitor_id', test.id('nt_cap_vid'), 'form', 'contact', 'name', 'Nina Capture', 'email', 'nt.capture@example.test'));
select app.capture_send_continue((select id from users where email = 'nt.capture@example.test'), (select id from contact_captures where email = 'nt.capture@example.test'));
-- the review request program's four emails (0146), built once here (suite 91 tests when they are sent)
select app.review_request_row(test.id('booking:NT-9'));
select app.ntf_emit(c, 'booking', test.id('booking:NT-9'), 'nt07', jsonb_build_object('booking_id', test.id('booking:NT-9')))
  from unnest(array['renter_trip_checkin', 'renter_review_ask', 'renter_review_reminder', 'renter_review_final']) c;
select test.flush();
-- the owner recruitment email (0167): a dealer that published its address (suite 99 ads tests the consent rules)
select app.recruit_consent_add(test.id('nt_admin'), jsonb_build_object('lead', (r ->> 'id'), 'channel', 'email', 'basis', 'implied_published', 'method', 'published',
         'source', 'Contact page, no no-solicitation note', 'evidence', 'https://dealer.example.test/contact'))
  from (select app.recruit_lead_save(test.id('nt_admin'), jsonb_build_object('business_name', 'NT Auto Sales', 'name', 'Nina Dealer', 'contact_kind', 'dealer', 'email', 'nt.dealer@example.test')) r) x;
select app.recruit_send(test.id('nt_admin'), jsonb_build_object('lead', (select id from leads where email = 'nt.dealer@example.test'), 'channel', 'email', 'subject', 'Cars between sales',
  'body', 'Hello Nina, CarmaCars rents cars in Toronto for their owners.'));
-- the change request made for the emails above is not left for the later files' counts
delete from booking_change_requests where id = test.id('nt_cr');
select test.eq('G no wired code is missing a variable (built here or supplied by the sender)',
  (select string_agg(distinct code || ':' || array_to_string(missing_variables, ','), '; ') from notification_outbox where missing_variables <> '{}'), null::text);
select test.eq('G every wired email code has been built at least once in these tests, digests included',
  (select string_agg(c.code, ',' order by c.code) from notification_catalogue c
    where c.has_email and c.emitted_by not like 'not emitted%'
      and not exists (select 1 from notification_outbox o where o.code = c.code)),
  null::text);
select test.eq('G the variables the sender supplies are only signed links and sign-in service values',
  (select string_agg(distinct v, ',' order by v) from notification_catalogue, unnest(sender_supplied) v),
  'invoice_url,link_expiry,receipt_url,reset_url,security_device,security_event,security_event_at,security_place,sign_in_url,signed_agreement_url,statement_url,supporting_document_url');
select test.eq('G no payload names the numbered company alone; the payee of the owner billing emails is "<legal name>, operating as CarmaCars" (0053, 0128)',
  (select count(*) from notification_outbox where replace(payload::text, (select company_legal_name || ', operating as ' || company_trade_name from app.settings()), 'CarmaCars') ~ '18122211|Canada Inc|operated by'), 0::bigint);
select test.eq('G the owner billing emails name the payee "<legal name>, operating as <business name>" (0053, 0128: the agreements keep the legal name alone, 0122)',
  (select bool_and(payload ->> 'payee_name' = (select company_legal_name || ', operating as ' || company_trade_name from app.settings())) from notification_outbox o join notification_catalogue c on c.code = o.code
    where c.from_address like '%billing@%' and c.audience = 'owner'), true);
select test.eq('G the mailing address and phone in the emails come from the site settings',
  (select string_agg(distinct (payload ->> 'company_address') || ' / ' || coalesce(payload ->> 'support_phone', '647-555-0100'), ', ') from notification_outbox
    where event_id in (select id from app_events where dedupe_key like '%:completeness')),
  '100 Sample Street, Toronto, Ontario / 647-555-0100');

-- ================================================================== H. in-app notices and the app functions
select test.login(test.id('nt_rita'));
select test.ok('H a renter lists her own notices only', (select count(*) > 0 and bool_and(user_id = test.id('nt_rita')) from app.my_notifications(200)));
select test.ok('H she marks them read', app.mark_notifications_read() > 0);
select test.eq('H then none is unread', (select count(*) from app.my_notifications(200, true)), 0::bigint);
select test.throws('H a browser cannot write a notice', $$insert into notifications (user_id, code, title, dedupe_key) values (app.uid(), 'renter_offer_ready', 'x', 'x')$$, 'permission denied');
select test.throws('H a browser cannot run the sender', $$select * from app.outbox_claim()$$, 'permission denied');
select test.throws('H a browser cannot process events', $$select app.process_events()$$, 'permission denied');
select test.logout();

-- ================================================================== I. row-level security, every role on every new table
insert into staff_digest_items (role, code, line, dedupe_key) values ('admin', 'staff_approval_needed', 'admin item', 'rls:admin'), ('va_finance', 'staff_payment_failed', 'finance item', 'rls:fin');
create or replace function test.vis_all() returns text language plpgsql as $$
declare t text; v text := ''; n bigint;
begin
  foreach t in array array['notification_catalogue', 'notification_link_paths', 'notification_outbox', 'staff_digest_items', 'notifications',
                           'notification_preferences', 'email_suppressions', 'marketing_sends'] loop
    n := test.visible('select 1 from ' || t);
    v := v || case when v = '' then '' else ',' end || left(t, 1) || substr(t, strpos(t, '_') + 1, 3) || '=' || case when n > 0 then 'y' when n = 0 then '0' else 'x' end;
  end loop;
  return v;
end $$;
select test.login(test.id('nt_admin'));
select test.eq('I admin sees every table', test.vis_all(), 'ncat=y,nlin=y,nout=y,sdig=y,nnot=y,npre=y,esup=y,msen=y');
select test.logout();
select test.login(test.id('nt_fin'));
select test.eq('I finance: catalogue, its own role''s digest items, suppressions, its own notices; no outbox or marketing records',
  test.vis_all(), 'ncat=y,nlin=y,nout=0,sdig=y,nnot=y,npre=0,esup=y,msen=0');
select test.eq('I finance sees only the finance digest items', (select string_agg(distinct role, ',') from staff_digest_items), 'va_finance');
select test.logout();
select test.login(test.id('nt_fleet'));
select test.eq('I fleet: its own role''s digest items; no suppressions', test.vis_all(), 'ncat=y,nlin=y,nout=0,sdig=y,nnot=y,npre=0,esup=0,msen=0');
select test.eq('I fleet sees only the fleet digest items', (select string_agg(distinct role, ',') from staff_digest_items), 'va_fleet');
select test.logout();
select test.login(test.id('nt_field'));
select test.eq('I field: the catalogue and own notices only', test.vis_all(), 'ncat=y,nlin=y,nout=0,sdig=0,nnot=y,npre=0,esup=0,msen=0');
select test.logout();
select test.login(test.id('nt_rob'));
select test.eq('I renter: own notices and own preferences only', test.vis_all(), 'ncat=0,nlin=0,nout=0,sdig=0,nnot=y,npre=y,esup=0,msen=0');
select test.eq('I a renter changes no outbox row', test.affected($$update notification_outbox set status = 'sent'$$), 0::bigint);
select test.logout();
select test.login(test.id('nt_olga'));
select test.eq('I owner: own notices only', test.vis_all(), 'ncat=0,nlin=0,nout=0,sdig=0,nnot=y,npre=0,esup=0,msen=0');
select test.eq('I the owner''s notices are her own', (select count(*) from notifications where user_id <> test.id('nt_olga')), 0::bigint);
select test.logout();
select test.eq('I every new table has row-level security, the admin policy and an audit trigger',
  (select string_agg(t, ',') from unnest(array['notification_catalogue', 'notification_link_paths', 'notification_outbox', 'staff_digest_items', 'notifications',
                                               'notification_preferences', 'email_suppressions', 'marketing_sends']) t
    where not exists (select 1 from pg_class c where c.relname = t and c.relrowsecurity)
       or not exists (select 1 from pg_policies p where p.tablename = t and p.policyname = 'admin_all')
       or not exists (select 1 from pg_trigger g join pg_class c on c.oid = g.tgrelid where c.relname = t and g.tgname = 'audit_' || t)), null::text);

-- ================================================================== J. scheduling
select test.eq('J the three notification wrappers are server-only',
  (select string_agg(p.proname, ',') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname in ('job_notify_events', 'job_notify_reminders', 'job_notify_scheduled')
      and (has_function_privilege('authenticated', p.oid, 'execute') or not has_function_privilege('service_role', p.oid, 'execute'))), null::text);
select test.eq('J the event processor wrapper does nothing when nothing is waiting', app.job_notify_events(), 'not_due');

-- ================================================================== restore the staff of the earlier files for the files that follow
update users set status = 'active' where id in (select id from test.nt_suspended);
update site_settings s set phone = o.phone, mailing_address = o.mailing_address, roadside_phone = o.roadside_phone from test.nt_site o where o.id = s.id;
drop table test.nt_site;
drop table test.nt_suspended;
drop table test.nt_synth;
