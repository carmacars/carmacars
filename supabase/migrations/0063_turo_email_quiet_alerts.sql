-- 0063_turo_email_quiet_alerts.sql
-- The owner's requests of October 19, 2026 (docs/changes/2026-10-19-turo-email-quiet-alerts.md):
--   A. Turo has no calendar link. Turo leaves the iCal platforms (Getaround, Google Calendar and any other stay). Turo
--      trips come by email instead: rent@carmacars.ca forwards Turo's trip emails (one Gmail filter) to the inbound
--      address on a subdomain (trips@in.carmacars.ca, Cloudflare Email Routing, so the root domain's Google Workspace
--      mail is untouched). The Worker reads each email (rules, then Workers AI for what the rules missed) and calls
--      app.turo_email_receive() with the parsed fields only: the car (from the Turo listing name, Turo car number,
--      plate or VIN set per car), start, end, trip number, the guest's first name and what happened (booked, changed,
--      extended, cancelled). Each Turo trip holds one "External booking" block with the turnaround through the
--      calendar sync machinery of 0062 (a per-car email "feed"), so availability, clashes (task, email, To do) and the
--      export links work as for the iCal platforms. Unclear emails go to a review list; Gmail's forwarding
--      confirmation is shown to the Admins with its code and link. Email bodies are never stored: only the parsed
--      fields, a short audit line and, for an email someone must look at, a redacted excerpt that goes when it is
--      handled (or after 14 days). Turo cannot read our calendar either: per car, the CarmaCars bookings not yet
--      blocked on Turo with a "Done on Turo" tick, and the cancelled or moved ones to free there.
--   B. Site alerts that do not spam: an email only for a real outage (a page failing continuously for
--      uptime_page_alert_minutes, emails failing for uptime_email_alert_minutes, the backup failing, Stripe failing for
--      uptime_stripe_alert_minutes), at most uptime_max_alert_emails a day, one recovery email per incident, nothing
--      from 23:00 to 07:00 Toronto unless the site has been fully down for uptime_quiet_outage_minutes. Short
--      problems (an Error 1102, a single failure) show on the Site health card only, and the day's problems are one
--      line in the Admin's morning digest. /api/health answering 404 because the website is older than the database
--      (its schema marker) reads "Waiting for the website deploy", not a failure.
-- No applied migration is edited.

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists turo_email_enabled boolean not null default true,
  add column if not exists turo_email_address text not null default 'trips@in.carmacars.ca' check (turo_email_address ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  add column if not exists turo_email_forwarders text not null default 'rent@carmacars.ca' check (length(turo_email_forwarders) <= 500),
  add column if not exists turo_email_ai boolean not null default true,
  add column if not exists turo_email_keep_days integer not null default 90 check (turo_email_keep_days between 7 and 400),
  add column if not exists uptime_page_alert_minutes integer not null default 15 check (uptime_page_alert_minutes between 5 and 240),
  add column if not exists uptime_email_alert_minutes integer not null default 30 check (uptime_email_alert_minutes between 5 and 480),
  add column if not exists uptime_stripe_alert_minutes integer not null default 30 check (uptime_stripe_alert_minutes between 5 and 480),
  add column if not exists uptime_max_alert_emails integer not null default 3 check (uptime_max_alert_emails between 0 and 20),
  add column if not exists uptime_quiet_from_hour integer not null default 23 check (uptime_quiet_from_hour between 0 and 23),
  add column if not exists uptime_quiet_until_hour integer not null default 7 check (uptime_quiet_until_hour between 0 and 23),
  add column if not exists uptime_quiet_outage_minutes integer not null default 60 check (uptime_quiet_outage_minutes between 15 and 600);
comment on column program_settings.turo_email_enabled is 'Turo by email (0063): read the trip emails Turo sends (forwarded from rent@carmacars.ca) and block the car for each Turo trip.';
comment on column program_settings.turo_email_address is 'Turo by email: the address Turo''s trip emails are forwarded to (Cloudflare Email Routing on in.carmacars.ca).';
comment on column program_settings.turo_email_forwarders is 'Turo by email: the mailboxes allowed to forward Turo emails, separated by commas (rent@carmacars.ca). Anything else is ignored.';
comment on column program_settings.turo_email_ai is 'Turo by email: when the rules cannot read an email, ask Workers AI (within the daily neuron limit). Its answer is used only where the email contains it.';
comment on column program_settings.turo_email_keep_days is 'Turo by email: keep the log of received emails (parsed fields and a short audit, never the email itself) this many days.';
comment on column program_settings.uptime_page_alert_minutes is 'Site check (0063): email only when a page has failed every check for this many minutes. Shorter problems (Error 1102) show on Site health and in the morning digest.';
comment on column program_settings.uptime_email_alert_minutes is 'Site check: email only when emails have been failing or stuck for this many minutes.';
comment on column program_settings.uptime_stripe_alert_minutes is 'Site check: email only when Stripe webhooks have been failing for this many minutes.';
comment on column program_settings.uptime_max_alert_emails is 'Site check: at most this many alert emails a day (recovery emails are not counted). The rest show on Site health.';
comment on column program_settings.uptime_quiet_from_hour is 'Site check: no alert emails from this hour (Toronto) ...';
comment on column program_settings.uptime_quiet_until_hour is '... until this hour, unless the whole site has been down longer than the next setting.';
comment on column program_settings.uptime_quiet_outage_minutes is 'Site check: during the quiet hours, the site being fully down (the home page failing) this many minutes still emails.';
comment on column program_settings.uptime_fail_threshold is 'Site check: a page shows as a problem on Site health after failing this many checks in a row. Emails follow the alert minutes (0063).';
comment on column program_settings.uptime_alert_cooldown_minutes is 'Site check: no longer used since 0063 (the daily limit, the quiet hours and the alert minutes decide).';

-- ================================================================ 2. calendar sync: Turo by email, Google Calendar
alter table calendar_feeds add column if not exists kind text not null default 'ical' check (kind in ('ical', 'email'));
alter table calendar_feeds alter column url drop not null;
alter table calendar_feeds drop constraint if exists calendar_feeds_url_check;
alter table calendar_feeds add constraint calendar_feeds_url_check
  check ((kind = 'ical' and url ~ '^https?://[^\s]+$' and length(url) <= 2000) or (kind = 'email' and url is null));
alter table calendar_feeds drop constraint if exists calendar_feeds_platform_check;
alter table calendar_feeds add constraint calendar_feeds_platform_check check (platform in ('turo', 'getaround', 'google', 'other'));
create unique index if not exists calendar_feeds_one_email on calendar_feeds (vehicle_id) where kind = 'email';
comment on column calendar_feeds.kind is 'ical: a calendar link read every few minutes (0062); email: the Turo trips of one car, read from Turo''s emails (0063).';

-- Turo has no calendar link: a Turo iCal link added since 0062 is turned off, its blocks freed, and it says why.
do $$
declare f record;
begin
  for f in select id from calendar_feeds where kind = 'ical' and platform = 'turo' loop
    update calendar_feeds set enabled = false, platform = 'other', last_status = 'error',
           last_error = 'Turo has no calendar link. Turo trips now come by email (Calendar sync, Turo by email). Remove this link.'
     where id = f.id;
    perform app.calendar_feed_apply(f.id, null, '{}'::jsonb);
  end loop;
end $$;

create table turo_vehicle_links (
  vehicle_id      uuid primary key references vehicles (id) on delete cascade,
  listing_name    text check (length(listing_name) between 3 and 120),
  turo_vehicle_id text check (turo_vehicle_id ~ '^\d{3,12}$'),
  created_by      uuid references users (id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create trigger turo_vehicle_links_updated before update on turo_vehicle_links for each row execute function app.set_updated_at();
comment on table turo_vehicle_links is 'Turo by email (0063): how Turo''s emails name each car listed on Turo (the listing name, the Turo car number in its page address). The plate and VIN come from the car.';

create table turo_calendar_trips (
  id               uuid primary key default gen_random_uuid(),
  trip_id          text not null unique check (trip_id ~ '^[0-9A-Z-]{3,40}$'),
  vehicle_id       uuid not null references vehicles (id) on delete cascade,
  status           text not null check (status in ('booked', 'cancelled')),
  starts_at        timestamptz,
  ends_at          timestamptz,
  guest_first_name text check (length(guest_first_name) <= 40),
  source           text not null check (source in ('email', 'manual')),
  last_kind        text not null check (last_kind in ('booked', 'changed', 'extended', 'cancelled', 'manual')),
  last_email_at    timestamptz,
  created_by       uuid references users (id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (status = 'cancelled' or (starts_at is not null and ends_at > starts_at))
);
create index turo_calendar_trips_vehicle_idx on turo_calendar_trips (vehicle_id, starts_at);
create trigger turo_calendar_trips_updated before update on turo_calendar_trips for each row execute function app.set_updated_at();
comment on table turo_calendar_trips is 'Turo by email (0063): one Turo trip, from Turo''s emails or added by hand. Only the guest''s first name is kept. A booked trip holds an External booking block (through its car''s email feed).';

create table turo_inbound_emails (
  id                uuid primary key default gen_random_uuid(),
  received_at       timestamptz not null default now(),
  message_id        text unique check (length(message_id) <= 300),
  sent_at           timestamptz,
  envelope_from     text check (length(envelope_from) <= 200),
  subject           text check (length(subject) <= 200),
  kind              text not null check (kind in ('booked', 'changed', 'extended', 'cancelled', 'request', 'other', 'not_turo', 'forwarding_confirmation')),
  status            text not null check (status in ('applied', 'review', 'ignored', 'notice', 'resolved', 'dismissed')),
  method            text not null default 'rules' check (method in ('rules', 'ai', 'none', 'staff')),
  trip_id           text check (length(trip_id) <= 40),
  vehicle_id        uuid references vehicles (id) on delete set null,
  starts_at         timestamptz,
  ends_at           timestamptz,
  guest_first_name  text check (length(guest_first_name) <= 40),
  vehicle_hint      text check (length(vehicle_hint) <= 120),
  reason            text check (length(reason) <= 300),
  audit             text check (length(audit) <= 300),
  excerpt           text check (length(excerpt) <= 800),
  confirmation_code text check (confirmation_code ~ '^\d{6,12}$'),
  confirmation_url  text check (confirmation_url ~ '^https://(mail-settings|mail|isolated\.mail)\.google\.com/'),
  turo_trip         uuid references turo_calendar_trips (id) on delete set null,
  task_id           uuid references tasks (id) on delete set null,
  resolved_by       uuid references users (id),
  resolved_at       timestamptz
);
create index turo_inbound_emails_idx on turo_inbound_emails (received_at desc);
create index turo_inbound_emails_review_idx on turo_inbound_emails (received_at) where status = 'review';
comment on table turo_inbound_emails is 'Turo by email (0063): one row per email received: the parsed fields and a short audit, never the email. A redacted excerpt only while it waits for review. Deleted after turo_email_keep_days.';

create table turo_blocked_bookings (
  booking_id uuid primary key references bookings (id) on delete cascade,
  vehicle_id uuid not null references vehicles (id) on delete cascade,
  starts_at  timestamptz not null,
  ends_at    timestamptz not null,
  done_by    uuid references users (id),
  done_at    timestamptz not null default now()
);
comment on table turo_blocked_bookings is 'Turo by email (0063): a CarmaCars booking someone blocked on Turo by hand ("Done on Turo"), with the dates blocked there. Turo cannot read our calendar.';

do $$
declare t text;
begin
  foreach t in array array['turo_vehicle_links', 'turo_calendar_trips', 'turo_inbound_emails', 'turo_blocked_bookings'] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('revoke all on %I from anon, authenticated', t);
  end loop;
end $$;

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, description) values
  ('turo_email_review', 'fleet', 'A Turo email to check', 'high', 'opening_minutes', 120, 'A trip email from Turo could not be read with certainty: open Calendar sync, check it on Turo and add the trip, or dismiss it')
on conflict (task_type) do update set queue = excluded.queue, title = excluded.title, priority = excluded.priority,
  due_kind = excluded.due_kind, due_amount = excluded.due_amount, description = excluded.description;

-- ================================================================ 3. Turo trips: blocks through the car's email feed
create or replace function app.platform_name(p text) returns text
language sql immutable as $$ select case p when 'turo' then 'Turo' when 'getaround' then 'Getaround' when 'google' then 'Google Calendar' else 'Other calendar' end $$;

-- iCal links only (an email feed is never fetched)
create or replace function app.calendar_feeds_due(p_limit integer default 50, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  v jsonb;
begin
  if not ps.calendar_sync_enabled then return '[]'::jsonb; end if;
  with due as (
    select f.id from calendar_feeds f
     where f.enabled and f.kind = 'ical' and (f.last_attempt_at is null or f.last_attempt_at <= p_now - make_interval(mins => ps.calendar_sync_minutes) + interval '60 seconds')
     order by f.last_attempt_at nulls first limit greatest(coalesce(p_limit, 50), 1)
     for update skip locked),
  upd as (update calendar_feeds f set last_attempt_at = p_now from due where f.id = due.id returning f.*)
  select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'url', u.url, 'platform', u.platform, 'etag', u.etag, 'last_modified', u.last_modified)), '[]'::jsonb)
    into v from upd u;
  return v;
end $$;

-- The car's Turo email feed (made on first use).
create or replace function app.turo_email_feed(p_vehicle uuid) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare v uuid;
begin
  select id into v from calendar_feeds where vehicle_id = p_vehicle and kind = 'email';
  if v is null then
    insert into calendar_feeds (vehicle_id, platform, kind, url, label, last_status)
    values (p_vehicle, 'turo', 'email', null, null, 'new')
    on conflict (vehicle_id) where kind = 'email' do nothing returning id into v;
    if v is null then select id into v from calendar_feeds where vehicle_id = p_vehicle and kind = 'email'; end if;
  end if;
  return v;
end $$;

-- The car's booked Turo trips become its email feed's events, through 0062's calendar_feed_apply: a block with the
-- turnaround for each, moved when the trip moves, freed when it is cancelled, clashes checked.
create or replace function app.turo_feed_refresh(p_vehicle uuid, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_feed uuid := app.turo_email_feed(p_vehicle);
begin
  return app.calendar_feed_apply(v_feed, coalesce((
    select jsonb_agg(jsonb_build_object('uid', 'turo:' || t.trip_id,
             'summary', case when t.trip_id ~ '^M-' then 'Turo trip (added by hand)' else 'Turo trip ' || t.trip_id end,
             'starts_at', t.starts_at, 'ends_at', t.ends_at, 'all_day', false) order by t.starts_at)
      from turo_calendar_trips t where t.vehicle_id = p_vehicle and t.status = 'booked' and t.ends_at > p_now - interval '30 days'), '[]'::jsonb),
    '{}'::jsonb, p_now);
end $$;

-- One trip change: booked, changed, extended or cancelled (from an email or staff). p: kind, trip_id, vehicle_id,
-- starts_at, ends_at, guest_first_name, sent_at, source (email | manual), by. Returns status (applied, review,
-- ignored), a reason in words, the audit line and the trip.
create or replace function app.turo_trip_apply(p jsonb, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_kind text := p ->> 'kind';
  v_trip text := upper(nullif(btrim(coalesce(p ->> 'trip_id', '')), ''));
  v_vehicle uuid := nullif(p ->> 'vehicle_id', '')::uuid;
  v_start timestamptz := nullif(p ->> 'starts_at', '')::timestamptz;
  v_end timestamptz := nullif(p ->> 'ends_at', '')::timestamptz;
  v_sent timestamptz := coalesce(nullif(p ->> 'sent_at', '')::timestamptz, p_now);
  v_source text := coalesce(nullif(p ->> 'source', ''), 'email');
  v_guest text := left(nullif(btrim(coalesce(p ->> 'guest_first_name', '')), ''), 40);
  t turo_calendar_trips;
  v_old_vehicle uuid;
  v_audit text;
  v_word text;
begin
  if v_kind not in ('booked', 'changed', 'extended', 'cancelled') then
    return jsonb_build_object('status', 'ignored', 'reason', 'Not a trip change');
  end if;
  if v_trip is null and v_source = 'manual' then v_trip := 'M-' || upper(substr(md5(gen_random_uuid()::text), 1, 8)); end if;
  if v_trip is null then return jsonb_build_object('status', 'review', 'reason', 'No Turo trip number in the email'); end if;
  if v_trip !~ '^[0-9A-Z-]{3,40}$' then return jsonb_build_object('status', 'review', 'reason', 'The trip number is not one Turo uses'); end if;
  select * into t from turo_calendar_trips where trip_id = v_trip for update;
  -- an email older than the last one applied to the trip changes nothing (Gmail can deliver out of order)
  if t.id is not null and v_source = 'email' and t.last_email_at is not null and v_sent < t.last_email_at then
    return jsonb_build_object('status', 'ignored', 'reason', 'Older than the last email about this trip', 'trip', t.id);
  end if;
  if v_kind = 'cancelled' then
    if t.id is null then
      return jsonb_build_object('status', 'ignored', 'reason', format('Turo trip %s was not on the calendar: nothing to free', v_trip));
    end if;
    update turo_calendar_trips set status = 'cancelled', last_kind = 'cancelled', last_email_at = case when v_source = 'email' then v_sent else last_email_at end
     where id = t.id returning * into t;
    perform app.turo_feed_refresh(t.vehicle_id, p_now);
    v_audit := format('Cancelled: Turo trip %s on the %s, block freed', v_trip, app.vehicle_name(t.vehicle_id));
    return jsonb_build_object('status', 'applied', 'audit', left(v_audit, 300), 'trip', t.id, 'vehicle_id', t.vehicle_id);
  end if;
  -- booked, changed, extended
  v_vehicle := coalesce(v_vehicle, t.vehicle_id);
  if v_vehicle is null then return jsonb_build_object('status', 'review', 'reason', 'Which car: no car matches the email'); end if;
  if not exists (select 1 from vehicles where id = v_vehicle) then raise exception 'Car not found' using errcode = 'P0002'; end if;
  v_start := coalesce(v_start, case when t.status = 'booked' or v_kind = 'extended' then t.starts_at end);
  v_end := coalesce(v_end, case when t.status = 'booked' then t.ends_at end);
  if v_start is null or v_end is null then
    return jsonb_build_object('status', 'review', 'reason', case when t.id is null then 'A change to a trip that is not on the calendar, without both dates'
                                                               else 'The start or end is missing' end);
  end if;
  if v_end <= v_start then return jsonb_build_object('status', 'review', 'reason', 'The end is not after the start'); end if;
  if v_end - v_start > interval '120 days' then return jsonb_build_object('status', 'review', 'reason', 'Longer than 120 days: check the dates'); end if;
  v_old_vehicle := t.vehicle_id;
  insert into turo_calendar_trips as x (trip_id, vehicle_id, status, starts_at, ends_at, guest_first_name, source, last_kind, last_email_at, created_by)
  values (v_trip, v_vehicle, 'booked', v_start, v_end, v_guest, case when v_source = 'manual' then 'manual' else 'email' end,
          case when v_source = 'manual' then 'manual' else v_kind end, case when v_source = 'email' then v_sent end, nullif(p ->> 'by', '')::uuid)
  on conflict (trip_id) do update
     set vehicle_id = excluded.vehicle_id, status = 'booked', starts_at = excluded.starts_at, ends_at = excluded.ends_at,
         guest_first_name = coalesce(excluded.guest_first_name, x.guest_first_name), last_kind = excluded.last_kind,
         last_email_at = coalesce(excluded.last_email_at, x.last_email_at)
  returning * into t;
  perform app.turo_feed_refresh(t.vehicle_id, p_now);
  if v_old_vehicle is not null and v_old_vehicle <> t.vehicle_id then perform app.turo_feed_refresh(v_old_vehicle, p_now); end if;
  v_word := case when v_source = 'manual' then 'Added by hand' when v_kind = 'booked' then 'Booked' when v_kind = 'extended' then 'Extended' else 'Changed' end;
  v_audit := format('%s: Turo trip %s, %s, %s to %s%s', v_word, case when v_trip ~ '^M-' then '(no number)' else v_trip end, app.vehicle_name(t.vehicle_id),
                    app.fmt_at(t.starts_at), app.fmt_at(t.ends_at), coalesce(' (' || t.guest_first_name || ')', ''));
  return jsonb_build_object('status', 'applied', 'audit', left(v_audit, 300), 'trip', t.id, 'vehicle_id', t.vehicle_id);
end $$;

-- ================================================================ 4. the inbound email (from the Worker, service role)
-- The cars Turo's emails may name, for the Worker's matcher, and whether the model may help today.
create or replace function app.turo_match_keys() returns jsonb
language sql stable security definer set search_path = public, app as $$
  with day as (select app.local_midnight(app.local_date(now())) as t0)
  select jsonb_build_object(
    'enabled', s.turo_email_enabled, 'forwarders', s.turo_email_forwarders, 'address', s.turo_email_address,
    'ai_ok', s.turo_email_ai and (select coalesce(sum(c.units), 0) from provider_calls c, day where c.unit = 'neurons' and c.created_at >= day.t0) < s.chat_ai_total_daily_neurons,
    'cars', coalesce((select jsonb_agg(jsonb_build_object('vehicle_id', v.id, 'name', app.vehicle_name(v.id), 'listing_name', l.listing_name,
                        'turo_vehicle_id', l.turo_vehicle_id, 'plate', v.plate, 'vin', v.vin, 'make', v.make, 'model', v.model, 'year', v.year) order by v.year desc)
                       from vehicles v left join turo_vehicle_links l on l.vehicle_id = v.id
                      where v.retired_at is null and v.status not in ('exited', 'total_loss', 'declined')), '[]'::jsonb))
    from (select (app.settings()).*) s
$$;

-- One email, parsed by the Worker (web/src/features/turo/email.ts). p: message_id, sent_at, envelope_from, subject,
-- from_turo, kind, trip_id, vehicle_id, starts_at, ends_at, guest_first_name, vehicle_hint, missing (list), method,
-- excerpt (only when something is missing), neurons; or kind forwarding_confirmation with code and url.
create or replace function app.turo_email_receive(p jsonb, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  v_mid text := left(nullif(btrim(coalesce(p ->> 'message_id', '')), ''), 300);
  v_kind text := coalesce(nullif(p ->> 'kind', ''), 'other');
  -- Gmail forwards with the envelope rent+caf_=trips=in.carmacars.ca@carmacars.ca: that is rent@carmacars.ca
  v_from text := regexp_replace(lower(left(coalesce(p ->> 'envelope_from', ''), 200)), '\+[^@]*@', '@');
  v_status text;
  v_reason text;
  v_audit text;
  r jsonb := '{}'::jsonb;
  e turo_inbound_emails;
  v_missing text := (select string_agg(x, ', ') from jsonb_array_elements_text(coalesce(p -> 'missing', '[]'::jsonb)) x);
  v_ok_forwarder boolean;
begin
  if v_mid is not null and exists (select 1 from turo_inbound_emails where message_id = v_mid) then
    return jsonb_build_object('status', 'duplicate');
  end if;
  -- housekeeping on the way: the log after turo_email_keep_days, a review excerpt after 14 days
  delete from turo_inbound_emails where received_at < p_now - make_interval(days => ps.turo_email_keep_days);
  update turo_inbound_emails set excerpt = null where excerpt is not null and received_at < p_now - interval '14 days';
  if v_kind = 'forwarding_confirmation' then
    insert into turo_inbound_emails (received_at, message_id, sent_at, envelope_from, subject, kind, status, method, confirmation_code, confirmation_url, audit)
    values (p_now, v_mid, nullif(p ->> 'sent_at', '')::timestamptz, v_from, left(p ->> 'subject', 200), 'forwarding_confirmation', 'notice', 'none',
            p ->> 'code', nullif(p ->> 'url', ''), 'Gmail forwarding confirmation: shown to the Admins on Calendar sync')
    returning * into e;
    return jsonb_build_object('status', 'notice', 'id', e.id);
  end if;
  v_ok_forwarder := v_from = '' or v_from = any (select lower(btrim(x)) from unnest(string_to_array(ps.turo_email_forwarders, ',')) x);
  if not ps.turo_email_enabled then
    v_status := 'ignored'; v_reason := 'Turo by email is turned off in Program settings';
  elsif not v_ok_forwarder then
    v_status := 'ignored'; v_kind := 'not_turo'; v_reason := 'Not forwarded by an allowed mailbox (Program settings, Turo by email)';
  elsif not coalesce((p ->> 'from_turo')::boolean, false) then
    v_status := 'ignored'; v_kind := 'not_turo'; v_reason := 'Not an email from Turo';
  elsif v_kind = 'request' then
    v_status := 'ignored'; v_reason := 'A trip request waiting for your answer on Turo: nothing is blocked until it is booked';
  elsif v_kind not in ('booked', 'changed', 'extended', 'cancelled') then
    v_status := 'ignored'; v_kind := 'other'; v_reason := 'Not about a trip (news, payouts, reviews)';
  elsif v_missing is not null and not (v_kind = 'cancelled' and v_missing = 'car') then
    v_status := 'review'; v_reason := 'Could not read: ' || v_missing;
  else
    r := app.turo_trip_apply(jsonb_build_object('kind', v_kind, 'trip_id', p ->> 'trip_id', 'vehicle_id', p ->> 'vehicle_id', 'starts_at', p ->> 'starts_at',
           'ends_at', p ->> 'ends_at', 'guest_first_name', p ->> 'guest_first_name', 'sent_at', p ->> 'sent_at', 'source', 'email'), p_now);
    v_status := r ->> 'status'; v_reason := r ->> 'reason'; v_audit := r ->> 'audit';
  end if;
  insert into turo_inbound_emails (received_at, message_id, sent_at, envelope_from, subject, kind, status, method, trip_id, vehicle_id, starts_at, ends_at,
                                   guest_first_name, vehicle_hint, reason, audit, excerpt, turo_trip)
  values (p_now, v_mid, nullif(p ->> 'sent_at', '')::timestamptz, v_from, left(p ->> 'subject', 200), v_kind, v_status,
          case when p ->> 'method' in ('rules', 'ai', 'none') then p ->> 'method' else 'rules' end,
          left(nullif(p ->> 'trip_id', ''), 40), coalesce((r ->> 'vehicle_id')::uuid, nullif(p ->> 'vehicle_id', '')::uuid),
          nullif(p ->> 'starts_at', '')::timestamptz, nullif(p ->> 'ends_at', '')::timestamptz, left(nullif(p ->> 'guest_first_name', ''), 40),
          left(nullif(p ->> 'vehicle_hint', ''), 120), left(v_reason, 300),
          left(coalesce(v_audit, initcap(v_kind) || case when v_status = 'review' then ': waiting for a person' else ': ' || coalesce(lower(v_reason), 'nothing to do') end), 300),
          case when v_status = 'review' then left(p ->> 'excerpt', 800) end, (r ->> 'trip')::uuid)
  returning * into e;
  if v_status = 'review' then
    update turo_inbound_emails set task_id = app.raise_task(p_type => 'turo_email_review',
        p_title => left(format('Turo email to check: %s', coalesce(e.subject, 'no subject')), 200),
        p_detail => format('%s. Open Calendar sync, check the trip on Turo, then add it there (Add a Turo trip) or dismiss the email.', v_reason),
        p_vehicle => e.vehicle_id, p_related_table => 'turo_inbound_emails', p_related_id => e.id, p_dedupe => 'turo_email:' || e.id)
     where id = e.id;
  end if;
  if (p ->> 'neurons') ~ '^\d+$' and (p ->> 'neurons')::integer > 0 then
    insert into provider_calls (provider, purpose, ok, units, unit, created_at)
    values ('workers-ai', 'turo_email', true, (p ->> 'neurons')::integer, 'neurons', p_now);
  end if;
  return jsonb_build_object('status', v_status, 'reason', v_reason, 'audit', e.audit, 'id', e.id);
end $$;

-- ================================================================ 5. Calendar sync: the Turo part of the page and its actions
create or replace function app.calendar_feed_row(f calendar_feeds) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', f.id, 'vehicle_id', f.vehicle_id, 'kind', f.kind, 'platform', f.platform, 'platform_name', app.platform_name(f.platform),
    'name', app.calendar_feed_name(f), 'label', f.label, 'url', f.url, 'enabled', f.enabled, 'status', f.last_status,
    'last_attempt_at', f.last_attempt_at, 'last_success_at', f.last_success_at, 'last_error', f.last_error,
    'failures', f.consecutive_failures, 'failing_since', f.failing_since, 'events', f.event_count, 'calendar_name', f.calendar_name,
    'created_at', f.created_at,
    'upcoming', coalesce((select jsonb_agg(jsonb_build_object('summary', e.summary, 'starts_at', e.starts_at, 'ends_at', e.ends_at, 'all_day', e.all_day,
                                   'blocked', exists (select 1 from vehicle_calendar_blocks k where k.id = e.block_id and k.removed_at is null)) order by e.starts_at)
                            from (select * from calendar_feed_events e where e.feed_id = f.id and e.removed_at is null and e.ends_at > now()
                                   order by e.starts_at limit 5) e), '[]'::jsonb))
$$;

-- The bookings to block on Turo by hand (Turo cannot read our calendar), and the ones to free there.
create or replace function app.turo_to_block(p_vehicle uuid, p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with turn as (select make_interval(mins => app.turnaround_minutes(p_vehicle)) as t)
  select jsonb_build_object(
    'block', coalesce((select jsonb_agg(jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number,
                         'starts_at', b.pickup_at - turn.t, 'ends_at', b.return_at + turn.t, 'pickup_at', b.pickup_at, 'return_at', b.return_at,
                         'was', case when d.booking_id is not null then jsonb_build_object('starts_at', d.starts_at, 'ends_at', d.ends_at) end) order by b.pickup_at)
                        from bookings b cross join turn left join turo_blocked_bookings d on d.booking_id = b.id
                       where b.vehicle_id = p_vehicle and b.status in ('confirmed', 'on_rent') and b.blocks_calendar and b.return_at > p_now
                         and (d.booking_id is null or d.starts_at <> b.pickup_at - turn.t or d.ends_at <> b.return_at + turn.t or d.vehicle_id <> b.vehicle_id)), '[]'::jsonb),
    'free', coalesce((select jsonb_agg(jsonb_build_object('booking_id', d.booking_id, 'booking_number', b.booking_number, 'starts_at', d.starts_at, 'ends_at', d.ends_at,
                         'why', case when b.vehicle_id <> d.vehicle_id then 'moved to another car' else replace(b.status::text, '_', ' ') end) order by d.starts_at)
                        from turo_blocked_bookings d join bookings b on b.id = d.booking_id
                       where d.vehicle_id = p_vehicle and d.ends_at > p_now
                         and (b.vehicle_id <> d.vehicle_id or b.status not in ('confirmed', 'on_rent') or not b.blocks_calendar)), '[]'::jsonb))
    from turn
$$;

alter function app.calendar_sync_read(uuid, jsonb) rename to calendar_sync_read_0062;
create or replace function app.calendar_sync_read(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.calendar_sync_read_0062(p_by, p);
  ps program_settings := app.settings();
  v_admin boolean := app.user_is_admin(p_by);
  c record;
  v_confirm turo_inbound_emails;
begin
  -- the cars: their Turo link, trips and the bookings to block or free on Turo
  v := jsonb_set(v, '{cars}', coalesce((
    select jsonb_agg(x.car || jsonb_build_object(
             'turo', jsonb_build_object(
               'link', (select jsonb_build_object('listing_name', l.listing_name, 'turo_vehicle_id', l.turo_vehicle_id, 'updated_at', l.updated_at)
                          from turo_vehicle_links l where l.vehicle_id = (x.car ->> 'id')::uuid),
               'trips', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'trip_id', t.trip_id, 'starts_at', t.starts_at, 'ends_at', t.ends_at,
                                    'guest_first_name', t.guest_first_name, 'source', t.source, 'last_kind', t.last_kind,
                                    'blocked', exists (select 1 from calendar_feed_events e join calendar_feeds f on f.id = e.feed_id join vehicle_calendar_blocks k on k.id = e.block_id
                                                        where f.vehicle_id = t.vehicle_id and f.kind = 'email' and e.uid = 'turo:' || t.trip_id and k.removed_at is null)) order by t.starts_at)
                                   from turo_calendar_trips t where t.vehicle_id = (x.car ->> 'id')::uuid and t.status = 'booked' and t.ends_at > now()), '[]'::jsonb))
             -- block and free: our bookings to block on Turo by hand, and the ones to free there
             || app.turo_to_block((x.car ->> 'id')::uuid))
             -- the iCal links only; the Turo email feed is shown as Turo trips
             || jsonb_build_object('feeds', coalesce((select jsonb_agg(f) from jsonb_array_elements(x.car -> 'feeds') f where coalesce(f ->> 'kind', 'ical') = 'ical'), '[]'::jsonb))
             order by x.n)
      from jsonb_array_elements(v -> 'cars') with ordinality x(car, n)), '[]'::jsonb));
  select * into v_confirm from turo_inbound_emails where kind = 'forwarding_confirmation' and status = 'notice' and received_at > now() - interval '7 days'
   order by received_at desc limit 1;
  return v || jsonb_build_object('turo', jsonb_build_object(
    'enabled', ps.turo_email_enabled, 'address', ps.turo_email_address, 'forwarders', ps.turo_email_forwarders, 'admin', v_admin,
    'confirmation', case when v_admin and v_confirm.id is not null then jsonb_build_object('id', v_confirm.id, 'code', v_confirm.confirmation_code,
                         'url', v_confirm.confirmation_url, 'received_at', v_confirm.received_at) end,
    'last_email_at', (select max(received_at) from turo_inbound_emails where kind not in ('forwarding_confirmation', 'not_turo')),
    'emails_7d', (select count(*) from turo_inbound_emails where kind not in ('forwarding_confirmation', 'not_turo') and received_at > now() - interval '7 days'),
    'review', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'received_at', e.received_at, 'subject', e.subject, 'kind', e.kind, 'reason', e.reason,
                          'trip_id', e.trip_id, 'vehicle_id', e.vehicle_id, 'vehicle', app.vehicle_name(e.vehicle_id), 'vehicle_hint', e.vehicle_hint,
                          'starts_at', e.starts_at, 'ends_at', e.ends_at, 'guest_first_name', e.guest_first_name, 'excerpt', e.excerpt) order by e.received_at)
                         from turo_inbound_emails e where e.status = 'review'), '[]'::jsonb),
    'log', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'received_at', e.received_at, 'kind', e.kind, 'status', e.status, 'method', e.method,
                       'audit', e.audit, 'reason', e.reason) order by e.received_at desc)
                      from (select * from turo_inbound_emails order by received_at desc limit 15) e), '[]'::jsonb)));
end $$;

alter function app.calendar_sync_do(uuid, text, jsonb) rename to calendar_sync_do_0062;
create or replace function app.calendar_sync_do(p_by uuid, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  f calendar_feeds;
  e turo_inbound_emails;
  t turo_calendar_trips;
  b bookings;
  r jsonb;
  v_vehicle uuid;
  v_turn interval;
  v_url text := btrim(coalesce(p ->> 'url', ''));
  v_platform text := coalesce(nullif(p ->> 'platform', ''), 'other');
begin
  perform app.assert_calendar_staff(p_by);
  case p_name
  when 'calendar_feed_add', 'calendar_feed_save' then
    -- 0062's add and save, with Google Calendar among the platforms and Turo refused (Turo has no calendar link)
    if v_platform = 'turo' then
      raise exception 'Turo has no calendar link. Use Turo by email on this page: set the car''s Turo listing name, and Turo''s trip emails block the car' using errcode = '22023';
    end if;
    if v_platform not in ('getaround', 'google', 'other') then raise exception 'Choose Getaround, Google Calendar or Other' using errcode = '22023'; end if;
    if v_url !~ '^(https?|webcal)://[^\s]+$' or length(v_url) > 2000 then
      raise exception 'Paste the full calendar link (it starts with https://)' using errcode = '22023';
    end if;
    v_url := regexp_replace(v_url, '^webcal://', 'https://');
    if v_url ~* '/api/ical/[0-9a-f]{64}' and v_url ~* 'carmacars' then
      raise exception 'That is a CarmaCars calendar link. Paste it into the other platform; here, paste the link the platform gives you' using errcode = '22023';
    end if;
    if p_name = 'calendar_feed_add' then
      v_vehicle := (p ->> 'vehicle')::uuid;
      if not exists (select 1 from vehicles where id = v_vehicle) then raise exception 'Car not found' using errcode = 'P0002'; end if;
      if exists (select 1 from calendar_feeds where vehicle_id = v_vehicle and url = v_url) then
        raise exception 'This link is already added to this car' using errcode = '23505';
      end if;
      insert into calendar_feeds (vehicle_id, platform, label, url, created_by)
      values (v_vehicle, v_platform, left(nullif(btrim(p ->> 'label'), ''), 60), v_url, p_by) returning * into f;
      insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
      values (p_by, 'INSERT', 'calendar_feeds', f.id, jsonb_build_object('vehicle_id', f.vehicle_id, 'platform', f.platform, 'label', f.label));
      return app.calendar_feed_row(f);
    end if;
    if exists (select 1 from calendar_feeds where id = (p ->> 'id')::uuid and kind = 'email') then
      raise exception 'Turo trips come by email: change them under Turo by email' using errcode = '22023';
    end if;
    update calendar_feeds set platform = v_platform, label = left(nullif(btrim(p ->> 'label'), ''), 60), url = v_url,
           enabled = coalesce((p ->> 'enabled')::boolean, enabled),
           etag = case when url <> v_url then null else etag end, last_modified = case when url <> v_url then null else last_modified end,
           last_attempt_at = case when url <> v_url then null else last_attempt_at end
     where id = (p ->> 'id')::uuid returning * into f;
    if f.id is null then raise exception 'Calendar link not found' using errcode = 'P0002'; end if;
    if not f.enabled then perform app.calendar_feed_apply(f.id, null, '{}'::jsonb); end if;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'UPDATE', 'calendar_feeds', f.id, jsonb_build_object('platform', f.platform, 'label', f.label, 'enabled', f.enabled));
    return app.calendar_feed_row(f);
  when 'calendar_feed_remove', 'calendar_feed_sync_start', 'calendar_feed_result' then
    if exists (select 1 from calendar_feeds where id = (p ->> 'id')::uuid and kind = 'email') then
      raise exception 'Turo trips come by email: change them under Turo by email' using errcode = '22023';
    end if;
    return app.calendar_sync_do_0062(p_by, p_name, p);
  when 'calendar_export_rotate' then
    return app.calendar_sync_do_0062(p_by, p_name, p);
  when 'turo_link_save' then
    v_vehicle := (p ->> 'vehicle')::uuid;
    if not exists (select 1 from vehicles where id = v_vehicle) then raise exception 'Car not found' using errcode = 'P0002'; end if;
    if nullif(btrim(p ->> 'listing_name'), '') is null and nullif(btrim(p ->> 'turo_vehicle_id'), '') is null then
      raise exception 'Type the car''s name as Turo shows it (for example Mercedes-Benz GLC 2021), or its Turo car number' using errcode = '22023';
    end if;
    if nullif(btrim(p ->> 'turo_vehicle_id'), '') is not null and btrim(p ->> 'turo_vehicle_id') !~ '^\d{3,12}$' then
      raise exception 'The Turo car number is the number at the end of the car''s page address on Turo (digits only)' using errcode = '22023';
    end if;
    insert into turo_vehicle_links (vehicle_id, listing_name, turo_vehicle_id, created_by)
    values (v_vehicle, left(nullif(btrim(p ->> 'listing_name'), ''), 120), nullif(btrim(p ->> 'turo_vehicle_id'), ''), p_by)
    on conflict (vehicle_id) do update set listing_name = excluded.listing_name, turo_vehicle_id = excluded.turo_vehicle_id;
    perform app.turo_email_feed(v_vehicle);
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'UPDATE', 'turo_vehicle_links', v_vehicle, jsonb_build_object('listing_name', p ->> 'listing_name', 'turo_vehicle_id', p ->> 'turo_vehicle_id'));
    return jsonb_build_object('saved', true);
  when 'turo_link_remove' then
    v_vehicle := (p ->> 'vehicle')::uuid;
    delete from turo_vehicle_links where vehicle_id = v_vehicle;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, before)
    values (p_by, 'DELETE', 'turo_vehicle_links', v_vehicle, '{}'::jsonb);
    return jsonb_build_object('removed', true);
  when 'turo_trip_add' then
    -- by hand: a trip on Turo whose email did not come (or a review item resolved); an existing trip number is changed
    r := app.turo_trip_apply(jsonb_build_object('kind', case when exists (select 1 from turo_calendar_trips where trip_id = upper(btrim(coalesce(p ->> 'trip_id', '')))) then 'changed' else 'booked' end,
           'trip_id', p ->> 'trip_id', 'vehicle_id', p ->> 'vehicle', 'starts_at', p ->> 'starts_at', 'ends_at', p ->> 'ends_at',
           'guest_first_name', p ->> 'guest_first_name', 'source', 'manual', 'by', p_by));
    if r ->> 'status' <> 'applied' then raise exception '%', coalesce(r ->> 'reason', 'The trip could not be added') using errcode = '22023'; end if;
    if nullif(p ->> 'email', '') is not null then
      update turo_inbound_emails set status = 'resolved', resolved_by = p_by, resolved_at = now(), excerpt = null, turo_trip = (r ->> 'trip')::uuid,
             audit = left('Resolved by staff. ' || (r ->> 'audit'), 300), method = 'staff'
       where id = (p ->> 'email')::uuid and status = 'review' returning * into e;
      update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'Trip added on Calendar sync'
       where id = e.task_id and status in ('open', 'in_progress', 'waiting');
    end if;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'INSERT', 'turo_calendar_trips', (r ->> 'trip')::uuid, jsonb_build_object('audit', r ->> 'audit'));
    return r;
  when 'turo_trip_cancel' then
    select * into t from turo_calendar_trips where id = (p ->> 'id')::uuid;
    if t.id is null then raise exception 'Turo trip not found' using errcode = 'P0002'; end if;
    r := app.turo_trip_apply(jsonb_build_object('kind', 'cancelled', 'trip_id', t.trip_id, 'source', 'manual', 'by', p_by));
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'UPDATE', 'turo_calendar_trips', t.id, jsonb_build_object('status', 'cancelled', 'by_hand', true));
    return r;
  when 'turo_review_dismiss' then
    update turo_inbound_emails set status = 'dismissed', resolved_by = p_by, resolved_at = now(), excerpt = null,
           audit = left('Dismissed by staff. ' || coalesce(reason, ''), 300)
     where id = (p ->> 'id')::uuid and status = 'review' returning * into e;
    if e.id is null then raise exception 'That email is no longer waiting' using errcode = 'P0002'; end if;
    update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'Dismissed on Calendar sync'
     where id = e.task_id and status in ('open', 'in_progress', 'waiting');
    return jsonb_build_object('dismissed', true);
  when 'turo_confirmation_dismiss' then
    perform app.assert_admin(p_by);
    update turo_inbound_emails set status = 'dismissed', resolved_by = p_by, resolved_at = now()
     where id = (p ->> 'id')::uuid and kind = 'forwarding_confirmation';
    return jsonb_build_object('dismissed', true);
  when 'turo_block_done' then
    select * into b from bookings where id = (p ->> 'booking')::uuid;
    if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
    v_turn := make_interval(mins => app.turnaround_minutes(b.vehicle_id));
    insert into turo_blocked_bookings (booking_id, vehicle_id, starts_at, ends_at, done_by, done_at)
    values (b.id, b.vehicle_id, b.pickup_at - v_turn, b.return_at + v_turn, p_by, now())
    on conflict (booking_id) do update set vehicle_id = excluded.vehicle_id, starts_at = excluded.starts_at, ends_at = excluded.ends_at,
                                           done_by = excluded.done_by, done_at = excluded.done_at;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'UPDATE', 'turo_blocked_bookings', b.id, jsonb_build_object('blocked_on_turo', true, 'starts_at', b.pickup_at - v_turn, 'ends_at', b.return_at + v_turn));
    return jsonb_build_object('done', true);
  when 'turo_unblock_done' then
    delete from turo_blocked_bookings where booking_id = (p ->> 'booking')::uuid;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'DELETE', 'turo_blocked_bookings', (p ->> 'booking')::uuid, jsonb_build_object('freed_on_turo', true));
    return jsonb_build_object('done', true);
  else
    return app.calendar_sync_do_0062(p_by, p_name, p);
  end case;
end $$;

-- ================================================================ 6. the site check: alerts that do not spam
alter table uptime_checks drop constraint if exists uptime_checks_status_check;
alter table uptime_checks add constraint uptime_checks_status_check check (status in ('ok', 'failing', 'unknown', 'waiting'));
alter table uptime_checks add column if not exists failing_since timestamptz;
update uptime_checks set failing_since = coalesce(last_ok_at, last_checked_at) where status = 'failing';
alter table site_alerts
  add column if not exists real_at timestamptz,              -- when it became a real outage (the alert minutes passed)
  add column if not exists emailed_at timestamptz,
  add column if not exists recovery_sent_at timestamptz,
  add column if not exists held_reason text,                 -- why a real outage was not emailed yet: quiet hours, the daily limit
  add column if not exists full_outage boolean not null default false;
-- 0062 emailed at once and sent the recovery when it passed: nothing of those goes again
update site_alerts set emailed_at = opened_at, real_at = opened_at where emailed and emailed_at is null;
update site_alerts set recovery_sent_at = resolved_at where emailed and resolved_at is not null and recovery_sent_at is null;
comment on column site_alerts.emailed is 'Since 0063: true once the alert email went (real outages only, outside the quiet hours, within the daily limit).';

-- The marker of the database's schema: the newest migration. The website sends its own (header x-carmacars-schema,
-- web/src/lib/schema-marker.ts); a website older than the database is waiting for its deploy.
create or replace function app.schema_marker() returns text
language plpgsql stable security definer set search_path = public, app as $$
declare v text;
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    begin
      execute $q$select max(version) from supabase_migrations.schema_migrations where version ~ '^\d{4}$'$q$ into v;
    exception when others then v := null;
    end;
  end if;
  return greatest(coalesce(v, '0063'), '0063');
end $$;

create or replace function app.health_ping() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('ok', true, 'at', now(), 'schema', app.schema_marker())
$$;

drop function if exists app.uptime_record(text, boolean, integer, integer, text, timestamptz);
-- One result of a check: the counters, the status and the open problem. Nothing is emailed here (app.uptime_notify).
create or replace function app.uptime_record(p_key text, p_ok boolean, p_http integer default null, p_ms integer default null,
                                             p_detail text default null, p_now timestamptz default now(), p_waiting boolean default false) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  c uptime_checks;
  a site_alerts;
  v_ok boolean := p_ok or p_waiting;
  v_need integer;
begin
  insert into uptime_results (check_key, at, ok, http_status, ms, detail) values (p_key, p_now, v_ok, p_http, p_ms, left(p_detail, 500));
  update uptime_checks
     set consecutive_failures = case when v_ok then 0 else consecutive_failures + 1 end,
         failing_since = case when v_ok then null else coalesce(failing_since, p_now) end,
         last_checked_at = p_now, last_ok_at = case when v_ok then p_now else last_ok_at end,
         last_http = p_http, last_ms = p_ms, last_detail = left(p_detail, 500)
   where key = p_key returning * into c;
  if c.key is null then return 'unknown check'; end if;
  v_need := case when c.kind = 'page' then ps.uptime_fail_threshold else 1 end;
  select * into a from site_alerts where check_key = p_key and resolved_at is null;
  if v_ok then
    update uptime_checks set status = case when p_waiting then 'waiting' else 'ok' end where key = p_key;
    if a.id is not null then
      update site_alerts set resolved_at = p_now where id = a.id;
      update tasks set status = 'done', completed_at = p_now, completion_note = 'Closed by itself: the site check passed again'
       where id = a.task_id and status in ('open', 'in_progress', 'waiting');
      return 'recovered';
    end if;
    return case when p_waiting then 'waiting' else 'ok' end;
  end if;
  if c.consecutive_failures < v_need then
    update uptime_checks set status = case when status = 'failing' then 'failing' when status = 'unknown' then 'unknown' else 'ok' end where key = p_key;
    return 'failed ' || c.consecutive_failures || ' of ' || v_need;
  end if;
  update uptime_checks set status = 'failing' where key = p_key;
  if a.id is not null then
    update site_alerts set detail = left(p_detail, 500), failures = c.consecutive_failures where id = a.id;
    return 'still failing';
  end if;
  insert into site_alerts (check_key, opened_at, detail, failures, emailed) values (p_key, p_now, left(p_detail, 500), c.consecutive_failures, false);
  return 'problem';
end $$;

create or replace function app.uptime_quiet(p_now timestamptz default now()) returns boolean
language sql stable security definer set search_path = public, app as $$
  select case when s.uptime_quiet_from_hour = s.uptime_quiet_until_hour then false
              when s.uptime_quiet_from_hour > s.uptime_quiet_until_hour
                then app.local_hour(p_now) >= s.uptime_quiet_from_hour or app.local_hour(p_now) < s.uptime_quiet_until_hour
              else app.local_hour(p_now) >= s.uptime_quiet_from_hour and app.local_hour(p_now) < s.uptime_quiet_until_hour end
    from (select (app.settings(app.local_date(p_now))).*) s
$$;

-- After each round: which open problems are real outages (task and, within the rules, one email), and which
-- recoveries to send. Error 1102 blips and single failures never get here long enough to email.
create or replace function app.uptime_notify(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  v_quiet boolean := app.uptime_quiet(p_now);
  v_sent integer := (select count(*) from site_alerts where emailed_at >= app.local_midnight(app.local_date(p_now)));
  v_full boolean := exists (select 1 from uptime_checks where key = 'home' and enabled and status = 'failing'
                               and failing_since <= p_now - make_interval(mins => ps.uptime_quiet_outage_minutes));
  r record;
  v_mins integer;
  v_task uuid;
  v_alerts integer := 0;
  v_recovered integer := 0;
begin
  for r in select a.id, a.task_id, a.emailed, a.real_at, c.key, c.kind, c.label, c.advice, c.failing_since, a.detail
             from site_alerts a join uptime_checks c on c.key = a.check_key
            where a.resolved_at is null order by a.opened_at, c.sort loop
    v_mins := case when r.kind = 'page' then ps.uptime_page_alert_minutes when r.key = 'email' then ps.uptime_email_alert_minutes
                   when r.key = 'stripe' then ps.uptime_stripe_alert_minutes when r.key = 'backup' then 0 end;
    -- scheduled jobs: never emailed (Site health and the morning digest)
    continue when v_mins is null or r.failing_since is null or r.failing_since > p_now - make_interval(mins => v_mins);
    if r.real_at is null then
      v_task := app.raise_task(p_type => 'site_alert', p_title => left('Site problem: ' || r.label, 200),
        p_detail => left(coalesce(r.detail, 'The check failed') || '. ' || r.advice, 2000), p_dedupe => 'site_alert:' || r.id);
      update site_alerts set real_at = p_now, task_id = v_task where id = r.id;
    end if;
    continue when r.emailed;
    if v_quiet and not (v_full and r.kind = 'page') then
      update site_alerts set held_reason = 'Quiet hours: emailed in the morning if it lasts' where id = r.id;
      continue;
    end if;
    if v_sent >= ps.uptime_max_alert_emails then
      update site_alerts set held_reason = format('Daily limit of %s alert emails reached', ps.uptime_max_alert_emails) where id = r.id;
      continue;
    end if;
    update site_alerts set emailed = true, emailed_at = p_now, held_reason = null, full_outage = v_full and r.kind = 'page' where id = r.id;
    perform app.emit_event('staff_site_alert', 'site_alert', r.id, '{}'::jsonb, 'staff_site_alert:' || r.id);
    v_sent := v_sent + 1;
    v_alerts := v_alerts + 1;
  end loop;
  -- one recovery email per emailed incident; in the quiet hours only for a full outage emailed in the night
  for r in select a.id, a.full_outage from site_alerts a
            where a.emailed and a.resolved_at is not null and a.recovery_sent_at is null and a.resolved_at > p_now - interval '2 days' loop
    continue when v_quiet and not r.full_outage;
    update site_alerts set recovery_sent_at = p_now where id = r.id;
    perform app.emit_event('staff_site_recovered', 'site_alert', r.id, '{}'::jsonb, 'staff_site_recovered:' || r.id);
    v_recovered := v_recovered + 1;
  end loop;
  return jsonb_build_object('alerts', v_alerts, 'recovered', v_recovered, 'quiet', v_quiet, 'sent_today', v_sent);
end $$;

-- What a page probe answered: ok, a failure in words, or (the health check answering 404 from a website older than the
-- database) waiting for the website deploy.
create or replace function app.uptime_page_result(p_key text, p_status integer, p_headers jsonb, p_body text, p_timed_out boolean, p_error text,
                                                  p_ms integer, p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v_site text := (select lower(value) from jsonb_each_text(coalesce(p_headers, '{}'::jsonb)) h(key, value) where lower(h.key) = 'x-carmacars-schema' limit 1);
  v_db text := app.schema_marker();
begin
  if p_key = 'health' and p_status = 404 and coalesce(p_timed_out, false) = false and (v_site is null or v_site < v_db) then
    return app.uptime_record(p_key, true, p_status, p_ms,
      format('Waiting for the website deploy: the website (%s) is older than the database (%s), so /api/health is not there yet', coalesce(v_site, 'before 0063'), v_db),
      p_now, true);
  end if;
  return app.uptime_record(p_key,
    p_status between 200 and 399 and coalesce(p_timed_out, false) = false and not (p_key = 'health' and coalesce(p_body, '') !~ '"ok"\s*:\s*true'),
    p_status, p_ms,
    case when p_key = 'health' and p_status between 200 and 399 and coalesce(p_body, '') !~ '"ok"\s*:\s*true' then 'The health check answered without "ok": the site could not reach the database'
         else app.uptime_page_detail(p_status, p_body, p_timed_out, p_error) end, p_now);
end $$;

create or replace function app.job_uptime(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  r record;
  v_id bigint;
  v_collected integer := 0;
  v_sent integer := 0;
  v_due boolean;
  v_net boolean := to_regclass('net._http_response') is not null;
  c uptime_checks;
  v_url text;
begin
  if not ps.uptime_enabled then return 'off'; end if;
  -- 1. answers of the pages asked before
  if v_net then
    for r in execute $q$select p.request_id, p.check_key, p.sent_at, x.status_code, x.timed_out, x.error_msg, x.headers, left(x.content, 4000) as body, x.created
                          from uptime_probes p left join net._http_response x on x.id = p.request_id$q$ loop
      if r.created is null and r.sent_at > p_now - interval '3 minutes' then continue; end if;
      if r.created is null then
        perform app.uptime_record(r.check_key, false, null, null, 'No answer within 3 minutes', p_now);
      else
        perform app.uptime_page_result(r.check_key, r.status_code, r.headers, r.body, r.timed_out, r.error_msg,
          greatest(0, (extract(epoch from r.created - r.sent_at) * 1000)::integer), p_now);
      end if;
      delete from uptime_probes where request_id = r.request_id;
      v_collected := v_collected + 1;
    end loop;
  end if;
  -- 2. time for the next round?
  v_due := not exists (select 1 from uptime_checks where kind = 'internal' and enabled and last_checked_at > p_now - make_interval(mins => ps.uptime_interval_minutes) + interval '30 seconds');
  if v_due then
    perform app.uptime_internal(p_now);
    if v_net then
      for c in select * from uptime_checks where kind = 'page' and enabled order by sort loop
        if exists (select 1 from uptime_probes p where p.check_key = c.key) then continue; end if;
        v_url := app.uptime_url(c.key);
        execute $q$select net.http_get(url := $1, headers := jsonb_build_object('User-Agent', 'CarmaCars site check', 'Cache-Control', 'no-cache'),
                                       timeout_milliseconds := 15000)$q$ into v_id using v_url;
        insert into uptime_probes (request_id, check_key, url, sent_at) values (v_id, c.key, v_url, p_now) on conflict do nothing;
        v_sent := v_sent + 1;
      end loop;
    end if;
    delete from uptime_results where at < p_now - make_interval(days => ps.uptime_keep_days);
  end if;
  -- 3. emails for real outages and recoveries (every minute, so the morning's held alerts go at 07:00)
  perform app.uptime_notify(p_now);
  if to_regclass('cron.job_run_details') is not null and app.local_hour(p_now) = 4 and extract(minute from p_now at time zone 'America/Toronto') < 5 then
    begin
      execute $q$delete from cron.job_run_details where end_time < $1 - interval '14 days'$q$ using p_now;
    exception when others then null;
    end;
  end if;
  return format('collected %s, asked %s', v_collected, v_sent);
end $$;

-- Admin > Today: the status panel, with what was emailed or held, and the waiting state.
create or replace function app.site_health(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings();
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object(
    'enabled', ps.uptime_enabled, 'interval', ps.uptime_interval_minutes, 'alert_email', ps.uptime_alert_email,
    'rules', jsonb_build_object('page_minutes', ps.uptime_page_alert_minutes, 'email_minutes', ps.uptime_email_alert_minutes,
                                'stripe_minutes', ps.uptime_stripe_alert_minutes, 'max_emails', ps.uptime_max_alert_emails,
                                'quiet_from', ps.uptime_quiet_from_hour, 'quiet_until', ps.uptime_quiet_until_hour, 'quiet_outage_minutes', ps.uptime_quiet_outage_minutes,
                                'emailed_today', (select count(*) from site_alerts where emailed_at >= app.local_midnight(app.local_date(now())))),
    'checks', coalesce((select jsonb_agg(jsonb_build_object('key', c.key, 'label', c.label, 'kind', c.kind, 'status', c.status,
                 'checked_at', c.last_checked_at, 'ok_at', c.last_ok_at, 'http', c.last_http, 'ms', c.last_ms, 'detail', c.last_detail,
                 'failures', c.consecutive_failures, 'failing_since', c.failing_since, 'advice', c.advice,
                 'day', (select jsonb_build_object('checks', count(*), 'failed', count(*) filter (where not u.ok))
                           from uptime_results u where u.check_key = c.key and u.at > now() - interval '24 hours')) order by c.sort)
               from uptime_checks c where c.enabled), '[]'::jsonb),
    'open', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'label', c.label, 'opened_at', a.opened_at, 'detail', a.detail, 'emailed', a.emailed,
                                'real', a.real_at is not null, 'held', a.held_reason, 'advice', c.advice) order by a.opened_at)
               from site_alerts a join uptime_checks c on c.key = a.check_key where a.resolved_at is null), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('label', c.label, 'opened_at', a.opened_at, 'resolved_at', a.resolved_at, 'detail', a.detail, 'emailed', a.emailed) order by a.opened_at desc)
               from (select * from site_alerts where resolved_at is not null and opened_at > now() - interval '7 days' order by opened_at desc limit 10) a
               join uptime_checks c on c.key = a.check_key), '[]'::jsonb));
end $$;

-- The day's site check in one line of the Admin's morning digest (the problems that did not email).
create or replace function app.site_check_day_line(p_from timestamptz, p_to timestamptz) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with f as (
    select c.label, c.sort, count(*) as n, count(*) filter (where u.detail ~ '1102') as e1102
      from uptime_results u join uptime_checks c on c.key = u.check_key
     where not u.ok and u.at >= p_from and u.at < p_to group by c.label, c.sort),
  a as (select count(*) filter (where emailed_at >= p_from and emailed_at < p_to) as emailed,
               count(*) filter (where opened_at >= p_from and opened_at < p_to) as opened,
               count(*) filter (where held_reason is not null and opened_at >= p_from and opened_at < p_to and not emailed) as held
          from site_alerts)
  select case when (select count(*) from f) = 0 and a.opened = 0 then null else jsonb_build_object(
    'line', format('Site check: %s failed check%s in the last 24 hours, %s', (select coalesce(sum(n), 0) from f),
                   case when (select coalesce(sum(n), 0) from f) = 1 then '' else 's' end,
                   case when a.emailed = 0 then 'no alert email' when a.emailed = 1 then '1 alert email' else a.emailed || ' alert emails' end),
    'meta', left(coalesce((select string_agg(f.label || ' ' || f.n || case when f.e1102 > 0 then format(' (Error 1102: %s)', f.e1102) else '' end, ', ' order by f.sort) from f), '')
                 || case when a.held > 0 then format('; %s held by the quiet hours or the daily limit', a.held) else '' end, 500)) end
    from a
$$;

alter function app.notify_digests(text, uuid, timestamptz) rename to notify_digests_pre0063;
create or replace function app.notify_digests(p_slot text, p_run uuid, p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb;
begin
  if p_slot = 'morning' then
    v := app.site_check_day_line(p_now - interval '24 hours', p_now);
    if v is not null then
      insert into staff_digest_items (role, code, digest_slot, line, meta, url, dedupe_key, created_at)
      values ('admin', 'staff_site_alert', 'next', v ->> 'line', nullif(v ->> 'meta', ''), (app.settings()).notify_base_url || '/admin#site-health',
              'site_check_day:' || app.local_date(p_now), p_now - interval '1 second')
      on conflict (dedupe_key) do nothing;
    end if;
  end if;
  return app.notify_digests_pre0063(p_slot, p_run, p_now);
end $$;

-- ================================================================ 7. Admin To do
alter function app.admin_todo(uuid) rename to admin_todo_0062;
create or replace function app.admin_todo(p_admin uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.admin_todo_0062(p_admin);
begin
  -- site problems: only the real outages (a short problem is on Site health only)
  v := jsonb_set(v, '{items}', (select jsonb_agg(case when i ->> 'key' = 'site_alerts'
                                                      then i || jsonb_build_object('count', (select count(*) from site_alerts where resolved_at is null and real_at is not null))
                                                      else i end order by n)
                                  from jsonb_array_elements(v -> 'items') with ordinality x(i, n)));
  return jsonb_set(v, '{items}', (v -> 'items') || jsonb_build_array(
    jsonb_build_object('key', 'turo_emails', 'label', 'Turo emails to check', 'button', 'Check them', 'href', '/admin/calendar-sync#turo-review',
                       'count', (select count(*) from turo_inbound_emails where status = 'review')),
    jsonb_build_object('key', 'gmail_forwarding', 'label', 'Gmail forwarding to confirm (Turo by email)', 'button', 'See the code', 'href', '/admin/calendar-sync#turo',
                       'count', (select count(*) from turo_inbound_emails e where e.kind = 'forwarding_confirmation' and e.status = 'notice'
                                    and e.received_at > now() - interval '7 days'
                                    and not exists (select 1 from turo_inbound_emails x where x.kind not in ('forwarding_confirmation', 'not_turo') and x.received_at > e.received_at)))));
end $$;

-- ================================================================ 8. the doors and privileges
create or replace function app.ops63(p_user uuid, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  return app.calendar_sync_do(p_user, p_name, p);
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0063;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
begin
  if p_call in ('va_do', 'admin_do', 'ops_do') and p_name in ('turo_link_save', 'turo_link_remove', 'turo_trip_add', 'turo_trip_cancel', 'turo_review_dismiss',
                                                             'turo_confirmation_dismiss', 'turo_block_done', 'turo_unblock_done') then
    if p_ ? '_va' then perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.ops63(p_user, p_call, p_name, p_ - '_va');
  end if;
  return app.door_pre0063(p_user, p_aal, p_call, p_name, p);
end $$;

-- server wrappers (the Worker's inbound email route, service role)
create or replace function public.turo_match_keys() returns jsonb
language sql security definer set search_path = public, app as $$ select app.turo_match_keys() $$;
create or replace function public.turo_email_receive(p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.turo_email_receive(p) $$;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array[
              'platform_name', 'calendar_feeds_due', 'turo_email_feed', 'turo_feed_refresh', 'turo_trip_apply', 'turo_match_keys', 'turo_email_receive',
              'calendar_feed_row', 'turo_to_block', 'calendar_sync_read', 'calendar_sync_do', 'schema_marker', 'health_ping', 'uptime_record',
              'uptime_quiet', 'uptime_notify', 'uptime_page_result', 'job_uptime', 'site_health', 'site_check_day_line', 'notify_digests',
              'admin_todo', 'ops63', 'door']))
        or (n.nspname = 'public' and p.proname = any (array['turo_match_keys', 'turo_email_receive']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- Each renamed function keeps its privileges; the function in its place gets the same.
do $$
declare
  r record;
  v_new regprocedure;
  g text;
begin
  for r in select p.oid, m.new_name, oidvectortypes(p.proargtypes) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             join (values ('door_pre0063', 'door'), ('admin_todo_0062', 'admin_todo'), ('notify_digests_pre0063', 'notify_digests'),
                          ('calendar_sync_read_0062', 'calendar_sync_read'), ('calendar_sync_do_0062', 'calendar_sync_do')) m(old_name, new_name)
               on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    execute format('revoke all on function %s from public, anon, authenticated', v_new);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;

-- ================================================================ 9. the alert emails' trigger text (emails/catalogue.json)
update notification_catalogue set trigger_text = 'Site check (every 5 minutes, from the database): a real outage only. A page (home, a car page, sign-in, the site''s health check) failing every check for uptime_page_alert_minutes (15), emails failing or stuck for uptime_email_alert_minutes (30), the nightly backup failing, or Stripe webhooks failing for uptime_stripe_alert_minutes (30). Short problems such as a single Error 1102 never email: they show on Site health and in the Admin''s morning digest. At most uptime_max_alert_emails (3) a day, none from uptime_quiet_from_hour (23) to uptime_quiet_until_hour (7) Toronto unless the whole site has been down for uptime_quiet_outage_minutes (60). Sent to the alert address in Program settings (uptime_alert_email), once per problem.',
       emitted_by = 'app.uptime_notify (0063)', updated_at = now() where code = 'staff_site_alert';
update notification_catalogue set trigger_text = 'Site check: a problem that sent a site alert passed its check again. One email per alert that was emailed, to the same address. During the quiet hours it waits for the morning, unless the alert was a full outage emailed in the night.',
       emitted_by = 'app.uptime_notify (0063)', updated_at = now() where code = 'staff_site_recovered';

do $$
begin
  if to_regclass('cron.job') is not null then
    -- Turo by email: the log and the review excerpts also go when no email arrives for a while
    perform cron.schedule('carmacars-turo-email-housekeeping', '17 4 * * *',
      $q$delete from turo_inbound_emails where received_at < now() - make_interval(days => (app.settings()).turo_email_keep_days);
         update turo_inbound_emails set excerpt = null where excerpt is not null and received_at < now() - interval '14 days';
         delete from turo_blocked_bookings where ends_at < now() - interval '60 days'$q$);
  end if;
end $$;

-- ================================================================ 10. the guides for this release
create or replace function app.guide_release_0063(p_portal text, p_slug text, p_kind text, p_after text, p_base_md text, p_title text, p_blurb text,
                                                  p_md text, p_html text) returns text
language sql security definer set search_path = public, app as $$
  select app.guide_release_section(p_portal, p_slug, p_kind, p_after, p_base_md, p_title, p_blurb, p_md, p_html)
$$;
revoke all on function app.guide_release_0063(text, text, text, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function app.guide_release_0063(text, text, text, text, text, text, text, text, text) to service_role;

-- GUIDES 0063 START (generated by supabase/seed/0063_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_0063('admin', 'calendar-sync-with-turo-and-other-platforms', 'chapter', 'calendars', 'A car rented on Turo, Getaround or another site must never be booked twice. Calendar sync works both ways through calendar links (iCal): their trips block the car here, and our bookings block it there.

## Bring Turo''s trips in

**Cars** > **Calendar sync**. Do this once for each car listed on another platform.

1. On Turo, open the car''s calendar and its calendar sync (export) settings, and copy the calendar link (it ends in .ics). On Getaround or another site, look for "Export calendar" or "iCal".
2. On Calendar sync, find the car, open **Add a calendar link**, choose the platform and paste the link. Press **Add the link**.
3. The link is read at once and then every 10 minutes. The card shows "Working", when it was read and the next trips it found.
4. Each trip becomes an "External booking" block on the car, with the turnaround before and after it. The car cannot be requested, offered or booked here for those times, and the public calendar shows them as taken.
5. A trip that moves or is cancelled on the platform moves or frees the block at the next read. **Sync now** reads the link at once.

## Send our bookings to Turo

1. Each car has its own CarmaCars link under "This car''s CarmaCars calendar": one for Turo, one for Getaround, one for any other platform. Each leaves out the trips that came from that platform, so nothing comes back twice.
2. Press **Copy** next to "For Turo" and paste it into the car''s calendar import on Turo. Do the same for each platform.
3. The link shows only "Booked" for our bookings (with the turnaround) and our blocks. No names, numbers or prices.
4. If a link was shared by mistake, press **Make a new link**. The old one stops working at once: paste the new one into every platform again.

## Double bookings

If a trip on another platform overlaps a confirmed CarmaCars booking of the same car, we tell you at once.

- An urgent Fleet task "Double booking: on Turo and CC-1042", a line on To do and an email to Fleet and the Admins.
- Calendar sync lists it at the top with both trips. Move, swap or cancel one of the two. The task closes by itself once they no longer overlap.
- An offer or a booking awaiting payment over a trip on another platform raises a task for customer service: its payment would be refused, so withdraw the offer or change the dates.

## A link that stops working

A platform answers an error when a link is reset or removed. After 3 failed reads in a row (a Program setting) Fleet gets a task and an email, and To do shows "Calendar links not working". The trips already read stay on the calendar. Copy the link from the platform again, remove the old one and add the new one.

> Good to know: A block from another platform can be removed from the calendar like any block; calendar sync will not put it back. In Program settings, "Calendar sync": on or off, how often links are read (10 minutes), failures before an alert, and whether our links include the turnaround.
', 'Calendar sync with Turo and other platforms', 'Turo by email (the Gmail filter, the car''s name on Turo, emails to check, Done on Turo), calendar links for other platforms, clashes.',
  'A car rented on Turo, Getaround or another site must never be booked twice. Turo has no calendar link, so Turo works by email: Turo''s trip emails block the car here, and you block our bookings on Turo by hand. Getaround, Google Calendar and other sites work through calendar links (iCal), both ways.

## Set up Turo by email (once)

Turo emails rent@carmacars.ca for every trip booked, changed, extended or cancelled. One Gmail filter forwards those emails to trips@in.carmacars.ca, and each one blocks the car here within a minute.

1. In Gmail (rent@carmacars.ca): Settings, See all settings, Forwarding and POP/IMAP. Press Add a forwarding address and type trips@in.carmacars.ca.
2. Gmail sends a confirmation code to that address. Open **Cars** > **Calendar sync**: the code shows under "Turo by email" (and To do shows "Gmail forwarding to confirm"). Type it in Gmail and press Verify. Leave forwarding itself off: only the filter forwards.
3. In Gmail, in the search box, show the search options. From: turo.com. Press Create filter, tick Forward it to: trips@in.carmacars.ca, and press Create filter.
4. On Calendar sync, for each car on Turo, press **This car is on Turo**, type its name exactly as Turo''s emails show it (for example Mercedes-Benz GLC 2021) and press **Save**. The Turo car number (the number at the end of its Turo page address) is optional; the plate and VIN are matched too.

## Turo trips on the calendar

1. A trip booked on Turo becomes an "External booking" block on the car, with the turnaround before and after it. The car cannot be requested, offered or booked here for those times.
2. A changed or extended trip moves its block; a cancelled trip frees the car. An older email never undoes a newer one.
3. Each car lists its Turo trips: the dates, the Turo trip number and the guest''s first name. Press Cancelled if Turo cancelled a trip and its email did not come.
4. **Add a Turo trip**: the trip start and end (Toronto time), and the Turo trip number if you have it. Use it for a trip whose email did not come.
5. Only what the email says is kept: the car, the dates, the trip number and the guest''s first name. The email itself is never stored.

## Turo emails to check

When the reader is not sure (which car, the dates or the trip number), the email waits under "Turo emails to check", with a Fleet task and a line on To do.

1. Read what was found and the short excerpt (no email addresses, phone numbers or links). Check the trip on Turo.
2. Press **Add as a Turo trip**, choose the car, check the dates and press **Add this trip**. The email is checked and the task closes.
3. Not a trip (a request, a message)? Press **Dismiss**.

## Block our bookings on Turo (Done on Turo)

Turo cannot read our calendar. Each car on Turo lists, under "Block on Turo", the CarmaCars bookings not yet blocked there.

1. Open the car''s calendar on Turo and block the dates shown (the turnaround is included).
2. Press **Done on Turo**. The booking leaves the list.
3. If the booking''s dates change, it comes back with the old dates to free first. A booking cancelled here shows the dates to free on Turo: free them, then press Freed on Turo.

## Getaround, Google Calendar and other calendar links

**Cars** > **Calendar sync**, for a platform that gives a calendar (iCal) link.

1. Copy the car''s calendar link on the platform (look for "Export calendar" or "iCal"). On Calendar sync, open **Add a calendar link**, choose Getaround, Google Calendar or Other, paste the link and press **Add the link**.
2. The link is read at once and then every 10 minutes; **Sync now** reads it at once. Each trip becomes an "External booking" block with the turnaround.
3. Send our bookings there: press **Copy** next to "For Getaround" (or "For Google Calendar", or "For any other platform") under "This car''s CarmaCars calendar" and paste it into the platform''s calendar import. It shows only "Booked" times: no names, numbers or prices.
4. If a link was shared by mistake, press **Make a new link**. The old one stops working at once: paste the new one into every platform again.

## Double bookings

If a trip on Turo or another platform overlaps a confirmed CarmaCars booking of the same car, we tell you at once.

- An urgent Fleet task "Double booking: on Turo and CC-1042", a line on To do and an email to Fleet and the Admins.
- Calendar sync lists it at the top with both trips. Move, swap or cancel one of the two. The task closes by itself once they no longer overlap.
- An offer or a booking awaiting payment over a trip on another platform raises a task for customer service: its payment would be refused, so withdraw the offer or change the dates.

## A link that stops working

A platform answers an error when a link is reset or removed. After 3 failed reads in a row (a Program setting) Fleet gets a task and an email, and To do shows "Calendar links not working". The trips already read stay on the calendar. Copy the link from the platform again, remove the old one and add the new one.

> Good to know: A block from another platform can be removed from the calendar like any block; calendar sync will not put it back. In Program settings, "Calendar sync" and "Turo by email": on or off, how often links are read, the inbound address, the mailboxes allowed to forward (rent@carmacars.ca) and how long the email log is kept (90 days).
',
  '<p class="gd-p">A car rented on Turo, Getaround or another site must never be booked twice. Turo has no calendar link, so Turo works by email: Turo&#39;s trip emails block the car here, and you block our bookings on Turo by hand. Getaround, Google Calendar and other sites work through calendar links (iCal), both ways.</p><section class="gd-task" id="calendar-sync-with-turo-and-other-platforms-set-up-turo-by-email-once" data-gd-task><h2 class="gd-h2">Set up Turo by email (once)</h2><p class="gd-p">Turo emails rent@carmacars.ca for every trip booked, changed, extended or cancelled. One Gmail filter forwards those emails to trips@in.carmacars.ca, and each one blocks the car here within a minute.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">In Gmail (rent@carmacars.ca): Settings, See all settings, Forwarding and POP/IMAP. Press Add a forwarding address and type trips@in.carmacars.ca.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Gmail sends a confirmation code to that address. Open <b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Calendar sync</b>: the code shows under &quot;Turo by email&quot; (and To do shows &quot;Gmail forwarding to confirm&quot;). Type it in Gmail and press Verify. Leave forwarding itself off: only the filter forwards.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">In Gmail, in the search box, show the search options. From: turo.com. Press Create filter, tick Forward it to: trips@in.carmacars.ca, and press Create filter.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">On Calendar sync, for each car on Turo, press <b class="gd-ui">This car is on Turo</b>, type its name exactly as Turo&#39;s emails show it (for example Mercedes-Benz GLC 2021) and press <b class="gd-ui">Save</b>. The Turo car number (the number at the end of its Turo page address) is optional; the plate and VIN are matched too.</div></li></ol></div></section><section class="gd-task" id="calendar-sync-with-turo-and-other-platforms-turo-trips-on-the-calendar" data-gd-task><h2 class="gd-h2">Turo trips on the calendar</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A trip booked on Turo becomes an &quot;External booking&quot; block on the car, with the turnaround before and after it. The car cannot be requested, offered or booked here for those times.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">A changed or extended trip moves its block; a cancelled trip frees the car. An older email never undoes a newer one.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each car lists its Turo trips: the dates, the Turo trip number and the guest&#39;s first name. Press Cancelled if Turo cancelled a trip and its email did not come.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Add a Turo trip</b>: the trip start and end (Toronto time), and the Turo trip number if you have it. Use it for a trip whose email did not come.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Only what the email says is kept: the car, the dates, the trip number and the guest&#39;s first name. The email itself is never stored.</div></li></ol></div></section><section class="gd-task" id="calendar-sync-with-turo-and-other-platforms-turo-emails-to-check" data-gd-task><h2 class="gd-h2">Turo emails to check</h2><p class="gd-p">When the reader is not sure (which car, the dates or the trip number), the email waits under &quot;Turo emails to check&quot;, with a Fleet task and a line on To do.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Read what was found and the short excerpt (no email addresses, phone numbers or links). Check the trip on Turo.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Add as a Turo trip</b>, choose the car, check the dates and press <b class="gd-ui">Add this trip</b>. The email is checked and the task closes.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Not a trip (a request, a message)? Press <b class="gd-ui">Dismiss</b>.</div></li></ol></div></section><section class="gd-task" id="calendar-sync-with-turo-and-other-platforms-block-our-bookings-on-turo-done-on-turo" data-gd-task><h2 class="gd-h2">Block our bookings on Turo (Done on Turo)</h2><p class="gd-p">Turo cannot read our calendar. Each car on Turo lists, under &quot;Block on Turo&quot;, the CarmaCars bookings not yet blocked there.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the car&#39;s calendar on Turo and block the dates shown (the turnaround is included).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Done on Turo</b>. The booking leaves the list.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">If the booking&#39;s dates change, it comes back with the old dates to free first. A booking cancelled here shows the dates to free on Turo: free them, then press Freed on Turo.</div></li></ol></div></section><section class="gd-task" id="calendar-sync-with-turo-and-other-platforms-getaround-google-calendar-and-other-calendar-links" data-gd-task><h2 class="gd-h2">Getaround, Google Calendar and other calendar links</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Calendar sync</b>, for a platform that gives a calendar (iCal) link.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Copy the car&#39;s calendar link on the platform (look for &quot;Export calendar&quot; or &quot;iCal&quot;). On Calendar sync, open <b class="gd-ui">Add a calendar link</b>, choose Getaround, Google Calendar or Other, paste the link and press <b class="gd-ui">Add the link</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The link is read at once and then every 10 minutes; <b class="gd-ui">Sync now</b> reads it at once. Each trip becomes an &quot;External booking&quot; block with the turnaround.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Send our bookings there: press <b class="gd-ui">Copy</b> next to &quot;For Getaround&quot; (or &quot;For Google Calendar&quot;, or &quot;For any other platform&quot;) under &quot;This car&#39;s CarmaCars calendar&quot; and paste it into the platform&#39;s calendar import. It shows only &quot;Booked&quot; times: no names, numbers or prices.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">If a link was shared by mistake, press <b class="gd-ui">Make a new link</b>. The old one stops working at once: paste the new one into every platform again.</div></li></ol></div></section><section class="gd-task" id="calendar-sync-with-turo-and-other-platforms-double-bookings" data-gd-task><h2 class="gd-h2">Double bookings</h2><p class="gd-p">If a trip on Turo or another platform overlaps a confirmed CarmaCars booking of the same car, we tell you at once.</p><ul class="gd-ul"><li>An urgent Fleet task &quot;Double booking: on Turo and CC-1042&quot;, a line on To do and an email to Fleet and the Admins.</li><li>Calendar sync lists it at the top with both trips. Move, swap or cancel one of the two. The task closes by itself once they no longer overlap.</li><li>An offer or a booking awaiting payment over a trip on another platform raises a task for customer service: its payment would be refused, so withdraw the offer or change the dates.</li></ul></section><section class="gd-task" id="calendar-sync-with-turo-and-other-platforms-a-link-that-stops-working" data-gd-task><h2 class="gd-h2">A link that stops working</h2><p class="gd-p">A platform answers an error when a link is reset or removed. After 3 failed reads in a row (a Program setting) Fleet gets a task and an email, and To do shows &quot;Calendar links not working&quot;. The trips already read stay on the calendar. Copy the link from the platform again, remove the old one and add the new one.</p><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A block from another platform can be removed from the calendar like any block; calendar sync will not put it back. In Program settings, &quot;Calendar sync&quot; and &quot;Turo by email&quot;: on or off, how often links are read, the inbound address, the mailboxes allowed to forward (rent@carmacars.ca) and how long the email log is kept (90 days).</div></aside></section>');
select app.guide_release_0063('admin', 'settings', 'chapter', 'search-car-pages-landing-pages-and-guides', 'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Coverage prices, Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.
7. Calendar sync, Booking recovery emails and Site check: how often calendar links are read, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca).
8. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")

## Official ServiceOntario forms

The five official forms are loaded with a draft mapping to the owner, car, company and lender details. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Press **Download a filled preview** for one car and check each value against the form.
3. Change a field if needed: What goes in it (or "The owner signs here"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed, and owners sign it with their other documents.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, or on paper.

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Staff**. Under Staff agreements, press **Send the agreement to sign** beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.
4. A field staff member''s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.
5. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
6. Your own PDF instead? **Send a PDF to sign** still works.
7. Signed on paper instead? Press **Record paper signature** in the same place and upload the scan.
8. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section''s history. There is nothing to review.
5. A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.
', 'Settings', 'Site, program settings, official forms mapping, insurers and the other lists.',
  'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Coverage prices, Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.
7. Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.
8. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")

## Official ServiceOntario forms

The five official forms are loaded with a draft mapping to the owner, car, company and lender details. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Press **Download a filled preview** for one car and check each value against the form.
3. Change a field if needed: What goes in it (or "The owner signs here"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed, and owners sign it with their other documents.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, or on paper.

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Staff**. Under Staff agreements, press **Send the agreement to sign** beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.
4. A field staff member''s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.
5. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
6. Your own PDF instead? **Send a PDF to sign** still works.
7. Signed on paper instead? Press **Record paper signature** in the same place and upload the scan.
8. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section''s history. There is nothing to review.
5. A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.
',
  '<p class="gd-p">Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.</p><section class="gd-task" id="settings-the-settings-page" data-gd-task><h2 class="gd-h2">The Settings page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Site setup lists what is still missing on the public site, with <b class="gd-ui">Open site settings</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Program settings: every timing and policy value.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Forms: the official ServiceOntario PDFs and what goes in each field.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Insurers: insurance companies billed for bookings.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-24-settings-desktop-89b31691.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:32.6%;top:33%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.8%;top:40.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.4%;top:40.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:25.8%;top:73.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:25.8%;top:84.9%" aria-hidden="true">5</span></div></div></figure></div><p class="gd-p">The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Coverage prices, Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.</p></section><section class="gd-task" id="settings-program-settings" data-gd-task><h2 class="gd-h2">Program settings</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month&#39;s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press <b class="gd-ui">Save the defaults</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Change a value and press <b class="gd-ui">Save</b>. It is saved as a new row from today; the rows before stay as they were.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/program</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/admin-25-program-settings-desktop-d16b066c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:25.8%;top:22%" aria-hidden="true">1</span><span class="gd-pin" style="left:27.8%;top:49%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="settings-official-serviceontario-forms" data-gd-task><h2 class="gd-h2">Official ServiceOntario forms</h2><p class="gd-p">The five official forms are loaded with a draft mapping to the owner, car, company and lender details. Until you check a form, owners get a data sheet with the values.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. Each form shows &quot;Mapping to check&quot; (a draft is ready) or &quot;Official PDF in use&quot;. Its notes say what the form is for and which boxes are left blank on purpose.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download a filled preview</b> for one car and check each value against the form.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Change a field if needed: What goes in it (or &quot;The owner signs here&quot;), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for owners</b>. Every owner&#39;s form of that kind is filled again, except ones already signed or filed, and owners sign it with their other documents.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A new version from ServiceOntario? Press <b class="gd-ui">Upload the official fillable PDF</b>: the fields of the same name keep their mapping.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company&#39;s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner&#39;s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person.</div></aside></section><section class="gd-task" id="settings-agreements-to-sign-investors-and-staff" data-gd-task><h2 class="gd-h2">Agreements to sign: investors and staff</h2><p class="gd-p">Investment agreements and staff agreements are made from the person&#39;s record and signed in their own portal, or on paper.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Investor: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Investors</b> and the investor. Under Investment agreement, press <b class="gd-ui">Send the agreement to sign</b>. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press <b class="gd-ui">Send to sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Once the investor signs, the agreement shows <b class="gd-ui">Awaiting countersignature</b> on the investor&#39;s page and on To do. It is not countersigned automatically: check it and press <b class="gd-ui">Countersign</b>. CarmaCars is bound once it has countersigned and the funds clear.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Staff: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Staff</b>. Under Staff agreements, press <b class="gd-ui">Send the agreement to sign</b> beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A field staff member&#39;s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Your own PDF instead? <b class="gd-ui">Send a PDF to sign</b> still works.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Signed on paper instead? Press <b class="gd-ui">Record paper signature</b> in the same place and upload the scan.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Sent by mistake? Press <b class="gd-ui">Withdraw</b> and give the reason.</div></li></ol></div></section><section class="gd-task" id="settings-the-user-guides" data-gd-task><h2 class="gd-h2">The user guides</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Guides</b>. The guide of each portal, as people read it under Guide.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each guide shows its version, when it was published and whether there are unpublished changes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a guide and press a section. Change its text and press <b class="gd-ui">Show the preview</b> to see it as people will. Press <b class="gd-ui">Save the draft</b>; each save is kept in the section&#39;s history.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Move a section with the arrows, hide it, or press <b class="gd-ui">Add a chapter</b>. Upload a screenshot under Screenshots and paste the line it gives you.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Publish version</b> (the next number). The portals show the new version at once.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.</div></li></ol></div></section><section class="gd-task" id="settings-the-guides-keep-up-by-themselves" data-gd-task><h2 class="gd-h2">The guides keep up by themselves</h2><p class="gd-p">After every update of the site that changes the portals, the guides are checked without anyone asking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal&#39;s own labels and menu, checked, and published. The PDFs of those guides are printed again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Such a section says <b class="gd-ui">Changed automatically on</b> and the date, in the list of guides and in the guide&#39;s editor. Not right? Open the section and press <b class="gd-ui">Revert</b>: the text it replaced comes back, published at once.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section&#39;s history. There is nothing to review.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The card &quot;The guides keep up by themselves&quot; at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.</div></aside></section><section class="gd-task" id="settings-insurers-and-the-other-lists" data-gd-task><h2 class="gd-h2">Insurers and the other lists</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press <b class="gd-ui">Add</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.</div></li></ol></div></section>');
select app.guide_release_0063('admin', 'email-backups-and-site-health', 'chapter', 'settings', 'Keep an eye on email use against the daily limit, the nightly backup and the occasional error page.

## Email

**Settings** > **Email log**

1. The banner shows today''s emails against the daily limit. From 80, Admins get a notice; near the limit, digests and marketing wait first and booking and sign-in emails are held last.
2. Filter the Outbox: All, Queued, Held, Sent, Failed, Suppressed or Skipped.
3. Open an email to **Resend** or **Cancel** it.
4. Suppressions: **Suppress an address** stops all mail to it; **Lift** undoes it.

![](/guides/img/admin-23-email-desktop-dad31712.jpg "desktop; size: 1440 760; address: carmacars.ca/admin/messages; pins: 1 56.5 31.7, 2 35.5 41.8, 3 81.9 52.6, 4 26.6 22.9")

## Backups

- The database is backed up every night, encrypted, kept for 30 days and test-restored on the spot.
- Every Monday the newest backup is checked again: it must be under 30 hours old and restore cleanly.
- A failed backup, or none for 30 hours, opens a site alert: an email, a task and a line on To do. Tell your developer the same day.
- Keep a copy of the backup key in the company password manager. Without it no backup can be read.

## Site health and alerts

**Today** > **To do**, the Site health card at the bottom.

1. Every 5 minutes the site checks itself: the home page, a car page, the sign-in page and the site''s health check, and also emails, scheduled jobs, the nightly backup and Stripe payments.
2. Each line shows Working, Problem or Not checked yet, what was found and how many checks failed in the last 24 hours.
3. A page that fails 3 checks in a row (a single Error 1102 does not count) opens an alert: an email to rent@carmacars.ca, an urgent task and "Site problems found by the site check" first on To do. Emails failing, a failed job or backup, or a Stripe event that failed alert at once.
4. When the check passes again you get one "Recovered" email and the task closes by itself. A new problem of the same kind within an hour shows on To do without another email.

> Good to know: The address the alerts go to and the timings are in Program settings, "Site check".

## When a page shows "Error 1102"

Our web host''s free plan sometimes stops a page that takes too long. Reload the page; you are still signed in. Moving to the Workers Paid plan removes it.
', 'Email, backups and site health', 'The email outbox and daily limit, suppressions, backups, the site check and its alerts, and Error 1102.',
  'Keep an eye on email use against the daily limit, the nightly backup and the occasional error page.

## Email

**Settings** > **Email log**

1. The banner shows today''s emails against the daily limit. From 80, Admins get a notice; near the limit, digests and marketing wait first and booking and sign-in emails are held last.
2. Filter the Outbox: All, Queued, Held, Sent, Failed, Suppressed or Skipped.
3. Open an email to **Resend** or **Cancel** it.
4. Suppressions: **Suppress an address** stops all mail to it; **Lift** undoes it.

![](/guides/img/admin-23-email-desktop-dad31712.jpg "desktop; size: 1440 760; address: carmacars.ca/admin/messages; pins: 1 56.5 31.7, 2 35.5 41.8, 3 81.9 52.6, 4 26.6 22.9")

## Backups

- The database is backed up every night, encrypted, kept for 30 days and test-restored on the spot.
- Every Monday the newest backup is checked again: it must be under 30 hours old and restore cleanly.
- A failed backup, or none for 30 hours, opens a site alert: an email (outside the quiet hours), a task and a line on To do. Tell your developer the same day.
- Keep a copy of the backup key in the company password manager. Without it no backup can be read.

## Site health and alerts

**Today** > **To do**, the Site health card at the bottom.

1. Every 5 minutes the site checks itself: the home page, a car page, the sign-in page and the site''s health check, and also emails, scheduled jobs, the nightly backup and Stripe payments.
2. Each line shows Working, Problem, Waiting for the website deploy or Not checked yet, what was found and how many checks failed in the last 24 hours.
3. Short problems, such as a single Error 1102, only show here and in your morning digest ("Site check: 6 failed checks in the last 24 hours, no alert email").
4. An email goes to rent@carmacars.ca only for a real outage: a page failing every check for 15 minutes, emails failing for 30 minutes, the nightly backup failing, or Stripe failing for 30 minutes. It also raises an urgent task and "Site problems found by the site check" first on To do. A failed scheduled job is never emailed.
5. At most 3 alert emails a day, and none from 11 pm to 7 am unless the whole site has been down for an hour. An outage held overnight is emailed at 7 am if it lasts. One "Recovered" email follows each alert, and the task closes by itself.
6. "Waiting for the website deploy" on the health check means the database was updated before the website: nothing is wrong, and it turns to Working after the deploy.

> Good to know: The alert address, the minutes before an email, the daily limit and the quiet hours are in Program settings, "Site check".

## When a page shows "Error 1102"

Our web host''s free plan sometimes stops a page that takes too long. Reload the page; you are still signed in. Moving to the Workers Paid plan removes it.
',
  '<p class="gd-p">Keep an eye on email use against the daily limit, the nightly backup and the occasional error page.</p><section class="gd-task" id="email-backups-and-site-health-email" data-gd-task><h2 class="gd-h2">Email</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Email log</b></p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The banner shows today&#39;s emails against the daily limit. From 80, Admins get a notice; near the limit, digests and marketing wait first and booking and sign-in emails are held last.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Filter the Outbox: All, Queued, Held, Sent, Failed, Suppressed or Skipped.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open an email to <b class="gd-ui">Resend</b> or <b class="gd-ui">Cancel</b> it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Suppressions: <b class="gd-ui">Suppress an address</b> stops all mail to it; <b class="gd-ui">Lift</b> undoes it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/messages</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/760"><img src="/guides/img/admin-23-email-desktop-dad31712.jpg" alt="" loading="lazy" decoding="async" width="1440" height="760"><span class="gd-pin" style="left:56.5%;top:31.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:35.5%;top:41.8%" aria-hidden="true">2</span><span class="gd-pin" style="left:81.9%;top:52.6%" aria-hidden="true">3</span><span class="gd-pin" style="left:26.6%;top:22.9%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="email-backups-and-site-health-backups" data-gd-task><h2 class="gd-h2">Backups</h2><ul class="gd-ul"><li>The database is backed up every night, encrypted, kept for 30 days and test-restored on the spot.</li><li>Every Monday the newest backup is checked again: it must be under 30 hours old and restore cleanly.</li><li>A failed backup, or none for 30 hours, opens a site alert: an email (outside the quiet hours), a task and a line on To do. Tell your developer the same day.</li><li>Keep a copy of the backup key in the company password manager. Without it no backup can be read.</li></ul></section><section class="gd-task" id="email-backups-and-site-health-site-health-and-alerts" data-gd-task><h2 class="gd-h2">Site health and alerts</h2><p class="gd-p"><b class="gd-ui">Today</b> &gt; <b class="gd-ui">To do</b>, the Site health card at the bottom.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every 5 minutes the site checks itself: the home page, a car page, the sign-in page and the site&#39;s health check, and also emails, scheduled jobs, the nightly backup and Stripe payments.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each line shows Working, Problem, Waiting for the website deploy or Not checked yet, what was found and how many checks failed in the last 24 hours.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Short problems, such as a single Error 1102, only show here and in your morning digest (&quot;Site check: 6 failed checks in the last 24 hours, no alert email&quot;).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">An email goes to rent@carmacars.ca only for a real outage: a page failing every check for 15 minutes, emails failing for 30 minutes, the nightly backup failing, or Stripe failing for 30 minutes. It also raises an urgent task and &quot;Site problems found by the site check&quot; first on To do. A failed scheduled job is never emailed.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">At most 3 alert emails a day, and none from 11 pm to 7 am unless the whole site has been down for an hour. An outage held overnight is emailed at 7 am if it lasts. One &quot;Recovered&quot; email follows each alert, and the task closes by itself.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">&quot;Waiting for the website deploy&quot; on the health check means the database was updated before the website: nothing is wrong, and it turns to Working after the deploy.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The alert address, the minutes before an email, the daily limit and the quiet hours are in Program settings, &quot;Site check&quot;.</div></aside></section><section class="gd-task" id="email-backups-and-site-health-when-a-page-shows-error-1102" data-gd-task><h2 class="gd-h2">When a page shows &quot;Error 1102&quot;</h2><p class="gd-p">Our web host&#39;s free plan sometimes stops a page that takes too long. Reload the page; you are still signed in. Moving to the Workers Paid plan removes it.</p></section>');
select app.guide_release_0063('va', 'fleet', 'chapter', 'finance', 'You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listing pipeline with its duplicate check and plate covering.

Your rail: Queue, Today, Field jobs, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.

## Schedule field jobs

1. Handovers and returns without a job are listed first. Every booking needs one.
2. Press **Schedule**: choose the kind, car, when, place, field staff and instructions.
3. Jobs, next three days: each with its field staff and whether they acknowledged it.
4. Change a job with **Assign**, **Reassign**, **Move** or **Cancel**.

![](/guides/img/va-fleet-02-field-jobs-desktop-b985927b.jpg "desktop; size: 1230 1180; address: carmacars.ca/va/fleet; pins: 1 15.4 10.4, 2 78.9 12.7, 3 11.4 68.6, 4 78.9 83.9")

## Daily checks

Twice a day: the opening check by 9:00 and the closing check by 18:00.

1. Open **Daily checks** and choose **Opening check** or **Closing check**.
2. Each line shows what was found. Tick OK, or Problem with a note.
3. Press **Save the opening check** (or **Save the closing check**). You can save it again.

![](/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg "desktop; size: 1230 820; address: carmacars.ca/va/checks; pins: 1 6.5 15.4, 2 44.7 42.0, 3 64.2 94.0")

## Photo reviews after a return

After each return, the field photo set waits under **Photo reviews**. Compare it with the pickup set. Press **Review done**, or **Ask for a re-shoot** if a photo is missing or unclear.

## Similar cars

A possible duplicate listing stops publishing until you decide.

1. Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.
2. Compare the permit, the plate and the photos.
3. Press **Not a duplicate** with a note when they are different cars, or **Same car** when they are.

![](/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg "desktop; size: 1230 460; address: carmacars.ca/va/similar-cars; pins: 1 23.6 30.4, 3 94.8 30.4")

## Listings and covering plates

1. Open **Listings**. A draft waiting shows Needs review. Open it.
2. The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.

![](/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg "desktop; size: 1230 340; address: carmacars.ca/va/listings; pins: 1 54.5 49.1")

3. Press **Cover the plate**. Check the suggested box; **Suggest the plate** asks again.
4. Drag over a plate to draw a box; drag a box to move it, its corner to resize it.
5. Choose **A CarmaCars plate**, **Pixelation** or **Blur**, then **Save the covered photo**.
6. No plate in the shot? **No plate visible on this photo**.

![](/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg "phone; size: 390 776; pins: 3 52.6 78.9, 4 50.0 43.8, 5 61.5 62.1, 6 43.1 92.3")

> Watch out: Publishing waits until every public photo is covered or marked. The covered photo replaces the public one; the original is kept privately.

## Calendar sync with Turo and other platforms

**Cars** > **Calendar sync**: a car listed on Turo or Getaround must never be booked twice.

1. On the platform, copy the car''s calendar link (iCal, it ends in .ics). Here, find the car, open **Add a calendar link**, choose the platform, paste it and press **Add the link**.
2. Its trips block the car here with the turnaround before and after, read every 10 minutes. The card shows "Working" and the next trips.
3. Copy the car''s CarmaCars link "For Turo" (or Getaround) with **Copy** and paste it into the platform''s calendar import. It shows only "Booked".
4. A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.
', 'Fleet', 'Field jobs, daily checks, photo reviews, similar cars and listings.',
  'You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listing pipeline with its duplicate check and plate covering.

Your rail: Queue, Today, Field jobs, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.

## Schedule field jobs

1. Handovers and returns without a job are listed first. Every booking needs one.
2. Press **Schedule**: choose the kind, car, when, place, field staff and instructions.
3. Jobs, next three days: each with its field staff and whether they acknowledged it.
4. Change a job with **Assign**, **Reassign**, **Move** or **Cancel**.

![](/guides/img/va-fleet-02-field-jobs-desktop-b985927b.jpg "desktop; size: 1230 1180; address: carmacars.ca/va/fleet; pins: 1 15.4 10.4, 2 78.9 12.7, 3 11.4 68.6, 4 78.9 83.9")

## Daily checks

Twice a day: the opening check by 9:00 and the closing check by 18:00.

1. Open **Daily checks** and choose **Opening check** or **Closing check**.
2. Each line shows what was found. Tick OK, or Problem with a note.
3. Press **Save the opening check** (or **Save the closing check**). You can save it again.

![](/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg "desktop; size: 1230 820; address: carmacars.ca/va/checks; pins: 1 6.5 15.4, 2 44.7 42.0, 3 64.2 94.0")

## Photo reviews after a return

After each return, the field photo set waits under **Photo reviews**. Compare it with the pickup set. Press **Review done**, or **Ask for a re-shoot** if a photo is missing or unclear.

## Similar cars

A possible duplicate listing stops publishing until you decide.

1. Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.
2. Compare the permit, the plate and the photos.
3. Press **Not a duplicate** with a note when they are different cars, or **Same car** when they are.

![](/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg "desktop; size: 1230 460; address: carmacars.ca/va/similar-cars; pins: 1 23.6 30.4, 3 94.8 30.4")

## Listings and covering plates

1. Open **Listings**. A draft waiting shows Needs review. Open it.
2. The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.

![](/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg "desktop; size: 1230 340; address: carmacars.ca/va/listings; pins: 1 54.5 49.1")

3. Press **Cover the plate**. Check the suggested box; **Suggest the plate** asks again.
4. Drag over a plate to draw a box; drag a box to move it, its corner to resize it.
5. Choose **A CarmaCars plate**, **Pixelation** or **Blur**, then **Save the covered photo**.
6. No plate in the shot? **No plate visible on this photo**.

![](/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg "phone; size: 390 776; pins: 3 52.6 78.9, 4 50.0 43.8, 5 61.5 62.1, 6 43.1 92.3")

> Watch out: Publishing waits until every public photo is covered or marked. The covered photo replaces the public one; the original is kept privately.

## Calendar sync with Turo and other platforms

**Cars** > **Calendar sync**: a car listed on Turo or Getaround must never be booked twice.

1. Turo has no calendar link: Turo''s trip emails come in by themselves and block the car with the turnaround. For each car on Turo, press **This car is on Turo**, type its name exactly as Turo''s emails show it and press **Save**.
2. Under "Turo emails to check", an email the reader was not sure about: check the trip on Turo, then **Add as a Turo trip** (choose the car, check the dates) or **Dismiss**. A trip whose email did not come: **Add a Turo trip** on the car.
3. Turo cannot read our calendar: under "Block on Turo", block each CarmaCars booking on the car''s Turo calendar, then press **Done on Turo**. Dates that changed or a booking cancelled here show the dates to free on Turo.
4. Getaround, Google Calendar or another platform with a calendar (iCal) link: open **Add a calendar link**, choose the platform, paste it and press **Add the link**. Copy the car''s CarmaCars link for that platform with **Copy** and paste it into the platform''s calendar import.
5. A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.
',
  '<p class="gd-p">You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listing pipeline with its duplicate check and plate covering.</p><p class="gd-p">Your rail: Queue, Today, Field jobs, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.</p><section class="gd-task" id="fleet-schedule-field-jobs" data-gd-task><h2 class="gd-h2">Schedule field jobs</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Handovers and returns without a job are listed first. Every booking needs one.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Schedule</b>: choose the kind, car, when, place, field staff and instructions.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Jobs, next three days: each with its field staff and whether they acknowledged it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Change a job with <b class="gd-ui">Assign</b>, <b class="gd-ui">Reassign</b>, <b class="gd-ui">Move</b> or <b class="gd-ui">Cancel</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/fleet</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/1180"><img src="/guides/img/va-fleet-02-field-jobs-desktop-b985927b.jpg" alt="" loading="lazy" decoding="async" width="1230" height="1180"><span class="gd-pin" style="left:15.4%;top:10.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:78.9%;top:12.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:11.4%;top:68.6%" aria-hidden="true">3</span><span class="gd-pin" style="left:78.9%;top:83.9%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="fleet-daily-checks" data-gd-task><h2 class="gd-h2">Daily checks</h2><p class="gd-p">Twice a day: the opening check by 9:00 and the closing check by 18:00.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Daily checks</b> and choose <b class="gd-ui">Opening check</b> or <b class="gd-ui">Closing check</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each line shows what was found. Tick OK, or Problem with a note.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Save the opening check</b> (or <b class="gd-ui">Save the closing check</b>). You can save it again.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/checks</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/820"><img src="/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg" alt="" loading="lazy" decoding="async" width="1230" height="820"><span class="gd-pin" style="left:6.5%;top:15.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:44.7%;top:42%" aria-hidden="true">2</span><span class="gd-pin" style="left:64.2%;top:94%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fleet-photo-reviews-after-a-return" data-gd-task><h2 class="gd-h2">Photo reviews after a return</h2><p class="gd-p">After each return, the field photo set waits under <b class="gd-ui">Photo reviews</b>. Compare it with the pickup set. Press <b class="gd-ui">Review done</b>, or <b class="gd-ui">Ask for a re-shoot</b> if a photo is missing or unclear.</p></section><section class="gd-task" id="fleet-similar-cars" data-gd-task><h2 class="gd-h2">Similar cars</h2><p class="gd-p">A possible duplicate listing stops publishing until you decide.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Compare the permit, the plate and the photos.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Not a duplicate</b> with a note when they are different cars, or <b class="gd-ui">Same car</b> when they are.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/similar-cars</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/460"><img src="/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg" alt="" loading="lazy" decoding="async" width="1230" height="460"><span class="gd-pin" style="left:23.6%;top:30.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.8%;top:30.4%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fleet-listings-and-covering-plates" data-gd-task><h2 class="gd-h2">Listings and covering plates</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Listings</b>. A draft waiting shows Needs review. Open it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/listings</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/340"><img src="/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg" alt="" loading="lazy" decoding="async" width="1230" height="340"><span class="gd-pin" style="left:54.5%;top:49.1%" aria-hidden="true">1</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol" start="3"><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Cover the plate</b>. Check the suggested box; <b class="gd-ui">Suggest the plate</b> asks again.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Drag over a plate to draw a box; drag a box to move it, its corner to resize it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Choose <b class="gd-ui">A CarmaCars plate</b>, <b class="gd-ui">Pixelation</b> or <b class="gd-ui">Blur</b>, then <b class="gd-ui">Save the covered photo</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">No plate in the shot? <b class="gd-ui">No plate visible on this photo</b>.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/776"><img src="/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg" alt="" loading="lazy" decoding="async" width="390" height="776"><span class="gd-pin" style="left:52.6%;top:78.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:50%;top:43.8%" aria-hidden="true">4</span><span class="gd-pin" style="left:61.5%;top:62.1%" aria-hidden="true">5</span><span class="gd-pin" style="left:43.1%;top:92.3%" aria-hidden="true">6</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Publishing waits until every public photo is covered or marked. The covered photo replaces the public one; the original is kept privately.</div></aside></section><section class="gd-task" id="fleet-calendar-sync-with-turo-and-other-platforms" data-gd-task><h2 class="gd-h2">Calendar sync with Turo and other platforms</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Calendar sync</b>: a car listed on Turo or Getaround must never be booked twice.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Turo has no calendar link: Turo&#39;s trip emails come in by themselves and block the car with the turnaround. For each car on Turo, press <b class="gd-ui">This car is on Turo</b>, type its name exactly as Turo&#39;s emails show it and press <b class="gd-ui">Save</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Under &quot;Turo emails to check&quot;, an email the reader was not sure about: check the trip on Turo, then <b class="gd-ui">Add as a Turo trip</b> (choose the car, check the dates) or <b class="gd-ui">Dismiss</b>. A trip whose email did not come: <b class="gd-ui">Add a Turo trip</b> on the car.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Turo cannot read our calendar: under &quot;Block on Turo&quot;, block each CarmaCars booking on the car&#39;s Turo calendar, then press <b class="gd-ui">Done on Turo</b>. Dates that changed or a booking cancelled here show the dates to free on Turo.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Getaround, Google Calendar or another platform with a calendar (iCal) link: open <b class="gd-ui">Add a calendar link</b>, choose the platform, paste it and press <b class="gd-ui">Add the link</b>. Copy the car&#39;s CarmaCars link for that platform with <b class="gd-ui">Copy</b> and paste it into the platform&#39;s calendar import.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.</div></li></ol></div></section>');
-- GUIDES 0063 END
