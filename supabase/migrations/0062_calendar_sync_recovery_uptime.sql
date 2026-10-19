-- 0062_calendar_sync_recovery_uptime.sql
-- The owner's request of October 19, 2026 (docs/changes/2026-10-19-calendar-sync-recovery-uptime.md):
--   A. calendar sync with Turo, Getaround and any platform that offers an iCal link, both ways. Per car, Admins and
--      Fleet paste one or more calendar links (import). The calendar-sync Edge Function (pg_cron through pg_net, every
--      5 minutes; each link is read every calendar_sync_minutes, 10 by default) reads them and calls
--      app.calendar_feed_apply(): every trip or block becomes an "External booking" block on the car, widened by the
--      car's turnaround, so availability, search and request to book respect it at once (app.vehicle_is_available
--      already reads every block). Changed events move their block, events gone from the link remove it, a clash with a
--      confirmed CarmaCars booking raises an urgent Fleet task, an Admin To do line and an email to Fleet. A link that
--      fails calendar_feed_alert_failures times in a row raises a task and an email; its blocks stay. Export: every
--      car has a private, unguessable iCal link of its busy times ("Booked", no personal data), rotatable, per
--      platform (the link for Turo leaves out what came from Turo).
--   B. booking recovery emails from the live visitor signals of 0060: a request started and not sent (marketing, only
--      with express consent), an offer opened and not answered, the pay page left, a change proposal opened and not
--      answered: one polite reminder after a set delay and at most one more, inside the sending hours, never after an
--      unsubscribe, stopped when the person acts or a staff member is already handling them.
--   C. a site check from the database: pg_cron every minute, pg_net probes of the home page, a car page, sign-in and
--      /api/health every uptime_interval_minutes (5), and checks of the email outbox, the scheduled jobs, the nightly
--      backup and the Stripe webhook. A problem opens one alert (Admin To do, an urgent task, an email to
--      uptime_alert_email) and its recovery sends one more email. A status panel on Admin > Today.
-- No applied migration is edited. Every new table has row-level security with the Admin policy; the browser reaches
-- them only through the functions below.

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists calendar_sync_enabled boolean not null default true,
  add column if not exists calendar_sync_minutes integer not null default 10 check (calendar_sync_minutes between 5 and 60),
  add column if not exists calendar_feed_alert_failures integer not null default 3 check (calendar_feed_alert_failures between 1 and 20),
  add column if not exists calendar_export_turnaround boolean not null default true,
  add column if not exists recovery_emails_enabled boolean not null default true,
  add column if not exists recovery_request_hours integer not null default 2 check (recovery_request_hours between 1 and 72),
  add column if not exists recovery_offer_hours integer not null default 4 check (recovery_offer_hours between 1 and 72),
  add column if not exists recovery_pay_minutes integer not null default 60 check (recovery_pay_minutes between 15 and 1440),
  add column if not exists recovery_change_hours integer not null default 4 check (recovery_change_hours between 1 and 72),
  add column if not exists recovery_second_hours integer not null default 24 check (recovery_second_hours between 2 and 168),
  add column if not exists recovery_max_emails integer not null default 2 check (recovery_max_emails between 1 and 2),
  add column if not exists recovery_send_from_hour integer not null default 9 check (recovery_send_from_hour between 0 and 23),
  add column if not exists recovery_send_until_hour integer not null default 21 check (recovery_send_until_hour between 1 and 24),
  add column if not exists uptime_enabled boolean not null default true,
  add column if not exists uptime_interval_minutes integer not null default 5 check (uptime_interval_minutes between 1 and 60),
  add column if not exists uptime_fail_threshold integer not null default 3 check (uptime_fail_threshold between 1 and 20),
  add column if not exists uptime_alert_email text not null default 'rent@carmacars.ca' check (uptime_alert_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  add column if not exists uptime_alert_cooldown_minutes integer not null default 60 check (uptime_alert_cooldown_minutes between 0 and 1440),
  add column if not exists uptime_backup_max_hours integer not null default 30 check (uptime_backup_max_hours between 6 and 168),
  add column if not exists uptime_email_failures integer not null default 3 check (uptime_email_failures between 1 and 100),
  add column if not exists uptime_keep_days integer not null default 14 check (uptime_keep_days between 1 and 90);
comment on column program_settings.calendar_sync_enabled is 'Calendar sync (0062): read the calendar links of other platforms (Turo, Getaround, others) and block the car for their trips.';
comment on column program_settings.calendar_sync_minutes is 'Calendar sync: each link is read every this many minutes (10 by default).';
comment on column program_settings.calendar_feed_alert_failures is 'Calendar sync: a link that fails this many times in a row raises a Fleet task and an email.';
comment on column program_settings.calendar_export_turnaround is 'Calendar sync: the CarmaCars calendar links given to other platforms include the turnaround before and after each trip.';
comment on column program_settings.recovery_emails_enabled is 'Booking recovery emails (0062): one polite reminder (and at most one more) when a known renter stops before finishing.';
comment on column program_settings.recovery_request_hours is 'Recovery: a booking request started and not sent, this many hours ago (marketing: only with consent).';
comment on column program_settings.recovery_offer_hours is 'Recovery: an offer opened and not answered, this many hours after it was opened.';
comment on column program_settings.recovery_pay_minutes is 'Recovery: the pay page left without paying, this many minutes ago.';
comment on column program_settings.recovery_change_hours is 'Recovery: a change proposal opened and not answered, this many hours after it was opened.';
comment on column program_settings.recovery_second_hours is 'Recovery: the second reminder, this many hours after the first.';
comment on column program_settings.recovery_max_emails is 'Recovery: reminders per offer, payment, proposal or request (1 or 2).';
comment on column program_settings.recovery_send_from_hour is 'Recovery: sent only from this hour (Toronto time) ...';
comment on column program_settings.recovery_send_until_hour is '... until this hour. Outside these hours they wait.';
comment on column program_settings.uptime_enabled is 'Site check (0062): check the site, emails, scheduled jobs, backups and Stripe from the database.';
comment on column program_settings.uptime_interval_minutes is 'Site check: the pages and services are checked every this many minutes.';
comment on column program_settings.uptime_fail_threshold is 'Site check: a page alerts after failing this many checks in a row (a single Error 1102 does not).';
comment on column program_settings.uptime_alert_email is 'Site check: the address that gets the alert and recovery emails.';
comment on column program_settings.uptime_alert_cooldown_minutes is 'Site check: a problem of the same kind within this many minutes of the last alert email shows on To do without another email.';
comment on column program_settings.uptime_backup_max_hours is 'Site check: alert when the last good nightly backup is older than this many hours.';
comment on column program_settings.uptime_email_failures is 'Site check: alert when this many emails failed in the last hour.';
comment on column program_settings.uptime_keep_days is 'Site check: keep the check results this many days.';

-- ================================================================ 2. calendar sync: tables
alter table vehicle_calendar_blocks drop constraint if exists vehicle_calendar_blocks_reason_check;
alter table vehicle_calendar_blocks add constraint vehicle_calendar_blocks_reason_check
  check (reason in ('service', 'repair', 'owner_unavailable', 'cleaning', 'exit', 'turo_owner_use', 'admin', 'external_booking'));
alter table vehicle_calendar_blocks drop constraint if exists vehicle_calendar_blocks_source_check;
alter table vehicle_calendar_blocks add constraint vehicle_calendar_blocks_source_check check (source in ('staff', 'turnaround', 'external'));
comment on column vehicle_calendar_blocks.source is 'staff: added by a person; turnaround: the cleaning block after a trip, kept in step with its booking; external: a trip or block read from another platform''s calendar link (0062), kept in step by calendar sync';

create table calendar_feeds (
  id                   uuid primary key default gen_random_uuid(),
  vehicle_id           uuid not null references vehicles (id) on delete cascade,
  platform             text not null check (platform in ('turo', 'getaround', 'other')),
  label                text check (length(label) <= 60),
  url                  text not null check (url ~ '^https?://[^\s]+$' and length(url) <= 2000),
  enabled              boolean not null default true,
  created_by           uuid references users (id),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  last_attempt_at      timestamptz,
  last_success_at      timestamptz,
  last_status          text not null default 'new' check (last_status in ('new', 'ok', 'error')),
  last_error           text,
  consecutive_failures integer not null default 0,
  failing_since        timestamptz,
  alerted_at           timestamptz,
  event_count          integer not null default 0,
  calendar_name        text,
  etag                 text,
  last_modified        text,
  unique (vehicle_id, url)
);
create index calendar_feeds_due_idx on calendar_feeds (last_attempt_at nulls first) where enabled;
create trigger calendar_feeds_updated before update on calendar_feeds for each row execute function app.set_updated_at();
comment on table calendar_feeds is 'Calendar sync (0062): a calendar link (iCal) of another platform for one car. The URL is a secret of that platform: Admins and Fleet only.';

create table calendar_feed_events (
  id            uuid primary key default gen_random_uuid(),
  feed_id       uuid not null references calendar_feeds (id) on delete cascade,
  vehicle_id    uuid not null references vehicles (id) on delete cascade,
  uid           text not null,
  summary       text,
  starts_at     timestamptz not null,
  ends_at       timestamptz not null check (ends_at > starts_at),
  all_day       boolean not null default false,
  block_id      uuid references vehicle_calendar_blocks (id) on delete set null,
  first_seen_at timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  changed_at    timestamptz,
  removed_at    timestamptz,
  unique (feed_id, uid)
);
create index calendar_feed_events_vehicle_idx on calendar_feed_events (vehicle_id, starts_at) where removed_at is null;
comment on table calendar_feed_events is 'Calendar sync (0062): one trip or block read from a calendar link, and the External booking block it holds on the car.';

create table calendar_conflicts (
  id          uuid primary key default gen_random_uuid(),
  event_id    uuid not null references calendar_feed_events (id) on delete cascade,
  booking_id  uuid not null references bookings (id) on delete cascade,
  kind        text not null check (kind in ('booking', 'offer')),
  task_id     uuid references tasks (id) on delete set null,
  found_at    timestamptz not null default now(),
  resolved_at timestamptz,
  unique (event_id, booking_id)
);
create index calendar_conflicts_open_idx on calendar_conflicts (found_at) where resolved_at is null;

create table vehicle_calendar_exports (
  vehicle_id      uuid primary key references vehicles (id) on delete cascade,
  token           text not null unique default (replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')),
  created_at      timestamptz not null default now(),
  rotated_at      timestamptz,
  last_fetched_at timestamptz,
  fetches         integer not null default 0
);
comment on table vehicle_calendar_exports is 'Calendar sync (0062): the private link of each car''s CarmaCars calendar (busy times only, "Booked"), pasted into Turo and other platforms. Rotating it ends the old link.';
insert into vehicle_calendar_exports (vehicle_id) select id from vehicles on conflict do nothing;
create or replace function app.vehicle_calendar_export_new() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  insert into vehicle_calendar_exports (vehicle_id) values (new.id) on conflict do nothing;
  return null;
end $$;
create trigger vehicle_calendar_export_new after insert on vehicles for each row execute function app.vehicle_calendar_export_new();

-- ================================================================ 3. recovery and site check: tables
create table recovery_emails (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null check (kind in ('request', 'offer', 'pay', 'change')),
  subject_key text not null,                         -- what the series is about: the signal's key
  step        smallint not null check (step in (1, 2)),
  signal_id   uuid references visitor_signals (id) on delete set null,
  renter_id   uuid references renters (id) on delete set null,
  user_id     uuid references users (id) on delete set null,
  booking_id  uuid references bookings (id) on delete set null,
  change_id   uuid references booking_change_requests (id) on delete set null,
  vehicle_id  uuid references vehicles (id) on delete set null,
  event_id    bigint references app_events (id) on delete set null,
  created_at  timestamptz not null default now(),
  stopped_at  timestamptz,
  stop_reason text,
  unique (subject_key, step)
);
create index recovery_emails_renter_idx on recovery_emails (renter_id, created_at desc);
comment on table recovery_emails is 'Booking recovery emails (0062): one row per reminder decided, so a series has at most two and stops for good.';

create table uptime_checks (
  key                  text primary key,
  label                text not null,
  kind                 text not null check (kind in ('page', 'internal')),
  path                 text,                       -- pages: the path on the site (the car page: the first public car)
  sort                 integer not null default 0,
  enabled              boolean not null default true,
  advice               text not null,
  status               text not null default 'unknown' check (status in ('ok', 'failing', 'unknown')),
  consecutive_failures integer not null default 0,
  last_checked_at      timestamptz,
  last_ok_at           timestamptz,
  last_http            integer,
  last_ms              integer,
  last_detail          text
);
insert into uptime_checks (key, label, kind, path, sort, advice) values
  ('home', 'Home page', 'page', '/', 1, 'Open carmacars.ca on your phone. If it does not load, tell your developer; Error 1102 means the web host''s free plan stopped the page (Workers Paid removes it).'),
  ('car_page', 'A car page', 'page', '/cars', 2, 'Open a car on carmacars.ca. If car pages fail and the home page works, the database may be slow or down: tell your developer.'),
  ('sign_in', 'Sign-in page', 'page', '/sign-in', 3, 'Open carmacars.ca/sign-in. If it fails, staff and renters cannot sign in: tell your developer.'),
  ('health', 'Site health check (/api/health)', 'page', '/api/health', 4, 'The site could not reach the database. Check the Supabase status page and tell your developer.'),
  ('email', 'Emails', 'internal', null, 5, 'Open Settings > Email log, filter Failed. A provider problem or the daily limit can hold emails; tell your developer if they keep failing.'),
  ('jobs', 'Scheduled jobs', 'internal', null, 6, 'Open Tasks: each failed job has its own task with the error. Tell your developer if it fails again.'),
  ('backup', 'Nightly backup', 'internal', null, 7, 'The nightly backup failed or did not run. Tell your developer the same day.'),
  ('stripe', 'Stripe webhook', 'internal', null, 8, 'Payments may not be recorded. Check Payments and refunds, and tell your developer.')
on conflict (key) do nothing;

create table uptime_probes (
  request_id bigint primary key,                  -- pg_net's request id
  check_key  text not null references uptime_checks (key) on delete cascade,
  url        text not null,
  sent_at    timestamptz not null default now()
);

create table uptime_results (
  id          bigserial primary key,
  check_key   text not null references uptime_checks (key) on delete cascade,
  at          timestamptz not null default now(),
  ok          boolean not null,
  http_status integer,
  ms          integer,
  detail      text
);
create index uptime_results_idx on uptime_results (check_key, at desc);

create table site_alerts (
  id           uuid primary key default gen_random_uuid(),
  check_key    text not null references uptime_checks (key) on delete cascade,
  opened_at    timestamptz not null default now(),
  resolved_at  timestamptz,
  detail       text,
  failures     integer not null default 1,
  emailed      boolean not null default false,
  task_id      uuid references tasks (id) on delete set null
);
create unique index site_alerts_one_open on site_alerts (check_key) where resolved_at is null;
comment on table site_alerts is 'Site check (0062): one row per problem, open until its check passes again. At most one open per check.';

do $$
declare t text;
begin
  foreach t in array array['calendar_feeds', 'calendar_feed_events', 'calendar_conflicts', 'vehicle_calendar_exports', 'recovery_emails',
                           'uptime_checks', 'uptime_probes', 'uptime_results', 'site_alerts'] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('revoke all on %I from anon, authenticated', t);
  end loop;
end $$;

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, description) values
  ('calendar_conflict', 'fleet', 'Double booking with another platform', 'urgent', 'opening_minutes', 30, 'A trip on Turo, Getaround or another calendar overlaps a confirmed CarmaCars booking of the same car: move, swap or cancel one'),
  ('calendar_offer_clash', 'cs', 'An offer clashes with another platform', 'high', 'opening_minutes', 60, 'An open offer or a booking awaiting payment overlaps a trip on another platform; its payment would be refused: withdraw it or change the dates'),
  ('calendar_feed_failing', 'fleet', 'A calendar link stopped working', 'high', 'opening_minutes', 240, 'Copy the calendar link from the platform again and paste it in Calendar sync'),
  ('site_alert', 'admin', 'Site problem found by the site check', 'urgent', 'opening_minutes', 30, 'See Site health on To do; the task closes by itself when the check passes again')
on conflict (task_type) do update set queue = excluded.queue, title = excluded.title, priority = excluded.priority,
  due_kind = excluded.due_kind, due_amount = excluded.due_amount, description = excluded.description;

-- ================================================================ 4. calendar sync: helpers
create or replace function app.platform_name(p text) returns text
language sql immutable as $$ select case p when 'turo' then 'Turo' when 'getaround' then 'Getaround' else 'Other calendar' end $$;

create or replace function app.calendar_feed_name(f calendar_feeds) returns text
language sql stable as $$ select coalesce(nullif(btrim(f.label), ''), app.platform_name(f.platform)) $$;

create or replace function app.assert_calendar_staff(p_user uuid) returns void
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_user is null or not app.user_runs_fleet(p_user) then
    raise exception 'Calendar sync is for Admins and Fleet' using errcode = '42501';
  end if;
end $$;

-- The links due a read, claimed (their attempt time set now) so two runs never read the same link at once.
create or replace function app.calendar_feeds_due(p_limit integer default 50, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  v jsonb;
begin
  if not ps.calendar_sync_enabled then return '[]'::jsonb; end if;
  with due as (
    select f.id from calendar_feeds f
     where f.enabled and (f.last_attempt_at is null or f.last_attempt_at <= p_now - make_interval(mins => ps.calendar_sync_minutes) + interval '60 seconds')
     order by f.last_attempt_at nulls first limit greatest(coalesce(p_limit, 50), 1)
     for update skip locked),
  upd as (update calendar_feeds f set last_attempt_at = p_now from due where f.id = due.id returning f.*)
  select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'url', u.url, 'platform', u.platform, 'etag', u.etag, 'last_modified', u.last_modified)), '[]'::jsonb)
    into v from upd u;
  return v;
end $$;

-- Clashes of one car: every imported event (turnaround included, as its block holds it) against the CarmaCars
-- bookings that hold the car (urgent task and email) and the open offers and bookings awaiting payment (a task for
-- customer service: their payment would be refused). Clashes whose reason passed close by themselves.
create or replace function app.calendar_conflicts_check(p_vehicle uuid, p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v_turn interval := make_interval(mins => app.turnaround_minutes(p_vehicle));
  x record;
  c calendar_conflicts;
  v_task uuid;
  v_new integer := 0;
begin
  -- clashes that passed: the event is gone, moved or the booking no longer holds the car
  for c in select k.* from calendar_conflicts k join calendar_feed_events e on e.id = k.event_id
            where e.vehicle_id = p_vehicle and k.resolved_at is null
              and (e.removed_at is not null or e.ends_at <= p_now
                   or not exists (select 1 from bookings b where b.id = k.booking_id
                                     and b.status in ('confirmed', 'on_rent', 'offered', 'pending_payment')
                                     and (b.status in ('offered', 'pending_payment') or b.blocks_calendar)
                                     and b.vehicle_id = e.vehicle_id
                                     and b.pickup_at < e.ends_at + v_turn and b.return_at > e.starts_at - v_turn)) loop
    update calendar_conflicts set resolved_at = p_now where id = c.id;
    update tasks set status = 'done', completed_at = p_now, completion_note = 'Closed by itself: the dates no longer overlap'
     where id = c.task_id and status in ('open', 'in_progress', 'waiting');
  end loop;
  for x in select e.id as event_id, e.summary, e.starts_at, e.ends_at, f.platform, app.calendar_feed_name(f) as feed_name,
                  b.id as booking_id, b.booking_number, b.status, b.pickup_at, b.return_at
             from calendar_feed_events e join calendar_feeds f on f.id = e.feed_id
             join bookings b on b.vehicle_id = e.vehicle_id
            where e.vehicle_id = p_vehicle and e.removed_at is null and e.ends_at > p_now and f.enabled
              and b.status in ('confirmed', 'on_rent', 'offered', 'pending_payment')
              and (b.status in ('offered', 'pending_payment') or b.blocks_calendar)
              and b.pickup_at < e.ends_at + v_turn and b.return_at > e.starts_at - v_turn
              and not exists (select 1 from calendar_conflicts k where k.event_id = e.id and k.booking_id = b.id and k.resolved_at is null) loop
    insert into calendar_conflicts as k (event_id, booking_id, kind, found_at)
    values (x.event_id, x.booking_id, case when x.status in ('confirmed', 'on_rent') then 'booking' else 'offer' end, p_now)
    on conflict (event_id, booking_id) do update set resolved_at = null, found_at = p_now, kind = excluded.kind
    returning * into c;
    if c.kind = 'booking' then
      v_task := app.raise_task(p_type => 'calendar_conflict',
        p_title => left(format('Double booking: %s on %s and %s', app.vehicle_name(p_vehicle), x.feed_name, x.booking_number), 200),
        p_detail => format('%s has the car from %s to %s ("%s"). CarmaCars booking %s: %s to %s. Move, swap or cancel one of them; the turnaround counts.',
                           x.feed_name, app.fmt_at(x.starts_at), app.fmt_at(x.ends_at), coalesce(x.summary, 'no title'),
                           x.booking_number, app.fmt_at(x.pickup_at), app.fmt_at(x.return_at)),
        p_booking => x.booking_id, p_vehicle => p_vehicle, p_related_table => 'calendar_conflicts', p_related_id => c.id,
        p_dedupe => 'calconflict:' || x.event_id || ':' || x.booking_id);
      perform app.emit_event('staff_calendar_conflict', 'calendar_conflict', c.id,
        jsonb_build_object('booking_id', x.booking_id, 'vehicle_id', p_vehicle, '_immediate', true),
        'staff_calendar_conflict:' || x.event_id || ':' || x.booking_id || ':' || extract(epoch from p_now)::bigint);
    else
      v_task := app.raise_task(p_type => 'calendar_offer_clash',
        p_title => left(format('%s clashes with %s: withdraw the offer or change the dates', x.booking_number, x.feed_name), 200),
        p_detail => format('%s has the %s from %s to %s. The payment of %s would be refused while it overlaps.',
                           x.feed_name, app.vehicle_name(p_vehicle), app.fmt_at(x.starts_at), app.fmt_at(x.ends_at), x.booking_number),
        p_booking => x.booking_id, p_vehicle => p_vehicle, p_related_table => 'calendar_conflicts', p_related_id => c.id,
        p_dedupe => 'caloffer:' || x.event_id || ':' || x.booking_id);
    end if;
    update calendar_conflicts set task_id = v_task where id = c.id;
    v_new := v_new + 1;
  end loop;
  return v_new;
end $$;

-- One successful read of a link. p_events: the events the parser kept (uid, summary, starts_at, ends_at, all_day);
-- null when the platform answered "not modified". Each event holds one External booking block, widened by the car's
-- turnaround; an event gone from the link frees its block. A block a person removed stays removed.
create or replace function app.calendar_feed_apply(p_feed uuid, p_events jsonb, p_meta jsonb default '{}'::jsonb, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  f calendar_feeds;
  v_turn interval;
  e jsonb;
  ev calendar_feed_events;
  v_uids text[] := '{}';
  v_added integer := 0;
  v_changed integer := 0;
  v_removed integer := 0;
  v_conf integer;
  v_start timestamptz;
  v_end timestamptz;
  v_note text;
  v_block uuid;
begin
  select * into f from calendar_feeds where id = p_feed for update;
  if f.id is null then raise exception 'Calendar link not found' using errcode = 'P0002'; end if;
  v_turn := make_interval(mins => app.turnaround_minutes(f.vehicle_id));
  if p_events is not null then
    if jsonb_typeof(p_events) <> 'array' then raise exception 'Events must be a list' using errcode = '22023'; end if;
    for e in select * from jsonb_array_elements(p_events) limit 2000 loop
      v_start := (e ->> 'starts_at')::timestamptz;
      v_end := (e ->> 'ends_at')::timestamptz;
      if nullif(e ->> 'uid', '') is null or v_start is null or v_end is null or v_end <= v_start then continue; end if;
      v_uids := v_uids || left(e ->> 'uid', 500);
      insert into calendar_feed_events as x (feed_id, vehicle_id, uid, summary, starts_at, ends_at, all_day, first_seen_at, last_seen_at)
      values (f.id, f.vehicle_id, left(e ->> 'uid', 500), left(nullif(btrim(e ->> 'summary'), ''), 200), v_start, v_end,
              coalesce((e ->> 'all_day')::boolean, false), p_now, p_now)
      on conflict (feed_id, uid) do update
         set summary = excluded.summary, starts_at = excluded.starts_at, ends_at = excluded.ends_at, all_day = excluded.all_day,
             last_seen_at = p_now, removed_at = null,
             changed_at = case when x.starts_at <> excluded.starts_at or x.ends_at <> excluded.ends_at or x.removed_at is not null then p_now else x.changed_at end
      returning * into ev;
      if ev.first_seen_at = p_now then v_added := v_added + 1; elsif ev.changed_at = p_now then v_changed := v_changed + 1; end if;
    end loop;
    update calendar_feed_events set removed_at = p_now
     where feed_id = f.id and removed_at is null and uid <> all (v_uids);
    get diagnostics v_removed = row_count;
  end if;
  -- the blocks follow the events
  for ev in select * from calendar_feed_events where feed_id = f.id loop
    v_note := left(app.calendar_feed_name(f) || ': ' || coalesce(ev.summary, 'Booked'), 300);
    if ev.removed_at is not null or not f.enabled then
      update vehicle_calendar_blocks set removed_at = p_now,
             removed_reason = case when ev.removed_at is not null then 'No longer in the ' || app.calendar_feed_name(f) || ' calendar' else 'Calendar link turned off' end
       where id = ev.block_id and removed_at is null;
      continue;
    end if;
    if ev.block_id is null or not exists (select 1 from vehicle_calendar_blocks k where k.id = ev.block_id) then
      insert into vehicle_calendar_blocks (vehicle_id, reason, source, starts_at, ends_at, note)
      values (f.vehicle_id, 'external_booking', 'external', ev.starts_at - v_turn, ev.ends_at + v_turn, v_note)
      returning id into v_block;
      update calendar_feed_events set block_id = v_block where id = ev.id;
    else
      -- a block a person removed stays removed; one the sync removed comes back with its event
      update vehicle_calendar_blocks
         set starts_at = ev.starts_at - v_turn, ends_at = ev.ends_at + v_turn, note = v_note,
             removed_at = null, removed_reason = null
       where id = ev.block_id and (removed_by is null)
         and (starts_at <> ev.starts_at - v_turn or ends_at is distinct from ev.ends_at + v_turn or note is distinct from v_note or removed_at is not null);
    end if;
  end loop;
  -- events long past are forgotten (their blocks stay as history)
  delete from calendar_feed_events where feed_id = f.id and ends_at < p_now - interval '30 days';
  update calendar_feeds
     set last_success_at = p_now, last_attempt_at = coalesce(last_attempt_at, p_now), last_status = 'ok', last_error = null,
         consecutive_failures = 0, failing_since = null, alerted_at = null,
         event_count = (select count(*) from calendar_feed_events x where x.feed_id = f.id and x.removed_at is null and x.ends_at > p_now),
         calendar_name = coalesce(left(nullif(p_meta ->> 'calendar_name', ''), 120), calendar_name),
         etag = case when p_meta ? 'etag' then left(nullif(p_meta ->> 'etag', ''), 300) else etag end,
         last_modified = case when p_meta ? 'last_modified' then left(nullif(p_meta ->> 'last_modified', ''), 100) else last_modified end
   where id = f.id;
  update tasks set status = 'done', completed_at = p_now, completion_note = 'Closed by itself: the calendar link works again'
   where task_type = 'calendar_feed_failing' and related_table = 'calendar_feeds' and related_id = f.id and status in ('open', 'in_progress', 'waiting');
  v_conf := app.calendar_conflicts_check(f.vehicle_id, p_now);
  return jsonb_build_object('added', v_added, 'changed', v_changed, 'removed', v_removed, 'conflicts', v_conf,
    'events', (select event_count from calendar_feeds where id = f.id));
end $$;

-- One failed read. The blocks of the link stay as they were; after calendar_feed_alert_failures in a row, a Fleet
-- task and one email for this run of failures.
create or replace function app.calendar_feed_failed(p_feed uuid, p_error text, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  f calendar_feeds;
begin
  update calendar_feeds
     set last_status = 'error', last_error = left(coalesce(nullif(btrim(p_error), ''), 'The link could not be read.'), 500),
         consecutive_failures = consecutive_failures + 1, failing_since = coalesce(failing_since, p_now), last_attempt_at = p_now
   where id = p_feed returning * into f;
  if f.id is null then raise exception 'Calendar link not found' using errcode = 'P0002'; end if;
  if f.consecutive_failures >= ps.calendar_feed_alert_failures and f.alerted_at is null then
    perform app.raise_task(p_type => 'calendar_feed_failing',
      p_title => left(format('Calendar link not working: %s on %s', app.vehicle_name(f.vehicle_id), app.calendar_feed_name(f)), 200),
      p_detail => format('%s failed tries in a row since %s. Last error: %s. Trips already imported stay on the calendar; new ones are not seen until the link works.',
                         f.consecutive_failures, app.fmt_at(f.failing_since), f.last_error),
      p_vehicle => f.vehicle_id, p_related_table => 'calendar_feeds', p_related_id => f.id, p_dedupe => 'calfeed:' || f.id);
    perform app.emit_event('staff_calendar_feed_failing', 'calendar_feed', f.id, jsonb_build_object('vehicle_id', f.vehicle_id, 'failures', f.consecutive_failures, '_immediate', true),
      'staff_calendar_feed_failing:' || f.id || ':' || extract(epoch from f.failing_since)::bigint);
    update calendar_feeds set alerted_at = p_now where id = f.id;
  end if;
  return jsonb_build_object('failures', f.consecutive_failures, 'error', f.last_error);
end $$;

-- ================================================================ 5. calendar sync: the export (the CarmaCars calendar of a car)
-- The busy times of the car, merged, as an iCal file: confirmed and on-rent bookings (with the turnaround when
-- calendar_export_turnaround is on), every block (service, cleaning, owner use, ...), and the trips imported from other
-- platforms except those of p_for (the link for Turo leaves Turo's own trips out). Each event says "Booked"; nothing
-- personal is in it. Null when the link is unknown (rotated).
create or replace function app.ical_text(p text) returns text
language sql immutable as $$ select replace(replace(replace(replace(coalesce(p, ''), '\', '\\'), ';', '\;'), ',', '\,'), e'\n', '\n') $$;
create or replace function app.ical_utc(p timestamptz) returns text
language sql immutable as $$ select to_char(p at time zone 'UTC', 'YYYYMMDD"T"HH24MISS"Z"') $$;

create or replace function app.calendar_export_ics(p_token text, p_for text default null, p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  x vehicle_calendar_exports;
  ps program_settings := app.settings(app.local_date(p_now));
  v_turn interval;
  v_from timestamptz := p_now - interval '1 day';
  v_to timestamptz := p_now + interval '540 days';
  v_window tstzrange;
  v_lines text[];
  r record;
  v_name text;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then return null; end if;
  select * into x from vehicle_calendar_exports where token = p_token;
  if x.vehicle_id is null then return null; end if;
  update vehicle_calendar_exports set last_fetched_at = p_now, fetches = fetches + 1 where vehicle_id = x.vehicle_id;
  v_turn := case when ps.calendar_export_turnaround then make_interval(mins => app.turnaround_minutes(x.vehicle_id)) else interval '0' end;
  v_window := tstzrange(v_from, v_to, '[)');
  v_name := 'CarmaCars: ' || coalesce(app.vehicle_name(x.vehicle_id), 'car');
  v_lines := array['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//CarmaCars//Calendar sync//EN', 'CALSCALE:GREGORIAN', 'METHOD:PUBLISH',
                   'X-WR-CALNAME:' || app.ical_text(v_name), 'X-WR-TIMEZONE:America/Toronto', 'X-PUBLISHED-TTL:PT15M'];
  for r in
    with busy as (
      select tstzrange(b.pickup_at - v_turn,
                       b.return_at + case when exists (select 1 from vehicle_calendar_blocks k where k.booking_id = b.id and k.source = 'turnaround' and k.removed_at is null)
                                          then interval '0' else v_turn end, '[)') as r
        from bookings b
       where b.vehicle_id = x.vehicle_id and b.blocks_calendar and b.status in ('confirmed', 'on_rent')
         and b.return_at > v_from and b.pickup_at < v_to
      union all
      select tstzrange(c.starts_at, coalesce(c.ends_at, v_to), '[)')
        from vehicle_calendar_blocks c
       where c.vehicle_id = x.vehicle_id and c.removed_at is null and c.starts_at < v_to and (c.ends_at is null or c.ends_at > v_from)
         -- an imported trip: never in the plain link; in a platform's link unless it came from that platform
         and (c.source <> 'external' or p_for = 'all'
              or (p_for is not null and not exists (select 1 from calendar_feed_events e join calendar_feeds f on f.id = e.feed_id
                                                     where e.block_id = c.id and f.platform = p_for)))),
    merged as (select unnest(range_agg(b.r * v_window)) as r from busy b where b.r && v_window)
    select lower(m.r) as s, upper(m.r) as e from merged m where not isempty(m.r) order by 1
  loop
    v_lines := v_lines || array['BEGIN:VEVENT',
      'UID:cc-' || md5(x.vehicle_id::text || ':' || app.ical_utc(r.s)) || '@carmacars.ca',
      'DTSTAMP:' || app.ical_utc(p_now), 'DTSTART:' || app.ical_utc(r.s), 'DTEND:' || app.ical_utc(r.e),
      'SUMMARY:Booked', 'TRANSP:OPAQUE', 'STATUS:CONFIRMED', 'END:VEVENT'];
  end loop;
  v_lines := v_lines || 'END:VCALENDAR'::text;
  return array_to_string(v_lines, e'\r\n') || e'\r\n';
end $$;
comment on function app.calendar_export_ics(text, text, timestamptz) is
  'p_for: null (other platforms) leaves out every imported trip, so nothing echoes back; turo or getaround leaves out only that platform''s own trips; all includes everything.';

-- ================================================================ 6. calendar sync: reads and actions for Admins and Fleet
create or replace function app.calendar_feed_row(f calendar_feeds) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', f.id, 'vehicle_id', f.vehicle_id, 'platform', f.platform, 'platform_name', app.platform_name(f.platform),
    'name', app.calendar_feed_name(f), 'label', f.label, 'url', f.url, 'enabled', f.enabled, 'status', f.last_status,
    'last_attempt_at', f.last_attempt_at, 'last_success_at', f.last_success_at, 'last_error', f.last_error,
    'failures', f.consecutive_failures, 'failing_since', f.failing_since, 'events', f.event_count, 'calendar_name', f.calendar_name,
    'created_at', f.created_at,
    'upcoming', coalesce((select jsonb_agg(jsonb_build_object('summary', e.summary, 'starts_at', e.starts_at, 'ends_at', e.ends_at, 'all_day', e.all_day,
                                   'blocked', exists (select 1 from vehicle_calendar_blocks k where k.id = e.block_id and k.removed_at is null)) order by e.starts_at)
                            from (select * from calendar_feed_events e where e.feed_id = f.id and e.removed_at is null and e.ends_at > now()
                                   order by e.starts_at limit 5) e), '[]'::jsonb))
$$;

create or replace function app.calendar_sync_read(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings();
  v_base text := ps.notify_base_url;
begin
  perform app.assert_calendar_staff(p_by);
  return jsonb_build_object(
    'enabled', ps.calendar_sync_enabled, 'minutes', ps.calendar_sync_minutes, 'alert_failures', ps.calendar_feed_alert_failures,
    'turnaround_minutes', ps.turnaround_buffer_minutes, 'export_turnaround', ps.calendar_export_turnaround,
    'cars', coalesce((select jsonb_agg(jsonb_build_object(
        'id', v.id, 'name', app.vehicle_name(v.id), 'plate', v.plate, 'status', v.status, 'is_sample', v.is_sample,
        'turnaround_minutes', app.turnaround_minutes(v.id),
        'export', jsonb_build_object('url', v_base || '/api/ical/' || x.token || '.ics', 'last_fetched_at', x.last_fetched_at, 'fetches', x.fetches,
                                     'rotated_at', x.rotated_at),
        'feeds', coalesce((select jsonb_agg(app.calendar_feed_row(f) order by f.created_at) from calendar_feeds f where f.vehicle_id = v.id), '[]'::jsonb))
        order by (exists (select 1 from calendar_feeds f where f.vehicle_id = v.id)) desc, v.is_sample, app.vehicle_name(v.id))
      from vehicles v left join vehicle_calendar_exports x on x.vehicle_id = v.id
     where v.status not in ('exited', 'total_loss', 'declined') and v.retired_at is null
       and (p ->> 'vehicle' is null or v.id = (p ->> 'vehicle')::uuid)), '[]'::jsonb),
    'conflicts', coalesce((select jsonb_agg(jsonb_build_object('id', k.id, 'kind', k.kind, 'found_at', k.found_at, 'vehicle', app.vehicle_name(e.vehicle_id),
                                  'vehicle_id', e.vehicle_id, 'platform', app.calendar_feed_name(f), 'summary', e.summary, 'starts_at', e.starts_at, 'ends_at', e.ends_at,
                                  'booking_number', b.booking_number, 'booking_status', b.status, 'pickup_at', b.pickup_at, 'return_at', b.return_at, 'task_id', k.task_id)
                                  order by k.kind, e.starts_at)
                             from calendar_conflicts k join calendar_feed_events e on e.id = k.event_id join calendar_feeds f on f.id = e.feed_id
                             join bookings b on b.id = k.booking_id where k.resolved_at is null), '[]'::jsonb),
    'failing', (select count(*) from calendar_feeds f where f.enabled and f.last_status = 'error'));
end $$;

create or replace function app.calendar_sync_do(p_by uuid, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  f calendar_feeds;
  v_url text := btrim(coalesce(p ->> 'url', ''));
  v_platform text := coalesce(nullif(p ->> 'platform', ''), 'other');
  v_vehicle uuid;
  v_token text;
  r jsonb;
begin
  perform app.assert_calendar_staff(p_by);
  if p_name in ('calendar_feed_add', 'calendar_feed_save') then
    if v_url !~ '^(https?|webcal)://[^\s]+$' or length(v_url) > 2000 then
      raise exception 'Paste the full calendar link (it starts with https://)' using errcode = '22023';
    end if;
    v_url := regexp_replace(v_url, '^webcal://', 'https://');
    if v_platform not in ('turo', 'getaround', 'other') then raise exception 'Choose Turo, Getaround or Other' using errcode = '22023'; end if;
    if v_url ~* '/api/ical/[0-9a-f]{64}' and v_url ~* 'carmacars' then
      raise exception 'That is a CarmaCars calendar link. Paste it into Turo or the other platform; here, paste the link the platform gives you' using errcode = '22023';
    end if;
  end if;
  case p_name
  when 'calendar_feed_add' then
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
  when 'calendar_feed_save' then
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
  when 'calendar_feed_remove' then
    select * into f from calendar_feeds where id = (p ->> 'id')::uuid;
    if f.id is null then raise exception 'Calendar link not found' using errcode = 'P0002'; end if;
    update vehicle_calendar_blocks k set removed_at = now(), removed_reason = 'Calendar link removed'
      from calendar_feed_events e where e.feed_id = f.id and e.block_id = k.id and k.removed_at is null;
    update tasks t set status = 'cancelled', completed_at = now(), completion_note = 'The calendar link was removed'
      from calendar_conflicts k join calendar_feed_events e on e.id = k.event_id
     where e.feed_id = f.id and t.id = k.task_id and t.status in ('open', 'in_progress', 'waiting');
    update tasks set status = 'cancelled', completed_at = now(), completion_note = 'The calendar link was removed'
     where related_table = 'calendar_feeds' and related_id = f.id and status in ('open', 'in_progress', 'waiting');
    delete from calendar_feeds where id = f.id;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, before)
    values (p_by, 'DELETE', 'calendar_feeds', f.id, jsonb_build_object('vehicle_id', f.vehicle_id, 'platform', f.platform, 'label', f.label));
    return jsonb_build_object('removed', true);
  when 'calendar_export_rotate' then
    v_vehicle := (p ->> 'vehicle')::uuid;
    v_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
    insert into vehicle_calendar_exports (vehicle_id, token, rotated_at) values (v_vehicle, v_token, now())
    on conflict (vehicle_id) do update set token = excluded.token, rotated_at = now(), last_fetched_at = null, fetches = 0;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'UPDATE', 'vehicle_calendar_exports', v_vehicle, jsonb_build_object('rotated', true));
    return jsonb_build_object('url', (app.settings()).notify_base_url || '/api/ical/' || v_token || '.ics');
  when 'calendar_feed_sync_start' then
    -- Sync now: the server reads the link at once (the same parser as the Edge Function) and sends the result back
    update calendar_feeds set last_attempt_at = now() where id = (p ->> 'id')::uuid returning * into f;
    if f.id is null then raise exception 'Calendar link not found' using errcode = 'P0002'; end if;
    return jsonb_build_object('id', f.id, 'url', f.url, 'platform', f.platform, 'etag', null, 'last_modified', null);
  when 'calendar_feed_result' then
    if not exists (select 1 from calendar_feeds where id = (p ->> 'id')::uuid) then raise exception 'Calendar link not found' using errcode = 'P0002'; end if;
    if coalesce((p ->> 'ok')::boolean, false) then
      r := app.calendar_feed_apply((p ->> 'id')::uuid, p -> 'events', coalesce(p -> 'meta', '{}'::jsonb));
    else
      r := app.calendar_feed_failed((p ->> 'id')::uuid, p ->> 'error');
    end if;
    return r || jsonb_build_object('feed', (select app.calendar_feed_row(f2) from calendar_feeds f2 where f2.id = (p ->> 'id')::uuid));
  else raise exception 'Unknown action %', p_name using errcode = '22023';
  end case;
end $$;

-- ================================================================ 7. booking recovery emails
-- Is a staff member already handling this renter? An open task on them or their booking that a person took, a
-- follow-up task a person completed since the moment, a chat with a person, or a message from staff since then.
create or replace function app.recovery_staff_handling(p_renter uuid, p_booking uuid, p_since timestamptz) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from tasks t
                  where ((p_booking is not null and t.booking_id = p_booking) or (p_renter is not null and t.renter_id = p_renter))
                    and ((t.status in ('open', 'in_progress', 'waiting') and (t.assigned_to is not null or t.status = 'in_progress'))
                         or (t.task_type = 'visitor_follow_up' and t.status = 'done' and t.completed_by is not null and t.completed_at > p_since)))
      or exists (select 1 from chat_conversations c where p_renter is not null and c.renter_id = p_renter
                    and (c.status in ('waiting', 'human') or c.first_human_reply_at > p_since))
      or exists (select 1 from messages m where m.direction = 'outbound' and m.sent_by is not null and m.occurred_at > p_since
                    and ((p_booking is not null and m.booking_id = p_booking) or (p_renter is not null and m.renter_id = p_renter)))
$$;

-- Has the reason of a reminder passed? Null while it still holds; otherwise why it stops.
create or replace function app.recovery_reason_passed(p_kind text, p_booking uuid, p_change uuid, p_renter uuid, p_since timestamptz) returns text
language sql stable security definer set search_path = public, app as $$
  select case p_kind
    when 'offer' then case when not exists (select 1 from bookings b where b.id = p_booking and b.status = 'offered') then 'The offer was answered, expired or withdrawn' end
    when 'pay' then case when not exists (select 1 from bookings b where b.id = p_booking and b.status = 'pending_payment') then 'Paid, or the booking moved on' end
    when 'change' then case when not exists (select 1 from booking_change_requests c where c.id = p_change and c.status = 'proposed') then 'The change was answered or expired' end
    when 'request' then case when exists (select 1 from bookings b where b.renter_id = p_renter and b.created_at > p_since) then 'A request was sent' end
  end
$$;

create or replace function app.job_booking_recovery(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  v_hour integer := app.local_hour(p_now);
  v_window boolean;
  r recovery_emails;
  x record;
  v_reason text;
  v_kind text;
  v_code text;
  v_anchor timestamptz;
  v_due timestamptz;
  v_step integer;
  v_last recovery_emails;
  v_user uuid;
  v_email text;
  v_change booking_change_requests;
  v_event bigint;
  v_sent integer := 0;
  v_stopped integer := 0;
  v_payload jsonb;
begin
  -- 1. a series whose reason passed stops; a reminder still waiting in the outbox is not sent
  for r in select * from recovery_emails where stopped_at is null loop
    v_reason := app.recovery_reason_passed(r.kind, r.booking_id, r.change_id, r.renter_id, r.created_at - interval '1 day');
    if v_reason is null and r.kind = 'request' then
      v_reason := case when exists (select 1 from bookings b where b.renter_id = r.renter_id and b.created_at > (select min(y.created_at) from recovery_emails y where y.subject_key = r.subject_key) - make_interval(hours => ps.recovery_request_hours))
                       then 'A request was sent' end;
    end if;
    if v_reason is null then continue; end if;
    update recovery_emails set stopped_at = p_now, stop_reason = v_reason where subject_key = r.subject_key and stopped_at is null;
    update notification_outbox set status = 'skipped', status_reason = 'Not sent: ' || lower(left(v_reason, 1)) || substr(v_reason, 2)
     where event_id in (select y.event_id from recovery_emails y where y.subject_key = r.subject_key) and status in ('queued', 'delayed');
    v_stopped := v_stopped + 1;
  end loop;
  if not ps.recovery_emails_enabled then return format('off, stopped %s', v_stopped); end if;
  v_window := v_hour >= ps.recovery_send_from_hour and v_hour < ps.recovery_send_until_hour;
  if not v_window then return format('outside the sending hours, stopped %s', v_stopped); end if;

  -- 2. the signals of known renters that may get a reminder
  for x in select g.*, coalesce(g.renter_id, s.renter_id) as rid, s.known_email
             from visitor_signals g left join visitor_sessions s on s.id = g.session_id
            where g.kind in ('request_stopped', 'offer_opened', 'pay_left', 'proposal_opened')
              and g.last_at > p_now - interval '14 days'
              and coalesce(g.renter_id, s.renter_id) is not null loop
    v_kind := case x.kind when 'request_stopped' then 'request' when 'offer_opened' then 'offer' when 'pay_left' then 'pay' else 'change' end;
    v_code := 'renter_recovery_' || v_kind;
    if exists (select 1 from recovery_emails y where y.subject_key = x.dedupe_key and y.stopped_at is not null) then continue; end if;
    select count(*) into v_step from recovery_emails y where y.subject_key = x.dedupe_key;
    if v_step >= ps.recovery_max_emails then continue; end if;
    select * into v_last from recovery_emails y where y.subject_key = x.dedupe_key order by step desc limit 1;
    v_anchor := case v_kind when 'offer' then x.first_at when 'change' then x.first_at else x.last_at end;
    v_due := case when v_step = 0 then v_anchor + case v_kind
                                                    when 'request' then make_interval(hours => ps.recovery_request_hours)
                                                    when 'offer' then make_interval(hours => ps.recovery_offer_hours)
                                                    when 'pay' then make_interval(mins => ps.recovery_pay_minutes)
                                                    else make_interval(hours => ps.recovery_change_hours) end
                  else v_last.created_at + make_interval(hours => ps.recovery_second_hours) end;
    if p_now < v_due then continue; end if;
    -- the change proposal the signal is about
    v_change := null;
    if v_kind = 'change' then
      select * into v_change from booking_change_requests c where c.booking_id = x.booking_id and c.status = 'proposed' order by c.created_at desc limit 1;
    end if;
    -- still current?
    v_reason := app.recovery_reason_passed(v_kind, x.booking_id, v_change.id, x.rid, x.first_at);
    if v_reason is null and v_kind = 'request' and exists (select 1 from visitor_events e where e.session_id = x.session_id and e.kind = 'request_submitted' and e.at > x.first_at) then
      v_reason := 'A request was sent';
    end if;
    if v_reason is null and app.recovery_staff_handling(x.rid, x.booking_id, x.first_at) then v_reason := 'A staff member is handling the renter'; end if;
    if v_reason is not null then
      if v_step > 0 then
        update recovery_emails set stopped_at = p_now, stop_reason = v_reason where subject_key = x.dedupe_key and stopped_at is null;
        v_stopped := v_stopped + 1;
      end if;
      continue;
    end if;
    -- who, and may we write
    select r2.user_id, coalesce(nullif(r2.email, ''), u.email) into v_user, v_email from renters r2 left join users u on u.id = r2.user_id where r2.id = x.rid;
    if nullif(btrim(coalesce(v_email, '')), '') is null then continue; end if;
    if exists (select 1 from users u where u.id = v_user and u.marketing_unsubscribed_at is not null
                  and u.marketing_unsubscribed_at >= coalesce((select max(c.given_at) from consents c where c.user_id = u.id and c.consent_code = 'marketing' and c.withdrawn_at is null), '-infinity'::timestamptz))
       or exists (select 1 from notification_preferences n where n.user_id = v_user and n.code = v_code and not n.email_enabled)
       or app.email_suppressed(v_email, v_kind = 'request') then
      continue;
    end if;
    if v_kind = 'request' then
      if v_user is null or not app.has_marketing_consent(v_user, 'express') then continue; end if;
      -- one series of request reminders per renter in 7 days
      if v_step = 0 and exists (select 1 from recovery_emails y where y.kind = 'request' and y.renter_id = x.rid and y.created_at > p_now - interval '7 days') then continue; end if;
    elsif v_kind = 'offer' then
      -- the offer's own expiry reminder covers its last hours
      if exists (select 1 from bookings b where b.id = x.booking_id and b.offer_expires_at < p_now + interval '7 hours') then continue; end if;
      if exists (select 1 from notification_outbox o where o.booking_id = x.booking_id and o.code = 'renter_offer_reminder' and o.created_at > p_now - interval '12 hours') then continue; end if;
    elsif v_kind = 'change' then
      if v_change.id is null then continue; end if;
      if v_change.accept_by is not null and v_change.accept_by < p_now + make_interval(hours => coalesce(ps.booking_change_reminder_hours, 12) + 1) then continue; end if;
      if v_change.reminded_at is not null and v_change.reminded_at > p_now - interval '12 hours' then continue; end if;
    end if;
    v_payload := jsonb_build_object('renter_id', x.rid, 'recovery_step', v_step + 1, '_immediate', true);
    if x.booking_id is not null then v_payload := v_payload || jsonb_build_object('booking_id', x.booking_id); end if;
    if x.vehicle_id is not null then v_payload := v_payload || jsonb_build_object('vehicle_id', x.vehicle_id); end if;
    if v_change.id is not null then v_payload := v_payload || jsonb_build_object('change_id', v_change.id); end if;
    v_event := app.emit_event(v_code, case when x.booking_id is not null then 'booking' else 'renter' end, coalesce(x.booking_id, x.rid),
                              v_payload, 'recovery:' || x.dedupe_key || ':' || (v_step + 1));
    insert into recovery_emails (kind, subject_key, step, signal_id, renter_id, user_id, booking_id, change_id, vehicle_id, event_id, created_at)
    values (v_kind, x.dedupe_key, v_step + 1, x.id, x.rid, v_user, x.booking_id, v_change.id, x.vehicle_id, v_event, p_now)
    on conflict (subject_key, step) do nothing;
    v_sent := v_sent + 1;
  end loop;
  return format('sent %s, stopped %s', v_sent, v_stopped);
end $$;

-- ================================================================ 8. site check
create or replace function app.uptime_url(p_key text) returns text
language sql stable security definer set search_path = public, app as $$
  select (app.settings()).notify_base_url
         || case when c.key = 'car_page'
                 then coalesce((select '/cars/' || l.slug from public_vehicle_listings l order by l.slug limit 1), '/cars')
                 else c.path end
    from uptime_checks c where c.key = p_key
$$;

-- One result of a check: the counters, the status and the alert that follows.
create or replace function app.uptime_record(p_key text, p_ok boolean, p_http integer default null, p_ms integer default null,
                                             p_detail text default null, p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  c uptime_checks;
  a site_alerts;
  v_task uuid;
  v_need integer;
  v_last_mail timestamptz;
begin
  insert into uptime_results (check_key, at, ok, http_status, ms, detail) values (p_key, p_now, p_ok, p_http, p_ms, left(p_detail, 500));
  update uptime_checks
     set consecutive_failures = case when p_ok then 0 else consecutive_failures + 1 end,
         last_checked_at = p_now, last_ok_at = case when p_ok then p_now else last_ok_at end,
         last_http = p_http, last_ms = p_ms, last_detail = left(p_detail, 500)
   where key = p_key returning * into c;
  if c.key is null then return 'unknown check'; end if;
  v_need := case when c.kind = 'page' then ps.uptime_fail_threshold else 1 end;
  select * into a from site_alerts where check_key = p_key and resolved_at is null;
  if p_ok then
    update uptime_checks set status = 'ok' where key = p_key;
    if a.id is not null then
      update site_alerts set resolved_at = p_now where id = a.id;
      update tasks set status = 'done', completed_at = p_now, completion_note = 'Closed by itself: the site check passed again'
       where id = a.task_id and status in ('open', 'in_progress', 'waiting');
      if a.emailed then
        perform app.emit_event('staff_site_recovered', 'site_alert', a.id, '{}'::jsonb, 'staff_site_recovered:' || a.id);
      end if;
      return 'recovered';
    end if;
    return 'ok';
  end if;
  if c.consecutive_failures < v_need then
    update uptime_checks set status = case when status = 'failing' then 'failing' else 'ok' end where key = p_key and status <> 'unknown';
    return 'failed ' || c.consecutive_failures || ' of ' || v_need;
  end if;
  update uptime_checks set status = 'failing' where key = p_key;
  if a.id is not null then
    update site_alerts set detail = left(p_detail, 500), failures = c.consecutive_failures where id = a.id;
    return 'still failing';
  end if;
  select max(opened_at) into v_last_mail from site_alerts where check_key = p_key and emailed;
  v_task := app.raise_task(p_type => 'site_alert', p_title => left('Site problem: ' || c.label, 200),
    p_detail => left(coalesce(p_detail, 'The check failed') || '. ' || c.advice, 2000), p_dedupe => 'site_alert:' || p_key);
  insert into site_alerts (check_key, opened_at, detail, failures, task_id, emailed)
  values (p_key, p_now, left(p_detail, 500), c.consecutive_failures, v_task,
          v_last_mail is null or v_last_mail < p_now - make_interval(mins => ps.uptime_alert_cooldown_minutes))
  returning * into a;
  if a.emailed then
    perform app.emit_event('staff_site_alert', 'site_alert', a.id, '{}'::jsonb, 'staff_site_alert:' || a.id);
  end if;
  return 'alert';
end $$;

-- The checks that need no request: the outbox, the scheduled jobs, the nightly backup, the Stripe webhook.
create or replace function app.uptime_internal(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  v_failed integer;
  v_stuck integer;
  v_cron text;
  v_jobs text;
  b job_runs;
  v_ok_at timestamptz;
  v_stripe integer;
  v_out jsonb := '{}'::jsonb;
  v_detail text;
begin
  -- emails: failures in the last hour, or emails due 15 minutes ago and still waiting (the sender is not running)
  select count(*) into v_failed from notification_outbox where status = 'failed' and updated_at > p_now - interval '1 hour';
  select count(*) into v_stuck from notification_outbox where status = 'queued' and send_after < p_now - interval '15 minutes';
  v_detail := case when v_failed >= ps.uptime_email_failures then format('%s emails failed in the last hour', v_failed)
                   when v_stuck > 0 then format('%s emails waiting more than 15 minutes (the sender may have stopped)', v_stuck) end;
  v_out := v_out || jsonb_build_object('email', app.uptime_record('email', v_detail is null, null, null, coalesce(v_detail, 'Sending normally'), p_now));
  -- scheduled jobs: a pg_cron run that failed in the last hour, or a job run marked failed
  if to_regclass('cron.job_run_details') is not null then
    begin
      execute $q$select string_agg(distinct j.jobname, ', ') from cron.job_run_details d join cron.job j on j.jobid = d.jobid
                  where d.status = 'failed' and d.start_time > $1 - interval '1 hour'$q$ into v_cron using p_now;
    exception when others then v_cron := null;
    end;
  end if;
  select string_agg(distinct job_name, ', ') into v_jobs from job_runs where status = 'failed' and coalesce(finished_at, started_at) > p_now - interval '1 hour';
  v_detail := nullif(concat_ws('; ', 'pg_cron: ' || v_cron, 'failed runs: ' || v_jobs), '');
  v_out := v_out || jsonb_build_object('jobs', app.uptime_record('jobs', v_detail is null, null, null, coalesce(v_detail, 'No failed run in the last hour'), p_now));
  -- the nightly backup: the last run failed, or the last good one is too old (only once a backup has run)
  select * into b from job_runs where job_name = 'backup-nightly' order by started_at desc limit 1;
  select max(coalesce(finished_at, started_at)) into v_ok_at from job_runs where job_name = 'backup-nightly' and status = 'succeeded';
  if b.id is null then
    v_out := v_out || jsonb_build_object('backup', app.uptime_record('backup', true, null, null, 'No backup recorded yet on this database', p_now));
  else
    v_detail := case when b.status = 'failed' then 'The last nightly backup failed: ' || coalesce(left(b.error, 200), 'see the backup workflow')
                     when v_ok_at is null or v_ok_at < p_now - make_interval(hours => ps.uptime_backup_max_hours)
                       then format('No good backup for more than %s hours (last: %s)', ps.uptime_backup_max_hours, coalesce(app.fmt_at(v_ok_at), 'never')) end;
    v_out := v_out || jsonb_build_object('backup', app.uptime_record('backup', v_detail is null, null, null,
      coalesce(v_detail, 'Last good backup ' || app.fmt_at(v_ok_at)), p_now));
  end if;
  -- Stripe: events that failed to process in the last hour (Stripe retries; a later success clears the error)
  select count(*) into v_stripe from webhook_events where provider = 'stripe' and error is not null and received_at > p_now - interval '1 hour';
  v_out := v_out || jsonb_build_object('stripe', app.uptime_record('stripe', v_stripe = 0, null, null,
    case when v_stripe = 0 then 'No failed Stripe event in the last hour' else format('%s Stripe events failed to process in the last hour', v_stripe) end, p_now));
  return v_out;
end $$;

-- What a page answered, in words.
create or replace function app.uptime_page_detail(p_http integer, p_body text, p_timed_out boolean, p_error text) returns text
language sql immutable as $$
  select case
    when p_timed_out then 'No answer within 15 seconds'
    when p_http is null then 'No answer: ' || coalesce(left(p_error, 200), 'the request failed')
    when p_body ~ '1102' and p_http >= 500 then 'Answered ' || p_http || ' with Error 1102 (the web host stopped the page)'
    when p_http >= 500 then 'Answered ' || p_http || ' (server error)'
    when p_http >= 400 then 'Answered ' || p_http
    else 'Answered ' || p_http end
$$;

-- pg_cron, every minute: collect the answers of the pages asked last time; every uptime_interval_minutes, run the
-- checks without requests and ask the pages again (pg_net; nothing is asked where pg_net is absent).
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
    for r in execute $q$select p.request_id, p.check_key, p.sent_at, x.status_code, x.timed_out, x.error_msg, left(x.content, 4000) as body, x.created
                          from uptime_probes p left join net._http_response x on x.id = p.request_id$q$ loop
      if r.created is null and r.sent_at > p_now - interval '3 minutes' then continue; end if;
      perform app.uptime_record(r.check_key,
        r.created is not null and coalesce(r.timed_out, false) = false and r.status_code between 200 and 399
          and not (r.check_key = 'health' and coalesce(r.body, '') !~ '"ok"\s*:\s*true'),
        r.status_code, case when r.created is not null then greatest(0, (extract(epoch from r.created - r.sent_at) * 1000)::integer) end,
        case when r.created is null then 'No answer within 3 minutes'
             when r.check_key = 'health' and r.status_code between 200 and 399 and coalesce(r.body, '') !~ '"ok"\s*:\s*true' then 'The health check answered without "ok": the site could not reach the database'
             else app.uptime_page_detail(r.status_code, r.body, r.timed_out, r.error_msg) end, p_now);
      delete from uptime_probes where request_id = r.request_id;
      v_collected := v_collected + 1;
    end loop;
  end if;
  -- 2. time for the next round?
  v_due := not exists (select 1 from uptime_checks where kind = 'internal' and enabled and last_checked_at > p_now - make_interval(mins => ps.uptime_interval_minutes) + interval '30 seconds');
  if not v_due then return format('collected %s', v_collected); end if;
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
  -- 3. old results go
  delete from uptime_results where at < p_now - make_interval(days => ps.uptime_keep_days);
  if to_regclass('cron.job_run_details') is not null and app.local_hour(p_now) = 4 and extract(minute from p_now at time zone 'America/Toronto') < 5 then
    begin
      execute $q$delete from cron.job_run_details where end_time < $1 - interval '14 days'$q$ using p_now;
    exception when others then null;
    end;
  end if;
  return format('collected %s, asked %s', v_collected, v_sent);
end $$;

-- The site's own health answer (/api/health): the database is reachable and answers.
create or replace function app.health_ping() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('ok', true, 'at', now(), 'migrations', (select count(*) from pg_proc where proname = 'job_uptime'))
$$;

-- Admin > Today: the status panel.
create or replace function app.site_health(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings();
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object(
    'enabled', ps.uptime_enabled, 'interval', ps.uptime_interval_minutes, 'alert_email', ps.uptime_alert_email,
    'checks', coalesce((select jsonb_agg(jsonb_build_object('key', c.key, 'label', c.label, 'kind', c.kind, 'status', c.status,
                 'checked_at', c.last_checked_at, 'ok_at', c.last_ok_at, 'http', c.last_http, 'ms', c.last_ms, 'detail', c.last_detail,
                 'failures', c.consecutive_failures, 'advice', c.advice,
                 'day', (select jsonb_build_object('checks', count(*), 'failed', count(*) filter (where not u.ok))
                           from uptime_results u where u.check_key = c.key and u.at > now() - interval '24 hours')) order by c.sort)
               from uptime_checks c where c.enabled), '[]'::jsonb),
    'open', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'label', c.label, 'opened_at', a.opened_at, 'detail', a.detail, 'emailed', a.emailed, 'advice', c.advice)
                                order by a.opened_at)
               from site_alerts a join uptime_checks c on c.key = a.check_key where a.resolved_at is null), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('label', c.label, 'opened_at', a.opened_at, 'resolved_at', a.resolved_at, 'detail', a.detail) order by a.opened_at desc)
               from (select * from site_alerts where resolved_at is not null and opened_at > now() - interval '7 days' order by opened_at desc limit 10) a
               join uptime_checks c on c.key = a.check_key), '[]'::jsonb));
end $$;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-booking-recovery', '7,22,37,52 * * * *', 'select app.job_booking_recovery()');
    perform cron.schedule('carmacars-uptime', '* * * * *', 'select app.job_uptime()');
  end if;
end $$;

-- ================================================================ 9. Admin To do: site problems and calendar clashes first
alter function app.admin_todo(uuid) rename to admin_todo_0058;
create or replace function app.admin_todo(p_admin uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.admin_todo_0058(p_admin);
begin
  return jsonb_set(v, '{items}', jsonb_build_array(
    jsonb_build_object('key', 'site_alerts', 'label', 'Site problems found by the site check', 'button', 'See site health', 'href', '/admin#site-health',
                       'count', (select count(*) from site_alerts where resolved_at is null)),
    jsonb_build_object('key', 'calendar_conflicts', 'label', 'Double bookings with Turo or another platform', 'button', 'Fix the calendar', 'href', '/admin/calendar-sync',
                       'count', (select count(*) from calendar_conflicts where resolved_at is null and kind = 'booking'))) || (v -> 'items') || jsonb_build_array(
    jsonb_build_object('key', 'calendar_feeds', 'label', 'Calendar links not working', 'button', 'Check the links', 'href', '/admin/calendar-sync',
                       'count', (select count(*) from calendar_feeds where enabled and last_status = 'error' and consecutive_failures >= (app.settings()).calendar_feed_alert_failures))));
end $$;

-- ================================================================ 10. emails: recipients and values
insert into notification_link_paths (key, path) values ('admin_calendar_sync', '/admin/calendar-sync'), ('va_calendar_sync', '/va/calendar-sync')
on conflict (key) do update set path = excluded.path;

alter function app.notification_recipients(app_events, notification_catalogue) rename to notification_recipients_pre0062;
create or replace function app.notification_recipients(p_event app_events, p_c notification_catalogue)
returns table (audience text, user_id uuid, email text, name text, renter_id uuid, owner_id uuid, immediate boolean)
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_to text;
begin
  if p_c.code in ('staff_site_alert', 'staff_site_recovered') then
    -- the alert address of Program settings (rent@carmacars.ca by default), whether or not it has an account
    v_to := lower(btrim((app.settings()).uptime_alert_email));
    return query select 'staff_admin'::text, (select u.id from users u where lower(u.email) = v_to limit 1), v_to,
                        coalesce((select u.full_name from users u where lower(u.email) = v_to limit 1), 'CarmaCars admin'), null::uuid, null::uuid, true;
    return;
  end if;
  if p_c.code = 'renter_recovery_request' then
    return query select 'renter'::text, r.user_id, coalesce(nullif(r.email, ''), u.email), r.legal_name, r.id, null::uuid, true
                   from renters r left join users u on u.id = r.user_id where r.id = (p_event.payload ->> 'renter_id')::uuid;
    return;
  end if;
  return query select * from app.notification_recipients_pre0062(p_event, p_c);
end $$;

alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre0062;
create or replace function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_pre0062(p_code, p_event, p_to);
  k calendar_conflicts;
  e calendar_feed_events;
  f calendar_feeds;
  b bookings;
  a site_alerts;
  c uptime_checks;
  ch booking_change_requests;
  v_staff_url text;
begin
  v_staff_url := app.ntf_link(case when (p_to ->> 'audience') = 'staff_admin' then 'admin_calendar_sync' else 'va_calendar_sync' end);
  if p_code = 'staff_calendar_conflict' then
    select * into k from calendar_conflicts where id = p_event.entity_id;
    select * into e from calendar_feed_events where id = k.event_id;
    select * into f from calendar_feeds where id = e.feed_id;
    select * into b from bookings where id = k.booking_id;
    x := x || jsonb_build_object('vehicle_name', app.vehicle_name(coalesce(e.vehicle_id, b.vehicle_id)), 'platform', coalesce(app.calendar_feed_name(f), 'Another platform'),
      'booking_number', b.booking_number, 'external_start', coalesce(app.fmt_at(e.starts_at), ''), 'external_end', coalesce(app.fmt_at(e.ends_at), ''),
      'external_summary', coalesce(nullif(e.summary, ''), 'No title'), 'booking_start', coalesce(app.fmt_at(b.pickup_at), ''),
      'booking_end', coalesce(app.fmt_at(b.return_at), ''), 'calendar_url', v_staff_url);
  elsif p_code = 'staff_calendar_feed_failing' then
    select * into f from calendar_feeds where id = p_event.entity_id;
    x := x || jsonb_build_object('vehicle_name', app.vehicle_name(f.vehicle_id), 'platform', coalesce(app.calendar_feed_name(f), 'Another platform'),
      'failures', coalesce(p_event.payload ->> 'failures', f.consecutive_failures::text, '0'), 'feed_error', coalesce(f.last_error, 'The link could not be read.'),
      'last_success', coalesce(app.fmt_at(f.last_success_at), 'never'), 'calendar_url', v_staff_url);
  elsif p_code in ('staff_site_alert', 'staff_site_recovered') then
    select * into a from site_alerts where id = p_event.entity_id;
    select * into c from uptime_checks where key = a.check_key;
    x := x || jsonb_build_object('check_label', coalesce(c.label, 'Site check'), 'alert_detail', coalesce(a.detail, 'The check failed'),
      'alert_opened', coalesce(app.fmt_at(a.opened_at), ''), 'alert_resolved', coalesce(app.fmt_at(a.resolved_at), ''),
      'failures', coalesce(a.failures, 1)::text, 'alert_advice', coalesce(c.advice, ''),
      'alert_duration', case when a.resolved_at is null then ''
                             when a.resolved_at - a.opened_at < interval '90 minutes' then greatest(1, round(extract(epoch from a.resolved_at - a.opened_at) / 60))::integer || ' minutes'
                             when a.resolved_at - a.opened_at < interval '48 hours' then round(extract(epoch from a.resolved_at - a.opened_at) / 3600)::integer || ' hours'
                             else round(extract(epoch from a.resolved_at - a.opened_at) / 86400)::integer || ' days' end);
  elsif p_code = 'renter_recovery_change' then
    select * into ch from booking_change_requests where id = (p_event.payload ->> 'change_id')::uuid;
    x := x || jsonb_build_object('accept_by', coalesce(app.fmt_at(ch.accept_by), 'the date in the proposal'));
  elsif p_code = 'renter_recovery_request' then
    x := x || jsonb_build_object(
      'first_name', coalesce(nullif(split_part(coalesce(p_to ->> 'name', ''), ' ', 1), ''), 'there'),
      'vehicle_name', coalesce(app.vehicle_name((p_event.payload ->> 'vehicle_id')::uuid), 'car you chose'),
      'car_url', (app.settings()).notify_base_url || coalesce((select '/cars/' || l.slug from vehicle_listings l
                                                                where l.vehicle_id = (p_event.payload ->> 'vehicle_id')::uuid and l.slug is not null), '/cars'));
  end if;
  return x;
end $$;

-- ================================================================ 11. the doors and privileges
create or replace function app.ops62(p_user uuid, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  case p_name
  when 'calendar_sync' then return app.calendar_sync_read(p_user, p);
  when 'site_health' then return app.site_health(p_user);
  when 'calendar_feed_add', 'calendar_feed_save', 'calendar_feed_remove', 'calendar_export_rotate', 'calendar_feed_sync_start', 'calendar_feed_result' then
    return app.calendar_sync_do(p_user, p_name, p);
  else raise exception 'Unknown action %', p_name using errcode = '22023';
  end case;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0062;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
begin
  if (p_call in ('va_read', 'admin_read', 'ops_read') and p_name = 'calendar_sync')
     or (p_call in ('admin_read', 'ops_read') and p_name = 'site_health')
     or (p_call in ('va_do', 'admin_do', 'ops_do') and p_name in ('calendar_feed_add', 'calendar_feed_save', 'calendar_feed_remove', 'calendar_export_rotate',
                                                                  'calendar_feed_sync_start', 'calendar_feed_result')) then
    if p_ ? '_va' then perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.ops62(p_user, p_call, p_name, p_ - '_va');
  end if;
  return app.door_pre0062(p_user, p_aal, p_call, p_name, p);
end $$;

-- server wrappers (the Worker: the export link and the health answer; the Edge Function calls app.* directly)
create or replace function public.calendar_export_ics(p_token text, p_for text default null) returns text
language sql security definer set search_path = public, app as $$ select app.calendar_export_ics(p_token, nullif(p_for, '')) $$;
create or replace function public.health_ping() returns jsonb
language sql security definer set search_path = public, app as $$ select app.health_ping() $$;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array[
              'vehicle_calendar_export_new', 'platform_name', 'calendar_feed_name', 'assert_calendar_staff', 'calendar_feeds_due', 'calendar_conflicts_check',
              'calendar_feed_apply', 'calendar_feed_failed', 'ical_text', 'ical_utc', 'calendar_export_ics', 'calendar_feed_row', 'calendar_sync_read',
              'calendar_sync_do', 'recovery_staff_handling', 'recovery_reason_passed', 'job_booking_recovery', 'uptime_url', 'uptime_record',
              'uptime_internal', 'uptime_page_detail', 'job_uptime', 'health_ping', 'site_health', 'admin_todo', 'notification_recipients',
              'notification_payload', 'ops62', 'door']))
        or (n.nspname = 'public' and p.proname = any (array['calendar_export_ics', 'health_ping']))
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
             join (values ('door_pre0062', 'door'), ('notification_recipients_pre0062', 'notification_recipients'),
                          ('ntf_payload_pre0062', 'notification_payload'), ('admin_todo_0058', 'admin_todo')) m(old_name, new_name)
               on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    execute format('revoke all on function %s from public, anon, authenticated', v_new);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;

-- ================================================================ 12. the email catalogue
-- CATALOGUE 0062 START (generated by supabase/seed/0062_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('renter_recovery_change', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Your answer to the change to booking {{booking_number}}', 'Answer by {{accept_by}}. If you do nothing, your booking stays as it is.', 'Some hours after the proposal was opened', 'Booking recovery job (every 15 minutes): the renter opened a change staff proposed to their booking and has not answered it after recovery_change_hours (Program settings, 4 by default). At most recovery_max_emails (2), the second after recovery_second_hours (24). Not sent when the deadline is within the change reminder hours (that reminder covers it), outside the hours set for these emails, to a renter who unsubscribed or turned these reminders off, or while a staff member is already handling the renter. Stops once the change is accepted, declined or expires.', null, '/account/bookings/{{booking_number}}/change', '[{"name":"accept_by","type":"string"},{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_recovery_change.html', 'templates/renter_recovery_change.txt'),
  ('renter_recovery_offer', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Still thinking about the {{vehicle_name}}?', 'Your offer is open until {{offer_expires_at}}. Questions? Reply to this email.', 'Some hours after the offer was opened', 'Booking recovery job (every 15 minutes): the renter opened their offer (page or email link) and has not answered it after recovery_offer_hours (Program settings, 4 by default). At most recovery_max_emails (2) per offer, the second after recovery_second_hours (24). Not sent when the offer expires within 7 hours (the expiry reminder covers it) or an expiry reminder went in the last 12 hours, outside the hours set for these emails, to a renter who unsubscribed or turned these reminders off, or while a staff member is already handling the renter (an assigned task, a chat with a person, a message from staff). Stops once the offer is answered, expires or is withdrawn.', null, '/account/bookings/{{booking_number}}/offer', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"offer_expires_at","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"pickup_date","type":"string"},{"name":"pickup_time","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_time","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"total_amount","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_recovery_offer.html', 'templates/renter_recovery_offer.txt'),
  ('renter_recovery_pay', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'One step left to book the {{vehicle_name}}', 'Your card is not charged until you finish. Need help? Reply to this email.', 'An hour after the pay page was left', 'Booking recovery job (every 15 minutes): the renter left the pay page of their approved booking (pending_payment) without paying, recovery_pay_minutes ago (Program settings, 60 by default). At most recovery_max_emails (2), the second after recovery_second_hours (24). Not sent outside the hours set for these emails, to a renter who unsubscribed or turned these reminders off, or while a staff member is already handling the renter. Stops once they pay or the booking leaves pending_payment.', null, '/account/bookings/{{booking_number}}/pay', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"pickup_date","type":"string"},{"name":"pickup_time","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_time","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"total_amount","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_recovery_pay.html', 'templates/renter_recovery_pay.txt'),
  ('renter_recovery_request', 'renter', '{}'::text[], 'marketing', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Your request for the {{vehicle_name}} is not sent yet', 'Pick up where you left off. It takes two minutes.', 'Some hours after a request was started', 'Booking recovery job (every 15 minutes): a signed-in or known renter started a booking request on the site and stopped without sending it, recovery_request_hours ago (Program settings, 2 by default), and has sent no request since. Marketing: only with the renter''s express marketing consent and never after they unsubscribed. At most recovery_max_emails (2), the second after recovery_second_hours (24), and one such reminder series per renter in 7 days. Not sent outside the hours set for these emails or while a staff member is already handling the renter. Stops once they send a request.', null, null, '[{"name":"car_url","type":"url"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"unsubscribe_url","type":"url"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_recovery_request.html', 'templates/renter_recovery_request.txt'),
  ('staff_calendar_conflict', 'staff_va_fleet', array['staff_admin']::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Double booking: {{vehicle_name}} on {{platform}} and {{booking_number}}', '{{platform}} has the car from {{external_start}} to {{external_end}}.', 'Immediate', 'Calendar sync (every 10 minutes by default): a trip or block imported from another platform (Turo, Getaround or another calendar link) overlaps a confirmed or on-rent CarmaCars booking of the same car, turnaround included. One email per imported event and booking; it also raises an urgent Fleet task and shows on the Admin To do. Immediate.', null, null, '[{"name":"booking_end","type":"string"},{"name":"booking_number","type":"string"},{"name":"booking_start","type":"string"},{"name":"calendar_url","type":"url"},{"name":"company_address","type":"string","global":true},{"name":"external_end","type":"string"},{"name":"external_start","type":"string"},{"name":"external_summary","type":"string"},{"name":"platform","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/staff_calendar_conflict.html', 'templates/staff_calendar_conflict.txt'),
  ('staff_calendar_feed_failing', 'staff_va_fleet', array['staff_admin']::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Calendar link not working: {{vehicle_name}} on {{platform}}', '{{failures}} failed tries in a row. {{feed_error}}', 'Immediate', 'Calendar sync: an imported calendar link (Turo, Getaround or another platform) failed this many times in a row (calendar_feed_alert_failures in Program settings, 3 by default). Sent once per run of failures; it also raises a Fleet task. The trips already imported stay on the calendar until the link works again. Immediate.', null, null, '[{"name":"calendar_url","type":"url"},{"name":"company_address","type":"string","global":true},{"name":"failures","type":"string"},{"name":"feed_error","type":"string"},{"name":"last_success","type":"string"},{"name":"platform","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/staff_calendar_feed_failing.html', 'templates/staff_calendar_feed_failing.txt'),
  ('staff_site_alert', 'staff_admin', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Site alert: {{check_label}}', '{{alert_detail}}', 'Immediate', 'Site check (every 5 minutes, from the database): a page or service failed its check repeatedly (the home page, a car page, sign-in or the site''s health check answers an error or Error 1102, or does not answer), emails are failing or stuck, a scheduled job failed, the nightly backup failed or is late, or Stripe webhooks are failing. Sent to the alert address in Program settings (uptime_alert_email), once per problem; a second problem of the same kind within the cooldown is shown on Admin > To do without another email. Immediate.', null, '/admin', '[{"name":"alert_advice","type":"string"},{"name":"alert_detail","type":"string"},{"name":"alert_opened","type":"string"},{"name":"check_label","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"failures","type":"string"}]'::jsonb, 'templates/staff_site_alert.html', 'templates/staff_site_alert.txt'),
  ('staff_site_recovered', 'staff_admin', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Recovered: {{check_label}}', 'Working again since {{alert_resolved}}, after {{alert_duration}}.', 'Immediate', 'Site check: a problem that sent a site alert passed its check again. One email per alert that was emailed, to the same address. Immediate.', null, '/admin', '[{"name":"alert_detail","type":"string"},{"name":"alert_duration","type":"string"},{"name":"alert_opened","type":"string"},{"name":"alert_resolved","type":"string"},{"name":"check_label","type":"string"},{"name":"company_address","type":"string","global":true}]'::jsonb, 'templates/staff_site_recovered.html', 'templates/staff_site_recovered.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 0062 END
update notification_catalogue set emitted_by = 'app.calendar_conflicts_check (0062)' where code = 'staff_calendar_conflict';
update notification_catalogue set emitted_by = 'app.calendar_feed_failed (0062)' where code = 'staff_calendar_feed_failing';
update notification_catalogue set emitted_by = 'app.uptime_record (0062)' where code in ('staff_site_alert', 'staff_site_recovered');
update notification_catalogue set emitted_by = 'app.job_booking_recovery (0062)' where code like 'renter_recovery_%';

-- ================================================================ 13. the guides for this release
create or replace function app.guide_release_0062(p_portal text, p_slug text, p_kind text, p_after text, p_base_md text, p_title text, p_blurb text,
                                                  p_md text, p_html text) returns text
language sql security definer set search_path = public, app as $$
  select app.guide_release_section(p_portal, p_slug, p_kind, p_after, p_base_md, p_title, p_blurb, p_md, p_html)
$$;
revoke all on function app.guide_release_0062(text, text, text, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function app.guide_release_0062(text, text, text, text, text, text, text, text, text) to service_role;

-- GUIDES 0062 START (generated by supabase/seed/0062_gen_guides.mjs from docs/guides/content; do not edit by hand)
-- GUIDES 0062 END
