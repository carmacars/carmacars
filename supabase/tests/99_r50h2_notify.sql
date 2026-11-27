-- 99: R50 hotfix 2, the notification audit (migration 5190, docs/changes/2026-11-27-r50-hotfix2-notify.md). Fixtures start with "rq50n_".
select test.suite('99 r50h2 notification matrix (5190)');

-- ---------------------------------------------------------------- 1. every catalogued event reaches someone, somehow
-- A message type nobody receives, or that has no way to arrive, is a missing notification: this fails on the first one.
select test.eq('matrix: every enabled message type has a recipient (an audience the platform sends to)',
  (select string_agg(code, ', ' order by code) from notification_catalogue
    where is_enabled and audience not in ('renter', 'owner', 'investor', 'partner', 'insurer', 'applicant', 'staff_admin', 'staff_va_finance',
                                          'staff_va_fleet', 'staff_va_cs', 'staff_va_sales', 'staff_field')),
  null::text);
select test.eq('matrix: every enabled message type has a channel (email with its template, a text, a phone alert, or the staff bell)',
  (select string_agg(c.code, ', ' order by c.code) from notification_catalogue c
    where c.is_enabled
      and not (c.has_email and c.template_html is not null and c.template_text is not null)
      and not exists (select 1 from sms_templates s where s.code = c.code)
      and c.push_topic is null
      and not exists (select 1 from notify_types t where t.code = c.pref_type and 'push' = any (t.channels))
      and c.code not in ('staff_alert_normal', 'staff_alert_urgent', 'staff_alert_digest')),   -- the carriers of the alert rules: the bell, the phone, the digest
  null::text);
-- everyone with an account can turn a type off or on: a type with no preference cannot be found in Notifications
select test.eq('matrix: every enabled type of a person with an account has its place in Notifications (a preference type)',
  (select string_agg(code, ', ' order by code) from notification_catalogue
    where is_enabled and pref_type is null and category <> 'marketing' and audience not in ('insurer', 'applicant', 'partner')
      and code not in ('staff_alert_normal', 'staff_alert_urgent',            -- each alert rule has its own type
                       'owner_recruit_outreach',                              -- a person who is not an owner yet
                       'owner_tracker_alert',                                 -- the tracker type of each alert (tracker_*)
                       'renter_recovery_request', 'renter_comeback_1w', 'renter_comeback_1m')),   -- follow-ups with their own consent
  null::text);
select test.eq('matrix: every alert rule that is on has someone to tell, a preference type and is wired',
  (select string_agg(rule, ', ' order by rule) from staff_alert_rules
    where enabled and (cardinality(who) = 0 or pref_type is null or not wired)),
  null::text);
select test.eq('matrix: every email template exists for every email type (template paths are set)',
  (select string_agg(code, ', ' order by code) from notification_catalogue where is_enabled and has_email and (template_html is null or template_text is null)),
  null::text);
select test.ok('5190: the insurer''s receipt is catalogued, sent as Blind Spot Car Rental',
  exists (select 1 from notification_catalogue where code = 'insurer_payment_received' and audience = 'insurer' and has_email
           and from_address like 'Blind Spot Car Rental <%' and subject not ilike '%carmacars%'));
select test.ok('5190: the new alert rules are on, to the right people',
  (select count(*) from staff_alert_rules where enabled and wired and
     ((rule = 'insurer_invoice_paid' and who = '{admin,fn:finance}') or (rule = 'work_assigned' and who = '{assigned}') or (rule = 'bug_report_closed' and who = '{assigned}'))) = 3);

-- ---------------------------------------------------------------- fixtures
select test.mk_user('rq50n_admin', 'admin');
select test.mk_user('rq50n_cs', 'va', 'cs');
select test.mk_user('rq50n_fin', 'va', 'finance');
select test.mk_owner('rq50n_olive');
select test.mk_vehicle('rq50n_car', 'rq50n_olive');
select test.mk_vehicle('rq50n_car2', 'rq50n_olive');
select test.mk_renter('rq50n_rita');
select test.mk_booking('RQ50N-1', 'rq50n_car', 'rq50n_rita', '2026-10-01 10:00', '2026-10-05 10:00', 'closed');
select test.mk_booking('RQ50N-2', 'rq50n_car2', 'rq50n_rita', '2026-10-10 10:00', '2026-10-12 10:00', 'closed');
insert into insurers (id, name, billing_contact_name, billing_email)
values (test.id('insurer:rq50n'), 'rq50n Mutual', 'Clara Adjuster', 'claims@rq50n-mutual.example.test');
update bookings set bill_to = 'insurer', insurer_id = test.id('insurer:rq50n') where id in (test.id('booking:RQ50N-1'), test.id('booking:RQ50N-2'));
insert into insurer_invoices (id, booking_id, insurer_id, period_start, period_end, amount_cents, hst_cents, status, sent_at)
values (test.id('ins:rq50n-1'), test.id('booking:RQ50N-1'), test.id('insurer:rq50n'), date '2026-10-01', date '2026-10-05', 40000, 5200, 'sent', now()),
       (test.id('ins:rq50n-2'), test.id('booking:RQ50N-2'), test.id('insurer:rq50n'), date '2026-10-10', date '2026-10-12', 20000, 2600, 'sent', now());

-- ---------------------------------------------------------------- 2. an insurer's payment (5190)
-- before: the payment of an insurer sent the renter a receipt for money they never paid
select app.record_insurer_payment_pre5190(test.id('ins:rq50n-2'), 10000, test.id('rq50n_admin'));
select test.ok('before 5190: an insurer''s payment sent the renter a payment receipt (the wrong person)',
  exists (select 1 from app_events where code = 'renter_payment_receipt' and payload ->> 'booking_id' = test.id('booking:RQ50N-2')::text));

select test.eq('5190: a part payment is recorded as before', app.record_insurer_payment(test.id('ins:rq50n-1'), 20000, test.id('rq50n_admin')), 'part_paid');
select test.ok('5190: the renter gets no receipt for the insurer''s money',
  not exists (select 1 from app_events where code = 'renter_payment_receipt' and payload ->> 'booking_id' = test.id('booking:RQ50N-1')::text));
select test.ok('5190: no "payment received" alert for it either (it has its own)',
  not exists (select 1 from app_events where code like 'staff_alert_%' and payload ->> 'rule' = 'payment_received' and payload ->> 'booking_id' = test.id('booking:RQ50N-1')::text));
select test.ok('5190: the insurer''s billing contact gets a receipt, with the amount and the balance',
  exists (select 1 from app_events where code = 'insurer_payment_received' and entity_id = test.id('ins:rq50n-1')
           and payload ->> 'to_email' = 'claims@rq50n-mutual.example.test' and (payload ->> 'amount_cents')::bigint = 20000
           and (payload ->> 'balance_cents')::bigint = 25200));
select test.ok('5190: Admin and Finance get the alert "Insurer invoice paid"',
  exists (select 1 from app_events where code like 'staff_alert_%' and payload ->> 'rule' = 'insurer_invoice_paid' and entity_id = test.id('ins:rq50n-1')));
select test.ok('5190: the alert goes to the Admins and the finance VA',
  (select count(*) filter (where user_id = test.id('rq50n_admin')) = 1 and count(*) filter (where user_id = test.id('rq50n_fin')) = 1
     and count(*) filter (where user_id = test.id('rq50n_cs')) = 0
     from app.staff_alert_users('insurer_invoice_paid', '{}'::jsonb)));
update bookings set insurer_adjuster_email = 'adjuster@rq50n-mutual.example.test', insurer_adjuster_name = 'Ada Adjuster' where id = test.id('booking:RQ50N-1');
select test.eq('5190: the rest paid: in full', app.record_insurer_payment(test.id('ins:rq50n-1'), 25200, test.id('rq50n_admin')), 'paid');
select test.ok('5190: the second receipt goes to the adjuster on the booking, paid in full',
  exists (select 1 from app_events where code = 'insurer_payment_received' and entity_id = test.id('ins:rq50n-1')
           and payload ->> 'to_email' = 'adjuster@rq50n-mutual.example.test' and (payload ->> 'balance_cents')::bigint = 0));
select app.process_events(500, now());
select test.ok('5190: the receipt is queued to the adjuster, every value filled',
  exists (select 1 from notification_outbox o where o.code = 'insurer_payment_received' and o.to_address = 'adjuster@rq50n-mutual.example.test'
           and o.payload ->> 'paid_in_full' = 'true' and o.payload ->> 'amount_paid' = '$252.00' and o.payload ->> 'balance' = '$0.00'
           and o.payload ->> 'invoice_total' = '$452.00' and o.payload ->> 'insurer_name' = 'rq50n Mutual' and coalesce(o.missing_variables, '{}') = '{}'));
select test.ok('5190: and the part-payment receipt went to the billing contact, with the balance still due',
  exists (select 1 from notification_outbox o where o.code = 'insurer_payment_received' and o.to_address = 'claims@rq50n-mutual.example.test'
           and o.payload ->> 'paid_in_full' = 'false' and o.payload ->> 'balance' = '$252.00'));

-- ---------------------------------------------------------------- 3. work someone else gives you (5190)
insert into tasks (id, queue, task_type, title, assigned_to, status)
values (test.id('task:rq50n-auto'), 'cs', 'rq50n_auto', 'rq50n routed by the site', test.id('rq50n_cs'), 'open');
select test.ok('5190: a To do the site routes by itself makes no alert (the queue and the morning brief have it)',
  not exists (select 1 from app_events where payload ->> 'rule' = 'work_assigned' and entity_id = test.id('task:rq50n-auto')));
select set_config('request.jwt.claim.sub', test.id('rq50n_admin')::text, false);
insert into tasks (id, queue, task_type, title, assigned_to, status)
values (test.id('task:rq50n-routed'), 'cs', 'rq50n_routed', 'rq50n raised by the site during an Admin''s action', test.id('rq50n_cs'), 'open');
insert into tasks (id, queue, task_type, title, assigned_to, status, created_by)
values (test.id('task:rq50n-given'), 'cs', 'rq50n_given', 'rq50n call the renter back', test.id('rq50n_cs'), 'open', test.id('rq50n_admin'));
update tasks set assigned_to = test.id('rq50n_fin') where id = test.id('task:rq50n-auto');
insert into leads (id, kind, name, email, status) values (test.id('lead:rq50n'), 'contact', 'Rq50n Lead', 'rq50n.lead@example.test', 'new');
update leads set assigned_to = test.id('rq50n_cs') where id = test.id('lead:rq50n');
select set_config('request.jwt.claim.sub', '', false);
select test.ok('5190: a To do the site raises during an Admin''s action makes no alert (only one a person made)',
  not exists (select 1 from app_events where payload ->> 'rule' = 'work_assigned' and entity_id = test.id('task:rq50n-routed')));
select test.ok('5190: a To do an Admin gives a person alerts that person',
  exists (select 1 from app_events where payload ->> 'rule' = 'work_assigned' and entity_id = test.id('task:rq50n-given')
           and payload ->> 'assigned_to' = test.id('rq50n_cs')::text and payload ->> 'alert_title' like 'To do for you: rq50n call the renter back%'));
select test.ok('5190: a To do moved to another person alerts the new one',
  exists (select 1 from app_events where payload ->> 'rule' = 'work_assigned' and entity_id = test.id('task:rq50n-auto')
           and payload ->> 'assigned_to' = test.id('rq50n_fin')::text));
select test.ok('5190: a lead an Admin assigns alerts the salesperson or agent',
  exists (select 1 from app_events where payload ->> 'rule' = 'work_assigned' and entity_id = test.id('lead:rq50n')
           and payload ->> 'assigned_to' = test.id('rq50n_cs')::text));
select test.ok('5190: only the assignee gets it',
  (select array_agg(user_id) from app.staff_alert_users('work_assigned', jsonb_build_object('assigned_to', test.id('rq50n_cs')))) = array[test.id('rq50n_cs')]);
select set_config('request.jwt.claim.sub', test.id('rq50n_cs')::text, false);
insert into tasks (id, queue, task_type, title, assigned_to, status)
values (test.id('task:rq50n-self'), 'cs', 'rq50n_self', 'rq50n my own note', test.id('rq50n_cs'), 'open');
select set_config('request.jwt.claim.sub', '', false);
select test.ok('5190: a To do you give yourself makes no alert',
  not exists (select 1 from app_events where payload ->> 'rule' = 'work_assigned' and entity_id = test.id('task:rq50n-self')));

-- ---------------------------------------------------------------- 4. the answer to a bug report (5190)
insert into bug_reports (id, reporter_id, portal, happened, severity, page_path, status)
values (test.id('bug:rq50n'), test.id('rq50n_cs'), 'staff', 'rq50n the save button does nothing on the bookings page', 'annoying', '/staff/bookings', 'new');
select app.bug_report_update(test.id('rq50n_admin'), jsonb_build_object('id', test.id('bug:rq50n'), 'note', 'rq50n looking'));
select test.ok('5190: an Admin''s note alone tells nobody (notes are internal)',
  not exists (select 1 from app_events where payload ->> 'rule' = 'bug_report_closed' and entity_id = test.id('bug:rq50n')));
select app.bug_report_update(test.id('rq50n_admin'), jsonb_build_object('id', test.id('bug:rq50n'), 'status', 'fixed', 'fixed_in', 'r50h2'));
select test.ok('5190: Fixed tells the person who reported it, with the release',
  exists (select 1 from app_events where payload ->> 'rule' = 'bug_report_closed' and entity_id = test.id('bug:rq50n')
           and payload ->> 'assigned_to' = test.id('rq50n_cs')::text and payload ->> 'alert_title' = 'Bug report BR-' || (select number from bug_reports where id = test.id('bug:rq50n')) || ' is fixed'
           and payload ->> 'alert_body' like 'Fixed in r50h2.%'));

-- ---------------------------------------------------------------- 5. emails held for the limit: the texts (0212, 5190)
create temp table rq50n_phone as select (app.settings()).phone_enabled v;
update program_settings set phone_enabled = true where id = (app.settings()).id;
select test.ok('5190: the messages a renter must act on are texted while emails wait for the limit',
  (select array['renter_request_needs_info', 'renter_identity_needed', 'renter_identity_rejected', 'renter_offer_withdrawn', 'renter_booking_cancelled_by_us',
                'renter_change_proposed', 'renter_extension_approved', 'renter_coverage_needed', 'renter_return_details', 'renter_request_declined'] <@ email_limit_text_codes
     from site_settings where singleton));
select test.mk_booking('RQ50N-3', 'rq50n_car', 'rq50n_rita', to_char((now() + interval '20 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
                       to_char((now() + interval '22 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'confirmed');
select test.mk_booking('RQ50N-4', 'rq50n_car2', 'rq50n_rita', to_char((now() + interval '3 hours') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
                       to_char((now() + interval '3 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'confirmed');
create temp table rq50n_ob (k text, id uuid);
with x(k, code, num) as (values ('far', 'renter_identity_needed', 'RQ50N-3'), ('near', 'renter_identity_needed', 'RQ50N-4')),
ins as (
  insert into notification_outbox (code, category, priority, audience, to_address, renter_id, booking_id, payload, dedupe_key, status, send_after)
  select x.code, 'transactional', 1, 'renter', 'rq50n_rita@example.test', test.id('renter:rq50n_rita'), test.id('booking:' || x.num),
         jsonb_build_object('booking_number', x.num, 'first_name', 'Rita'), 'rq50n:' || x.k, 'queued', now() from x
  returning id, dedupe_key)
insert into rq50n_ob select substr(dedupe_key, 7), id from ins;
update notification_outbox set status = 'delayed', status_reason = 'daily email limit', send_after = now() + interval '6 hours'
 where id in (select id from rq50n_ob);
select test.ok('5190: a licence request held for the limit is texted',
  (select bool_and(limit_text_id is not null) from notification_outbox where id in (select id from rq50n_ob)));
select test.ok('5190: a pickup weeks away: the text waits for the end of quiet hours (not urgent)',
  exists (select 1 from notification_outbox n join phone_outbox p on p.id = n.limit_text_id
           where n.id = (select id from rq50n_ob where k = 'far') and not p.urgent and p.send_after = app.sms_quiet_end(p.created_at)));
select test.ok('5190: a pickup within 6 hours: the text goes at once, even at night',
  exists (select 1 from notification_outbox n join phone_outbox p on p.id = n.limit_text_id
           where n.id = (select id from rq50n_ob where k = 'near') and p.urgent));
update program_settings set phone_enabled = (select v from rq50n_phone) where id = (app.settings()).id;

-- ---------------------------------------------------------------- 6. an accident or a breakdown: who hears (0018, no test named these codes)
-- the audit (5190) found no test for the incident fan-out: the renter's instructions, the third-party owner, the staff
select test.mk_booking('RQ50N-5', 'rq50n_car', 'rq50n_rita', to_char((now() - interval '1 day') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
                       to_char((now() + interval '2 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'on_rent');
insert into incidents (id, incident_number, kind, vehicle_id, booking_id, reported_at, rental_ended, status)
values (test.id('inc:rq50n-acc'), 'RQ50N-I1', 'accident', test.id('vehicle:rq50n_car'), test.id('booking:RQ50N-5'), now(), false, 'open'),
       (test.id('inc:rq50n-brk'), 'RQ50N-I2', 'breakdown', test.id('vehicle:rq50n_car'), test.id('booking:RQ50N-5'), now(), false, 'open');
select test.eq('incident: an accident on a rental tells the staff, the renter (what to do) and the third-party owner',
  (select string_agg(code, ',' order by code) from app_events where entity = 'incident' and entity_id = test.id('inc:rq50n-acc')),
  'owner_incident_opened,renter_accident_instructions,staff_incident_reported');
select test.eq('incident: a breakdown tells the staff only',
  (select string_agg(code, ',' order by code) from app_events where entity = 'incident' and entity_id = test.id('inc:rq50n-brk')),
  'staff_breakdown_reported');
