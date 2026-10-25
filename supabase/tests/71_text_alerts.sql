-- 71: text alerts (migration 0096). Each person's channel (Email, Text or Both) and its default; who can be texted (a
-- verified phone, STOP, the US gate, numbers outside Canada and the US, switched off); routing of every customer
-- notification (text only skips the email, both sends both, documents always emailed, sign-in emails never texted,
-- marketing only with consent, staff notices untouched, a phone-only account); the texts (template, generic, link,
-- the STOP line on the first text and after START); quiet hours (non-urgent texts wait, urgent ones go); STOP while a
-- text waits sends the email instead, more keywords, the log; the job checking again before sending; setting the
-- channel (profile, the booking request, staff with the audit log, who may); Settings and Site health reads;
-- privileges; the privacy policy; every customer email has its own text; the STOP and START confirmation texts; a
-- driver's link texted to the driver. Fixtures start with "ta".
select test.suite('71 text alerts');

select test.mk_user('ta_admin', 'admin');
select test.mk_user('ta_cs', 'va', 'cs');
select test.mk_renter('ta_tess');                 -- verified phone, email
select test.mk_renter('ta_eve');                  -- email only
select test.mk_renter('ta_guest', false);         -- a record without an account
select test.mk_owner('ta_otto');
select test.mk_vehicle('ta_car', 'ta_otto');
-- a phone-only account (made by phone sign-in): no email
insert into users (id, email, phone, phone_verified_at, full_name, preferred_sign_in) values (test.id('ta_pia'), null, '+14375550301', now(), 'Pia Phone', 'phone');
insert into user_roles (user_id, role) values (test.id('ta_pia'), 'renter');
insert into renters (id, user_id, legal_name, mobile) values (test.id('renter:ta_pia'), test.id('ta_pia'), 'Pia Phone', '+14375550301');
insert into payment_methods (id, renter_id, card_brand, card_last4, cardholder_name, exp_month, exp_year, is_credit)
values (test.id('card:ta_pia'), test.id('renter:ta_pia'), 'visa', '4242', 'Pia Phone', 12, 2030, true);
insert into users (id, email, full_name) values (test.id('ta_ivy'), 'ta_ivy@example.test', 'Ivy Investor');
insert into investors (id, user_id, legal_name, investor_type, email) values (test.id('investor:ta_ivy'), test.id('ta_ivy'), 'Ivy Investor', 'individual', 'ta_ivy@example.test');
update users set phone = '+16475550302', phone_verified_at = now() where id = test.id('ta_tess');
update users set phone = '+14165550303', phone_verified_at = now() where id = test.id('ta_otto');
update program_settings set sms_alerts_enabled = true, sms_quiet_hours = false, signin_phone_us_allowed = false, phone_enabled = true, sms_stop_line = true,
  sms_default_with_phone = 'both', sms_default_phone_only = 'text';
select test.mk_booking('TA-1', 'ta_car', 'ta_tess', to_char((now() + interval '5 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
  to_char((now() + interval '8 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'confirmed');
select test.mk_booking('TA-2', 'ta_car', 'ta_pia', to_char((now() + interval '15 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
  to_char((now() + interval '17 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'confirmed');

-- a notification row as app.process_events writes it (one per recipient)
create or replace function test.tmail(p_code text, p_key text, p_user uuid, p_renter uuid, p_to text, p_booking text default 'TA-1',
  p_status text default 'queued', p_reason text default null, p_category text default null, p_audience text default 'renter', p_owner uuid default null) returns notification_outbox
language sql as $$
  insert into notification_outbox (code, category, priority, audience, recipient_user_id, to_address, renter_id, owner_id, booking_id, payload, dedupe_key, status, status_reason)
  values (p_code, coalesce(p_category, (select category from notification_catalogue where code = p_code)), 1, p_audience, p_user, p_to, p_renter, p_owner,
          case when p_booking is not null then test.id('booking:' || p_booking) end,
          jsonb_build_object('first_name', 'Tess', 'booking_number', coalesce(p_booking, ''), 'vehicle_name', '2023 Mercedes-Benz C 300', 'pickup_date', 'Fri, Oct 30, 2026',
            'pickup_time', '10:00 am', 'total_amount', '$612.00', 'amount', '$612.00', 'return_time', '10:00 am', 'statement_month', 'October 2026', 'payout_amount', '$812.00',
            'invoice_number', 'INV-9', 'invoice_total', '$45.00', 'due_date', 'Nov 1, 2026', 'final_deadline', 'Sat, Oct 31 at 2:00 pm'),
          p_key, p_status, p_reason)
  returning * $$;
create or replace function test.ttext(p_key text) returns setof phone_outbox language sql stable as $$ select * from phone_outbox where dedupe_key = 'sms:' || p_key $$;
create or replace function test.tstatus(p_key text) returns text language sql stable as $$ select status || coalesce(': ' || status_reason, '') from notification_outbox where dedupe_key = p_key $$;

-- ================================================================ 1. settings and templates
select test.eq('settings: on, Both with a phone, Text for a phone-only account, quiet hours 21 to 8, the STOP line',
  (select format('%s %s %s %s %s %s', sms_alerts_enabled, sms_default_with_phone, sms_default_phone_only, sms_quiet_from_hour, sms_quiet_until_hour, sms_stop_line)
     from program_settings order by effective_from desc limit 1), 't both text 21 8 t');
select test.ok('every listed notification has its own short text', (select count(*) from sms_templates where code in ('renter_request_received', 'renter_offer_ready',
  'renter_booking_confirmed', 'renter_payment_receipt', 'renter_payment_failed', 'renter_deposit_declined', 'renter_booking_reminder', 'renter_return_reminder',
  'renter_extension_confirmed', 'renter_late_return_first', 'renter_agreement_ready', 'renter_identity_needed', 'renter_review_request', 'owner_payout_sent',
  'owner_statement_ready', 'owner_fee_invoice', 'owner_agreement_ready', 'owner_new_booking')) = 18);
select test.ok('every template: CarmaCars, the link, no long dash, at most 320 characters',
  not exists (select 1 from sms_templates where not app.sms_template_ok(body) or length(body) > 320));
select test.throws('a template with a long dash is refused', format($$update sms_templates set body = 'CarmaCars %s ready {{link}}' where code = 'renter_offer_ready'$$, chr(8212)), 'sms_templates_body_check');
select test.throws('a template without the link is refused', $$update sms_templates set body = 'CarmaCars: your offer is ready' where code = 'renter_offer_ready'$$, 'sms_templates_body_check');
select test.eq('every customer email (renter, owner, investor, driver, co-signer, lead) has its own text, except the sign-in and security ones',
  (select count(*) from notification_catalogue c where c.audience in ('renter', 'owner', 'investor') and not c.no_text and not exists (select 1 from sms_templates t where t.code = c.code)),
  0::bigint);
select test.eq('...116 texts; never texted: password reset, sign-in link, security notice, the continue-your-request sign-in link, the signing code and the agreement versions (their signers get their own text, 0154)',
  (select count(*) from sms_templates)::text || ' | ' || (select string_agg(code, ',' order by code) from notification_catalogue where no_text),
  '116 | account_password_reset,account_security_notice,account_sign_in_link,renter_agreement_version,renter_continue_request,renter_signing_code');
select test.ok('documents are always emailed; sign-in emails never become texts',
  (select bool_and(always_email) from notification_catalogue where code in ('renter_payment_receipt', 'renter_agreement_signed', 'owner_statement_ready', 'investor_statement_ready'))
  and (select bool_and(no_text) from notification_catalogue where code in ('account_password_reset', 'account_sign_in_link')));
select test.eq('the renderer: a missing value leaves no gap', app.sms_render('CarmaCars: refund {{refund_amount}}. Details: {{link}}', '{"link": "https://carmacars.ca/x"}'),
  'CarmaCars: refund. Details: https://carmacars.ca/x');

-- ================================================================ 2. reach: the channel and who can be texted
select test.eq('no verified phone: Email', (select format('%s %s %s', r ->> 'default', r ->> 'channel', r ->> 'why_not') from (select app.notify_reach(test.id('ta_eve')) r) x), 'email email no_verified_phone');
select test.eq('a verified phone and an email: Both by default', (select format('%s %s %s', r ->> 'default', r ->> 'channel', r ->> 'textable') from (select app.notify_reach(test.id('ta_tess')) r) x), 'both both true');
select test.eq('a phone-only account: Text by default', (select format('%s %s', r ->> 'default', r ->> 'channel') from (select app.notify_reach(test.id('ta_pia')) r) x), 'text text');
select test.eq('Email chosen by a phone-only account: still text (no address to email)', (app.set_notify_channel(test.id('ta_pia'), 'email') ->> 'channel'), 'text');
select app.set_notify_channel(test.id('ta_pia'), null);
select test.eq('Text chosen without a verified phone: email until a phone is verified', (select format('%s %s', r ->> 'wanted', r ->> 'channel') from (select app.set_notify_channel(test.id('ta_eve'), 'text') r) x), 'text email');
select test.eq('a record without an account: its own choice, email only', (select format('%s %s', r ->> 'chosen', r ->> 'channel') from (select app.notify_staff(test.id('ta_cs'), 'notify_channel_set', jsonb_build_object('renter_id', test.id('renter:ta_guest'), 'channel', 'both')) r) x), 'both email');
update users set phone = '+12125550304', phone_verified_at = now() where id = test.id('ta_eve');
select test.eq('a US number: email while US texting waits for A2P 10DLC', (select format('%s %s', r ->> 'channel', r ->> 'why_not') from (select app.notify_reach(test.id('ta_eve')) r) x), 'email us_waiting');
update program_settings set signin_phone_us_allowed = true;
select test.eq('...texted once an Admin allows US numbers', app.notify_reach(test.id('ta_eve')) ->> 'channel', 'text');
update program_settings set signin_phone_us_allowed = false;
update users set phone = '+447700900305' where id = test.id('ta_eve');
select test.eq('a number outside Canada and the US: email', app.notify_reach(test.id('ta_eve')) ->> 'why_not', 'not_canada');
update users set phone = null, phone_verified_at = null where id = test.id('ta_eve');
update program_settings set sms_alerts_enabled = false;
select test.eq('text alerts switched off: everyone on email', (select format('%s %s', r ->> 'channel', r ->> 'why_not') from (select app.notify_reach(test.id('ta_tess')) r) x), 'email off');
update program_settings set sms_alerts_enabled = true;

-- ================================================================ 3. routing
-- Both (Tess's default): the email and a text, the first text with the STOP line
select test.tmail('renter_offer_ready', 'ta-1', test.id('ta_tess'), test.id('renter:ta_tess'), 'ta_tess@example.test');
select test.eq('Both: the email goes, and a text with the link and the STOP line',
  test.tstatus('ta-1') || ' | ' || (select format('%s %s %s', kind, status, to_number) from test.ttext('ta-1')) || ' | ' || (select body from test.ttext('ta-1')),
  format('queued | notify queued +16475550302 | CarmaCars: your offer for the 2023 Mercedes-Benz C 300 is ready, $612.00. Review and accept: %s/account/bookings/TA-1/offer Reply STOP to opt out.',
         (app.settings()).notify_base_url));
select test.eq('...the row says Both', (select channel from notification_outbox where dedupe_key = 'ta-1'), 'both');
select test.tmail('renter_booking_confirmed', 'ta-2', test.id('ta_tess'), test.id('renter:ta_tess'), 'ta_tess@example.test');
select test.ok('the second text has no STOP line', (select body not like '%STOP%' and body like 'CarmaCars: booking TA-1 is confirmed.%' from test.ttext('ta-2')));
-- Text only
select app.set_notify_channel(test.id('ta_tess'), 'text');
select test.tmail('renter_booking_reminder', 'ta-3', test.id('ta_tess'), test.id('renter:ta_tess'), 'ta_tess@example.test');
select test.eq('Text: the email is skipped and the text queued', test.tstatus('ta-3') || ' | ' || (select status from test.ttext('ta-3')), 'skipped: Sent by text (the person chose text) | queued');
select test.tmail('renter_payment_receipt', 'ta-4', test.id('ta_tess'), test.id('renter:ta_tess'), 'ta_tess@example.test');
select test.eq('Text, a receipt: still emailed (a document), and a text with a link to view it', test.tstatus('ta-4') || ' | ' || (select body like '%Receipt: %/account/bookings/TA-1' from test.ttext('ta-4')), 'queued | true');
select test.tmail('account_password_reset', 'ta-5', test.id('ta_tess'), test.id('renter:ta_tess'), 'ta_tess@example.test', null);
select test.eq('a sign-in email is never a text, and never skipped', test.tstatus('ta-5') || ' ' || (select count(*) from test.ttext('ta-5')), 'queued 0');
create temp table ta_tpl as select * from sms_templates where code = 'renter_damage_found';
delete from sms_templates where code = 'renter_damage_found';
select test.tmail('renter_damage_found', 'ta-6', test.id('ta_tess'), test.id('renter:ta_tess'), 'ta_tess@example.test');
select test.eq('a notification without its own text (one added later): the generic text from the subject, always emailed (a notice)', test.tstatus('ta-6') || ' | ' || (select body from test.ttext('ta-6')),
  format('queued | CarmaCars: Damage found on the 2023 Mercedes-Benz C 300 after your return. Details: %s/account', (app.settings()).notify_base_url));
insert into sms_templates select * from ta_tpl;
select test.tmail('renter_damage_found', 'ta-6b', test.id('ta_tess'), test.id('renter:ta_tess'), 'ta_tess@example.test');
select test.eq('...with its own text', (select body from test.ttext('ta-6b')),
  format('CarmaCars: we found damage on the 2023 Mercedes-Benz C 300 after your return (booking TA-1). Details: %s/account', (app.settings()).notify_base_url));
update sms_templates set enabled = false where code = 'renter_return_reminder';
select test.tmail('renter_return_reminder', 'ta-7', test.id('ta_tess'), test.id('renter:ta_tess'), 'ta_tess@example.test');
select test.eq('a text switched off in Settings: the email goes even for Text', test.tstatus('ta-7') || ' ' || (select count(*) from test.ttext('ta-7')), 'queued 0');
update sms_templates set enabled = true where code = 'renter_return_reminder';
-- marketing: the review request follows consent
select test.tmail('renter_review_request', 'ta-8', test.id('ta_tess'), test.id('renter:ta_tess'), 'ta_tess@example.test', 'TA-1', 'skipped', 'no marketing consent');
select test.eq('a review request without consent: no text either', (select count(*) from test.ttext('ta-8')), 0::bigint);
select test.tmail('renter_review_request', 'ta-9', test.id('ta_tess'), test.id('renter:ta_tess'), 'ta_tess@example.test');
select test.eq('...with consent (the email went): a text instead of the email', test.tstatus('ta-9') || ' | ' || (select status from test.ttext('ta-9')), 'skipped: Sent by text (the person chose text) | queued');
-- Email chosen
select app.set_notify_channel(test.id('ta_tess'), 'email');
select test.tmail('renter_payment_failed', 'ta-10', test.id('ta_tess'), test.id('renter:ta_tess'), 'ta_tess@example.test');
select test.eq('Email: no text', test.tstatus('ta-10') || ' ' || (select count(*) from test.ttext('ta-10')), 'queued 0');
-- no verified phone: email only even with Text chosen (Eve)
select test.tmail('renter_offer_ready', 'ta-11', test.id('ta_eve'), test.id('renter:ta_eve'), 'ta_eve@example.test', null);
select test.eq('Text chosen, no verified phone: the email goes, no text', test.tstatus('ta-11') || ' ' || (select count(*) from test.ttext('ta-11')) || ' ' || (select channel from notification_outbox where dedupe_key = 'ta-11'), 'queued 0 email');
-- a phone-only account: the email had no address, the text goes
select test.tmail('renter_booking_confirmed', 'ta-12', test.id('ta_pia'), test.id('renter:ta_pia'), null, 'TA-2', 'skipped', 'no email address');
select test.eq('a phone-only account: no email address, so the text', test.tstatus('ta-12') || ' | ' || (select format('%s %s', status, to_number) from test.ttext('ta-12')), 'skipped: no email address | queued +14375550301');
-- an owner on Both, an investor without a phone, a staff notice
select test.tmail('owner_payout_sent', 'ta-13', test.id('ta_otto'), null, 'ta_otto@example.test', null, 'queued', null, null, 'owner', test.id('owner:ta_otto'));
select test.eq('an owner (Both by default): the email and a text to the owner''s portal', test.tstatus('ta-13') || ' | ' || (select body like 'CarmaCars: payout of $812.00 sent for October 2026. Details: %/owner/statements/%' from test.ttext('ta-13')),
  'queued | true');
select test.tmail('investor_statement_ready', 'ta-14', test.id('ta_ivy'), null, 'ta_ivy@example.test', null, 'queued', null, null, 'investor');
select test.eq('an investor without a verified phone: email only', test.tstatus('ta-14') || ' ' || (select count(*) from test.ttext('ta-14')), 'queued 0');
insert into notification_outbox (code, category, priority, audience, recipient_user_id, to_address, payload, dedupe_key)
values ('staff_booking_request_new', 'transactional', 3, 'staff_va_cs', test.id('ta_otto'), 'ta_otto@example.test', '{}', 'ta-15');
select test.eq('a staff notice is never routed', (select coalesce(channel, 'none') || ' ' || status from notification_outbox where dedupe_key = 'ta-15') || ' ' || (select count(*) from test.ttext('ta-15')), 'none queued 0');
select test.eq('the same notification twice makes one text', (select count(*) from phone_outbox where dedupe_key = 'sms:ta-1'), 1::bigint);

-- an additional driver's link: texted to the driver's own account (Eve here), never to the renter (Tess)
update users set phone = '+16475550310', phone_verified_at = now() where id = test.id('ta_eve');
select app.set_notify_channel(test.id('ta_eve'), 'both');
insert into notification_outbox (code, category, priority, audience, to_address, renter_id, booking_id, payload, dedupe_key)
values ('renter_driver_link', 'transactional', 1, 'renter', 'TA_eve@example.test', test.id('renter:ta_tess'), test.id('booking:TA-1'),
        '{"first_name": "Eve", "renter_name": "Tess Renter", "booking_number": "TA-1", "sign_url": "https://carmacars.ca/sign/driver/abc"}', 'ta-16');
select test.eq('a driver''s link: the driver''s phone, with the signing link (the email address finds the account)',
  (select to_number || ' | ' || body from test.ttext('ta-16')),
  '+16475550310 | CarmaCars: Tess Renter added you as a driver on booking TA-1. Accept the rental agreement before pickup: https://carmacars.ca/sign/driver/abc Reply STOP to opt out.');
select test.tmail('owner_cosigner_sign', 'ta-17', null, null, 'nobody@example.test', null, 'queued', null, null, 'owner', test.id('owner:ta_otto'));
select test.eq('a co-signer without an account: email only, never a text to the owner', test.tstatus('ta-17') || ' ' || (select count(*) from test.ttext('ta-17')), 'queued 0');
update users set phone = null, phone_verified_at = null, notify_channel = 'text' where id = test.id('ta_eve');

-- ================================================================ 4. quiet hours
update program_settings set sms_quiet_hours = true, sms_quiet_from_hour = 21, sms_quiet_until_hour = 8;
select test.eq('quiet hours: 22:30 waits for 8:00 the next morning, 6:00 for 8:00 the same morning, noon goes now',
  to_char(app.sms_quiet_end('2026-10-22 22:30'::timestamp at time zone 'America/Toronto') at time zone 'America/Toronto', 'DD HH24:MI') || ' '
  || to_char(app.sms_quiet_end('2026-10-23 06:00'::timestamp at time zone 'America/Toronto') at time zone 'America/Toronto', 'DD HH24:MI') || ' '
  || to_char(app.sms_quiet_end('2026-10-23 12:00'::timestamp at time zone 'America/Toronto') at time zone 'America/Toronto', 'DD HH24:MI'), '23 08:00 23 08:00 23 12:00');
select test.eq('...21:00 is quiet, 8:00 is not', to_char(app.sms_quiet_end('2026-10-22 21:00'::timestamp at time zone 'America/Toronto') at time zone 'America/Toronto', 'DD HH24:MI') || ' '
  || to_char(app.sms_quiet_end('2026-10-23 08:00'::timestamp at time zone 'America/Toronto') at time zone 'America/Toronto', 'DD HH24:MI'), '23 08:00 23 08:00');
-- quiet now: from this hour to the next
update program_settings set sms_quiet_from_hour = app.local_hour(now()), sms_quiet_until_hour = (app.local_hour(now()) + 1) % 24;
select app.set_notify_channel(test.id('ta_tess'), 'both');
select test.tmail('renter_return_reminder', 'ta-20', test.id('ta_tess'), test.id('renter:ta_tess'), 'ta_tess@example.test');
select test.tmail('renter_late_return_first', 'ta-21', test.id('ta_tess'), test.id('renter:ta_tess'), 'ta_tess@example.test');
select test.eq('during the quiet hours: a reminder waits for their end; a late return notice (urgent) goes now',
  (select send_after > now() + interval '1 second' and send_after <= now() + interval '1 hour' from test.ttext('ta-20'))::text || ' '
  || (select send_after <= now() from test.ttext('ta-21'))::text, 'true true');
select test.eq('...the waiting text is not claimed by the job yet', (select count(*) from jsonb_array_elements(app.server_phone_due() -> 'texts') x where x ->> 'id' = (select id::text from test.ttext('ta-20'))), 0::bigint);
update program_settings set sms_quiet_hours = false, sms_quiet_from_hour = 21, sms_quiet_until_hour = 8;

-- ================================================================ 5. the US gate on every text
select test.eq('a staff reply to a US number waits for A2P 10DLC', (app.phone_outbox_put('+12125550306', 'Hello from CarmaCars', 'staff')).status_reason like 'US texts wait for A2P 10DLC%', true);
update program_settings set signin_phone_us_allowed = true;
select test.eq('...queued once US numbers are allowed', (app.phone_outbox_put('+12125550307', 'Hello from CarmaCars', 'staff')).status, 'queued');
update program_settings set signin_phone_us_allowed = false;

-- ================================================================ 6. STOP, START, the fallback email, the log
select app.set_notify_channel(test.id('ta_tess'), 'text');
select test.tmail('renter_extension_confirmed', 'ta-30', test.id('ta_tess'), test.id('renter:ta_tess'), 'ta_tess@example.test');
select test.eq('a text waiting, its email skipped', test.tstatus('ta-30') || ' | ' || (select status from test.ttext('ta-30')), 'skipped: Sent by text (the person chose text) | queued');
update program_settings set sms_quiet_hours = true, sms_quiet_from_hour = app.local_hour(now()), sms_quiet_until_hour = (app.local_hour(now()) + 1) % 24;
create temp table ta_stop as select app.server_phone_event(jsonb_build_object('event_id', 'ev-ta-stop', 'type', 'message.received', 'quo_id', 'AC-ta-stop', 'direction', 'in',
  'their_number', '+16475550302', 'text', 'STOP', 'status', 'received', 'at', now())) as x;
select test.eq('STOP: one confirmation text, sent at once by the webhook even in the quiet hours (Quo sends none)',
  (select string_agg(e ->> 'body', ' / ') from ta_stop, jsonb_array_elements(ta_stop.x -> 'send') e),
  'CarmaCars: you''re unsubscribed and won''t get more texts. Reply START to resubscribe.');
select test.eq('...an opt_confirm row being sent, linked from the log', (select format('%s %s %s', o.kind, o.status, o.sms_kind) from sms_opt_out_log l join phone_outbox o on o.id = l.confirm_id
  where l.number = '+16475550302' and l.action = 'stop'), 'opt_confirm sending opt_stop');
select app.server_phone_sent(jsonb_build_object('id', (select e ->> 'id' from ta_stop, jsonb_array_elements(ta_stop.x -> 'send') e limit 1), 'ok', true, 'quo_id', 'AC-ta-stop-conf'));
update program_settings set sms_quiet_hours = false, sms_quiet_from_hour = 21, sms_quiet_until_hour = 8;
select test.eq('...a second STOP: no second confirmation', (select jsonb_array_length(app.server_phone_event(jsonb_build_object('event_id', 'ev-ta-stop2', 'type', 'message.received',
  'quo_id', 'AC-ta-stop2', 'direction', 'in', 'their_number', '+16475550302', 'text', 'STOP', 'status', 'received', 'at', now())) -> 'send'))
  || ' ' || (select count(*) from phone_outbox where to_number = '+16475550302' and kind = 'opt_confirm'), '0 1');
select test.eq('STOP: the waiting text is skipped and its email goes instead', (select status from test.ttext('ta-30')) || ' | ' || test.tstatus('ta-30'),
  'skipped | queued: By email: the text was not sent (The number opted out of texts)');
select test.eq('...the person is now reached by email, and the profile says why', (select format('%s %s', r ->> 'channel', r ->> 'why_not') from (select app.my_notify_channel(test.id('ta_tess')) r) x), 'email opted_out');
select test.tmail('renter_extension_declined', 'ta-31', test.id('ta_tess'), test.id('renter:ta_tess'), 'ta_tess@example.test');
select test.eq('...new notifications: email only, no text', test.tstatus('ta-31') || ' ' || (select count(*) from test.ttext('ta-31')), 'queued 0');
select test.eq('the opt-out log has the STOP', (select string_agg(action || ':' || coalesce(source, ''), ',') from sms_opt_out_log where number = '+16475550302'), 'stop:stop');
create temp table ta_start as select app.server_phone_event(jsonb_build_object('event_id', 'ev-ta-start', 'type', 'message.received', 'quo_id', 'AC-ta-start', 'direction', 'in',
  'their_number', '+16475550302', 'text', 'START', 'status', 'received', 'at', now())) as x;
select test.eq('START: texts again, logged', (app.notify_reach(test.id('ta_tess')) ->> 'channel') || ' ' || (select count(*) from sms_opt_out_log where number = '+16475550302' and action = 'start'), 'text 1');
select test.eq('...and confirmed by one text', (select string_agg(e ->> 'body', ' / ') from ta_start, jsonb_array_elements(ta_start.x -> 'send') e)
  || ' | ' || (select o.sms_kind from sms_opt_out_log l join phone_outbox o on o.id = l.confirm_id where l.number = '+16475550302' and l.action = 'start'),
  'CarmaCars: texts are back on. Reply STOP to opt out. | opt_start');
select test.tmail('renter_identity_needed', 'ta-32', test.id('ta_tess'), test.id('renter:ta_tess'), 'ta_tess@example.test');
select test.ok('the first text after START has the STOP line again', (select body like '%Reply STOP to opt out.' from test.ttext('ta-32')));
select app.server_phone_event(jsonb_build_object('event_id', 'ev-ta-optout', 'type', 'message.received', 'quo_id', 'AC-ta-optout', 'direction', 'in',
  'their_number', '+16475550302', 'text', 'Opt out', 'status', 'received', 'at', now()));
select test.eq('more keywords: OPT OUT stops texts too', (app.notify_reach(test.id('ta_tess')) ->> 'why_not') || ' ' || (select status from test.ttext('ta-32')), 'opted_out skipped');
select app.server_phone_event(jsonb_build_object('event_id', 'ev-ta-start2', 'type', 'message.received', 'quo_id', 'AC-ta-start2', 'direction', 'in',
  'their_number', '+16475550302', 'text', 'start', 'status', 'received', 'at', now()));
select test.eq('OPT OUT and START (other keywords) are confirmed too: 2 STOP and 2 START confirmations in all',
  (select count(*) filter (where sms_kind = 'opt_stop')::text || ' ' || count(*) filter (where sms_kind = 'opt_start') from phone_outbox where to_number = '+16475550302' and kind = 'opt_confirm'), '2 2');
-- staff and carrier changes are logged, never texted
select app.phone_outbox_put('+16475550309', 'Hello from CarmaCars', 'staff');
update phone_threads set opted_out_at = now(), opt_out_source = 'staff' where number = '+16475550309';
update phone_threads set opted_out_at = null, opt_out_source = null where number = '+16475550309';
select app.server_phone_event(jsonb_build_object('event_id', 'ev-ta-carrier', 'type', 'message.failed', 'quo_id', 'AC-ta-carrier', 'direction', 'out',
  'their_number', '+16475550309', 'status', 'failed', 'error_code', '30006', 'at', now()));
select test.eq('a staff change or a carrier error: logged, no confirmation text',
  (select string_agg(action || ':' || coalesce(source, '') || ':' || (confirm_id is not null), ',' order by id) from sms_opt_out_log where number = '+16475550309')
  || ' ' || (select count(*) from phone_outbox where to_number = '+16475550309' and kind = 'opt_confirm'), 'stop:staff:false,start:staff:false,stop:carrier:false 0');
-- a US number while US texting waits: the confirmation is logged as skipped
select app.phone_thread_for('+12125550308');
select app.server_phone_event(jsonb_build_object('event_id', 'ev-ta-us-stop', 'type', 'message.received', 'quo_id', 'AC-ta-us-stop', 'direction', 'in',
  'their_number', '+12125550308', 'text', 'STOP', 'status', 'received', 'at', now()));
select test.eq('a US number before A2P 10DLC: opted out, the confirmation skipped with the reason',
  (select format('%s %s', o.status, left(o.status_reason, 27)) from sms_opt_out_log l join phone_outbox o on o.id = l.confirm_id where l.number = '+12125550308'), 'skipped US texts wait for A2P 10DLC');
-- a confirmation that never reported back is not sent again
update phone_outbox set status = 'sending', locked_at = now() - interval '11 minutes' where id = (select confirm_id from sms_opt_out_log where number = '+16475550302' and action = 'start' order by id desc limit 1);
select app.server_phone_due();
select test.eq('...a confirmation with no answer from Quo is not retried', (select status from phone_outbox where id = (select confirm_id from sms_opt_out_log where number = '+16475550302' and action = 'start' order by id desc limit 1)), 'failed');
-- a refusal from Quo: the email instead
select test.tmail('renter_agreement_ready', 'ta-33', test.id('ta_tess'), test.id('renter:ta_tess'), 'ta_tess@example.test');
select app.server_phone_sent(jsonb_build_object('id', (select id from test.ttext('ta-33')), 'ok', false, 'error', 'Quo 400: invalid number', 'permanent', true));
select test.eq('a text Quo refuses: its email goes', (select status from test.ttext('ta-33')) || ' | ' || split_part(test.tstatus('ta-33'), ' (', 1), 'failed | queued: By email: the text was not sent');

-- ================================================================ 7. the job checks again before sending
select test.tmail('renter_coverage_needed', 'ta-40', test.id('ta_tess'), test.id('renter:ta_tess'), 'ta_tess@example.test');
update phone_outbox set send_after = now() - interval '1 minute' where dedupe_key = 'sms:ta-40';
select app.set_notify_channel(test.id('ta_tess'), 'email');
create temp table ta_due as select app.server_phone_due() as x;
select test.eq('the person chose email while the text waited: the job skips it and the email goes',
  (select count(*) from ta_due, jsonb_array_elements(ta_due.x -> 'texts') e where e ->> 'id' = (select id::text from test.ttext('ta-40')))::text || ' '
  || (select status from test.ttext('ta-40')) || ' | ' || split_part(test.tstatus('ta-40'), ' (', 1), '0 skipped | queued: By email: the text was not sent');

-- ================================================================ 8. setting the channel
select test.throws('not a channel', $$select app.set_notify_channel(test.id('ta_tess'), 'pigeon')$$, 'Choose Email, Text or Both');
select test.eq('the profile card: the choice and when, our number for START',
  (select format('%s %s %s', r ->> 'chosen', r ->> 'chosen_at' is not null, r ->> 'our_number' is not null) from (select app.my_notify_channel(test.id('ta_tess')) r) x), 'email t t');
update bookings set created_at = now() - interval '2 hours' where id = test.id('booking:TA-1');
select test.eq('the booking request: a visitor cannot set the channel of an older booking',
  app.request_notify_channel('TA-1', 'both', null) ->> 'error', 'too_late');
update bookings set created_at = now() where id = test.id('booking:TA-2');
select test.eq('...a fresh request: saved', app.request_notify_channel('TA-2', 'both', null) ->> 'ok', 'true');
select test.eq('...someone else signed in cannot set it', app.request_notify_channel('TA-2', 'text', test.id('ta_eve')) ->> 'error', 'not_yours');
select test.eq('...the person signed in', app.request_notify_channel('TA-2', 'text', test.id('ta_pia')) ->> 'ok', 'true');
select test.eq('...saved on the record and the account', (select notify_channel from users where id = test.id('ta_pia')) || ' ' || (select notify_channel from renters where id = test.id('renter:ta_pia')), 'text text');
select test.eq('staff: customer service changes a renter''s channel',
  app.notify_staff(test.id('ta_cs'), 'notify_channel_set', jsonb_build_object('renter_id', test.id('renter:ta_tess'), 'channel', 'both')) ->> 'channel', 'both');
select test.eq('...recorded in the audit log', (select count(*) from audit_log where action = 'notify_channel_set' and actor_user_id = test.id('ta_cs') and entity_id::text = test.id('renter:ta_tess')::text), 1::bigint);
select test.eq('...back to the default', (app.notify_staff(test.id('ta_admin'), 'notify_channel_set', jsonb_build_object('renter_id', test.id('renter:ta_tess'), 'channel', null)) ->> 'chosen') is null, true);
select test.throws('...an investor''s only by an Admin', format($$select app.notify_staff(%L, 'notify_channel_set', jsonb_build_object('investor_id', %L, 'channel', 'text'))$$, test.id('ta_cs'), test.id('investor:ta_ivy')), 'Only Admins');
select test.eq('...an Admin may', app.notify_staff(test.id('ta_admin'), 'notify_channel_set', jsonb_build_object('investor_id', test.id('investor:ta_ivy'), 'channel', 'text')) ->> 'chosen', 'text');
select test.throws('...a renter may not', format($$select app.notify_staff(%L, 'notify_reach', jsonb_build_object('renter_id', %L))$$, test.id('ta_eve'), test.id('renter:ta_tess')), 'Staff only');
select test.eq('the door: staff read and change through admin_read / ops_do', (app.door(test.id('ta_cs'), 'aal2', 'ops_do', 'notify_channel_set', jsonb_build_object('owner_id', test.id('owner:ta_otto'), 'channel', 'text')) ->> 'channel')
  || ' ' || (app.door(test.id('ta_admin'), 'aal2', 'admin_read', 'notify_reach', jsonb_build_object('owner_id', test.id('owner:ta_otto'))) ->> 'chosen'), 'text text');

-- ================================================================ 9. Settings, Site health
select test.eq('Settings > Text alerts: templates, the generic count, people', (select format('%s %s %s', jsonb_array_length(x -> 'templates') >= 40, (x ->> 'generic')::int = 0, x -> 'people' ? 'both')
  from (select app.door(test.id('ta_admin'), 'aal2', 'admin_read', 'sms_settings') x) y), 't t t');
select test.eq('an Admin edits a text', app.door(test.id('ta_admin'), 'aal2', 'admin_do', 'sms_template_save', jsonb_build_object('code', 'renter_offer_ready', 'body', 'CarmaCars: offer ready for {{vehicle_name}}: {{link}}', 'urgent', false)) ->> 'body',
  'CarmaCars: offer ready for {{vehicle_name}}: {{link}}');
select test.throws('...a bad text is refused', format($$select app.sms_template_save(%L, '{"code": "renter_offer_ready", "body": "Offer ready"}')$$, test.id('ta_admin')), '320 characters');
select test.throws('...customer service cannot', format($$select app.door(%L, 'aal2', 'admin_do', 'sms_template_save', '{"code": "renter_offer_ready", "body": "CarmaCars {{link}}"}')$$, test.id('ta_cs')), null);
select test.ok('Site health: texts a day for 7 days, the waiting count', (select jsonb_array_length(x -> 'sms' -> 'days') = 7 and x -> 'sms' ? 'waiting_quiet' from (select app.site_health(test.id('ta_admin')) x) y));
select test.ok('...today counts the sent texts', (select ((app.sms_volume(1) -> 'days' -> 0 ->> 'sent')::int) >= 0));

-- ================================================================ 10. privileges and the privacy policy
select test.eq('only the server sets a channel or reads the reach; the tables are closed',
  has_function_privilege('anon', 'public.server_set_notify_channel(uuid, text)', 'execute')::text || has_function_privilege('authenticated', 'app.notify_reach(uuid, text, uuid)', 'execute')::text
  || has_table_privilege('authenticated', 'sms_templates', 'select')::text || has_table_privilege('anon', 'sms_opt_out_log', 'select')::text
  || has_function_privilege('service_role', 'public.server_my_notify_channel(uuid)', 'execute')::text, 'falsefalsefalsefalsetrue');
select test.eq('row-level security on the new tables', (select count(*) from pg_class where relname in ('sms_templates', 'sms_opt_out_log') and relrowsecurity), 2::bigint);
select test.ok('the privacy policy: texts if you choose text, STOP at any time',
  (select body like '%If you choose to get our messages by text, we text you service messages%reply STOP at any time%' from site_content_blocks where block_key = 'legal.privacy')
  or not exists (select 1 from site_content_blocks where block_key = 'legal.privacy' and body like '%we text a one-time sign-in code to the phone number you give%'));
update program_settings set sms_quiet_hours = true, sms_quiet_from_hour = 21, sms_quiet_until_hour = 8;
