-- 3260_r48rw_notify_prefs.sql
-- Release 48, part RW (rewards, content calendar, notifications; docs/changes/2026-11-20-r48-rewards-calendar-notify.md).
-- The owner, Nov 20 13:03: "EVERYONE can customise their notifications: renters, owners, staff, investors, partners,
-- Admin. One Notifications page per portal (and in the native app): each notification type x channel (push / email /
-- text) on/off, quiet hours, instant vs daily digest vs weekly summary. Locked (can't be turned off): security/sign-in
-- codes, legal and agreement notices, charge/fee notices (needed as dispute evidence), payment receipts, booking
-- confirmations/changes, return reminders. For staff: jobs/shifts assigned to them and onboarding/suspension notices.
-- The text channel respects the Quo credit fallback (it falls back to email). Defaults stay as they are today. Existing
-- per-person settings (Dwight's notifications off, the owners' no-new-booking rule) migrate into it."
--
--   1. notify_types: the kinds of notification a person can switch (about ten a portal, not the 240 codes). Every
--      catalogue code and every staff alert rule belongs to one (notification_catalogue.pref_type,
--      staff_alert_rules.pref_type). A locked type is always sent on every channel it has.
--   2. notify_prefs: a person's (or a partner's) switch per type and channel. No row: the type's default.
--      notify_profiles: quiet hours, instant / daily / weekly, and "every optional notification off".
--   3. Three triggers hold the choice where messages are queued, whatever queued them: the email outbox, the phone
--      alert outbox and the text outbox. The notice in the portal (the bell, Messages) always stays, so nothing is lost.
--      A text that cannot go still falls back to email (3113: text_fell_back is a locked type).
--   4. Daily or weekly: the optional emails of the period are held as lines (notify_digest_items) and sent as one
--      summary (notify_summary) by app.job_notify_digest.
--   5. Migrated: Dwight Laird's staff_notices_off becomes "every optional notification off" (his assigned jobs and
--      onboarding or suspension notices are locked on, as for everyone); the three owner emails switched off in 2620
--      (a new booking, an Owner Booking confirmed, a booking changed) are on again in the catalogue and belong to the
--      type "New bookings on your cars", off by default, so no owner hears more than today until they choose to;
--      emails muted in notification_preferences (0018) and the phone alert topics a person removed (0300) carry over.
-- No applied migration is edited: functions are wrapped (name_pre3260) or replaced as noted.
set local check_function_bodies = off;

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- the person acting, for the audit log, in a function the server calls with the session's user (as app.door_begin does)
create function app.rw_act_as(p_user uuid) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if p_user is null then return; end if;
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  perform set_config('request.jwt.claims', (coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb || jsonb_build_object('sub', p_user))::text, true);
end $$;

-- ================================================================ settings
alter table program_settings
  add column if not exists notify_pref_digest_hour smallint not null default 8 check (notify_pref_digest_hour between 0 and 23),
  add column if not exists notify_pref_weekly_dow smallint not null default 1 check (notify_pref_weekly_dow between 1 and 7),
  add column if not exists notify_pref_quiet_from_minute smallint not null default 1260 check (notify_pref_quiet_from_minute between 0 and 1439),
  add column if not exists notify_pref_quiet_until_minute smallint not null default 480 check (notify_pref_quiet_until_minute between 0 and 1439);
comment on column program_settings.notify_pref_digest_hour is 'Notification preferences (3260): the hour, Toronto time, the daily and weekly summaries go out.';
comment on column program_settings.notify_pref_weekly_dow is 'Notification preferences (3260): the weekday of the weekly summary (1 Monday to 7 Sunday).';
comment on column program_settings.notify_pref_quiet_from_minute is 'Notification preferences (3260): the quiet hours a person starts with when they turn them on, from this minute of the day (1260 = 9:00 pm).';
comment on column program_settings.notify_pref_quiet_until_minute is 'Notification preferences (3260): ... until this minute of the day (480 = 8:00 am).';

-- ================================================================ 1. the types
create table notify_types (
  code          text primary key check (code ~ '^[a-z][a-z0-9_]{2,40}$'),
  label         text not null check (length(label) between 3 and 80),
  detail        text check (detail is null or length(detail) <= 240),
  grp           text not null check (length(grp) between 2 and 60),
  portals       text[] not null default '{}',
  locked        boolean not null default false,
  channels      text[] not null default '{push,email,text}' check (channels <@ array['push', 'email', 'text']),
  push_default  boolean not null default true,
  email_default boolean not null default true,
  text_default  boolean not null default true,
  push_topic    text,
  live_setting  text,
  sort          integer not null default 100,
  updated_at    timestamptz not null default now(),
  check (portals <@ array['renter', 'owner', 'investor', 'staff', 'admin', 'partner'])
);
comment on table notify_types is 'Notification preferences (3260): the kinds of notification a person switches per channel. locked: always sent (security, legal, charges, receipts, bookings, returns; for staff assigned work and onboarding). portals: who sees it. live_setting: a Program settings switch the type waits for (the tracker alerts wait for trackers_available). The defaults are editable by an Admin.';
alter table notify_types enable row level security;
revoke all on notify_types from public, anon, authenticated;
grant all on notify_types to service_role;
create policy admin_all on notify_types for all to authenticated using (app.is_admin()) with check (app.is_admin());
create trigger notify_types_updated before update on notify_types for each row execute function app.set_updated_at();
create trigger audit_notify_types after insert or update or delete on notify_types for each row execute function app.audit_row();

insert into notify_types (code, label, detail, grp, portals, locked, channels, push_default, email_default, text_default, push_topic, sort) values
  -- always sent
  ('security', 'Security and sign-in codes', 'Sign-in links and codes, password resets, a change to your sign-in or bank details.', 'Always sent', '{renter,owner,investor,staff,admin}', true, '{email,text}', true, true, true, null, 10),
  ('legal', 'Legal and agreement notices', 'Agreements to sign and signed copies, notices your agreement requires, updated terms.', 'Always sent', '{renter,owner,investor,staff,admin,partner}', true, '{push,email,text}', true, true, true, 'documents', 11),
  ('charges', 'Charges and fees', 'Any charge or fee, a failed payment, a balance owing, an invoice. Kept as the record if a charge is ever disputed.', 'Always sent', '{renter,owner,partner}', true, '{push,email,text}', true, true, true, 'payments', 12),
  ('receipts', 'Receipts and payments', 'Receipts, refunds, deposits released, statements, payouts and pay statements.', 'Always sent', '{renter,owner,investor,staff,admin,partner}', true, '{push,email,text}', true, true, true, 'payments', 13),
  ('bookings', 'Booking confirmations and changes', 'Requests, offers, confirmations, changes, extensions, cancellations and what a booking still needs from you.', 'Always sent', '{renter}', true, '{push,email,text}', true, true, true, 'bookings', 14),
  ('returns', 'Pickup and return reminders', 'Pickup details, the trip start, the return reminder and the return details.', 'Always sent', '{renter}', true, '{push,email,text}', true, true, true, 'handovers', 15),
  ('safety', 'Safety, accidents and breakdowns', 'Accident and breakdown steps, a late return, a car that is disabled, an incident on your car.', 'Always sent', '{renter,owner}', true, '{push,email,text}', true, true, true, 'alerts', 16),
  ('staff_jobs', 'Jobs and shifts assigned to you', 'A job or a shift given to you or changed, today''s and tomorrow''s jobs, a job running late.', 'Always sent', '{staff,admin}', true, '{push,email,text}', true, true, true, 'handovers', 17),
  ('staff_onboarding', 'Onboarding, access and suspension', 'Your academy and agreement steps, an inactivity warning, access suspended or restored.', 'Always sent', '{staff,admin}', true, '{push,email,text}', true, true, true, null, 18),
  ('system', 'Delivery notices', 'A text that could not be sent and went by email instead, and your daily or weekly summary.', 'Always sent', '{}', true, '{email}', true, true, true, null, 19),
  -- renters
  ('messages', 'Messages from the team', 'A message from CarmaCars staff about your booking or account, and chat transcripts.', 'Messages', '{renter,owner,investor}', false, '{push,email,text}', true, true, true, 'messages', 30),
  ('rewards', 'Rewards, points and codes', 'Points earned, tier changes, your free day, discount codes and their reminders.', 'Rewards and offers', '{renter}', false, '{push,email,text}', true, true, true, null, 31),
  ('reviews', 'Review requests', 'A request to review your trip.', 'Rewards and offers', '{renter}', false, '{push,email,text}', true, true, true, null, 32),
  -- owners
  ('owner_new_bookings', 'New bookings on your cars', 'A booking confirmed on your car, your own booking confirmed, a confirmed booking changed. Off by default: many bookings change before the trip.', 'Your cars', '{owner}', false, '{push,email,text}', false, false, false, 'requests', 40),
  ('owner_trips', 'Trips completed', 'A trip on your car is complete and the car is back, with your share when it shows.', 'Your cars', '{owner}', false, '{push,email,text}', true, true, true, 'bookings', 41),
  ('owner_weekly', 'Weekly summary', 'Monday: last week''s trips, what is coming up and your month so far.', 'Your cars', '{owner}', false, '{push,email}', true, true, false, null, 42),
  ('owner_cars', 'Listing and onboarding steps', 'Your application, the steps to get a car listed, a car enrolled or listed, forms approved or sent back.', 'Your cars', '{owner}', false, '{push,email,text}', true, true, true, 'documents', 43),
  ('owner_rewards', 'Owner rewards', 'A discount or upgrade you can use, a friend who used your code, a credit, a merch kit to redeem or on its way.', 'Rewards', '{owner}', false, '{push,email,text}', true, true, false, null, 44),
  -- investors
  ('investor_updates', 'Updates and notices', 'Updates from CarmaCars and a notice we received from you.', 'Updates', '{investor}', false, '{push,email,text}', true, true, true, 'messages', 50),
  -- staff and Admins (the groups of Alerts, 0462)
  ('staff_leads', 'Leads and visitors', 'A new lead, an unfinished request, a hot visitor.', 'Work alerts', '{staff,admin}', false, '{push,email,text}', true, true, true, 'leads', 60),
  ('staff_bookings', 'Requests and bookings', 'Booking requests, offers answered, changes, extensions, cars out and back.', 'Work alerts', '{staff,admin}', false, '{push,email,text}', true, true, true, 'requests', 61),
  ('staff_money', 'Money', 'Payments, deposits, refunds, invoices and payouts to handle.', 'Work alerts', '{staff,admin}', false, '{push,email,text}', true, true, true, 'payments', 62),
  ('staff_customers', 'Customers and reviews', 'Messages, chats, reviews and complaints.', 'Work alerts', '{staff,admin}', false, '{push,email,text}', true, true, true, 'messages', 63),
  ('staff_documents', 'Documents', 'Licences to review, agreements signed or waiting, insurance pages.', 'Work alerts', '{staff,admin}', false, '{push,email,text}', true, true, true, 'documents', 64),
  ('staff_fleet', 'Fleet, cars and field work', 'Tracker and fleet alerts, listings, tolls, field jobs started and done.', 'Work alerts', '{staff,admin}', false, '{push,email,text}', true, true, true, 'alerts', 65),
  ('staff_system', 'Site, staff and system', 'Site health, usage, sending limits, staff and hiring notices.', 'Work alerts', '{staff,admin}', false, '{push,email,text}', true, true, true, 'alerts', 66),
  ('staff_sent', 'Copies of messages sent to customers', 'The record of what a renter, owner or investor was sent.', 'Work alerts', '{admin}', false, '{push,email}', true, true, false, 'alerts', 67),
  ('staff_digests', 'Digests and summaries', 'The morning and end-of-day digests and the weekly summary.', 'Summaries', '{staff,admin}', false, '{email}', true, true, false, null, 68),
  ('staff_marketing', 'Content calendar and social posts', 'A month''s calendar ready to approve, a post to publish by hand, a post that failed.', 'Work alerts', '{staff,admin}', false, '{push,email,text}', true, true, false, 'alerts', 69),
  ('staff_rewards', 'My rewards', 'A perk unlocked, a free day earned or about to end, a new tier, top seller of the month.', 'Rewards', '{staff,admin}', false, '{push,email,text}', true, true, false, null, 70)
on conflict (code) do nothing;

-- the owner's tracker alerts (13:02): real-time ones and the weekly driving summary, each its own switch; the critical
-- ones on, the rest off. They wait for trackers_available (Program settings).
insert into notify_types (code, label, detail, grp, portals, locked, channels, push_default, email_default, text_default, push_topic, live_setting, sort) values
  ('tracker_theft', 'Possible theft', 'Your car is far outside its area, or moving with no active booking.', 'Tracker alerts', '{owner}', false, '{push,email,text}', true, true, true, 'alerts', 'trackers_available', 80),
  ('tracker_tamper', 'Tracker disconnected or tampered with', 'The tracker was unplugged, lost power or stopped reporting.', 'Tracker alerts', '{owner}', false, '{push,email,text}', true, true, true, 'alerts', 'trackers_available', 81),
  ('tracker_crash', 'Crash or impact', 'The tracker felt an impact.', 'Tracker alerts', '{owner}', false, '{push,email,text}', true, true, true, 'alerts', 'trackers_available', 82),
  ('tracker_place', 'At an impound lot, auto shop or shipping port', 'Your car stopped at a place of that kind.', 'Tracker alerts', '{owner}', false, '{push,email,text}', true, true, true, 'alerts', 'trackers_available', 83),
  ('tracker_health', 'Vehicle health warning', 'A warning light or a battery warning the tracker read from the car.', 'Tracker alerts', '{owner}', false, '{push,email,text}', false, false, false, 'alerts', 'trackers_available', 84),
  ('tracker_speed', 'Over 180 km/h', 'Your car was driven over 180 km/h.', 'Tracker alerts', '{owner}', false, '{push,email,text}', false, false, false, 'alerts', 'trackers_available', 85),
  ('tracker_weekly', 'Weekly driving summary', 'Speeding, hard braking and acceleration, late-night driving, and kilometres against the allowance.', 'Tracker alerts', '{owner}', false, '{push,email}', false, false, false, null, 'trackers_available', 86)
on conflict (code) do nothing;

-- ================================================================ each code and each alert rule belongs to a type
alter table notification_catalogue add column if not exists pref_type text references notify_types (code) on update cascade on delete set null;
create index if not exists notification_catalogue_pref_type_idx on notification_catalogue (pref_type) where pref_type is not null;
comment on column notification_catalogue.pref_type is 'Notification preferences (3260): the type a person switches this code with. Empty: not governed (an applicant, an insurer, marketing with its own consent).';
alter table staff_alert_rules add column if not exists pref_type text references notify_types (code) on update cascade on delete set null;
create index if not exists staff_alert_rules_pref_type_idx on staff_alert_rules (pref_type) where pref_type is not null;
comment on column staff_alert_rules.pref_type is 'Notification preferences (3260): the type a staff member switches this alert with.';

-- the catalogue's codes by what they are (one pass each; the first that fits wins, so the order is the rule)
create function app.notify_type_guess(c notification_catalogue) returns text
language sql immutable as $$
  select case
    when c.audience in ('applicant', 'insurer') or c.code ~ '^(marketing_|renter_comeback|renter_recovery_request|owner_recruit)' then null
    when c.code in ('text_fell_back', 'notify_summary') then 'system'
    when c.code ~ '(password_reset|security_notice|sign_in_link|signing_code|accounts_merged|bank_details_changed)' then 'security'
    -- staff
    when c.code ~ '^staff_(field_job|not_back$|pickup_unrecorded$)' then 'staff_jobs'
    when c.code ~ '^staff_(access_|agreement_reminder|inactivity_warning|team_group)' then 'staff_onboarding'
    when c.code ~ '^staff_(pay_statement|commission_)' then 'receipts'
    when c.code ~ '^staff_(digest_|weekly_summary|seo_digest|alert_digest)' then 'staff_digests'
    when c.code ~ '^staff_(lead_new|owner_lead_new|hot_visitor|request_unfinished)' then 'staff_leads'
    when c.code ~ '^staff_reward' then 'staff_rewards'
    when c.code ~ '^staff_social' then 'staff_marketing'
    when c.code in ('staff_alert_urgent', 'staff_alert_normal') then null
    when c.audience = 'staff_va_finance' or (c.audience like 'staff%' and c.push_topic = 'payments') or c.code ~ '^staff_(payouts|owner_debit|monthly_statements|statements_ready|deposit_)' then 'staff_money'
    when c.code ~ '^staff_(chat_|renter_replied|review_received)' then 'staff_customers'
    when c.code ~ '^staff_(identity_review|owner_form_uploaded)' then 'staff_documents'
    when c.audience = 'staff_va_fleet' or c.code ~ '^staff_(tracker_alert|incident_reported|fleet_count)' then 'staff_fleet'
    when c.audience in ('staff_va_cs', 'staff_va_sales') or c.code ~ '^staff_(approval_needed|disable_approval|dispute_opened)' then 'staff_bookings'
    when c.audience like 'staff%' then 'staff_system'
    -- everyone else
    when c.code ~ '(agreement|cosigner_sign|document_to_sign|schedule_resign|fee_change|mode_change|exit_|named_to_authority)' then 'legal'
    when c.code ~ '(accident|breakdown|vehicle_disabled|late_return|return_due|incident_)' then 'safety'
    when c.code ~ '(extra_charge|damage_found|balance_overdue|payment_failed|deposit_declined|fee_invoice|invoice_issued|upfront_invoice|debit_notice|debit_returned|debit_setup|pad_confirmed|in_arrears|toll_ticket|partner_invoice|return_claim_denied)' then 'charges'
    when c.code ~ '(payment_receipt|refund_issued|deposit_released|final_statement|payment_received|payment_recorded|payment_reversed|invoice_voided|return_paid|payout_sent|statement_ready)' then 'receipts'
    when c.code ~ '^owner_(new_booking|booking_confirmed|booking_changed)$' then 'owner_new_bookings'
    when c.code = 'owner_trip_completed' then 'owner_trips'
    when c.code = 'owner_weekly_summary' then 'owner_weekly'
    when c.code ~ '^owner_reward' then 'owner_rewards'
    when c.code = 'owner_tracker_weekly' then 'tracker_weekly'
    when c.code = 'owner_tracker_alert' then null
    when c.audience = 'owner' then 'owner_cars'
    when c.audience = 'investor' then 'investor_updates'
    when c.code ~ '(staff_message|chat_transcript)' then 'messages'
    when c.code ~ '^renter_(rewards_|game_code|promo_)' then 'rewards'
    when c.code ~ '^renter_(review_|google_review)' then 'reviews'
    when c.code ~ '^renter_(return_|pickup_|booking_reminder|trip_|rental_started)' then 'returns'
    when c.audience = 'renter' then 'bookings'
    when c.audience = 'partner' then 'charges'
  end
$$;
update notification_catalogue c set pref_type = app.notify_type_guess(c) where pref_type is null and app.notify_type_guess(c) is not null;
-- a code added later takes its type the same way unless its migration names one
create function app.notify_type_default() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.pref_type is null then new.pref_type := app.notify_type_guess(new); end if;
  return new;
end $$;
create trigger notification_catalogue_pref_type before insert on notification_catalogue for each row execute function app.notify_type_default();

update staff_alert_rules r set pref_type = case
    when r.rule in ('job_assigned', 'job_late') or r.rule like 'shift_%' then 'staff_jobs'
    when r.rule like 'sent:%' then 'staff_sent'
    when r.grp = 'Leads' then 'staff_leads'
    when r.grp = 'Money' then 'staff_money'
    when r.grp = 'Bookings' then 'staff_bookings'
    when r.grp = 'Customers' then 'staff_customers'
    when r.grp = 'Documents' then 'staff_documents'
    when r.grp in ('Fleet and cars', 'Field work') then 'staff_fleet'
    when r.rule ~ '^(townhall|interview|staff_restore|onboarding)' then 'staff_onboarding'
    else 'staff_system' end
 where pref_type is null;

-- the three owner emails of 2620 are on again, behind the type that is off by default (the same silence as today)
update notification_catalogue set is_enabled = true
 where code in ('owner_new_booking', 'owner_booking_confirmed', 'owner_booking_changed') and not is_enabled;

-- ================================================================ 2. a person's choices
create table notify_prefs (
  subject_kind text not null check (subject_kind in ('user', 'partner')),
  subject_id   uuid not null,
  type         text not null references notify_types (code) on update cascade on delete cascade,
  push         boolean not null,
  email        boolean not null,
  sms          boolean not null,
  updated_at   timestamptz not null default now(),
  updated_by   uuid references users (id) on delete set null,
  primary key (subject_kind, subject_id, type)
);
create index notify_prefs_type_idx on notify_prefs (type);
comment on table notify_prefs is 'Notification preferences (3260): a person''s (subject_kind user) or a referral partner''s (partner) switch per type and channel. No row: the type''s defaults. A locked type has no row.';
create table notify_profiles (
  subject_kind text not null check (subject_kind in ('user', 'partner')),
  subject_id   uuid not null,
  quiet_on     boolean not null default false,
  quiet_from   smallint not null default 1260 check (quiet_from between 0 and 1439),
  quiet_until  smallint not null default 480 check (quiet_until between 0 and 1439),
  cadence      text not null default 'instant' check (cadence in ('instant', 'daily', 'weekly')),
  all_off      boolean not null default false,
  digest_sent_at timestamptz,
  updated_at   timestamptz not null default now(),
  updated_by   uuid references users (id) on delete set null,
  primary key (subject_kind, subject_id)
);
comment on table notify_profiles is 'Notification preferences (3260): quiet hours (minutes of the day, Toronto; phone alerts and texts of optional types wait for the end), instant or a daily or weekly summary of the optional emails, and every optional notification off. Locked types ignore all three.';
create table notify_digest_items (
  id         bigserial primary key,
  user_id    uuid not null references users (id) on delete cascade,
  type       text references notify_types (code) on update cascade on delete set null,
  code       text not null,
  title      text not null,
  url        text,
  created_at timestamptz not null default now(),
  sent_at    timestamptz
);
create index notify_digest_items_user_idx on notify_digest_items (user_id, created_at) where sent_at is null;
create index notify_digest_items_type_idx on notify_digest_items (type) where type is not null;
comment on table notify_digest_items is 'Notification preferences (3260): the optional emails held for a person on a daily or weekly summary, one line each, until the summary carries them.';
do $$
declare t text;
begin
  foreach t in array array['notify_prefs', 'notify_profiles', 'notify_digest_items'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from public, anon, authenticated', t);
    execute format('grant all on %I to service_role', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
  end loop;
end $$;
grant usage on sequence notify_digest_items_id_seq to service_role;
revoke all on sequence notify_digest_items_id_seq from public, anon, authenticated;
create trigger notify_prefs_updated before update on notify_prefs for each row execute function app.set_updated_at();
create trigger notify_profiles_updated before update on notify_profiles for each row execute function app.set_updated_at();
create trigger audit_notify_prefs after insert or update or delete on notify_prefs for each row execute function app.audit_row();
create trigger audit_notify_profiles after insert or update or delete on notify_profiles for each row execute function app.audit_row();

-- ================================================================ reading a choice
-- the portals a person has (a staff member who is also a renter sees each portal's types on that portal's page)
create function app.notify_portals(p_user uuid) returns text[]
language sql stable security definer set search_path = public, app as $$
  select array_remove(array[
    case when exists (select 1 from user_roles r where r.user_id = p_user and r.role::text = 'admin') then 'admin' end,
    case when exists (select 1 from user_roles r where r.user_id = p_user and r.role::text in ('va', 'field')) then 'staff' end,
    case when exists (select 1 from owners o where o.user_id = p_user) or exists (select 1 from user_roles r where r.user_id = p_user and r.role::text = 'owner') then 'owner' end,
    case when exists (select 1 from investors i where i.user_id = p_user) then 'investor' end,
    case when exists (select 1 from renters x where x.user_id = p_user) or exists (select 1 from user_roles r where r.user_id = p_user and r.role::text = 'renter') then 'renter' end], null)
$$;
create function app.notify_is_staff(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from user_roles r where r.user_id = p_user and r.role::text in ('admin', 'va', 'field'))
$$;

-- the type of one message: its catalogue code, or for a staff alert its rule
create function app.notify_type_of(p_code text, p_rule text default null) returns text
language sql stable security definer set search_path = public, app as $$
  select case when p_code like 'staff_alert_%' and nullif(p_rule, '') is not null
              then coalesce((select r.pref_type from staff_alert_rules r where r.rule = p_rule), 'staff_system')
              -- an owner's tracker alert carries its own type (3264: tracker_theft, tracker_crash, ...)
              when p_code = 'owner_tracker_alert' then (select t.code from notify_types t where t.code = p_rule)
              else (select c.pref_type from notification_catalogue c where c.code = p_code) end
$$;

-- a type that waits for a Program settings switch (the tracker alerts) is not live until the switch is on
create function app.notify_type_live(t notify_types) returns boolean
language sql stable security definer set search_path = public, app as $$
  select t.live_setting is null or coalesce((to_jsonb(app.settings()) ->> t.live_setting)::boolean, false)
$$;

-- the choice in force for one subject and type: locked is always on; "all off" turns every optional one off
create function app.notify_pref_of(p_kind text, p_id uuid, p_type text, out push boolean, out email boolean, out sms boolean, out locked boolean, out cadence text, out known boolean)
language plpgsql stable security definer set search_path = public, app as $$
declare
  t notify_types;
  p notify_prefs;
  f notify_profiles;
begin
  select * into t from notify_types where code = p_type;
  if t.code is null or p_id is null then
    push := true; email := true; sms := true; locked := true; cadence := 'instant'; known := false;
    return;
  end if;
  known := true;
  locked := t.locked;
  if t.locked then push := true; email := true; sms := true; cadence := 'instant'; return; end if;
  select * into p from notify_prefs x where x.subject_kind = p_kind and x.subject_id = p_id and x.type = p_type;
  select * into f from notify_profiles x where x.subject_kind = p_kind and x.subject_id = p_id;
  cadence := coalesce(f.cadence, 'instant');
  if coalesce(f.all_off, false) then push := false; email := false; sms := false; return; end if;
  push := coalesce(p.push, t.push_default) and 'push' = any (t.channels);
  email := coalesce(p.email, t.email_default) and 'email' = any (t.channels);
  sms := coalesce(p.sms, t.text_default) and 'text' = any (t.channels);
end $$;

-- the quiet hours of a subject: staff keep the quiet hours of Alerts (0466: on by default, 9:00 pm to 8:00 am);
-- everyone else their own (off until they turn them on)
create function app.notify_quiet_of(p_kind text, p_id uuid, out quiet_on boolean, out quiet_from integer, out quiet_until integer)
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  f notify_profiles;
  a staff_alert_prefs;
begin
  if p_kind = 'user' and app.notify_is_staff(p_id) then
    select * into a from staff_alert_prefs where user_id = p_id;
    quiet_on := coalesce(a.quiet_on, true); quiet_from := coalesce(a.quiet_from, 1260); quiet_until := coalesce(a.quiet_until, 480);
    return;
  end if;
  select * into f from notify_profiles x where x.subject_kind = p_kind and x.subject_id = p_id;
  quiet_on := coalesce(f.quiet_on, false);
  quiet_from := coalesce(f.quiet_from, s.notify_pref_quiet_from_minute);
  quiet_until := coalesce(f.quiet_until, s.notify_pref_quiet_until_minute);
end $$;

-- when the quiet hours of a subject end (p_at itself outside them)
create function app.notify_quiet_end(p_kind text, p_id uuid, p_at timestamptz default now()) returns timestamptz
language plpgsql stable security definer set search_path = public, app as $$
declare
  q record;
  v_local timestamp := p_at at time zone 'America/Toronto';
  v_min integer := extract(hour from v_local)::integer * 60 + extract(minute from v_local)::integer;
  v_in boolean;
  v_day date := v_local::date;
begin
  select * into q from app.notify_quiet_of(p_kind, p_id);
  if not q.quiet_on or q.quiet_from = q.quiet_until then return p_at; end if;
  v_in := case when q.quiet_from > q.quiet_until then v_min >= q.quiet_from or v_min < q.quiet_until else v_min >= q.quiet_from and v_min < q.quiet_until end;
  if not v_in then return p_at; end if;
  if q.quiet_from > q.quiet_until and v_min >= q.quiet_from then v_day := v_day + 1; end if;
  return (v_day::timestamp + make_interval(mins => q.quiet_until)) at time zone 'America/Toronto';
end $$;

-- ================================================================ 3. the three outboxes hold the choice
-- the email: off, or held for the summary; the text it planned: off
create function app.notify_pref_outbox() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_user uuid := coalesce(new.recipient_user_id, (app.notify_who(new) ->> 'user_id')::uuid);
  v_type text;
  f record;
  c notification_catalogue;
begin
  if v_user is null then return new; end if;
  -- a staff alert's rule and an owner tracker alert's type are on the event (the email's own values are its template's)
  v_type := app.notify_type_of(new.code, coalesce(new.payload ->> 'rule', (select e.payload ->> 'rule' from app_events e where e.id = new.event_id)));
  if v_type is null then return new; end if;
  select * into f from app.notify_pref_of('user', v_user, v_type);
  if f.locked then return new; end if;
  -- the text
  if new.sms_planned and (not f.sms or f.cadence <> 'instant') then
    new.sms_planned := false;
    if new.status = 'skipped' and coalesce(new.status_reason, '') like 'Sent by text%' then
      new.status := 'queued'; new.status_reason := null;
    end if;
  end if;
  if new.status not in ('queued', 'delayed') then return new; end if;
  if not f.email then
    -- a kind that starts off on every channel and that this person left off: no row at all, as before 3260
    if not f.push and not f.sms and exists (select 1 from notify_types t where t.code = v_type and not t.push_default and not t.email_default and not t.text_default) then
      return null;
    end if;
    new.status := 'suppressed';
    new.status_reason := 'not sent: turned off in notification preferences';
  elsif f.cadence <> 'instant' then
    select * into c from notification_catalogue where code = new.code;
    insert into notify_digest_items (user_id, type, code, title, url)
    values (v_user, v_type, new.code, left(coalesce(nullif(app.render_text(c.subject, new.payload), ''), c.code), 200), app.notification_url(c, new.payload));
    new.status := 'suppressed';
    new.status_reason := 'not sent: in the ' || f.cadence || ' summary';
  end if;
  return new;
end $$;
-- by its name it runs after the channel is chosen (notification_outbox_route) and before a staff email is moved into the
-- person's email digest (notification_outbox_staff_digest), so an email switched off is in neither
create trigger notification_outbox_staff_a_prefs before insert on notification_outbox for each row execute function app.notify_pref_outbox();

-- the phone alert: off, on a summary, or held to the end of the quiet hours (an urgent staff alert still goes at once)
create function app.notify_pref_push() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_type text;
  f record;
  v_rule text;
begin
  if (new.code like 'staff_alert_%' or new.code = 'owner_tracker_alert') and new.notification_id is not null then
    select e.payload ->> 'rule' into v_rule from notifications n join app_events e on e.id = n.event_id where n.id = new.notification_id;
  end if;
  v_type := app.notify_type_of(new.code, v_rule);
  if v_type is null then return new; end if;
  select * into f from app.notify_pref_of('user', new.user_id, v_type);
  if f.locked then return new; end if;
  if not f.push or f.cadence <> 'instant' then return null; end if;
  if not new.urgent then new.send_after := greatest(new.send_after, app.notify_quiet_end('user', new.user_id, new.send_after)); end if;
  return new;
end $$;
create trigger push_outbox_prefs before insert on push_outbox for each row execute function app.notify_pref_push();

-- the text: a notice to a renter, owner or investor (its email's person), or a staff alert by text (the person of the number)
create function app.notify_pref_text() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_user uuid := new.user_id;
  v_type text;
  v_code text := new.sms_kind;
  f record;
  n notification_outbox;
begin
  if new.status <> 'queued' or new.kind not in ('notify', 'staff') or new.sent_by is not null then return new; end if;
  if new.notification_id is not null then
    select * into n from notification_outbox where id = new.notification_id;
    v_user := coalesce(v_user, n.recipient_user_id, (app.notify_who(n) ->> 'user_id')::uuid);
    v_code := coalesce(n.code, v_code);
  elsif v_user is null and new.kind = 'staff' then
    select u.id into v_user from users u
     where u.phone = new.to_number and exists (select 1 from user_roles r where r.user_id = u.id and r.role::text in ('admin', 'va', 'field'))
     order by u.created_at limit 1;
  end if;
  if v_user is null or v_code is null then return new; end if;
  v_type := app.notify_type_of(v_code, case when v_code like 'staff_alert_%' or v_code = 'owner_tracker_alert' then coalesce(n.payload ->> 'rule', (select e.payload ->> 'rule' from app_events e where e.id = n.event_id)) end);
  if v_type is null then return new; end if;
  select * into f from app.notify_pref_of('user', v_user, v_type);
  if f.locked then return new; end if;
  if not f.sms or f.cadence <> 'instant' then
    new.status := 'skipped';
    new.status_reason := 'not sent: the email already covers it (text turned off in notification preferences)';
    return new;
  end if;
  if not coalesce(new.urgent, false) then new.send_after := greatest(new.send_after, app.notify_quiet_end('user', v_user, new.send_after)); end if;
  return new;
end $$;
create trigger phone_outbox_zzz_prefs before insert on phone_outbox for each row execute function app.notify_pref_text();

-- ================================================================ 4. the daily and weekly summary
insert into notification_catalogue (code, audience, category, subject, preheader, timing, trigger_text, link_path, variables, template_html, template_text, emitted_by, no_text, pref_type, priority)
values ('notify_summary', 'renter', 'transactional', 'Your {{period_word}} CarmaCars summary: {{count_words}}', 'What happened since your last summary.',
        'Daily or weekly, the person''s choice', 'A person chose a daily or weekly summary in their notification preferences (3260): the optional emails of the period, one line each.',
        '/account/profile?tab=notifications',
        '[{"name":"first_name","type":"string"},{"name":"period_word","type":"string"},{"name":"count_words","type":"string"},{"name":"items","type":"list","fields":["title","when","url"]},{"name":"prefs_url","type":"url"}]'::jsonb,
        'templates/notify_summary.html', 'templates/notify_summary.txt', 'app.job_notify_digest (3260)', true, 'system', 4)
on conflict (code) do nothing;

create function app.notify_prefs_path(p_user uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case app.push_role(p_user)
    when 'admin' then '/admin/settings/profile#notifications'
    when 'staff' then '/staff/profile#notifications'
    when 'field' then '/staff/field/profile#notifications'
    when 'owner' then '/owner/account?tab=notifications'
    when 'investor' then '/investor/profile#notifications'
    else '/account/profile?tab=notifications' end
$$;

create function app.job_notify_digest(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_hour integer := app.local_hour(p_now);
  v_dow integer := extract(isodow from (p_now at time zone 'America/Toronto'))::integer;
  v_day date := app.local_date(p_now);
  r record;
  v_items jsonb;
  v_n integer;
  v_sent integer := 0;
  v_first text;
  v_base text := rtrim(s.notify_base_url, '/');
begin
  if v_hour < s.notify_pref_digest_hour then return 0; end if;
  for r in
    select f.subject_id as user_id, f.cadence from notify_profiles f
     where f.subject_kind = 'user' and f.cadence in ('daily', 'weekly')
       and (f.cadence = 'daily' or v_dow = s.notify_pref_weekly_dow)
       and (f.digest_sent_at is null or app.local_date(f.digest_sent_at) < v_day)
       and exists (select 1 from notify_digest_items i where i.user_id = f.subject_id and i.sent_at is null)
     for update of f skip locked
  loop
    select jsonb_agg(jsonb_build_object('title', x.title, 'when', app.fmt_at(x.created_at),
                                        'url', case when x.url like 'http%' then x.url else v_base || coalesce(nullif(x.url, ''), app.notify_prefs_path(r.user_id)) end) order by x.created_at), count(*)
      into v_items, v_n
      from (select * from notify_digest_items i where i.user_id = r.user_id and i.sent_at is null order by i.created_at limit 60) x;
    select coalesce(nullif(btrim(u.greeting_name), ''), nullif(split_part(btrim(coalesce(u.full_name, '')), ' ', 1), ''), 'there') into v_first from users u where u.id = r.user_id;
    perform app.emit_event('notify_summary', 'user', r.user_id, jsonb_build_object(
      'signer_user_id', r.user_id, 'signer_name', v_first, 'first_name', v_first, '_email_only', true,
      'period_word', case r.cadence when 'weekly' then 'weekly' else 'daily' end,
      'count_words', case when v_n = 1 then '1 update' else v_n || ' updates' end,
      'items', v_items, 'prefs_url', v_base || app.notify_prefs_path(r.user_id)),
      'notify_summary:' || r.user_id || ':' || to_char(v_day, 'YYYYMMDD'));
    update notify_digest_items set sent_at = p_now where user_id = r.user_id and sent_at is null;
    update notify_profiles set digest_sent_at = p_now where subject_kind = 'user' and subject_id = r.user_id;
    v_sent := v_sent + 1;
  end loop;
  -- a person back on instant: the lines held for them are dropped (the notices are in the portal)
  update notify_digest_items i set sent_at = p_now
   where i.sent_at is null and not exists (select 1 from notify_profiles f where f.subject_kind = 'user' and f.subject_id = i.user_id and f.cadence <> 'instant');
  return v_sent;
end $$;

-- ================================================================ the page: what a person sees and saves
create function app.notify_prefs_state(p_kind text, p_id uuid, p_portal text default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_portals text[];
  v_portal text;
  f notify_profiles;
  q record;
  r jsonb := '{}'::jsonb;
  v_staff boolean := false;
  v_groups jsonb;
  v_devices integer := 0;
begin
  if p_kind = 'partner' then
    if not exists (select 1 from referral_partners x where x.id = p_id) then raise exception 'Unknown partner' using errcode = 'P0002'; end if;
    v_portals := array['partner']; v_portal := 'partner';
  else
    if not exists (select 1 from users u where u.id = p_id) then raise exception 'Unknown person' using errcode = 'P0002'; end if;
    v_portals := app.notify_portals(p_id);
    v_portal := case when p_portal = any (v_portals) then p_portal
                     when p_portal = 'staff' and 'admin' = any (v_portals) then 'admin'
                     else coalesce(v_portals[1], 'renter') end;
    v_staff := app.notify_is_staff(p_id);
    r := app.notify_reach(p_id, null, null);
    select count(*) into v_devices from push_subscriptions ps where ps.user_id = p_id;
  end if;
  select * into f from notify_profiles x where x.subject_kind = p_kind and x.subject_id = p_id;
  select * into q from app.notify_quiet_of(p_kind, p_id);
  select coalesce(jsonb_agg(g.obj order by g.ord), '[]'::jsonb) into v_groups from (
    select jsonb_build_object('name', t.grp, 'locked', bool_and(t.locked),
             'types', jsonb_agg(jsonb_build_object('code', t.code, 'label', t.label, 'detail', t.detail, 'locked', t.locked, 'channels', to_jsonb(t.channels),
                        'live', app.notify_type_live(t), 'push', x.push, 'email', x.email, 'text', x.sms) order by t.sort, t.code)) as obj,
           min(t.sort) as ord
      from notify_types t cross join lateral app.notify_pref_of(p_kind, p_id, t.code) x
     where v_portal = any (t.portals)
     group by t.grp) g;
  return jsonb_build_object(
    'kind', p_kind, 'portal', v_portal, 'portals', to_jsonb(v_portals), 'staff', v_staff,
    'profile', jsonb_build_object('quiet_on', q.quiet_on, 'quiet_from', q.quiet_from, 'quiet_until', q.quiet_until,
                                  'cadence', coalesce(f.cadence, 'instant'), 'all_off', coalesce(f.all_off, false)),
    'channels', jsonb_build_object(
      'push', jsonb_build_object('on', coalesce(s.push_enabled, true) and p_kind = 'user', 'devices', v_devices),
      'email', jsonb_build_object('on', true, 'address', case when p_kind = 'partner' then (select x.email from referral_partners x where x.id = p_id) else r ->> 'email' end),
      'text', jsonb_build_object('on', case when p_kind = 'partner' then false when v_staff then coalesce(s.phone_enabled and s.sms_alerts_enabled, false) else coalesce((r ->> 'textable')::boolean, false) end,
                                 'why_not', case when v_staff or p_kind = 'partner' then null else r ->> 'why_not' end,
                                 'chosen', r ->> 'wanted', 'paused', app.quo_paused())),
    'summary', jsonb_build_object('hour', s.notify_pref_digest_hour, 'weekly_dow', s.notify_pref_weekly_dow),
    'groups', v_groups);
end $$;

-- one change. p: {type, channel, on} | {quiet_on, quiet_from, quiet_until} | {cadence} | {all_off}
create function app.notify_prefs_save(p_kind text, p_id uuid, p jsonb, p_by uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  t notify_types;
  v_ch text := p ->> 'channel';
  v_on boolean := (p ->> 'on')::boolean;
  v_want text;
  v_staff boolean := p_kind = 'user' and app.notify_is_staff(p_id);
  v_portals text[] := case when p_kind = 'partner' then array['partner'] else app.notify_portals(p_id) end;
  q record;
  v_from integer; v_until integer;
begin
  if p_kind not in ('user', 'partner') or p_id is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  perform app.rw_act_as(coalesce(p_by, case when p_kind = 'user' then p_id end));
  if p ? 'type' then
    select * into t from notify_types where code = p ->> 'type';
    if t.code is null or not (t.portals && v_portals) then raise exception 'Unknown notification type' using errcode = '22023'; end if;
    if t.locked then raise exception '% is always sent: it is about your security, your agreement, your money or your booking', t.label using errcode = '23514'; end if;
    if v_ch is null or not (v_ch = any (t.channels)) or v_on is null then raise exception 'Choose push, email or text, on or off' using errcode = '22023'; end if;
    -- a person whose one channel was email (or text) and who now turns the other on for this type: every other
    -- optional type keeps what it had (off on that channel), and the account takes both channels from here
    if p_kind = 'user' and not v_staff and v_on and v_ch in ('email', 'text') then
      v_want := app.notify_reach(p_id, null, null) ->> 'wanted';
      if v_want in ('email', 'text') and v_want <> v_ch then
        insert into notify_prefs (subject_kind, subject_id, type, push, email, sms, updated_by)
        select 'user', p_id, x.code, x.push_default, case when v_ch = 'email' then false else x.email_default end, case when v_ch = 'text' then false else x.text_default end, p_by
          from notify_types x where not x.locked and x.portals && v_portals
        on conflict (subject_kind, subject_id, type) do update
           set email = case when v_ch = 'email' then false else notify_prefs.email end, sms = case when v_ch = 'text' then false else notify_prefs.sms end;
        update users set notify_channel = 'both', notify_channel_at = now(), notify_channel_by = coalesce(p_by, p_id) where id = p_id;
      end if;
    end if;
    insert into notify_prefs (subject_kind, subject_id, type, push, email, sms, updated_by)
    values (p_kind, p_id, t.code,
            case when v_ch = 'push' then v_on else t.push_default end, case when v_ch = 'email' then v_on else t.email_default end,
            case when v_ch = 'text' then v_on else t.text_default end, p_by)
    on conflict (subject_kind, subject_id, type) do update
       set push = case when v_ch = 'push' then v_on else notify_prefs.push end, email = case when v_ch = 'email' then v_on else notify_prefs.email end,
           sms = case when v_ch = 'text' then v_on else notify_prefs.sms end, updated_by = excluded.updated_by;
    -- a switch on while everything optional was off ends "all off" (the other types keep their own switches)
    if v_on then update notify_profiles set all_off = false, updated_by = p_by where subject_kind = p_kind and subject_id = p_id and all_off; end if;
  end if;
  if p ?| array['quiet_on', 'quiet_from', 'quiet_until', 'cadence', 'all_off'] then
    select * into q from app.notify_quiet_of(p_kind, p_id);
    v_from := coalesce((p ->> 'quiet_from')::integer, q.quiet_from);
    v_until := coalesce((p ->> 'quiet_until')::integer, q.quiet_until);
    if v_from not between 0 and 1439 or v_until not between 0 and 1439 then raise exception 'Choose a time of day' using errcode = '22023'; end if;
    if p ? 'cadence' and (p ->> 'cadence') not in ('instant', 'daily', 'weekly') then raise exception 'Choose instant, a daily summary or a weekly summary' using errcode = '22023'; end if;
    insert into notify_profiles (subject_kind, subject_id, quiet_on, quiet_from, quiet_until, cadence, all_off, updated_by)
    values (p_kind, p_id, coalesce((p ->> 'quiet_on')::boolean, q.quiet_on), v_from, v_until, coalesce(p ->> 'cadence', 'instant'), coalesce((p ->> 'all_off')::boolean, false), p_by)
    on conflict (subject_kind, subject_id) do update
       set quiet_on = case when p ? 'quiet_on' then (p ->> 'quiet_on')::boolean else notify_profiles.quiet_on end,
           quiet_from = case when p ? 'quiet_from' then v_from else notify_profiles.quiet_from end,
           quiet_until = case when p ? 'quiet_until' then v_until else notify_profiles.quiet_until end,
           cadence = case when p ? 'cadence' then p ->> 'cadence' else notify_profiles.cadence end,
           all_off = case when p ? 'all_off' then (p ->> 'all_off')::boolean else notify_profiles.all_off end,
           updated_by = excluded.updated_by;
    -- staff: the quiet hours of Alerts are the same ones (0466)
    if v_staff and p ?| array['quiet_on', 'quiet_from', 'quiet_until'] then
      insert into staff_alert_prefs (user_id, quiet_on, quiet_from, quiet_until)
      values (p_id, coalesce((p ->> 'quiet_on')::boolean, q.quiet_on), v_from, v_until)
      on conflict (user_id) do update set quiet_on = excluded.quiet_on, quiet_from = excluded.quiet_from, quiet_until = excluded.quiet_until, updated_at = now();
    end if;
  end if;
  return app.notify_prefs_state(p_kind, p_id, p ->> 'portal');
end $$;

-- the signed-in person (every portal and the app): the server passes the session's user
create function public.server_notify_prefs(p_user uuid, p_portal text default null) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.notify_prefs_state('user', p_user, p_portal) $$;
create function public.server_notify_prefs_save(p_user uuid, p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.notify_prefs_save('user', p_user, p, p_user) $$;
-- a referral partner's portal link (its id and the key of the link, checked as the portal checks it)
create function public.server_partner_notify_prefs(p_partner uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.notify_prefs_state('partner', p_partner, 'partner') $$;
create function public.server_partner_notify_prefs_save(p_partner uuid, p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.notify_prefs_save('partner', p_partner, p, null) $$;

-- ================================================================ the Admin's view: the types, and a person's choices
create function app.notify_prefs_admin(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_user uuid := nullif(p ->> 'user', '')::uuid;
begin
  if not app.user_is_admin(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  return jsonb_build_object(
    'types', (select coalesce(jsonb_agg(jsonb_build_object('code', t.code, 'label', t.label, 'detail', t.detail, 'grp', t.grp, 'portals', to_jsonb(t.portals), 'locked', t.locked,
                 'channels', to_jsonb(t.channels), 'push_default', t.push_default, 'email_default', t.email_default, 'text_default', t.text_default, 'live', app.notify_type_live(t),
                 'codes', (select count(*) from notification_catalogue c where c.pref_type = t.code) + (select count(*) from staff_alert_rules r where r.pref_type = t.code),
                 'changed_by', (select count(*) from notify_prefs x where x.type = t.code)) order by t.sort, t.code), '[]'::jsonb) from notify_types t where t.portals <> '{}'),
    'people', (select coalesce(jsonb_agg(jsonb_build_object('user_id', u.id, 'name', coalesce(u.full_name, u.email), 'email', u.email, 'portals', to_jsonb(app.notify_portals(u.id)),
                 'changed', (select count(*) from notify_prefs x where x.subject_kind = 'user' and x.subject_id = u.id),
                 'cadence', coalesce(f.cadence, 'instant'), 'quiet_on', coalesce(f.quiet_on, false), 'all_off', coalesce(f.all_off, false)) order by coalesce(f.all_off, false) desc, u.full_name), '[]'::jsonb)
                 from users u left join notify_profiles f on f.subject_kind = 'user' and f.subject_id = u.id
                where f.subject_id is not null or exists (select 1 from notify_prefs x where x.subject_kind = 'user' and x.subject_id = u.id)),
    'person', case when v_user is not null then app.notify_prefs_state('user', v_user, p ->> 'portal') || jsonb_build_object('user_id', v_user,
                 'name', (select coalesce(u.full_name, u.email) from users u where u.id = v_user)) end,
    'waiting', (select count(*) from notify_digest_items where sent_at is null));
end $$;

-- p: {user, ...a change} for a person; or {type, push_default, email_default, text_default} for a type's defaults
create function app.notify_prefs_admin_do(p_by uuid, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare t notify_types;
begin
  if not app.user_is_admin(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  perform app.rw_act_as(p_by);
  if p_name = 'notify_pref_set' then
    return app.notify_prefs_save('user', (p ->> 'user')::uuid, p - 'user', p_by);
  end if;
  select * into t from notify_types where code = p ->> 'type';
  if t.code is null then raise exception 'Unknown notification type' using errcode = 'P0002'; end if;
  if t.locked then raise exception 'A locked type is always sent on every channel' using errcode = '23514'; end if;
  update notify_types set push_default = coalesce((p ->> 'push_default')::boolean, push_default), email_default = coalesce((p ->> 'email_default')::boolean, email_default),
         text_default = coalesce((p ->> 'text_default')::boolean, text_default) where code = t.code;
  return jsonb_build_object('ok', true);
end $$;

-- ================================================================ 5. what was set before carries over
-- Dwight Laird (3113): notifications off becomes every optional notification off; the locked ones reach him again
insert into notify_profiles (subject_kind, subject_id, all_off)
select 'user', u.id, true from users u where u.staff_notices_off
on conflict (subject_kind, subject_id) do update set all_off = true;
insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
select null, 'notify_prefs_migrated', 'users', u.id::text, jsonb_build_object('from', 'staff_notices_off', 'to', 'every optional notification off; assigned work and onboarding or suspension notices stay on (3260)')
  from users u where u.staff_notices_off;
update users set staff_notices_off = false where staff_notices_off;
-- emails a person muted (0018)
insert into notify_prefs (subject_kind, subject_id, type, push, email, sms)
select distinct on (np.user_id, t.code) 'user', np.user_id, t.code, t.push_default, false, t.text_default
  from notification_preferences np join notification_catalogue c on c.code = np.code join notify_types t on t.code = c.pref_type and not t.locked
 where not np.email_enabled
on conflict do nothing;
-- phone alert topics a person removed (0300): the types of that topic
insert into notify_prefs (subject_kind, subject_id, type, push, email, sms)
select 'user', pp.user_id, t.code, false, t.email_default, t.text_default
  from push_preferences pp join notify_types t on not t.locked and t.push_topic is not null and not (t.push_topic = any (pp.topics))
 where t.portals && app.notify_portals(pp.user_id)
on conflict (subject_kind, subject_id, type) do update set push = false;

-- the old per-code list keeps answering for the screens of the app's first build; a type that is off answers off
alter function app.my_notification_preferences() rename to my_notification_preferences_pre3260;
create function app.my_notification_preferences() returns table (code text, subject text, category text, user_can_mute boolean, email_enabled boolean, in_app_enabled boolean)
language sql stable security definer set search_path = public, app as $$
  select m.code, m.subject, m.category, m.user_can_mute,
         m.email_enabled and coalesce((select x.email from notification_catalogue c, app.notify_pref_of('user', app.uid(), c.pref_type) x where c.code = m.code and c.pref_type is not null), true),
         m.in_app_enabled
    from app.my_notification_preferences_pre3260() m
$$;
select pg_temp.copy_grants('app.my_notification_preferences()'::regprocedure, 'app.my_notification_preferences_pre3260()'::regprocedure);

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('carmacars-notify-digest', '*/15 * * * *', $q$select app.job_notify_digest()$q$);
  end if;
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('app', 'public') and (p.proname ~ '^(rw_act_as|notify_type_|notify_portals|notify_is_staff|notify_pref|notify_prefs_|notify_quiet_|job_notify_digest|server_notify_prefs|server_partner_notify_prefs)' or p.proname ~ '_pre3260$')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
