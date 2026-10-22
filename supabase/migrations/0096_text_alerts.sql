-- 0096_text_alerts.sql
-- Text alerts: each person chooses how CarmaCars reaches them, Email, Text or Both (docs/changes/2026-10-22-text-alerts.md).
-- Builds on 0085 (the Quo line and its outbox) and 0091 (verified phones, the US gate).
--
--   1. The choice: users.notify_channel (and a record-level copy on renters, owners and investors for a person without
--      an account yet, such as a guest's booking request). Empty means the default: Both when the person has a verified
--      phone (Text for an account with a verified phone and no email), otherwise Email. Profiles, the booking request,
--      the phone sign-up and staff (Admin > the renter, owner or investor) set it.
--   2. Routing (a trigger on notification_outbox, so every way an email is queued is covered): for a renter, owner or
--      investor notification, the person's channel decides. Text: the email is skipped and a text is queued in
--      phone_outbox. Both: the email and a text. Email: the email only. Legal or long documents (signed agreements,
--      statements, receipts, invoices, notices) always go by email when there is an email address; a text-only person
--      also gets a text with a link to view or download it in their portal (behind sign-in). No verified phone, an
--      opted-out number, a US number while US texting waits for A2P 10DLC (signin_phone_us_allowed of 0091), or a
--      number outside Canada and the US: email only. A text that cannot go after all (STOP, a refusal, the choice
--      changed while it waited) sends the email it replaced.
--   3. A short text of its own for every customer notification (renter, owner, investor, additional driver, co-signer,
--      lead): sms_templates, editable in Admin > Settings > Text alerts, always with a link. The generic text from the
--      email's subject is only for a notification added later without a template. The sign-in emails (password reset,
--      sign-in link, security notice, the continue-your-request sign-in link) never become texts. A driver's or
--      co-signer's link is texted to that person (their own account and verified phone), never to the renter or owner.
--   4. Opt-outs: STOP (and the usual keywords) and START through the Quo webhook (0085's phone_threads.opted_out_at is
--      the opt-out list; this adds more keywords and a log). Quo sends no confirmation of its own, so CarmaCars texts one
--      right away (quiet hours do not apply), once per change, logged with the STOP or START: "you're unsubscribed" after
--      STOP, "texts are back on" after START. The first automated text to a number, and the first after a START, ends
--      "Reply STOP to opt out."
--   5. Quiet hours: no text that is not urgent from 9 pm to 8 am Toronto time; they wait in the outbox until 8 am.
--      Urgent: late return notices, same-day pickup and return details, breakdown, accident and vehicle disabled.
--   6. The US gate on every text from the outbox (missed-call texts and staff replies too).
--   7. Admin: Settings > Text alerts (defaults, quiet hours, templates), each person's channel on their page, and SMS
--      volume per day on Site health.
--   8. The privacy policy: one paragraph in section 10.
-- Replaces 0085's booking texts (the trigger notification_outbox_phone_sms and the program_settings phone_sms_* moments,
-- which stay as columns but are no longer read). No earlier migration is edited.
set local check_function_bodies = off;

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists sms_alerts_enabled boolean not null default true,
  add column if not exists sms_default_with_phone text not null default 'both' check (sms_default_with_phone in ('email', 'text', 'both')),
  add column if not exists sms_default_phone_only text not null default 'text' check (sms_default_phone_only in ('text', 'both')),
  add column if not exists sms_quiet_hours boolean not null default true,
  add column if not exists sms_quiet_from_hour integer not null default 21 check (sms_quiet_from_hour between 0 and 23),
  add column if not exists sms_quiet_until_hour integer not null default 8 check (sms_quiet_until_hour between 0 and 23),
  add column if not exists sms_stop_line boolean not null default true,
  add column if not exists sms_generic_text text not null default 'CarmaCars: {{subject}}. Details: {{link}}',
  add column if not exists sms_stop_confirm_text text not null default 'CarmaCars: you''re unsubscribed and won''t get more texts. Reply START to resubscribe.',
  add column if not exists sms_start_confirm_text text not null default 'CarmaCars: texts are back on. Reply STOP to opt out.';

comment on column program_settings.sms_alerts_enabled is 'Text alerts: send notifications by text to people who chose Text or Both and have a verified phone. Off: everyone gets email only.';
comment on column program_settings.sms_default_with_phone is 'Text alerts: the channel of a person with a verified phone and an email who has not chosen (both, text or email).';
comment on column program_settings.sms_default_phone_only is 'Text alerts: the channel of an account with a verified phone and no email (text or both; both acts as text until an email is added).';
comment on column program_settings.sms_quiet_hours is 'Text alerts: hold texts that are not urgent during the quiet hours below and send them when they end.';
comment on column program_settings.sms_quiet_from_hour is 'Text alerts: quiet hours start (Toronto hour, 21 is 9 pm).';
comment on column program_settings.sms_quiet_until_hour is 'Text alerts: quiet hours end (Toronto hour, 8 is 8 am).';
comment on column program_settings.sms_stop_line is 'Text alerts: add "Reply STOP to opt out." to the first text to a number (and the first after START).';
comment on column program_settings.sms_stop_confirm_text is 'Text alerts: the one text sent right after a STOP reply (Quo sends none of its own). Names CarmaCars and how to undo it (START).';
comment on column program_settings.sms_start_confirm_text is 'Text alerts: the one text sent right after a START reply. Names CarmaCars and how to stop (STOP).';
comment on column program_settings.sms_generic_text is 'Text alerts: the text of a notification without its own template. {{subject}} is the email''s subject, {{link}} the page.';

-- A text template: 1 to 320 characters (two texts), no long dashes, names CarmaCars, has the link.
create or replace function app.sms_template_ok(p text) returns boolean
language sql immutable as $$
  select p is not null and length(btrim(p)) between 1 and 320 and strpos(p, chr(8212)) = 0 and strpos(p, chr(8211)) = 0
     and strpos(p, 'CarmaCars') > 0 and strpos(p, '{{link}}') > 0
$$;
comment on function app.sms_template_ok(text) is 'A text alert template: 1 to 320 characters, no long dashes, names CarmaCars and has {{link}}.';
alter table program_settings drop constraint if exists program_settings_sms_generic_check;
alter table program_settings add constraint program_settings_sms_generic_check check (app.sms_template_ok(sms_generic_text) and strpos(sms_generic_text, '{{subject}}') > 0);
-- the STOP and START confirmations: 1 to 320 characters, no long dashes, name CarmaCars and the keyword that undoes them
alter table program_settings drop constraint if exists program_settings_sms_confirm_check;
alter table program_settings add constraint program_settings_sms_confirm_check check (
  length(btrim(sms_stop_confirm_text)) between 1 and 320 and strpos(sms_stop_confirm_text, chr(8212)) = 0 and strpos(sms_stop_confirm_text, chr(8211)) = 0
  and strpos(sms_stop_confirm_text, 'CarmaCars') > 0 and strpos(upper(sms_stop_confirm_text), 'START') > 0
  and length(btrim(sms_start_confirm_text)) between 1 and 320 and strpos(sms_start_confirm_text, chr(8212)) = 0 and strpos(sms_start_confirm_text, chr(8211)) = 0
  and strpos(sms_start_confirm_text, 'CarmaCars') > 0 and strpos(upper(sms_start_confirm_text), 'STOP') > 0);

-- ================================================================ 2. the choice
alter table users add column if not exists notify_channel text check (notify_channel in ('email', 'text', 'both'));
alter table users add column if not exists notify_channel_at timestamptz;
alter table users add column if not exists notify_channel_by uuid;
comment on column users.notify_channel is 'Since 0096: how the person wants notifications: email, text or both. Empty: the default (both with a verified phone, text for a phone-only account, otherwise email).';
alter table renters add column if not exists notify_channel text check (notify_channel in ('email', 'text', 'both'));
alter table owners add column if not exists notify_channel text check (notify_channel in ('email', 'text', 'both'));
alter table investors add column if not exists notify_channel text check (notify_channel in ('email', 'text', 'both'));
comment on column renters.notify_channel is 'Since 0096: the channel chosen for this record before it had an account (a guest''s booking request) or by staff. The account''s own choice wins.';
comment on column owners.notify_channel is 'Since 0096: the channel chosen for this record by staff while it has no account. The account''s own choice wins.';
comment on column investors.notify_channel is 'Since 0096: the channel chosen for this record by staff while it has no account. The account''s own choice wins.';

-- ================================================================ 3. which notifications, which texts
alter table notification_catalogue add column if not exists always_email boolean not null default false;
alter table notification_catalogue add column if not exists no_text boolean not null default false;
comment on column notification_catalogue.always_email is 'Since 0096: a legal or long document (signed agreements, statements, receipts, invoices, notices): emailed whenever there is an address, whatever the person chose.';
alter table notification_catalogue add column if not exists text_to_recipient boolean not null default false;
comment on column notification_catalogue.no_text is 'Since 0096: never a text (the sign-in and security emails: password reset, sign-in link, security notice, the continue-your-request sign-in link).';
comment on column notification_catalogue.text_to_recipient is 'Since 0096: sent to someone other than the record''s person (an additional driver, a co-signer): the text goes to the account of the address it is sent to, never to the renter or owner of the record.';

update notification_catalogue set always_email = true where code in (
  'renter_payment_receipt', 'renter_agreement_signed', 'renter_final_statement', 'renter_extra_charge', 'renter_refund_issued', 'renter_named_to_authority',
  'renter_damage_found', 'owner_statement_ready', 'owner_agreement_signed', 'owner_fee_invoice', 'owner_invoice_issued', 'owner_upfront_invoice',
  'owner_invoice_voided', 'owner_payment_recorded', 'owner_pad_confirmed', 'owner_debit_notice', 'owner_fee_change_notice', 'owner_vehicle_enrolled',
  'owner_exit_completed', 'owner_exit_notice_received', 'investor_statement_ready', 'investor_notice_received',
  -- the visitor typed an address to get the copy: it goes there whatever the channel, and the text says so
  'renter_chat_transcript');
update notification_catalogue set no_text = true where code in (
  'account_password_reset', 'account_sign_in_link', 'account_security_notice', 'renter_continue_request');
update notification_catalogue set text_to_recipient = true where code in ('renter_driver_link', 'owner_cosigner_sign');

create table if not exists sms_templates (
  code        text primary key references notification_catalogue (code) on update cascade on delete cascade,
  label       text not null,
  body        text not null check (app.sms_template_ok(body)),
  enabled     boolean not null default true,
  urgent      boolean not null default false,
  sort_order  integer not null default 100,
  updated_at  timestamptz not null default now(),
  updated_by  uuid references users (id) on delete set null
);
create trigger sms_templates_updated before update on sms_templates for each row execute function app.set_updated_at();
comment on table sms_templates is 'Text alerts (0096): the short text of a notification. Placeholders are the email''s {{variables}} and {{link}} (the page in the portal). Urgent texts ignore the quiet hours. A notification without a row here uses the generic text of Program settings.';

insert into sms_templates (code, label, body, urgent, sort_order) values
  ('renter_request_received', 'Booking received', 'CarmaCars: we have your request {{booking_number}} for the {{vehicle_name}}, {{pickup_date}}. Track it: {{link}}', false, 10),
  ('renter_offer_ready', 'Offer ready', 'CarmaCars: your offer for the {{vehicle_name}} is ready, {{total_amount}}. Review and accept: {{link}}', false, 20),
  ('renter_offer_reminder', 'Offer about to expire', 'CarmaCars: your offer for the {{vehicle_name}} expires {{offer_expires_at}}. Accept it here: {{link}}', false, 21),
  ('renter_booking_confirmed', 'Offer accepted, booking confirmed', 'CarmaCars: booking {{booking_number}} is confirmed. {{vehicle_name}}, pickup {{pickup_date}} at {{pickup_time}}. Details: {{link}}', false, 30),
  ('renter_rental_added', 'Rental booked by staff', 'CarmaCars: you are booked in the {{vehicle_name}}, {{pickup_date}}. Details and signing: {{link}}', false, 31),
  ('renter_recovery_pay', 'Payment link', 'CarmaCars: one step left to book the {{vehicle_name}}. Pay to confirm: {{link}}', false, 32),
  ('renter_payment_receipt', 'Payment received', 'CarmaCars: payment of {{amount}} received for booking {{booking_number}}. Receipt: {{link}}', false, 40),
  ('renter_payment_failed', 'Payment failed', 'CarmaCars: your payment of {{amount}} for booking {{booking_number}} did not go through. Pay here: {{link}}', false, 41),
  ('renter_balance_overdue', 'Balance overdue', 'CarmaCars: {{amount_due}} is overdue on booking {{booking_number}}. Pay here: {{link}}', false, 42),
  ('renter_deposit_declined', 'Deposit hold declined', 'CarmaCars: the deposit hold of {{deposit_amount}} for booking {{booking_number}} was declined. Fix it here: {{link}}', false, 43),
  ('renter_deposit_released', 'Deposit hold released', 'CarmaCars: the deposit hold for booking {{booking_number}} is released, {{release_amount}}. Details: {{link}}', false, 44),
  ('renter_booking_reminder', 'Pickup reminder', 'CarmaCars: pickup tomorrow at {{pickup_time}} for the {{vehicle_name}} ({{booking_number}}). What to bring: {{link}}', false, 50),
  ('renter_pickup_details', 'Pickup today', 'CarmaCars: pickup today at {{pickup_time}}, {{pickup_place}}. Details: {{link}}', true, 51),
  ('renter_return_reminder', 'Return reminder', 'CarmaCars: booking {{booking_number}} ends tomorrow at {{return_time}}. Return or extend: {{link}}', false, 52),
  ('renter_return_details', 'Return today', 'CarmaCars: return today at {{return_time}}, {{return_place}}. Details: {{link}}', true, 53),
  ('renter_extension_approved', 'Extension available', 'CarmaCars: your extension is available. Pay {{extension_amount}} by {{return_time}} to confirm: {{link}}', false, 60),
  ('renter_extension_confirmed', 'Extension confirmed', 'CarmaCars: extension confirmed. New return {{new_return_date}} at {{new_return_time}}. Details: {{link}}', false, 61),
  ('renter_extension_declined', 'Extension declined', 'CarmaCars: we cannot extend booking {{booking_number}}. Please return by {{return_time}}. Details: {{link}}', false, 62),
  ('renter_late_return_first', 'Late return', 'CarmaCars: booking {{booking_number}} ended at {{return_time}}. Please return the car now or extend: {{link}}', true, 63),
  ('renter_late_return_final', 'Late return, final notice', 'CarmaCars final notice: return the {{vehicle_name}} by {{final_deadline}}. Details: {{link}}', true, 64),
  ('renter_agreement_ready', 'Agreement to sign', 'CarmaCars: your rental agreement for booking {{booking_number}} is ready to sign: {{link}}', false, 70),
  ('renter_agreement_signed', 'Agreement signed', 'CarmaCars: your rental agreement for booking {{booking_number}} is signed. View or download it: {{link}}', false, 71),
  ('renter_identity_needed', 'Verification: documents needed', 'CarmaCars: upload your licence and proof of coverage for booking {{booking_number}} by {{verify_by}}: {{link}}', false, 80),
  ('renter_identity_rejected', 'Verification: resend a document', 'CarmaCars: please resend a document for booking {{booking_number}}: {{link}}', false, 81),
  ('renter_coverage_needed', 'Verification: coverage needed', 'CarmaCars: pickup in {{hours_left}} and we still need your proof of coverage: {{link}}', false, 82),
  ('renter_identity_approved', 'Verification: approved', 'CarmaCars: you are verified for booking {{booking_number}}. All set for {{pickup_date}}. {{link}}', false, 83),
  ('renter_final_statement', 'Final statement', 'CarmaCars: your final statement for booking {{booking_number}} is ready. View or download it: {{link}}', false, 90),
  ('renter_review_request', 'Review request', 'CarmaCars: how was the {{vehicle_name}}? Rate your rental: {{link}}', false, 91),
  ('renter_booking_cancelled', 'Booking cancelled', 'CarmaCars: booking {{booking_number}} is cancelled. Refund {{refund_amount}}. Details: {{link}}', false, 92),
  ('renter_staff_message', 'Message from staff', 'CarmaCars: you have a new message about booking {{booking_number}}. Read and reply: {{link}}', false, 93),
  ('owner_new_booking', 'Owner: car booked', 'CarmaCars: your {{vehicle_name}} is booked, {{pickup_date}} to {{return_date}}. Details: {{link}}', false, 200),
  ('owner_payout_sent', 'Owner: payout sent', 'CarmaCars: payout of {{payout_amount}} sent for {{statement_month}}. Details: {{link}}', false, 210),
  ('owner_statement_ready', 'Owner: statement ready', 'CarmaCars: your {{statement_month}} statement is ready, {{payout_amount}}. View or download it: {{link}}', false, 211),
  ('owner_fee_invoice', 'Owner: invoice due', 'CarmaCars: invoice {{invoice_number}} for {{invoice_total}} is due {{due_date}}. View it: {{link}}', false, 220),
  ('owner_invoice_issued', 'Owner: invoice issued', 'CarmaCars: invoice {{invoice_number}} for {{invoice_total}} is ready. View it: {{link}}', false, 221),
  ('owner_upfront_invoice', 'Owner: upfront invoice', 'CarmaCars: upfront invoice {{invoice_number}} for {{invoice_total}} is ready. View it: {{link}}', false, 222),
  ('owner_debit_notice', 'Owner: debit notice', 'CarmaCars: we will debit {{debit_total}} from your account on {{debit_date}}. Details: {{link}}', false, 223),
  ('owner_payment_failed', 'Owner: payment failed', 'CarmaCars: your {{amount}} payment for the {{vehicle_name}} failed. Details: {{link}}', false, 224),
  ('owner_agreement_ready', 'Owner: agreement to sign', 'CarmaCars: your owner documents for the {{vehicle_name}} are ready to sign: {{link}}', false, 230),
  ('owner_schedule_resign', 'Owner: schedule to sign', 'CarmaCars: please sign the updated Vehicle Schedule for the {{vehicle_name}}: {{link}}', false, 231),
  ('owner_agreement_signed', 'Owner: agreement signed', 'CarmaCars: your owner documents for the {{vehicle_name}} are signed. View or download them: {{link}}', false, 232),
  ('investor_statement_ready', 'Investor: statement ready', 'CarmaCars: your {{statement_month}} investor statement is ready. View or download it: {{link}}', false, 300),
  ('investor_return_paid', 'Investor: payment sent', 'CarmaCars: payment of {{return_amount}} sent for {{statement_month}}. Details: {{link}}', false, 301),
  ('person_document_to_sign', 'Document to sign', 'CarmaCars: a document is ready for you to sign: {{link}}', false, 310),
  ('renter_breakdown_help', 'Breakdown help', 'CarmaCars: help is on the way, about {{eta_minutes}} minutes. Details: {{link}}', true, 400),
  ('renter_accident_instructions', 'Accident instructions', 'CarmaCars: what to do now for booking {{booking_number}}: {{link}}', true, 401),
  ('renter_vehicle_disabled', 'Vehicle disabled', 'CarmaCars: your rental has ended and the {{vehicle_name}} will not restart. Details: {{link}}', true, 402),
  -- every other customer email has its own text too (renters, leads, drivers)
  ('renter_account_created', 'Account ready', 'CarmaCars: your account is ready. Find a car and book: {{link}}', false, 1),
  ('renter_request_needs_info', 'Request: one question', 'CarmaCars: one question before we can send your offer for booking {{booking_number}}. Answer it here: {{link}}', false, 11),
  ('renter_request_declined', 'Request declined', 'CarmaCars: we cannot fill your request for {{pickup_date}}. See other cars: {{link}}', false, 12),
  ('renter_recovery_request', 'Request not sent yet', 'CarmaCars: your request for the {{vehicle_name}} is not sent yet. Finish it here: {{link}}', false, 13),
  ('renter_recovery_offer', 'Offer waiting', 'CarmaCars: still thinking about the {{vehicle_name}}? Your offer is held until {{offer_expires_at}}: {{link}}', false, 22),
  ('renter_offer_expired', 'Offer expired', 'CarmaCars: your offer for the {{vehicle_name}} has expired. Ask for a new one: {{link}}', false, 23),
  ('renter_offer_withdrawn', 'Offer withdrawn', 'CarmaCars: we have withdrawn your offer for the {{vehicle_name}}, {{pickup_date}}. Details: {{link}}', false, 24),
  ('renter_refund_issued', 'Refund sent', 'CarmaCars: refund of {{refund_amount}} sent for booking {{booking_number}}. Details: {{link}}', false, 45),
  ('renter_extra_charge', 'Extra charge', 'CarmaCars: {{charge_type}} charge of {{charge_total}} on booking {{booking_number}}. Details: {{link}}', false, 46),
  ('renter_rental_started', 'Rental started', 'CarmaCars: your rental of the {{vehicle_name}} has started. Return by {{return_date}} at {{return_time}}. Condition report: {{link}}', false, 54),
  ('renter_return_complete', 'Returned', 'CarmaCars: the {{vehicle_name}} is returned. Thanks for renting with us. Condition report: {{link}}', false, 55),
  ('renter_extension_requested', 'Extension requested', 'CarmaCars: we have your request to extend booking {{booking_number}} and will reply soon. Details: {{link}}', false, 59),
  ('renter_change_request_received', 'Change requested', 'CarmaCars: we have your change request for booking {{booking_number}} and will reply soon. Track it: {{link}}', false, 65),
  ('renter_change_request_approved', 'Change approved', 'CarmaCars: your change to booking {{booking_number}} is approved. Accept it by {{accept_by}}: {{link}}', false, 66),
  ('renter_change_request_declined', 'Change declined', 'CarmaCars: we cannot make that change to booking {{booking_number}}. Your booking stays as it was. Details: {{link}}', false, 67),
  ('renter_change_proposed', 'Change suggested', 'CarmaCars: we suggest a change to booking {{booking_number}}. Review and answer by {{accept_by}}: {{link}}', false, 68),
  ('renter_change_proposal_reminder', 'Change: reminder', 'CarmaCars: please answer the change to booking {{booking_number}} by {{accept_by}}: {{link}}', false, 69),
  ('renter_recovery_change', 'Change: answer waiting', 'CarmaCars: we still need your answer to the change to booking {{booking_number}}, by {{accept_by}}: {{link}}', false, 72),
  ('renter_change_proposal_expired', 'Change: not accepted', 'CarmaCars: the change to booking {{booking_number}} was not accepted in time, so the booking stays as it was. Details: {{link}}', false, 73),
  ('renter_change_applied', 'Booking updated', 'CarmaCars: booking {{booking_number}} is updated. See the new details: {{link}}', false, 74),
  ('renter_driver_link', 'Additional driver: accept', 'CarmaCars: {{renter_name}} added you as a driver on booking {{booking_number}}. Accept the rental agreement before pickup: {{link}}', false, 75),
  ('renter_damage_found', 'Damage found', 'CarmaCars: we found damage on the {{vehicle_name}} after your return (booking {{booking_number}}). Details: {{link}}', false, 94),
  ('renter_named_to_authority', 'Named to the authority', 'CarmaCars: we gave your details to the issuing authority for {{notice_type_lower}} {{notice_number}} (booking {{booking_number}}). Details: {{link}}', false, 95),
  ('renter_booking_cancelled_by_us', 'Booking cancelled by us', 'CarmaCars: we are sorry, we had to cancel booking {{booking_number}}. Full refund of {{refund_amount}}. Find another car: {{link}}', false, 96),
  ('renter_google_review_request', 'Google review request', 'CarmaCars: thanks for renting the {{vehicle_name}}. Would you review us on Google? {{link}}', false, 97),
  ('renter_comeback_1w', 'Come back: 1 week', 'CarmaCars: thanks for renting with us. {{discount_percent}}% off your next rental with code {{discount_code}}, until {{discount_expires}}: {{link}}', false, 98),
  ('renter_comeback_1m', 'Come back: 1 month', 'CarmaCars: {{discount_percent}}% off your next rental with code {{discount_code}}, until {{discount_expires}}. Book: {{link}}', false, 99),
  ('renter_game_code', 'Game prize code', 'CarmaCars: your code {{discount_code}} for {{prize_label}}, valid until {{discount_expires}}. Use it here: {{link}}', false, 120),
  ('renter_game_code_reminder', 'Game code ends tomorrow', 'CarmaCars: your {{prize_label}} code {{discount_code}} ends tomorrow. Book now: {{link}}', false, 121),
  ('renter_chat_transcript', 'Chat copy emailed', 'CarmaCars: we emailed you a copy of your chat {{chat_number}}. See our cars: {{link}}', false, 122),
  -- owners and co-signers
  ('owner_account_created', 'Owner: account ready', 'CarmaCars: your owner account is ready. Sign in: {{link}}', false, 190),
  ('owner_application_received', 'Owner: application received', 'CarmaCars: we have your application for the {{vehicle_name}}. Track it: {{link}}', false, 191),
  ('owner_application_info_requested', 'Owner: application, more needed', 'CarmaCars: we need a little more for application {{application_number}}. See what to send: {{link}}', false, 192),
  ('owner_application_approved', 'Owner: application approved', 'CarmaCars: approved. Your {{vehicle_name}} can join CarmaCars. Next steps: {{link}}', false, 193),
  ('owner_application_declined', 'Owner: application declined', 'CarmaCars: we cannot enrol your {{vehicle_name}}. Details: {{link}}', false, 194),
  ('owner_onboarding_steps', 'Owner: next steps', 'CarmaCars: next steps to enrol your {{vehicle_name}}: {{link}}', false, 195),
  ('owner_registry_visit', 'Owner: registry visit', 'CarmaCars: registry visit booked for your {{vehicle_name}}, {{visit_date}} at {{visit_time}}. Details: {{link}}', false, 196),
  ('owner_car_set_up', 'Owner: car set up, review', 'CarmaCars: we set up your {{vehicle_name}}. Review the details and sign: {{link}}', false, 197),
  ('owner_vehicle_enrolled', 'Owner: on the fleet policy', 'CarmaCars: your {{vehicle_name}} is on the fleet policy. Written confirmation: {{link}}', false, 198),
  ('owner_vehicle_listed', 'Owner: car live', 'CarmaCars: your {{vehicle_name}} is live and open for bookings. See its calendar: {{link}}', false, 199),
  ('owner_booking_changed', 'Owner: booking changed', 'CarmaCars: booking {{booking_number}} of your car changed. Details: {{link}}', false, 201),
  ('owner_booking_confirmed', 'Owner: own booking confirmed', 'CarmaCars: confirmed, your own booking of the {{vehicle_name}}, {{pickup_date}} at {{pickup_time}}. Details: {{link}}', false, 202),
  ('owner_payment_received', 'Owner: payment received', 'CarmaCars: payment of {{amount}} received for invoice {{invoice_number}}. Details: {{link}}', false, 225),
  ('owner_payment_recorded', 'Owner: receipt', 'CarmaCars: receipt, {{amount}} received for invoice {{invoice_number}}. View it: {{link}}', false, 226),
  ('owner_payment_reversed', 'Owner: payment not received', 'CarmaCars: the payment for invoice {{invoice_number}} was not received. Balance {{balance}}. Details: {{link}}', false, 227),
  ('owner_invoice_voided', 'Owner: invoice cancelled', 'CarmaCars: invoice {{invoice_number}} is cancelled. Details: {{link}}', false, 228),
  ('owner_debit_setup_needed', 'Owner: set up bank debit', 'CarmaCars: set up your bank debit for {{debit_total}} due {{debit_date}}: {{link}}', false, 229),
  ('owner_pad_confirmed', 'Owner: debit agreement', 'CarmaCars: your pre-authorized debit agreement with {{payee_name}} is in place. View it: {{link}}', false, 233),
  ('owner_debit_returned', 'Owner: debit returned', 'CarmaCars: the debit for invoice {{invoice_number}} was returned by your bank. Balance {{balance}}. Pay or update: {{link}}', false, 234),
  ('owner_in_arrears', 'Owner: in arrears', 'CarmaCars: {{arrears_amount}} is owing on your {{vehicle_name}}. Please pay now: {{link}}', false, 235),
  ('owner_bank_details_changed', 'Owner: payment details changed', 'CarmaCars: the payment details on your owner account were changed. Not you? Call {{support_phone}}. Review: {{link}}', false, 236),
  ('owner_fee_change_notice', 'Owner: change to terms', 'CarmaCars: notice of a change to your terms for the {{vehicle_name}}, from {{effective_date}}. Read it: {{link}}', false, 237),
  ('owner_cosigner_sign', 'Co-signer: documents to sign', 'CarmaCars: {{owner_name}} added you as a co-signer. Please sign the owner documents: {{link}}', false, 238),
  ('owner_document_due', 'Owner: document due', 'CarmaCars: {{document_type}} for your {{vehicle_name}} is due {{due_date}}. Upload it: {{link}}', false, 240),
  ('owner_form_approved', 'Owner: form approved', 'CarmaCars: {{form_title}} is approved. Details: {{link}}', false, 241),
  ('owner_form_rejected', 'Owner: form to upload again', 'CarmaCars: please upload {{form_title}} again. See why: {{link}}', false, 242),
  ('owner_incident_opened', 'Owner: incident', 'CarmaCars: an incident involving your {{vehicle_name}} on {{incident_date}}. We are on it. Details: {{link}}', false, 250),
  ('owner_incident_update', 'Owner: incident update', 'CarmaCars: update on incident {{incident_number}}, {{incident_status}}. Details: {{link}}', false, 251),
  ('owner_toll_ticket', 'Owner: toll or ticket', 'CarmaCars: {{notice_type}} for your {{vehicle_name}}, {{notice_amount}}. Details: {{link}}', false, 252),
  ('owner_exit_notice_received', 'Owner: exit notice received', 'CarmaCars: we received your exit notice for the {{vehicle_name}}. Exit Date {{exit_date}}. Details: {{link}}', false, 260),
  ('owner_exit_completed', 'Owner: exit complete', 'CarmaCars: exit complete, your {{vehicle_name}} is back with you. Documents: {{link}}', false, 261),
  -- investors
  ('investor_notice_received', 'Investor: notice received', 'CarmaCars: we received your notice of {{notice_date}}. Details: {{link}}', false, 302)
on conflict (code) do nothing;
-- a template only for a code that exists in this database's catalogue (the foreign key) and is not a staff code
delete from sms_templates t where not exists (select 1 from notification_catalogue c where c.code = t.code);

-- 0085's six booking moments: a moment an Admin switched off stays off
update sms_templates t set enabled = false
  from (select (app.settings()).*) s
 where (t.code = 'renter_offer_ready' and not s.phone_sms_offer_sent) or (t.code = 'renter_booking_confirmed' and not s.phone_sms_payment_confirmed)
    or (t.code = 'renter_payment_receipt' and not s.phone_sms_payment_received) or (t.code = 'renter_booking_reminder' and not s.phone_sms_pickup_tomorrow)
    or (t.code = 'renter_return_reminder' and not s.phone_sms_return_reminder) or (t.code = 'renter_recovery_pay' and not s.phone_sms_payment_link);
update program_settings set sms_alerts_enabled = false where not phone_sms_booking;

-- Fills {{variables}} and {{link}}, then tidies: a value that was empty leaves no double space or space before a comma.
create or replace function app.sms_render(p_tpl text, p jsonb) returns text
language plpgsql immutable as $$
declare
  t text := replace(replace(app.render_text(coalesce(p_tpl, ''), coalesce(p, '{}'::jsonb)), chr(8212), ','), chr(8211), '-');
begin
  t := regexp_replace(t, '\(\s*\)', '', 'g');
  t := regexp_replace(t, '\s+', ' ', 'g');
  t := regexp_replace(t, '\s+([,.!?:)])', '\1', 'g');
  t := regexp_replace(t, ',\s*([,.])', '\1', 'g');
  return left(btrim(t), 1600);
end $$;

-- ================================================================ 4. reaching a person
-- How a person is reached: {chosen, default, channel (what is used now), email, phone (verified, E.164), country,
-- textable, why_not (no_verified_phone | opted_out | us_waiting | not_canada | off)}.
-- p_kind/p_record: the renter, owner or investor record (its own choice counts when the account has none).
create or replace function app.notify_reach(p_user uuid, p_kind text default null, p_record uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  u users;
  v_rec_choice text;
  v_rec_email text;
  v_phone text;
  v_country text;
  v_email text;
  v_why text;
  v_default text;
  v_want text;
  v_channel text;
  v_opted timestamptz;
begin
  if p_user is not null then select * into u from users where id = p_user; end if;
  if p_kind = 'renter' and p_record is not null then
    select r.notify_channel, nullif(btrim(r.email), '') into v_rec_choice, v_rec_email from renters r where r.id = p_record;
    if u.id is null then select x.* into u from users x join renters r on r.user_id = x.id where r.id = p_record; end if;
  elsif p_kind = 'owner' and p_record is not null then
    select o.notify_channel, nullif(btrim(o.email), '') into v_rec_choice, v_rec_email from owners o where o.id = p_record;
    if u.id is null then select x.* into u from users x join owners o on o.user_id = x.id where o.id = p_record; end if;
  elsif p_kind = 'investor' and p_record is not null then
    select i.notify_channel, nullif(btrim(i.email), '') into v_rec_choice, v_rec_email from investors i where i.id = p_record;
    if u.id is null then select x.* into u from users x join investors i on i.user_id = x.id where i.id = p_record; end if;
  elsif u.id is not null then
    select r.notify_channel into v_rec_choice from renters r where r.user_id = u.id order by r.created_at desc limit 1;
  end if;
  v_email := coalesce(nullif(btrim(u.email), ''), v_rec_email);
  v_phone := case when u.phone_verified_at is not null then app.phone_e164(u.phone) end;
  v_country := app.phone_country(v_phone);
  if v_phone is not null then
    select t.opted_out_at into v_opted from phone_threads t where t.number = v_phone;
    if v_opted is null and exists (select 1 from renters r where r.user_id = u.id and r.sms_opt_out_at is not null) then
      select max(r.sms_opt_out_at) into v_opted from renters r where r.user_id = u.id;
    end if;
  end if;
  v_why := case
    when not (s.phone_enabled and s.sms_alerts_enabled) then 'off'
    when v_phone is null then 'no_verified_phone'
    when v_opted is not null then 'opted_out'
    when v_country = 'US' and not s.signin_phone_us_allowed then 'us_waiting'
    when coalesce(v_country, 'other') not in ('CA', 'US') then 'not_canada' end;
  v_default := case when v_phone is null then 'email' when v_email is null then s.sms_default_phone_only else s.sms_default_with_phone end;
  v_want := coalesce(u.notify_channel, v_rec_choice, v_default);
  v_channel := case when v_why is not null then 'email'
                    when v_email is null then 'text'
                    else v_want end;
  return jsonb_build_object('user_id', u.id, 'chosen', coalesce(u.notify_channel, v_rec_choice), 'default', v_default, 'wanted', v_want, 'channel', v_channel,
    'email', v_email, 'phone', v_phone, 'country', v_country, 'textable', v_why is null, 'why_not', v_why, 'opted_out_at', v_opted,
    'chosen_at', u.notify_channel_at);
end $$;

-- The quiet hours of texts (21:00 to 8:00 Toronto by default): when a text that is not urgent may go.
create or replace function app.sms_quiet_end(p_now timestamptz default now()) returns timestamptz
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  h integer := app.local_hour(p_now);
  v_quiet boolean;
begin
  if not s.sms_quiet_hours or s.sms_quiet_from_hour = s.sms_quiet_until_hour then return p_now; end if;
  v_quiet := case when s.sms_quiet_from_hour > s.sms_quiet_until_hour then h >= s.sms_quiet_from_hour or h < s.sms_quiet_until_hour
                  else h >= s.sms_quiet_from_hour and h < s.sms_quiet_until_hour end;
  if not v_quiet then return p_now; end if;
  return app.local_midnight(app.local_date(p_now) + case when h >= s.sms_quiet_until_hour then 1 else 0 end) + make_interval(hours => s.sms_quiet_until_hour);
end $$;

-- ================================================================ 5. the outbox: texts of notifications, the US gate, STOP line
alter table phone_outbox drop constraint if exists phone_outbox_kind_check;
alter table phone_outbox add constraint phone_outbox_kind_check check (kind in ('missed_call', 'booking', 'staff', 'notify', 'opt_confirm'));
alter table phone_outbox add column if not exists user_id uuid references users (id) on delete set null;
alter table phone_outbox add column if not exists urgent boolean not null default false;
create index if not exists phone_outbox_created_idx on phone_outbox (created_at);
create index if not exists phone_outbox_notification_idx on phone_outbox (notification_id) where notification_id is not null;
alter table phone_threads add column if not exists opted_in_at timestamptz;

alter table notification_outbox add column if not exists channel text check (channel in ('email', 'text', 'both'));
alter table notification_outbox add column if not exists sms_planned boolean not null default false;
comment on column notification_outbox.channel is 'Since 0096: the channel of the person when this was queued (renters, owners and investors). Text: the email was skipped and a text went instead, unless the code is always emailed.';

-- A text to a number: queued (or ready to send now), or skipped with the reason (opted out, US texting not yet
-- registered, switched off). 0085's function with the US gate and the notification texts.
create or replace function app.phone_outbox_put(p_number text, p_body text, p_kind text, p_booking uuid default null, p_renter uuid default null,
  p_sms_kind text default null, p_notification uuid default null, p_dedupe text default null, p_send_after timestamptz default now(),
  p_status text default 'queued', p_by uuid default null) returns phone_outbox
language plpgsql security definer set search_path = public, app as $$
declare
  t phone_threads := app.phone_thread_for(p_number);
  s program_settings := app.settings();
  o phone_outbox;
  v_skip text;
begin
  if p_dedupe is not null then
    select * into o from phone_outbox where dedupe_key = p_dedupe;
    if o.id is not null then return o; end if;
  end if;
  if t.opted_out_at is not null then v_skip := 'The number opted out of texts';
  elsif p_kind in ('booking', 'notify') and p_renter is not null and exists (select 1 from renters r where r.id = p_renter and r.sms_opt_out_at is not null) then v_skip := 'The renter asked for no texts';
  elsif not s.phone_enabled then v_skip := 'Phone and texts are off in Program settings';
  elsif app.phone_country(t.number) = 'US' and not s.signin_phone_us_allowed then v_skip := 'US texts wait for A2P 10DLC registration (Program settings, Sign-in by phone: also US numbers)';
  end if;
  insert into phone_outbox (thread_id, to_number, body, kind, sms_kind, notification_id, booking_id, renter_id, status, status_reason, send_after, sent_by, dedupe_key,
                            locked_at)
  values (t.id, t.number, left(p_body, 1600), p_kind, p_sms_kind, p_notification, p_booking, p_renter, case when v_skip is null then p_status else 'skipped' end, v_skip,
          coalesce(p_send_after, now()), p_by, p_dedupe, case when v_skip is null and p_status = 'sending' then now() end)
  returning * into o;
  return o;
end $$;

-- Is this the first automated text to the number (ever, or since its last START)?
create or replace function app.sms_first_to(p_number text) returns boolean
language sql stable security definer set search_path = public, app as $$
  select not exists (select 1 from phone_outbox o join phone_threads t on t.id = o.thread_id
                      where t.number = app.phone_e164(p_number) and o.kind in ('booking', 'notify') and o.status in ('queued', 'sending', 'sent')
                        and o.created_at > coalesce(t.opted_in_at, '-infinity'::timestamptz))
$$;

-- The booking's own values, for a text whose email did not carry them (the email's values win).
create or replace function app.sms_booking_vars(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce((select jsonb_build_object('booking_number', b.booking_number, 'vehicle_name', app.vehicle_name(b.vehicle_id),
           'pickup_date', app.fmt_date(b.pickup_at), 'pickup_time', app.fmt_time(b.pickup_at), 'return_date', app.fmt_date(b.return_at),
           'return_time', app.fmt_time(b.return_at), 'first_name', split_part(btrim(coalesce(r.legal_name, '')), ' ', 1))
      from bookings b left join renters r on r.id = b.renter_id where b.id = p_booking), '{}'::jsonb)
$$;

-- The text of a notification row: its template (or the generic one) with the email's values and the page's link.
create or replace function app.sms_text_for(p_code text, p_payload jsonb, p_audience text, p_booking uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  c notification_catalogue;
  t sms_templates;
  v_link text;
  v_tpl text;
begin
  select * into c from notification_catalogue where code = p_code;
  if c.code is null or c.no_text then return null; end if;
  p_payload := app.sms_booking_vars(p_booking) || coalesce((select jsonb_object_agg(e.key, e.value) from jsonb_each(coalesce(p_payload, '{}'::jsonb)) e
                                                      where jsonb_typeof(e.value) <> 'null' and e.value <> '""'::jsonb), '{}'::jsonb);
  select * into t from sms_templates where code = p_code;
  if t.code is not null and not t.enabled then return null; end if;
  -- the email's page; for an email without one, its own link (a driver's signing link, the Google review page, the car
  -- of an unsent request), else the person's portal
  v_link := coalesce(app.notification_url(c, p_payload), nullif(p_payload ->> 'sign_url', ''), nullif(p_payload ->> 'google_review_url', ''),
    nullif(p_payload ->> 'car_url', ''),
    rtrim(coalesce(s.notify_base_url, 'https://carmacars.ca'), '/') || case p_audience when 'owner' then '/owner' when 'investor' then '/investor' else '/account' end);
  v_tpl := coalesce(t.body, s.sms_generic_text);
  return jsonb_build_object('body', app.sms_render(v_tpl, coalesce(p_payload, '{}'::jsonb) || jsonb_build_object('link', v_link,
             'subject', rtrim(app.render_text(c.subject, coalesce(p_payload, '{}'::jsonb)), '.'))),
           'urgent', coalesce(t.urgent, false), 'own', t.code is not null);
end $$;

-- ================================================================ 6. routing (before and after a notification is queued)
-- Whose channel and phone count for a notification row: {user_id, kind, record}. The record's person (renter or owner),
-- or, for an email to someone else (an additional driver, a co-signer), the account of the address it goes to, with no
-- record (the renter's or owner's choice and phone never apply to it).
create or replace function app.notify_who(p_row notification_outbox) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_user uuid := p_row.recipient_user_id;
begin
  if (select c.text_to_recipient from notification_catalogue c where c.code = p_row.code) then
    if v_user is null and nullif(btrim(coalesce(p_row.to_address, '')), '') is not null then
      select u.id into v_user from users u where lower(u.email) = lower(btrim(p_row.to_address)) order by u.created_at limit 1;
    end if;
    return jsonb_build_object('user_id', v_user, 'kind', null, 'record', null);
  end if;
  if v_user is null and p_row.audience = 'renter' and p_row.renter_id is not null then select user_id into v_user from renters where id = p_row.renter_id; end if;
  if v_user is null and p_row.audience = 'owner' and p_row.owner_id is not null then select user_id into v_user from owners where id = p_row.owner_id; end if;
  return jsonb_build_object('user_id', v_user,
    'kind', case when p_row.audience = 'renter' and p_row.renter_id is not null then 'renter' when p_row.audience = 'owner' and p_row.owner_id is not null then 'owner' end,
    'record', case p_row.audience when 'renter' then p_row.renter_id when 'owner' then p_row.owner_id end);
end $$;

create or replace function app.notify_route() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  c notification_catalogue;
  w jsonb;
  v_user uuid;
  r jsonb;
  v_ch text;
  v_text jsonb;
  v_email_ok boolean;
begin
  if new.audience not in ('renter', 'owner', 'investor') then return new; end if;
  select * into c from notification_catalogue where code = new.code;
  w := app.notify_who(new);
  v_user := (w ->> 'user_id')::uuid;
  r := app.notify_reach(v_user, w ->> 'kind', (w ->> 'record')::uuid);
  v_ch := r ->> 'channel';
  new.channel := v_ch;
  if v_ch = 'email' or not (r ->> 'textable')::boolean or c.no_text then return new; end if;
  -- the email would go, or could not go only for want of an address (or a suppressed one): the text follows the
  -- same consent and preferences
  if not (new.status = 'queued' or new.status = 'suppressed' or (new.status = 'skipped' and new.status_reason = 'no email address')) then return new; end if;
  if new.category = 'marketing' and not app.has_marketing_consent(v_user, coalesce(c.consent_rule, 'express')) then return new; end if;
  v_text := app.sms_text_for(new.code, new.payload, new.audience, new.booking_id);
  if v_text is null then return new; end if;
  new.sms_planned := true;
  v_email_ok := new.status = 'queued';
  -- Text only: the email is skipped, unless it is a document that always goes by email
  if v_ch = 'text' and v_email_ok and not c.always_email then
    new.status := 'skipped';
    new.status_reason := 'Sent by text (the person chose text)';
  end if;
  return new;
end $$;

create or replace function app.notify_route_text() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  w jsonb;
  r jsonb;
  v_text jsonb;
  v_body text;
  v_after timestamptz;
  o phone_outbox;
begin
  if not new.sms_planned then return new; end if;
  w := app.notify_who(new);
  r := app.notify_reach((w ->> 'user_id')::uuid, w ->> 'kind', (w ->> 'record')::uuid);
  v_text := app.sms_text_for(new.code, new.payload, new.audience, new.booking_id);
  if v_text is null or r ->> 'phone' is null then return new; end if;
  v_body := v_text ->> 'body';
  if s.sms_stop_line and app.sms_first_to(r ->> 'phone') then v_body := v_body || ' Reply STOP to opt out.'; end if;
  v_after := case when (v_text ->> 'urgent')::boolean then new.send_after else greatest(new.send_after, app.sms_quiet_end(now())) end;
  o := app.phone_outbox_put(r ->> 'phone', v_body, 'notify', new.booking_id, case when w ->> 'kind' = 'renter' then new.renter_id end, new.code, new.id,
         'sms:' || new.dedupe_key, v_after);
  update phone_outbox set user_id = (r ->> 'user_id')::uuid, urgent = (v_text ->> 'urgent')::boolean where id = o.id and user_id is null;
  -- the text could not be queued after all: the email it replaced goes
  if o.status = 'skipped' and new.status = 'skipped' and new.status_reason like 'Sent by text%' and nullif(btrim(coalesce(new.to_address, '')), '') is not null then
    update notification_outbox set status = 'queued', status_reason = 'By email: ' || coalesce(o.status_reason, 'the text could not be sent'), send_after = now() where id = new.id;
  end if;
  return new;
end $$;

drop trigger if exists notification_outbox_phone_sms on notification_outbox;
drop trigger if exists notification_outbox_route on notification_outbox;
drop trigger if exists notification_outbox_route_text on notification_outbox;
create trigger notification_outbox_route before insert on notification_outbox for each row execute function app.notify_route();
create trigger notification_outbox_route_text after insert on notification_outbox for each row execute function app.notify_route_text();

-- A text that ends up not sent (STOP while it waited, a refusal, the choice changed): the email it replaced goes.
create or replace function app.sms_fallback_email() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.kind = 'notify' and new.notification_id is not null and new.status in ('skipped', 'failed') and old.status not in ('skipped', 'failed') then
    update notification_outbox set status = 'queued', status_reason = 'By email: the text was not sent (' || coalesce(new.status_reason, new.last_error, new.status) || ')', send_after = now()
     where id = new.notification_id and status = 'skipped' and status_reason like 'Sent by text%' and nullif(btrim(coalesce(to_address, '')), '') is not null;
  end if;
  return new;
end $$;
drop trigger if exists phone_outbox_fallback on phone_outbox;
create trigger phone_outbox_fallback after update of status on phone_outbox for each row execute function app.sms_fallback_email();

-- The five-minute job: before texts are claimed, a waiting notification text is checked again (the person may have
-- chosen email, replied STOP, or the number may now be gated).
alter function app.server_phone_due(integer) rename to server_phone_due_pre0096;
create or replace function app.server_phone_due(p_limit integer default 20) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o record;
  r jsonb;
begin
  -- a STOP or START confirmation is sent once: one that never reported back is not tried again (0085 would retry it)
  update phone_outbox set status = 'failed', locked_at = null, status_reason = 'No answer from Quo; a confirmation is sent once'
   where kind = 'opt_confirm' and status = 'sending' and locked_at < now() - interval '10 minutes';
  for o in select x.id, x.user_id, x.renter_id from phone_outbox x where x.status = 'queued' and x.kind = 'notify' and x.send_after <= now() and x.user_id is not null
           order by x.send_after limit greatest(p_limit, 1) * 3 for update skip locked loop
    r := app.notify_reach(o.user_id, case when o.renter_id is not null then 'renter' end, o.renter_id);
    if not (r ->> 'textable')::boolean or r ->> 'channel' = 'email' then
      update phone_outbox set status = 'skipped', status_reason = case when (r ->> 'textable')::boolean then 'The person now gets email only'
                                                                       else 'Texts not possible now: ' || coalesce(r ->> 'why_not', '') end
       where id = o.id;
    end if;
  end loop;
  return app.server_phone_due_pre0096(p_limit);
end $$;

-- ================================================================ 7. STOP and START: more keywords, the log, the confirmation
create table if not exists sms_opt_out_log (
  id         bigserial primary key,
  number     text not null,
  action     text not null check (action in ('stop', 'start')),
  source     text,
  at         timestamptz not null default now(),
  confirm_id uuid references phone_outbox (id) on delete set null
);
create index if not exists sms_opt_out_log_number_idx on sms_opt_out_log (number, at desc);
comment on table sms_opt_out_log is 'Text alerts (0096): every STOP and START of a number (the reply, a carrier error or staff), for the record, with the confirmation text sent for a reply (confirm_id, a phone_outbox row of kind opt_confirm). The current list is phone_threads.opted_out_at.';

-- When texts start again (the first automated text after it carries the STOP line again).
create or replace function app.sms_opt_in_at() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.opted_out_at is null and old.opted_out_at is not null then new.opted_in_at := now(); end if;
  return new;
end $$;
drop trigger if exists phone_threads_opt_log on phone_threads;
drop trigger if exists phone_threads_opt_in_at on phone_threads;
create trigger phone_threads_opt_in_at before update of opted_out_at on phone_threads for each row execute function app.sms_opt_in_at();

-- Each change is logged once. A change made by a reply (STOP or START texted to us, read by the Quo webhook, which
-- sets app.sms_reply for its transaction) is confirmed by one text, sent at once by the webhook (quiet hours do not
-- apply: the person just texted us). Quo sends no confirmation of its own. A carrier error or a staff change gets no
-- text. The US gate and "Phone and texts" off still hold (the row is then skipped with the reason, and logged).
create or replace function app.sms_opt_log() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_action text;
  v_log bigint;
  v_reply boolean := coalesce(current_setting('app.sms_reply', true), '') = 'on';
  v_skip text;
  v_id uuid;
begin
  if new.opted_out_at is not null and old.opted_out_at is null then v_action := 'stop';
  elsif new.opted_out_at is null and old.opted_out_at is not null then v_action := 'start';
  else return new; end if;
  insert into sms_opt_out_log (number, action, source)
  values (new.number, v_action, case when v_action = 'stop' then new.opt_out_source when v_reply then 'start' else 'staff' end)
  returning id into v_log;
  if not v_reply or (v_action = 'stop' and new.opt_out_source is distinct from 'stop') then return new; end if;
  if not s.phone_enabled then v_skip := 'Phone and texts are off in Program settings';
  elsif app.phone_country(new.number) = 'US' and not s.signin_phone_us_allowed then v_skip := 'US texts wait for A2P 10DLC registration (Program settings, Sign-in by phone: also US numbers)';
  end if;
  insert into phone_outbox (thread_id, to_number, body, kind, sms_kind, renter_id, status, status_reason, send_after, dedupe_key, locked_at, urgent)
  values (new.id, new.number, case v_action when 'stop' then s.sms_stop_confirm_text else s.sms_start_confirm_text end, 'opt_confirm', 'opt_' || v_action, new.renter_id,
          case when v_skip is null then 'sending' else 'skipped' end, v_skip, now(), 'optconfirm:' || v_log, case when v_skip is null then now() end, true)
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  update sms_opt_out_log set confirm_id = v_id where id = v_log;
  return new;
end $$;
create trigger phone_threads_opt_log after update of opted_out_at on phone_threads for each row execute function app.sms_opt_log();

-- The webhook: a reply's STOP or START is confirmed in the same delivery (the text is returned with the missed-call
-- text, if any, and sent at once).
alter function app.server_phone_event(jsonb) rename to server_phone_event_pre0096;
create or replace function app.server_phone_event(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb;
  v_conf jsonb;
begin
  perform set_config('app.sms_reply', 'on', true);
  r := app.server_phone_event_pre0096(p);
  perform set_config('app.sms_reply', '', true);
  if r ->> 'thread_id' is null then return r; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'to', o.to_number, 'body', o.body) order by o.created_at), '[]'::jsonb) into v_conf
    from phone_outbox o where o.thread_id = (r ->> 'thread_id')::uuid and o.kind = 'opt_confirm' and o.status = 'sending' and o.locked_at = now();
  if jsonb_array_length(v_conf) = 0 then return r; end if;
  return r || jsonb_build_object('send', coalesce(r -> 'send', '[]'::jsonb) || v_conf);
end $$;

-- The keywords carriers also honour that 0085 does not read (STOP and START themselves stay with 0085).
create or replace function app.sms_keywords() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  w text := regexp_replace(btrim(upper(coalesce(new.body, ''))), '[^A-Z ]', '', 'g');
begin
  if new.kind <> 'text' or new.direction <> 'in' then return new; end if;
  if w ~ '^(STOP ALL|OPT OUT|OPTOUT|REVOKE|UNSUBSCRIBE ALL|STOP PLEASE|PLEASE STOP)$' then
    update phone_threads set opted_out_at = coalesce(opted_out_at, now()), opt_out_source = coalesce(opt_out_source, 'stop') where id = new.thread_id;
    update renters set sms_opt_out_at = coalesce(sms_opt_out_at, now()) where id = (select renter_id from phone_threads where id = new.thread_id);
    update phone_outbox set status = 'skipped', status_reason = 'The number opted out of texts' where thread_id = new.thread_id and status = 'queued';
  elsif w ~ '^(OPT IN|OPTIN|RESUME|START ALL)$' then
    update phone_threads set opted_out_at = null, opt_out_source = null where id = new.thread_id and opted_out_at is not null and opt_out_source = 'stop';
    update renters set sms_opt_out_at = null where id = (select renter_id from phone_threads where id = new.thread_id);
  end if;
  return new;
end $$;
drop trigger if exists phone_activity_keywords on phone_activity;
create trigger phone_activity_keywords after insert or update of body on phone_activity for each row execute function app.sms_keywords();

-- ================================================================ 8. setting the choice
-- The person's own card: their reach, the options and what to say.
create or replace function app.my_notify_channel(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.notify_reach(p_user) || jsonb_build_object('our_number', app.phone_display(app.phone_our_number()),
           'quiet_from', s.sms_quiet_from_hour, 'quiet_until', s.sms_quiet_until_hour, 'quiet', s.sms_quiet_hours, 'enabled', s.phone_enabled and s.sms_alerts_enabled)
    from (select (app.settings()).*) s
$$;

create or replace function app.set_notify_channel(p_user uuid, p_channel text, p_by uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v text := nullif(btrim(lower(coalesce(p_channel, ''))), '');
  b jsonb;
begin
  if v is not null and v not in ('email', 'text', 'both') then raise exception 'Choose Email, Text or Both' using errcode = '22023'; end if;
  select jsonb_build_object('notify_channel', notify_channel) into b from users where id = p_user;
  if b is null then raise exception 'Account not found' using errcode = 'P0002'; end if;
  update users set notify_channel = v, notify_channel_at = now(), notify_channel_by = coalesce(p_by, p_user) where id = p_user;
  if p_by is not null and p_by <> p_user then
    insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
    values (p_by, 'notify_channel_set', 'users', p_user, b, jsonb_build_object('notify_channel', v));
  end if;
  return app.my_notify_channel(p_user);
end $$;

-- The booking request: the choice made in the form, on the renter record (and the account when the person is signed in).
create or replace function app.request_notify_channel(p_booking_number text, p_channel text, p_user uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v text := nullif(btrim(lower(coalesce(p_channel, ''))), '');
  r renters;
begin
  if v is null then return jsonb_build_object('ok', true, 'changed', false); end if;
  if v not in ('email', 'text', 'both') then raise exception 'Choose Email, Text or Both' using errcode = '22023'; end if;
  select x.* into r from renters x join bookings b on b.renter_id = x.id where b.booking_number = p_booking_number;
  if r.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  -- a visitor may set the record of their own fresh request only; a signed-in person their own record
  if p_user is not null and r.user_id is distinct from p_user then return jsonb_build_object('ok', false, 'error', 'not_yours'); end if;
  if p_user is null and not exists (select 1 from bookings b where b.booking_number = p_booking_number and b.created_at > now() - interval '30 minutes') then
    return jsonb_build_object('ok', false, 'error', 'too_late');
  end if;
  update renters set notify_channel = v where id = r.id;
  if p_user is not null then update users set notify_channel = v, notify_channel_at = now(), notify_channel_by = p_user where id = p_user; end if;
  return jsonb_build_object('ok', true, 'changed', true, 'reach', app.notify_reach(r.user_id, 'renter', r.id));
end $$;

-- Staff: a person's channel (renter, owner, investor, or an account), and changing it. Admins and every active
-- assistant may see and change a renter's or owner's; an investor's only Admins.
create or replace function app.notify_staff(p_by uuid, p_action text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_kind text;
  v_rec uuid;
  v_user uuid := nullif(p ->> 'user_id', '')::uuid;
  v text := nullif(btrim(lower(coalesce(p ->> 'channel', ''))), '');
  b jsonb;
  r jsonb;
begin
  if not (app.user_is_admin(p_by) or app.user_is_staff(p_by)) then raise exception 'Staff only' using errcode = '42501'; end if;
  if p ? 'renter_id' then v_kind := 'renter'; v_rec := (p ->> 'renter_id')::uuid; select user_id into v_user from renters where id = v_rec;
  elsif p ? 'owner_id' then v_kind := 'owner'; v_rec := (p ->> 'owner_id')::uuid; select user_id into v_user from owners where id = v_rec;
  elsif p ? 'investor_id' then v_kind := 'investor'; v_rec := (p ->> 'investor_id')::uuid; select user_id into v_user from investors where id = v_rec;
  end if;
  if v_kind = 'investor' and not app.user_is_admin(p_by) then raise exception 'Only Admins change an investor''s details' using errcode = '42501'; end if;
  if v_kind is null and v_user is null then raise exception 'Say whose channel' using errcode = '22023'; end if;
  if p_action = 'notify_channel_set' then
    if v is not null and v not in ('email', 'text', 'both') then raise exception 'Choose Email, Text or Both' using errcode = '22023'; end if;
    b := jsonb_build_object('user', (select notify_channel from users where id = v_user),
           'record', case v_kind when 'renter' then (select notify_channel from renters where id = v_rec) when 'owner' then (select notify_channel from owners where id = v_rec)
                                 when 'investor' then (select notify_channel from investors where id = v_rec) end);
    if v_user is not null then update users set notify_channel = v, notify_channel_at = now(), notify_channel_by = p_by where id = v_user; end if;
    if v_kind = 'renter' then update renters set notify_channel = v where id = v_rec;
    elsif v_kind = 'owner' then update owners set notify_channel = v where id = v_rec;
    elsif v_kind = 'investor' then update investors set notify_channel = v where id = v_rec; end if;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
    values (p_by, 'notify_channel_set', coalesce(v_kind || 's', 'users'), coalesce(v_rec, v_user), b, jsonb_build_object('notify_channel', v));
  end if;
  r := app.notify_reach(v_user, v_kind, v_rec);
  return r || jsonb_build_object('log', coalesce((select jsonb_agg(jsonb_build_object('action', l.action, 'source', l.source, 'at', l.at,
                                                   'confirmation', (select o.status from phone_outbox o where o.id = l.confirm_id)) order by l.at desc)
                                                   from (select * from sms_opt_out_log where number = r ->> 'phone' order by at desc limit 5) l), '[]'::jsonb),
    'texts_30d', (select count(*) from phone_outbox o where o.user_id = v_user and o.kind = 'notify' and o.status = 'sent' and o.created_at > now() - interval '30 days'));
end $$;

-- ================================================================ 9. Admin: Settings > Text alerts, Site health
create or replace function app.sms_settings(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'templates', coalesce((select jsonb_agg(jsonb_build_object('code', t.code, 'label', t.label, 'body', t.body, 'enabled', t.enabled, 'urgent', t.urgent,
                    'always_email', c.always_email, 'audience', c.audience, 'subject', c.subject) order by t.sort_order, t.code)
                    from sms_templates t join notification_catalogue c on c.code = t.code), '[]'::jsonb),
    'generic', (select count(*) from notification_catalogue c where c.audience in ('renter', 'owner', 'investor') and c.is_enabled and c.in_catalogue and not c.no_text
                  and not exists (select 1 from sms_templates t where t.code = c.code)),
    'always_email', coalesce((select jsonb_agg(c.code order by c.code) from notification_catalogue c where c.always_email), '[]'::jsonb),
    'people', (select jsonb_build_object('text', count(*) filter (where notify_channel = 'text'), 'both', count(*) filter (where notify_channel = 'both'),
                  'email', count(*) filter (where notify_channel = 'email'), 'verified_phones', count(*) filter (where phone_verified_at is not null)) from users),
    'opted_out', (select count(*) from phone_threads where opted_out_at is not null),
    'us_allowed', (app.settings()).signin_phone_us_allowed)
$$;

create or replace function app.sms_template_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  t sms_templates;
  v_body text := btrim(coalesce(p ->> 'body', ''));
begin
  perform app.assert_admin(p_by);
  select * into t from sms_templates where code = p ->> 'code' for update;
  if t.code is null then raise exception 'No text for that notification' using errcode = 'P0002'; end if;
  if v_body = '' then v_body := t.body; end if;
  if not app.sms_template_ok(v_body) then
    raise exception 'A text is 1 to 320 characters, names CarmaCars, has {{link}} and no long dashes' using errcode = '23514';
  end if;
  update sms_templates set body = v_body, enabled = coalesce((p ->> 'enabled')::boolean, enabled), urgent = coalesce((p ->> 'urgent')::boolean, urgent), updated_by = p_by
   where code = t.code returning * into t;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'sms_template_save', 'sms_templates', null, jsonb_build_object('code', p ->> 'code'), to_jsonb(t));
  return to_jsonb(t);
end $$;

-- SMS volume per day (Toronto days, the last 7): notification texts, booking texts, staff replies, missed-call texts
-- and sign-in codes, by result; the texts waiting for the quiet hours to end.
create or replace function app.sms_volume(p_days integer default 7) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with days as (select (app.local_date(now()) - g) as day from generate_series(0, greatest(p_days, 1) - 1) g),
  o as (select app.local_date(coalesce(o.sent_at, o.created_at)) as day, o.status, o.kind from phone_outbox o
         where coalesce(o.sent_at, o.created_at) >= app.local_midnight(app.local_date(now()) - greatest(p_days, 1) + 1)),
  c as (select app.local_date(l.created_at) as day, l.status from app.auth_sms_log l where l.created_at >= app.local_midnight(app.local_date(now()) - greatest(p_days, 1) + 1))
  select jsonb_build_object(
    'days', coalesce((select jsonb_agg(jsonb_build_object('day', d.day,
              'sent', (select count(*) from o where o.day = d.day and o.status = 'sent'),
              'alerts', (select count(*) from o where o.day = d.day and o.status = 'sent' and o.kind in ('notify', 'booking')),
              'failed', (select count(*) from o where o.day = d.day and o.status = 'failed'),
              'skipped', (select count(*) from o where o.day = d.day and o.status = 'skipped'),
              'codes', (select count(*) from c where c.day = d.day and c.status = 'sent')) order by d.day desc) from days d), '[]'::jsonb),
    'waiting_quiet', (select count(*) from phone_outbox where status = 'queued' and send_after > now()),
    'queued_due', (select count(*) from phone_outbox where status = 'queued' and send_after <= now()),
    'opted_out', (select count(*) from phone_threads where opted_out_at is not null),
    'quiet_from', (app.settings()).sms_quiet_from_hour, 'quiet_until', (app.settings()).sms_quiet_until_hour)
$$;

alter function app.site_health(uuid) rename to site_health_pre0096;
create or replace function app.site_health(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  return app.site_health_pre0096(p_by) || jsonb_build_object('sms', app.sms_volume(7));
end $$;

-- ================================================================ 10. the doors
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0096;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
begin
  if (p_call in ('admin_read', 'ops_read', 'va_read') and p_name = 'notify_reach')
     or (p_call in ('admin_do', 'ops_do', 'va_do') and p_name = 'notify_channel_set') then
    if p_ ? '_va' then perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.notify_staff(p_user, p_name, p_ - '_va');
  end if;
  if p_call = 'admin_read' and p_name = 'sms_settings' then
    perform app.door_begin(p_user, p_aal);
    perform app.assert_admin(p_user);
    return app.sms_settings(p_user);
  end if;
  if p_call = 'admin_do' and p_name = 'sms_template_save' then
    perform app.door_begin(p_user, p_aal);
    return app.sms_template_save(p_user, p_);
  end if;
  return app.door_pre0096(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ 11. the privacy policy (the live legal.privacy block, where it still has our text)
update site_content_blocks
   set body = replace(body, 'If you sign in or verify your phone number with us, we text a one-time sign-in code to the phone number you give.',
     'If you sign in or verify your phone number with us, we text a one-time sign-in code to the phone number you give.

If you choose to get our messages by text, we text you service messages about your bookings, account, payments and documents from our phone number, instead of or as well as email. Legal documents, statements and receipts are still emailed when we have your email address. You can reply STOP at any time to stop texts, and START to turn them back on; we then reach you by email. Message and data rates may apply.')
 where block_key = 'legal.privacy' and body like '%we text a one-time sign-in code to the phone number you give.%'
   and body not like '%If you choose to get our messages by text%';

-- ================================================================ 12. server wrappers and privileges
create or replace function public.server_my_notify_channel(p_user uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.my_notify_channel(p_user) $$;
create or replace function public.server_set_notify_channel(p_user uuid, p_channel text) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.set_notify_channel(p_user, p_channel, null) $$;
create or replace function public.server_request_notify_channel(p_booking_number text, p_channel text, p_user uuid default null) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.request_notify_channel(p_booking_number, p_channel, p_user) $$;

alter table sms_templates enable row level security;
alter table sms_opt_out_log enable row level security;
drop policy if exists admin_all on sms_templates;
create policy admin_all on sms_templates for all to authenticated using (app.is_admin()) with check (app.is_admin());
drop policy if exists admin_all on sms_opt_out_log;
create policy admin_all on sms_opt_out_log for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on sms_templates, sms_opt_out_log from anon, authenticated;
revoke all on sequence sms_opt_out_log_id_seq from anon, authenticated;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['notify_reach', 'sms_quiet_end', 'sms_first_to', 'sms_text_for', 'sms_booking_vars', 'notify_route', 'notify_route_text',
              'sms_fallback_email', 'server_phone_due', 'server_phone_due_pre0096', 'sms_opt_log', 'sms_opt_in_at', 'sms_keywords', 'notify_who',
              'server_phone_event', 'server_phone_event_pre0096', 'my_notify_channel', 'set_notify_channel',
              'request_notify_channel', 'notify_staff', 'sms_settings', 'sms_template_save', 'sms_volume', 'site_health', 'site_health_pre0096', 'phone_outbox_put']))
        or (n.nspname = 'public' and p.proname = any (array['server_my_notify_channel', 'server_set_notify_channel', 'server_request_notify_channel']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
-- pure helpers, no data
grant execute on function app.sms_template_ok(text), app.sms_render(text, jsonb) to anon, authenticated, service_role;

-- the renamed door keeps its privileges; the new one gets the same
do $$
declare
  g text;
begin
  revoke all on function app.door(uuid, text, text, text, jsonb) from public, anon, authenticated;
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.door_pre0096(uuid, text, text, text, jsonb)'::regprocedure, 'execute') then
      execute format('grant execute on function app.door(uuid, text, text, text, jsonb) to %I', g);
    end if;
  end loop;
end $$;
