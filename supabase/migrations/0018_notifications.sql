-- 0018_notifications.sql
-- The notification layer: from business events (app_events, migration 0017) to emails, staff
-- digests and in-app notices. Read with docs/changes/0018_notifications.md and
-- docs/blueprint/12-notifications.md.
--
-- This migration runs after 0017 and before 0019 to 0022, so it uses only objects of 0001 to 0017.
-- Everything that reads or watches the tables of 0019 to 0022 (the full merge payloads, the
-- triggers that emit events, the time-based jobs and the digests) is in 0023_notification_wiring.sql.
--
-- How it works
--   1. A function or trigger calls app.emit_event(code, entity, id, payload, dedupe_key) (0017).
--   2. app.process_events() (pg_cron, every minute) reads each unprocessed event, looks up its
--      catalogue row (the email code), finds the recipients by audience, and for each one writes
--        an outbox row (an email to send), or
--        a staff digest item (a staff notice with digest true, collected for the role's digest), and
--        an in-app notice for anyone with an account.
--      Suppression, preferences, consent and the merge payload are decided here.
--   3. The Edge Function send-outbox (service role) claims a batch with app.outbox_claim(), which
--      applies the daily cap by priority, renders each email with emails/src/engine.mjs, sends it,
--      and reports back with app.outbox_mark_sent() or app.outbox_mark_failed().
--   4. The provider's webhook reports bounces and complaints (app.outbox_record_bounce()); the
--      one-click unsubscribe link calls app.unsubscribe().
--
-- Every amount, time and limit is a program_settings column (an admin edits it). Dedupe keys
-- follow code:entity_id:discriminator; an outbox key adds the recipient after a '|'.

-- ================================================================ 1. settings (admin editable)
alter table program_settings
  add column notify_daily_cap                integer   not null default 100  check (notify_daily_cap > 0),
  add column notify_monthly_cap              integer   not null default 3000 check (notify_monthly_cap > 0),
  -- the day's count under which each priority class may still send (1 customer transactional,
  -- 2 owner and investor, 3 immediate staff, 4 digests and scheduled summaries, 5 marketing)
  add column notify_class_limits             integer[] not null default array[100, 100, 95, 95, 60]
                                             check (cardinality(notify_class_limits) = 5),
  add column notify_marketing_daily_max      integer   not null default 15 check (notify_marketing_daily_max >= 0),
  add column notify_marketing_from           time      not null default '10:00',
  add column notify_marketing_until          time      not null default '16:00',
  add column notify_max_attempts             integer   not null default 3 check (notify_max_attempts between 1 and 20),
  add column notify_backoff_minutes          integer[] not null default array[1, 5, 30],
  add column notify_sending_lock_minutes     integer   not null default 10 check (notify_sending_lock_minutes > 0),
  add column notify_event_batch              integer   not null default 500 check (notify_event_batch > 0),
  add column notify_base_url                 text      not null default 'https://carmacars.ca'
                                             check (notify_base_url ~ '^https://[^/]+$'),
  add column notify_unsubscribe_path         text      not null default '/email/unsubscribe',
  add column notify_digest_morning           time      not null default '07:30',
  add column notify_digest_eod               time      not null default '18:15',
  add column notify_field_today              time      not null default '07:00',
  add column notify_field_tomorrow           time      not null default '18:00',
  add column notify_weekly_dow               smallint  not null default 1 check (notify_weekly_dow between 1 and 7),
  add column notify_weekly_time              time      not null default '07:45',
  add column notify_booking_reminder_hours   integer   not null default 24 check (notify_booking_reminder_hours > 0),
  add column notify_pickup_details_hours     integer   not null default 3 check (notify_pickup_details_hours > 0),
  add column notify_return_reminder_hours    integer   not null default 24 check (notify_return_reminder_hours > 0),
  add column notify_offer_reminder_hours     integer   not null default 6 check (notify_offer_reminder_hours > 0),
  add column notify_offer_halfway_below_hours integer  not null default 12 check (notify_offer_halfway_below_hours > 0),
  add column notify_identity_chase_hours     integer   not null default 48 check (notify_identity_chase_hours > 0),
  add column notify_agreement_unsigned_minutes integer not null default 60 check (notify_agreement_unsigned_minutes > 0),
  add column notify_request_waiting_minutes  integer   not null default 120 check (notify_request_waiting_minutes > 0),
  add column notify_late_staff_minutes       integer[] not null default array[0, 30],
  add column notify_late_final_deadline_minutes integer not null default 60 check (notify_late_final_deadline_minutes > 0),
  add column notify_review_request_days      integer   not null default 2 check (notify_review_request_days >= 0),
  add column notify_comeback_1w_days         integer   not null default 7 check (notify_comeback_1w_days > 0),
  add column notify_comeback_1m_days         integer   not null default 30 check (notify_comeback_1m_days > 0),
  add column notify_comeback_1w_bps          integer   not null default 1000 check (notify_comeback_1w_bps between 1 and 10000),
  add column notify_comeback_1m_bps          integer   not null default 1500 check (notify_comeback_1m_bps between 1 and 10000),
  add column notify_comeback_valid_days      integer   not null default 30 check (notify_comeback_valid_days > 0),
  add column notify_followup_time            time      not null default '10:00',
  add column notify_balance_overdue_days     integer   not null default 7 check (notify_balance_overdue_days >= 0),
  add column notify_insurer_due_days         integer   not null default 30 check (notify_insurer_due_days > 0),
  add column notify_insurer_repeat_days      integer   not null default 7 check (notify_insurer_repeat_days > 0),
  add column notify_insurer_admin_days       integer   not null default 60 check (notify_insurer_admin_days > 0),
  add column notify_daily_checks_time        time      not null default '06:00',
  add column notify_statements_reminder_day  smallint  not null default 8 check (notify_statements_reminder_day between 1 and 28),
  add column notify_statements_reminder_time time      not null default '09:00',
  add column notify_payouts_due_time         time      not null default '08:00',
  add column notify_cancellation_admin_cents bigint    not null default 50000 check (notify_cancellation_admin_cents >= 0),
  add column notify_review_alert_max_rating  smallint  not null default 2 check (notify_review_alert_max_rating between 0 and 5),
  add column notify_offer_paid_immediate_hours integer not null default 24 check (notify_offer_paid_immediate_hours >= 0),
  add column notify_payment_failed_alert_hours integer not null default 24 check (notify_payment_failed_alert_hours >= 0),
  add column notify_digest_waiting_hours     integer   not null default 2 check (notify_digest_waiting_hours > 0);

-- ================================================================ 2. formatting (Toronto time, dollars)
create or replace function app.fmt_money(p_cents numeric) returns text
language sql immutable as $$
  select case when p_cents is null then null
              else case when p_cents < 0 then '-' else '' end || '$' || to_char(abs(p_cents) / 100.0, 'FM999,999,990.00') end
$$;
create or replace function app.fmt_date(p_at timestamptz) returns text
language sql immutable as $$ select to_char(p_at at time zone 'America/Toronto', 'Dy, Mon FMDD, YYYY') $$;
create or replace function app.fmt_day(p_on date) returns text
language sql immutable as $$ select to_char(p_on, 'Dy, Mon FMDD, YYYY') $$;
create or replace function app.fmt_time(p_at timestamptz) returns text
language sql immutable as $$ select to_char(p_at at time zone 'America/Toronto', 'FMHH12:MI am') $$;
-- 'Wed, Oct 21 at 2:15 pm' (no year), as the templates show deadlines.
create or replace function app.fmt_at(p_at timestamptz) returns text
language sql immutable as $$ select to_char(p_at at time zone 'America/Toronto', 'Dy, Mon FMDD') || ' at ' || app.fmt_time(p_at) $$;
-- 'Tue, Oct 20, 2026 at 9:14 am'
create or replace function app.fmt_datetime(p_at timestamptz) returns text
language sql immutable as $$ select app.fmt_date(p_at) || ' at ' || app.fmt_time(p_at) $$;
create or replace function app.fmt_km(p_km numeric) returns text
language sql immutable as $$ select case when p_km is null then null else to_char(p_km, 'FM999,999,990') || ' km' end $$;
create or replace function app.fmt_pct(p_bps integer) returns text
language sql immutable as $$ select case when p_bps is null then null
  when p_bps % 100 = 0 then (p_bps / 100)::text || '%' else to_char(p_bps / 100.0, 'FM990.0#') || '%' end $$;

-- Fill {{name}} from a jsonb object (subjects, preheaders and link paths only; they have no sections).
create or replace function app.render_text(p_template text, p_vars jsonb) returns text
language plpgsql immutable as $$
declare
  v text := p_template;
  k text;
begin
  if v is null then return null; end if;
  for k in select regexp_matches[1] from regexp_matches(v, '\{\{\s*([a-z0-9_]+)\s*\}\}', 'g') as regexp_matches loop
    v := regexp_replace(v, '\{\{\s*' || k || '\s*\}\}',
                        replace(coalesce(case jsonb_typeof(p_vars -> k) when 'string' then p_vars ->> k
                                                                    when 'null' then '' else p_vars ->> k end, ''), '\', '\\'), 'g');
  end loop;
  return v;
end $$;

-- ================================================================ 3. the catalogue
create table notification_link_paths (
  key  text primary key check (key ~ '^[a-z0-9_]+$'),
  path text not null check (path like '/%')
);
comment on table notification_link_paths is 'The paths of emails/src/links.mjs. Generated by supabase/seed/0018_gen_catalogue.mjs.';

create table notification_catalogue (
  code              text primary key check (code ~ '^[a-z][a-z0-9_]*$'),
  audience          text not null,
  also_sent_to      text[] not null default '{}',
  category          text not null check (category in ('transactional', 'marketing')),
  is_digest         boolean not null default false,
  digest_slot       text check (digest_slot in ('next', 'morning')),
  from_address      text,
  reply_to          text,
  subject           text not null,
  preheader         text,
  timing            text,
  trigger_text      text,
  replaces_template text,
  link_path         text,             -- the template's main link (a path, may hold {{variables}})
  variables         jsonb not null default '[]'::jsonb,
  template_html     text,
  template_text     text,
  has_email         boolean not null default true,    -- false: an in-app notice only
  in_catalogue      boolean not null default true,    -- false: left emails/catalogue.json (kept for old rows)
  -- worked out by app.notification_catalogue_refresh(); an admin may change them afterwards
  priority          smallint not null default 1 check (priority between 1 and 5),
  consent_rule      text check (consent_rule in ('express', 'implied')),
  user_can_mute     boolean not null default false,
  sender_supplied   text[] not null default '{}',     -- variables the Edge Function adds (signed links, sign-in links)
  is_enabled        boolean not null default true,
  emitted_by        text,                             -- documentation: what emits the code
  updated_at        timestamptz not null default now()
);
comment on table notification_catalogue is 'One row per email code (emails/catalogue.json) plus in-app-only codes. Rows come from the generator; is_enabled, priority and user_can_mute are an admin''s to change.';

-- The variables only the sender can produce: signed file links (valid 7 days), sign-in service
-- links, and the details of a sign-in service event. Everything else is built in the database.
create or replace function app.notification_catalogue_refresh() returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  n integer;
begin
  update notification_catalogue c
     set priority = case when c.category = 'marketing' then 5
                         when c.code like 'staff_digest_%' or c.code like 'staff_field_jobs_%' or c.code = 'staff_weekly_summary' then 4
                         when c.audience like 'staff_%' then 3
                         when c.audience in ('owner', 'investor') then 2
                         else 1 end,
         consent_rule = case when c.code in ('renter_comeback_1w', 'renter_comeback_1m') then 'express'
                             when c.category = 'marketing' then 'implied' end,
         user_can_mute = c.category = 'marketing' or c.code like 'staff_digest_%' or c.code = 'staff_weekly_summary',
         sender_supplied = coalesce((select array_agg(v ->> 'name' order by v ->> 'name')
                                       from jsonb_array_elements(c.variables) v
                                      where v ->> 'name' in ('verify_url', 'reset_url', 'sign_in_url', 'link_expiry',
                                                             'signed_agreement_url', 'receipt_url', 'statement_url',
                                                             'supporting_document_url', 'security_device', 'security_event',
                                                             'security_event_at', 'security_place')), '{}'),
         updated_at = now()
   where c.has_email;
  get diagnostics n = row_count;
  -- messages.template_code must point at a message_templates row (0006)
  insert into message_templates (code, purpose, audience, version)
  select c.code, left(c.subject, 200),
         case when c.audience like 'staff_%' then 'internal' when c.audience in ('owner', 'investor') then 'owner' else 'renter' end, 1
    from notification_catalogue c
  on conflict (code) do nothing;
  return n;
end $$;

-- In-app-only codes (no email, so they spend nothing from the daily cap).
insert into notification_catalogue (code, audience, category, subject, preheader, has_email, priority, emitted_by, link_path)
values ('staff_email_cap_reached', 'staff_admin', 'transactional', 'Email limit reached for today',
        '{{held_count}} emails are held until after midnight. Safety and booking emails go first.', false, 3,
        'app.outbox_claim (0018)', '/admin');

-- CATALOGUE START (generated by supabase/seed/0018_gen_catalogue.mjs; do not edit by hand)
-- Source: emails/catalogue.json (123 emails), emails/src/links.mjs (59 paths).
insert into notification_link_paths (key, path) values
  ('home', '/'),
  ('cars', '/cars'),
  ('terms', '/terms'),
  ('privacy', '/privacy'),
  ('cancellation_policy', '/terms#cancellation'),
  ('booking', '/account/bookings/{{booking_number}}'),
  ('booking_offer', '/account/bookings/{{booking_number}}/offer'),
  ('booking_request', '/account/bookings/{{booking_number}}/request'),
  ('booking_agreement', '/account/bookings/{{booking_number}}/agreement'),
  ('booking_verify', '/account/bookings/{{booking_number}}/verify'),
  ('booking_pickup', '/account/bookings/{{booking_number}}/pickup'),
  ('booking_condition_report', '/account/bookings/{{booking_number}}/condition-report'),
  ('booking_return', '/account/bookings/{{booking_number}}/return'),
  ('booking_extend', '/account/bookings/{{booking_number}}/extend'),
  ('booking_change', '/account/bookings/{{booking_number}}/change'),
  ('booking_statement', '/account/bookings/{{booking_number}}/statement'),
  ('booking_pay', '/account/bookings/{{booking_number}}/pay'),
  ('booking_incident', '/account/bookings/{{booking_number}}/incident'),
  ('booking_review', '/account/bookings/{{booking_number}}/review'),
  ('owner', '/owner'),
  ('owner_application', '/owner/application'),
  ('owner_agreements', '/owner/agreements'),
  ('owner_billing', '/owner/billing'),
  ('owner_documents', '/owner/documents'),
  ('owner_vehicle', '/owner/vehicles/{{vehicle_id}}'),
  ('owner_vehicle_onboarding', '/owner/vehicles/{{vehicle_id}}/onboarding'),
  ('owner_vehicle_calendar', '/owner/vehicles/{{vehicle_id}}/calendar'),
  ('owner_vehicle_exit', '/owner/vehicles/{{vehicle_id}}/exit'),
  ('owner_booking', '/owner/bookings/{{booking_number}}'),
  ('owner_invoice', '/owner/invoices/{{invoice_number}}'),
  ('owner_statement', '/owner/statements/{{statement_number}}'),
  ('owner_claim', '/owner/claims/{{incident_number}}'),
  ('admin', '/admin'),
  ('admin_approvals', '/admin/approvals'),
  ('admin_statements', '/admin/statements'),
  ('admin_payouts', '/admin/payouts'),
  ('admin_dispute', '/admin/disputes/{{dispute_id}}'),
  ('admin_incident', '/admin/incidents/{{incident_number}}'),
  ('admin_fleet', '/admin/fleet'),
  ('admin_jobs', '/admin/jobs'),
  ('admin_weekly', '/admin/reports/weekly'),
  ('va_cs', '/va/cs'),
  ('va_cs_booking', '/va/cs/bookings/{{booking_number}}'),
  ('va_cs_identity', '/va/cs/bookings/{{booking_number}}/identity'),
  ('va_cs_reviews', '/va/cs/reviews'),
  ('va_finance', '/va/finance'),
  ('va_finance_booking', '/va/finance/bookings/{{booking_number}}'),
  ('va_finance_toll', '/va/finance/tolls-tickets/{{toll_ticket_id}}'),
  ('va_finance_invoice', '/va/finance/owner-invoices/{{invoice_number}}'),
  ('va_finance_insurer_invoice', '/va/finance/insurer-invoices/{{invoice_number}}'),
  ('va_fleet', '/va/fleet'),
  ('va_fleet_booking', '/va/fleet/bookings/{{booking_number}}'),
  ('va_fleet_listing', '/va/fleet/listings/{{vehicle_id}}'),
  ('va_fleet_expiries', '/va/fleet/expiries'),
  ('va_fleet_vehicle', '/va/fleet/vehicles/{{vehicle_id}}'),
  ('va_sales', '/va/sales'),
  ('va_sales_application', '/va/sales/applications/{{application_id}}'),
  ('field', '/field'),
  ('field_job', '/field/jobs/{{job_id}}')
on conflict (key) do update set path = excluded.path;

insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('account_password_reset', 'renter', array['owner', 'investor', 'staff_admin', 'staff_va_finance', 'staff_va_fleet', 'staff_va_cs', 'staff_va_sales', 'staff_field']::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Reset your CarmaCars password', 'The link works once and expires in {{link_expiry}}.', 'Immediate', 'A password reset is requested for any account (the sign-in service recovery event). One template for every account type.', null, null, '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"instagram_url","type":"url","global":true},{"name":"link_expiry","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"reset_url","type":"url"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/account_password_reset.html', 'templates/account_password_reset.txt'),
  ('account_security_notice', 'renter', array['owner', 'investor', 'staff_admin', 'staff_va_finance', 'staff_va_fleet', 'staff_va_cs', 'staff_va_sales', 'staff_field']::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'privacy@carmacars.ca', 'Security notice: {{security_event}} on your CarmaCars account', '{{security_event_at}}. If this was you, there is nothing to do.', 'Immediate', 'A security event on any account: a sign-in from a device or browser not seen before on that account, a password change, or a change of the account email address. One template for every account type. For an email change it is sent to both the old and the new address. Never batched.', null, null, '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"link_expiry","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"reset_url","type":"url"},{"name":"security_device","type":"string"},{"name":"security_event","type":"string"},{"name":"security_event_at","type":"string"},{"name":"security_place","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/account_security_notice.html', 'templates/account_security_notice.txt'),
  ('account_sign_in_link', 'renter', array['owner', 'investor', 'staff_admin', 'staff_va_finance', 'staff_va_fleet', 'staff_va_cs', 'staff_va_sales', 'staff_field']::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Your CarmaCars sign-in link', 'Tap to sign in. The link works once and expires in {{link_expiry}}.', 'Immediate', 'A one-time sign-in link is requested for any account (the sign-in service magic link event). Also used as the invitation when an admin creates an owner, investor or staff account.', null, null, '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"instagram_url","type":"url","global":true},{"name":"link_expiry","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"sign_in_url","type":"url"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/account_sign_in_link.html', 'templates/account_sign_in_link.txt'),
  ('renter_accident_instructions', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'What to do now, booking {{booking_number}}', 'If anyone is hurt call 911. Then follow these steps. Report due by {{report_due}}.', 'Immediate', 'An incident of type accident, theft or vandalism is opened on an on_rent booking (Fleet logs the renter''s call). (Message template T16.)', 'T16', '/account/bookings/{{booking_number}}/incident', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"incident_number","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"report_due","type":"string"},{"name":"roadside_phone","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_accident_instructions.html', 'templates/renter_accident_instructions.txt'),
  ('renter_account_created', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Confirm your email to finish your CarmaCars account', 'One tap confirms your email. The link works for {{link_expiry}}.', 'Immediate', 'A user with the renter role is created (sign-up form, or the account made with a first booking request) and the email address is not yet verified.', null, null, '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"link_expiry","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"verify_url","type":"url"}]'::jsonb, 'templates/renter_account_created.html', 'templates/renter_account_created.txt'),
  ('renter_agreement_ready', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Sign your rental agreement for booking {{booking_number}}', 'Sign on the website by {{sign_by}}. It takes about two minutes.', 'Immediate', 'A signature request is opened for a signer who is not in the middle of checkout: each additional driver on the booking, or the renter when the agreement is reissued (accepted change, extension or renewal) or left unsigned for 1 hour while the booking is pending_payment (offer approved, signing and payment in progress).', null, '/account/bookings/{{booking_number}}/agreement', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"pickup_date","type":"string"},{"name":"pickup_time","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_time","type":"string"},{"name":"sign_by","type":"string"},{"name":"signer_role","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_agreement_ready.html', 'templates/renter_agreement_ready.txt'),
  ('renter_agreement_signed', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Your signed rental agreement, booking {{booking_number}}', 'Keep this copy. It sets the terms of your rental.', 'Immediate', 'A rental agreement signature request is completed (every signer has signed and CarmaCars has countersigned). Sent to the renter and to each additional driver who signed.', null, '/account/bookings/{{booking_number}}', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"signed_agreement_url","type":"url"},{"name":"signed_at","type":"string"},{"name":"signers","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_agreement_signed.html', 'templates/renter_agreement_signed.txt'),
  ('renter_balance_overdue', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Overdue: {{amount_due}} on booking {{booking_number}}', 'Interest of {{interest_rate}} a month now applies. Pay today to stop it.', '7 days after the statement, then monthly on the 1st', 'Daily check: a renter statement was sent 7 days ago and a balance on it is still unpaid (all card retries failed or are pending). Sent once at 7 days, then with each monthly interest posting on the 1st while a balance remains.', null, '/account/bookings/{{booking_number}}/pay', '[{"name":"amount_due","type":"string"},{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"interest_rate","type":"string"},{"name":"interest_to_date","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"statement_date","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_balance_overdue.html', 'templates/renter_balance_overdue.txt'),
  ('renter_booking_cancelled', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Booking {{booking_number}} is cancelled. Refund {{refund_amount}}', 'Received {{cancellation_received_at}}. {{refund_percent}} of {{amount_paid}} is refunded.', 'Immediate', 'Booking status changes from confirmed to cancelled or no_show with a booking cancellation row where cancelled_by is renter (the database computes the tier, percent and refund). (Message template T12.)', 'T12', '/terms#cancellation', '[{"name":"amount_paid","type":"string"},{"name":"booking_number","type":"string"},{"name":"cancellation_received_at","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"has_refund","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"pickup_date","type":"string"},{"name":"pickup_time","type":"string"},{"name":"refund_amount","type":"string"},{"name":"refund_percent","type":"string"},{"name":"refund_tier","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_booking_cancelled.html', 'templates/renter_booking_cancelled.txt'),
  ('renter_booking_cancelled_by_us', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'We have had to cancel booking {{booking_number}}. Full refund', '{{refund_amount}} is going back to your card. We are sorry.', 'Immediate', 'Booking status changes from confirmed to cancelled with a booking cancellation row where the cancelling party is CarmaCars (no car or accepted substitute), or where the reason is that a driver could not be verified. The refund is 100%, including non-refundable bookings.', null, '/cars', '[{"name":"booking_number","type":"string"},{"name":"cancel_reason","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"pickup_date","type":"string"},{"name":"refund_amount","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_booking_cancelled_by_us.html', 'templates/renter_booking_cancelled_by_us.txt'),
  ('renter_booking_confirmed', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Confirmed: {{vehicle_name}}, {{pickup_date}}', 'Booking {{booking_number}}. {{amount_paid}} paid. Next: licence and coverage check.', 'Immediate', 'Booking status changes from pending_payment to confirmed (the offer was approved, the agreement signed, the booking total paid and the car still free for the dates).', null, '/account/bookings/{{booking_number}}/verify', '[{"name":"amount_paid","type":"string"},{"name":"booking_number","type":"string"},{"name":"card_brand","type":"string"},{"name":"card_last4","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"deposit_amount","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"is_non_refundable","type":"boolean"},{"name":"km_allowance","type":"string"},{"name":"line_items","type":"list","fields":["label","amount"]},{"name":"needs_verification","type":"boolean"},{"name":"opening_hours","type":"string","global":true},{"name":"overage_rate","type":"string"},{"name":"pickup_date","type":"string"},{"name":"pickup_place","type":"string"},{"name":"pickup_time","type":"string"},{"name":"receipt_number","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_place","type":"string"},{"name":"return_time","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_image_url","type":"url"},{"name":"vehicle_name","type":"string"},{"name":"verify_by","type":"string"}]'::jsonb, 'templates/renter_booking_confirmed.html', 'templates/renter_booking_confirmed.txt'),
  ('renter_booking_reminder', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Tomorrow: your {{vehicle_name}} at {{pickup_time}}', 'Bring your original licence and the card ending {{card_last4}}.', '24 hours before pickup', 'Hourly reminders job: booking status is confirmed and the pickup time is 24 hours away. Sent once. (Message template T5.)', 'T5', '/account/bookings/{{booking_number}}/verify', '[{"name":"booking_number","type":"string"},{"name":"card_last4","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"deposit_amount","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"missing_items","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"pickup_date","type":"string"},{"name":"pickup_place","type":"string"},{"name":"pickup_time","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"},{"name":"verification_pending","type":"boolean"}]'::jsonb, 'templates/renter_booking_reminder.html', 'templates/renter_booking_reminder.txt'),
  ('renter_breakdown_help', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Help is on the way, about {{eta_minutes}} minutes', 'Stay somewhere safe. Call {{roadside_phone}} if anything changes.', 'Immediate', 'An incident of type breakdown on an on_rent booking has roadside dispatched (dispatched_at is set by Fleet). (Message template T18.)', 'T18', '/account/bookings/{{booking_number}}', '[{"name":"booking_number","type":"string"},{"name":"breakdown_location","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"eta_minutes","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"roadside_phone","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_breakdown_help.html', 'templates/renter_breakdown_help.txt'),
  ('renter_change_request_approved', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Your change to booking {{booking_number}} is ready to accept', 'Review the new details and accept by {{accept_by}}.', 'Immediate', 'Staff approve a change request on a confirmed booking. Sent when the change request status becomes approved. (A change to a booking that is still offered is sent as a revised offer with renter_offer_ready instead.)', null, '/account/bookings/{{booking_number}}/change', '[{"name":"accept_by","type":"string"},{"name":"approved_changes","type":"list","fields":["label","before","after"]},{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"difference_amount","type":"string"},{"name":"difference_label","type":"string"},{"name":"first_name","type":"string"},{"name":"has_difference","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"total_amount","type":"string"}]'::jsonb, 'templates/renter_change_request_approved.html', 'templates/renter_change_request_approved.txt'),
  ('renter_change_request_declined', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'We cannot make that change to booking {{booking_number}}', 'Your booking stays exactly as it was.', 'Immediate', 'Staff decline a change request. Sent when the change request status becomes declined; staff enter the reason.', null, '/account/bookings/{{booking_number}}', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"decline_reason","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"pickup_date","type":"string"},{"name":"pickup_time","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_time","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_image_url","type":"url"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_change_request_declined.html', 'templates/renter_change_request_declined.txt'),
  ('renter_change_request_received', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'We have your change request for booking {{booking_number}}', 'Your current booking stays as it is until we reply.', 'Immediate', 'The renter asks for a change: on an open offer the current booking_offers row becomes change_requested (booking status offered); on a booking with status confirmed a change request is logged.', null, '/account/bookings/{{booking_number}}', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"current_state","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"requested_changes","type":"list","fields":["label","before","after"]},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_change_request_received.html', 'templates/renter_change_request_received.txt'),
  ('renter_comeback_1m', 'renter', '{}'::text[], 'marketing', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', '{{discount_percent}}% off your next rental, {{first_name}}', 'Code {{discount_code}}, good until {{discount_expires}}.', '30 days after the booking closes', '30 days after booking status becomes closed, only if the renter''s marketing consent is true, they have not unsubscribed, no booking or request was created since that booking closed, the renter is not blocked and has no unpaid balance. A new single-use discount code is generated at send time. This is the last automated offer for that booking.', null, '/cars', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"discount_applies_to","type":"string"},{"name":"discount_code","type":"string"},{"name":"discount_expires","type":"string"},{"name":"discount_percent","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"last_vehicle_name","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"unsubscribe_url","type":"url"}]'::jsonb, 'templates/renter_comeback_1m.html', 'templates/renter_comeback_1m.txt'),
  ('renter_comeback_1w', 'renter', '{}'::text[], 'marketing', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', '{{discount_percent}}% off your next CarmaCars rental', 'Code {{discount_code}}, good until {{discount_expires}}.', '7 days after the booking closes', '7 days after booking status becomes closed, only if the renter''s marketing consent is true, they have not unsubscribed, no future booking or open request exists, the renter is not blocked and has no unpaid balance. A single-use discount code is generated for the renter at send time.', null, '/cars', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"discount_applies_to","type":"string"},{"name":"discount_code","type":"string"},{"name":"discount_expires","type":"string"},{"name":"discount_percent","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"unsubscribe_url","type":"url"}]'::jsonb, 'templates/renter_comeback_1w.html', 'templates/renter_comeback_1w.txt'),
  ('renter_damage_found', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Damage found on the {{vehicle_name}} after your return', 'Booking {{booking_number}}. Photos inside. An itemized statement will follow.', 'Immediate, within 48 hours of return', 'An incident of type damage is recorded on a returned booking from the photo review after hand-back (damage not noted on the signed return report). Must be sent within 48 hours of check-in. (Message template T8.)', 'T8', null, '[{"name":"booking_number","type":"string"},{"name":"checkin_date","type":"string"},{"name":"checkin_time","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"damage_description","type":"string"},{"name":"first_name","type":"string"},{"name":"inspection_date","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"supporting_document_url","type":"url"},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_damage_found.html', 'templates/renter_damage_found.txt'),
  ('renter_deposit_declined', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Your deposit of {{deposit_amount}} was declined', 'We cannot hand over the {{vehicle_name}} until the deposit goes through.', 'Immediate', 'The security deposit attempt at pickup fails: a payment of kind hold (rental of 7 days or less) or charge (longer rental) for the booking deposit is declined while the booking is confirmed and the pickup job is in progress. Sent on each failed attempt. The car is not released.', null, '/account/bookings/{{booking_number}}/pay', '[{"name":"booking_number","type":"string"},{"name":"card_brand","type":"string"},{"name":"card_last4","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"deposit_amount","type":"string"},{"name":"deposit_method_text","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_deposit_declined.html', 'templates/renter_deposit_declined.txt'),
  ('renter_deposit_released', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'The rest of your deposit has been released, booking {{booking_number}}', '{{release_amount}} is on its way back to your card ending {{card_last4}}.', 'Immediate', 'A deposit amount that was held back after the final statement is released or applied (deposit released_at is set, or the hold-back is applied to a charge). Happens within 30 days of check-in.', null, '/account/bookings/{{booking_number}}/statement', '[{"name":"booking_number","type":"string"},{"name":"card_brand","type":"string"},{"name":"card_last4","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"deposit_held_back","type":"string"},{"name":"first_name","type":"string"},{"name":"holdback_applied","type":"string"},{"name":"holdback_reason","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"release_amount","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_deposit_released.html', 'templates/renter_deposit_released.txt'),
  ('renter_extension_approved', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Extension available. Pay {{extension_amount}} by {{return_time}} to confirm', 'New return: {{new_return_date}}, {{new_return_time}}. Not confirmed until paid.', 'Immediate', 'Booking extension status changes from requested to approved (staff checked the calendar, unpaid charges and coverage to the new return date). Payment is still outstanding.', null, '/account/bookings/{{booking_number}}/extend', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"extension_amount","type":"string"},{"name":"extension_lines","type":"list","fields":["label","amount"]},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"new_return_date","type":"string"},{"name":"new_return_time","type":"string"},{"name":"new_total_amount","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_time","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_extension_approved.html', 'templates/renter_extension_approved.txt'),
  ('renter_extension_confirmed', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Extension confirmed. New return {{new_return_date}}, {{new_return_time}}', 'Booking {{booking_number}} repriced to {{new_total_amount}}. Paid today {{extension_amount}}.', 'Immediate', 'Booking extension status changes to confirmed (the extension payment succeeded before the return time and the booking return time was moved). This is the written confirmation. (Message template T11.)', 'T11', '/account/bookings/{{booking_number}}', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"deposit_note","type":"string"},{"name":"extension_amount","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"km_allowance","type":"string"},{"name":"new_return_date","type":"string"},{"name":"new_return_time","type":"string"},{"name":"new_total_amount","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"return_place","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_extension_confirmed.html', 'templates/renter_extension_confirmed.txt'),
  ('renter_extension_declined', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'We cannot extend booking {{booking_number}}', 'Please return the {{vehicle_name}} by {{return_time}} on {{return_date}}.', 'Immediate', 'Booking extension status changes from requested to declined. Staff choose the reason.', null, '/account/bookings/{{booking_number}}/return', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"decline_reason","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_place","type":"string"},{"name":"return_time","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_extension_declined.html', 'templates/renter_extension_declined.txt'),
  ('renter_extension_requested', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'We have your extension request for booking {{booking_number}}', 'Your return time is unchanged until we confirm and you pay.', 'Immediate', 'A booking extension row is created with status requested by the renter on an on_rent or confirmed booking.', null, '/account/bookings/{{booking_number}}', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"requested_return_date","type":"string"},{"name":"requested_return_time","type":"string"},{"name":"return_date","type":"string"},{"name":"return_time","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_extension_requested.html', 'templates/renter_extension_requested.txt'),
  ('renter_extra_charge', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', '{{charge_type}} charge of {{charge_total}} on booking {{booking_number}}', '{{charge_summary}}. The record is linked inside.', 'Immediate, when the charge is taken', 'A charge is billed to a renter after the final statement: a toll or ticket matched to the booking and charged, or a damage, fuel, cleaning, mileage, lost key or other line added by Finance with its supporting record. One email per charge event. The supporting document is required; the charge cannot be sent without it. (Message template T19 for tolls and tickets.)', 'T19', '/account/bookings/{{booking_number}}/statement', '[{"name":"booking_number","type":"string"},{"name":"charge_event_date","type":"string"},{"name":"charge_lines","type":"list","fields":["label","amount"]},{"name":"charge_reference","type":"string"},{"name":"charge_summary","type":"string"},{"name":"charge_total","type":"string"},{"name":"charge_type","type":"string"},{"name":"charged_to","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"payment_date","type":"string"},{"name":"pickup_date","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"supporting_document_url","type":"url"},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_extra_charge.html', 'templates/renter_extra_charge.txt'),
  ('renter_final_statement', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Your final statement for booking {{booking_number}}', 'Charges {{charges_total}}. Deposit returned {{deposit_returned}}.', 'When the statement is issued, within 7 business days of check-in', 'A renter statement for a returned booking is issued (statement sent_at is set by Finance), which captures charges from the deposit and releases the balance. Due within 7 business days of check-in. (Message template T9.)', 'T9', '/account/bookings/{{booking_number}}/statement', '[{"name":"booking_number","type":"string"},{"name":"card_charged","type":"string"},{"name":"card_last4","type":"string"},{"name":"charges_total","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"deposit_amount","type":"string"},{"name":"deposit_applied","type":"string"},{"name":"deposit_held_back","type":"string"},{"name":"deposit_return_note","type":"string"},{"name":"deposit_returned","type":"string"},{"name":"first_name","type":"string"},{"name":"has_card_charge","type":"boolean"},{"name":"has_charges","type":"boolean"},{"name":"has_holdback","type":"boolean"},{"name":"holdback_reason","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"statement_lines","type":"list","fields":["label","amount"]},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_final_statement.html', 'templates/renter_final_statement.txt'),
  ('renter_identity_approved', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'You are verified. All set for {{pickup_date}}', 'Bring your original licence and the card ending {{card_last4}}.', 'Immediate', 'Every driver on a confirmed booking has identity_status verified and the booking coverage proof is marked confirmed (whichever happens last).', null, '/account/bookings/{{booking_number}}', '[{"name":"booking_number","type":"string"},{"name":"card_brand","type":"string"},{"name":"card_last4","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"deposit_amount","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"pickup_date","type":"string"},{"name":"pickup_time","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_time","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_identity_approved.html', 'templates/renter_identity_approved.txt'),
  ('renter_identity_needed', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Upload your licence and coverage proof for {{pickup_date}}', 'We need them by {{verify_by}}. No car is released without them.', 'On confirmation, then 48 hours before pickup if still missing', 'Booking status becomes confirmed while any driver has identity_status other than verified or the booking has no confirmed coverage option (skipped when renter_booking_confirmed already carried the notice in the same minute). Sent again 48 hours before pickup if anything is still missing.', null, '/account/bookings/{{booking_number}}/verify', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"coverage_for_sale","type":"boolean"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"missing_items","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"pickup_date","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"},{"name":"verify_by","type":"string"}]'::jsonb, 'templates/renter_identity_needed.html', 'templates/renter_identity_needed.txt'),
  ('renter_identity_rejected', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Please resend a document for booking {{booking_number}}', 'We could not accept one item. Send a new one by {{verify_by}}.', 'Immediate', 'Staff reject an identity document, selfie or coverage proof on a confirmed booking (identity verification or coverage proof status becomes rejected). Staff choose the reason; it fills reject_reason.', null, '/account/bookings/{{booking_number}}/verify', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"driver_name","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reject_reason","type":"string"},{"name":"rejected_item","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"verify_by","type":"string"}]'::jsonb, 'templates/renter_identity_rejected.html', 'templates/renter_identity_rejected.txt'),
  ('renter_late_return_final', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Final notice: return the {{vehicle_name}} by {{final_deadline}}', 'The car is 2 hours overdue. Return it or pay for an extension now.', '2 hours after the return time', 'Late-returns job: the booking is 2 hours past its return time, still on_rent, with no paid extension. The deadline shown is 1 hour after this email is sent. (Message template T14.)', 'T14', '/account/bookings/{{booking_number}}/extend', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"final_deadline","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"return_place","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_late_return_final.html', 'templates/renter_late_return_final.txt'),
  ('renter_late_return_first', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Your rental ended at {{return_time}}. Please return the car now', 'Return the {{vehicle_name}} or call {{support_phone}} to extend.', 'At the return time', 'Late-returns job (every 5 minutes): the return time has passed, booking status is still on_rent and no paid extension covers the time. Sent once, at 0 minutes late. (Message template T13.)', 'T13', '/account/bookings/{{booking_number}}/extend', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"late_fee_hourly","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_place","type":"string"},{"name":"return_time","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_late_return_first.html', 'templates/renter_late_return_first.txt'),
  ('renter_named_to_authority', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'We gave your details to the issuing authority for {{notice_type_lower}} {{notice_number}}', 'The authority will contact you directly about booking {{booking_number}}.', 'Immediate, when the admin names the renter', 'An admin names the renter to the issuing authority for a ticket or offence notice matched to the renter''s booking (toll ticket status becomes named_to_authority). The authority will send its notice to the renter directly; CarmaCars does not pay it and adds no charge for it.', null, null, '[{"name":"authority_name","type":"string"},{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"notice_amount","type":"string"},{"name":"notice_description","type":"string"},{"name":"notice_event_date","type":"string"},{"name":"notice_number","type":"string"},{"name":"notice_type_lower","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"supporting_document_url","type":"url"},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_named_to_authority.html', 'templates/renter_named_to_authority.txt'),
  ('renter_offer_expired', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Your offer for the {{vehicle_name}} has expired', 'Nothing was charged. Your request is closed and our team will follow up with you.', 'Immediate', 'The offers-expire job (every 5 minutes, app.expire_offers) marks the current booking_offers row expired because offer_expires_at passed without approval. The booking becomes expired (the request is closed), and customer service gets an offer_expired task to reopen it with a new offer or leave it closed. Sent once per offer version.', null, '/account/bookings/{{booking_number}}/request', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"instagram_url","type":"url","global":true},{"name":"offer_expires_at","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"pickup_date","type":"string"},{"name":"pickup_time","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_time","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_offer_expired.html', 'templates/renter_offer_expired.txt'),
  ('renter_offer_ready', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Your offer is ready: {{vehicle_name}}, {{pickup_date}}', 'Approve, sign and pay by {{offer_expires_at}} to confirm. Total {{total_amount}}.', 'Immediate', 'A booking_offers row is created with status sent by app.send_offer(), which moves the booking from requested to offered. Fires for every offer version: is_revised is true when the version is greater than 1 or an earlier offer was superseded, so this email also serves as the revised offer (there is no separate renter_offer_revised). has_adjustments is true when the offer differs from what the renter asked for; adjustments lists each difference.', null, '/account/bookings/{{booking_number}}/offer', '[{"name":"adjustments","type":"list","fields":["label","before","after"]},{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"deposit_amount","type":"string"},{"name":"first_name","type":"string"},{"name":"has_adjustments","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"is_revised","type":"boolean"},{"name":"km_allowance","type":"string"},{"name":"line_items","type":"list","fields":["label","amount"]},{"name":"offer_expires_at","type":"string"},{"name":"offer_note","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"overage_rate","type":"string"},{"name":"pickup_date","type":"string"},{"name":"pickup_place","type":"string"},{"name":"pickup_time","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_place","type":"string"},{"name":"return_time","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"total_amount","type":"string"},{"name":"vehicle_image_url","type":"url"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_offer_ready.html', 'templates/renter_offer_ready.txt'),
  ('renter_offer_reminder', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Your offer for the {{vehicle_name}} expires {{offer_expires_at}}', 'Approve, sign and pay {{total_amount}} to book the car.', '6 hours before the offer expires', 'Scheduled check: booking status is offered, its current booking_offers row is still sent, and offer_expires_at is 6 hours away (for an offer window shorter than 12 hours, at the halfway point). Sent once per offer.', null, '/account/bookings/{{booking_number}}/offer', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"deposit_amount","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"offer_expires_at","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"pickup_date","type":"string"},{"name":"pickup_time","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_time","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"time_left","type":"string"},{"name":"total_amount","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_offer_reminder.html', 'templates/renter_offer_reminder.txt'),
  ('renter_offer_withdrawn', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'We have withdrawn your offer for the {{vehicle_name}}', 'Nothing was booked. We are checking what else we can offer for your dates.', 'Immediate', 'A booking_offers row becomes withdrawn: staff take the offer back (booking event offer_withdrawn), or the system pushes the booking back from offered or pending_payment to requested because another booking was confirmed for the same car on overlapping dates (booking event pushed_back). Not sent when staff replace the offer with a revised one in the same action; renter_offer_ready covers that.', null, '/account/bookings/{{booking_number}}/request', '[{"name":"amount_paid","type":"string"},{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"has_amount_paid","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"pickup_date","type":"string"},{"name":"pickup_time","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_time","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"},{"name":"withdraw_reason","type":"string"}]'::jsonb, 'templates/renter_offer_withdrawn.html', 'templates/renter_offer_withdrawn.txt'),
  ('renter_payment_failed', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Payment of {{amount}} did not go through, booking {{booking_number}}', 'Your card ending {{card_last4}} was declined. {{next_step_short}}', 'Immediate', 'A renter payment attempt fails. Two cases, set by is_booking_payment: (true) the checkout payment for an approved offer fails, no fee, the booking stays pending_payment and does not block the car; (false) a charge to the Card on File is declined, the declined payment fee is added once per charge and retries are scheduled after 1, 3 and 7 days. Sent on the first decline and again after each failed retry. (Message template T10.)', 'T10', '/account/bookings/{{booking_number}}/pay', '[{"name":"amount","type":"string"},{"name":"amount_due","type":"string"},{"name":"booking_number","type":"string"},{"name":"card_brand","type":"string"},{"name":"card_last4","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"declined_fee","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"interest_rate","type":"string"},{"name":"is_booking_payment","type":"boolean"},{"name":"next_retry_date","type":"string"},{"name":"next_step_short","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"pay_by","type":"string"},{"name":"payment_reason","type":"string"},{"name":"pickup_date","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_payment_failed.html', 'templates/renter_payment_failed.txt'),
  ('renter_payment_receipt', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Receipt: {{amount}} paid, booking {{booking_number}}', '{{payment_reason}}. Charged to your {{card_brand}} ending {{card_last4}}.', 'Immediate', 'A renter payment of kind charge or capture succeeds, except the payment that confirms a booking (renter_booking_confirmed carries that receipt). Covers extensions, accepted changes, extra charges paid by link and retried payments.', null, '/account/bookings/{{booking_number}}', '[{"name":"amount","type":"string"},{"name":"booking_number","type":"string"},{"name":"card_brand","type":"string"},{"name":"card_last4","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"payment_date","type":"string"},{"name":"payment_reason","type":"string"},{"name":"receipt_lines","type":"list","fields":["label","amount"]},{"name":"receipt_number","type":"string"},{"name":"receipt_url","type":"url"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_payment_receipt.html', 'templates/renter_payment_receipt.txt'),
  ('renter_pickup_details', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Pickup today: {{field_staff_name}} meets you at {{pickup_time}}', '{{pickup_place}}. Allow a few minutes for the walk-around.', '3 hours before pickup', 'The pickup field job for a confirmed booking has an assigned staff member and the pickup is 3 hours away. Sent earlier, at once, if the job is assigned inside that window, and sent again if the place, time or staff member changes after sending.', null, '/account/bookings/{{booking_number}}/pickup', '[{"name":"booking_number","type":"string"},{"name":"card_last4","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"deposit_amount","type":"string"},{"name":"field_staff_name","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"meeting_note","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"pickup_date","type":"string"},{"name":"pickup_place","type":"string"},{"name":"pickup_time","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_image_url","type":"url"},{"name":"vehicle_name","type":"string"},{"name":"vehicle_plate","type":"string"}]'::jsonb, 'templates/renter_pickup_details.html', 'templates/renter_pickup_details.txt'),
  ('renter_refund_issued', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Refund of {{refund_amount}} sent, booking {{booking_number}}', 'Back to your {{card_brand}} ending {{card_last4}}. Allow up to 10 business days.', 'Immediate', 'A refund row reaches status succeeded at the processor, for any refund except one already reported by a cancellation email sent in the same hour. Covers refunds for unused time after a breakdown, corrections and a charged deposit returned.', null, '/account/bookings/{{booking_number}}', '[{"name":"booking_number","type":"string"},{"name":"card_brand","type":"string"},{"name":"card_last4","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"payment_date","type":"string"},{"name":"refund_amount","type":"string"},{"name":"refund_reason","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_refund_issued.html', 'templates/renter_refund_issued.txt'),
  ('renter_rental_started', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Your rental has started. Condition report inside', 'Return by {{return_time}} on {{return_date}}. Keep the 24-hour number handy.', 'Immediate', 'Booking status changes to on_rent (deposit taken, pickup condition report signed, keys handed over).', null, '/account/bookings/{{booking_number}}/condition-report', '[{"name":"booking_number","type":"string"},{"name":"card_last4","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"deposit_amount","type":"string"},{"name":"deposit_method","type":"string"},{"name":"first_name","type":"string"},{"name":"fuel_out","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"km_allowance","type":"string"},{"name":"odometer_out","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"overage_rate","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_place","type":"string"},{"name":"return_time","type":"string"},{"name":"roadside_phone","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_rental_started.html', 'templates/renter_rental_started.txt'),
  ('renter_request_declined', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'We cannot fill your request for {{pickup_date}}', 'Nothing was charged. Here is why, and what you can do.', 'Immediate', 'Booking status changes from requested to declined. Staff choose a reason; it fills decline_reason.', null, '/cars', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"decline_reason","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"pickup_date","type":"string"},{"name":"pickup_time","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_time","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_request_declined.html', 'templates/renter_request_declined.txt'),
  ('renter_request_needs_info', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'One question before we can send your offer', 'Reply by {{reply_by}} so we can send your offer for the {{vehicle_name}}.', 'Immediate', 'Staff send a "more information needed" message on a booking with status requested. This is an event, not a status: the booking stays requested. Staff must enter the question (info_request) and a reply-by time (reply_by).', null, '/account/bookings/{{booking_number}}/request', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"info_request","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"pickup_date","type":"string"},{"name":"pickup_time","type":"string"},{"name":"reply_by","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_time","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_request_needs_info.html', 'templates/renter_request_needs_info.txt'),
  ('renter_request_received', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'We have your request for the {{vehicle_name}}', 'Nothing is booked or charged yet. We will reply with a firm offer.', 'Immediate', 'A booking row is created with status requested (booking event requested; the renter submitted the request form).', null, '/account/bookings/{{booking_number}}/request', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"estimate_amount","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"pickup_date","type":"string"},{"name":"pickup_place","type":"string"},{"name":"pickup_time","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_place","type":"string"},{"name":"return_time","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_image_url","type":"url"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_request_received.html', 'templates/renter_request_received.txt'),
  ('renter_return_complete', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Returned. Thanks for renting the {{vehicle_name}}', 'Checked in at {{checkin_time}}. Your statement follows within 7 business days.', 'Immediate', 'Booking status changes to returned (keys taken, return condition report signed).', null, '/account/bookings/{{booking_number}}/condition-report', '[{"name":"booking_number","type":"string"},{"name":"checkin_date","type":"string"},{"name":"checkin_time","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"deposit_amount","type":"string"},{"name":"first_name","type":"string"},{"name":"fuel_in","type":"string"},{"name":"fuel_out","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"km_allowance","type":"string"},{"name":"km_driven","type":"string"},{"name":"odometer_in","type":"string"},{"name":"odometer_out","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"return_findings","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_return_complete.html', 'templates/renter_return_complete.txt'),
  ('renter_return_details', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Return details for today: {{return_time}}, {{return_place}}', '{{field_staff_name}} will meet you. Bring all keys.', 'Immediate, only inside the 24 hours before return', 'The return field job of an on_rent booking has its place, time or assigned staff member changed after renter_return_reminder was sent, or is first assigned inside the last 24 hours before return.', null, '/account/bookings/{{booking_number}}/return', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"field_staff_name","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"meeting_note","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_place","type":"string"},{"name":"return_time","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_return_details.html', 'templates/renter_return_details.txt'),
  ('renter_return_reminder', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Your rental ends tomorrow at {{return_time}}', 'Return to {{return_place}} with the same fuel and all keys.', '24 hours before return', 'Hourly reminders job: booking status is on_rent and the return time is 24 hours away. Sent once per return time, so it is sent again after an extension moves the return. (Message template T6.)', 'T6', '/account/bookings/{{booking_number}}/extend', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"fuel_out","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"km_allowance","type":"string"},{"name":"late_fee_hourly","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"overage_rate","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_place","type":"string"},{"name":"return_time","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_return_reminder.html', 'templates/renter_return_reminder.txt'),
  ('renter_review_request', 'renter', '{}'::text[], 'marketing', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Rate your rental of the {{vehicle_name}}', 'Two minutes. Your review helps the next renter choose.', '2 days after the booking closes', '2 days after booking status becomes closed. Only if the renter has not unsubscribed and no review exists for it. A booking that had a problem (an incident, a dispute, an unpaid balance or a damage charge) is not sent automatically: it waits for a staff member to approve it (review_request_decision task, app.decide_review_request). Only an approval sends it, at once; a refusal means it is never sent. Relies on the existing business relationship for consent, so it carries the unsubscribe link and mailing address.', null, '/account/bookings/{{booking_number}}/review', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"pickup_date","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"unsubscribe_url","type":"url"},{"name":"vehicle_image_url","type":"url"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_review_request.html', 'templates/renter_review_request.txt'),
  ('renter_vehicle_disabled', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Your rental has ended and the {{vehicle_name}} will not restart', 'If anyone is unsafe where it is parked, call {{roadside_phone}} now.', 'Immediate', 'A tracker command of type engine disable for a booking is confirmed by the tracker (status confirmed), after admin approval. (Message template T15.)', 'T15', '/account/bookings/{{booking_number}}', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"roadside_phone","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_vehicle_disabled.html', 'templates/renter_vehicle_disabled.txt'),
  ('owner_account_created', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Confirm your email to open your CarmaCars owner account', 'One tap confirms your email. The link works for {{link_expiry}}.', 'Immediate', 'A user with the owner role is created (owner sign-up, or created by staff from an application) and the email address is not yet verified.', null, null, '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"link_expiry","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"verify_url","type":"url"}]'::jsonb, 'templates/owner_account_created.html', 'templates/owner_account_created.txt'),
  ('owner_agreement_ready', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Your CarmaCars owner documents are ready to sign', 'For the {{vehicle_name}}. Please sign by {{sign_by}}.', 'Immediate', 'Vehicle onboarding status changes to documents_sent (a signature request for the owner documents is opened): the Enrollment Agreement and Title Agreement for a first vehicle, or an Additional Vehicle Schedule for a later one, with the forms that vehicle needs.', null, '/owner/agreements', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"documents_to_sign","type":"list","fields":["name","note"]},{"name":"first_name","type":"string"},{"name":"has_paper_forms","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"insurance_fee","type":"string"},{"name":"management_mode","type":"string"},{"name":"onboarding_method","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"paper_forms","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"revenue_share","type":"string"},{"name":"sign_by","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"tracker_fee","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_agreement_ready.html', 'templates/owner_agreement_ready.txt'),
  ('owner_agreement_signed', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Signed: your owner documents for the {{vehicle_name}}', 'Your copies are inside. Next step: {{next_step_short}}', 'Immediate', 'Vehicle onboarding status changes to documents_signed (every owner document for the vehicle is signed by the owner and countersigned by CarmaCars, and witnessed forms are uploaded).', null, '/owner/agreements', '[{"name":"agreement_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"document_count","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"next_step","type":"string"},{"name":"next_step_short","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"signed_agreement_url","type":"url"},{"name":"signed_at","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_agreement_signed.html', 'templates/owner_agreement_signed.txt'),
  ('owner_application_declined', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'We cannot enrol your {{vehicle_name}}', 'Here is why, and what it means for your other vehicles.', 'Immediate', 'Vehicle onboarding status changes to declined at any step before enrolled. Staff choose the reason.', null, '/owner', '[{"name":"amount_paid","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"decline_reason","type":"string"},{"name":"first_name","type":"string"},{"name":"has_amount_paid","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_application_declined.html', 'templates/owner_application_declined.txt'),
  ('owner_application_received', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'We have your application for the {{vehicle_name}}', 'We reply within 1 business day with your fees and cost estimate.', 'Immediate', 'An owner vehicle application is submitted (vehicle onboarding row created with status intake), for a first vehicle or an added vehicle.', null, '/owner/application', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"ownership_summary","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"},{"name":"vehicle_plate","type":"string"},{"name":"vehicle_vin","type":"string"}]'::jsonb, 'templates/owner_application_received.html', 'templates/owner_application_received.txt'),
  ('owner_bank_details_changed', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Your CarmaCars payment details were changed', '{{change_summary}}. If this was not you, call us now.', 'Immediate', 'An owner''s payout account, pre-authorized debit authorization or card on file is added, changed or removed, by the owner or by staff. Sent to the owner''s email address on file before the change, and never batched. Security notice.', null, '/owner/billing', '[{"name":"change_summary","type":"string"},{"name":"changed_at","type":"string"},{"name":"changed_by","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"details_on_file","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/owner_bank_details_changed.html', 'templates/owner_bank_details_changed.txt'),
  ('owner_booking_confirmed', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Confirmed: your own booking of the {{vehicle_name}}, {{pickup_date}}', 'No rental charge or deposit. Booking {{booking_number}}.', 'Immediate', 'A booking of type owner (an Owner Booking: the owner driving their own vehicle) changes to confirmed, after the owner signs the Owner Rental agreement and staff confirm the licence is valid.', null, '/owner/bookings/{{booking_number}}', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"pickup_date","type":"string"},{"name":"pickup_place","type":"string"},{"name":"pickup_time","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_place","type":"string"},{"name":"return_time","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_booking_confirmed.html', 'templates/owner_booking_confirmed.txt'),
  ('owner_document_due', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', '{{document_type}} for your {{vehicle_name}} is due {{due_date}}', '{{document_action_short}}', '14 days before the expiry, again at 3 days', 'Expiry-watch job (daily 06:00): a document or registration item on the owner''s vehicle expires in 14 days: plate renewal, or for a Turo-Only vehicle the owner''s insurance proof. Sent once at 14 days and again at 3 days if still open. (Message template T23 for Turo-Only insurance.)', 'T23', '/owner/documents', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"document_action","type":"string"},{"name":"document_action_short","type":"string"},{"name":"document_consequence","type":"string"},{"name":"document_type","type":"string"},{"name":"due_date","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"},{"name":"vehicle_plate","type":"string"}]'::jsonb, 'templates/owner_document_due.html', 'templates/owner_document_due.txt'),
  ('owner_exit_completed', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Exit complete: your {{vehicle_name}} is back with you', 'Tracker removed, registration returned. Final statement on {{final_payout_date}}.', 'Immediate', 'Vehicle status changes from exit_notice to exited (Form E signed by both sides, tracker removed, registration returned).', null, '/owner/documents', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"exit_date","type":"string"},{"name":"final_payout_date","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"retransfer_summary","type":"string"},{"name":"signed_agreement_url","type":"url"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_exit_completed.html', 'templates/owner_exit_completed.txt'),
  ('owner_exit_notice_received', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Exit notice received for your {{vehicle_name}}. Exit Date {{exit_date}}', 'What happens between now and then, and what we need from you.', 'Immediate', 'Vehicle status changes to exit_notice (the owner''s written notice naming the vehicle is logged, or an admin decides to remove it) and the Exit Date is set. This email confirms the Exit Date in writing.', null, '/owner/vehicles/{{vehicle_id}}/exit', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"exit_date","type":"string"},{"name":"exit_date_basis","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"notice_date","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"retransfer_fee_note","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_id","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_exit_notice_received.html', 'templates/owner_exit_notice_received.txt'),
  ('owner_fee_change_notice', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Notice of a change to your terms for the {{vehicle_name}}, from {{effective_date}}', '{{fee_change_summary}}', 'Immediate, at least 30 days before the effective date', 'An admin schedules a change to a vehicle''s Insurance Fee or Tracker Fee (a fee history row with a future effective date), or proposes a new Revenue Share (a new Vehicle Schedule opened for signature). One email per vehicle. A fee change must be sent at least 30 days before its effective date. is_share_change is true when the Revenue Share changes, which needs the owner''s signature.', null, '/owner/agreements', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"effective_date","type":"string"},{"name":"fee_change_reason","type":"string"},{"name":"fee_change_summary","type":"string"},{"name":"fee_changes","type":"list","fields":["label","before","after"]},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"is_share_change","type":"boolean"},{"name":"notice_days","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_id","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_fee_change_notice.html', 'templates/owner_fee_change_notice.txt'),
  ('owner_fee_invoice', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Invoice {{invoice_number}}: {{invoice_month}} fees for your {{vehicle_name}}, {{invoice_total}}', 'Charged today by pre-authorized debit. Nothing to do if your account is funded.', '15th of each month', 'Owner-billing job on the 15th: a monthly owner invoice for a vehicle is issued and its pre-authorized debit is submitted. One invoice and one email per vehicle. Not sent for Turo-Only vehicles or vehicles owned personally by the two principals. (Message template T24.)', 'T24', '/owner/invoices/{{invoice_number}}', '[{"name":"bank_last4","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"invoice_lines","type":"list","fields":["label","amount"]},{"name":"invoice_month","type":"string"},{"name":"invoice_number","type":"string"},{"name":"invoice_period","type":"string"},{"name":"invoice_total","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"},{"name":"vehicle_plate","type":"string"}]'::jsonb, 'templates/owner_fee_invoice.html', 'templates/owner_fee_invoice.txt'),
  ('owner_in_arrears', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'In arrears: {{arrears_amount}} owing on your {{vehicle_name}}', 'The retry failed. Pay by {{removal_date}} to keep the vehicle in the program.', 'The day the bank reports the failed retry (18th or after)', 'Debit-retry job on the 18th: the retry of a failed owner invoice also fails and the invoice status becomes in_arrears (the vehicle''s arrears flag is set).', null, '/owner/invoices/{{invoice_number}}', '[{"name":"amount","type":"string"},{"name":"arrears_amount","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"invoice_number","type":"string"},{"name":"is_self_managed","type":"boolean"},{"name":"late_fee","type":"string"},{"name":"next_payout_date","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"removal_date","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_in_arrears.html', 'templates/owner_in_arrears.txt'),
  ('owner_incident_opened', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Incident involving your {{vehicle_name}} on {{incident_date}}', 'We are managing the claim and the repair. Please do not contact the insurer.', 'Immediate, the day the incident is opened', 'An incident (accident, theft, vandalism, or damage found at return) is opened on a vehicle that belongs to a third-party owner, or a claim is opened for it. (Message template T17.)', 'T17', '/owner/claims/{{incident_number}}', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"incident_date","type":"string"},{"name":"incident_number","type":"string"},{"name":"incident_summary","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_location","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_incident_opened.html', 'templates/owner_incident_opened.txt'),
  ('owner_incident_update', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Update on incident {{incident_number}}: {{incident_status}}', 'Your {{vehicle_name}}. {{incident_update_short}}', 'Immediate', 'A claim on a third-party owner''s vehicle changes status (submitted, accepted, in_repair, repaired, settling, closed), or staff post an incident event marked visible to the owner.', null, '/owner/claims/{{incident_number}}', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"expected_back","type":"string"},{"name":"first_name","type":"string"},{"name":"incident_number","type":"string"},{"name":"incident_status","type":"string"},{"name":"incident_update","type":"string"},{"name":"incident_update_short","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"owner_action","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"update_date","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_incident_update.html', 'templates/owner_incident_update.txt'),
  ('owner_new_booking', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'New booking on your {{vehicle_name}}: {{pickup_date}} to {{return_date}}', 'Rental charge {{rental_charge}}. Booking {{booking_number}}.', 'Immediate', 'A standard or non-refundable booking on the owner''s vehicle changes to confirmed. Not sent for Owner Bookings or for Turo trips. is_self_managed is true when the vehicle''s management mode is Self-Managed; only then are the renter''s name and mobile number included.', null, '/owner/bookings/{{booking_number}}', '[{"name":"billable_days","type":"string"},{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"is_self_managed","type":"boolean"},{"name":"opening_hours","type":"string","global":true},{"name":"pickup_date","type":"string"},{"name":"pickup_time","type":"string"},{"name":"rental_charge","type":"string"},{"name":"renter_name","type":"string"},{"name":"renter_phone","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_time","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_new_booking.html', 'templates/owner_new_booking.txt'),
  ('owner_onboarding_steps', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Next steps to enrol your {{vehicle_name}}', 'What to get, what to bring, and what the registry will cost you.', 'Immediate', 'Vehicle onboarding status changes to upfront_paid (or straight from documents_signed for a shareholder-owned vehicle). Lists the steps and documents for that vehicle''s onboarding method.', null, '/owner/vehicles/{{vehicle_id}}/onboarding', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"documents_needed","type":"list","fields":["name","status"]},{"name":"first_name","type":"string"},{"name":"government_forms","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"onboarding_estimate","type":"string"},{"name":"onboarding_method","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"owner_to_obtain","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_id","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_onboarding_steps.html', 'templates/owner_onboarding_steps.txt'),
  ('owner_payment_failed', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Your {{amount}} payment for the {{vehicle_name}} failed', 'A {{late_fee}} late fee applies. We retry on {{retry_date}}.', 'The day the bank reports the failed debit', 'Debit-results job (15th to 25th, daily): the debit for a monthly owner invoice is returned and the invoice status becomes failed, which adds the Late Fee to that vehicle. One email per vehicle. (Message template T25.)', 'T25', '/owner/billing', '[{"name":"amount","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"invoice_month","type":"string"},{"name":"invoice_number","type":"string"},{"name":"late_fee","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"retry_amount","type":"string"},{"name":"retry_date","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_payment_failed.html', 'templates/owner_payment_failed.txt'),
  ('owner_payment_received', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Payment received: {{amount}} for invoice {{invoice_number}}', 'For your {{vehicle_name}}. Nothing more to do.', 'Immediate', 'An owner invoice changes to paid: the debit for a monthly invoice clears (including a cleared retry), or the upfront invoice is paid by card or e-Transfer.', null, '/owner/invoices/{{invoice_number}}', '[{"name":"amount","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"invoice_number","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"payment_date","type":"string"},{"name":"payment_method","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_payment_received.html', 'templates/owner_payment_received.txt'),
  ('owner_payout_sent', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Payout sent: {{payout_amount}} for {{statement_month}}', 'By bank transfer to your account ending {{bank_last4}}.', '10th of each month, when the transfer is sent', 'A payout row for an owner changes to paid (an admin sent the bank transfer and recorded its reference). Normally the 10th. Not sent when the statement shows a balance owing instead of a payout. (Message template T26, payment part.)', 'T26', '/owner/statements/{{statement_number}}', '[{"name":"bank_last4","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"payment_date","type":"string"},{"name":"payout_amount","type":"string"},{"name":"payout_reference","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"statement_month","type":"string"},{"name":"statement_number","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/owner_payout_sent.html', 'templates/owner_payout_sent.txt'),
  ('owner_registry_visit', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Registry visit booked: {{visit_date}} at {{visit_time}}', 'For your {{vehicle_name}}. Bring the items on this list.', 'Immediate', 'Vehicle onboarding status changes to registry_booked (Fleet booked the registry visit), and again if the date, time or place changes. (Message template T21.)', 'T21', '/owner/vehicles/{{vehicle_id}}/onboarding', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"onboarding_estimate","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_id","type":"string"},{"name":"vehicle_name","type":"string"},{"name":"visit_date","type":"string"},{"name":"visit_items","type":"list","fields":["name"]},{"name":"visit_place","type":"string"},{"name":"visit_time","type":"string"}]'::jsonb, 'templates/owner_registry_visit.html', 'templates/owner_registry_visit.txt'),
  ('owner_statement_ready', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Your {{statement_month}} statement: {{payout_amount}}', 'Owner Revenue {{owner_revenue_total}}. {{payout_summary}}', '10th of each month', 'An owner statement changes to issued: on the 10th of the month, after an admin approves the payout run, for the previous month. One statement and one email per owner, covering all their vehicles. (Message template T26, statement part.)', 'T26', '/owner/statements/{{statement_number}}', '[{"name":"balance_forward","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"deductions_total","type":"string"},{"name":"first_name","type":"string"},{"name":"has_balance_forward","type":"boolean"},{"name":"has_payout_hst","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"kickbacks_deducted","type":"string"},{"name":"kickbacks_earned","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"owner_revenue_total","type":"string"},{"name":"payout_amount","type":"string"},{"name":"payout_hst","type":"string"},{"name":"payout_label","type":"string"},{"name":"payout_summary","type":"string"},{"name":"rentals_total","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"revenue_share_total","type":"string"},{"name":"statement_month","type":"string"},{"name":"statement_number","type":"string"},{"name":"statement_vehicles","type":"list","fields":["name","owner_revenue","payable"]},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/owner_statement_ready.html', 'templates/owner_statement_ready.txt'),
  ('owner_toll_ticket', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', '{{notice_type}} for your {{vehicle_name}}, {{notice_amount}}', '{{notice_action_short}}', 'Immediate, when Finance matches the notice', 'A toll or ticket is matched to the owner rather than a renter. is_forwarded true: the owner had the car outside the program, or the car is Turo-Only, and the notice is forwarded for the owner to pay. is_forwarded false: the owner had the car on an Owner Booking, CarmaCars paid it and an owner deduction is created at cost with no fee.', null, null, '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"is_forwarded","type":"boolean"},{"name":"notice_action_short","type":"string"},{"name":"notice_amount","type":"string"},{"name":"notice_description","type":"string"},{"name":"notice_due_date","type":"string"},{"name":"notice_event_date","type":"string"},{"name":"notice_number","type":"string"},{"name":"notice_type","type":"string"},{"name":"notice_type_lower","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"supporting_document_url","type":"url"},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_toll_ticket.html', 'templates/owner_toll_ticket.txt'),
  ('owner_upfront_invoice', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Upfront invoice {{invoice_number}} for the {{vehicle_name}}: {{invoice_total}}', 'Pay by card or e-Transfer to start registration. No security deposit.', 'Immediate', 'The upfront owner invoice for a vehicle is issued after documents_signed: the Install Fee plus the first and last month''s Insurance Fee, with HST. Not issued for Turo-Only or shareholder-owned vehicles.', null, '/owner/invoices/{{invoice_number}}', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"invoice_lines","type":"list","fields":["label","amount"]},{"name":"invoice_number","type":"string"},{"name":"invoice_total","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_upfront_invoice.html', 'templates/owner_upfront_invoice.txt'),
  ('owner_vehicle_enrolled', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Written confirmation: your {{vehicle_name}} is on the fleet policy', 'Enrollment Date {{enrollment_date}}. You may now cancel your own insurance on it.', 'Immediate', 'Vehicle onboarding status changes to enrolled (the insurer''s confirmation is filed and the vehicle is on the fleet policy). This email is the written confirmation that sets the Enrollment Date. (Message template T22.)', 'T22', '/owner/vehicles/{{vehicle_id}}', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"enrollment_date","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_id","type":"string"},{"name":"vehicle_name","type":"string"},{"name":"vehicle_plate","type":"string"},{"name":"vehicle_vin","type":"string"}]'::jsonb, 'templates/owner_vehicle_enrolled.html', 'templates/owner_vehicle_enrolled.txt'),
  ('owner_vehicle_listed', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Your {{vehicle_name}} is live and open for bookings', 'Approved and listed on carmacars.ca. Check the rates and block any dates you need.', 'Immediate', 'Vehicle status changes from ready_to_list to available and its listing is published (staff approved the listing).', null, '/owner/vehicles/{{vehicle_id}}/calendar', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"daily_rate","type":"string"},{"name":"deposit_amount","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"km_per_day","type":"string"},{"name":"monthly_rate","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_id","type":"string"},{"name":"vehicle_image_url","type":"url"},{"name":"vehicle_name","type":"string"},{"name":"weekend_rate","type":"string"},{"name":"weekly_rate","type":"string"}]'::jsonb, 'templates/owner_vehicle_listed.html', 'templates/owner_vehicle_listed.txt'),
  ('investor_notice_received', 'investor', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'investors@carmacars.ca', 'We received your notice of {{notice_date}}', 'This confirms receipt. Details inside.', 'Immediate, when the notice is logged', 'An admin logs a written notice received from an existing investor (change of bank account, change of the pay or reinvest election, change of contact details, or another notice under the Investment Agreement).', null, null, '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"notice_date","type":"string"},{"name":"notice_effective","type":"string"},{"name":"notice_subject","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/investor_notice_received.html', 'templates/investor_notice_received.txt'),
  ('investor_return_paid', 'investor', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'investors@carmacars.ca', 'Payment sent: {{return_amount}} for {{statement_month}}', 'By electronic transfer to your account ending {{bank_last4}}.', '15th of each month, when the transfer is sent', 'An investor monthly return row changes to paid (an admin sent the transfer on the Payment Date, the 15th of the month after the Return Month, and recorded its reference). Not sent for a reinvested return.', null, null, '[{"name":"bank_last4","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"payment_date","type":"string"},{"name":"payout_reference","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_amount","type":"string"},{"name":"statement_month","type":"string"},{"name":"statement_url","type":"url"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/investor_return_paid.html', 'templates/investor_return_paid.txt'),
  ('investor_statement_ready', 'investor', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'investors@carmacars.ca', 'Your {{statement_month}} statement is ready', 'Statement for {{statement_month}} under your Investment Agreement.', 'Monthly, when the statement is issued', 'An investor monthly statement for a Return Month is issued by an admin (after the returns accrual on the 1st). Sent only to existing investors with an active investment. Neutral servicing notice.', null, null, '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"invested_amount","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"return_amount","type":"string"},{"name":"return_treatment","type":"string"},{"name":"statement_month","type":"string"},{"name":"statement_number","type":"string"},{"name":"statement_url","type":"url"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/investor_statement_ready.html', 'templates/investor_statement_ready.txt'),
  ('staff_approval_needed', 'staff_admin', '{}'::text[], 'transactional', true, 'next', 'CarmaCars <billing@carmacars.ca>', 'contact@carmacars.ca', 'Approval needed: {{approval_type}}, {{amount}}', 'Asked by {{requested_by}}. {{approval_summary}}', 'Next digest. Immediate if due within 4 hours', 'A task that only an admin can approve is raised, other than a tracker disable: a refund outside the tier table or over the VA limit, a deposit release with a hold-back, a price override, a fee off the grid, or a write-off. Queued for the next admin digest. Sent immediately instead when its due time is within 4 hours.', null, '/admin/approvals', '[{"name":"amount","type":"string"},{"name":"approval_due","type":"string"},{"name":"approval_reason","type":"string"},{"name":"approval_subject","type":"string"},{"name":"approval_summary","type":"string"},{"name":"approval_type","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"requested_at","type":"string"},{"name":"requested_by","type":"string"}]'::jsonb, 'templates/staff_approval_needed.html', 'templates/staff_approval_needed.txt'),
  ('staff_digest_eod_admin', 'staff_admin', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Admin end of day: {{digest_count}} items open, {{digest_date}}', '{{digest_summary}}', 'Daily 18:15', 'Scheduled digest for Admin. Sent every day at 18:15 Toronto time (after the 18:00 reconcile job) to each active staff member with this role. Skipped when there is nothing to report. It carries every notice queued for this role with digest true since the last digest, plus these lists computed at send time: bookings confirmed today, money collected today, approvals still open, incidents updated today, anything a VA escalated that is not closed, tomorrow''s pickups and returns. Each line links to the item. One email replaces the separate notices.', null, '/admin', '[{"name":"company_address","type":"string","global":true},{"name":"digest_count","type":"string"},{"name":"digest_date","type":"string"},{"name":"digest_summary","type":"string"},{"name":"first_name","type":"string"},{"name":"has_items","type":"boolean"},{"name":"sections","type":"list","fields":["title","items","count"]},{"name":"stat_1","type":"string"},{"name":"stat_2","type":"string"}]'::jsonb, 'templates/staff_digest_eod_admin.html', 'templates/staff_digest_eod_admin.txt'),
  ('staff_digest_morning_admin', 'staff_admin', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Admin morning digest: {{digest_count}} items for {{digest_date}}', '{{digest_summary}}', 'Daily 07:30', 'Scheduled digest for Admin. Sent every day at 07:30 Toronto time to each active staff member with this role, even when nothing is waiting, so a missing digest is itself a warning sign. It carries every notice queued for this role with digest true since the last digest, plus these lists computed at send time: approvals waiting, open incidents and claims, open disputes, late returns, charges unpaid over 24 hours, owners in arrears, requests waiting over 2 hours, failed jobs. Each line links to the item. One email replaces the separate notices.', null, '/admin', '[{"name":"company_address","type":"string","global":true},{"name":"digest_count","type":"string"},{"name":"digest_date","type":"string"},{"name":"digest_summary","type":"string"},{"name":"first_name","type":"string"},{"name":"has_items","type":"boolean"},{"name":"sections","type":"list","fields":["title","items","count"]},{"name":"stat_1","type":"string"},{"name":"stat_2","type":"string"}]'::jsonb, 'templates/staff_digest_morning_admin.html', 'templates/staff_digest_morning_admin.txt'),
  ('staff_disable_approval_needed', 'staff_admin', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'contact@carmacars.ca', 'APPROVAL NEEDED: disable {{vehicle_name}}, booking {{booking_number}}', 'Requested by {{requested_by}}. Ground: {{disable_ground}}.', 'Immediate', 'A tracker command of type engine disable is created with status requested (Fleet asks after the final notice deadline passes, or on another ground in procedure 8). Sent to both admins. Immediate. The car is never disabled by a job.', null, '/admin/approvals', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"disable_ground","type":"string"},{"name":"final_notice_at","type":"string"},{"name":"renter_name","type":"string"},{"name":"renter_phone","type":"string"},{"name":"requested_at","type":"string"},{"name":"requested_by","type":"string"},{"name":"tracker_summary","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/staff_disable_approval_needed.html', 'templates/staff_disable_approval_needed.txt'),
  ('staff_dispute_opened', 'staff_admin', array['staff_va_finance']::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'contact@carmacars.ca', 'DISPUTE: {{amount}} on booking {{booking_number}}, answer by {{evidence_due}}', '{{renter_name}}. Reason given: {{dispute_reason}}.', 'Immediate', 'A dispute row is created from the payment processor webhook (a card dispute or chargeback is opened on a renter payment, or a debit dispute on an owner invoice). Sent to both admins and finance. Immediate.', null, '/admin/disputes/{{dispute_id}}', '[{"name":"amount","type":"string"},{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"dispute_id","type":"string"},{"name":"dispute_reason","type":"string"},{"name":"evidence_due","type":"string"},{"name":"owner_revenue_in_dispute","type":"string"},{"name":"payment_date","type":"string"},{"name":"payment_reason","type":"string"},{"name":"renter_name","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/staff_dispute_opened.html', 'templates/staff_dispute_opened.txt'),
  ('staff_fleet_count_warning', 'staff_admin', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'contact@carmacars.ca', 'Fleet count is {{fleet_count}}. The minimum is 10', '{{fleet_exiting}} under exit notice. Count after exits: {{fleet_count_after}}.', 'Monday 08:00, or at once on an exit notice', 'Fleet-recount job (Monday 08:00): vehicles on the fleet policy, less those under exit notice, number 11 or fewer. Also sent at once when an exit notice or removal would take the count to 11 or fewer. Turo-Only cars are not counted.', null, '/admin/fleet', '[{"name":"company_address","type":"string","global":true},{"name":"fleet_count","type":"string"},{"name":"fleet_count_after","type":"string"},{"name":"fleet_exiting","type":"string"},{"name":"fleet_onboarding","type":"string"},{"name":"next_exit_date","type":"string"}]'::jsonb, 'templates/staff_fleet_count_warning.html', 'templates/staff_fleet_count_warning.txt'),
  ('staff_incident_reported', 'staff_admin', array['staff_va_fleet']::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'contact@carmacars.ca', 'INCIDENT {{incident_number}}: {{incident_type}}, {{vehicle_name}}', 'Booking {{booking_number}}, {{renter_name}}. {{incident_summary}}', 'Immediate', 'An incident row is created of type accident, theft, vandalism or damage (including damage recorded on a return condition report or found in the photo review). Sent to both admins and Fleet. Immediate.', null, '/admin/incidents/{{incident_number}}', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"drivable","type":"string"},{"name":"incident_date","type":"string"},{"name":"incident_number","type":"string"},{"name":"incident_place","type":"string"},{"name":"incident_summary","type":"string"},{"name":"incident_type","type":"string"},{"name":"injuries","type":"string"},{"name":"owner_name","type":"string"},{"name":"police_report","type":"string"},{"name":"renter_name","type":"string"},{"name":"requested_at","type":"string"},{"name":"requested_by","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/staff_incident_reported.html', 'templates/staff_incident_reported.txt'),
  ('staff_job_failed', 'staff_admin', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'JOB FAILED: {{job_name}}, {{job_run_date}}', '{{job_effect}}', 'Immediate', 'A scheduled job run is marked failed in job_runs (which also raises one urgent admin task). Sent to both admins once per job per day. Immediate.', null, '/admin/jobs', '[{"name":"company_address","type":"string","global":true},{"name":"job_effect","type":"string"},{"name":"job_error","type":"string"},{"name":"job_name","type":"string"},{"name":"job_run_date","type":"string"}]'::jsonb, 'templates/staff_job_failed.html', 'templates/staff_job_failed.txt'),
  ('staff_monthly_statements_ready', 'staff_admin', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'contact@carmacars.ca', '{{statement_month}} statements are drafted and need your review', 'Company statement final, {{owner_statement_count}} owner statements waiting. Payouts go out on {{payout_date}}.', 'Immediate, when the company statement is finalized', 'The company statement for a month is finalized (company statement status becomes final): the company statement and the owner statements for that month are drafted and need an admin''s review before the owner statements are approved and issued. One email to each admin.', null, '/admin/statements', '[{"name":"company_address","type":"string","global":true},{"name":"company_statement_status","type":"string"},{"name":"draft_count","type":"string"},{"name":"first_name","type":"string"},{"name":"owner_revenue_total","type":"string"},{"name":"owner_statement_count","type":"string"},{"name":"payout_date","type":"string"},{"name":"payout_total","type":"string"},{"name":"revenue_share_total","type":"string"},{"name":"statement_month","type":"string"}]'::jsonb, 'templates/staff_monthly_statements_ready.html', 'templates/staff_monthly_statements_ready.txt'),
  ('staff_payouts_due', 'staff_admin', array['staff_va_finance']::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'contact@carmacars.ca', 'Payouts due today: {{payout_count}} transfers, {{payout_total}}', '{{payout_run_name}}. {{payout_run_status}}', '10th (owners) and 15th (investor returns), 08:00', 'Payouts job on the 10th at 08:00: approved owner payouts are due to be sent by bank transfer that day. Also on the 15th at 08:00 for investor returns due on the Payment Date. One email to both admins and finance. If the run is not approved yet, the email says so.', null, '/admin/payouts', '[{"name":"company_address","type":"string","global":true},{"name":"payout_count","type":"string"},{"name":"payout_rows","type":"list","fields":["name","amount"]},{"name":"payout_run_name","type":"string"},{"name":"payout_run_status","type":"string"},{"name":"payout_total","type":"string"},{"name":"run_approved","type":"boolean"}]'::jsonb, 'templates/staff_payouts_due.html', 'templates/staff_payouts_due.txt'),
  ('staff_statements_ready_for_approval', 'staff_admin', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'contact@carmacars.ca', '{{statement_month}} owner statements are ready for approval', '{{statement_count}} statements, {{payout_total}} to pay on the 10th. Approve by the 9th.', '5th of each month, reminder on the 8th', 'Statements-draft job on the 5th at 06:00: the draft owner statements for last month are built and an approval task is raised. One email to both admins. A reminder is sent on the 8th at 09:00 if the run is still not approved.', null, '/admin/statements', '[{"name":"company_address","type":"string","global":true},{"name":"deductions_total","type":"string"},{"name":"kickbacks_earned","type":"string"},{"name":"negative_balances","type":"string"},{"name":"owner_revenue_total","type":"string"},{"name":"payout_total","type":"string"},{"name":"revenue_share_total","type":"string"},{"name":"staff_kickbacks","type":"string"},{"name":"statement_count","type":"string"},{"name":"statement_flags","type":"string"},{"name":"statement_month","type":"string"}]'::jsonb, 'templates/staff_statements_ready_for_approval.html', 'templates/staff_statements_ready_for_approval.txt'),
  ('staff_weekly_summary', 'staff_admin', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Week of {{week_label}}: {{bookings_confirmed}} bookings, {{revenue_collected}} collected', 'Utilization {{utilization}}. {{overdue_count}} overdue items need a decision.', 'Monday 07:45', 'Scheduled: every Monday at 07:45 Toronto time, for the week that ended Sunday at midnight. One email to each of the two admins. Always sent, even with no activity.', null, '/admin/reports/weekly', '[{"name":"bookings_change","type":"string"},{"name":"bookings_confirmed","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"overdue_count","type":"string"},{"name":"overdue_items","type":"list","fields":["line","meta","url"]},{"name":"revenue_change","type":"string"},{"name":"revenue_collected","type":"string"},{"name":"upcoming_1","type":"string"},{"name":"upcoming_2","type":"string"},{"name":"upcoming_3","type":"string"},{"name":"utilization","type":"string"},{"name":"utilization_change","type":"string"},{"name":"week_label","type":"string"},{"name":"weekly_metrics","type":"list","fields":["label","value","previous"]}]'::jsonb, 'templates/staff_weekly_summary.html', 'templates/staff_weekly_summary.txt'),
  ('staff_cancellation_received', 'staff_va_finance', array['staff_va_cs']::text[], 'transactional', true, 'next', 'CarmaCars <billing@carmacars.ca>', 'contact@carmacars.ca', 'Cancelled: {{booking_number}}, refund {{refund_amount}} to process', '{{renter_name}}, tier {{refund_percent}}. Refund due within 10 business days.', 'Next digest. Immediate to admins when approval is needed', 'A booking cancellation row is created (booking status becomes cancelled or no_show). Queued for the next finance and customer service digests. Sent immediately to the admins instead when the refund is over $500 or outside the tier table, because it needs approval.', null, '/va/finance/bookings/{{booking_number}}', '[{"name":"amount_paid","type":"string"},{"name":"booked_at","type":"string"},{"name":"booking_number","type":"string"},{"name":"cancellation_received_at","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"deposit_status","type":"string"},{"name":"pickup_date","type":"string"},{"name":"pickup_time","type":"string"},{"name":"refund_amount","type":"string"},{"name":"refund_percent","type":"string"},{"name":"refund_tier","type":"string"},{"name":"renter_name","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/staff_cancellation_received.html', 'templates/staff_cancellation_received.txt'),
  ('staff_digest_eod_va_finance', 'staff_va_finance', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Finance end of day: {{digest_count}} items open, {{digest_date}}', '{{digest_summary}}', 'Daily 18:15', 'Scheduled digest for Finance. Sent every day at 18:15 Toronto time (after the 18:00 reconcile job) to each active staff member with this role. Skipped when there is nothing to report. It carries every notice queued for this role with digest true since the last digest, plus these lists computed at send time: processor payouts not matched by the 18:00 reconcile job, today''s returns not yet billed, refunds still open, cancellations received today, payments that failed today. Each line links to the item. One email replaces the separate notices.', null, '/va/finance', '[{"name":"company_address","type":"string","global":true},{"name":"digest_count","type":"string"},{"name":"digest_date","type":"string"},{"name":"digest_summary","type":"string"},{"name":"first_name","type":"string"},{"name":"has_items","type":"boolean"},{"name":"sections","type":"list","fields":["title","items","count"]},{"name":"stat_1","type":"string"},{"name":"stat_2","type":"string"}]'::jsonb, 'templates/staff_digest_eod_va_finance.html', 'templates/staff_digest_eod_va_finance.txt'),
  ('staff_digest_morning_va_finance', 'staff_va_finance', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Finance morning digest: {{digest_count}} items for {{digest_date}}', '{{digest_summary}}', 'Daily 07:30', 'Scheduled digest for Finance. Sent every day at 07:30 Toronto time to each active staff member with this role, even when nothing is waiting, so a missing digest is itself a warning sign. It carries every notice queued for this role with digest true since the last digest, plus these lists computed at send time: returns waiting for a statement, deposits near 7 business days since check-in, hold-backs near 30 days, card retries due today, declined payments, tolls and tickets to match and charge, refunds to process, owner invoices failed. Each line links to the item. One email replaces the separate notices.', null, '/va/finance', '[{"name":"company_address","type":"string","global":true},{"name":"digest_count","type":"string"},{"name":"digest_date","type":"string"},{"name":"digest_summary","type":"string"},{"name":"first_name","type":"string"},{"name":"has_items","type":"boolean"},{"name":"sections","type":"list","fields":["title","items","count"]},{"name":"stat_1","type":"string"},{"name":"stat_2","type":"string"}]'::jsonb, 'templates/staff_digest_morning_va_finance.html', 'templates/staff_digest_morning_va_finance.txt'),
  ('staff_insurer_invoice_due', 'staff_va_finance', array['staff_admin']::text[], 'transactional', true, 'morning', 'CarmaCars <billing@carmacars.ca>', 'contact@carmacars.ca', 'Insurer invoice {{invoice_number}} unpaid for {{days_outstanding}} days: {{balance_due}}', '{{insurer_name}}, claim {{claim_number}}, booking {{booking_number}}. Chase the adjuster.', 'Morning digest, 30 days after the invoice was sent, then weekly', 'Daily check at 06:00: an insurer_invoices row with status sent or part_paid has a balance and sent_at is 30 days ago. Queued once for the finance morning digest, then listed again every 7 days while the balance remains. At 60 days it is also queued for the admin digest.', null, '/va/finance/insurer-invoices/{{invoice_number}}', '[{"name":"adjuster_contact","type":"string"},{"name":"amount_paid","type":"string"},{"name":"balance_due","type":"string"},{"name":"booking_number","type":"string"},{"name":"claim_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"days_outstanding","type":"string"},{"name":"insurer_name","type":"string"},{"name":"invoice_number","type":"string"},{"name":"invoice_sent_at","type":"string"},{"name":"invoice_total","type":"string"},{"name":"last_contact","type":"string"},{"name":"renter_name","type":"string"}]'::jsonb, 'templates/staff_insurer_invoice_due.html', 'templates/staff_insurer_invoice_due.txt'),
  ('staff_owner_invoice_failed', 'staff_va_finance', array['staff_admin']::text[], 'transactional', true, 'next', 'CarmaCars <billing@carmacars.ca>', 'contact@carmacars.ca', 'Owner debit {{failure_stage}}: {{owner_name}}, {{vehicle_name}}, {{amount}}', 'Invoice {{invoice_number}}. {{failure_next_step}}', 'Next digest. Immediate to admins when the retry fails', 'An owner invoice changes to failed (first debit returned) or in_arrears (retry on the 18th returned). Queued for the next finance digest. The in_arrears case is also sent immediately to both admins.', null, '/va/finance/owner-invoices/{{invoice_number}}', '[{"name":"amount","type":"string"},{"name":"arrears_amount","type":"string"},{"name":"bank_reason","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"failure_next_step","type":"string"},{"name":"failure_stage","type":"string"},{"name":"invoice_month","type":"string"},{"name":"invoice_number","type":"string"},{"name":"late_fee","type":"string"},{"name":"owner_name","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/staff_owner_invoice_failed.html', 'templates/staff_owner_invoice_failed.txt'),
  ('staff_payment_failed', 'staff_va_finance', '{}'::text[], 'transactional', true, 'next', 'CarmaCars <billing@carmacars.ca>', 'contact@carmacars.ca', 'Declined: {{amount}} on booking {{booking_number}}', '{{renter_name}}, card ending {{card_last4}}. Attempt {{attempt_number}}. Next retry {{next_retry_date}}.', 'Next digest. Immediate at 24 hours unpaid during a rental', 'A charge to a renter''s Card on File is declined (payment attempt fails, not a checkout attempt on an offer). Queued for the next finance digest. Sent immediately to finance and admins instead when the booking is on_rent and the charge is still unpaid 24 hours after the request.', null, '/va/finance/bookings/{{booking_number}}', '[{"name":"amount","type":"string"},{"name":"amount_due","type":"string"},{"name":"attempt_number","type":"string"},{"name":"booking_number","type":"string"},{"name":"booking_status","type":"string"},{"name":"card_brand","type":"string"},{"name":"card_last4","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"declined_fee","type":"string"},{"name":"next_retry_date","type":"string"},{"name":"payment_reason","type":"string"},{"name":"renter_name","type":"string"}]'::jsonb, 'templates/staff_payment_failed.html', 'templates/staff_payment_failed.txt'),
  ('staff_return_findings', 'staff_va_finance', '{}'::text[], 'transactional', true, 'next', 'CarmaCars <bookings@carmacars.ca>', 'contact@carmacars.ca', 'Return findings: booking {{booking_number}}, {{findings_headline}}', '{{vehicle_name}}. Statement due within 7 business days of check-in.', 'Next digest, same day as the return', 'Fleet completes the review of a return (the return condition report is reviewed and the findings are saved on the booking). Queued for the next finance digest. Sent immediately to the admins as well when damage is recorded. (Message template T7, internal.)', 'T7', '/va/finance/bookings/{{booking_number}}', '[{"name":"booking_number","type":"string"},{"name":"cleaning_grade","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"damage_summary","type":"string"},{"name":"deposit_amount","type":"string"},{"name":"deposit_method","type":"string"},{"name":"deposit_release_due","type":"string"},{"name":"findings_headline","type":"string"},{"name":"fuel_in","type":"string"},{"name":"fuel_out","type":"string"},{"name":"keys_summary","type":"string"},{"name":"km_allowance","type":"string"},{"name":"km_driven","type":"string"},{"name":"minutes_late","type":"string"},{"name":"odometer_in","type":"string"},{"name":"odometer_out","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/staff_return_findings.html', 'templates/staff_return_findings.txt'),
  ('staff_toll_ticket_logged', 'staff_va_finance', '{}'::text[], 'transactional', true, 'next', 'CarmaCars <billing@carmacars.ca>', 'contact@carmacars.ca', '{{notice_type}} logged: plate {{vehicle_plate}}, {{notice_amount}}, due {{notice_due_date}}', 'Match: {{match_summary}}. Charge it within 3 business days.', 'Next digest', 'A toll or ticket row is created (a notice is logged) and the automatic match has run. Queued for the next finance digest with the match result.', null, '/va/finance/tolls-tickets/{{toll_ticket_id}}', '[{"name":"company_address","type":"string","global":true},{"name":"match_summary","type":"string"},{"name":"notice_amount","type":"string"},{"name":"notice_description","type":"string"},{"name":"notice_due_date","type":"string"},{"name":"notice_event_date","type":"string"},{"name":"notice_number","type":"string"},{"name":"notice_type","type":"string"},{"name":"toll_ticket_id","type":"string"},{"name":"vehicle_plate","type":"string"}]'::jsonb, 'templates/staff_toll_ticket_logged.html', 'templates/staff_toll_ticket_logged.txt'),
  ('staff_toll_ticket_unmatched', 'staff_va_finance', array['staff_admin']::text[], 'transactional', true, 'morning', 'CarmaCars <billing@carmacars.ca>', 'contact@carmacars.ca', 'Unmatched for 2 business days: {{notice_type}}, plate {{vehicle_plate}}', '{{notice_amount}}, due {{notice_due_date}}. Nobody had the car on record.', 'Morning digest, 2 business days after logging', 'Daily check at 06:00: a toll or ticket row has had no match for 2 business days since it was logged. Queued for the morning digest of finance and the admins, once per notice.', null, '/va/finance/tolls-tickets/{{toll_ticket_id}}', '[{"name":"company_address","type":"string","global":true},{"name":"logged_at","type":"string"},{"name":"nearest_records","type":"string"},{"name":"notice_amount","type":"string"},{"name":"notice_description","type":"string"},{"name":"notice_due_date","type":"string"},{"name":"notice_event_date","type":"string"},{"name":"notice_number","type":"string"},{"name":"notice_type","type":"string"},{"name":"toll_ticket_id","type":"string"},{"name":"vehicle_plate","type":"string"}]'::jsonb, 'templates/staff_toll_ticket_unmatched.html', 'templates/staff_toll_ticket_unmatched.txt'),
  ('staff_breakdown_reported', 'staff_va_fleet', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'contact@carmacars.ca', 'BREAKDOWN: {{vehicle_name}}, booking {{booking_number}}', '{{renter_name}} at {{breakdown_location}}. Dispatch roadside within 15 minutes.', 'Immediate', 'An incident row of type breakdown is created (a call to the 24-hour line is logged, or the renter reports it in the portal). Sent to the on-call Fleet person. Immediate.', null, '/va/fleet/bookings/{{booking_number}}', '[{"name":"booking_number","type":"string"},{"name":"breakdown_location","type":"string"},{"name":"breakdown_symptom","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"renter_name","type":"string"},{"name":"renter_phone","type":"string"},{"name":"tracker_summary","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/staff_breakdown_reported.html', 'templates/staff_breakdown_reported.txt'),
  ('staff_digest_eod_va_fleet', 'staff_va_fleet', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Fleet end of day: {{digest_count}} items open, {{digest_date}}', '{{digest_summary}}', 'Daily 18:15', 'Scheduled digest for Fleet. Sent every day at 18:15 Toronto time (after the 18:00 reconcile job) to each active staff member with this role. Skipped when there is nothing to report. It carries every notice queued for this role with digest true since the last digest, plus these lists computed at send time: the closing checks of procedure 19: handovers and returns without a signed condition report or full photo set, returns with no findings sent to Finance, calendar statuses that do not match, tomorrow''s cars not cleaned, incidents updated, the handover note for the on-call person. Each line links to the item. One email replaces the separate notices.', null, '/va/fleet', '[{"name":"company_address","type":"string","global":true},{"name":"digest_count","type":"string"},{"name":"digest_date","type":"string"},{"name":"digest_summary","type":"string"},{"name":"first_name","type":"string"},{"name":"has_items","type":"boolean"},{"name":"sections","type":"list","fields":["title","items","count"]},{"name":"stat_1","type":"string"},{"name":"stat_2","type":"string"}]'::jsonb, 'templates/staff_digest_eod_va_fleet.html', 'templates/staff_digest_eod_va_fleet.txt'),
  ('staff_digest_morning_va_fleet', 'staff_va_fleet', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Fleet morning digest: {{digest_count}} items for {{digest_date}}', '{{digest_summary}}', 'Daily 07:30', 'Scheduled digest for Fleet. Sent every day at 07:30 Toronto time to each active staff member with this role, even when nothing is waiting, so a missing digest is itself a warning sign. It carries every notice queued for this role with digest true since the last digest, plus these lists computed at send time: the opening checks of procedure 19: trackers not reporting, overnight movement or tamper alerts, today''s handovers and returns with their field person and acknowledgement, tomorrow''s pickups not ready, late returns, the expiry watch, listings to review, cars due for cleaning. Each line links to the item. One email replaces the separate notices.', null, '/va/fleet', '[{"name":"company_address","type":"string","global":true},{"name":"digest_count","type":"string"},{"name":"digest_date","type":"string"},{"name":"digest_summary","type":"string"},{"name":"first_name","type":"string"},{"name":"has_items","type":"boolean"},{"name":"sections","type":"list","fields":["title","items","count"]},{"name":"stat_1","type":"string"},{"name":"stat_2","type":"string"}]'::jsonb, 'templates/staff_digest_morning_va_fleet.html', 'templates/staff_digest_morning_va_fleet.txt'),
  ('staff_exit_notice_received', 'staff_va_fleet', array['staff_admin', 'staff_va_finance']::text[], 'transactional', true, 'next', 'CarmaCars <owners@carmacars.ca>', 'contact@carmacars.ca', 'Exit notice: {{owner_name}}, {{vehicle_name}}, Exit Date {{exit_date}}', 'Block the calendar after the Exit Date and plan the re-transfer.', 'Next digest. Immediate to admins if the fleet would fall below 10', 'Vehicle status changes to exit_notice. Queued for the next Fleet, finance and admin digests. Sent immediately to the admins instead when the fleet count after the exit would be below 10.', null, '/va/fleet/vehicles/{{vehicle_id}}', '[{"name":"bookings_before_exit","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"enrollment_date","type":"string"},{"name":"exit_date","type":"string"},{"name":"fleet_count_after","type":"string"},{"name":"notice_date","type":"string"},{"name":"owner_name","type":"string"},{"name":"retransfer_fee_note","type":"string"},{"name":"vehicle_id","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/staff_exit_notice_received.html', 'templates/staff_exit_notice_received.txt'),
  ('staff_expiry_watch', 'staff_va_fleet', array['staff_admin']::text[], 'transactional', true, 'morning', 'CarmaCars <owners@carmacars.ca>', 'contact@carmacars.ca', 'Expiry watch: {{expiry_count}} items, {{expiry_urgent_count}} within 3 days', 'Plates, insurance documents and safety certificates coming due.', 'Morning digest. Own email when an item is within 3 days', 'Expiry-watch job (daily 06:00) finds at least one item inside its window: plate renewal within 30 days, an insurance document within 14 days, a safety certificate inside its 36-day window with no registry visit booked, or arrears older than 30 days. The list is included in the Fleet morning digest; sent as its own email to Fleet and admins only when an item expires within 3 days.', null, '/va/fleet/expiries', '[{"name":"company_address","type":"string","global":true},{"name":"expiry_count","type":"string"},{"name":"expiry_items","type":"list","fields":["vehicle","item","expires"]},{"name":"expiry_urgent_count","type":"string"}]'::jsonb, 'templates/staff_expiry_watch.html', 'templates/staff_expiry_watch.txt'),
  ('staff_late_return_alert', 'staff_va_fleet', array['staff_admin']::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'contact@carmacars.ca', 'LATE {{minutes_late}} min: {{vehicle_name}}, booking {{booking_number}}', '{{renter_name}}, due {{return_time}}. {{late_action_short}}', 'At 0 and 30 minutes late (Fleet); at 2 hours (Fleet and admins)', 'Late-returns job (every 5 minutes): an on_rent booking passes its return time with no paid extension. Sent to Fleet at 0 minutes and at 30 minutes, and to Fleet and both admins at 2 hours. Immediate. The stage fills late_stage.', null, '/va/fleet/bookings/{{booking_number}}', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"late_action","type":"string"},{"name":"late_action_short","type":"string"},{"name":"late_stage","type":"string"},{"name":"minutes_late","type":"string"},{"name":"next_booking","type":"string"},{"name":"renter_name","type":"string"},{"name":"renter_phone","type":"string"},{"name":"return_date","type":"string"},{"name":"return_place","type":"string"},{"name":"return_time","type":"string"},{"name":"tracker_summary","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/staff_late_return_alert.html', 'templates/staff_late_return_alert.txt'),
  ('staff_listing_ready_for_review', 'staff_va_fleet', array['staff_admin']::text[], 'transactional', true, 'next', 'CarmaCars <owners@carmacars.ca>', 'contact@carmacars.ca', 'Listing ready for review: {{vehicle_name}}', 'Draft text and {{photo_count}} photos. Check, fix and publish within 2 business days.', 'Next digest', 'The AI drafting step finishes for a vehicle listing (photos processed, description and details drafted) and the vehicle status becomes ready_to_list. Queued for the next Fleet digest. Nothing is published until a person approves.', null, '/va/fleet/listings/{{vehicle_id}}', '[{"name":"company_address","type":"string","global":true},{"name":"listing_due","type":"string"},{"name":"listing_flags","type":"string"},{"name":"owner_name","type":"string"},{"name":"photo_count","type":"string"},{"name":"rates_status","type":"string"},{"name":"vehicle_id","type":"string"},{"name":"vehicle_image_url","type":"url"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/staff_listing_ready_for_review.html', 'templates/staff_listing_ready_for_review.txt'),
  ('staff_booking_request_new', 'staff_va_cs', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'contact@carmacars.ca', 'New request {{booking_number}}: {{vehicle_name}}, {{pickup_date}}', '{{renter_name}}, {{billable_days}} days, estimate {{estimate_amount}}. Review and send the offer.', 'Immediate', 'A booking row is created with status requested (booking event requested). Sent to every active customer service VA. Immediate, never batched.', null, '/va/cs/bookings/{{booking_number}}', '[{"name":"billable_days","type":"string"},{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"drivers_summary","type":"string"},{"name":"estimate_amount","type":"string"},{"name":"identity_summary","type":"string"},{"name":"pickup_date","type":"string"},{"name":"pickup_place","type":"string"},{"name":"pickup_time","type":"string"},{"name":"renter_history","type":"string"},{"name":"renter_name","type":"string"},{"name":"renter_note","type":"string"},{"name":"return_date","type":"string"},{"name":"return_time","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/staff_booking_request_new.html', 'templates/staff_booking_request_new.txt'),
  ('staff_change_request_received', 'staff_va_cs', '{}'::text[], 'transactional', true, 'next', 'CarmaCars <bookings@carmacars.ca>', 'contact@carmacars.ca', 'Change request on {{booking_number}}: {{change_summary}}', '{{renter_name}}, {{vehicle_name}}. Approve with a new price, or decline with a reason.', 'Next digest. Immediate if pickup is within 48 hours or the car is on rent', 'A booking change request row is created by a renter. Queued for the next customer service digest. Sent immediately instead when the pickup is less than 48 hours away or the booking is on_rent.', null, '/va/cs/bookings/{{booking_number}}', '[{"name":"booking_number","type":"string"},{"name":"booking_status","type":"string"},{"name":"change_summary","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"renter_name","type":"string"},{"name":"renter_note","type":"string"},{"name":"requested_changes","type":"list","fields":["label","before","after"]},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/staff_change_request_received.html', 'templates/staff_change_request_received.txt'),
  ('staff_digest_eod_va_cs', 'staff_va_cs', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Customer service end of day: {{digest_count}} items open, {{digest_date}}', '{{digest_summary}}', 'Daily 18:15', 'Scheduled digest for Customer service. Sent every day at 18:15 Toronto time (after the 18:00 reconcile job) to each active staff member with this role. Skipped when there is nothing to report. It carries every notice queued for this role with digest true since the last digest, plus these lists computed at send time: requests still unanswered, offers sent today and still open, documents still to review, change requests open, tomorrow''s pickups and their verification status, reviews received today. Each line links to the item. One email replaces the separate notices.', null, '/va/cs', '[{"name":"company_address","type":"string","global":true},{"name":"digest_count","type":"string"},{"name":"digest_date","type":"string"},{"name":"digest_summary","type":"string"},{"name":"first_name","type":"string"},{"name":"has_items","type":"boolean"},{"name":"sections","type":"list","fields":["title","items","count"]},{"name":"stat_1","type":"string"},{"name":"stat_2","type":"string"}]'::jsonb, 'templates/staff_digest_eod_va_cs.html', 'templates/staff_digest_eod_va_cs.txt'),
  ('staff_digest_morning_va_cs', 'staff_va_cs', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Customer service morning digest: {{digest_count}} items for {{digest_date}}', '{{digest_summary}}', 'Daily 07:30', 'Scheduled digest for Customer service. Sent every day at 07:30 Toronto time to each active staff member with this role, even when nothing is waiting, so a missing digest is itself a warning sign. It carries every notice queued for this role with digest true since the last digest, plus these lists computed at send time: requests waiting for an offer, requests waiting on the renter, offers open and when each expires, identity and coverage documents to review, change requests, tomorrow''s pickups with verification incomplete, reviews to moderate, bookings confirmed since the last digest. Each line links to the item. One email replaces the separate notices.', null, '/va/cs', '[{"name":"company_address","type":"string","global":true},{"name":"digest_count","type":"string"},{"name":"digest_date","type":"string"},{"name":"digest_summary","type":"string"},{"name":"first_name","type":"string"},{"name":"has_items","type":"boolean"},{"name":"sections","type":"list","fields":["title","items","count"]},{"name":"stat_1","type":"string"},{"name":"stat_2","type":"string"}]'::jsonb, 'templates/staff_digest_morning_va_cs.html', 'templates/staff_digest_morning_va_cs.txt'),
  ('staff_extension_requested', 'staff_va_cs', array['staff_va_finance']::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'contact@carmacars.ca', 'Extension asked: {{booking_number}}, current return {{return_date}} {{return_time}}', '{{renter_name}} wants the {{vehicle_name}} until {{requested_return_date}}. Answer before the return time.', 'Immediate', 'A booking extension row is created with status requested. Immediate, because an extension must be confirmed in writing and paid before the current return time.', null, '/va/cs/bookings/{{booking_number}}', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"coverage_valid_to","type":"string"},{"name":"new_length","type":"string"},{"name":"renter_name","type":"string"},{"name":"requested_return_date","type":"string"},{"name":"requested_return_time","type":"string"},{"name":"return_date","type":"string"},{"name":"return_time","type":"string"},{"name":"unpaid_charges","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/staff_extension_requested.html', 'templates/staff_extension_requested.txt'),
  ('staff_identity_review', 'staff_va_cs', '{}'::text[], 'transactional', true, 'next', 'CarmaCars <bookings@carmacars.ca>', 'contact@carmacars.ca', 'Documents to review: {{driver_name}}, booking {{booking_number}}', '{{documents_summary}}. Pickup {{pickup_date}}. Due {{verify_by}}.', 'Next digest. Immediate if pickup is within 48 hours', 'A renter or additional driver uploads identity documents (licence front, back and selfie) or coverage proof, creating a verification in status pending review. Queued for the next customer service digest. Sent immediately instead when the booking''s pickup is less than 48 hours away.', null, '/va/cs/bookings/{{booking_number}}/identity', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"documents_summary","type":"string"},{"name":"driver_name","type":"string"},{"name":"driver_role","type":"string"},{"name":"pickup_date","type":"string"},{"name":"pickup_time","type":"string"},{"name":"verify_by","type":"string"}]'::jsonb, 'templates/staff_identity_review.html', 'templates/staff_identity_review.txt'),
  ('staff_offer_approved_paid', 'staff_va_cs', array['staff_va_fleet']::text[], 'transactional', true, 'next', 'CarmaCars <bookings@carmacars.ca>', 'contact@carmacars.ca', 'Confirmed and paid: {{booking_number}}, {{vehicle_name}}, {{pickup_date}}', '{{renter_name}} paid {{amount_paid}}. Start verification and plan the handover.', 'Next digest. Immediate if pickup is within 24 hours', 'Booking status changes from pending_payment to confirmed (offer approved, agreement signed, total paid). Queued for the next digest of customer service and fleet. Sent immediately instead when the pickup is less than 24 hours away.', null, '/va/cs/bookings/{{booking_number}}', '[{"name":"amount_paid","type":"string"},{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"coverage_summary","type":"string"},{"name":"identity_summary","type":"string"},{"name":"pickup_date","type":"string"},{"name":"pickup_place","type":"string"},{"name":"pickup_time","type":"string"},{"name":"renter_name","type":"string"},{"name":"return_date","type":"string"},{"name":"return_time","type":"string"},{"name":"vehicle_name","type":"string"},{"name":"vehicle_plate","type":"string"}]'::jsonb, 'templates/staff_offer_approved_paid.html', 'templates/staff_offer_approved_paid.txt'),
  ('staff_request_waiting', 'staff_va_cs', array['staff_admin']::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'contact@carmacars.ca', 'Waiting {{waiting_time}}: request {{booking_number}} has no offer', '{{renter_name}}, {{vehicle_name}}, pickup {{pickup_date}}. Answer it now.', '2 hours after an unanswered request', 'Scheduled check every 5 minutes: a booking has had status requested for more than 2 hours since requested_at with no offer sent, no more-information message and no decline. Not raised for a booking that returned to requested from an expired or withdrawn offer. Sent once per request, to customer service and both admins. Immediate.', null, '/va/cs/bookings/{{booking_number}}', '[{"name":"assigned_to","type":"string"},{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"pickup_date","type":"string"},{"name":"pickup_time","type":"string"},{"name":"renter_name","type":"string"},{"name":"request_received_at","type":"string"},{"name":"return_date","type":"string"},{"name":"return_time","type":"string"},{"name":"vehicle_name","type":"string"},{"name":"waiting_time","type":"string"}]'::jsonb, 'templates/staff_request_waiting.html', 'templates/staff_request_waiting.txt'),
  ('staff_review_received', 'staff_va_cs', array['staff_admin']::text[], 'transactional', true, 'next', 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'New review: {{review_rating}} of 5 for the {{vehicle_name}}', '{{renter_name}}, booking {{booking_number}}. Read it and publish or reply.', 'Next digest. Immediate for 2 stars or lower', 'A renter submits a review for a closed booking (review row created, status pending moderation). Queued for the next customer service digest. A rating of 2 stars or lower is sent immediately to customer service and both admins instead.', null, '/va/cs/reviews', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"field_staff_name","type":"string"},{"name":"pickup_date","type":"string"},{"name":"renter_name","type":"string"},{"name":"return_date","type":"string"},{"name":"review_rating","type":"string"},{"name":"review_text","type":"string"},{"name":"review_title","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/staff_review_received.html', 'templates/staff_review_received.txt'),
  ('staff_digest_eod_va_sales', 'staff_va_sales', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Sales end of day: {{digest_count}} items open, {{digest_date}}', '{{digest_summary}}', 'Daily 18:15', 'Scheduled digest for Sales. Sent every day at 18:15 Toronto time (after the 18:00 reconcile job) to each active staff member with this role. Skipped when there is nothing to report. It carries every notice queued for this role with digest true since the last digest, plus these lists computed at send time: applications received today and whether each was answered, documents signed today, upfront invoices paid today, applications with no contact for 3 days. Each line links to the item. One email replaces the separate notices.', null, '/va/sales', '[{"name":"company_address","type":"string","global":true},{"name":"digest_count","type":"string"},{"name":"digest_date","type":"string"},{"name":"digest_summary","type":"string"},{"name":"first_name","type":"string"},{"name":"has_items","type":"boolean"},{"name":"sections","type":"list","fields":["title","items","count"]},{"name":"stat_1","type":"string"},{"name":"stat_2","type":"string"}]'::jsonb, 'templates/staff_digest_eod_va_sales.html', 'templates/staff_digest_eod_va_sales.txt'),
  ('staff_digest_morning_va_sales', 'staff_va_sales', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Sales morning digest: {{digest_count}} items for {{digest_date}}', '{{digest_summary}}', 'Daily 07:30', 'Scheduled digest for Sales. Sent every day at 07:30 Toronto time to each active staff member with this role, even when nothing is waiting, so a missing digest is itself a warning sign. It carries every notice queued for this role with digest true since the last digest, plus these lists computed at send time: owner applications not yet answered, owners with documents sent but not signed, upfront invoices unpaid, onboardings waiting on an owner document, registry visits in the next 7 days. Each line links to the item. One email replaces the separate notices.', null, '/va/sales', '[{"name":"company_address","type":"string","global":true},{"name":"digest_count","type":"string"},{"name":"digest_date","type":"string"},{"name":"digest_summary","type":"string"},{"name":"first_name","type":"string"},{"name":"has_items","type":"boolean"},{"name":"sections","type":"list","fields":["title","items","count"]},{"name":"stat_1","type":"string"},{"name":"stat_2","type":"string"}]'::jsonb, 'templates/staff_digest_morning_va_sales.html', 'templates/staff_digest_morning_va_sales.txt'),
  ('staff_owner_application_received', 'staff_va_sales', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'contact@carmacars.ca', 'New owner application: {{owner_name}}, {{vehicle_name}}', '{{ownership_summary}}. Reply within 1 business day.', 'Immediate', 'An owner vehicle application is submitted (vehicle onboarding row created with status intake), from a new owner or an enrolled owner adding a vehicle. Sent to every active sales VA. Immediate.', null, '/va/sales/applications/{{application_id}}', '[{"name":"application_id","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"current_insurer","type":"string"},{"name":"lender","type":"string"},{"name":"management_mode","type":"string"},{"name":"owner_contact","type":"string"},{"name":"owner_name","type":"string"},{"name":"owner_type","type":"string"},{"name":"ownership_summary","type":"string"},{"name":"referred_by","type":"string"},{"name":"vehicle_km","type":"string"},{"name":"vehicle_name","type":"string"},{"name":"vehicle_plate","type":"string"},{"name":"vehicle_vin","type":"string"}]'::jsonb, 'templates/staff_owner_application_received.html', 'templates/staff_owner_application_received.txt'),
  ('staff_field_job_assigned', 'staff_field', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'contact@carmacars.ca', 'New job: {{job_type}}, {{job_date}} at {{job_time}}', '{{vehicle_name}}, {{job_place}}. Open it and tap Acknowledge.', 'Immediate', 'A field job (pickup handover, return, tracker install, detail or photo shoot) is assigned to a field staff member, or reassigned to a new one. Sent to the new assignee. Immediate.', null, '/field/jobs/{{job_id}}', '[{"name":"company_address","type":"string","global":true},{"name":"customer_first_name","type":"string"},{"name":"first_name","type":"string"},{"name":"job_date","type":"string"},{"name":"job_id","type":"string"},{"name":"job_note","type":"string"},{"name":"job_place","type":"string"},{"name":"job_time","type":"string"},{"name":"job_type","type":"string"},{"name":"vehicle_name","type":"string"},{"name":"vehicle_plate","type":"string"}]'::jsonb, 'templates/staff_field_job_assigned.html', 'templates/staff_field_job_assigned.txt'),
  ('staff_field_job_changed', 'staff_field', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'contact@carmacars.ca', 'Job changed: {{job_type}}, now {{job_date}} at {{job_time}}', '{{job_change_summary}}', 'Immediate', 'An assigned field job has its time, place or vehicle changed, or is cancelled or taken away from the assignee. Sent to the staff member who held the job. Immediate.', null, '/field', '[{"name":"company_address","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"job_cancelled","type":"boolean"},{"name":"job_change_headline","type":"string"},{"name":"job_change_summary","type":"string"},{"name":"job_changes","type":"list","fields":["label","before","after"]},{"name":"job_date","type":"string"},{"name":"job_id","type":"string"},{"name":"job_place","type":"string"},{"name":"job_time","type":"string"},{"name":"job_type","type":"string"},{"name":"vehicle_name","type":"string"},{"name":"vehicle_plate","type":"string"}]'::jsonb, 'templates/staff_field_job_changed.html', 'templates/staff_field_job_changed.txt'),
  ('staff_field_jobs_today', 'staff_field', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'contact@carmacars.ca', 'Today: {{job_count}} jobs, first at {{first_job_time}}', '{{jobs_summary}}', 'Daily 07:00', 'Scheduled digest for field staff: every day at 07:00 Toronto time, one email to each field staff member who has at least one job that day. Skipped for a person with no jobs. Lists the same jobs as the evening digest, with any changes made overnight.', null, '/field', '[{"name":"company_address","type":"string","global":true},{"name":"digest_date","type":"string"},{"name":"first_job_time","type":"string"},{"name":"first_name","type":"string"},{"name":"job_count","type":"string"},{"name":"jobs","type":"list","fields":["time","type","vehicle","place","note","url"]},{"name":"jobs_summary","type":"string"}]'::jsonb, 'templates/staff_field_jobs_today.html', 'templates/staff_field_jobs_today.txt'),
  ('staff_field_jobs_tomorrow', 'staff_field', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'contact@carmacars.ca', 'Tomorrow: {{job_count}} jobs, first at {{first_job_time}}', '{{jobs_summary}}', 'Daily 18:00', 'Scheduled digest for field staff: every day at 18:00 Toronto time, one email to each field staff member who has at least one job assigned for the next day (pickup handovers, returns, tracker installs, details, photo shoots). Skipped for a person with no jobs. Jobs assigned or changed after it is sent go out at once with staff_field_job_assigned or staff_field_job_changed.', null, '/field', '[{"name":"company_address","type":"string","global":true},{"name":"digest_date","type":"string"},{"name":"first_job_time","type":"string"},{"name":"first_name","type":"string"},{"name":"job_count","type":"string"},{"name":"jobs","type":"list","fields":["time","type","vehicle","place","note","url"]},{"name":"jobs_summary","type":"string"}]'::jsonb, 'templates/staff_field_jobs_tomorrow.html', 'templates/staff_field_jobs_tomorrow.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();

-- A code that has left the catalogue is kept (old outbox rows point at it) but is marked.
update notification_catalogue set in_catalogue = false, updated_at = now()
 where in_catalogue and has_email and code not in (
  'account_password_reset',
  'account_security_notice',
  'account_sign_in_link',
  'renter_accident_instructions',
  'renter_account_created',
  'renter_agreement_ready',
  'renter_agreement_signed',
  'renter_balance_overdue',
  'renter_booking_cancelled',
  'renter_booking_cancelled_by_us',
  'renter_booking_confirmed',
  'renter_booking_reminder',
  'renter_breakdown_help',
  'renter_change_request_approved',
  'renter_change_request_declined',
  'renter_change_request_received',
  'renter_comeback_1m',
  'renter_comeback_1w',
  'renter_damage_found',
  'renter_deposit_declined',
  'renter_deposit_released',
  'renter_extension_approved',
  'renter_extension_confirmed',
  'renter_extension_declined',
  'renter_extension_requested',
  'renter_extra_charge',
  'renter_final_statement',
  'renter_identity_approved',
  'renter_identity_needed',
  'renter_identity_rejected',
  'renter_late_return_final',
  'renter_late_return_first',
  'renter_named_to_authority',
  'renter_offer_expired',
  'renter_offer_ready',
  'renter_offer_reminder',
  'renter_offer_withdrawn',
  'renter_payment_failed',
  'renter_payment_receipt',
  'renter_pickup_details',
  'renter_refund_issued',
  'renter_rental_started',
  'renter_request_declined',
  'renter_request_needs_info',
  'renter_request_received',
  'renter_return_complete',
  'renter_return_details',
  'renter_return_reminder',
  'renter_review_request',
  'renter_vehicle_disabled',
  'owner_account_created',
  'owner_agreement_ready',
  'owner_agreement_signed',
  'owner_application_declined',
  'owner_application_received',
  'owner_bank_details_changed',
  'owner_booking_confirmed',
  'owner_document_due',
  'owner_exit_completed',
  'owner_exit_notice_received',
  'owner_fee_change_notice',
  'owner_fee_invoice',
  'owner_in_arrears',
  'owner_incident_opened',
  'owner_incident_update',
  'owner_new_booking',
  'owner_onboarding_steps',
  'owner_payment_failed',
  'owner_payment_received',
  'owner_payout_sent',
  'owner_registry_visit',
  'owner_statement_ready',
  'owner_toll_ticket',
  'owner_upfront_invoice',
  'owner_vehicle_enrolled',
  'owner_vehicle_listed',
  'investor_notice_received',
  'investor_return_paid',
  'investor_statement_ready',
  'staff_approval_needed',
  'staff_digest_eod_admin',
  'staff_digest_morning_admin',
  'staff_disable_approval_needed',
  'staff_dispute_opened',
  'staff_fleet_count_warning',
  'staff_incident_reported',
  'staff_job_failed',
  'staff_monthly_statements_ready',
  'staff_payouts_due',
  'staff_statements_ready_for_approval',
  'staff_weekly_summary',
  'staff_cancellation_received',
  'staff_digest_eod_va_finance',
  'staff_digest_morning_va_finance',
  'staff_insurer_invoice_due',
  'staff_owner_invoice_failed',
  'staff_payment_failed',
  'staff_return_findings',
  'staff_toll_ticket_logged',
  'staff_toll_ticket_unmatched',
  'staff_breakdown_reported',
  'staff_digest_eod_va_fleet',
  'staff_digest_morning_va_fleet',
  'staff_exit_notice_received',
  'staff_expiry_watch',
  'staff_late_return_alert',
  'staff_listing_ready_for_review',
  'staff_booking_request_new',
  'staff_change_request_received',
  'staff_digest_eod_va_cs',
  'staff_digest_morning_va_cs',
  'staff_extension_requested',
  'staff_identity_review',
  'staff_offer_approved_paid',
  'staff_request_waiting',
  'staff_review_received',
  'staff_digest_eod_va_sales',
  'staff_digest_morning_va_sales',
  'staff_owner_application_received',
  'staff_field_job_assigned',
  'staff_field_job_changed',
  'staff_field_jobs_today',
  'staff_field_jobs_tomorrow'
 );
-- Sending class, urgency and what emits each code are worked out in SQL, not here.
select app.notification_catalogue_refresh();
-- CATALOGUE END

-- ================================================================ 4. outbox, digests, notices, preferences
create table notification_outbox (
  id                 uuid primary key default gen_random_uuid(),
  event_id           bigint references app_events (id),
  code               text not null references notification_catalogue (code),
  category           text not null check (category in ('transactional', 'marketing')),
  priority           smallint not null check (priority between 1 and 5),
  audience           text not null,                  -- the recipient's audience (renter, owner, staff_va_cs, ...)
  recipient_user_id  uuid references users (id),
  to_address         text,
  to_name            text,
  renter_id          uuid references renters (id),
  owner_id           uuid references owners (id),
  booking_id         uuid references bookings (id),
  vehicle_id         uuid references vehicles (id),
  entity             text,
  entity_id          uuid,
  payload            jsonb not null default '{}'::jsonb,
  missing_variables  text[] not null default '{}',   -- catalogue variables neither built here nor supplied by the sender
  dedupe_key         text not null unique,
  status             text not null default 'queued'
                     check (status in ('queued', 'sending', 'sent', 'failed', 'suppressed', 'skipped', 'delayed')),
  status_reason      text,
  attempts           integer not null default 0 check (attempts >= 0),
  send_after         timestamptz not null default now(),
  locked_at          timestamptz,
  provider_id        text,
  sent_at            timestamptz,
  last_error         text,
  unsubscribe_token  uuid unique,                    -- marketing only
  message_id         uuid references messages (id),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  check (status <> 'sent' or sent_at is not null)
);
create index notification_outbox_due_idx on notification_outbox (priority, send_after) where status in ('queued', 'delayed');
create index notification_outbox_sent_idx on notification_outbox (sent_at) where status = 'sent';
create index notification_outbox_event_idx on notification_outbox (event_id);
create index notification_outbox_provider_idx on notification_outbox (provider_id);
create trigger notification_outbox_updated before update on notification_outbox for each row execute function app.set_updated_at();
comment on table notification_outbox is 'Emails to send, one row per recipient. Written by app.process_events(); sent by the send-outbox Edge Function.';

create table staff_digest_items (
  id               uuid primary key default gen_random_uuid(),
  role             text not null check (role in ('admin', 'va_finance', 'va_fleet', 'va_cs', 'va_sales')),
  code             text not null references notification_catalogue (code),
  event_id         bigint references app_events (id),
  digest_slot      text not null default 'next' check (digest_slot in ('next', 'morning')),
  line             text not null,
  meta             text,
  url              text,
  entity           text,
  entity_id        uuid,
  booking_id       uuid references bookings (id),
  dedupe_key       text not null unique,
  created_at       timestamptz not null default now(),
  digested_at      timestamptz,
  digest_code      text,             -- the digest that carried it
  digest_run_key   text
);
create index staff_digest_items_open_idx on staff_digest_items (role, created_at) where digested_at is null;
comment on table staff_digest_items is 'Staff notices with digest true, waiting for the role''s next (or morning) digest.';

create table notifications (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references users (id),
  code        text not null references notification_catalogue (code),
  title       text not null,
  body        text,
  url         text,
  entity      text,
  entity_id   uuid,
  event_id    bigint references app_events (id),
  dedupe_key  text not null unique,
  created_at  timestamptz not null default now(),
  read_at     timestamptz
);
create index notifications_user_idx on notifications (user_id, created_at desc);
create index notifications_unread_idx on notifications (user_id) where read_at is null;
comment on table notifications is 'In-app notices, one per user and event. Free: they do not count toward the email cap.';

create table notification_preferences (
  user_id         uuid not null references users (id) on delete cascade,
  code            text not null references notification_catalogue (code),
  email_enabled   boolean not null default true,
  in_app_enabled  boolean not null default true,
  updated_at      timestamptz not null default now(),
  primary key (user_id, code)
);
create trigger notification_preferences_updated before update on notification_preferences for each row execute function app.set_updated_at();
comment on table notification_preferences is 'Per user and code. Email can be turned off only where the catalogue says user_can_mute (marketing, staff digests, the weekly summary).';

create table email_suppressions (
  id            uuid primary key default gen_random_uuid(),
  email         text not null check (email = lower(btrim(email))),
  scope         text not null check (scope in ('all', 'marketing')),
  reason        text not null check (reason in ('bounce', 'complaint', 'unsubscribe', 'manual')),
  outbox_id     uuid references notification_outbox (id),
  detail        text,
  created_by    uuid references users (id),
  created_at    timestamptz not null default now(),
  lifted_at     timestamptz,
  lifted_by     uuid references users (id),
  lift_reason   text,
  check ((lifted_at is null) = (lifted_by is null))
);
create unique index email_suppressions_active on email_suppressions (email, scope) where lifted_at is null;
comment on table email_suppressions is 'Addresses not to email: scope all (hard bounce, complaint, manual) or marketing (unsubscribed).';

create table marketing_sends (
  id            uuid primary key default gen_random_uuid(),
  code          text not null references notification_catalogue (code),
  booking_id    uuid references bookings (id),
  renter_id     uuid references renters (id),
  user_id       uuid references users (id),
  outbox_id     uuid references notification_outbox (id),
  promo_code_id uuid references promo_codes (id),
  consent_id    uuid references consents (id),
  decided_at    timestamptz not null default now(),
  unique (code, booking_id)
);
comment on table marketing_sends is 'One row per marketing email decided for a booking (review request, come-back offers): the once-only record and the code it carried.';

-- ================================================================ 5. consent and suppression
-- Express consent: an active marketing consent row, or the account's marketing opt-in, given after
-- any unsubscribe. Implied (existing business relationship): only "has not unsubscribed".
create or replace function app.has_marketing_consent(p_user uuid, p_rule text default 'express') returns boolean
language sql stable security definer set search_path = public, app as $$
  select case when p_user is null then false
    when p_rule = 'implied' then not exists (
         select 1 from users u where u.id = p_user
            and u.marketing_unsubscribed_at is not null
            and u.marketing_unsubscribed_at >= coalesce(
                  (select max(c.given_at) from consents c where c.user_id = u.id and c.consent_code = 'marketing' and c.withdrawn_at is null),
                  case when u.marketing_opt_in then u.marketing_opt_in_at end, '-infinity'::timestamptz))
    else exists (
         select 1 from users u
          where u.id = p_user
            and greatest(coalesce((select max(c.given_at) from consents c
                                    where c.user_id = u.id and c.consent_code = 'marketing' and c.withdrawn_at is null), '-infinity'::timestamptz),
                         case when u.marketing_opt_in then coalesce(u.marketing_opt_in_at, u.created_at) else '-infinity'::timestamptz end)
                > coalesce(u.marketing_unsubscribed_at, '-infinity'::timestamptz))
  end
$$;

create or replace function app.email_suppressed(p_email text, p_marketing boolean) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from email_suppressions s
                  where s.email = lower(btrim(p_email)) and s.lifted_at is null
                    and (s.scope = 'all' or p_marketing))
$$;

-- ================================================================ 6. recipients and payload
-- The base merge payload: the event's own values, the two global values and the recipient's first
-- name. Migration 0023 replaces this function with the full builder (it reads the tables of 0019
-- to 0022 and 0022's site_settings).
create or replace function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
begin
  return p_event.payload
      || jsonb_build_object('company_address', coalesce(s.company_address, ''),
                            'support_phone', coalesce(s.company_phone, ''),
                            'first_name', coalesce(split_part(p_to ->> 'name', ' ', 1), ''));
end $$;

-- Who receives an event, from the catalogue audience (and also_sent_to for staff codes).
-- Payload hints, set by the emitter:
--   recipient_user_id   one named user (field staff on a job, or a named staff member)
--   signer_email, signer_name, signer_user_id   one signer of a rental agreement
--   signers             a list of signers (renter_agreement_signed): each one except CarmaCars
--   email, first_name   a person without an account yet (an owner lead)
--   renter_id, owner_id, investor_id, booking_id, vehicle_id   the record to read the address from
--   _roles              staff roles to use instead of the catalogue's
--   _immediate          true: every staff recipient gets the email now, not the digest
--   _immediate_roles    the staff roles that get it now; the others get the digest
create or replace function app.notification_recipients(p_event app_events, p_c notification_catalogue)
returns table (audience text, user_id uuid, email text, name text, renter_id uuid, owner_id uuid, immediate boolean)
language plpgsql stable security definer set search_path = public, app as $$
declare
  p jsonb := p_event.payload;
  v_booking uuid := coalesce((p ->> 'booking_id')::uuid, case when p_event.entity = 'booking' then p_event.entity_id end);
  v_vehicle uuid := coalesce((p ->> 'vehicle_id')::uuid, case when p_event.entity = 'vehicle' then p_event.entity_id end);
  v_renter uuid;
  v_owner uuid;
  v_roles text[];
  v_role text;
begin
  if p_c.audience = 'renter' then
    if p ? 'signer_email' or p ? 'signer_user_id' then
      return query select 'renter'::text, (p ->> 'signer_user_id')::uuid,
                          coalesce(nullif(p ->> 'signer_email', ''), (select u.email from users u where u.id = (p ->> 'signer_user_id')::uuid)),
                          p ->> 'signer_name', null::uuid, null::uuid, true;
      return;
    end if;
    if jsonb_typeof(p -> 'signers') = 'array' then
      return query select 'renter'::text, (g ->> 'signer_user_id')::uuid, g ->> 'signer_email', g ->> 'signer_name',
                          null::uuid, null::uuid, true
                     from jsonb_array_elements(p -> 'signers') g
                    where coalesce(g ->> 'signer_role', '') <> 'carmacars' and nullif(g ->> 'signer_email', '') is not null;
      return;
    end if;
    v_renter := coalesce((p ->> 'renter_id')::uuid, (select b.renter_id from bookings b where b.id = v_booking),
                         case when p_event.entity = 'user' then (select r.id from renters r where r.user_id = p_event.entity_id) end);
    if v_renter is null and p_event.entity = 'user' then
      return query select 'renter'::text, u.id, u.email, u.full_name, null::uuid, null::uuid, true from users u where u.id = p_event.entity_id;
      return;
    end if;
    return query select 'renter'::text, r.user_id, coalesce(nullif(r.email, ''), u.email), r.legal_name, r.id, null::uuid, true
                   from renters r left join users u on u.id = r.user_id where r.id = v_renter;
    return;
  elsif p_c.audience = 'owner' then
    v_owner := coalesce((p ->> 'owner_id')::uuid,
                        case when p_event.entity = 'owner' then p_event.entity_id end,
                        (select b.owner_id from bookings b where b.id = v_booking),
                        (select v.owner_id from vehicles v where v.id = v_vehicle));
    if v_owner is null and p_event.entity = 'user' then
      return query select 'owner'::text, u.id, u.email, u.full_name, null::uuid, null::uuid, true from users u where u.id = p_event.entity_id;
      return;
    end if;
    if v_owner is null and nullif(p ->> 'email', '') is not null then
      return query select 'owner'::text, null::uuid, p ->> 'email', coalesce(p ->> 'owner_name', p ->> 'first_name'), null::uuid, null::uuid, true;
      return;
    end if;
    return query select 'owner'::text, o.user_id, coalesce(nullif(o.email, ''), u.email), o.legal_name, null::uuid, o.id, true
                   from owners o left join users u on u.id = o.user_id where o.id = v_owner;
    return;
  elsif p_c.audience = 'investor' then
    return query select 'investor'::text, i.user_id, coalesce(nullif(i.email, ''), u.email), i.legal_name, null::uuid, null::uuid, true
                   from investors i left join users u on u.id = i.user_id where i.id = (p ->> 'investor_id')::uuid;
    return;
  end if;

  -- staff
  if p ? 'recipient_user_id' then
    return query select coalesce(p_c.audience, 'staff'), u.id, u.email, u.full_name, null::uuid, null::uuid, true
                   from users u where u.id = (p ->> 'recipient_user_id')::uuid and u.status = 'active';
    return;
  end if;
  if jsonb_typeof(p -> '_roles') = 'array' then
    select array_agg(x) into v_roles from jsonb_array_elements_text(p -> '_roles') x;
  else
    v_roles := array[p_c.audience] || coalesce(p_c.also_sent_to, '{}');
  end if;
  foreach v_role in array v_roles loop
    if v_role not like 'staff_%' then continue; end if;
    return query
      select v_role, u.id, u.email, u.full_name, null::uuid, null::uuid,
             (not p_c.is_digest) or coalesce((p ->> '_immediate')::boolean, false)
             or coalesce(p -> '_immediate_roles' ? v_role, false)
        from users u
       where u.status = 'active'
         and case v_role
               when 'staff_admin' then exists (select 1 from user_roles r where r.user_id = u.id and r.role = 'admin')
               when 'staff_field' then exists (select 1 from user_roles r join staff_profiles sp on sp.user_id = r.user_id
                                                where r.user_id = u.id and r.role = 'field' and sp.staff_type = 'field' and sp.is_active)
               else exists (select 1 from user_roles r join staff_profiles sp on sp.user_id = r.user_id
                             where r.user_id = u.id and r.role = 'va' and sp.staff_type = 'va' and sp.is_active
                               and 'staff_va_' || sp.va_function::text = v_role)
             end;
  end loop;
end $$;

-- The one line a digest shows for a notice: the rendered subject, unless the emitter gave a line.
create or replace function app.digest_line(p_c notification_catalogue, p_payload jsonb) returns text
language sql stable as $$
  select coalesce(nullif(p_payload ->> '_digest_line', ''), app.render_text(p_c.subject, p_payload))
$$;

create or replace function app.notification_url(p_c notification_catalogue, p_payload jsonb) returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce(nullif(p_payload ->> '_url', ''),
                  case when p_c.link_path is not null then (app.settings()).notify_base_url || app.render_text(p_c.link_path, p_payload) end)
$$;

-- ================================================================ 7. turning events into notifications
-- Idempotent: every row it writes has a unique dedupe key, and an event is processed once.
create or replace function app.process_events(p_limit integer default null, p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  e app_events;
  c notification_catalogue;
  r record;
  v_payload jsonb;
  v_vars text[];
  v_missing text[];
  v_status text;
  v_reason text;
  v_token uuid;
  v_base text;
  v_n integer := 0;
  v_out integer;
  v_dig integer;
  v_app integer;
  v_role text;
  v_marketing boolean;
  v_email_on boolean;
  v_inapp_on boolean;
  v_booking uuid;
  v_vehicle uuid;
begin
  for e in select * from app_events where processed_at is null order by id
           limit coalesce(p_limit, s.notify_event_batch) for update skip locked
  loop
    v_out := 0; v_dig := 0; v_app := 0;
    select * into c from notification_catalogue where code = e.code;
    if c.code is null or not c.is_enabled then
      update app_events set processed_at = p_now, process_note = case when c.code is null then 'no catalogue entry' else 'code disabled' end
       where id = e.id;
      v_n := v_n + 1;
      continue;
    end if;
    v_base := coalesce(e.dedupe_key, e.code || ':' || coalesce(e.entity_id::text, '-') || ':e' || e.id);
    v_booking := coalesce((e.payload ->> 'booking_id')::uuid, case when e.entity = 'booking' then e.entity_id end);
    v_vehicle := coalesce((e.payload ->> 'vehicle_id')::uuid, case when e.entity = 'vehicle' then e.entity_id end,
                          (select b.vehicle_id from bookings b where b.id = v_booking));
    select array_agg(v ->> 'name') into v_vars from jsonb_array_elements(c.variables) v;
    v_marketing := c.category = 'marketing';

    for r in select * from app.notification_recipients(e, c) loop
      v_status := 'queued';
      v_payload := app.notification_payload(c.code, e, to_jsonb(r));
      select coalesce(n.email_enabled or not c.user_can_mute, true), coalesce(n.in_app_enabled, true)
        into v_email_on, v_inapp_on
        from (select 1) one left join notification_preferences n on n.user_id = r.user_id and n.code = c.code;

      -- a staff notice for the digest: one item per role (not per person)
      if r.audience like 'staff_%' and r.audience <> 'staff_field' and c.is_digest and not r.immediate then
        v_role := substr(r.audience, 7);
        insert into staff_digest_items (role, code, event_id, digest_slot, line, meta, url, entity, entity_id, booking_id, dedupe_key)
        values (v_role, c.code, e.id, coalesce(c.digest_slot, 'next'), app.digest_line(c, v_payload),
                nullif(v_payload ->> '_digest_meta', ''), app.notification_url(c, v_payload),
                e.entity, e.entity_id, v_booking, v_base || '|' || v_role)
        on conflict (dedupe_key) do nothing;
        if found then v_dig := v_dig + 1; end if;
      elsif c.has_email then
        v_status := 'queued'; v_reason := null; v_token := null;
        if v_marketing then
          v_token := gen_random_uuid();
          v_payload := v_payload || jsonb_build_object('unsubscribe_url',
                         s.notify_base_url || s.notify_unsubscribe_path || '?token=' || v_token::text);
        end if;
        select array_agg(x order by x) into v_missing
          from unnest(coalesce(v_vars, '{}')) x
         where (not v_payload ? x or jsonb_typeof(v_payload -> x) = 'null') and x <> all (c.sender_supplied);
        if nullif(btrim(coalesce(r.email, '')), '') is null then
          v_status := 'skipped'; v_reason := 'no email address';
        elsif app.email_suppressed(r.email, v_marketing) then
          v_status := 'suppressed'; v_reason := 'address suppressed';
        elsif v_marketing and not app.has_marketing_consent(r.user_id, coalesce(c.consent_rule, 'express')) then
          v_status := 'skipped'; v_reason := 'no marketing consent';
        elsif not v_email_on then
          v_status := 'skipped'; v_reason := 'turned off in preferences';
        end if;
        insert into notification_outbox (event_id, code, category, priority, audience, recipient_user_id, to_address, to_name,
             renter_id, owner_id, booking_id, vehicle_id, entity, entity_id, payload, missing_variables, dedupe_key,
             status, status_reason, send_after, unsubscribe_token)
        values (e.id, c.code, c.category,
                case when r.audience like 'staff_%' and c.priority = 4 then 4
                     when r.audience like 'staff_%' then 3 else c.priority end,
                r.audience, r.user_id, lower(btrim(r.email)), r.name, r.renter_id, r.owner_id, v_booking, v_vehicle,
                e.entity, e.entity_id, v_payload - array(select k from jsonb_object_keys(v_payload) k where k like '\_%'),
                coalesce(v_missing, '{}'), v_base || '|' || coalesce(r.user_id::text, lower(btrim(coalesce(r.email, '-')))),
                v_status, v_reason, coalesce((e.payload ->> '_send_after')::timestamptz, p_now), v_token)
        on conflict (dedupe_key) do nothing;
        if found then v_out := v_out + 1; end if;
      end if;

      -- the in-app notice (anyone with an account; a marketing notice only where its email may go)
      if r.user_id is not null and v_inapp_on and not (v_marketing and v_status <> 'queued') then
        insert into notifications (user_id, code, title, body, url, entity, entity_id, event_id, dedupe_key)
        values (r.user_id, c.code, app.render_text(c.subject, v_payload), app.render_text(c.preheader, v_payload),
                app.notification_url(c, v_payload), e.entity, e.entity_id, e.id, v_base || '|' || r.user_id::text)
        on conflict (dedupe_key) do nothing;
        if found then v_app := v_app + 1; end if;
      end if;
    end loop;

    update app_events set processed_at = p_now,
           process_note = format('outbox %s, digest %s, in-app %s', v_out, v_dig, v_app)
     where id = e.id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- pg_cron wrapper, every minute (0015 pattern). A run is recorded only when it did something.
create or replace function app.job_notify_events(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v_n integer;
  v_run uuid;
begin
  v_n := app.process_events(null, p_now);
  if v_n = 0 then return 'not_due'; end if;
  v_run := app.job_claim('notify-events', to_char(p_now at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  if v_run is not null then perform app.job_succeed(v_run, jsonb_build_object('events', v_n)); end if;
  return 'succeeded';
end $$;

-- ================================================================ 8. sender functions (service role only)
-- How many emails count against today's cap (Toronto day) and this month's.
create or replace function app.outbox_sent_today(p_now timestamptz default now()) returns integer
language sql stable security definer set search_path = public, app as $$
  select count(*)::integer from notification_outbox
   where (status = 'sent' and sent_at >= app.local_midnight(app.local_date(p_now))) or status = 'sending'
$$;

-- Claim the next emails to send. Order: priority class, then due time. A class sends only while
-- today's count is under its limit (and under the daily and monthly caps); marketing also only
-- inside its hours and under its own daily maximum. What cannot go now is marked delayed until
-- the next Toronto midnight (or the next marketing window): never dropped. When something is
-- held for the cap, the admins get one in-app notice that day.
create or replace function app.outbox_claim(p_limit integer default 20, p_now timestamptz default now())
returns table (id uuid, code text, category text, to_address text, to_name text, from_address text, reply_to text,
               subject text, payload jsonb, attempts integer, unsubscribe_url text, template_html text, template_text text)
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  v_today date := app.local_date(p_now);
  v_midnight timestamptz := app.local_midnight(app.local_date(p_now) + 1);
  v_local time := (p_now at time zone 'America/Toronto')::time;
  v_count integer;
  v_month integer;
  v_mkt integer;
  v_taken integer := 0;
  v_held integer := 0;
  v_ids uuid[] := '{}';
  r notification_outbox;
  v_limit integer;
  v_admin uuid;
begin
  -- a send that never reported back is tried again
  update notification_outbox o set status = 'queued', locked_at = null, last_error = 'sending lock expired'
   where o.status = 'sending' and o.locked_at < p_now - make_interval(mins => s.notify_sending_lock_minutes);
  v_count := app.outbox_sent_today(p_now);
  select count(*) into v_month from notification_outbox o
   where o.status = 'sent' and o.sent_at >= app.local_midnight(app.month_start(v_today));
  select count(*) into v_mkt from notification_outbox o
   where o.category = 'marketing' and o.status in ('sent', 'sending') and o.sent_at >= app.local_midnight(v_today);

  for r in select * from notification_outbox o
            where o.status in ('queued', 'delayed') and o.send_after <= p_now
            order by o.priority, o.send_after, o.created_at
            for update skip locked
  loop
    exit when v_taken >= p_limit;
    v_limit := least(s.notify_daily_cap, s.notify_class_limits[r.priority]);
    if r.category = 'marketing' and not (v_local >= s.notify_marketing_from and v_local < s.notify_marketing_until) then
      update notification_outbox o set status = 'delayed', status_reason = 'outside the marketing hours',
             send_after = case when v_local < s.notify_marketing_from then (v_today + s.notify_marketing_from) at time zone 'America/Toronto'
                               else (v_today + 1 + s.notify_marketing_from) at time zone 'America/Toronto' end
       where o.id = r.id;
    elsif v_count >= v_limit or v_month >= s.notify_monthly_cap
          or (r.category = 'marketing' and v_mkt >= s.notify_marketing_daily_max) then
      update notification_outbox o set status = 'delayed',
             status_reason = case when r.category = 'marketing' and v_mkt >= s.notify_marketing_daily_max then 'marketing maximum for today'
                                  when v_month >= s.notify_monthly_cap then 'monthly email limit' else 'daily email limit' end,
             send_after = v_midnight
       where o.id = r.id;
      v_held := v_held + 1;
    else
      update notification_outbox o set status = 'sending', locked_at = p_now, attempts = o.attempts + 1, status_reason = null
       where o.id = r.id;
      v_ids := v_ids || r.id;
      v_taken := v_taken + 1;
      v_count := v_count + 1;
      v_month := v_month + 1;
      if r.category = 'marketing' then v_mkt := v_mkt + 1; end if;
    end if;
  end loop;

  if v_held > 0 then
    for v_admin in select u.id from users u join user_roles ur on ur.user_id = u.id and ur.role = 'admin' where u.status = 'active' loop
      insert into notifications (user_id, code, title, body, url, dedupe_key)
      values (v_admin, 'staff_email_cap_reached', 'Email limit reached for today',
              format('%s emails are held until the limit resets. Safety and booking emails go first.', v_held),
              s.notify_base_url || '/admin', 'staff_email_cap_reached:' || v_today || '|' || v_admin)
      on conflict (dedupe_key) do nothing;
    end loop;
  end if;

  return query
    select o.id, o.code, o.category, o.to_address, o.to_name, c.from_address, c.reply_to,
           app.render_text(c.subject, o.payload), o.payload, o.attempts, o.payload ->> 'unsubscribe_url', c.template_html, c.template_text
      from notification_outbox o join notification_catalogue c on c.code = o.code
     where o.id = any (v_ids)
     order by o.priority, o.send_after;
end $$;

-- The provider accepted the email: mark it sent and keep the permanent log (messages).
create or replace function app.outbox_mark_sent(p_id uuid, p_provider_id text, p_body_text text default null,
                                                p_now timestamptz default now()) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  o notification_outbox;
  c notification_catalogue;
  v_msg uuid;
begin
  select * into o from notification_outbox where id = p_id for update;
  if o.id is null then raise exception 'Outbox row % not found', p_id using errcode = 'P0002'; end if;
  if o.status = 'sent' then return; end if;
  if o.status <> 'sending' then raise exception 'Outbox row % is %, not sending', p_id, o.status using errcode = '23514'; end if;
  select * into c from notification_catalogue where code = o.code;
  insert into messages (direction, channel, template_code, subject, body, to_address, from_address, user_id, renter_id, owner_id,
                        booking_id, vehicle_id, related_table, related_id, provider, provider_ref, status, occurred_at)
  values ('outbound', 'email', o.code, app.render_text(c.subject, o.payload), p_body_text, o.to_address, c.from_address,
          o.recipient_user_id, o.renter_id, o.owner_id, o.booking_id, o.vehicle_id, 'notification_outbox', o.id,
          'resend', p_provider_id, 'sent', p_now)
  returning id into v_msg;
  update notification_outbox set status = 'sent', sent_at = p_now, provider_id = p_provider_id, locked_at = null,
         last_error = null, message_id = v_msg
   where id = p_id;
end $$;

-- The send failed. Retried after the backoff of settings (1, 5, 30 minutes) until the maximum
-- attempts; a permanent failure (a rejected address) stops at once.
create or replace function app.outbox_mark_failed(p_id uuid, p_error text, p_permanent boolean default false,
                                                  p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  o notification_outbox;
  v_wait integer;
begin
  select * into o from notification_outbox where id = p_id for update;
  if o.id is null then raise exception 'Outbox row % not found', p_id using errcode = 'P0002'; end if;
  if p_permanent or o.attempts >= s.notify_max_attempts then
    update notification_outbox set status = 'failed', last_error = p_error, locked_at = null where id = p_id;
    return 'failed';
  end if;
  v_wait := coalesce(s.notify_backoff_minutes[greatest(o.attempts, 1)],
                     s.notify_backoff_minutes[cardinality(s.notify_backoff_minutes)], 30);
  update notification_outbox set status = 'queued', last_error = p_error, locked_at = null,
         send_after = p_now + make_interval(mins => v_wait)
   where id = p_id;
  return 'retry';
end $$;

-- Provider webhook: a hard bounce or a complaint. The address is suppressed for every email
-- (an admin can lift it), the row is failed, and a booking email to a renter raises a customer
-- service task to confirm the address.
create or replace function app.outbox_record_bounce(p_provider_id text, p_kind text, p_detail text default null,
                                                    p_email text default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  o notification_outbox;
  v_email text;
  v_id uuid;
begin
  if p_kind not in ('bounce', 'complaint') then
    raise exception 'Kind must be bounce or complaint, not %', p_kind using errcode = '22023';
  end if;
  select * into o from notification_outbox where provider_id = p_provider_id order by created_at desc limit 1;
  v_email := lower(btrim(coalesce(p_email, o.to_address)));
  if v_email is null then raise exception 'No outbox row for provider id % and no address given', p_provider_id using errcode = 'P0002'; end if;
  insert into email_suppressions (email, scope, reason, outbox_id, detail)
  values (v_email, 'all', p_kind, o.id, p_detail)
  on conflict (email, scope) where lifted_at is null do nothing
  returning id into v_id;
  if o.id is not null then
    update notification_outbox set status = 'failed', last_error = p_kind || coalesce(': ' || p_detail, '')
     where id = o.id and status in ('sending', 'sent', 'queued', 'delayed');
    update messages set status = 'failed' where id = o.message_id;
    if p_kind = 'bounce' and o.booking_id is not null and o.audience = 'renter'
       and not exists (select 1 from tasks t where t.task_type = 'email_bounced' and t.booking_id = o.booking_id
                         and t.status in ('open', 'in_progress', 'waiting')) then
      insert into tasks (queue, task_type, title, detail, priority, booking_id, renter_id, related_table, related_id)
      values ('cs', 'email_bounced', format('Email to %s bounced: confirm the address', coalesce(o.to_name, v_email)),
              format('%s could not be delivered to %s.', o.code, v_email), 'high', o.booking_id, o.renter_id,
              'notification_outbox', o.id);
    end if;
  end if;
  -- anything still waiting for that address is not sent
  update notification_outbox set status = 'suppressed', status_reason = 'address suppressed'
   where to_address = v_email and status in ('queued', 'delayed');
  return v_id;
end $$;

-- One-click unsubscribe: what the page shows before the click (valid, a masked address, the email).
create or replace function app.unsubscribe_token_info(p_token uuid)
returns table (valid boolean, masked_email text, code text, already_unsubscribed boolean)
language sql stable security definer set search_path = public, app as $$
  select true,
         left(o.to_address, 1) || '***' || substr(o.to_address, strpos(o.to_address, '@')),
         o.code,
         app.email_suppressed(o.to_address, true)
    from notification_outbox o where o.unsubscribe_token = p_token
  union all
  select false, null, null, false
   where not exists (select 1 from notification_outbox o where o.unsubscribe_token = p_token)
$$;

-- The click (also the List-Unsubscribe-Post request). Stops all marketing to the address and the
-- account; transactional emails continue. Idempotent.
create or replace function app.unsubscribe(p_token uuid, p_now timestamptz default now()) returns boolean
language plpgsql security definer set search_path = public, app as $$
declare
  o notification_outbox;
begin
  select * into o from notification_outbox where unsubscribe_token = p_token;
  if o.id is null then return false; end if;
  insert into email_suppressions (email, scope, reason, outbox_id, detail)
  values (o.to_address, 'marketing', 'unsubscribe', o.id, 'one-click link')
  on conflict (email, scope) where lifted_at is null do nothing;
  if o.recipient_user_id is not null then
    update users set marketing_opt_in = false, marketing_unsubscribed_at = p_now
     where id = o.recipient_user_id and (marketing_unsubscribed_at is null or marketing_opt_in);
    update consents set withdrawn_at = p_now
     where user_id = o.recipient_user_id and consent_code = 'marketing' and withdrawn_at is null;
  end if;
  update notification_outbox set status = 'suppressed', status_reason = 'unsubscribed'
   where to_address = o.to_address and category = 'marketing' and status in ('queued', 'delayed');
  return true;
end $$;

-- ================================================================ 9. app functions (signed-in users)
create or replace function app.my_notifications(p_limit integer default 50, p_unread_only boolean default false)
returns setof notifications
language sql stable security definer set search_path = public, app as $$
  select * from notifications
   where user_id = app.uid() and (not p_unread_only or read_at is null)
   order by created_at desc limit least(greatest(coalesce(p_limit, 50), 1), 200)
$$;

-- Mark the given notices read (all of mine when no ids are given). Returns how many changed.
create or replace function app.mark_notifications_read(p_ids uuid[] default null) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  n integer;
begin
  if app.uid() is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  update notifications set read_at = now()
   where user_id = app.uid() and read_at is null and (p_ids is null or id = any (p_ids));
  get diagnostics n = row_count;
  return n;
end $$;

-- The codes that can reach me (by my roles), with my settings.
create or replace function app.my_notification_preferences()
returns table (code text, subject text, category text, user_can_mute boolean, email_enabled boolean, in_app_enabled boolean)
language sql stable security definer set search_path = public, app as $$
  select c.code, c.subject, c.category, c.user_can_mute,
         coalesce(p.email_enabled, true) or not c.user_can_mute, coalesce(p.in_app_enabled, true)
    from notification_catalogue c
    left join notification_preferences p on p.user_id = app.uid() and p.code = c.code
   where c.in_catalogue and c.is_enabled and app.uid() is not null
     and ((c.audience = 'renter' and app.has_role('renter'))
          or (c.audience = 'owner' and app.has_role('owner'))
          or (c.audience = 'investor' and exists (select 1 from investors i where i.user_id = app.uid()))
          or (c.audience = 'staff_admin' and app.is_admin())
          or (c.audience = 'staff_field' and app.is_field())
          or (c.audience like 'staff_va_%' and app.va_has(substr(c.audience, 10)))
          or (app.is_admin() and 'staff_admin' = any (c.also_sent_to))
          or exists (select 1 from unnest(c.also_sent_to) a where a like 'staff_va_%' and app.va_has(substr(a, 10))))
   order by c.code
$$;

create or replace function app.set_notification_preference(p_code text, p_email boolean, p_in_app boolean) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  c notification_catalogue;
begin
  if app.uid() is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  select * into c from notification_catalogue where code = p_code;
  if c.code is null then raise exception 'Unknown notification %', p_code using errcode = '22023'; end if;
  if not coalesce(p_email, true) and not c.user_can_mute then
    raise exception 'The email % cannot be turned off: it is about your booking, account or money', p_code using errcode = '23514';
  end if;
  insert into notification_preferences (user_id, code, email_enabled, in_app_enabled)
  values (app.uid(), p_code, coalesce(p_email, true), coalesce(p_in_app, true))
  on conflict (user_id, code) do update set email_enabled = excluded.email_enabled, in_app_enabled = excluded.in_app_enabled;
end $$;

-- ================================================================ 10. row-level security
do $$
declare t text;
begin
  foreach t in array array['notification_link_paths', 'notification_catalogue', 'notification_outbox', 'staff_digest_items',
                           'notifications', 'notification_preferences', 'email_suppressions', 'marketing_sends'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy admin_all on public.%I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
  end loop;
end $$;
create policy staff_read on notification_catalogue for select to authenticated using (app.is_va() or app.is_field());
create policy staff_read on notification_link_paths for select to authenticated using (app.is_va() or app.is_field());
create policy role_read on staff_digest_items for select to authenticated using (role like 'va\_%' and app.va_has(substr(role, 4)));
create policy self_read on notifications for select to authenticated using (user_id = app.uid());
create policy self_read on notification_preferences for select to authenticated using (user_id = app.uid());
create policy staff_read on email_suppressions for select to authenticated using (app.va_has('cs', 'finance'));

revoke all on notification_link_paths, notification_catalogue, notification_outbox, staff_digest_items, notifications,
              notification_preferences, email_suppressions, marketing_sends from anon, authenticated;
grant select on notification_link_paths, notification_catalogue, staff_digest_items, notifications, notification_preferences,
                email_suppressions to authenticated;
grant select, insert, update on notification_outbox, marketing_sends to authenticated;   -- admins only, by policy
grant insert, update on notification_link_paths, notification_catalogue, staff_digest_items, email_suppressions to authenticated; -- admins only, by policy
grant all on notification_link_paths, notification_catalogue, notification_outbox, staff_digest_items, notifications,
             notification_preferences, email_suppressions, marketing_sends to service_role;

-- functions: the server and the scheduler run the layer; a browser runs only its own notices
revoke all on function
  app.notification_catalogue_refresh(), app.has_marketing_consent(uuid, text), app.email_suppressed(text, boolean),
  app.notification_payload(text, app_events, jsonb), app.notification_recipients(app_events, notification_catalogue),
  app.digest_line(notification_catalogue, jsonb), app.notification_url(notification_catalogue, jsonb),
  app.process_events(integer, timestamptz), app.job_notify_events(timestamptz), app.outbox_sent_today(timestamptz),
  app.outbox_claim(integer, timestamptz), app.outbox_mark_sent(uuid, text, text, timestamptz),
  app.outbox_mark_failed(uuid, text, boolean, timestamptz), app.outbox_record_bounce(text, text, text, text),
  app.unsubscribe_token_info(uuid), app.unsubscribe(uuid, timestamptz),
  app.my_notifications(integer, boolean), app.mark_notifications_read(uuid[]), app.my_notification_preferences(),
  app.set_notification_preference(text, boolean, boolean)
  from public, anon, authenticated;
grant execute on function app.my_notifications(integer, boolean), app.mark_notifications_read(uuid[]),
  app.my_notification_preferences(), app.set_notification_preference(text, boolean, boolean) to authenticated;
grant execute on function app.fmt_money(numeric), app.fmt_date(timestamptz), app.fmt_day(date), app.fmt_time(timestamptz),
  app.fmt_at(timestamptz), app.fmt_datetime(timestamptz), app.fmt_km(numeric), app.fmt_pct(integer), app.render_text(text, jsonb)
  to authenticated;
grant execute on all functions in schema app to service_role;

-- ================================================================ 11. schedule (pg_cron, 0015 pattern)
do $$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron is not available here: no jobs scheduled';
    return;
  end if;
  begin
    create extension if not exists pg_cron;
  exception when others then
    raise warning 'pg_cron could not be created in this database (%): no jobs scheduled', sqlerrm;
    return;
  end;
  perform cron.schedule('carmacars-notify-events', '* * * * *', 'select app.job_notify_events()');
end $$;

-- ================================================================ 12. audit
do $$ begin perform app.attach_audit(); end $$;
