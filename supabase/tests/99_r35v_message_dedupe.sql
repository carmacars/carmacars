-- 99: fewer repeat messages (migration 0900, docs/changes/2026-11-08-r35-fewer-repeat-messages.md): each cause of the
-- owner's November 8 list, the repeat guard for emails, texts and portal notices, the combined email and text, and how
-- Cloudflare Email Service is detected and counted in the day's cap. Fixtures start with "v35"; addresses are example.test.
select test.suite('99 r35v fewer repeat messages');
-- the production defaults (helpers.sql turns both off for the suites before this one)
update program_settings set notify_merge_window_minutes = 2, notify_repeat_window_minutes = 30;

select test.mk_owner('v35_owner');
select test.mk_vehicle('V35A', 'v35_owner');
select test.mk_vehicle('V35B', 'v35_owner');
select test.mk_vehicle('V35C', 'v35_owner');
select test.mk_renter('v35_renter');
-- pickups tomorrow, Toronto wall-clock
create temp table v35_t as select to_char((now() + interval '20 hours') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI') as pick,
                                  to_char((now() + interval '68 hours') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI') as ret,
                                  to_char((now() + interval '30 hours') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI') as pick2;
select test.mk_booking('CC-V3501', 'V35A', 'v35_renter', (select pick from v35_t), (select ret from v35_t), 'confirmed');
select test.mk_booking('CC-V3502', 'V35B', 'v35_renter', (select pick from v35_t), (select ret from v35_t), 'confirmed');
select test.mk_booking('CC-V3503', 'V35C', 'v35_renter', (select pick2 from v35_t), (select ret from v35_t), 'pending_payment');

-- ---------------------------------------------------------------- a. paying is not a change of terms
select test.eq('agreement: the card that paid and the deposit''s method are not a change',
  app.agreement_changes('{"payment": {"card": "Visa 4242", "deposit_method": "pending"}}'::jsonb, '{"payment": {"card": "Mastercard 4444", "deposit_method": "card_hold"}}'::jsonb), '[]'::jsonb);
select test.eq('agreement: a real change is still listed',
  (select x ->> 'key' from jsonb_array_elements(app.agreement_changes('{"renter": {"address": "1 Example St"}, "payment": {"card": "Visa 4242"}}'::jsonb,
                                                                    '{"renter": {"address": "2 Example St"}, "payment": {"card": "Visa 1111"}}'::jsonb)) x), 'renter.address');

-- ---------------------------------------------------------------- b and c. reminders the confirmation already gave
select app.emit_event('renter_booking_confirmed', 'booking', test.id('booking:CC-V3501'), jsonb_build_object('booking_id', test.id('booking:CC-V3501')), 'v35:confirmed:1');
select app.emit_event('renter_booking_confirmed', 'booking', test.id('booking:CC-V3502'), jsonb_build_object('booking_id', test.id('booking:CC-V3502')), 'v35:confirmed:2');
update app_events set created_at = now() - interval '4 days' where dedupe_key = 'v35:confirmed:2';
select test.ok('a confirmation minutes ago covers tomorrow''s reminder', app.ntf_confirmation_covers(test.id('booking:CC-V3501'), now() - interval '4 hours'));
select test.ok('a confirmation days ago does not', not app.ntf_confirmation_covers(test.id('booking:CC-V3502'), now() - interval '4 hours'));
select app.notify_reminders(now());
select test.eq('no "Tomorrow" reminder right after the confirmation',
  (select count(*)::int from app_events where code = 'renter_booking_reminder' and entity_id = test.id('booking:CC-V3501')), 0);
select test.eq('the reminder still goes for a booking confirmed days ago',
  (select count(*)::int from app_events where code = 'renter_booking_reminder' and entity_id = test.id('booking:CC-V3502')), 1);
select test.eq('no documents chase right after the confirmation that listed them',
  (select count(*)::int from app_events where code = 'renter_identity_needed' and entity_id = test.id('booking:CC-V3501')), 0);
select test.eq('the chase goes for the older booking with something missing',
  (select count(*)::int from app_events where code = 'renter_identity_needed' and entity_id = test.id('booking:CC-V3502')), 1);
select test.eq('only what is missing: no driver to check, the proof of coverage to send',
  (select (x ->> 'needs_licence') || '/' || (x ->> 'needs_coverage') || '/' || (x ->> 'needed_title') from app.ntf_booking(test.id('booking:CC-V3502')) x),
  'false/true/Send your proof of coverage');
insert into coverage_proofs (booking_id, coverage_option, status, insurer_name, policy_number, policy_expiry)
select test.id('booking:CC-V3502'), 1, 'submitted', 'Example Mutual', 'P-V35', current_date + 300;
select test.ok('a proof waiting for our review is not the renter''s to send', not app.renter_todo_any(test.id('booking:CC-V3502')));
-- (0970 wraps the reminders job: the body is notify_reminders_pre0970 once it exists)
select test.ok('the chase asks for what is missing', position('app.renter_todo_any' in pg_get_functiondef(coalesce(to_regprocedure('app.notify_reminders_pre0970(timestamptz)'), 'app.notify_reminders(timestamptz)'::regprocedure))) > 0);

-- ---------------------------------------------------------------- d. no recovery email while a staff pay link is open
select test.ok('before any pay link: nobody is handling the payment', not app.recovery_staff_handling(test.id('renter:v35_renter'), test.id('booking:CC-V3503'), now()));
insert into payment_requests (booking_id, renter_id, kind, covers, amount_cents, token_sha256, channel, expires_at, created_by)
values (test.id('booking:CC-V3503'), test.id('renter:v35_renter'), 'charge', 'rental', 10000, md5('v35-pay'), 'email', now() + interval '2 days', test.id('v35_owner'));
select test.ok('an open staff pay link holds the recovery email', app.recovery_staff_handling(test.id('renter:v35_renter'), test.id('booking:CC-V3503'), now()));

-- ---------------------------------------------------------------- e. each pay link email says what it is for
select test.ok('the deposit link''s email is not "Payment for booking"', position('Deposit hold for booking' in pg_get_functiondef('app.payreq_send(uuid, jsonb)'::regprocedure)) > 0);

-- ---------------------------------------------------------------- 2. the repeat guard (emails)
insert into notification_outbox (code, category, priority, audience, to_address, to_name, booking_id, renter_id, payload, dedupe_key)
values ('renter_booking_reminder', 'transactional', 1, 'renter', 'v35_renter@example.test', 'V35', test.id('booking:CC-V3502'), test.id('renter:v35_renter'), '{}'::jsonb, 'v35:rem:1');
insert into notification_outbox (code, category, priority, audience, to_address, to_name, booking_id, renter_id, payload, dedupe_key)
values ('renter_booking_reminder', 'transactional', 1, 'renter', 'V35_renter@example.test', 'V35', test.id('booking:CC-V3502'), test.id('renter:v35_renter'), '{}'::jsonb, 'v35:rem:2');
select test.eq('the same email to the same person for the same booking is held back',
  (select status || '/' || (status_reason like 'Repeat held back%')::text || '/' || sms_planned::text from notification_outbox where dedupe_key = 'v35:rem:2'), 'suppressed/true/false');
insert into notification_outbox (code, category, priority, audience, to_address, to_name, booking_id, renter_id, payload, dedupe_key)
values ('renter_booking_reminder', 'transactional', 1, 'renter', 'v35_renter@example.test', 'V35', test.id('booking:CC-V3503'), test.id('renter:v35_renter'), '{}'::jsonb, 'v35:rem:3');
select test.ok('another booking''s is not', (select status <> 'suppressed' from notification_outbox where dedupe_key = 'v35:rem:3'));
insert into notification_outbox (code, category, priority, audience, to_address, to_name, booking_id, renter_id, payload, dedupe_key)
values ('renter_payment_receipt', 'transactional', 1, 'renter', 'v35_renter@example.test', 'V35', test.id('booking:CC-V3501'), test.id('renter:v35_renter'), '{}'::jsonb, 'v35:rc:1'),
       ('renter_payment_receipt', 'transactional', 1, 'renter', 'v35_renter@example.test', 'V35', test.id('booking:CC-V3501'), test.id('renter:v35_renter'), '{}'::jsonb, 'v35:rc:2');
select test.eq('a receipt is always sent (combined, never held back)',
  (select string_agg(status, ',' order by dedupe_key) from notification_outbox where dedupe_key in ('v35:rc:1', 'v35:rc:2')), 'queued,merged');
update program_settings set notify_repeat_window_minutes = 0;
insert into notification_outbox (code, category, priority, audience, to_address, to_name, booking_id, renter_id, payload, dedupe_key)
values ('renter_booking_reminder', 'transactional', 1, 'renter', 'v35_renter@example.test', 'V35', test.id('booking:CC-V3502'), test.id('renter:v35_renter'), '{}'::jsonb, 'v35:rem:4');
select test.ok('the window is a setting: 0 turns the guard off', (select status <> 'suppressed' from notification_outbox where dedupe_key = 'v35:rem:4'));
update program_settings set notify_repeat_window_minutes = 30;

-- ---------------------------------------------------------------- 4. one email for the booking
insert into notification_outbox (code, category, priority, audience, to_address, to_name, booking_id, renter_id, payload, dedupe_key)
values ('renter_booking_confirmed', 'transactional', 1, 'renter', 'v35-merge@example.test', 'V35', test.id('booking:CC-V3502'), null, '{}'::jsonb, 'v35:m:1');
insert into notification_outbox (code, category, priority, audience, to_address, to_name, booking_id, renter_id, payload, dedupe_key)
values ('renter_payment_receipt', 'transactional', 1, 'renter', 'v35-merge@example.test', 'V35', test.id('booking:CC-V3502'), null, '{}'::jsonb, 'v35:m:2');
insert into notification_outbox (code, category, priority, audience, to_address, to_name, booking_id, renter_id, payload, dedupe_key)
values ('renter_agreement_version', 'transactional', 1, 'renter', 'v35-merge@example.test', 'V35', test.id('booking:CC-V3502'), null, '{}'::jsonb, 'v35:m:3');
insert into notification_outbox (code, category, priority, audience, to_address, to_name, booking_id, renter_id, payload, dedupe_key)
values ('renter_staff_message', 'transactional', 1, 'renter', 'v35-merge@example.test', 'V35', test.id('booking:CC-V3502'), null, '{}'::jsonb, 'v35:m:4');
-- (one transaction here: the order of arrival is set by hand)
update notification_outbox set created_at = now() + interval '1 second' where dedupe_key = 'v35:m:2';
update notification_outbox set created_at = now() + interval '2 seconds' where dedupe_key = 'v35:m:3';
select test.eq('the first is held a moment, the next ones go inside it',
  (select string_agg(status || ':' || (hold_until is not null)::text, ',' order by dedupe_key) from notification_outbox where dedupe_key in ('v35:m:1', 'v35:m:2', 'v35:m:3')),
  'queued:true,merged:false,merged:false');
select test.ok('the held one waits for the window', (select send_after > now() + interval '1 minute' and send_after <= now() + interval '2 minutes 5 seconds' from notification_outbox where dedupe_key = 'v35:m:1'));
select test.eq('a message staff typed is never held', (select status || ':' || (hold_until is null)::text || ':' || (send_after <= now() + interval '1 second')::text from notification_outbox where dedupe_key = 'v35:m:4'), 'queued:true:true');
select test.eq('one subject naming the booking',
  app.outbox_merge_parts((select id from notification_outbox where dedupe_key = 'v35:m:1')) ->> 'subject', 'Update on your booking CC-V3502: confirmed, receipt and agreement');
select test.eq('each email is its own part, the first first',
  (select string_agg(p ->> 'code', ',' order by o) from jsonb_array_elements(app.outbox_merge_parts((select id from notification_outbox where dedupe_key = 'v35:m:1')) -> 'parts') with ordinality e(p, o)),
  'renter_booking_confirmed,renter_payment_receipt,renter_agreement_version');
select test.eq('a lone email keeps its own subject', app.outbox_merge_parts((select id from notification_outbox where dedupe_key = 'v35:m:4')) -> 'subject', 'null'::jsonb);
update notification_outbox set status = 'sending', locked_at = now() where dedupe_key = 'v35:m:1';
select app.outbox_mark_sent((select id from notification_outbox where dedupe_key = 'v35:m:1'), 'cf:v35-one', 'combined');
select test.eq('sent: the parts went with it and count as one email',
  (select string_agg(status || ':' || (sent_at is not null)::text || ':' || coalesce(provider_id, ''), ',' order by dedupe_key) from notification_outbox where dedupe_key in ('v35:m:1', 'v35:m:2', 'v35:m:3')),
  'sent:true:cf:v35-one,merged:true:cf:v35-one,merged:true:cf:v35-one');
-- a combined email that will not go: its parts do not go either
insert into notification_outbox (code, category, priority, audience, to_address, to_name, booking_id, payload, dedupe_key)
values ('renter_booking_confirmed', 'transactional', 1, 'renter', 'v35-rel@example.test', 'V35', test.id('booking:CC-V3501'), '{}'::jsonb, 'v35:r:1'),
       ('renter_identity_approved', 'transactional', 1, 'renter', 'v35-rel@example.test', 'V35', test.id('booking:CC-V3501'), '{}'::jsonb, 'v35:r:2');
update notification_outbox set status = 'skipped', status_reason = 'cancelled' where dedupe_key = 'v35:r:1';
select app.outbox_merge_release(now());
select test.eq('skipped with the combined email, saying why', (select status || ':' || (status_reason like 'Not sent: the email it was combined with%')::text from notification_outbox where dedupe_key = 'v35:r:2'), 'skipped:true');
update program_settings set notify_merge_window_minutes = 0;
insert into notification_outbox (code, category, priority, audience, to_address, to_name, booking_id, payload, dedupe_key)
values ('renter_booking_confirmed', 'transactional', 1, 'renter', 'v35-off@example.test', 'V35', test.id('booking:CC-V3501'), '{}'::jsonb, 'v35:o:1');
select test.ok('the window is a setting: 0 sends each on its own', (select hold_until is null from notification_outbox where dedupe_key = 'v35:o:1'));
update program_settings set notify_merge_window_minutes = 2;

-- ---------------------------------------------------------------- f. cancelled owner invoices: one email per owner
insert into notification_outbox (code, category, priority, audience, to_address, to_name, owner_id, payload, dedupe_key)
values ('owner_invoice_voided', 'transactional', 2, 'owner', 'v35_owner@example.test', 'V35', test.id('owner:v35_owner'),
        app.owner_void_payload(jsonb_build_object('invoice_number', 'INV-V1', 'void_reason', 'Wrong amount', 'invoices', jsonb_build_array(jsonb_build_object('invoice_number', 'INV-V1', 'invoice_total', '$10.00', 'vehicle_name', 'V35A', 'void_reason', 'Wrong amount', 'replacement_number', '')))), 'v35:void:1');
insert into notification_outbox (code, category, priority, audience, to_address, to_name, owner_id, payload, dedupe_key)
values ('owner_invoice_voided', 'transactional', 2, 'owner', 'v35_owner@example.test', 'V35', test.id('owner:v35_owner'),
        app.owner_void_payload(jsonb_build_object('invoice_number', 'INV-V2', 'void_reason', 'Duplicate', 'invoices', jsonb_build_array(jsonb_build_object('invoice_number', 'INV-V2', 'invoice_total', '$20.00', 'vehicle_name', 'V35A', 'void_reason', 'Duplicate', 'replacement_number', '')))), 'v35:void:2');
select test.eq('the first waits, the second is listed in it',
  (select string_agg(status, ',' order by dedupe_key) from notification_outbox where dedupe_key like 'v35:void:%'), 'queued,merged');
select test.ok('the wait is the setting''s', (select send_after > now() + interval '29 minutes' from notification_outbox where dedupe_key = 'v35:void:1'));
select test.eq('one email listing both',
  (select (payload ->> 'voided_title') || '/' || jsonb_array_length(payload -> 'invoices') || '/' || (payload ->> 'has_several') from notification_outbox where dedupe_key = 'v35:void:1'),
  '2 invoices are cancelled/2/true');
select test.eq('a folded one is not a part of its own', jsonb_array_length(app.outbox_merge_parts((select id from notification_outbox where dedupe_key = 'v35:void:1')) -> 'parts'), 1);
select test.eq('one invoice reads as one', app.owner_void_payload('{"invoices": [{"invoice_number": "INV-9", "vehicle_name": "Car"}]}'::jsonb) ->> 'voided_title', 'Invoice INV-9 is cancelled');

-- ---------------------------------------------------------------- g. no "your car is live" for a partner's car
select test.ok('a partner car: nobody', coalesce((select count(*) = 0 from vehicles v, app.notification_recipients(
    row(null, 'owner_vehicle_listed', 'vehicle', v.id, '{}'::jsonb, 'v35:listed', null, now(), null, null)::app_events,
    (select c from notification_catalogue c where c.code = 'owner_vehicle_listed')) r where v.id = (select id from vehicles where supply_type = 'partner' limit 1)), true));
select test.ok('a partner car is never announced', position('supply_type <> ''partner''' in pg_get_functiondef('app.publish_listing(uuid, uuid)'::regprocedure)) > 0
  and position('supply_type <> ''partner''' in pg_get_functiondef('app.vehicle_status_listing_after()'::regprocedure)) > 0);

-- ---------------------------------------------------------------- 3 and 4. texts: combined, and repeats held back
select test.eq('two texts as one, a line each',
  app.sms_merge_body('CarmaCars: booking CC-1 is confirmed.', 'CarmaCars: payment received. Reply STOP to opt out.'),
  E'CarmaCars updates:\n- booking CC-1 is confirmed.\n- payment received.\nReply STOP to opt out.');
select test.eq('a third line joins them', app.sms_merge_body(E'CarmaCars updates:\n- a\n- b', 'CarmaCars: c'), E'CarmaCars updates:\n- a\n- b\n- c');
create temp table v35_p as select (app.phone_outbox_put('+16475550135', 'CarmaCars: booking CC-V3502 is confirmed.', 'notify', test.id('booking:CC-V3502'), null, 'renter_booking_confirmed', null, 'v35:sms:1')).id as a;
insert into v35_p select (app.phone_outbox_put('+16475550135', 'CarmaCars: receipt for CC-V3502.', 'notify', test.id('booking:CC-V3502'), null, 'renter_payment_receipt', null, 'v35:sms:2')).id;
select test.eq('the second text goes inside the first',
  (select string_agg(status, ',' order by dedupe_key) from phone_outbox where dedupe_key in ('v35:sms:1', 'v35:sms:2')), 'queued,merged');
select test.eq('one text, a line per item', (select body from phone_outbox where dedupe_key = 'v35:sms:1'),
  E'CarmaCars updates:\n- booking CC-V3502 is confirmed.\n- receipt for CC-V3502.');
select app.phone_outbox_put('+16475550135', 'CarmaCars: booking CC-V3502 is confirmed (again).', 'notify', test.id('booking:CC-V3502'), null, 'renter_booking_confirmed', null, 'v35:sms:3');
select test.eq('the same text for the same booking is held back', (select status from phone_outbox where dedupe_key = 'v35:sms:3'), 'suppressed');
select app.phone_outbox_put('+16475550136', 'CarmaCars: your car is ready.', 'notify', test.id('booking:CC-V3502'), null, 'renter_pickup_soon', null, 'v35:sms:4');
select test.eq('an urgent text is never held', (select (hold_until is null)::text || ':' || (send_after <= now() + interval '1 second')::text from phone_outbox where dedupe_key = 'v35:sms:4'), 'true:true');

-- ---------------------------------------------------------------- portal notices: the same guard
insert into notifications (user_id, code, title, entity, entity_id, dedupe_key)
values (test.id('v35_renter'), 'renter_booking_reminder', 'Tomorrow', 'booking', test.id('booking:CC-V3502'), 'v35:n:1');
insert into notifications (user_id, code, title, entity, entity_id, dedupe_key)
values (test.id('v35_renter'), 'renter_booking_reminder', 'Tomorrow', 'booking', test.id('booking:CC-V3502'), 'v35:n:2');
select test.eq('the same portal notice twice is shown once', (select count(*)::int from notifications where dedupe_key like 'v35:n:%'), 1);

-- ---------------------------------------------------------------- 5. Cloudflare Email Service: detected and counted
create temp table v35_ps as select * from email_provider_state;
create temp table v35_cf as select bool_or(cf_email_enabled) as was_on from program_settings;
-- since 1750 a Cloudflare send in the last 48 hours means it works: earlier suites' sends are set three days back for this
-- section (and put back after it)
create temp table v35_recent as select id, sent_at from notification_outbox where provider_id like 'cf:%' and sent_at > now() - interval '48 hours';
update notification_outbox o set sent_at = r.sent_at - interval '3 days' from v35_recent r where o.id = r.id;
update email_provider_state set cf_ok_at = now() - interval '3 days', cf_failed_at = null, cf_error = null;
update program_settings set cf_email_enabled = true;
select test.ok('a recorded success counts as Cloudflare sending', app.cf_email_ever_sent());
select test.eq('ok after a success, even days ago', app.cf_email_setup(now()) ->> 'state', 'ok');
select test.eq('the cap is Cloudflare''s budget plus Resend''s',
  app.email_day_cap(now()), (select least(s.notify_daily_cap, s.notify_cf_daily_budget + s.notify_resend_daily_budget) from app.settings_base(app.local_date(now())) s));
select test.eq('the pace read says so', (app.email_pace(now()) ->> 'cf_counted')::boolean, true);
update email_provider_state set cf_failed_at = now() - interval '1 hour', cf_error = 'Cloudflare: The operation was aborted due to timeout';
select test.eq('a timeout an hour ago is not a refusal', app.cf_email_setup(now()) ->> 'state', 'ok');
update email_provider_state set cf_failed_at = now(), cf_error = 'Cloudflare 502: refused';
select test.eq('a refusal since the last success: failing', app.cf_email_setup(now()) ->> 'state', 'failing');
update email_provider_state set cf_failed_at = now() - interval '1 hour', cf_error = 'Cloudflare 503: no EMAIL binding on the Worker (Email Service not set up)';
-- since 1750 Cloudflare rests only 15 minutes after a refusal and keeps its day in the capacity (99_r35c_email_capacity)
select test.eq('no binding: not set up; the day stays Cloudflare''s plus Resend''s (1750)', (app.cf_email_setup(now()) ->> 'state') || '/' || app.email_day_cap(now()),
  'absent/' || (app.cf_emails_between(app.local_midnight(app.local_date(now())), now() + interval '1 second') + app.cf_email_left(now())
                + (select least(s.notify_daily_cap, s.notify_resend_daily_budget) from app.settings_base(app.local_date(now())) s)));
update email_provider_state e set cf_ok_at = p.cf_ok_at, cf_failed_at = p.cf_failed_at, cf_error = p.cf_error from v35_ps p;
update program_settings set cf_email_enabled = (select was_on from v35_cf);
update notification_outbox o set sent_at = r.sent_at from v35_recent r where o.id = r.id;
update program_settings set notify_merge_window_minutes = 0, notify_repeat_window_minutes = 0;
