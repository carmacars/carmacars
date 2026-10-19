-- 0060_live_visitors_chat.sql
-- The owner's request of October 19, 2026 (docs/changes/2026-10-19-live-visitors-chat.md):
--   A. live visitors and buying signals: a first-party beacon (no third-party analytics) records sessions, page views
--      and key events (dates searched, a car opened, a booking request started, stopped or sent, an offer email link
--      opened, the offer, the change proposal and the pay page viewed or left, the chat opened), the referrer and UTM,
--      the device and an approximate city from Cloudflare (no network address is stored). Analytics need the visitor's
--      consent; without it only what the chat and a known customer's own booking pages need is kept. A visitor is
--      known when signed in or arriving from one of our emails (the outbox row in the link). Signals with badges, a
--      Live page for Admins, customer service and Sales, interest per car, a timeline on the renter and the booking,
--      follow-up tasks with a suggested action (thresholds in Program settings), raw events kept 90 days (a setting),
--      daily counts per car kept.
--   B. live chat: an AI assistant first (Workers AI, called by the site; the database gives it facts, availability
--      and prices through the existing pricing functions and records every reply), then a person: an inbox for staff
--      with the visitor's session beside the conversation, take over, reply, hand back, close, typing and unread
--      counts, proactive chats, contact details and a task after hours, the transcript by email, retention settings.
-- No applied migration is edited. Every new table has row-level security with the Admin policy; the browser reaches
-- them only through the functions below.

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists visitor_tracking_enabled boolean not null default true,
  add column if not exists visitor_events_keep_days integer not null default 90 check (visitor_events_keep_days between 7 and 730),
  add column if not exists visitor_live_minutes integer not null default 3 check (visitor_live_minutes between 1 and 30),
  add column if not exists visitor_spree_cars integer not null default 6 check (visitor_spree_cars between 2 and 50),
  add column if not exists visitor_spree_minutes integer not null default 10 check (visitor_spree_minutes between 1 and 120),
  add column if not exists visitor_offer_no_answer_hours integer not null default 6 check (visitor_offer_no_answer_hours between 1 and 72),
  add column if not exists visitor_proposal_opens integer not null default 2 check (visitor_proposal_opens between 1 and 20),
  add column if not exists visitor_returning_visits integer not null default 3 check (visitor_returning_visits between 2 and 30),
  add column if not exists visitor_pay_left_minutes integer not null default 30 check (visitor_pay_left_minutes between 5 and 1440),
  add column if not exists visitor_request_stopped_minutes integer not null default 30 check (visitor_request_stopped_minutes between 5 and 1440),
  add column if not exists visitor_followup_tasks boolean not null default true,
  add column if not exists chat_enabled boolean not null default true,
  add column if not exists chat_ai_enabled boolean not null default true,
  add column if not exists chat_ai_model text not null default '@cf/meta/llama-3.3-70b-instruct-fp8-fast',
  add column if not exists chat_ai_daily_neurons integer not null default 6000 check (chat_ai_daily_neurons >= 0),
  add column if not exists chat_ai_total_daily_neurons integer not null default 10000 check (chat_ai_total_daily_neurons >= 0),
  add column if not exists chat_ai_max_replies integer not null default 12 check (chat_ai_max_replies between 1 and 100),
  add column if not exists chat_greeting_seconds integer not null default 0 check (chat_greeting_seconds between 0 and 600),
  add column if not exists chat_greeting_text text not null default 'Hi! Questions about this car? I can check dates and prices for you.',
  add column if not exists chat_shift_minutes integer not null default 15 check (chat_shift_minutes between 1 and 240),
  add column if not exists chat_keep_days integer not null default 365 check (chat_keep_days between 30 and 2555);
comment on column program_settings.visitor_tracking_enabled is 'Live visitors (0060): record visits on the site. Off: nothing is recorded and the Live page stays empty.';
comment on column program_settings.visitor_events_keep_days is 'Live visitors (0060): page views and events are deleted after this many days (90 by default). The daily counts per car are kept.';
comment on column program_settings.visitor_live_minutes is 'Live visitors (0060): a visitor seen within this many minutes is on the site now.';
comment on column program_settings.visitor_spree_cars is 'Signal "Viewing spree": this many different cars ...';
comment on column program_settings.visitor_spree_minutes is '... within this many minutes.';
comment on column program_settings.visitor_offer_no_answer_hours is 'Follow-up: an offer opened and not answered after this many hours raises a task.';
comment on column program_settings.visitor_proposal_opens is 'Signal: the change proposal opened this many times without an answer.';
comment on column program_settings.visitor_returning_visits is 'Signal "Returning visitor": this many visits in 7 days.';
comment on column program_settings.visitor_pay_left_minutes is 'Follow-up: the pay page left without paying, this many minutes ago.';
comment on column program_settings.visitor_request_stopped_minutes is 'Follow-up: a booking request started and not sent, this many minutes ago (known visitors only).';
comment on column program_settings.visitor_followup_tasks is 'Signals of known visitors raise follow-up tasks for customer service and Sales.';
comment on column program_settings.chat_enabled is 'Live chat (0060): the chat button on the site and portals.';
comment on column program_settings.chat_ai_enabled is 'Live chat: the AI assistant answers first. Off: every chat waits for a person.';
comment on column program_settings.chat_ai_model is 'Live chat: the Workers AI model.';
comment on column program_settings.chat_ai_daily_neurons is 'Live chat: the AI stops for the day once chat replies used this many neurons (Toronto day); chats then wait for a person.';
comment on column program_settings.chat_ai_total_daily_neurons is 'Live chat: the AI also stops once every Workers AI use of the day (listing copy, guides, vision, chat) reached this many neurons (10,000 a day are free).';
comment on column program_settings.chat_ai_max_replies is 'Live chat: AI replies in one conversation before a person takes it over.';
comment on column program_settings.chat_greeting_seconds is 'Live chat: the assistant greets a visitor on a car page after this many seconds (0: off).';
comment on column program_settings.chat_greeting_text is 'Live chat: the greeting.';
comment on column program_settings.chat_shift_minutes is 'Live chat: a staff member with Live chat or Live visitors open within this many minutes is on shift; with nobody on shift a chat collects contact details.';
comment on column program_settings.chat_keep_days is 'Live chat: conversations not linked to a renter or booking are deleted after this many days. Those linked to a renter are kept with the rental records.';

-- ================================================================ 2. tables
create table visitor_sessions (
  id                 uuid primary key,                       -- the browser tab's session id (random, kept for 30 minutes of inactivity)
  visitor_id         uuid not null,                          -- the browser's id (first-party cookie cc_vid)
  user_id            uuid references users (id) on delete set null,
  renter_id          uuid references renters (id) on delete set null,
  known_name         text,
  known_email        text,
  identified_by      text check (identified_by in ('sign_in', 'email_link', 'chat', 'request')),
  consent            text not null default 'essential' check (consent in ('analytics', 'essential')),
  started_at         timestamptz not null default now(),
  last_seen_at       timestamptz not null default now(),
  city               text,
  region             text,
  country            text,
  device             text check (device in ('phone', 'tablet', 'desktop')),
  referrer           text,                                   -- the referring site's host only
  utm                jsonb not null default '{}'::jsonb,
  landing_path       text,
  current_path       text,
  current_vehicle_id uuid references vehicles (id) on delete set null,
  current_booking_id uuid references bookings (id) on delete set null,
  page_views         integer not null default 0,
  cars_viewed        uuid[] not null default '{}',
  visit_number       integer not null default 1,
  ended_at           timestamptz
);
create index visitor_sessions_seen_idx on visitor_sessions (last_seen_at desc);
create index visitor_sessions_visitor_idx on visitor_sessions (visitor_id, started_at desc);
create index visitor_sessions_renter_idx on visitor_sessions (renter_id) where renter_id is not null;
comment on table visitor_sessions is 'Live visitors (0060): one browser session on the site. No network address is stored; the city comes from Cloudflare.';

create table visitor_events (
  id          bigserial primary key,
  session_id  uuid not null references visitor_sessions (id) on delete cascade,
  at          timestamptz not null default now(),
  kind        text not null check (kind in ('page_view', 'page_leave', 'search', 'car_view', 'request_started', 'request_abandoned',
                'request_submitted', 'email_link_opened', 'offer_viewed', 'change_viewed', 'pay_viewed', 'pay_left', 'chat_opened')),
  path        text,
  vehicle_id  uuid references vehicles (id) on delete set null,
  booking_id  uuid references bookings (id) on delete set null,
  ms          integer check (ms >= 0),                       -- time on the page, for page_leave
  data        jsonb not null default '{}'::jsonb
);
create index visitor_events_session_idx on visitor_events (session_id, at);
create index visitor_events_at_idx on visitor_events (at);
create index visitor_events_booking_idx on visitor_events (booking_id, at) where booking_id is not null;
create index visitor_events_vehicle_idx on visitor_events (vehicle_id, at) where vehicle_id is not null;

create table visitor_signals (
  id          uuid primary key default gen_random_uuid(),
  dedupe_key  text not null unique,
  session_id  uuid references visitor_sessions (id) on delete set null,
  visitor_id  uuid not null,
  renter_id   uuid references renters (id) on delete set null,
  kind        text not null check (kind in ('viewing_spree', 'offer_opened', 'proposal_opened', 'pay_left', 'returning', 'request_stopped')),
  label       text not null,
  booking_id  uuid references bookings (id) on delete set null,
  vehicle_id  uuid references vehicles (id) on delete set null,
  times       integer not null default 1,
  first_at    timestamptz not null default now(),
  last_at     timestamptz not null default now(),
  resolved_at timestamptz,
  task_id     uuid references tasks (id) on delete set null
);
create index visitor_signals_open_idx on visitor_signals (last_at desc) where resolved_at is null;
create index visitor_signals_visitor_idx on visitor_signals (visitor_id);

create table vehicle_interest_daily (
  vehicle_id uuid not null references vehicles (id) on delete cascade,
  day        date not null,
  views      integer not null default 0,
  viewers    integer not null default 0,
  requests   integer not null default 0,
  primary key (vehicle_id, day)
);
comment on table vehicle_interest_daily is 'Live visitors (0060): page views, distinct sessions and requests sent per car and Toronto day. Kept when raw events are deleted.';

create sequence chat_number_seq start 1001;
create table chat_conversations (
  id                   uuid primary key default gen_random_uuid(),
  number               text not null unique default ('LC-' || nextval('chat_number_seq')),
  token                text not null unique default (replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')),
  session_id           uuid references visitor_sessions (id) on delete set null,
  visitor_id           uuid,
  user_id              uuid references users (id) on delete set null,
  renter_id            uuid references renters (id) on delete set null,
  name                 text,
  email                text,
  phone                text,
  status               text not null default 'ai' check (status in ('ai', 'waiting', 'human', 'closed')),
  started_by           text not null default 'visitor' check (started_by in ('visitor', 'staff', 'greeting')),
  started_by_staff     uuid references users (id),
  assigned_to          uuid references users (id),
  human_requested_at   timestamptz,
  human_reason         text,
  first_human_reply_at timestamptz,
  offline              boolean not null default false,
  page                 text,
  vehicle_id           uuid references vehicles (id) on delete set null,
  booking_id           uuid references bookings (id) on delete set null,
  lead_id              uuid references leads (id) on delete set null,
  task_id              uuid references tasks (id) on delete set null,
  last_message_at      timestamptz not null default now(),
  last_visitor_at      timestamptz,
  staff_read_id        bigint not null default 0,
  visitor_read_id      bigint not null default 0,
  visitor_typing_at    timestamptz,
  staff_typing_at      timestamptz,
  ai_replies           integer not null default 0,
  ai_neurons           integer not null default 0,
  transcript_sent_at   timestamptz,
  closed_at            timestamptz,
  closed_by            uuid references users (id),
  created_at           timestamptz not null default now()
);
create index chat_conversations_open_idx on chat_conversations (last_message_at desc) where status <> 'closed';
create index chat_conversations_visitor_idx on chat_conversations (visitor_id, created_at desc);
create index chat_conversations_renter_idx on chat_conversations (renter_id) where renter_id is not null;
comment on column chat_conversations.token is 'The visitor''s secret for this conversation (kept in their browser). Never shown to staff.';

create table chat_messages (
  id              bigserial primary key,
  conversation_id uuid not null references chat_conversations (id) on delete cascade,
  at              timestamptz not null default now(),
  sender          text not null check (sender in ('visitor', 'ai', 'staff', 'system')),
  staff_id        uuid references users (id),
  body            text not null check (length(body) between 1 and 4000),
  meta            jsonb not null default '{}'::jsonb
);
create index chat_messages_conv_idx on chat_messages (conversation_id, id);

create table chat_staff_prefs (
  user_id            uuid primary key references users (id) on delete cascade,
  email_when_waiting boolean not null default false,
  desktop_alerts     boolean not null default false,
  last_seen_at       timestamptz
);

do $$
declare t text;
begin
  foreach t in array array['visitor_sessions', 'visitor_events', 'visitor_signals', 'vehicle_interest_daily', 'chat_conversations', 'chat_messages', 'chat_staff_prefs'] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('revoke all on %I from anon, authenticated', t);
  end loop;
end $$;

alter table leads drop constraint if exists leads_kind_check;
alter table leads add constraint leads_kind_check check (kind in ('owner_program', 'contact', 'insurer', 'launch_notice', 'other', 'chat'));

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, description) values
  ('visitor_follow_up', 'sales', 'Follow up a visitor', 'normal', 'opening_minutes', 60, 'A buying signal of a known visitor (Live visitors): call or message them'),
  -- due at the first reply target in force when raised (app.task_due('first_reply'), given by the raising function)
  ('live_chat_waiting', 'cs', 'A visitor asked for a person in live chat', 'high', 'opening_minutes', 5, 'Reply in Live chat within the first reply target'),
  ('chat_request', 'sales', 'Booking request from live chat', 'high', 'opening_minutes', 5, 'The chat assistant collected a request: quote it or call back'),
  ('chat_contact', 'cs', 'Reply to a chat left after hours', 'normal', 'opening_minutes', 5, 'The visitor left contact details while nobody was on shift')
on conflict (task_type) do update set queue = excluded.queue, title = excluded.title, priority = excluded.priority,
  due_kind = excluded.due_kind, due_amount = excluded.due_amount, description = excluded.description;

-- ================================================================ 3. helpers
-- Admins, customer service and Sales work Live visitors and Live chat.
create or replace function app.live_staff_ok(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_user is not null and (app.user_is_admin(p_user) or app.user_va_has(p_user, 'cs', 'sales'))
$$;
create or replace function app.assert_live_staff(p_user uuid) returns void
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.live_staff_ok(p_user) then raise exception 'Live visitors and Live chat are for Admins, customer service and Sales' using errcode = '42501'; end if;
end $$;

create or replace function app.visitor_device_words(p text) returns text
language sql immutable as $$ select case p when 'phone' then 'phone' when 'tablet' then 'tablet' when 'desktop' then 'computer' else 'device not known' end $$;

-- "Maya Chen" when known; otherwise "Visitor from Toronto, phone".
create or replace function app.visitor_who(s visitor_sessions) returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce(nullif(s.known_name, ''),
    (select r.legal_name from renters r where r.id = s.renter_id),
    (select u.full_name from users u where u.id = s.user_id),
    'Visitor' || coalesce(' from ' || nullif(s.city, ''), '') || ', ' || app.visitor_device_words(s.device))
$$;

create or replace function app.visitor_chat_name(c chat_conversations) returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce(nullif(c.name, ''), (select r.legal_name from renters r where r.id = c.renter_id),
    (select app.visitor_who(s) from visitor_sessions s where s.id = c.session_id), 'Visitor')
$$;

create or replace function app.path_label(p text) returns text
language sql immutable as $$
  select case
    when p is null then null
    when p = '/' then 'Home'
    when p ~ '^/cars/[^/]+$' then 'Car page'
    when p ~ '^/rent/' then 'Model page'
    when p = '/cars' then 'All cars'
    when p ~ '^/book/sent' then 'Request sent'
    when p ~ '^/book/' then 'Booking request form'
    when p ~ '^/account/bookings/[^/]+/offer' then 'Offer'
    when p ~ '^/account/bookings/[^/]+/change' then 'Change proposal'
    when p ~ '^/account/bookings/[^/]+/pay' then 'Pay page'
    when p ~ '^/account/bookings/[^/]+/sign' then 'Agreement to sign'
    when p ~ '^/account' then 'Renter portal'
    when p ~ '^/owner' then 'Owner portal'
    when p ~ '^/sign-in' then 'Sign in'
    else initcap(replace(split_part(ltrim(p, '/'), '/', 1), '-', ' '))
  end
$$;

-- The visitor's renter, from an email link (?m=<outbox row>): the row's renter or user, and the booking it was about.
create or replace function app.visitor_from_email_link(p_m text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  o notification_outbox;
begin
  if p_m is null or p_m !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return null; end if;
  select * into o from notification_outbox where id = p_m::uuid and created_at > now() - interval '60 days' and audience = 'renter';
  if o.id is null then return null; end if;
  return jsonb_build_object('code', o.code, 'user_id', o.recipient_user_id,
    'renter_id', coalesce(o.renter_id, (select r.id from renters r where r.user_id = o.recipient_user_id)),
    'email', o.to_address, 'name', o.to_name, 'booking_id', o.booking_id);
end $$;

-- ================================================================ 4. the beacon
-- One call per batch from the site (the Worker's /api/t, or the app's route): the session, its events, the signals,
-- and what the browser should know back (a chat a staff member started, the greeting settings). Staff browsing the
-- site are not recorded. Without analytics consent only a known customer's own booking pages and the chat are kept.
create or replace function app.track_ingest(p jsonb, p_geo jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings();
  v_sid uuid;
  v_vid uuid;
  v_uid uuid := app.uid();
  v_consent text := case when p ->> 'consent' = 'analytics' then 'analytics' else 'essential' end;
  v_known jsonb;
  v_renter uuid;
  v_name text;
  v_email text;
  v_by text;
  s visitor_sessions;
  e jsonb;
  v_kind text;
  v_path text;
  v_vehicle uuid;
  v_booking uuid;
  v_transactional boolean;
  v_keep boolean;
  v_chat boolean;
  v_new boolean := false;
  v_n integer := 0;
  v_day date := app.local_date(now());
  v_invite jsonb;
  v_seen boolean;
  b bookings;
begin
  if p ->> 'sid' !~ '^[0-9a-f-]{36}$' or p ->> 'vid' !~ '^[0-9a-f-]{36}$' then return jsonb_build_object('ok', false, 'error', 'bad ids'); end if;
  v_sid := (p ->> 'sid')::uuid; v_vid := (p ->> 'vid')::uuid;
  if not app.rate_limit('trk:' || v_sid, 90, interval '1 minute')
     or (nullif(p_geo ->> 'ip_key', '') is not null and not app.rate_limit('trk-ip:' || (p_geo ->> 'ip_key'), 600, interval '1 minute')) then
    return jsonb_build_object('ok', false, 'limited', true);
  end if;
  if not ps.visitor_tracking_enabled then return jsonb_build_object('ok', true, 'off', true, 'cfg', app.chat_public_cfg()); end if;
  if v_uid is not null and (app.user_is_admin(v_uid) or app.user_is_staff(v_uid) or app.user_is_field(v_uid)) then
    return jsonb_build_object('ok', true, 'staff', true, 'cfg', app.chat_public_cfg());
  end if;

  -- who: the signed-in renter, or the recipient of the email whose link brought them here
  if v_uid is not null then
    v_renter := (select r.id from renters r where r.user_id = v_uid);
    select coalesce(r.legal_name, u.full_name), u.email into v_name, v_email from users u left join renters r on r.user_id = u.id where u.id = v_uid;
    v_by := 'sign_in';
  end if;
  for e in select * from jsonb_array_elements(coalesce(p -> 'events', '[]'::jsonb)) loop
    if v_known is null and nullif(e ->> 'm', '') is not null then v_known := app.visitor_from_email_link(e ->> 'm'); end if;
  end loop;
  if v_known is not null and v_renter is null then
    v_renter := nullif(v_known ->> 'renter_id', '')::uuid;
    v_name := coalesce(v_name, (select r.legal_name from renters r where r.id = v_renter), v_known ->> 'name');
    v_email := coalesce(v_email, v_known ->> 'email');
    v_by := coalesce(v_by, 'email_link');
  end if;

  select * into s from visitor_sessions where id = v_sid;
  v_chat := exists (select 1 from chat_conversations c where c.visitor_id = v_vid and c.status <> 'closed');
  -- without consent: only a known customer, or a visitor with a chat open
  v_keep := v_consent = 'analytics' or v_renter is not null or v_uid is not null or v_chat or s.id is not null;
  if not v_keep then
    return jsonb_build_object('ok', true, 'kept', false, 'cfg', app.chat_public_cfg(), 'invite', null);
  end if;

  if s.id is null then
    insert into visitor_sessions (id, visitor_id, user_id, renter_id, known_name, known_email, identified_by, consent, city, region, country, device,
                                  referrer, utm, landing_path, visit_number)
    values (v_sid, v_vid, v_uid, v_renter, v_name, v_email, v_by, v_consent,
            left(nullif(p_geo ->> 'city', ''), 80), left(nullif(p_geo ->> 'region', ''), 80), left(nullif(p_geo ->> 'country', ''), 2),
            case when p ->> 'device' in ('phone', 'tablet', 'desktop') then p ->> 'device' end,
            case when v_consent = 'analytics' then left(nullif(p ->> 'ref', ''), 120) end,
            case when v_consent = 'analytics' and jsonb_typeof(p -> 'utm') = 'object' then
              (select coalesce(jsonb_object_agg(k, left(v, 120)), '{}'::jsonb) from jsonb_each_text(p -> 'utm') x(k, v) where k in ('source', 'medium', 'campaign', 'term', 'content')) else '{}'::jsonb end,
            case when v_consent = 'analytics' then left(p ->> 'landing', 300) end,
            1 + (select count(*) from visitor_sessions o where o.visitor_id = v_vid))
    returning * into s;
    v_new := true;
  else
    update visitor_sessions set last_seen_at = now(), ended_at = null,
           consent = case when v_consent = 'analytics' then 'analytics' else consent end,
           user_id = coalesce(user_id, v_uid), renter_id = coalesce(renter_id, v_renter),
           known_name = coalesce(known_name, v_name), known_email = coalesce(known_email, v_email), identified_by = coalesce(identified_by, v_by)
     where id = v_sid returning * into s;
  end if;
  -- a known visitor: every earlier session of this browser belongs to the same renter
  if s.renter_id is not null then
    update visitor_sessions set renter_id = s.renter_id, known_name = coalesce(known_name, s.known_name), known_email = coalesce(known_email, s.known_email)
     where visitor_id = v_vid and renter_id is null;
    update chat_conversations set renter_id = s.renter_id where visitor_id = v_vid and renter_id is null;
  end if;

  for e in select * from jsonb_array_elements(coalesce(p -> 'events', '[]'::jsonb)) limit 30 loop
    v_kind := e ->> 'k';
    v_path := left(split_part(e ->> 'path', '?', 1), 300);
    v_vehicle := null; v_booking := null; b := null;
    if nullif(e ->> 'slug', '') is not null then
      select l.vehicle_id into v_vehicle from vehicle_listings l where l.slug = left(e ->> 'slug', 120);
    end if;
    if nullif(e ->> 'bn', '') is not null then
      select * into b from bookings where booking_number = left(e ->> 'bn', 30);
      -- only the visitor's own booking (signed in as its renter, or the booking of the email that brought them)
      if b.id is not null and (b.renter_id = s.renter_id or b.id = nullif(v_known ->> 'booking_id', '')::uuid) then v_booking := b.id; end if;
    end if;
    if v_kind = 'page_view' then
      v_kind := case
        when v_path ~ '^/account/bookings/[^/]+/offer' then 'offer_viewed'
        when v_path ~ '^/account/bookings/[^/]+/change' then 'change_viewed'
        when v_path ~ '^/account/bookings/[^/]+/pay' then 'pay_viewed'
        when v_vehicle is not null and v_path ~ '^/(cars|rent)/' then 'car_view'
        when v_path ~ '^/book/sent' then 'request_submitted'
        else 'page_view' end;
    end if;
    if v_kind not in ('page_view', 'page_leave', 'search', 'car_view', 'request_started', 'request_abandoned', 'request_submitted', 'email_link_opened',
                      'offer_viewed', 'change_viewed', 'pay_viewed', 'pay_left', 'chat_opened') then continue; end if;
    v_transactional := v_kind in ('email_link_opened', 'offer_viewed', 'change_viewed', 'pay_viewed', 'pay_left', 'chat_opened');
    -- without analytics consent: the known customer's own booking pages and the chat only
    if s.consent <> 'analytics' and not (v_transactional and (v_booking is not null or v_kind = 'chat_opened' or (v_kind = 'email_link_opened' and v_known is not null))) then continue; end if;
    if v_kind in ('offer_viewed', 'change_viewed', 'pay_viewed', 'pay_left') and v_booking is null then v_kind := 'page_view'; end if;
    if v_kind = 'email_link_opened' and v_booking is null and v_known is not null then
      v_booking := nullif(v_known ->> 'booking_id', '')::uuid;
      select * into b from bookings where id = v_booking;
    end if;
    insert into visitor_events (session_id, kind, path, vehicle_id, booking_id, ms, data)
    values (v_sid, v_kind, v_path, v_vehicle, v_booking,
            case when (e ->> 'ms') ~ '^\d{1,9}$' then least((e ->> 'ms')::integer, 86400000) end,
            jsonb_strip_nulls(jsonb_build_object(
              'pickup', case when (e -> 'd' ->> 'pickup') ~ '^\d{4}-\d{2}-\d{2}' then left(e -> 'd' ->> 'pickup', 16) end,
              'return', case when (e -> 'd' ->> 'return') ~ '^\d{4}-\d{2}-\d{2}' then left(e -> 'd' ->> 'return', 16) end,
              'code', case when v_kind = 'email_link_opened' then v_known ->> 'code' end,
              'booking_number', case when v_booking is not null then b.booking_number end)));
    v_n := v_n + 1;
    if v_kind in ('page_view', 'car_view', 'offer_viewed', 'change_viewed', 'pay_viewed', 'request_submitted') then
      update visitor_sessions set page_views = page_views + 1, current_path = v_path, current_vehicle_id = v_vehicle, current_booking_id = v_booking
       where id = v_sid;
    end if;
    if v_kind = 'car_view' then
      v_seen := v_vehicle = any (coalesce((select cars_viewed from visitor_sessions where id = v_sid), '{}'::uuid[]));
      insert into vehicle_interest_daily as d (vehicle_id, day, views, viewers)
      values (v_vehicle, v_day, 1, 1)
      on conflict (vehicle_id, day) do update set views = d.views + 1, viewers = d.viewers + case when v_seen then 0 else 1 end;
      update visitor_sessions set cars_viewed = case when v_vehicle = any (cars_viewed) then cars_viewed else cars_viewed || v_vehicle end where id = v_sid;
    elsif v_kind = 'request_submitted' and v_vehicle is not null then
      insert into vehicle_interest_daily as d (vehicle_id, day, requests) values (v_vehicle, v_day, 1)
      on conflict (vehicle_id, day) do update set requests = d.requests + 1;
    end if;
  end loop;

  if v_n > 0 or v_new then perform app.visitor_signals_eval(v_sid); end if;

  -- a chat a staff member started for this visitor, not answered yet
  select jsonb_build_object('token', c.token, 'number', c.number,
           'message', (select m.body from chat_messages m where m.conversation_id = c.id and m.sender = 'staff' order by m.id limit 1),
           'from', (select split_part(u.full_name, ' ', 1) from users u where u.id = c.started_by_staff))
    into v_invite
    from chat_conversations c
   where c.session_id = v_sid and c.started_by = 'staff' and c.status <> 'closed' and c.last_visitor_at is null
   order by c.created_at desc limit 1;
  return jsonb_build_object('ok', true, 'kept', true, 'known', s.renter_id is not null, 'events', v_n, 'invite', v_invite, 'cfg', app.chat_public_cfg());
end $$;

-- What the chat button needs to know (no secret): on or off, the greeting.
create or replace function app.chat_public_cfg() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('chat', s.chat_enabled, 'greet_after', s.chat_greeting_seconds, 'greet_text', s.chat_greeting_text)
    from (select (app.settings()).*) s
$$;

-- ================================================================ 5. signals
create or replace function app.visitor_signal_put(p_key text, s visitor_sessions, p_kind text, p_label text, p_booking uuid default null,
                                                  p_vehicle uuid default null, p_times integer default 1) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  insert into visitor_signals as g (dedupe_key, session_id, visitor_id, renter_id, kind, label, booking_id, vehicle_id, times)
  values (p_key, s.id, s.visitor_id, s.renter_id, p_kind, p_label, p_booking, p_vehicle, p_times)
  on conflict (dedupe_key) do update set label = excluded.label, times = greatest(g.times, excluded.times), last_at = now(),
    session_id = excluded.session_id, renter_id = coalesce(g.renter_id, excluded.renter_id), resolved_at = null
  where g.label is distinct from excluded.label or g.times < excluded.times or g.resolved_at is not null or g.last_at < now() - interval '1 minute';
end $$;

-- The signals of one session, from its events and the visitor's other sessions.
create or replace function app.visitor_signals_eval(p_session uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings();
  s visitor_sessions;
  r record;
  v_n integer;
begin
  select * into s from visitor_sessions where id = p_session;
  if s.id is null then return; end if;
  -- viewing spree: N different cars within M minutes
  select count(distinct vehicle_id) into v_n from visitor_events
   where session_id = s.id and kind = 'car_view' and at > now() - make_interval(mins => ps.visitor_spree_minutes);
  if v_n >= ps.visitor_spree_cars then
    perform app.visitor_signal_put('spree:' || s.id, s, 'viewing_spree', format('Viewing spree: %s cars in %s minutes', v_n, ps.visitor_spree_minutes), null, null, v_n);
  end if;
  -- an offer opened (page or email link) and not answered
  for r in select e.booking_id, count(*) as n from visitor_events e join visitor_sessions o on o.id = e.session_id
            where (o.visitor_id = s.visitor_id or o.renter_id = s.renter_id) and e.kind in ('offer_viewed', 'email_link_opened') and e.booking_id is not null
              and (e.kind = 'offer_viewed' or e.data ->> 'code' ~ 'offer')
            group by e.booking_id loop
    if exists (select 1 from bookings b where b.id = r.booking_id and b.status = 'offered') then
      perform app.visitor_signal_put('offer:' || r.booking_id || ':' || coalesce((select max(v.version) from booking_offers v where v.booking_id = r.booking_id), 0),
        s, 'offer_opened', format('Opened offer %s%s, not answered', (select booking_number from bookings where id = r.booking_id),
          case when r.n > 1 then format(' (%s times)', r.n) else '' end), r.booking_id, null, r.n::integer);
    end if;
  end loop;
  -- the change proposal opened N times without an answer
  for r in select e.booking_id, count(*) as n from visitor_events e join visitor_sessions o on o.id = e.session_id
            where (o.visitor_id = s.visitor_id or o.renter_id = s.renter_id) and e.kind = 'change_viewed' and e.booking_id is not null group by e.booking_id loop
    if r.n >= ps.visitor_proposal_opens and exists (select 1 from booking_change_requests c where c.booking_id = r.booking_id and c.status = 'proposed') then
      perform app.visitor_signal_put('proposal:' || r.booking_id || ':' || (select c.id from booking_change_requests c where c.booking_id = r.booking_id and c.status = 'proposed' limit 1),
        s, 'proposal_opened', format('Opened the change proposal %s', case r.n when 2 then 'twice' else r.n || ' times' end), r.booking_id, null, r.n::integer);
    end if;
  end loop;
  -- left the pay page without paying
  for r in select distinct e.booking_id from visitor_events e where e.session_id = s.id and e.kind = 'pay_left' and e.booking_id is not null loop
    if exists (select 1 from bookings b where b.id = r.booking_id and b.status = 'pending_payment') then
      perform app.visitor_signal_put('pay:' || r.booking_id, s, 'pay_left', format('Left the pay page (%s)', (select booking_number from bookings where id = r.booking_id)), r.booking_id);
    end if;
  end loop;
  -- returning visitor: N visits in 7 days
  select count(*) into v_n from visitor_sessions o where o.visitor_id = s.visitor_id and o.started_at > now() - interval '7 days';
  if v_n >= ps.visitor_returning_visits then
    perform app.visitor_signal_put('return:' || s.visitor_id || ':' || app.local_date(now()), s, 'returning', format('Returning visitor, %s visit this week', app.ordinal(v_n)), null, null, v_n);
  end if;
  -- started a booking request and stopped
  for r in select e.vehicle_id, max(e.at) as at from visitor_events e where e.session_id = s.id and e.kind in ('request_started', 'request_abandoned') group by e.vehicle_id loop
    if not exists (select 1 from visitor_events x where x.session_id = s.id and x.kind = 'request_submitted' and x.at > r.at - interval '1 second')
       and (exists (select 1 from visitor_events x where x.session_id = s.id and x.kind = 'request_abandoned' and x.vehicle_id is not distinct from r.vehicle_id)
            or r.at < now() - interval '10 minutes') then
      perform app.visitor_signal_put('request:' || s.id || ':' || coalesce(r.vehicle_id::text, '-'), s, 'request_stopped',
        'Started a request and stopped' || coalesce(' (' || app.vehicle_name(r.vehicle_id) || ')', ''), null, r.vehicle_id);
    end if;
  end loop;
  -- signals whose moment passed are resolved: the offer answered, the payment made, the proposal answered, the request sent
  update visitor_signals g set resolved_at = now()
   where g.visitor_id = s.visitor_id and g.resolved_at is null and (
         (g.kind = 'offer_opened' and not exists (select 1 from bookings b where b.id = g.booking_id and b.status = 'offered'))
      or (g.kind = 'pay_left' and not exists (select 1 from bookings b where b.id = g.booking_id and b.status = 'pending_payment'))
      or (g.kind = 'proposal_opened' and not exists (select 1 from booking_change_requests c where c.booking_id = g.booking_id and c.status = 'proposed'))
      or (g.kind = 'request_stopped' and exists (select 1 from visitor_events x where x.session_id = g.session_id and x.kind = 'request_submitted' and x.at > g.first_at)));
end $$;

-- Is a signal still current (shown on the Live page)?
create or replace function app.visitor_signals_json(p_visitor uuid, p_session uuid default null) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('kind', g.kind, 'label', g.label, 'at', g.last_at, 'booking_number', b.booking_number, 'task_id', g.task_id)
                  order by g.last_at desc), '[]'::jsonb)
    from visitor_signals g left join bookings b on b.id = g.booking_id
   where g.visitor_id = p_visitor and g.resolved_at is null and g.last_at > now() - interval '7 days'
     and (g.kind not in ('viewing_spree', 'request_stopped') or g.session_id = p_session or p_session is null)
$$;

-- ================================================================ 6. follow-up tasks (pg_cron, every 15 minutes)
create or replace function app.job_visitor_followups(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  x record;
  v_task uuid;
  v_title text;
  v_queue text;
  v_n integer := 0;
  v_contact text;
begin
  -- the signals' moments are re-checked first (an answered offer, a payment)
  update visitor_signals g set resolved_at = p_now
   where g.resolved_at is null and (
         (g.kind = 'offer_opened' and not exists (select 1 from bookings b where b.id = g.booking_id and b.status = 'offered'))
      or (g.kind = 'pay_left' and not exists (select 1 from bookings b where b.id = g.booking_id and b.status = 'pending_payment'))
      or (g.kind = 'proposal_opened' and not exists (select 1 from booking_change_requests c where c.booking_id = g.booking_id and c.status = 'proposed')));
  -- a follow-up whose reason passed closes by itself
  update tasks t set status = 'done', completed_at = p_now, completion_note = 'Closed by itself: the visitor answered, paid or the signal passed'
    from visitor_signals g
   where g.task_id = t.id and g.resolved_at is not null and t.status in ('open', 'in_progress', 'waiting') and t.task_type = 'visitor_follow_up';
  if not ps.visitor_followup_tasks then return 'off'; end if;
  for x in select vs.*, s.known_name, s.known_email, b.booking_number, b.sales_staff_id, r.legal_name, r.mobile, r.email as renter_email
             from visitor_signals vs
             left join visitor_sessions s on s.id = vs.session_id
             left join bookings b on b.id = vs.booking_id
             left join renters r on r.id = vs.renter_id
            where vs.resolved_at is null and vs.task_id is null and vs.kind <> 'returning'
              and (vs.renter_id is not null or s.known_email is not null) loop
    v_contact := coalesce(x.legal_name, x.known_name, x.known_email, 'the visitor');
    v_title := null; v_queue := 'cs';
    if x.kind = 'offer_opened' and x.first_at <= p_now - make_interval(hours => ps.visitor_offer_no_answer_hours) then
      v_title := format('Call or message %s: opened offer %s %s, no answer for %s hours', v_contact, x.booking_number,
                        case when x.times > 1 then case x.times when 2 then 'twice' else x.times || ' times' end else 'once' end,
                        floor(extract(epoch from p_now - x.first_at) / 3600)::integer);
      v_queue := case when x.sales_staff_id is not null and app.user_va_has(x.sales_staff_id, 'sales') then 'sales' else 'cs' end;
    elsif x.kind = 'pay_left' and x.last_at <= p_now - make_interval(mins => ps.visitor_pay_left_minutes) then
      v_title := format('Call or message %s: left the pay page for %s without paying', v_contact, x.booking_number);
    elsif x.kind = 'proposal_opened' then
      v_title := format('Call or message %s: opened the change proposal for %s %s times, no answer yet', v_contact, x.booking_number, x.times);
    elsif x.kind = 'request_stopped' and x.last_at <= p_now - make_interval(mins => ps.visitor_request_stopped_minutes) then
      v_title := format('Call or message %s: started a booking request%s and stopped', v_contact, coalesce(' for the ' || app.vehicle_name(x.vehicle_id), ''));
      v_queue := 'sales';
    elsif x.kind = 'viewing_spree' then
      v_title := format('Reach out to %s: %s', v_contact, lower(left(x.label, 1)) || substr(x.label, 2));
      v_queue := 'sales';
    end if;
    if v_title is null then continue; end if;
    v_task := app.raise_task(p_type => 'visitor_follow_up', p_title => left(v_title, 200),
      p_detail => format('Signal on Live visitors: %s. Contact: %s%s. Mark the task done when you reached them; it closes by itself when they answer or pay.',
                         x.label, coalesce(x.mobile, 'no phone'), coalesce(', ' || coalesce(x.renter_email, x.known_email), '')),
      p_booking => x.booking_id, p_vehicle => x.vehicle_id, p_renter => x.renter_id, p_queue => v_queue,
      p_related_table => 'visitor_signals', p_related_id => x.id, p_dedupe => 'visitor:' || x.dedupe_key);
    update visitor_signals set task_id = v_task where id = x.id;
    v_n := v_n + 1;
  end loop;
  return 'raised ' || v_n;
end $$;

-- ================================================================ 7. housekeeping (daily)
create or replace function app.job_visitor_housekeeping(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  v_e integer; v_s integer; v_c integer;
begin
  delete from visitor_events where at < p_now - make_interval(days => ps.visitor_events_keep_days);
  get diagnostics v_e = row_count;
  delete from visitor_signals where last_at < p_now - make_interval(days => ps.visitor_events_keep_days);
  delete from chat_conversations c where c.renter_id is null and c.booking_id is null
     and coalesce(c.closed_at, c.last_message_at) < p_now - make_interval(days => ps.chat_keep_days);
  get diagnostics v_c = row_count;
  delete from visitor_sessions s where s.last_seen_at < p_now - make_interval(days => ps.visitor_events_keep_days)
     and not exists (select 1 from chat_conversations c where c.session_id = s.id);
  get diagnostics v_s = row_count;
  -- closed after an hour without a word: the chat is over
  update chat_conversations set status = 'closed', closed_at = p_now
   where status in ('ai') and last_message_at < p_now - interval '12 hours';
  return format('events %s, sessions %s, chats %s', v_e, v_s, v_c);
end $$;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-visitor-followups', '*/15 * * * *', 'select app.job_visitor_followups()');
    perform cron.schedule('carmacars-visitor-housekeeping', '23 8 * * *', 'select app.job_visitor_housekeeping()');
  end if;
end $$;

-- ================================================================ 8. reads for staff
create or replace function app.visitor_session_row(s visitor_sessions) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', s.id, 'visitor_id', s.visitor_id, 'who', app.visitor_who(s), 'known', s.renter_id is not null or s.known_email is not null,
    'renter_id', s.renter_id, 'email', s.known_email, 'identified_by', s.identified_by, 'consent', s.consent,
    'city', s.city, 'region', s.region, 'device', s.device, 'referrer', s.referrer, 'utm_source', s.utm ->> 'source', 'utm_campaign', s.utm ->> 'campaign',
    'started_at', s.started_at, 'last_seen_at', s.last_seen_at, 'page_views', s.page_views, 'visit_number', s.visit_number,
    'current_path', s.current_path, 'current_page', app.path_label(s.current_path),
    'car', case when s.current_vehicle_id is not null then app.vehicle_name(s.current_vehicle_id) end, 'vehicle_id', s.current_vehicle_id,
    'booking_number', (select b.booking_number from bookings b where b.id = s.current_booking_id),
    'cars_viewed', cardinality(s.cars_viewed),
    'signals', app.visitor_signals_json(s.visitor_id, s.id),
    'chat', (select jsonb_build_object('id', c.id, 'number', c.number, 'status', c.status) from chat_conversations c
              where c.visitor_id = s.visitor_id and c.status <> 'closed' order by c.created_at desc limit 1))
$$;

create or replace function app.live_visitors(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings();
  v_day date := app.local_date(now());
begin
  perform app.assert_live_staff(p_by);
  return jsonb_build_object(
    'live_minutes', ps.visitor_live_minutes, 'tracking', ps.visitor_tracking_enabled, 'at', now(),
    'now', coalesce((select jsonb_agg(app.visitor_session_row(s) order by (s.renter_id is not null) desc, s.last_seen_at desc)
                       from visitor_sessions s where s.last_seen_at > now() - make_interval(mins => ps.visitor_live_minutes) and s.ended_at is null), '[]'::jsonb),
    'signals', coalesce((select jsonb_agg(x order by x ->> 'at' desc) from (
                  select jsonb_build_object('kind', g.kind, 'label', g.label, 'at', g.last_at, 'who',
                           coalesce((select app.visitor_who(s) from visitor_sessions s where s.id = g.session_id), 'Visitor'),
                           'session_id', g.session_id, 'renter_id', g.renter_id, 'booking_number', b.booking_number, 'task_id', g.task_id) as x
                    from visitor_signals g left join bookings b on b.id = g.booking_id
                   where g.resolved_at is null and g.last_at > now() - interval '24 hours' order by g.last_at desc limit 30) y), '[]'::jsonb),
    'most_viewed', app.most_viewed_cars(7, 8),
    'today', jsonb_build_object(
      'sessions', (select count(*) from visitor_sessions s where s.started_at >= app.local_midnight(v_day)),
      'known', (select count(*) from visitor_sessions s where s.started_at >= app.local_midnight(v_day) and s.renter_id is not null),
      'chats', (select count(*) from chat_conversations c where c.created_at >= app.local_midnight(v_day))));
end $$;

create or replace function app.most_viewed_cars(p_days integer default 7, p_limit integer default 8) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(x order by (x ->> 'views_7d')::integer desc), '[]'::jsonb) from (
    select jsonb_build_object('vehicle_id', d.vehicle_id, 'car', app.vehicle_name(d.vehicle_id),
             'views_today', coalesce(sum(d.views) filter (where d.day = app.local_date(now())), 0),
             'views_7d', sum(d.views), 'viewers_7d', sum(d.viewers), 'requests_7d', sum(d.requests),
             'looking_now', (select count(*) from visitor_sessions s where s.current_vehicle_id = d.vehicle_id
                              and s.last_seen_at > now() - make_interval(mins => (app.settings()).visitor_live_minutes) and s.ended_at is null)) as x
      from vehicle_interest_daily d where d.day > app.local_date(now()) - p_days
     group by d.vehicle_id order by sum(d.views) desc limit p_limit) y
$$;

create or replace function app.vehicle_interest(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v uuid := (p ->> 'vehicle_id')::uuid;
  v_day date := app.local_date(now());
  v_viewers30 bigint;
  v_req30 bigint;
begin
  perform app.assert_live_staff(p_by);
  select coalesce(sum(viewers), 0), coalesce(sum(requests), 0) into v_viewers30, v_req30 from vehicle_interest_daily where vehicle_id = v and day > v_day - 30;
  return jsonb_build_object(
    'views_today', (select coalesce(sum(views), 0) from vehicle_interest_daily where vehicle_id = v and day = v_day),
    'views_7d', (select coalesce(sum(views), 0) from vehicle_interest_daily where vehicle_id = v and day > v_day - 7),
    'viewers_7d', (select coalesce(sum(viewers), 0) from vehicle_interest_daily where vehicle_id = v and day > v_day - 7),
    'requests_30d', v_req30, 'viewers_30d', v_viewers30,
    'bookings_30d', (select count(*) from bookings b where b.vehicle_id = v and b.booked_at > now() - interval '30 days' and b.booking_type <> 'owner'),
    'conversion_bps', case when v_viewers30 > 0 then round(10000.0 * v_req30 / v_viewers30)::integer end,
    'looking_now', (select count(*) from visitor_sessions s where s.current_vehicle_id = v and s.last_seen_at > now() - make_interval(mins => (app.settings()).visitor_live_minutes) and s.ended_at is null),
    'days', coalesce((select jsonb_agg(jsonb_build_object('day', d, 'views', coalesce(x.views, 0)) order by d)
                        from generate_series(v_day - 13, v_day, interval '1 day') d
                        left join vehicle_interest_daily x on x.vehicle_id = v and x.day = d::date), '[]'::jsonb));
end $$;

-- One session in full: its pages and events, the visitor's other visits and chats.
create or replace function app.live_session(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s visitor_sessions;
begin
  perform app.assert_live_staff(p_by);
  select * into s from visitor_sessions where id = (p ->> 'id')::uuid;
  if s.id is null then raise exception 'That visit is no longer kept' using errcode = 'P0002'; end if;
  return app.visitor_session_row(s) || jsonb_build_object(
    'events', coalesce((select jsonb_agg(jsonb_build_object('at', e.at, 'kind', e.kind, 'path', e.path, 'page', app.path_label(e.path),
                          'car', case when e.vehicle_id is not null then app.vehicle_name(e.vehicle_id) end, 'booking_number', e.data ->> 'booking_number',
                          'ms', e.ms, 'pickup', e.data ->> 'pickup', 'return', e.data ->> 'return') order by e.at desc)
                         from (select * from visitor_events where session_id = s.id order by at desc limit 60) e), '[]'::jsonb),
    'visits', (select count(*) from visitor_sessions o where o.visitor_id = s.visitor_id),
    'visits_7d', (select count(*) from visitor_sessions o where o.visitor_id = s.visitor_id and o.started_at > now() - interval '7 days'));
end $$;

-- The timeline of a renter (or of a booking's renter): what they looked at on the site and their chats.
create or replace function app.visitor_timeline(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_renter uuid := nullif(p ->> 'renter_id', '')::uuid;
  v_booking uuid := nullif(p ->> 'booking_id', '')::uuid;
begin
  if not (app.live_staff_ok(p_by) or app.user_is_staff(p_by)) then raise exception 'Staff only' using errcode = '42501'; end if;
  if v_booking is not null then select renter_id into v_renter from bookings where id = v_booking; end if;
  return jsonb_build_object(
    'events', coalesce((select jsonb_agg(x order by x ->> 'at' desc) from (
        select jsonb_build_object('at', e.at, 'kind', e.kind, 'page', app.path_label(e.path), 'path', e.path,
                 'car', case when e.vehicle_id is not null then app.vehicle_name(e.vehicle_id) end, 'booking_number', e.data ->> 'booking_number',
                 'ms', e.ms) as x
          from visitor_events e join visitor_sessions s on s.id = e.session_id
         where s.renter_id = v_renter and (v_booking is null or e.booking_id = v_booking or e.kind in ('car_view', 'search', 'chat_opened'))
           and e.kind <> 'page_leave'
         order by e.at desc limit 80) y), '[]'::jsonb),
    'chats', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'number', c.number, 'status', c.status, 'at', c.created_at,
                         'messages', (select count(*) from chat_messages m where m.conversation_id = c.id)) order by c.created_at desc)
                         from chat_conversations c where c.renter_id = v_renter), '[]'::jsonb),
    'visits', (select count(*) from visitor_sessions s where s.renter_id = v_renter),
    'last_seen_at', (select max(s.last_seen_at) from visitor_sessions s where s.renter_id = v_renter),
    'signals', coalesce((select jsonb_agg(jsonb_build_object('label', g.label, 'at', g.last_at) order by g.last_at desc)
                          from visitor_signals g where g.renter_id = v_renter and g.resolved_at is null), '[]'::jsonb));
end $$;

-- An Admin's renter page (People > Renters > a renter): the record, the bookings and the timeline.
create or replace function app.renter_live(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r renters;
begin
  perform app.assert_admin(p_by);
  select * into r from renters where id = (p ->> 'renter_id')::uuid;
  if r.id is null then raise exception 'Renter not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('id', r.id, 'name', r.legal_name, 'email', r.email, 'mobile', r.mobile, 'identity_status', r.identity_status, 'created_at', r.created_at,
    'city', r.city, 'is_blocked', coalesce((to_jsonb(r) ->> 'is_blocked')::boolean, false),
    'bookings', coalesce((select jsonb_agg(jsonb_build_object('number', b.booking_number, 'status', b.status, 'pickup_at', b.pickup_at, 'return_at', b.return_at,
                   'car', app.vehicle_name(b.vehicle_id)) order by b.pickup_at desc) from bookings b where b.renter_id = r.id), '[]'::jsonb),
    'timeline', app.visitor_timeline(p_by, jsonb_build_object('renter_id', r.id)));
end $$;

-- Follow-ups for My sales: tasks of the visitor signals done by the person, and the bookings confirmed after them.
create or replace function app.visitor_followups_figures(p_staff uuid, p jsonb default '{}'::jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with t as (
    select * from tasks where task_type in ('visitor_follow_up', 'live_chat_waiting', 'chat_request', 'chat_contact') and completed_by = p_staff and status = 'done'
       and completed_at >= case when p ->> 'period' = 'month' then app.local_midnight(date_trunc('month', app.local_date(now()))::date)
                                else app.local_midnight(app.local_date(now()) - ((extract(isodow from app.local_date(now()))::integer) - 1)) end)
  select jsonb_build_object(
    'done', (select count(*) from t),
    'open', (select count(*) from tasks x where x.task_type in ('visitor_follow_up', 'live_chat_waiting', 'chat_request', 'chat_contact')
               and x.status in ('open', 'in_progress', 'waiting') and (x.assigned_to = p_staff or (x.assigned_to is null and app.user_works_queue(p_staff, x.queue)))),
    'booked', (select count(distinct b.id) from t join bookings b on b.id = t.booking_id
                where b.confirmed_at is not null and b.confirmed_at >= t.completed_at),
    'chats_handled', (select count(*) from chat_conversations c where c.assigned_to = p_staff and c.first_human_reply_at is not null
       and c.first_human_reply_at >= case when p ->> 'period' = 'month' then app.local_midnight(date_trunc('month', app.local_date(now()))::date)
                                else app.local_midnight(app.local_date(now()) - ((extract(isodow from app.local_date(now()))::integer) - 1)) end))
$$;

-- ================================================================ 9. chat, the visitor's side
-- The staff member's first name, or "CarmaCars" for the assistant: what the visitor reads beside each message.
create or replace function app.chat_messages_json(p_conv uuid, p_after bigint, p_staff boolean) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'at', m.at, 'sender', m.sender, 'body', m.body,
           'name', case m.sender when 'staff' then coalesce((select split_part(u.full_name, ' ', 1) from users u where u.id = m.staff_id), 'CarmaCars')
                                 when 'ai' then 'CarmaCars assistant' when 'system' then 'CarmaCars' else null end)
           || case when p_staff then jsonb_build_object('meta', m.meta, 'staff_name', (select u.full_name from users u where u.id = m.staff_id)) else '{}'::jsonb end
           order by m.id), '[]'::jsonb)
    from (select * from chat_messages where conversation_id = p_conv and id > coalesce(p_after, 0) order by id limit 200) m
$$;

create or replace function app.chat_on_shift() returns integer
language sql stable security definer set search_path = public, app as $$
  select count(*)::integer from chat_staff_prefs p
   where p.last_seen_at > now() - make_interval(mins => (app.settings()).chat_shift_minutes) and app.live_staff_ok(p.user_id)
$$;

-- The visitor polls their conversation by its secret (directly from the browser: no Worker).
create or replace function app.chat_poll(p_token text, p_after bigint default 0) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c chat_conversations;
  v_max bigint;
begin
  select * into c from chat_conversations where token = p_token;
  if c.id is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  select max(id) into v_max from chat_messages where conversation_id = c.id;
  if coalesce(v_max, 0) > c.visitor_read_id then update chat_conversations set visitor_read_id = v_max where id = c.id; end if;
  return jsonb_build_object('ok', true, 'number', c.number, 'status', c.status, 'offline', c.offline,
    'staff_typing', coalesce(c.staff_typing_at > now() - interval '6 seconds', false),
    'has_contact', c.email is not null or c.phone is not null,
    'agent', case when c.status = 'human' then (select split_part(u.full_name, ' ', 1) from users u where u.id = c.assigned_to) end,
    'messages', app.chat_messages_json(c.id, p_after, false));
end $$;

create or replace function app.chat_typing(p_token text) returns boolean
language sql security definer set search_path = public, app as $$
  update chat_conversations set visitor_typing_at = now() where token = p_token and status <> 'closed' returning true
$$;

-- The server (the app's /api/chat, after its own checks): open or continue the visitor's conversation.
create or replace function app.server_chat_open(p jsonb, p_user uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings();
  c chat_conversations;
  v_vid uuid := case when p ->> 'vid' ~ '^[0-9a-f-]{36}$' then (p ->> 'vid')::uuid end;
  v_sid uuid := case when p ->> 'sid' ~ '^[0-9a-f-]{36}$' then (p ->> 'sid')::uuid end;
  v_vehicle uuid;
  v_renter uuid;
begin
  if not ps.chat_enabled then return jsonb_build_object('ok', false, 'error', 'off'); end if;
  if v_vid is null then return jsonb_build_object('ok', false, 'error', 'bad ids'); end if;
  if nullif(p ->> 'token', '') is not null then
    select * into c from chat_conversations where token = p ->> 'token' and status <> 'closed';
  end if;
  if c.id is null then
    select * into c from chat_conversations where visitor_id = v_vid and status <> 'closed' order by created_at desc limit 1;
  end if;
  if c.id is null then
    if not app.rate_limit('chat-open:' || v_vid, 6, interval '1 hour') then return jsonb_build_object('ok', false, 'error', 'limited'); end if;
    select l.vehicle_id into v_vehicle from vehicle_listings l where l.slug = nullif(left(p ->> 'slug', 120), '');
    v_renter := (select r.id from renters r where r.user_id = p_user);
    -- the session may not be recorded yet (no analytics consent): the chat keeps one essential row
    if v_sid is not null and not exists (select 1 from visitor_sessions where id = v_sid) then
      insert into visitor_sessions (id, visitor_id, user_id, renter_id, consent, device, city, region, country)
      values (v_sid, v_vid, p_user, v_renter, 'essential', case when p ->> 'device' in ('phone', 'tablet', 'desktop') then p ->> 'device' end,
              left(nullif(p ->> 'city', ''), 80), left(nullif(p ->> 'region', ''), 80), left(nullif(p ->> 'country', ''), 2))
      on conflict (id) do nothing;
    end if;
    insert into chat_conversations (session_id, visitor_id, user_id, renter_id, name, email, page, vehicle_id, started_by, status)
    values (v_sid, v_vid, p_user, coalesce(v_renter, (select s.renter_id from visitor_sessions s where s.id = v_sid)),
            coalesce((select r.legal_name from renters r where r.id = v_renter), (select u.full_name from users u where u.id = p_user)),
            (select u.email from users u where u.id = p_user),
            left(p ->> 'page', 300), v_vehicle, case when p ->> 'greeting' = 'true' then 'greeting' else 'visitor' end,
            case when ps.chat_ai_enabled then 'ai' else 'waiting' end)
    returning * into c;
    if v_sid is not null then
      insert into visitor_events (session_id, kind, path, vehicle_id) select v_sid, 'chat_opened', left(p ->> 'page', 300), v_vehicle
       where exists (select 1 from visitor_sessions where id = v_sid);
    end if;
    if p ->> 'greeting' = 'true' then
      insert into chat_messages (conversation_id, sender, body, meta) values (c.id, 'ai', ps.chat_greeting_text, '{"greeting": true}');
    end if;
  elsif v_sid is not null and c.session_id is distinct from v_sid and exists (select 1 from visitor_sessions where id = v_sid) then
    update chat_conversations set session_id = v_sid where id = c.id returning * into c;
  end if;
  return jsonb_build_object('ok', true, 'token', c.token, 'number', c.number, 'status', c.status,
    'name', c.name, 'has_contact', c.email is not null or c.phone is not null, 'on_shift', app.chat_on_shift() > 0,
    'messages', app.chat_messages_json(c.id, 0, false));
end $$;

create or replace function app.chat_budget() returns jsonb
language sql stable security definer set search_path = public, app as $$
  with day as (select app.local_midnight(app.local_date(now())) as t0)
  select jsonb_build_object(
    'chat_neurons', (select coalesce(sum(c.units), 0) from provider_calls c, day where c.unit = 'neurons' and c.purpose = 'chat' and c.created_at >= day.t0),
    'all_neurons', (select coalesce(sum(c.units), 0) from provider_calls c, day where c.unit = 'neurons' and c.created_at >= day.t0),
    'chat_cap', s.chat_ai_daily_neurons, 'all_cap', s.chat_ai_total_daily_neurons, 'ai_enabled', s.chat_ai_enabled, 'model', s.chat_ai_model,
    'max_replies', s.chat_ai_max_replies,
    'ok', s.chat_ai_enabled
          and (select coalesce(sum(c.units), 0) from provider_calls c, day where c.unit = 'neurons' and c.purpose = 'chat' and c.created_at >= day.t0) < s.chat_ai_daily_neurons
          and (select coalesce(sum(c.units), 0) from provider_calls c, day where c.unit = 'neurons' and c.created_at >= day.t0) < s.chat_ai_total_daily_neurons)
    from (select (app.settings()).*) s
$$;

-- The facts the assistant answers from: the fleet with its rates from the database, the rules of the site, the
-- day in Toronto, and the names it must never say (the insurers). Read by the app, cached a few minutes.
create or replace function app.server_chat_facts() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'today', app.local_date(now()), 'weekday', to_char(app.local_date(now()), 'FMDay'),
    'site', (select jsonb_build_object('brand', s ->> 'brand_name', 'city', s ->> 'city', 'phone', s ->> 'phone', 'email', s ->> 'email',
              'hours', s ->> 'opening_hours_text', 'reply', s ->> 'reply_wording', 'service_area', s ->> 'service_area', 'delivery_area', s ->> 'delivery_area_text')
              from (select public.site_settings_public() as s) x),
    'rules', (select jsonb_build_object('min_age', f -> 'min_renter_age', 'standard_min_age', f -> 'standard_min_age', 'max_days', f -> 'max_rental_days',
              'licences', f -> 'accepted_licence_classes', 'notice_minutes', f -> 'booking_min_notice_minutes', 'offer_hours', f -> 'offer_expiry_hours',
              'cancellation', f -> 'cancellation', 'non_refundable_discount_bps', f -> 'non_refundable_discount_bps', 'deposit_release_days', f -> 'deposit_release_business_days',
              'airports', f -> 'airports', 'max_additional_drivers', f -> 'max_additional_drivers', 'hst_bps', f -> 'hst_bps',
              'fees', (select jsonb_object_agg(k, jsonb_strip_nulls(jsonb_build_object('label', v ->> 'label', 'unit', v ->> 'unit', 'amount_cents', v -> 'amount_cents', 'cap_cents', v -> 'cap_cents')))
                         from jsonb_each(f -> 'fees') x(k, v) where (v ->> 'amount_cents') is not null and k in ('cleaning', 'smoking', 'pet_cleaning', 'baby_seat', 'winter_tire', 'lost_key_fee', 'late_return', 'additional_driver')))
              from (select public.site_facts() as f) x),
    'fleet', (select coalesce(jsonb_agg(jsonb_build_object('slug', c ->> 'slug', 'name', concat_ws(' ', c ->> 'year', c ->> 'make', c ->> 'model', c ->> 'trim'),
                'class', c ->> 'class', 'seats', c -> 'seats', 'transmission', c ->> 'transmission', 'fuel', c ->> 'fuel', 'area', c ->> 'home_area',
                'daily_rate_cents', c -> 'daily_rate_cents', 'weekly_rate_cents', c -> 'weekly_rate_cents', 'deposit_cents', c -> 'deposit_cents',
                'km_per_day', c -> 'km_allowance_per_day', 'young_18_20', c -> 'allows_18_to_20', 'vehicle_id', c ->> 'vehicle_id', 'taking_requests', c -> 'taking_requests')), '[]'::jsonb)
              from public.fleet('{}'::jsonb) as c),
    'never_say', coalesce((select jsonb_agg(distinct i.name) from insurers i where i.name is not null), '[]'::jsonb),
    'budget', app.chat_budget())
$$;

-- A visitor's message. The answer says whether the assistant should reply and gives it the conversation so far.
create or replace function app.server_chat_visitor_message(p_token text, p_body text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c chat_conversations;
  v_id bigint;
  v_budget jsonb := app.chat_budget();
begin
  select * into c from chat_conversations where token = p_token for update;
  if c.id is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if c.status = 'closed' then return jsonb_build_object('ok', false, 'error', 'closed'); end if;
  p_body := left(btrim(coalesce(p_body, '')), 2000);
  if p_body = '' then return jsonb_build_object('ok', false, 'error', 'empty'); end if;
  if not app.rate_limit('chat-msg:' || c.id, 20, interval '1 minute') then return jsonb_build_object('ok', false, 'error', 'limited'); end if;
  insert into chat_messages (conversation_id, sender, body) values (c.id, 'visitor', p_body) returning id into v_id;
  update chat_conversations set last_message_at = now(), last_visitor_at = now(), visitor_typing_at = null,
         visitor_read_id = greatest(visitor_read_id, v_id) where id = c.id returning * into c;
  return jsonb_build_object('ok', true, 'id', v_id, 'status', c.status, 'number', c.number,
    'ai', c.status = 'ai' and (v_budget ->> 'ok')::boolean and c.ai_replies < (v_budget ->> 'max_replies')::integer,
    'ai_reason', case when c.status <> 'ai' then 'person' when not (v_budget ->> 'ok')::boolean then 'budget' when c.ai_replies >= (v_budget ->> 'max_replies')::integer then 'max_replies' end,
    'model', v_budget ->> 'model', 'name', c.name, 'email', c.email, 'phone', c.phone, 'page', c.page,
    'car', (select l.slug from vehicle_listings l where l.vehicle_id = c.vehicle_id),
    'history', coalesce((select jsonb_agg(jsonb_build_object('sender', m.sender, 'body', m.body, 'meta', m.meta) order by m.id)
                           from (select * from chat_messages where conversation_id = c.id and sender <> 'system' order by id desc limit 14) m), '[]'::jsonb));
end $$;

-- The assistant's reply, with what it used (the quotes it read, the tools, its neurons).
create or replace function app.server_chat_ai_reply(p_token text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c chat_conversations;
  v_id bigint;
  v_neurons integer := greatest(coalesce((p ->> 'neurons')::integer, 0), 0);
begin
  select * into c from chat_conversations where token = p_token for update;
  if c.id is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if v_neurons > 0 or (p ->> 'model') is not null then
    insert into provider_calls (provider, purpose, ok, error, duration_ms, units, unit)
    values ('workers-ai', 'chat', coalesce((p ->> 'ok')::boolean, true), left(p ->> 'error', 300), nullif(p ->> 'duration_ms', '')::integer, v_neurons, 'neurons');
  end if;
  -- a person took the conversation while the assistant was thinking: the reply is dropped
  if c.status <> 'ai' or nullif(p ->> 'body', '') is null then
    update chat_conversations set ai_neurons = ai_neurons + v_neurons where id = c.id;
    return jsonb_build_object('ok', true, 'dropped', true, 'status', c.status);
  end if;
  insert into chat_messages (conversation_id, sender, body, meta) values (c.id, 'ai', left(p ->> 'body', 4000), coalesce(p -> 'meta', '{}'::jsonb)) returning id into v_id;
  update chat_conversations set last_message_at = now(), ai_replies = ai_replies + 1, ai_neurons = ai_neurons + v_neurons,
         vehicle_id = coalesce((select l.vehicle_id from vehicle_listings l where l.slug = p ->> 'car'), vehicle_id)
   where id = c.id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- A person is needed: the visitor asked, the assistant could not answer safely, a complaint, damage, an accident,
-- a payment, or the day's AI allowance is used. A task for customer service with the first reply target, the email
-- to the staff on shift who asked for it; nobody on shift: the chat asks for contact details.
create or replace function app.server_chat_handoff(p_token text, p_reason text, p_message text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c chat_conversations;
  v_online integer := app.chat_on_shift();
  v_task uuid;
begin
  select * into c from chat_conversations where token = p_token for update;
  if c.id is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if c.status in ('waiting', 'human') then
    return jsonb_build_object('ok', true, 'status', c.status, 'on_shift', v_online > 0, 'offline', c.offline, 'has_contact', c.email is not null or c.phone is not null);
  end if;
  v_task := app.raise_task(p_type => 'live_chat_waiting', p_due_at => app.task_due('first_reply', null),
    p_title => left(format('Live chat %s: %s asked for a person', c.number, app.visitor_chat_name(c)), 200),
    p_detail => format('Reason: %s. Open Live chat to reply.', coalesce(nullif(p_reason, ''), 'asked for a person')),
    p_renter => c.renter_id, p_vehicle => c.vehicle_id, p_related_table => 'chat_conversations', p_related_id => c.id, p_dedupe => 'chat:' || c.id);
  update chat_conversations set status = 'waiting', human_requested_at = coalesce(human_requested_at, now()), human_reason = left(coalesce(p_reason, 'asked for a person'), 300),
         task_id = v_task, offline = v_online = 0, last_message_at = now()
   where id = c.id returning * into c;
  insert into chat_messages (conversation_id, sender, body, meta)
  values (c.id, 'system', coalesce(nullif(p_message, ''), case when v_online > 0 then 'A person will reply shortly.'
            else 'Our team is away right now. Leave your name and email or phone and we will get back to you as soon as we are back. We can also email you a copy of this chat.' end),
          jsonb_build_object('handoff', p_reason));
  if v_online > 0 then
    perform app.emit_event('staff_chat_waiting', 'chat_conversation', c.id, jsonb_build_object('reason', p_reason), 'staff_chat_waiting:' || c.id);
  end if;
  return jsonb_build_object('ok', true, 'status', c.status, 'on_shift', v_online > 0, 'offline', c.offline, 'has_contact', c.email is not null or c.phone is not null);
end $$;

-- The visitor's contact details (after hours, or asked by the assistant): kept on the conversation and a lead; a
-- task when nobody is on shift; the renter linked when the email is theirs; the transcript emailed when asked.
create or replace function app.server_chat_contact(p_token text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c chat_conversations;
  v_email text := lower(nullif(btrim(p ->> 'email'), ''));
  v_phone text := nullif(regexp_replace(coalesce(p ->> 'phone', ''), '[^0-9+]', '', 'g'), '');
  v_name text := nullif(left(btrim(p ->> 'name'), 120), '');
  v_lead uuid;
  v_renter uuid;
  v_task uuid;
begin
  select * into c from chat_conversations where token = p_token for update;
  if c.id is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return jsonb_build_object('ok', false, 'error', 'That email does not look right'); end if;
  if v_email is null and v_phone is null then return jsonb_build_object('ok', false, 'error', 'Give an email or a phone number'); end if;
  if not app.rate_limit('chat-contact:' || c.id, 5, interval '1 hour') then return jsonb_build_object('ok', false, 'error', 'limited'); end if;
  v_renter := coalesce(c.renter_id, (select r.id from renters r where lower(r.email) = v_email limit 1));
  if c.lead_id is null then
    insert into leads (kind, name, email, phone, message, payload, source, source_url)
    values ('chat', coalesce(v_name, c.name), coalesce(v_email, c.email), coalesce(v_phone, c.phone), left(p ->> 'note', 500),
            jsonb_build_object('chat', c.number), 'chat', c.page)
    returning id into v_lead;
  else
    v_lead := c.lead_id;
    update leads set name = coalesce(v_name, name), email = coalesce(v_email, email), phone = coalesce(v_phone, phone) where id = v_lead;
  end if;
  update chat_conversations set name = coalesce(v_name, name), email = coalesce(v_email, email), phone = coalesce(v_phone, phone),
         renter_id = v_renter, lead_id = v_lead where id = c.id returning * into c;
  if c.session_id is not null then
    update visitor_sessions set known_name = coalesce(known_name, c.name), known_email = coalesce(known_email, c.email),
           renter_id = coalesce(renter_id, v_renter), identified_by = coalesce(identified_by, 'chat') where id = c.session_id;
  end if;
  insert into chat_messages (conversation_id, sender, body, meta)
  values (c.id, 'system', format('Thanks%s. We will reply to %s.', coalesce(', ' || split_part(c.name, ' ', 1), ''), coalesce(c.email, c.phone)), '{"contact": true}');
  if c.status = 'waiting' and c.offline then
    v_task := app.raise_task(p_type => 'chat_contact', p_due_at => app.task_due('first_reply', null), p_title => left(format('Reply to %s (live chat %s, left after hours)', coalesce(c.name, c.email, c.phone), c.number), 200),
      p_detail => format('Contact: %s. The conversation is in Live chat.', concat_ws(', ', c.email, c.phone)),
      p_renter => c.renter_id, p_related_table => 'chat_conversations', p_related_id => c.id, p_dedupe => 'chat-contact:' || c.id);
  end if;
  if coalesce((p ->> 'transcript')::boolean, false) and c.email is not null then perform app.chat_send_transcript(c.id); end if;
  return jsonb_build_object('ok', true, 'has_contact', true);
end $$;

-- The assistant collected a booking request: a lead with the car and dates, and a task for Sales.
create or replace function app.server_chat_lead(p_token text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c chat_conversations;
  v_email text := lower(nullif(btrim(p ->> 'email'), ''));
  v_phone text := nullif(regexp_replace(coalesce(p ->> 'phone', ''), '[^0-9+]', '', 'g'), '');
  v_name text := nullif(left(btrim(p ->> 'name'), 120), '');
  v_vehicle uuid;
  v_lead uuid;
  v_task uuid;
begin
  select * into c from chat_conversations where token = p_token for update;
  if c.id is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if v_name is null then return jsonb_build_object('ok', false, 'missing', 'name'); end if;
  if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return jsonb_build_object('ok', false, 'missing', 'email'); end if;
  if v_phone is null or length(v_phone) < 10 then return jsonb_build_object('ok', false, 'missing', 'phone'); end if;
  select l.vehicle_id into v_vehicle from vehicle_listings l where l.slug = nullif(p ->> 'car', '');
  insert into leads (kind, name, email, phone, message, payload, source, source_url)
  values ('chat', v_name, v_email, v_phone, left(p ->> 'note', 500),
          jsonb_strip_nulls(jsonb_build_object('chat', c.number, 'car', p ->> 'car', 'pickup', p ->> 'pickup', 'return', p ->> 'return', 'quote_total_cents', p -> 'quote_total_cents')),
          'chat', c.page)
  returning id into v_lead;
  update chat_conversations set name = v_name, email = v_email, phone = v_phone, lead_id = v_lead, vehicle_id = coalesce(v_vehicle, vehicle_id),
         renter_id = coalesce(renter_id, (select r.id from renters r where lower(r.email) = v_email limit 1))
   where id = c.id returning * into c;
  if c.session_id is not null then
    update visitor_sessions set known_name = coalesce(known_name, v_name), known_email = coalesce(known_email, v_email), renter_id = coalesce(renter_id, c.renter_id),
           identified_by = coalesce(identified_by, 'chat') where id = c.session_id;
  end if;
  v_task := app.raise_task(p_type => 'chat_request', p_due_at => app.task_due('first_reply', null),
    p_title => left(format('Booking request from live chat %s: %s%s%s', c.number, v_name, coalesce(', ' || app.vehicle_name(v_vehicle), ''),
                           coalesce(', ' || (p ->> 'pickup') || ' to ' || (p ->> 'return'), '')), 200),
    p_detail => format('Contact: %s, %s. Make a quote (New quote) and send the offer. Choose "I sourced this client" only if you handled this chat.%s', v_email, v_phone,
                       coalesce(' Note: ' || left(p ->> 'note', 300), '')),
    p_vehicle => v_vehicle, p_renter => c.renter_id, p_related_table => 'chat_conversations', p_related_id => c.id, p_dedupe => 'chat-request:' || c.id || ':' || v_lead);
  return jsonb_build_object('ok', true, 'lead_id', v_lead, 'reference', c.number);
end $$;

-- The visitor ends the chat (or a staff member closes it): the transcript goes to their email if they gave one.
create or replace function app.chat_close(p_conv uuid, p_by uuid default null) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  c chat_conversations;
begin
  update chat_conversations set status = 'closed', closed_at = now(), closed_by = p_by, staff_typing_at = null, visitor_typing_at = null
   where id = p_conv and status <> 'closed' returning * into c;
  if c.id is null then return; end if;
  insert into chat_messages (conversation_id, sender, body, meta) values (c.id, 'system', 'This chat is closed. Start a new one any time.', '{"closed": true}');
  if c.task_id is not null then
    update tasks set status = 'done', completed_at = now(), completed_by = coalesce(p_by, c.assigned_to), completion_note = 'The chat was closed'
     where id = c.task_id and status in ('open', 'in_progress', 'waiting') and (p_by is not null or c.assigned_to is not null);
  end if;
  if c.email is not null and exists (select 1 from chat_messages m where m.conversation_id = c.id and m.sender in ('visitor')) then
    perform app.chat_send_transcript(c.id);
  end if;
end $$;

create or replace function app.server_chat_end(p_token text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v uuid;
begin
  select id into v from chat_conversations where token = p_token;
  if v is null then return jsonb_build_object('ok', false); end if;
  perform app.chat_close(v, null);
  return jsonb_build_object('ok', true);
end $$;

create or replace function app.chat_send_transcript(p_conv uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  c chat_conversations;
begin
  select * into c from chat_conversations where id = p_conv;
  if c.email is null then return; end if;
  perform app.emit_event('renter_chat_transcript', 'chat_conversation', c.id,
    jsonb_build_object('upto', (select max(id) from chat_messages where conversation_id = c.id)),
    'renter_chat_transcript:' || c.id || ':' || coalesce((select max(id) from chat_messages where conversation_id = c.id), 0));
  update chat_conversations set transcript_sent_at = now() where id = c.id;
end $$;

-- ================================================================ 10. chat, the staff side
create or replace function app.chat_presence(p_by uuid) returns void
language sql security definer set search_path = public, app as $$
  insert into chat_staff_prefs (user_id, last_seen_at) values (p_by, now())
  on conflict (user_id) do update set last_seen_at = now()
$$;

create or replace function app.chat_row(c chat_conversations) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', c.id, 'number', c.number, 'status', c.status, 'who', app.visitor_chat_name(c), 'email', c.email, 'phone', c.phone,
    'renter_id', c.renter_id, 'session_id', c.session_id, 'started_by', c.started_by, 'assigned_to', c.assigned_to,
    'assigned_name', (select u.full_name from users u where u.id = c.assigned_to),
    'human_requested_at', c.human_requested_at, 'human_reason', c.human_reason, 'first_human_reply_at', c.first_human_reply_at, 'offline', c.offline,
    'page', app.path_label(c.page), 'car', case when c.vehicle_id is not null then app.vehicle_name(c.vehicle_id) end,
    'last_message_at', c.last_message_at, 'created_at', c.created_at, 'closed_at', c.closed_at,
    'unread', (select count(*) from chat_messages m where m.conversation_id = c.id and m.sender = 'visitor' and m.id > c.staff_read_id),
    'last', (select left(m.body, 140) from chat_messages m where m.conversation_id = c.id and m.sender <> 'system' order by m.id desc limit 1),
    'visitor_typing', coalesce(c.visitor_typing_at > now() - interval '6 seconds', false),
    'online', exists (select 1 from visitor_sessions s where s.id = c.session_id and s.last_seen_at > now() - make_interval(mins => (app.settings()).visitor_live_minutes)),
    'waiting_minutes', case when c.status = 'waiting' then floor(extract(epoch from now() - c.human_requested_at) / 60)::integer end,
    'target_minutes', app.first_reply_minutes(),
    'ai_replies', c.ai_replies, 'lead_id', c.lead_id)
$$;

create or replace function app.chat_inbox(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.assert_live_staff(p_by);
  perform app.chat_presence(p_by);
  return jsonb_build_object('at', now(), 'on_shift', app.chat_on_shift(),
    'open', coalesce((select jsonb_agg(app.chat_row(c) order by (c.status = 'waiting') desc, c.last_message_at desc)
                        from chat_conversations c where c.status <> 'closed' and c.last_message_at > now() - interval '3 days'), '[]'::jsonb),
    'closed', coalesce((select jsonb_agg(app.chat_row(c) order by c.closed_at desc) from (
                          select * from chat_conversations where status = 'closed' and closed_at > now() - interval '7 days' order by closed_at desc limit 30) c), '[]'::jsonb),
    'prefs', coalesce((select jsonb_build_object('email_when_waiting', x.email_when_waiting, 'desktop_alerts', x.desktop_alerts) from chat_staff_prefs x where x.user_id = p_by),
                      '{"email_when_waiting": false, "desktop_alerts": false}'::jsonb),
    'budget', app.chat_budget(),
    'waiting', (select count(*) from chat_conversations c where c.status = 'waiting'),
    'unread', (select count(*) from chat_messages m join chat_conversations c on c.id = m.conversation_id
                where c.status in ('waiting', 'human') and m.sender = 'visitor' and m.id > c.staff_read_id and (c.assigned_to is null or c.assigned_to = p_by)));
end $$;

create or replace function app.chat_thread(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c chat_conversations;
  s visitor_sessions;
  v_max bigint;
begin
  perform app.assert_live_staff(p_by);
  perform app.chat_presence(p_by);
  select * into c from chat_conversations where id = (p ->> 'id')::uuid;
  if c.id is null then raise exception 'That chat is no longer kept' using errcode = 'P0002'; end if;
  select max(id) into v_max from chat_messages where conversation_id = c.id;
  -- read by the staff member who works it (or anyone, while nobody does)
  if coalesce(v_max, 0) > c.staff_read_id and (c.assigned_to is null or c.assigned_to = p_by) then
    update chat_conversations set staff_read_id = v_max where id = c.id;
  end if;
  select * into s from visitor_sessions where id = c.session_id;
  return jsonb_build_object('chat', app.chat_row(c), 'mine', c.assigned_to = p_by,
    'messages', app.chat_messages_json(c.id, coalesce((p ->> 'after')::bigint, 0), true),
    'session', case when s.id is not null then app.live_session(p_by, jsonb_build_object('id', s.id)) end,
    'renter', (select jsonb_build_object('id', r.id, 'name', r.legal_name, 'email', r.email, 'mobile', r.mobile,
                 'bookings', (select coalesce(jsonb_agg(jsonb_build_object('number', b.booking_number, 'status', b.status, 'pickup_at', b.pickup_at) order by b.pickup_at desc), '[]'::jsonb)
                                from (select * from bookings where renter_id = r.id order by pickup_at desc limit 5) b))
                 from renters r where r.id = c.renter_id));
end $$;

create or replace function app.chat_staff_do(p_by uuid, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c chat_conversations;
  s visitor_sessions;
  v_body text := left(btrim(coalesce(p ->> 'body', '')), 4000);
  v_id bigint;
begin
  perform app.assert_live_staff(p_by);
  perform app.chat_presence(p_by);
  if p_name = 'chat_prefs' then
    insert into chat_staff_prefs (user_id, email_when_waiting, desktop_alerts, last_seen_at)
    values (p_by, coalesce((p ->> 'email_when_waiting')::boolean, false), coalesce((p ->> 'desktop_alerts')::boolean, false), now())
    on conflict (user_id) do update set email_when_waiting = excluded.email_when_waiting, desktop_alerts = excluded.desktop_alerts;
    return jsonb_build_object('ok', true);
  end if;
  if p_name = 'chat_start' then
    -- a proactive chat with a visitor on the site now: they see a message bubble
    select * into s from visitor_sessions where id = (p ->> 'session_id')::uuid;
    if s.id is null or s.last_seen_at < now() - interval '10 minutes' then raise exception 'That visitor has left the site' using errcode = '22023'; end if;
    if v_body = '' then v_body := 'Hi, I am ' || coalesce((select split_part(full_name, ' ', 1) from users where id = p_by), 'here') || ' from CarmaCars. Can I help you find a car or answer a question?'; end if;
    select * into c from chat_conversations where visitor_id = s.visitor_id and status <> 'closed' order by created_at desc limit 1;
    if c.id is null then
      insert into chat_conversations (session_id, visitor_id, user_id, renter_id, name, email, status, started_by, started_by_staff, assigned_to, page, vehicle_id, first_human_reply_at)
      values (s.id, s.visitor_id, s.user_id, s.renter_id, s.known_name, s.known_email, 'human', 'staff', p_by, p_by, s.current_path, s.current_vehicle_id, now())
      returning * into c;
    else
      update chat_conversations set status = 'human', assigned_to = p_by, session_id = s.id where id = c.id returning * into c;
    end if;
    insert into chat_messages (conversation_id, sender, staff_id, body) values (c.id, 'staff', p_by, v_body) returning id into v_id;
    update chat_conversations set last_message_at = now(), staff_read_id = greatest(staff_read_id, v_id) where id = c.id;
    return jsonb_build_object('ok', true, 'id', c.id, 'number', c.number);
  end if;
  select * into c from chat_conversations where id = (p ->> 'id')::uuid for update;
  if c.id is null then raise exception 'That chat is no longer kept' using errcode = 'P0002'; end if;
  case p_name
  when 'chat_take' then
    if c.status = 'closed' then raise exception 'That chat is closed' using errcode = '22023'; end if;
    update chat_conversations set status = 'human', assigned_to = p_by where id = c.id;
    insert into chat_messages (conversation_id, sender, body, meta)
    values (c.id, 'system', coalesce((select split_part(full_name, ' ', 1) from users where id = p_by), 'A team member') || ' from CarmaCars joined the chat.', '{"joined": true}');
    if c.task_id is not null then update tasks set assigned_to = p_by, status = 'in_progress' where id = c.task_id and status in ('open', 'waiting'); end if;
  when 'chat_reply' then
    if v_body = '' then raise exception 'Write a reply first' using errcode = '22023'; end if;
    if c.status = 'closed' then raise exception 'That chat is closed' using errcode = '22023'; end if;
    -- replying takes the conversation (the assistant stops)
    if c.status <> 'human' or c.assigned_to is distinct from p_by then
      update chat_conversations set status = 'human', assigned_to = p_by where id = c.id;
    end if;
    insert into chat_messages (conversation_id, sender, staff_id, body) values (c.id, 'staff', p_by, v_body) returning id into v_id;
    update chat_conversations set last_message_at = now(), staff_typing_at = null, staff_read_id = greatest(staff_read_id, v_id),
           first_human_reply_at = coalesce(first_human_reply_at, now()) where id = c.id;
    if c.task_id is not null then
      update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'Answered in Live chat'
       where id = c.task_id and status in ('open', 'in_progress', 'waiting') and task_type = 'live_chat_waiting';
    end if;
  when 'chat_hand_back' then
    update chat_conversations set status = 'ai', assigned_to = null where id = c.id and status <> 'closed';
    insert into chat_messages (conversation_id, sender, body, meta) values (c.id, 'system', 'The CarmaCars assistant is back to help. Ask for a person any time.', '{"hand_back": true}');
  when 'chat_close' then
    perform app.chat_close(c.id, p_by);
  when 'chat_typing' then
    update chat_conversations set staff_typing_at = now() where id = c.id;
    return jsonb_build_object('ok', true);
  when 'chat_transcript' then
    if c.email is null then raise exception 'This visitor gave no email' using errcode = '22023'; end if;
    perform app.chat_send_transcript(c.id);
  else raise exception 'Unknown action %', p_name using errcode = '22023';
  end case;
  return jsonb_build_object('ok', true, 'id', c.id);
end $$;

-- ================================================================ 11. emails: the transcript, a chat waiting for staff
insert into notification_link_paths (key, path) values ('admin_chat', '/admin/chat'), ('va_chat', '/va/chat')
on conflict (key) do update set path = excluded.path;

alter function app.notification_recipients(app_events, notification_catalogue) rename to notification_recipients_pre0060;
create or replace function app.notification_recipients(p_event app_events, p_c notification_catalogue)
returns table (audience text, user_id uuid, email text, name text, renter_id uuid, owner_id uuid, immediate boolean)
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_c.code = 'renter_chat_transcript' then
    return query select 'renter'::text, c.user_id, c.email, c.name, c.renter_id, null::uuid, true
                   from chat_conversations c where c.id = p_event.entity_id and c.email is not null;
    return;
  end if;
  if p_c.code = 'staff_chat_waiting' then
    -- the staff on shift who asked for an email when a chat waits (Live chat > Notify me)
    return query select case when app.user_is_admin(u.id) then 'staff_admin' else 'staff_va_' || coalesce(sp.va_function::text, 'cs') end,
                        u.id, u.email, u.full_name, null::uuid, null::uuid, true
                   from chat_staff_prefs x join users u on u.id = x.user_id left join staff_profiles sp on sp.user_id = u.id
                  where x.email_when_waiting and x.last_seen_at > now() - make_interval(mins => (app.settings()).chat_shift_minutes)
                    and app.live_staff_ok(u.id) and u.email is not null;
    return;
  end if;
  return query select * from app.notification_recipients_pre0060(p_event, p_c);
end $$;

alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre0060;
create or replace function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_pre0060(p_code, p_event, p_to);
  c chat_conversations;
begin
  if p_code in ('renter_chat_transcript', 'staff_chat_waiting') then
    select * into c from chat_conversations where id = p_event.entity_id;
    x := x || jsonb_build_object(
      'first_name', coalesce(nullif(split_part(coalesce(case when p_code = 'renter_chat_transcript' then c.name end, p_to ->> 'name', ''), ' ', 1), ''), 'there'),
      'chat_number', c.number,
      'chat_date', app.fmt_date(c.created_at),
      'visitor_name', app.visitor_chat_name(c),
      'chat_reason', coalesce(c.human_reason, 'asked for a person'),
      'chat_page', coalesce(app.path_label(c.page), 'the site'),
      'chat_url', app.ntf_link(case when (p_to ->> 'audience') = 'staff_admin' then 'admin_chat' else 'va_chat' end),
      'messages', coalesce((select jsonb_agg(jsonb_build_object('who', case m.sender when 'visitor' then 'You' when 'ai' then 'CarmaCars assistant'
                                 when 'staff' then coalesce((select split_part(u.full_name, ' ', 1) from users u where u.id = m.staff_id), 'CarmaCars') else 'CarmaCars' end,
                               'time', app.fmt_time(m.at), 'text', m.body) order by m.id)
                             from chat_messages m where m.conversation_id = c.id
                              and m.id <= coalesce((p_event.payload ->> 'upto')::bigint, 9223372036854775807)), '[]'::jsonb));
  end if;
  return x;
end $$;

-- ================================================================ 12. the privacy policy and the cookie wording (flagged for the lawyer)
-- The live copy changes only where it still carries our text; an Admin's own edit is left as it is.
update site_content_blocks
   set body = replace(body,
     'Essential cookies keep you signed in and keep bookings secure. Analytics cookies measure how the Site is used and are set only if you accept them. You can block cookies in your browser, but parts of the Site may then not work.',
     'Essential cookies keep you signed in and keep bookings secure. Analytics cookies measure how the Site is used and are set only if you accept them. You can block cookies in your browser, but parts of the Site may then not work.

We measure visits ourselves, with no third-party analytics. With your consent we record the pages and cars you view, the dates you search, the booking steps you start or finish, the site that sent you, your type of device and an approximate city worked out from your connection. We do not store your network address for this. Our customer service and sales staff see this while you are on the Site, and use it to help you, for example to answer a question about a car you are looking at. Without your consent we record none of it, except what follows.

Two things are recorded without the analytics choice, because they are part of the service you asked for. When you open live chat, we keep the conversation and the page you were on. When you are signed in, or open a link from one of our emails, we record when you open your offer, a change we proposed, the agreement or the pay page for your own booking, so we can follow up if something is stuck.

Live chat is answered first by an automated assistant that uses our own information about cars, prices and policies, and then by our staff. The assistant does not make decisions about you; a person reviews anything it collects. Chat conversations are kept with your rental records if you are a customer, and otherwise for 12 months. If you give an email address in the chat, we can email you a copy of the conversation.')
 where block_key = 'legal.privacy' and body like '%Analytics cookies measure how the Site is used and are set only if you accept them. You can block cookies in your browser, but parts of the Site may then not work.%'
   and body not like '%We measure visits ourselves%';
update site_content_blocks
   set body = replace(body, '| Site data: IP address, device, pages viewed and cookies | To secure and improve the Site |',
     '| Site data: IP address (security logs only), device, approximate city, pages and cars viewed, booking steps and cookies | To secure and improve the Site, and, with your consent, to help you while you browse (section 10) |
| Live chat: the conversation and the page you were on, and your name, email or phone if you give them | To answer you and follow up on your request |')
 where block_key = 'legal.privacy' and body like '%| Site data: IP address, device, pages viewed and cookies | To secure and improve the Site |%';
update site_content_blocks
   set body = replace(body, '| Marketing contact details | Until you unsubscribe |',
     '| Site visit records (pages, events) | 90 days; daily counts per car without personal information are kept |
| Live chat conversations | With your rental records if you are a customer; otherwise 12 months |
| Marketing contact details | Until you unsubscribe |')
 where block_key = 'legal.privacy' and body like '%| Marketing contact details | Until you unsubscribe |%' and body not like '%Live chat conversations%';
-- the banner asks again: the wording changed
update site_content_blocks
   set data = data || jsonb_build_object('version', '2026-10-19',
     'text', 'We use necessary cookies to keep the site working, your bookings secure and live chat running. With your consent we also measure visits ourselves (pages and cars viewed, approximate city, device), so our team can help you and we can improve the site. No third-party analytics.',
     'groups', jsonb_build_array(
        jsonb_build_object('code', 'necessary_cookies', 'name', 'Necessary', 'always', true,
          'text', 'Sign-in, security, your booking request and live chat. When you are signed in or open one of our email links, we note when you open your own offer, proposal or pay page. Always on.'),
        jsonb_build_object('code', 'analytics_cookies', 'name', 'Analytics', 'always', false,
          'text', 'Records the pages and cars you view, the dates you search and the site that sent you, with your approximate city and device. Our team sees it while you browse. Off unless you turn it on.')))
 where block_key = 'cookies.banner' and coalesce(data ->> 'version', '') < '2026-10-19';
update site_content_blocks set data = data || jsonb_build_object('last_updated', 'October 19, 2026')
 where block_key = 'legal.meta' and (data ->> 'last_updated') in ('October 8, 2026', 'October 16, 2026');

-- ================================================================ 13. the doors and privileges
create or replace function app.ops60(p_user uuid, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  case p_name
  when 'live_visitors' then return app.live_visitors(p_user, p);
  when 'live_session' then return app.live_session(p_user, p);
  when 'vehicle_interest' then return app.vehicle_interest(p_user, p);
  when 'visitor_timeline' then return app.visitor_timeline(p_user, p);
  when 'my_followups' then return app.visitor_followups_figures(p_user, p);
  when 'renter_live' then return app.renter_live(p_user, p);
  when 'most_viewed' then perform app.assert_live_staff(p_user); return app.most_viewed_cars(coalesce((p ->> 'days')::integer, 7), coalesce((p ->> 'limit')::integer, 5));
  when 'staff_followups' then perform app.assert_admin(p_user); return app.visitor_followups_figures((p ->> 'staff')::uuid, p);
  when 'chat_inbox' then return app.chat_inbox(p_user, p);
  when 'chat_thread' then return app.chat_thread(p_user, p);
  when 'chat_counts' then
    if not app.live_staff_ok(p_user) then return jsonb_build_object('waiting', 0, 'unread', 0, 'live', 0); end if;
    return jsonb_build_object('waiting', (select count(*) from chat_conversations where status = 'waiting'),
      'unread', (select count(*) from chat_messages m join chat_conversations c on c.id = m.conversation_id
                  where c.status in ('waiting', 'human') and m.sender = 'visitor' and m.id > c.staff_read_id and (c.assigned_to is null or c.assigned_to = p_user)),
      'live', (select count(*) from visitor_sessions s where s.last_seen_at > now() - make_interval(mins => (app.settings()).visitor_live_minutes) and s.ended_at is null));
  when 'chat_prefs', 'chat_start', 'chat_take', 'chat_reply', 'chat_hand_back', 'chat_close', 'chat_typing', 'chat_transcript' then
    return app.chat_staff_do(p_user, p_name, p);
  else raise exception 'Unknown action %', p_name using errcode = '22023';
  end case;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0060;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
begin
  if (p_call in ('va_read', 'admin_read', 'ops_read') and p_name in ('live_visitors', 'live_session', 'vehicle_interest', 'visitor_timeline', 'my_followups', 'chat_inbox', 'chat_thread', 'chat_counts', 'most_viewed'))
     or (p_call = 'admin_read' and p_name in ('staff_followups', 'renter_live'))
     or (p_call in ('va_do', 'admin_do', 'ops_do') and p_name in ('chat_prefs', 'chat_start', 'chat_take', 'chat_reply', 'chat_hand_back', 'chat_close', 'chat_typing', 'chat_transcript')) then
    if p_ ? '_va' then perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.ops60(p_user, p_call, p_name, p_ - '_va');
  end if;
  return app.door_pre0060(p_user, p_aal, p_call, p_name, p);
end $$;

-- public wrappers: the beacon and the chat poll are called from the browser or the Worker (anon or a signed-in
-- user); everything else only by the server.
create or replace function public.track_ingest(p jsonb, p_geo jsonb default '{}'::jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.track_ingest(p, p_geo) $$;
create or replace function public.chat_poll(p_token text, p_after bigint default 0) returns jsonb
language sql security definer set search_path = public, app as $$ select app.chat_poll(p_token, p_after) $$;
create or replace function public.chat_typing(p_token text) returns boolean
language sql security definer set search_path = public, app as $$ select coalesce(app.chat_typing(p_token), false) $$;
create or replace function public.server_chat_open(p jsonb, p_user uuid default null) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_chat_open(p, p_user) $$;
create or replace function public.server_chat_facts() returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_chat_facts() $$;
create or replace function public.server_chat_visitor_message(p_token text, p_body text) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_chat_visitor_message(p_token, p_body) $$;
create or replace function public.server_chat_ai_reply(p_token text, p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_chat_ai_reply(p_token, p) $$;
create or replace function public.server_chat_handoff(p_token text, p_reason text, p_message text default null) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_chat_handoff(p_token, p_reason, p_message) $$;
create or replace function public.server_chat_contact(p_token text, p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_chat_contact(p_token, p) $$;
create or replace function public.server_chat_lead(p_token text, p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_chat_lead(p_token, p) $$;
create or replace function public.server_chat_end(p_token text) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_chat_end(p_token) $$;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig, n.nspname, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array[
              'live_staff_ok', 'assert_live_staff', 'visitor_device_words', 'visitor_who', 'visitor_chat_name', 'path_label', 'visitor_from_email_link',
              'track_ingest', 'chat_public_cfg', 'visitor_signal_put', 'visitor_signals_eval', 'visitor_signals_json', 'job_visitor_followups',
              'job_visitor_housekeeping', 'visitor_session_row', 'live_visitors', 'most_viewed_cars', 'vehicle_interest', 'live_session', 'visitor_timeline',
              'visitor_followups_figures', 'renter_live', 'chat_messages_json', 'chat_on_shift', 'chat_poll', 'chat_typing', 'server_chat_open', 'server_chat_facts',
              'chat_budget', 'server_chat_visitor_message', 'server_chat_ai_reply', 'server_chat_handoff', 'server_chat_contact', 'server_chat_lead',
              'chat_close', 'server_chat_end', 'chat_send_transcript', 'chat_presence', 'chat_row', 'chat_inbox', 'chat_thread', 'chat_staff_do',
              'notification_recipients', 'notification_payload', 'ops60', 'door']))
        or (n.nspname = 'public' and p.proname = any (array['server_chat_open', 'server_chat_facts', 'server_chat_visitor_message', 'server_chat_ai_reply',
              'server_chat_handoff', 'server_chat_contact', 'server_chat_lead', 'server_chat_end']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
  -- the browser's and the Worker's three
  revoke all on function public.track_ingest(jsonb, jsonb), public.chat_poll(text, bigint), public.chat_typing(text) from public;
  grant execute on function public.track_ingest(jsonb, jsonb), public.chat_poll(text, bigint), public.chat_typing(text) to anon, authenticated, service_role;
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
             join (values ('door_pre0060', 'door'), ('notification_recipients_pre0060', 'notification_recipients'), ('ntf_payload_pre0060', 'notification_payload')) m(old_name, new_name)
               on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    execute format('revoke all on function %s from public, anon, authenticated', v_new);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;

-- ================================================================ 14. the email catalogue
-- CATALOGUE 0060 START (generated by supabase/seed/0060_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('renter_chat_transcript', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Your chat with CarmaCars ({{chat_number}})', 'A copy of your conversation of {{chat_date}}.', 'Immediate', 'A live chat on the site closes (the visitor ends it, a staff member closes it, or the visitor left contact details after hours and asked for a copy) and the visitor gave an email address in it. One email to that address with the conversation. Transactional: it is the copy the visitor asked for.', null, '/cars', '[{"name":"chat_date","type":"string"},{"name":"chat_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"messages","type":"list","fields":["who","time","text"]},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_chat_transcript.html', 'templates/renter_chat_transcript.txt'),
  ('staff_chat_waiting', 'staff_va_cs', array['staff_va_sales', 'staff_admin']::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Live chat {{chat_number}} waits for you: {{visitor_name}}', '{{chat_reason}}. Reply within the first reply target.', 'Immediate', 'A visitor in live chat needs a person (they asked, or the assistant handed over: a complaint, damage, an accident, a payment, a question it could not answer, or the day''s AI allowance is used). Sent only to staff on shift (Live chat or Live visitors open in the last minutes) who turned on "Email me when a chat waits" in Live chat. Immediate.', null, null, '[{"name":"chat_number","type":"string"},{"name":"chat_page","type":"string"},{"name":"chat_reason","type":"string"},{"name":"chat_url","type":"url"},{"name":"company_address","type":"string","global":true},{"name":"visitor_name","type":"string"}]'::jsonb, 'templates/staff_chat_waiting.html', 'templates/staff_chat_waiting.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 0060 END
update notification_catalogue set emitted_by = 'app.chat_send_transcript (0060)' where code = 'renter_chat_transcript';
update notification_catalogue set emitted_by = 'app.server_chat_handoff (0060)' where code = 'staff_chat_waiting';

-- ================================================================ 15. the guides for this release
-- GUIDES 0060 START (generated by supabase/seed/0060_gen_guides.mjs from docs/guides/content; do not edit by hand)
-- GUIDES 0060 END
