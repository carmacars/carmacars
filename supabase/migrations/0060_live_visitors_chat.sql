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
-- From docs/guides/content (docs/guides/src, exported): Live visitors and live chat for Admins and assistants, the chat
-- for renters. Published as 0059 publishes (app.guide_release_section).
create or replace function app.guide_release_0060(p_portal text, p_slug text, p_kind text, p_after text, p_base_md text, p_title text, p_blurb text,
                                                  p_md text, p_html text) returns text
language sql security definer set search_path = public, app as $$
  select app.guide_release_section(p_portal, p_slug, p_kind, p_after, p_base_md, p_title, p_blurb, p_md, p_html)
$$;
revoke all on function app.guide_release_0060(text, text, text, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function app.guide_release_0060(text, text, text, text, text, text, text, text, text) to service_role;

-- GUIDES 0060 START (generated by supabase/seed/0060_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_0060('renter', 'find-a-car-and-send-a-request', 'chapter', 'start-here', 'Every booking starts as a request. A person checks the car and the price, then sends you an offer. Nothing is charged until you approve, sign and pay.

:::flow
Request | You pick a car and dates
Offer | We confirm the price
Sign | The rental agreement
Pay | Your card is authorized
Verify | Licence, selfie, coverage
Pick up | We hand over the keys
:::

## Find a car

Start on carmacars.ca. You do not need to sign in to look around.

1. Go to `carmacars.ca` and press **Find a car**.
2. Add your pickup and return dates. The list then shows the cars that are free and what the whole trip costs.
3. Narrow the list with Filters: type, seats, transmission and daily rate.
4. Open a car to see its photos, rates, what is included and its own calendar.

![](/guides/img/public-02-cars-desktop-b6cd4fb8.jpg "desktop; size: 1440 880; address: carmacars.ca/cars; pins: 1 86.1 4.0, 2 11.1 56.8, 3 3.0 82.3, 4 34.0 87.5")

## Choose your dates on the car page

1. Under Dates and price, tap your pickup date, then your return date. Hatched days are already booked.
2. Choose the Pickup time and the Return time.
3. Want it brought to you? Tick **Deliver it to me** or **Pick it up from me at the end**.
4. Check Your estimate, then press **Request to book**.

![](/guides/img/public-03-car-page-desktop-73be4d63.jpg "desktop; size: 1120 760; address: carmacars.ca/cars/bmw-330i; pins: 1 24.4 39.7, 2 12.9 68.2, 3 3.0 76.2, 4 97.0 50.0")

> Watch out: A request does not hold the car. The car is booked only once you approve the offer, sign and pay.

## Send your request

The request has four short steps. Your answers are saved as you go, so you can come back.

1. Step 1, Dates and delivery: check the car and tap your dates in the calendar.
2. Set the Pickup time and Return time. Any time, day or night, with at least 2 hours of notice.
3. Your request, on the right, shows the estimated total as you go.

![](/guides/img/public-04-book-1-trip-desktop-63a3738b.jpg "desktop; size: 1440 1002; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 1 9.2 67.1, 2 15.3 91.0, 3 91.1 54.7")

4. Choose where you get the car: **At our location**, **Deliver it to an address** or **At the airport**. Then choose where you return it.
5. Press **Continue to driver details**.

![](/guides/img/public-04-book-1-trip-desktop-befba4f6.jpg "desktop; size: 760 942; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 4 5.3 26.2, 5 61.8 93.3")

6. Step 2, The driver: fill in your first and last name, email, mobile number and date of birth.
7. Someone else will drive too? Add them under Additional drivers. Each needs a G2 or G licence and signs the agreement.
8. Press **Continue to licence**.

![](/guides/img/public-05-book-2-driver-desktop-7b572499.jpg "desktop; size: 980 1032; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 6 30.6 21.1, 7 30.6 64.8, 8 55.6 88.0")

9. Step 3: choose your Licence class, for example Ontario G2.
10. Choose how the car is covered: Option 1 (OPCF 27 on your own auto policy), Option 2 (rental coverage on your credit card) or Option 3 (the CarmaCars Protection Plan). You can change this any time before pickup.
11. Choose the Booking type: Standard, or Non-refundable for 10% off with no refund.
12. Add extras such as Winter tires or Baby seats, and anything we should know.
13. Press **Review request**.

![](/guides/img/public-06-book-3-licence-desktop-22bb144e.jpg "desktop; size: 760 1452; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 9 61.8 11.2, 10 92.1 32.2, 11 92.1 50.4, 12 92.1 66.9, 13 71.7 97.0")

14. Step 4, Check it and send: read every line. Use Edit beside a line to change it.
15. Tick the box to confirm you are 18 or older and agree to the Terms of use and Privacy policy.
16. Press **Send request**. Nothing is charged and no card is needed.

![](/guides/img/public-07-book-4-review-desktop-005f4c0b.jpg "desktop; size: 760 492; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 14 92.1 24.8, 15 3.9 59.3, 16 73.7 89.0")

17. The confirmation shows your request number, for example CC-10021. Keep it for any question.
18. A person checks the calendar, your dates and your place, usually within 2 hours, day or night. Your offer arrives by email and in Trips.

![](/guides/img/public-08-book-5-sent-phone-14a99ccf.jpg "phone; size: 390 755; pins: 17 32.8 12.3")
', 'Find a car and send a request', 'Search the fleet, pick dates and send a request in four short steps.',
  'Every booking starts as a request. A person checks the car and the price, then sends you an offer. Nothing is charged until you approve, sign and pay.

:::flow
Request | You pick a car and dates
Offer | We confirm the price
Sign | The rental agreement
Pay | Your card is authorized
Verify | Licence, selfie, coverage
Pick up | We hand over the keys
:::

## Find a car

Start on carmacars.ca. You do not need to sign in to look around.

1. Go to `carmacars.ca` and press **Find a car**.
2. Add your pickup and return dates. The list then shows the cars that are free and what the whole trip costs.
3. Narrow the list with Filters: type, seats, transmission and daily rate.
4. Open a car to see its photos, rates, what is included and its own calendar.

![](/guides/img/public-02-cars-desktop-b6cd4fb8.jpg "desktop; size: 1440 880; address: carmacars.ca/cars; pins: 1 86.1 4.0, 2 11.1 56.8, 3 3.0 82.3, 4 34.0 87.5")

## Choose your dates on the car page

1. Under Dates and price, tap your pickup date, then your return date. Hatched days are already booked.
2. Choose the Pickup time and the Return time.
3. Want it brought to you? Tick **Deliver it to me** or **Pick it up from me at the end**.
4. Check Your estimate, then press **Request to book**.

![](/guides/img/public-03-car-page-desktop-73be4d63.jpg "desktop; size: 1120 760; address: carmacars.ca/cars/bmw-330i; pins: 1 24.4 39.7, 2 12.9 68.2, 3 3.0 76.2, 4 97.0 50.0")

> Watch out: A request does not hold the car. The car is booked only once you approve the offer, sign and pay.

## Send your request

The request has four short steps. Your answers are saved as you go, so you can come back.

1. Step 1, Dates and delivery: check the car and tap your dates in the calendar.
2. Set the Pickup time and Return time. Any time, day or night, with at least 2 hours of notice.
3. Your request, on the right, shows the estimated total as you go.

![](/guides/img/public-04-book-1-trip-desktop-63a3738b.jpg "desktop; size: 1440 1002; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 1 9.2 67.1, 2 15.3 91.0, 3 91.1 54.7")

4. Choose where you get the car: **At our location**, **Deliver it to an address** or **At the airport**. Then choose where you return it.
5. Press **Continue to driver details**.

![](/guides/img/public-04-book-1-trip-desktop-befba4f6.jpg "desktop; size: 760 942; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 4 5.3 26.2, 5 61.8 93.3")

6. Step 2, The driver: fill in your first and last name, email, mobile number and date of birth.
7. Someone else will drive too? Add them under Additional drivers. Each needs a G2 or G licence and signs the agreement.
8. Press **Continue to licence**.

![](/guides/img/public-05-book-2-driver-desktop-7b572499.jpg "desktop; size: 980 1032; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 6 30.6 21.1, 7 30.6 64.8, 8 55.6 88.0")

9. Step 3: choose your Licence class, for example Ontario G2.
10. Choose how the car is covered: Option 1 (OPCF 27 on your own auto policy), Option 2 (rental coverage on your credit card) or Option 3 (the CarmaCars Protection Plan). You can change this any time before pickup.
11. Choose the Booking type: Standard, or Non-refundable for 10% off with no refund.
12. Add extras such as Winter tires or Baby seats, and anything we should know.
13. Press **Review request**.

![](/guides/img/public-06-book-3-licence-desktop-22bb144e.jpg "desktop; size: 760 1452; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 9 61.8 11.2, 10 92.1 32.2, 11 92.1 50.4, 12 92.1 66.9, 13 71.7 97.0")

14. Step 4, Check it and send: read every line. Use Edit beside a line to change it.
15. Tick the box to confirm you are 18 or older and agree to the Terms of use and Privacy policy.
16. Press **Send request**. Nothing is charged and no card is needed.

![](/guides/img/public-07-book-4-review-desktop-005f4c0b.jpg "desktop; size: 760 492; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 14 92.1 24.8, 15 3.9 59.3, 16 73.7 89.0")

17. The confirmation shows your request number, for example CC-10021. Keep it for any question.
18. A person checks the calendar, your dates and your place, usually within 2 hours, day or night. Your offer arrives by email and in Trips.

![](/guides/img/public-08-book-5-sent-phone-14a99ccf.jpg "phone; size: 390 755; pins: 17 32.8 12.3")

## Ask in the chat

The chat button sits in the corner of every page.

1. Press it and write your question: a car, your dates, the price, how booking works. The CarmaCars assistant answers right away with prices from our booking system.
2. Want a person? Press **Talk to a person**. When our team is away, leave your name and email or phone with **Send my details** and tick "Email me a copy of this chat".
3. Press **End chat** when you are done. If you gave your email, a copy of the chat arrives by email.

A price in the chat is for the dates you asked. Nothing is booked until you approve an offer, sign and pay.
',
  '<p class="gd-p">Every booking starts as a request. A person checks the car and the price, then sends you an offer. Nothing is charged until you approve, sign and pay.</p><ol class="gd-flow"><li><b>1</b><span>Request</span><em>You pick a car and dates</em></li><li><b>2</b><span>Offer</span><em>We confirm the price</em></li><li><b>3</b><span>Sign</span><em>The rental agreement</em></li><li><b>4</b><span>Pay</span><em>Your card is authorized</em></li><li><b>5</b><span>Verify</span><em>Licence, selfie, coverage</em></li><li><b>6</b><span>Pick up</span><em>We hand over the keys</em></li></ol><section class="gd-task" id="find-a-car-and-send-a-request-find-a-car" data-gd-task><h2 class="gd-h2">Find a car</h2><p class="gd-p">Start on carmacars.ca. You do not need to sign in to look around.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Go to <span class="gd-url">carmacars.ca</span> and press <b class="gd-ui">Find a car</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Add your pickup and return dates. The list then shows the cars that are free and what the whole trip costs.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Narrow the list with Filters: type, seats, transmission and daily rate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Open a car to see its photos, rates, what is included and its own calendar.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/cars</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/880"><img src="/guides/img/public-02-cars-desktop-b6cd4fb8.jpg" alt="" loading="lazy" decoding="async" width="1440" height="880"><span class="gd-pin" style="left:86.1%;top:4%" aria-hidden="true">1</span><span class="gd-pin" style="left:11.1%;top:56.8%" aria-hidden="true">2</span><span class="gd-pin" style="left:3%;top:82.3%" aria-hidden="true">3</span><span class="gd-pin" style="left:34%;top:87.5%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="find-a-car-and-send-a-request-choose-your-dates-on-the-car-page" data-gd-task><h2 class="gd-h2">Choose your dates on the car page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Under Dates and price, tap your pickup date, then your return date. Hatched days are already booked.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the Pickup time and the Return time.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Want it brought to you? Tick <b class="gd-ui">Deliver it to me</b> or <b class="gd-ui">Pick it up from me at the end</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Check Your estimate, then press <b class="gd-ui">Request to book</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/cars/bmw-330i</span></div><div class="gd-imgwrap" style="aspect-ratio:1120/760"><img src="/guides/img/public-03-car-page-desktop-73be4d63.jpg" alt="" loading="lazy" decoding="async" width="1120" height="760"><span class="gd-pin" style="left:24.4%;top:39.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:12.9%;top:68.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:3%;top:76.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:97%;top:50%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>A request does not hold the car. The car is booked only once you approve the offer, sign and pay.</div></aside></section><section class="gd-task" id="find-a-car-and-send-a-request-send-your-request" data-gd-task><h2 class="gd-h2">Send your request</h2><p class="gd-p">The request has four short steps. Your answers are saved as you go, so you can come back.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Step 1, Dates and delivery: check the car and tap your dates in the calendar.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Set the Pickup time and Return time. Any time, day or night, with at least 2 hours of notice.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Your request, on the right, shows the estimated total as you go.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1002"><img src="/guides/img/public-04-book-1-trip-desktop-63a3738b.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1002"><span class="gd-pin" style="left:9.2%;top:67.1%" aria-hidden="true">1</span><span class="gd-pin" style="left:15.3%;top:91%" aria-hidden="true">2</span><span class="gd-pin" style="left:91.1%;top:54.7%" aria-hidden="true">3</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="4"><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Choose where you get the car: <b class="gd-ui">At our location</b>, <b class="gd-ui">Deliver it to an address</b> or <b class="gd-ui">At the airport</b>. Then choose where you return it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Continue to driver details</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:760/942"><img src="/guides/img/public-04-book-1-trip-desktop-befba4f6.jpg" alt="" loading="lazy" decoding="async" width="760" height="942"><span class="gd-pin" style="left:5.3%;top:26.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:61.8%;top:93.3%" aria-hidden="true">5</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="6"><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Step 2, The driver: fill in your first and last name, email, mobile number and date of birth.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Someone else will drive too? Add them under Additional drivers. Each needs a G2 or G licence and signs the agreement.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Press <b class="gd-ui">Continue to licence</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:980/1032"><img src="/guides/img/public-05-book-2-driver-desktop-7b572499.jpg" alt="" loading="lazy" decoding="async" width="980" height="1032"><span class="gd-pin" style="left:30.6%;top:21.1%" aria-hidden="true">6</span><span class="gd-pin" style="left:30.6%;top:64.8%" aria-hidden="true">7</span><span class="gd-pin" style="left:55.6%;top:88%" aria-hidden="true">8</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="9"><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Step 3: choose your Licence class, for example Ontario G2.</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Choose how the car is covered: Option 1 (OPCF 27 on your own auto policy), Option 2 (rental coverage on your credit card) or Option 3 (the CarmaCars Protection Plan). You can change this any time before pickup.</div></li><li><span class="gd-n" aria-hidden="true">11</span><div class="gd-t">Choose the Booking type: Standard, or Non-refundable for 10% off with no refund.</div></li><li><span class="gd-n" aria-hidden="true">12</span><div class="gd-t">Add extras such as Winter tires or Baby seats, and anything we should know.</div></li><li><span class="gd-n" aria-hidden="true">13</span><div class="gd-t">Press <b class="gd-ui">Review request</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:760/1452"><img src="/guides/img/public-06-book-3-licence-desktop-22bb144e.jpg" alt="" loading="lazy" decoding="async" width="760" height="1452"><span class="gd-pin" style="left:61.8%;top:11.2%" aria-hidden="true">9</span><span class="gd-pin" style="left:92.1%;top:32.2%" aria-hidden="true">10</span><span class="gd-pin" style="left:92.1%;top:50.4%" aria-hidden="true">11</span><span class="gd-pin" style="left:92.1%;top:66.9%" aria-hidden="true">12</span><span class="gd-pin" style="left:71.7%;top:97%" aria-hidden="true">13</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="14"><li><span class="gd-n" aria-hidden="true">14</span><div class="gd-t">Step 4, Check it and send: read every line. Use Edit beside a line to change it.</div></li><li><span class="gd-n" aria-hidden="true">15</span><div class="gd-t">Tick the box to confirm you are 18 or older and agree to the Terms of use and Privacy policy.</div></li><li><span class="gd-n" aria-hidden="true">16</span><div class="gd-t">Press <b class="gd-ui">Send request</b>. Nothing is charged and no card is needed.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:760/492"><img src="/guides/img/public-07-book-4-review-desktop-005f4c0b.jpg" alt="" loading="lazy" decoding="async" width="760" height="492"><span class="gd-pin" style="left:92.1%;top:24.8%" aria-hidden="true">14</span><span class="gd-pin" style="left:3.9%;top:59.3%" aria-hidden="true">15</span><span class="gd-pin" style="left:73.7%;top:89%" aria-hidden="true">16</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol" start="17"><li><span class="gd-n" aria-hidden="true">17</span><div class="gd-t">The confirmation shows your request number, for example CC-10021. Keep it for any question.</div></li><li><span class="gd-n" aria-hidden="true">18</span><div class="gd-t">A person checks the calendar, your dates and your place, usually within 2 hours, day or night. Your offer arrives by email and in Trips.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/755"><img src="/guides/img/public-08-book-5-sent-phone-14a99ccf.jpg" alt="" loading="lazy" decoding="async" width="390" height="755"><span class="gd-pin" style="left:32.8%;top:12.3%" aria-hidden="true">17</span></div></div></figure></div></section><section class="gd-task" id="find-a-car-and-send-a-request-ask-in-the-chat" data-gd-task><h2 class="gd-h2">Ask in the chat</h2><p class="gd-p">The chat button sits in the corner of every page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press it and write your question: a car, your dates, the price, how booking works. The CarmaCars assistant answers right away with prices from our booking system.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Want a person? Press <b class="gd-ui">Talk to a person</b>. When our team is away, leave your name and email or phone with <b class="gd-ui">Send my details</b> and tick &quot;Email me a copy of this chat&quot;.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">End chat</b> when you are done. If you gave your email, a copy of the chat arrives by email.</div></li></ol></div><p class="gd-p">A price in the chat is for the dates you asked. Nothing is booked until you approve an offer, sign and pay.</p></section>');
select app.guide_release_0060('admin', 'live-visitors-and-live-chat', 'chapter', 'tolls-and-tickets', null, 'Live visitors and live chat', 'Who is on the site now, signals and follow-ups, interest per car, the chat inbox, take over and hand back.',
  'See who is on the site right now and what they look at, with buying signals, and answer the live chat. The CarmaCars assistant answers the chat first; you take over whenever you want, and it hands over by itself for complaints, damage, payments and anything it should not answer.

## Live visitors

Visitors who accepted analytics, known customers on their own booking pages and anyone in a chat.

1. Open **Today** > **Live visitors**. The tiles count who is on the site now, known customers, visits and chats today.
2. Each visitor shows their name when known (signed in, or arrived from one of our emails), otherwise "Visitor from Toronto, phone"; the page and car they are on; the pages and cars of this visit; their visit number, device, city and the site or campaign that sent them.
3. Badges are buying signals: "Viewing spree: 6 cars in 10 minutes", "Opened offer CC-1042, not answered", "Opened the change proposal twice", "Left the pay page", "Returning visitor, 3rd visit this week", "Started a request and stopped".
4. Press **Pages** for every page and event of the visit, or **Start a chat** to write to the visitor. They see your message in a bubble and reply from it.
5. Below: the signals of the last 24 hours and the most viewed cars of the week. The page refreshes by itself every few seconds.

## Follow-up tasks

Signals of known visitors become tasks with a suggested action, for example "Call or message Maya Chen: opened offer CC-1042 twice, no answer for 6 hours".

- An offer opened and not answered: after 6 hours, to Sales when the booking is credited to someone in Sales, otherwise customer service.
- The pay page left without paying: after 30 minutes, customer service. The change proposal opened twice: customer service.
- A booking request started and stopped, or a viewing spree, by a known visitor: Sales.
- A task closes by itself when the renter answers the offer, pays or answers the proposal. Each signal raises one task only.
- The thresholds are in **Settings** > **Program**, group "Live visitors and live chat". Follow-ups done count in My sales.

## Interest in a car

**Cars** > **Vehicles**, a car, Overview: "Interest on the site" shows who is looking now, views today and in 7 days, conversion over 30 days (requests from the people who viewed it) and the last 14 days. The Vehicles list has "Most viewed cars this week".

## A renter''s visits

On a renter''s page (People > Renters, the name) and on a booking''s History tab, "On the site" lists when they viewed the offer, opened the change proposal, viewed or left the pay page, which cars they looked at, and their chats.

## Live chat

1. Open **Bookings** > **Live chat**. The menu counts chats waiting for a person. Open chats come first, those waiting for a person on top, with their minutes against the first reply target (5 minutes).
2. Choose a conversation. Beside it you see the visitor''s page, pages, signals, and the renter with their bookings when known.
3. Press **Take over**: the assistant stops and the visitor reads that you joined. Writing a reply also takes over. Press **Send** (or Enter).
4. **Hand back to the assistant** lets it answer again. **Close** ends the chat; if the visitor gave an email they get a copy. **Email the transcript** sends it any time.
5. Notify me: "Email me when a chat waits (while I am on shift)" and desktop alerts in this browser. You are on shift while Live chat or Live visitors is open.

> Tip: The assistant only repeats prices from our pricing (a quote or the car''s rates), never offers discounts or promises a car, never talks about insurance and never names a provider. Each reply it was not allowed to send says so in the conversation. When nobody is on shift, the chat asks for the visitor''s name, email or phone and raises a task. A booking from a chat you handled is credited only when you choose "I sourced this client" on the quote or offer.

## The assistant''s settings

In Program settings, "Live visitors and live chat": the chat on or off, the AI first or not, its model, the neurons it may use a day (6,000, about 10 chats; then chats wait for a person), the greeting on car pages after some seconds (off by default), how long chats and visits are kept (12 months and 90 days, as the privacy policy says).
',
  '<p class="gd-p">See who is on the site right now and what they look at, with buying signals, and answer the live chat. The CarmaCars assistant answers the chat first; you take over whenever you want, and it hands over by itself for complaints, damage, payments and anything it should not answer.</p><section class="gd-task" id="live-visitors-and-live-chat-live-visitors" data-gd-task><h2 class="gd-h2">Live visitors</h2><p class="gd-p">Visitors who accepted analytics, known customers on their own booking pages and anyone in a chat.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Today</b> &gt; <b class="gd-ui">Live visitors</b>. The tiles count who is on the site now, known customers, visits and chats today.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each visitor shows their name when known (signed in, or arrived from one of our emails), otherwise &quot;Visitor from Toronto, phone&quot;; the page and car they are on; the pages and cars of this visit; their visit number, device, city and the site or campaign that sent them.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Badges are buying signals: &quot;Viewing spree: 6 cars in 10 minutes&quot;, &quot;Opened offer CC-1042, not answered&quot;, &quot;Opened the change proposal twice&quot;, &quot;Left the pay page&quot;, &quot;Returning visitor, 3rd visit this week&quot;, &quot;Started a request and stopped&quot;.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Pages</b> for every page and event of the visit, or <b class="gd-ui">Start a chat</b> to write to the visitor. They see your message in a bubble and reply from it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Below: the signals of the last 24 hours and the most viewed cars of the week. The page refreshes by itself every few seconds.</div></li></ol></div></section><section class="gd-task" id="live-visitors-and-live-chat-follow-up-tasks" data-gd-task><h2 class="gd-h2">Follow-up tasks</h2><p class="gd-p">Signals of known visitors become tasks with a suggested action, for example &quot;Call or message Maya Chen: opened offer CC-1042 twice, no answer for 6 hours&quot;.</p><ul class="gd-ul"><li>An offer opened and not answered: after 6 hours, to Sales when the booking is credited to someone in Sales, otherwise customer service.</li><li>The pay page left without paying: after 30 minutes, customer service. The change proposal opened twice: customer service.</li><li>A booking request started and stopped, or a viewing spree, by a known visitor: Sales.</li><li>A task closes by itself when the renter answers the offer, pays or answers the proposal. Each signal raises one task only.</li><li>The thresholds are in <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>, group &quot;Live visitors and live chat&quot;. Follow-ups done count in My sales.</li></ul></section><section class="gd-task" id="live-visitors-and-live-chat-interest-in-a-car" data-gd-task><h2 class="gd-h2">Interest in a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, a car, Overview: &quot;Interest on the site&quot; shows who is looking now, views today and in 7 days, conversion over 30 days (requests from the people who viewed it) and the last 14 days. The Vehicles list has &quot;Most viewed cars this week&quot;.</p></section><section class="gd-task" id="live-visitors-and-live-chat-a-renter-s-visits" data-gd-task><h2 class="gd-h2">A renter&#39;s visits</h2><p class="gd-p">On a renter&#39;s page (People &gt; Renters, the name) and on a booking&#39;s History tab, &quot;On the site&quot; lists when they viewed the offer, opened the change proposal, viewed or left the pay page, which cars they looked at, and their chats.</p></section><section class="gd-task" id="live-visitors-and-live-chat-live-chat" data-gd-task><h2 class="gd-h2">Live chat</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Live chat</b>. The menu counts chats waiting for a person. Open chats come first, those waiting for a person on top, with their minutes against the first reply target (5 minutes).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose a conversation. Beside it you see the visitor&#39;s page, pages, signals, and the renter with their bookings when known.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Take over</b>: the assistant stops and the visitor reads that you joined. Writing a reply also takes over. Press <b class="gd-ui">Send</b> (or Enter).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Hand back to the assistant</b> lets it answer again. <b class="gd-ui">Close</b> ends the chat; if the visitor gave an email they get a copy. <b class="gd-ui">Email the transcript</b> sends it any time.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Notify me: &quot;Email me when a chat waits (while I am on shift)&quot; and desktop alerts in this browser. You are on shift while Live chat or Live visitors is open.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The assistant only repeats prices from our pricing (a quote or the car&#39;s rates), never offers discounts or promises a car, never talks about insurance and never names a provider. Each reply it was not allowed to send says so in the conversation. When nobody is on shift, the chat asks for the visitor&#39;s name, email or phone and raises a task. A booking from a chat you handled is credited only when you choose &quot;I sourced this client&quot; on the quote or offer.</div></aside></section><section class="gd-task" id="live-visitors-and-live-chat-the-assistant-s-settings" data-gd-task><h2 class="gd-h2">The assistant&#39;s settings</h2><p class="gd-p">In Program settings, &quot;Live visitors and live chat&quot;: the chat on or off, the AI first or not, its model, the neurons it may use a day (6,000, about 10 chats; then chats wait for a person), the greeting on car pages after some seconds (off by default), how long chats and visits are kept (12 months and 90 days, as the privacy policy says).</p></section>');
select app.guide_release_0060('admin', 'settings', 'chapter', 'live-visitors-and-live-chat', 'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

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
6. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

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
7. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

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
  '<p class="gd-p">Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.</p><section class="gd-task" id="settings-the-settings-page" data-gd-task><h2 class="gd-h2">The Settings page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Site setup lists what is still missing on the public site, with <b class="gd-ui">Open site settings</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Program settings: every timing and policy value.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Forms: the official ServiceOntario PDFs and what goes in each field.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Insurers: insurance companies billed for bookings.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-24-settings-desktop-89b31691.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:32.6%;top:33%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.8%;top:40.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.4%;top:40.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:25.8%;top:73.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:25.8%;top:84.9%" aria-hidden="true">5</span></div></div></figure></div><p class="gd-p">The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Coverage prices, Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.</p></section><section class="gd-task" id="settings-program-settings" data-gd-task><h2 class="gd-h2">Program settings</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month&#39;s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press <b class="gd-ui">Save the defaults</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Change a value and press <b class="gd-ui">Save</b>. It is saved as a new row from today; the rows before stay as they were.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/program</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/admin-25-program-settings-desktop-d16b066c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:25.8%;top:22%" aria-hidden="true">1</span><span class="gd-pin" style="left:27.8%;top:49%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="settings-official-serviceontario-forms" data-gd-task><h2 class="gd-h2">Official ServiceOntario forms</h2><p class="gd-p">The five official forms are loaded with a draft mapping to the owner, car, company and lender details. Until you check a form, owners get a data sheet with the values.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. Each form shows &quot;Mapping to check&quot; (a draft is ready) or &quot;Official PDF in use&quot;. Its notes say what the form is for and which boxes are left blank on purpose.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download a filled preview</b> for one car and check each value against the form.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Change a field if needed: What goes in it (or &quot;The owner signs here&quot;), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for owners</b>. Every owner&#39;s form of that kind is filled again, except ones already signed or filed, and owners sign it with their other documents.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A new version from ServiceOntario? Press <b class="gd-ui">Upload the official fillable PDF</b>: the fields of the same name keep their mapping.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company&#39;s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner&#39;s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person.</div></aside></section><section class="gd-task" id="settings-agreements-to-sign-investors-and-staff" data-gd-task><h2 class="gd-h2">Agreements to sign: investors and staff</h2><p class="gd-p">Investment agreements and staff agreements are made from the person&#39;s record and signed in their own portal, or on paper.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Investor: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Investors</b> and the investor. Under Investment agreement, press <b class="gd-ui">Send the agreement to sign</b>. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press <b class="gd-ui">Send to sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Once the investor signs, the agreement shows <b class="gd-ui">Awaiting countersignature</b> on the investor&#39;s page and on To do. It is not countersigned automatically: check it and press <b class="gd-ui">Countersign</b>. CarmaCars is bound once it has countersigned and the funds clear.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Staff: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Staff</b>. Under Staff agreements, press <b class="gd-ui">Send the agreement to sign</b> beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A field staff member&#39;s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Your own PDF instead? <b class="gd-ui">Send a PDF to sign</b> still works.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Signed on paper instead? Press <b class="gd-ui">Record paper signature</b> in the same place and upload the scan.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Sent by mistake? Press <b class="gd-ui">Withdraw</b> and give the reason.</div></li></ol></div></section><section class="gd-task" id="settings-the-user-guides" data-gd-task><h2 class="gd-h2">The user guides</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Guides</b>. The guide of each portal, as people read it under Guide.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each guide shows its version, when it was published and whether there are unpublished changes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a guide and press a section. Change its text and press <b class="gd-ui">Show the preview</b> to see it as people will. Press <b class="gd-ui">Save the draft</b>; each save is kept in the section&#39;s history.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Move a section with the arrows, hide it, or press <b class="gd-ui">Add a chapter</b>. Upload a screenshot under Screenshots and paste the line it gives you.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Publish version</b> (the next number). The portals show the new version at once.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.</div></li></ol></div></section><section class="gd-task" id="settings-the-guides-keep-up-by-themselves" data-gd-task><h2 class="gd-h2">The guides keep up by themselves</h2><p class="gd-p">After every update of the site that changes the portals, the guides are checked without anyone asking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal&#39;s own labels and menu, checked, and published. The PDFs of those guides are printed again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Such a section says <b class="gd-ui">Changed automatically on</b> and the date, in the list of guides and in the guide&#39;s editor. Not right? Open the section and press <b class="gd-ui">Revert</b>: the text it replaced comes back, published at once.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section&#39;s history. There is nothing to review.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The card &quot;The guides keep up by themselves&quot; at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.</div></aside></section><section class="gd-task" id="settings-insurers-and-the-other-lists" data-gd-task><h2 class="gd-h2">Insurers and the other lists</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press <b class="gd-ui">Add</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.</div></li></ol></div></section>');
select app.guide_release_0060('va', 'your-workday', 'chapter', 'start-here', 'Every function works the same way: start on To do, take the oldest task, finish it, and check Today for pickups and returns. The menu keeps your own work first, then the screens of your function in a few groups.

## The menu

My work comes first: To do, Today, My scorecard and My sales. Then the groups of your function. The current group is open; press another to open it. On a phone the whole menu sits behind one Menu button.

| Function | Groups and pages |
| --- | --- |
| Customer service | Bookings (Requests, New quote, Add a rental, Calendar), Renters (Messages, Find a renter), Cars (Listings, Similar cars), Owners (Owners and enquiries, Owner forms) |
| Sales | Bookings (Requests and offers, New quote, Add a rental, Calendar), Owners (Owner leads) |
| Finance | Money (Payments, deposits and refunds, Tolls and tickets, Reconciliation, Turo trips), Renters and bookings (Find a renter, Calendar), Rentals (Add a rental, New quote) |
| Fleet | Field work (Field jobs, Daily checks, Photo reviews), Cars (Listings, Similar cars, Calendar), Renters (Find a renter), Rentals (Add a rental, New quote) |

## To do

Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more.

1. The top line shows your function and how many tasks are open.
2. Filter: All, Mine, Unassigned or Waiting; Any time, Overdue, Due today or Escalated; and by type.
3. Each row has a priority, the task, its record, when it is due and how long it has waited. The oldest due is first.
4. Press **Take it** to make it yours. **Sheet** opens the step-by-step procedure.

![](/guides/img/va-cs-01-queue-desktop-c36a8e2d.jpg "desktop; size: 1440 640; address: carmacars.ca/va; pins: 1 13.9 5.0, 2 36.1 17.5, 3 31.9 43.8, 4 91.7 52.3")

## Work a task

Open the task. The buttons along the top move it on.

| Button | What it does |
| --- | --- |
| **Open the working screen** | Jumps to the booking, car or owner the task is about. |
| **Done** | You finished it. It leaves the queue. |
| **Waiting** | You are waiting on someone (a renter, an owner). It stays yours. |
| **Escalate** | It needs an Admin. Add why. |
| **Hand over** | Give it to someone else on the team. |
| **Add a note** | Leave a note for whoever looks next. |

> Tip: Work oldest due first. A task meets its target when it is done by its due time; that is what your scorecard counts.

## Today

1. Today lists pickups and returns, and what is due, for your function.
2. Press a booking number to open it. **To do** takes you back to your tasks.

![](/guides/img/va-cs-02-today-desktop-dfd277b7.jpg "desktop; size: 1440 700; address: carmacars.ca/va/today; pins: 1 20.8 14.3")

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. The queue shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, hours, rate and start date), then press **Read the PDF** and read it.
3. Press **Sign**. Your full legal name is your signature (or press **Draw instead**). Several documents? One signature covers all of them. The signed copy stays on the same page.

## Several functions? Switch with Working as

If you cover more than one function, **Working as** above the menu lists them: Customer service, Finance, Fleet and Sales. Choose one; the menu, To do and Today change to that function.

## Your scorecard

1. Open **My work** > **My scorecard**.
2. By week shows each measure, its target and your result for each week.
3. A task meets its target when done by its due time. Daily checks count when done by 9:00 and 18:00.
4. The first reply target is 5 minutes: a new booking request, an enquiry, a change the renter asked for or a renter message is due 5 minutes after it comes in. An Admin sets it in Program settings, and the target column shows the one in force.

![](/guides/img/va-sales-05-scorecard-desktop-78ec1b03.jpg "desktop; size: 1440 360; address: carmacars.ca/va/scorecard; pins: 1 4.2 39.7, 2 62.5 58.3")
', 'Your workday', 'The menu, To do, task actions, Today, switching functions and your scorecard.',
  'Every function works the same way: start on To do, take the oldest task, finish it, and check Today for pickups and returns. The menu keeps your own work first, then the screens of your function in a few groups.

## The menu

My work comes first: To do, Today, My scorecard and My sales (customer service and Sales also have Live visitors and Live chat). Then the groups of your function. The current group is open; press another to open it. On a phone the whole menu sits behind one Menu button.

| Function | Groups and pages |
| --- | --- |
| Customer service | Bookings (Requests, New quote, Add a rental, Calendar), Renters (Messages, Find a renter), Cars (Listings, Similar cars), Owners (Owners and enquiries, Owner forms) |
| Sales | Bookings (Requests and offers, New quote, Add a rental, Calendar), Owners (Owner leads) |
| Finance | Money (Payments, deposits and refunds, Tolls and tickets, Reconciliation, Turo trips), Renters and bookings (Find a renter, Calendar), Rentals (Add a rental, New quote) |
| Fleet | Field work (Field jobs, Daily checks, Photo reviews), Cars (Listings, Similar cars, Calendar), Renters (Find a renter), Rentals (Add a rental, New quote) |

## To do

Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more.

1. The top line shows your function and how many tasks are open.
2. Filter: All, Mine, Unassigned or Waiting; Any time, Overdue, Due today or Escalated; and by type.
3. Each row has a priority, the task, its record, when it is due and how long it has waited. The oldest due is first.
4. Press **Take it** to make it yours. **Sheet** opens the step-by-step procedure.

![](/guides/img/va-cs-01-queue-desktop-c36a8e2d.jpg "desktop; size: 1440 640; address: carmacars.ca/va; pins: 1 13.9 5.0, 2 36.1 17.5, 3 31.9 43.8, 4 91.7 52.3")

## Work a task

Open the task. The buttons along the top move it on.

| Button | What it does |
| --- | --- |
| **Open the working screen** | Jumps to the booking, car or owner the task is about. |
| **Done** | You finished it. It leaves the queue. |
| **Waiting** | You are waiting on someone (a renter, an owner). It stays yours. |
| **Escalate** | It needs an Admin. Add why. |
| **Hand over** | Give it to someone else on the team. |
| **Add a note** | Leave a note for whoever looks next. |

> Tip: Work oldest due first. A task meets its target when it is done by its due time; that is what your scorecard counts.

## Today

1. Today lists pickups and returns, and what is due, for your function.
2. Press a booking number to open it. **To do** takes you back to your tasks.

![](/guides/img/va-cs-02-today-desktop-dfd277b7.jpg "desktop; size: 1440 700; address: carmacars.ca/va/today; pins: 1 20.8 14.3")

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. The queue shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, hours, rate and start date), then press **Read the PDF** and read it.
3. Press **Sign**. Your full legal name is your signature (or press **Draw instead**). Several documents? One signature covers all of them. The signed copy stays on the same page.

## Several functions? Switch with Working as

If you cover more than one function, **Working as** above the menu lists them: Customer service, Finance, Fleet and Sales. Choose one; the menu, To do and Today change to that function.

## Your scorecard

1. Open **My work** > **My scorecard**.
2. By week shows each measure, its target and your result for each week.
3. A task meets its target when done by its due time. Daily checks count when done by 9:00 and 18:00.
4. The first reply target is 5 minutes: a new booking request, an enquiry, a change the renter asked for or a renter message is due 5 minutes after it comes in. An Admin sets it in Program settings, and the target column shows the one in force.

![](/guides/img/va-sales-05-scorecard-desktop-78ec1b03.jpg "desktop; size: 1440 360; address: carmacars.ca/va/scorecard; pins: 1 4.2 39.7, 2 62.5 58.3")
',
  '<p class="gd-p">Every function works the same way: start on To do, take the oldest task, finish it, and check Today for pickups and returns. The menu keeps your own work first, then the screens of your function in a few groups.</p><section class="gd-task" id="your-workday-the-menu" data-gd-task><h2 class="gd-h2">The menu</h2><p class="gd-p">My work comes first: To do, Today, My scorecard and My sales (customer service and Sales also have Live visitors and Live chat). Then the groups of your function. The current group is open; press another to open it. On a phone the whole menu sits behind one Menu button.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Function</th><th scope="col">Groups and pages</th></tr></thead><tbody><tr><td>Customer service</td><td>Bookings (Requests, New quote, Add a rental, Calendar), Renters (Messages, Find a renter), Cars (Listings, Similar cars), Owners (Owners and enquiries, Owner forms)</td></tr><tr><td>Sales</td><td>Bookings (Requests and offers, New quote, Add a rental, Calendar), Owners (Owner leads)</td></tr><tr><td>Finance</td><td>Money (Payments, deposits and refunds, Tolls and tickets, Reconciliation, Turo trips), Renters and bookings (Find a renter, Calendar), Rentals (Add a rental, New quote)</td></tr><tr><td>Fleet</td><td>Field work (Field jobs, Daily checks, Photo reviews), Cars (Listings, Similar cars, Calendar), Renters (Find a renter), Rentals (Add a rental, New quote)</td></tr></tbody></table></div></section><section class="gd-task" id="your-workday-to-do" data-gd-task><h2 class="gd-h2">To do</h2><p class="gd-p">Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The top line shows your function and how many tasks are open.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Filter: All, Mine, Unassigned or Waiting; Any time, Overdue, Due today or Escalated; and by type.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each row has a priority, the task, its record, when it is due and how long it has waited. The oldest due is first.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Take it</b> to make it yours. <b class="gd-ui">Sheet</b> opens the step-by-step procedure.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/640"><img src="/guides/img/va-cs-01-queue-desktop-c36a8e2d.jpg" alt="" loading="lazy" decoding="async" width="1440" height="640"><span class="gd-pin" style="left:13.9%;top:5%" aria-hidden="true">1</span><span class="gd-pin" style="left:36.1%;top:17.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:31.9%;top:43.8%" aria-hidden="true">3</span><span class="gd-pin" style="left:91.7%;top:52.3%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="your-workday-work-a-task" data-gd-task><h2 class="gd-h2">Work a task</h2><p class="gd-p">Open the task. The buttons along the top move it on.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Button</th><th scope="col">What it does</th></tr></thead><tbody><tr><td><b class="gd-ui">Open the working screen</b></td><td>Jumps to the booking, car or owner the task is about.</td></tr><tr><td><b class="gd-ui">Done</b></td><td>You finished it. It leaves the queue.</td></tr><tr><td><b class="gd-ui">Waiting</b></td><td>You are waiting on someone (a renter, an owner). It stays yours.</td></tr><tr><td><b class="gd-ui">Escalate</b></td><td>It needs an Admin. Add why.</td></tr><tr><td><b class="gd-ui">Hand over</b></td><td>Give it to someone else on the team.</td></tr><tr><td><b class="gd-ui">Add a note</b></td><td>Leave a note for whoever looks next.</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Work oldest due first. A task meets its target when it is done by its due time; that is what your scorecard counts.</div></aside></section><section class="gd-task" id="your-workday-today" data-gd-task><h2 class="gd-h2">Today</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Today lists pickups and returns, and what is due, for your function.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press a booking number to open it. <b class="gd-ui">To do</b> takes you back to your tasks.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/today</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/700"><img src="/guides/img/va-cs-02-today-desktop-dfd277b7.jpg" alt="" loading="lazy" decoding="async" width="1440" height="700"><span class="gd-pin" style="left:20.8%;top:14.3%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="your-workday-documents-to-sign" data-gd-task><h2 class="gd-h2">Documents to sign</h2><p class="gd-p">Your staff agreement, when CarmaCars sends it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The queue shows &quot;You have a document to sign&quot;. Press <b class="gd-ui">Read and sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the key values at the top (your role, hours, rate and start date), then press <b class="gd-ui">Read the PDF</b> and read it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Sign</b>. Your full legal name is your signature (or press <b class="gd-ui">Draw instead</b>). Several documents? One signature covers all of them. The signed copy stays on the same page.</div></li></ol></div></section><section class="gd-task" id="your-workday-several-functions-switch-with-working-as" data-gd-task><h2 class="gd-h2">Several functions? Switch with Working as</h2><p class="gd-p">If you cover more than one function, <b class="gd-ui">Working as</b> above the menu lists them: Customer service, Finance, Fleet and Sales. Choose one; the menu, To do and Today change to that function.</p></section><section class="gd-task" id="your-workday-your-scorecard" data-gd-task><h2 class="gd-h2">Your scorecard</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">My work</b> &gt; <b class="gd-ui">My scorecard</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">By week shows each measure, its target and your result for each week.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A task meets its target when done by its due time. Daily checks count when done by 9:00 and 18:00.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The first reply target is 5 minutes: a new booking request, an enquiry, a change the renter asked for or a renter message is due 5 minutes after it comes in. An Admin sets it in Program settings, and the target column shows the one in force.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/scorecard</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/360"><img src="/guides/img/va-sales-05-scorecard-desktop-78ec1b03.jpg" alt="" loading="lazy" decoding="async" width="1440" height="360"><span class="gd-pin" style="left:4.2%;top:39.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:62.5%;top:58.3%" aria-hidden="true">2</span></div></div></figure></div></section>');
select app.guide_release_0060('va', 'live-visitors-and-live-chat', 'chapter', 'commissions', null, 'Live visitors and live chat', 'Who is on the site, buying signals, follow-ups, the chat inbox, take over and hand back.',
  'Customer service and Sales see who is on the site now and answer the live chat. The CarmaCars assistant answers first; you take over whenever you want.

## Live visitors

1. Open **My work** > **Live visitors**. Each visitor shows a name when known, otherwise "Visitor from Toronto, phone", the page and car they are on, and this visit''s pages.
2. Badges are buying signals: "Viewing spree: 6 cars in 10 minutes", "Opened offer CC-1042, not answered", "Left the pay page", "Started a request and stopped" and more.
3. Press **Pages** for the whole visit. Press **Start a chat**, write a short friendly message and press **Send**: the visitor sees it in a bubble.

## Follow-ups

Signals of known visitors raise tasks on To do with what to do, for example "Call or message Maya Chen: opened offer CC-1042 twice, no answer for 6 hours". Call or message, then mark the task done. A task closes by itself when the renter answers or pays. Follow-ups done count in My sales.

## Live chat

1. Open **My work** > **Live chat**. The menu counts chats waiting for a person. Reply within 5 minutes.
2. Choose a conversation. Beside it: the visitor''s page, pages and signals, and the renter''s bookings when known.
3. Press **Take over** (or just write a reply): the assistant stops. Write and press **Send** or Enter. The visitor sees when you type.
4. **Hand back to the assistant** when you are done, or **Close**. A visitor who gave an email gets a copy of the chat.
5. Tick "Email me when a chat waits (while I am on shift)" or desktop alerts if you want them.

> Tip: Prices: send a quote from New quote, never a price from memory. If you handled the chat, choose "I sourced this client" on the quote; nothing is credited by itself.
',
  '<p class="gd-p">Customer service and Sales see who is on the site now and answer the live chat. The CarmaCars assistant answers first; you take over whenever you want.</p><section class="gd-task" id="live-visitors-and-live-chat-live-visitors" data-gd-task><h2 class="gd-h2">Live visitors</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">My work</b> &gt; <b class="gd-ui">Live visitors</b>. Each visitor shows a name when known, otherwise &quot;Visitor from Toronto, phone&quot;, the page and car they are on, and this visit&#39;s pages.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Badges are buying signals: &quot;Viewing spree: 6 cars in 10 minutes&quot;, &quot;Opened offer CC-1042, not answered&quot;, &quot;Left the pay page&quot;, &quot;Started a request and stopped&quot; and more.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Pages</b> for the whole visit. Press <b class="gd-ui">Start a chat</b>, write a short friendly message and press <b class="gd-ui">Send</b>: the visitor sees it in a bubble.</div></li></ol></div></section><section class="gd-task" id="live-visitors-and-live-chat-follow-ups" data-gd-task><h2 class="gd-h2">Follow-ups</h2><p class="gd-p">Signals of known visitors raise tasks on To do with what to do, for example &quot;Call or message Maya Chen: opened offer CC-1042 twice, no answer for 6 hours&quot;. Call or message, then mark the task done. A task closes by itself when the renter answers or pays. Follow-ups done count in My sales.</p></section><section class="gd-task" id="live-visitors-and-live-chat-live-chat" data-gd-task><h2 class="gd-h2">Live chat</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">My work</b> &gt; <b class="gd-ui">Live chat</b>. The menu counts chats waiting for a person. Reply within 5 minutes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose a conversation. Beside it: the visitor&#39;s page, pages and signals, and the renter&#39;s bookings when known.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Take over</b> (or just write a reply): the assistant stops. Write and press <b class="gd-ui">Send</b> or Enter. The visitor sees when you type.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Hand back to the assistant</b> when you are done, or <b class="gd-ui">Close</b>. A visitor who gave an email gets a copy of the chat.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Tick &quot;Email me when a chat waits (while I am on shift)&quot; or desktop alerts if you want them.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Prices: send a quote from New quote, never a price from memory. If you handled the chat, choose &quot;I sourced this client&quot; on the quote; nothing is credited by itself.</div></aside></section>');
-- GUIDES 0060 END
