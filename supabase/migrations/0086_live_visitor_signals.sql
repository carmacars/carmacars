-- 0086_live_visitor_signals.sql
-- The owner's request of October 21, 2026 (docs/changes/2026-10-21-live-visitor-signals.md): "The signals for live
-- visitors can be improved. They're too basic right now. We need more useful and more creative signals."
--
--   A. Signals that tell staff who is likely to book, why, and what to say. 29 rules in five groups (intent, urgency,
--      value, hesitation, context) computed in the database from the events already collected plus seven new
--      low-cost events (the price shown, the booking form step reached, a question opened, a tap to call or message,
--      photos looked through, sorting and filters, a form error or repeated taps), and a flag for an ad click (the
--      click id itself is never sent). Each signal has a label, a short "why", a strength, and a suggested action
--      with a message to send. The six 0060 signals take part too.
--   B. A booking likelihood score from 0 to 100 per visit: the sum of the weights of its signals, with the top three
--      reasons. The Live visitors list is sorted by it; "hot" visits are highlighted and counted in the menu, and staff
--      with Live visitors or Live chat open get an in-app alert (a desktop alert only if they turned it on, never in
--      the quiet hours of the site check). No email.
--   C. One-click actions: invite to chat with the suggested message, send a single-use discount code in the chat
--      (Admins and Sales by default, a daily limit per person), assign the visitor to Sales (a task when we know who
--      they are), suggest a similar car that is free for their dates. Every action is logged on the visit.
--   D. Per car: people looking now, prices shown, the cars most often compared with it (counted per day, no person).
--   E. Every threshold, weight, message and the score bands are Admin settings (Live visitors > Signal settings).
--   F. CPU: signals are computed on ingest for the session that sent events, and every 5 minutes for visits active in
--      the last hour (time-based rules); the Live page only reads stored rows.
--   G. Privacy: the new events are analytics, recorded only with the analytics choice, as the beacon already does. No
--      keystrokes, no form values, no session recording, no network address. Privacy policy section 10 lists them
--      (flagged for the lawyer).
-- No applied migration is edited. Every new table has row-level security with the Admin policy; the browser reaches
-- them only through the functions below.

-- ================================================================ 1. the rules and their settings
create table visitor_signal_rules (
  code        text primary key check (code ~ '^[a-z][a-z0-9_]*$'),
  grp         text not null check (grp in ('intent', 'urgency', 'value', 'hesitation', 'context')),
  label       text not null check (length(label) between 2 and 80),
  explain     text not null default '',                          -- what the rule looks for, shown in the settings
  enabled     boolean not null default true,
  weight      integer not null default 0 check (weight between -50 and 100),
  t1          numeric check (t1 >= 0),                           -- the rule's first threshold (see explain)
  t2          numeric check (t2 >= 0),                           -- its second threshold, when it has one
  t1_label    text,
  t2_label    text,
  param       text,                                              -- a list the rule uses (classes, email domains)
  param_label text,
  action      text not null default 'chat' check (action in ('chat', 'discount', 'assign', 'similar', 'none')),
  message     text not null default '' check (length(message) <= 600),
  scope       text not null default 'session' check (scope in ('session', 'visitor')),
  legacy      boolean not null default false,                    -- a 0060 signal: raised by its own rule in Program settings
  sort        integer not null default 100,
  updated_at  timestamptz not null default now(),
  updated_by  uuid references users (id)
);
comment on table visitor_signal_rules is 'Live visitors (0086): one row per signal. Admins change the weight (points towards the booking likelihood), thresholds, the suggested action and its message in Live visitors > Signal settings.';

create table visitor_signal_config (
  id                     boolean primary key default true check (id),
  hot_score              integer not null default 60 check (hot_score between 1 and 100),
  warm_score             integer not null default 30 check (warm_score between 0 and 100),
  strong_weight          integer not null default 15 check (strong_weight between 1 and 100),
  medium_weight          integer not null default 8 check (medium_weight between 1 and 100),
  notify_hot             boolean not null default true,
  discount_enabled       boolean not null default true,
  discount_percent       integer not null default 10 check (discount_percent between 1 and 50),
  discount_max_cents     bigint check (discount_max_cents is null or discount_max_cents > 0) default 7500,
  discount_valid_days    integer not null default 3 check (discount_valid_days between 1 and 60),
  discount_daily_cap     integer not null default 10 check (discount_daily_cap between 0 and 200),
  discount_cs            boolean not null default false,
  discount_message       text not null default 'Hi{first_name_sp}! Here is {percent}% off the rental charge of your booking with the code {code}. It works once, until {valid_until}. Add it in the promo code box of the request form.' check (length(discount_message) <= 600),
  updated_at             timestamptz not null default now(),
  updated_by             uuid references users (id),
  check (warm_score < hot_score),
  check (medium_weight < strong_weight)
);
insert into visitor_signal_config default values;
comment on table visitor_signal_config is 'Live visitors (0086): the score bands (hot, warm), the strength of a signal by its weight, the hot alert, and the discount code staff may send (percent, cap, days valid, a daily limit per person, customer service allowed or not).';

insert into visitor_signal_rules (code, grp, label, explain, weight, t1, t2, t1_label, t2_label, param, param_label, action, message, scope, legacy, sort) values
  -- intent
  ('dates_repeat', 'intent', 'Searching dates again and again', 'Searched dates this many times in one visit.', 10, 3, null, 'Searches', null, null, null, 'chat',
   'Hi! I see you are checking a few dates. Tell me your trip and I will find you a car that is free and the best price.', 'session', false, 10),
  ('price_seen', 'intent', 'Saw the full price', 'The price for their dates was shown on a car page or the request form.', 10, null, null, null, null, null, null, 'chat',
   'Hi! Any question about the price for the {car}? I can explain what is included and how the deposit works.', 'session', false, 11),
  ('form_reached', 'intent', 'Reached the booking form', 'Started the request form (the step reached is in the why).', 15, null, null, null, null, null, null, 'chat',
   'Hi! I am here if you need a hand with your request for the {car}. There is no payment until we confirm and you approve.', 'session', false, 12),
  ('same_car_return', 'intent', 'Came back for the same car', 'Looked at a car they had already looked at on an earlier day.', 15, null, null, null, null, null, null, 'chat',
   'Welcome back! Still thinking about the {car}? Tell me your dates and I will check it for you.', 'session', false, 13),
  ('comparing', 'intent', 'Comparing cars', 'Went back and forth between a few cars: at least this many returns to a car already seen, among no more than this many cars.', 8, 2, 4, 'Returns', 'Cars at most', null, null, 'chat',
   'Hi! Choosing between the {car} and the {other}? Happy to help you decide.', 'session', false, 14),
  ('policy_check', 'intent', 'Read the cancellation policy', 'Opened the cancellation policy or a question about cancelling: often the last check before booking.', 10, null, null, null, null, null, null, 'chat',
   'Hi! Any question about cancelling before you book? I can explain our policy.', 'session', false, 15),
  ('help_read', 'intent', 'Read the rules', 'Opened the requirements, the FAQ or a question about the price, deposit, insurance, kilometres or requirements.', 6, null, null, null, null, null, null, 'chat',
   'Hi! Any question about {topics}? I can answer here.', 'session', false, 16),
  ('contact_tap', 'intent', 'Tapped to call or message', 'Tapped our phone, WhatsApp, text or email link, or copied our phone number.', 20, null, null, null, null, null, null, 'chat',
   'Hi! If it is easier than calling, I am right here in the chat.', 'session', false, 17),
  ('delivery_check', 'intent', 'Checked delivery', 'Priced delivery or read the delivery page.', 6, null, null, null, null, null, null, 'chat',
   'Hi! Want the {car} delivered? Tell me the address and I will confirm the delivery price.', 'session', false, 18),
  ('photo_dwell', 'intent', 'Looked closely at one car', 'Looked through this many photos of a car, or stayed on its page this many seconds.', 8, 6, 90, 'Photos', 'Seconds on the page', null, null, 'chat',
   'Hi! Want more photos or details of the {car}? I can send them.', 'session', false, 19),
  -- urgency
  ('soon_pickup', 'urgency', 'Pickup soon', 'The pickup date searched is within this many hours.', 12, 72, null, 'Hours', null, null, null, 'chat',
   'Hi! Need a car soon? I can confirm the {car} for {pickup} quickly.', 'session', false, 20),
  ('weekend_trip', 'urgency', 'Weekend or holiday dates', 'A short trip starting Thursday to Saturday, or dates over a holiday.', 4, null, null, null, null, null, null, 'chat',
   'Hi! Planning a weekend trip? Weekends book up first; I can check the {car} for you now.', 'session', false, 21),
  ('late_night', 'urgency', 'On a phone late at night', 'On a phone between these hours (Toronto time) and looking at cars or dates.', 3, 22, 5, 'From hour', 'Until hour', null, null, 'chat',
   'Hi! I am here if you have a question about the {car}.', 'session', false, 22),
  ('local_search', 'urgency', 'Came from a local search', 'Landed on a city or model page, or the search terms say "near me".', 6, null, null, null, null, null, null, 'chat',
   'Hi! Looking for a car nearby? Tell me where and when, and I will find one that is free.', 'session', false, 23),
  -- value
  ('long_rental', 'value', 'Long rental', 'Searched at least this many days (weekly); the second number is monthly.', 12, 7, 28, 'Days', 'Days (monthly)', null, null, 'assign',
   'Hi! For {days} days our weekly and monthly rates apply. Want me to send you a price?', 'session', false, 30),
  ('premium_class', 'value', 'Premium car', 'Looked at a car in one of these classes.', 6, null, null, null, null, 'luxury,premium,exotic,suv,van', 'Classes (codes)', 'chat',
   'Hi! Questions about the {car}? I can tell you more and check your dates.', 'session', false, 31),
  ('extra_driver', 'value', 'Adding a driver', 'Priced an additional driver, or opened a question about one.', 4, null, null, null, null, null, null, 'chat',
   'Hi! Adding a driver is easy. I can explain the fee and what they need.', 'session', false, 32),
  ('young_driver', 'value', 'Asked about young drivers', 'Opened a question or a page about drivers under 25.', 0, null, null, null, null, null, null, 'chat',
   'Hi! Drivers under 25 can rent some of our cars. I can tell you which ones and the fee.', 'session', false, 33),
  ('business_email', 'value', 'Business email', 'Gave an email (chat, game or account) on a domain not in this list of personal email providers.', 6, null, null, null, null,
   'gmail.com,googlemail.com,hotmail.com,hotmail.ca,outlook.com,live.com,live.ca,msn.com,yahoo.com,yahoo.ca,ymail.com,icloud.com,me.com,mac.com,aol.com,proton.me,protonmail.com,gmx.com,mail.com,rogers.com,sympatico.ca,bell.net,shaw.ca,telus.net,cogeco.ca',
   'Personal email domains', 'assign', 'Hi! Renting for work? Tell me what you need and I will send you a quote.', 'session', false, 34),
  -- hesitation
  ('price_sensitive', 'hesitation', 'Watching the price', 'Sorted by lowest price, lowered the price limit, or changed filters this many times.', 0, 3, null, 'Filter changes', null, null, null, 'discount', '', 'session', false, 40),
  ('left_at_price', 'hesitation', 'Left after seeing the price', 'Saw the price and did not start a request: moved to another page, or this many minutes passed.', 0, 10, null, 'Minutes', null, null, null, 'discount', '', 'session', false, 41),
  ('deposit_worry', 'hesitation', 'Unsure about the deposit', 'Opened a question about the deposit and did not start a request.', 0, null, null, null, null, null, null, 'chat',
   'Hi! Any question about the deposit? I can explain how it works and when it comes back.', 'session', false, 42),
  ('friction', 'hesitation', 'Trouble with a form', 'A form showed at least this many errors, or they tapped again and again on something.', 5, 2, null, 'Errors', null, null, null, 'chat',
   'Hi! Is something not working? I can help, or take your request here in the chat.', 'session', false, 43),
  ('unavailable', 'hesitation', 'Dates not free', 'The car they priced is not free for their dates.', 5, null, null, null, null, null, null, 'similar',
   'Hi! The {car} is booked for those dates, but these are free: {similar}', 'session', false, 44),
  -- context
  ('from_ad', 'context', 'Came from an ad', 'Arrived from one of our ads (the ad click itself is not kept), or a paid campaign.', 4, null, null, null, null, null, null, 'none', '', 'session', false, 50),
  ('known_renter', 'context', 'Past renter', 'A renter with at least one finished trip.', 15, null, null, null, null, null, null, 'assign',
   'Welcome back{first_name_sp}! Want me to set up your next trip?', 'visitor', false, 51),
  ('open_offer', 'context', 'Has an offer waiting', 'A renter with an offer or a payment waiting.', 10, null, null, null, null, null, null, 'chat',
   'Hi{first_name_sp}! Any question about your booking {booking}? I can help you finish it.', 'visitor', false, 52),
  ('game_code', 'context', 'Has a game code to use', 'Claimed a discount game code that is still valid and not used.', 8, null, null, null, null, null, null, 'chat',
   'Hi{first_name_sp}! Your discount code is still waiting. Want help using it?', 'visitor', false, 53),
  ('popular_car', 'context', 'Popular car', 'The car they are on was looked at by at least this many people today.', 3, 5, null, 'People today', null, null, null, 'chat',
   'Hi! The {car} is popular today. Want me to check your dates before it goes?', 'session', false, 54),
  -- the 0060 signals: raised by their own rules (Program settings); here only their points, action and message
  ('offer_opened', 'intent', 'Opened the offer, not answered', 'The renter opened their offer (page or email) and did not answer. Its thresholds are in Program settings.', 25, null, null, null, null, null, null, 'chat',
   'Hi{first_name_sp}! Any question about your offer {booking}? I can help you approve it.', 'visitor', true, 60),
  ('proposal_opened', 'intent', 'Opened the change proposal', 'Opened the change proposal several times without an answer. Its thresholds are in Program settings.', 15, null, null, null, null, null, null, 'chat',
   'Hi{first_name_sp}! Any question about the change we proposed for {booking}?', 'visitor', true, 61),
  ('pay_left', 'hesitation', 'Left the pay page', 'Left the pay page without paying.', 25, null, null, null, null, null, null, 'chat',
   'Hi{first_name_sp}! Anything wrong with the payment for {booking}? I can help.', 'visitor', true, 62),
  ('request_stopped', 'hesitation', 'Started a request and stopped', 'Started the request form and did not send it.', 15, null, null, null, null, null, null, 'chat',
   'Hi! I saw your request for the {car} was not sent. Anything I can help with?', 'session', true, 63),
  ('returning', 'intent', 'Returning visitor', 'Several visits this week. Its threshold is in Program settings.', 10, null, null, null, null, null, null, 'chat',
   'Welcome back! Can I help you find the right car?', 'visitor', true, 64),
  ('viewing_spree', 'intent', 'Viewing spree', 'Many cars in a few minutes. Its thresholds are in Program settings.', 5, null, null, null, null, null, null, 'chat',
   'Hi! Looking at a few cars? Tell me your trip and I will suggest the best one.', 'session', true, 65);

-- ================================================================ 2. tables and columns
alter table visitor_events drop constraint if exists visitor_events_kind_check;
alter table visitor_events add constraint visitor_events_kind_check check (kind in ('page_view', 'page_leave', 'search', 'car_view', 'request_started', 'request_abandoned',
  'request_submitted', 'email_link_opened', 'offer_viewed', 'change_viewed', 'pay_viewed', 'pay_left', 'chat_opened',
  -- 0086 (analytics consent only)
  'quote_seen', 'request_step', 'help_open', 'contact_click', 'photos', 'browse', 'friction'));
comment on column visitor_events.data is 'The event''s details: dates searched, the email code, the booking number; since 0086 also the price shown (days, total, free or not, delivery, an extra driver), the form step, a question''s topic, how they contacted us (call, WhatsApp, text, email, copy), photos looked through, a sort or filter, a form error or repeated taps. Never what a visitor types.';

alter table visitor_sessions
  add column if not exists from_ad      boolean not null default false,
  add column if not exists score        smallint check (score between 0 and 100),
  add column if not exists score_reasons jsonb not null default '[]'::jsonb,
  add column if not exists score_at     timestamptz,
  add column if not exists hot_at       timestamptz,
  add column if not exists audience     text not null default 'renter' check (audience in ('renter', 'owner')),
  add column if not exists assigned_to  uuid references users (id) on delete set null,
  add column if not exists assigned_at  timestamptz;
comment on column visitor_sessions.from_ad is 'Live visitors (0086): the visit arrived with an ad click id in the address (Google or Microsoft Ads). Only this flag is kept, never the id.';
comment on column visitor_sessions.score is 'Live visitors (0086): booking likelihood, 0 to 100: the sum of the points of the visit''s signals (visitor_signal_rules.weight), capped. Empty for owners and staff pages.';
comment on column visitor_sessions.hot_at is 'Live visitors (0086): when the score first reached the hot band (visitor_signal_config.hot_score).';
create index if not exists visitor_sessions_score_idx on visitor_sessions (score desc) where score is not null;
create index if not exists visitor_sessions_hot_idx on visitor_sessions (hot_at desc) where hot_at is not null;

-- the signals of one visit, computed from its events and the visitor's records (replaced on every evaluation)
create table visitor_live_signals (
  session_id uuid not null references visitor_sessions (id) on delete cascade,
  kind       text not null references visitor_signal_rules (code) on update cascade on delete cascade,
  visitor_id uuid not null,
  why        text not null,
  data       jsonb not null default '{}'::jsonb,
  vehicle_id uuid references vehicles (id) on delete set null,
  first_at   timestamptz not null default now(),
  last_at    timestamptz not null default now(),
  active     boolean not null default true,
  primary key (session_id, kind)
);
create index visitor_live_signals_recent_idx on visitor_live_signals (last_at desc) where active;
comment on table visitor_live_signals is 'Live visitors (0086): the signals of one visit, worked out by app.visitor_live_eval from its events. A signal whose reason passed is kept inactive.';

-- what staff did about a visit: the invitation, a discount code, an assignment
create table visitor_actions (
  id            uuid primary key default gen_random_uuid(),
  session_id    uuid references visitor_sessions (id) on delete set null,
  visitor_id    uuid not null,
  action        text not null check (action in ('chat', 'discount', 'assign', 'similar')),
  signal        text,
  by_user       uuid not null references users (id),
  to_user       uuid references users (id),
  promo_code_id uuid references promo_codes (id) on delete set null,
  chat_id       uuid references chat_conversations (id) on delete set null,
  task_id       uuid references tasks (id) on delete set null,
  score         smallint,
  at            timestamptz not null default now()
);
create index visitor_actions_session_idx on visitor_actions (session_id, at desc);
create index visitor_actions_by_idx on visitor_actions (by_user, at desc);
comment on table visitor_actions is 'Live visitors (0086): each one-click action staff took on a visit (chat invitation, discount code, assignment to Sales, a similar car suggested).';

-- cars looked at in the same visit, per Toronto day (no person): the "most compared" alternatives
create table vehicle_pairs_daily (
  vehicle_a uuid not null references vehicles (id) on delete cascade,
  vehicle_b uuid not null references vehicles (id) on delete cascade,
  day       date not null,
  sessions  integer not null default 0,
  primary key (vehicle_a, vehicle_b, day),
  check (vehicle_a < vehicle_b)
);
comment on table vehicle_pairs_daily is 'Live visitors (0086): two cars viewed in the same visit, counted per Toronto day. No personal information; kept like the daily counts per car.';

alter table vehicle_interest_daily add column if not exists quotes integer not null default 0;
comment on column vehicle_interest_daily.quotes is 'Live visitors (0086): visits that were shown the price of this car for their dates (once a visit).';

-- the settings Admins change are audited; the visit rows are high-volume records like 0060's (no money, pricing or status)
create trigger audit_visitor_signal_rules after insert or update or delete on visitor_signal_rules for each row execute function app.audit_row();
create trigger audit_visitor_signal_config after insert or update or delete on visitor_signal_config for each row execute function app.audit_row();

do $$
declare t text;
begin
  foreach t in array array['visitor_signal_rules', 'visitor_signal_config', 'visitor_live_signals', 'visitor_actions', 'vehicle_pairs_daily'] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('revoke all on %I from anon, authenticated', t);
  end loop;
end $$;

-- ================================================================ 3. helpers
create or replace function app.visitor_sig_cfg() returns visitor_signal_config
language sql stable security definer set search_path = public, app as $$ select * from visitor_signal_config where id $$;

-- strength by points: 3 strong, 2 medium, 1 weak (0 for a rule worth nothing or less)
create or replace function app.visitor_strength(p_weight integer) returns smallint
language sql stable security definer set search_path = public, app as $$
  select (case when p_weight >= c.strong_weight then 3 when p_weight >= c.medium_weight then 2 when p_weight > 0 then 1 else 0 end)::smallint
    from visitor_signal_config c where c.id
$$;

create or replace function app.visitor_band(p_score integer) returns text
language sql stable security definer set search_path = public, app as $$
  select case when p_score is null then null when p_score >= c.hot_score then 'hot' when p_score >= c.warm_score then 'warm' else 'cold' end
    from visitor_signal_config c where c.id
$$;

-- A message with its {placeholders} filled; the ones left empty fall back to a plain word.
create or replace function app.visitor_fill(p_text text, p_vars jsonb) returns text
language plpgsql immutable as $$
declare
  v text := coalesce(p_text, '');
  k text;
  x text;
  d jsonb := jsonb_build_object('car', 'car', 'other', 'other car', 'days', 'a few', 'pickup', 'your dates', 'total', 'the price', 'booking', 'your booking',
    'topics', 'the rules', 'similar', 'a similar car', 'first_name', '', 'first_name_sp', '', 'n', '', 'code', '', 'percent', '', 'valid_until', '');
begin
  for k, x in select key, value from jsonb_each_text(d || jsonb_strip_nulls(coalesce(p_vars, '{}'::jsonb))) loop
    v := replace(v, '{' || k || '}', coalesce(x, ''));
  end loop;
  v := regexp_replace(v, '\{[a-z_]+\}', '', 'g');
  return btrim(regexp_replace(regexp_replace(v, '\s+([!?.,])', '\1', 'g'), '\s{2,}', ' ', 'g'));
end $$;

-- the help topic of a page
create or replace function app.visitor_path_topic(p text) returns text
language sql immutable as $$
  select case
    when p is null then null
    when p ~ '^/cancellation-policy' then 'cancel'
    when p ~ '^/requirements' then 'requirements'
    when p ~ '^/delivery' then 'delivery'
    when p ~ '^/faq' then 'faq'
    when p ~ '^/car-rental/young' then 'young'
    when p ~ '^/car-rental/(monthly|weekly)' then 'long'
  end
$$;

create or replace function app.visitor_topic_words(p text[]) returns text
language sql immutable as $$
  select coalesce(string_agg(w, ', ' order by o), 'the rules') from (
    select distinct on (w) w, o from (
      select case t when 'price' then 'the price' when 'deposit' then 'the deposit' when 'requirements' then 'the requirements'
                    when 'insurance' then 'insurance' when 'km' then 'kilometres' when 'faq' then 'our FAQ' end as w,
             case t when 'price' then 1 when 'deposit' then 2 when 'insurance' then 3 when 'requirements' then 4 when 'km' then 5 else 6 end as o
        from unnest(p) t) y where w is not null order by w, o) z
$$;

create or replace function app.visitor_date_words(p date) returns text
language sql immutable as $$ select to_char(p, 'FMMonth FMDD') $$;

-- ================================================================ 4. the beacon, with the new events
-- 0060's app.track_ingest, with: the seven 0086 events and their details (each detail checked against a short list;
-- anything else is dropped), the ad flag, the price shown counted per car and visit, the cars viewed together counted
-- per day, the signals of 0086 after 0060's.
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
  d jsonb;
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
  v_prev uuid[];
  v_ad boolean := coalesce(p ->> 'ad' in ('1', 'true'), false);
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
  v_keep := v_consent = 'analytics' or v_renter is not null or v_uid is not null or v_chat or s.id is not null;
  if not v_keep then
    return jsonb_build_object('ok', true, 'kept', false, 'cfg', app.chat_public_cfg(), 'invite', null);
  end if;

  if s.id is null then
    insert into visitor_sessions (id, visitor_id, user_id, renter_id, known_name, known_email, identified_by, consent, city, region, country, device,
                                  referrer, utm, landing_path, visit_number, from_ad)
    values (v_sid, v_vid, v_uid, v_renter, v_name, v_email, v_by, v_consent,
            left(nullif(p_geo ->> 'city', ''), 80), left(nullif(p_geo ->> 'region', ''), 80), left(nullif(p_geo ->> 'country', ''), 2),
            case when p ->> 'device' in ('phone', 'tablet', 'desktop') then p ->> 'device' end,
            case when v_consent = 'analytics' then left(nullif(p ->> 'ref', ''), 120) end,
            case when v_consent = 'analytics' and jsonb_typeof(p -> 'utm') = 'object' then
              (select coalesce(jsonb_object_agg(k, left(v, 120)), '{}'::jsonb) from jsonb_each_text(p -> 'utm') x(k, v) where k in ('source', 'medium', 'campaign', 'term', 'content')) else '{}'::jsonb end,
            case when v_consent = 'analytics' then left(p ->> 'landing', 300) end,
            1 + (select count(*) from visitor_sessions o where o.visitor_id = v_vid),
            v_consent = 'analytics' and v_ad)
    returning * into s;
    v_new := true;
  else
    update visitor_sessions set last_seen_at = now(), ended_at = null,
           consent = case when v_consent = 'analytics' then 'analytics' else consent end,
           from_ad = from_ad or (v_consent = 'analytics' and v_ad),
           user_id = coalesce(user_id, v_uid), renter_id = coalesce(renter_id, v_renter),
           known_name = coalesce(known_name, v_name), known_email = coalesce(known_email, v_email), identified_by = coalesce(identified_by, v_by)
     where id = v_sid returning * into s;
  end if;
  if s.renter_id is not null then
    update visitor_sessions set renter_id = s.renter_id, known_name = coalesce(known_name, s.known_name), known_email = coalesce(known_email, s.known_email)
     where visitor_id = v_vid and renter_id is null;
    update chat_conversations set renter_id = s.renter_id where visitor_id = v_vid and renter_id is null;
  end if;

  for e in select * from jsonb_array_elements(coalesce(p -> 'events', '[]'::jsonb)) limit 30 loop
    v_kind := e ->> 'k';
    v_path := left(split_part(e ->> 'path', '?', 1), 300);
    v_vehicle := null; v_booking := null; b := null;
    d := case when jsonb_typeof(e -> 'd') = 'object' then e -> 'd' else '{}'::jsonb end;
    if nullif(e ->> 'slug', '') is not null then
      select l.vehicle_id into v_vehicle from vehicle_listings l where l.slug = left(e ->> 'slug', 120);
    end if;
    if nullif(e ->> 'bn', '') is not null then
      select * into b from bookings where booking_number = left(e ->> 'bn', 30);
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
                      'offer_viewed', 'change_viewed', 'pay_viewed', 'pay_left', 'chat_opened',
                      'quote_seen', 'request_step', 'help_open', 'contact_click', 'photos', 'browse', 'friction') then continue; end if;
    v_transactional := v_kind in ('email_link_opened', 'offer_viewed', 'change_viewed', 'pay_viewed', 'pay_left', 'chat_opened');
    -- without analytics consent: the known customer's own booking pages and the chat only (never the 0086 events)
    if s.consent <> 'analytics' and not (v_transactional and (v_booking is not null or v_kind = 'chat_opened' or (v_kind = 'email_link_opened' and v_known is not null))) then continue; end if;
    if v_kind in ('offer_viewed', 'change_viewed', 'pay_viewed', 'pay_left') and v_booking is null then v_kind := 'page_view'; end if;
    if v_kind = 'email_link_opened' and v_booking is null and v_known is not null then
      v_booking := nullif(v_known ->> 'booking_id', '')::uuid;
      select * into b from bookings where id = v_booking;
    end if;
    -- an event of 0086 with none of its details is not kept
    if v_kind = 'help_open' and coalesce(d ->> 'topic', '') not in ('price', 'deposit', 'requirements', 'insurance', 'cancel', 'delivery', 'young', 'drivers', 'km', 'other') then continue; end if;
    if v_kind = 'contact_click' and coalesce(d ->> 'via', '') not in ('call', 'whatsapp', 'sms', 'email', 'copy') then continue; end if;
    if v_kind = 'request_step' and coalesce(d ->> 'step', '') !~ '^[1-9]$' then continue; end if;
    if v_kind = 'photos' and coalesce(d ->> 'n', '') !~ '^\d{1,3}$' then continue; end if;
    if v_kind = 'friction' and coalesce(d ->> 'type', '') not in ('error', 'rage') then continue; end if;
    if v_kind = 'browse' and coalesce(d ->> 'sort', '') not in ('price-asc', 'price-desc', 'other') and coalesce(d ->> 'filter', '') <> '1' and coalesce(d ->> 'maxp', '') <> '1' then continue; end if;
    if v_kind = 'quote_seen' and coalesce(d ->> 'days', '') !~ '^\d{1,3}$' then continue; end if;
    insert into visitor_events (session_id, kind, path, vehicle_id, booking_id, ms, data)
    values (v_sid, v_kind, v_path, v_vehicle, v_booking,
            case when (e ->> 'ms') ~ '^\d{1,9}$' then least((e ->> 'ms')::integer, 86400000) end,
            jsonb_strip_nulls(jsonb_build_object(
              'pickup', case when (d ->> 'pickup') ~ '^\d{4}-\d{2}-\d{2}' then left(d ->> 'pickup', 16) end,
              'return', case when (d ->> 'return') ~ '^\d{4}-\d{2}-\d{2}' then left(d ->> 'return', 16) end,
              'code', case when v_kind = 'email_link_opened' then v_known ->> 'code' end,
              'booking_number', case when v_booking is not null then b.booking_number end,
              'days', case when v_kind = 'quote_seen' then (d ->> 'days')::integer end,
              'total', case when v_kind = 'quote_seen' and (d ->> 'total') ~ '^\d{1,7}$' then (d ->> 'total')::integer end,
              'avail', case when v_kind = 'quote_seen' and d ->> 'avail' in ('0', '1') then d ->> 'avail' end,
              'deliv', case when v_kind = 'quote_seen' and d ->> 'deliv' = '1' then '1' end,
              'xdrv', case when v_kind = 'quote_seen' and d ->> 'xdrv' = '1' then '1' end,
              'step', case when v_kind = 'request_step' then (d ->> 'step')::integer end,
              'topic', case when v_kind = 'help_open' then d ->> 'topic' end,
              'via', case when v_kind = 'contact_click' then d ->> 'via' end,
              'n', case when v_kind = 'photos' then least((d ->> 'n')::integer, 200) end,
              'sort', case when v_kind = 'browse' and d ->> 'sort' in ('price-asc', 'price-desc', 'other') then d ->> 'sort' end,
              'filter', case when v_kind = 'browse' and d ->> 'filter' = '1' then '1' end,
              'maxp', case when v_kind = 'browse' and d ->> 'maxp' = '1' then '1' end,
              'type', case when v_kind = 'friction' then d ->> 'type' end)));
    v_n := v_n + 1;
    if v_kind in ('page_view', 'car_view', 'offer_viewed', 'change_viewed', 'pay_viewed', 'request_submitted') then
      update visitor_sessions set page_views = page_views + 1, current_path = v_path, current_vehicle_id = v_vehicle, current_booking_id = v_booking
       where id = v_sid;
    end if;
    if v_kind = 'car_view' then
      v_prev := coalesce((select cars_viewed from visitor_sessions where id = v_sid), '{}'::uuid[]);
      v_seen := v_vehicle = any (v_prev);
      insert into vehicle_interest_daily as x (vehicle_id, day, views, viewers)
      values (v_vehicle, v_day, 1, 1)
      on conflict (vehicle_id, day) do update set views = x.views + 1, viewers = x.viewers + case when v_seen then 0 else 1 end;
      if not v_seen then
        update visitor_sessions set cars_viewed = cars_viewed || v_vehicle where id = v_sid;
        -- the cars of this visit viewed together with this one (the first 20)
        insert into vehicle_pairs_daily as x (vehicle_a, vehicle_b, day, sessions)
        select least(o, v_vehicle), greatest(o, v_vehicle), v_day, 1 from unnest(v_prev[1:20]) o where o <> v_vehicle
        on conflict (vehicle_a, vehicle_b, day) do update set sessions = x.sessions + 1;
      end if;
    elsif v_kind = 'request_submitted' and v_vehicle is not null then
      insert into vehicle_interest_daily as x (vehicle_id, day, requests) values (v_vehicle, v_day, 1)
      on conflict (vehicle_id, day) do update set requests = x.requests + 1;
    elsif v_kind = 'quote_seen' and v_vehicle is not null
          and not exists (select 1 from visitor_events q where q.session_id = v_sid and q.kind = 'quote_seen' and q.vehicle_id = v_vehicle
                            and q.id < currval(pg_get_serial_sequence('visitor_events', 'id'))) then
      insert into vehicle_interest_daily as x (vehicle_id, day, quotes) values (v_vehicle, v_day, 1)
      on conflict (vehicle_id, day) do update set quotes = x.quotes + 1;
    end if;
  end loop;

  if v_n > 0 or v_new then
    perform app.visitor_signals_eval(v_sid);
    perform app.visitor_live_eval(v_sid);
  end if;

  select jsonb_build_object('token', c.token, 'number', c.number,
           'message', (select m.body from chat_messages m where m.conversation_id = c.id and m.sender = 'staff' order by m.id limit 1),
           'from', (select split_part(u.full_name, ' ', 1) from users u where u.id = c.started_by_staff))
    into v_invite
    from chat_conversations c
   where c.session_id = v_sid and c.started_by = 'staff' and c.status <> 'closed' and c.last_visitor_at is null
   order by c.created_at desc limit 1;
  return jsonb_build_object('ok', true, 'kept', true, 'known', s.renter_id is not null, 'events', v_n, 'invite', v_invite, 'cfg', app.chat_public_cfg());
end $$;

-- ================================================================ 5. the signals of a visit and its score
-- One pass over the visit's events (indexed by session), a few lookups on the visitor's records, then the set of
-- signals is replaced and the score stored. Called on ingest for the session that sent events, and by the 5-minute job.
create or replace function app.visitor_live_eval(p_session uuid, p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  c visitor_signal_config := app.visitor_sig_cfg();
  s visitor_sessions;
  R jsonb;
  a record;
  q record;
  srch record;
  v_out jsonb := '{}'::jsonb;              -- kind -> {why, data, vehicle}
  v_car uuid;
  v_carname text;
  v_first text;
  v_topics text[];
  v_pick date;
  v_ret date;
  v_days integer;
  v_n integer;
  v_x text;
  v_email text;
  v_other uuid;
  v_seq uuid[];
  v_returns integer := 0;
  v_cars integer;
  v_hour integer;
  v_score integer;
  v_reasons jsonb;
  v_owner boolean;
  i integer;
begin
  select * into s from visitor_sessions where id = p_session;
  if s.id is null then return null; end if;
  select jsonb_object_agg(code, jsonb_build_object('on', enabled, 't1', t1, 't2', t2, 'param', param)) into R from visitor_signal_rules;

  -- owners, investors and field staff on their portals are not renters: no score
  v_owner := (s.user_id is not null and s.renter_id is null and exists (select 1 from owners o where o.user_id = s.user_id))
          or exists (select 1 from visitor_events e where e.session_id = s.id and e.kind = 'page_view' and e.path ~ '^/(owner|investor|field)(/|$)');
  if v_owner then
    update visitor_live_signals set active = false where session_id = s.id and active;
    update visitor_sessions set audience = 'owner', score = null, score_reasons = '[]'::jsonb, score_at = p_now where id = s.id;
    return null;
  end if;

  select
    count(*) filter (where e.kind = 'search') as searches,
    max(e.at) filter (where e.kind = 'quote_seen') as quote_at,
    min(e.at) filter (where e.kind in ('request_started', 'request_step')) as form_first,
    max(e.at) filter (where e.kind in ('request_started', 'request_step', 'request_submitted')) as form_at,
    max((e.data ->> 'step')::integer) filter (where e.kind = 'request_step') as max_step,
    count(*) filter (where e.kind = 'request_started') as started,
    count(*) filter (where e.kind = 'contact_click') as contacts,
    string_agg(distinct e.data ->> 'via', ',') filter (where e.kind = 'contact_click') as vias,
    array_agg(distinct e.data ->> 'topic') filter (where e.kind = 'help_open') as topics,
    array_agg(distinct app.visitor_path_topic(e.path)) filter (where e.kind = 'page_view' and app.visitor_path_topic(e.path) is not null) as page_topics,
    count(*) filter (where e.kind = 'friction' and e.data ->> 'type' = 'error') as errors,
    count(*) filter (where e.kind = 'friction' and e.data ->> 'type' = 'rage') as rages,
    bool_or(e.kind = 'browse' and e.data ->> 'sort' = 'price-asc') as sort_price,
    bool_or(e.kind = 'browse' and e.data ? 'maxp') as maxp,
    count(*) filter (where e.kind = 'browse' and (e.data ? 'filter' or e.data ? 'maxp')) as filters,
    max((e.data ->> 'n')::integer) filter (where e.kind = 'photos') as photos,
    (array_agg(e.vehicle_id order by (e.data ->> 'n')::integer desc) filter (where e.kind = 'photos'))[1] as photo_car,
    max(e.ms) filter (where e.kind = 'page_leave' and e.vehicle_id is not null) as car_ms,
    (array_agg(e.vehicle_id order by e.ms desc) filter (where e.kind = 'page_leave' and e.vehicle_id is not null and e.ms is not null))[1] as dwell_car,
    count(*) filter (where e.kind in ('car_view', 'search', 'quote_seen')) as browsing,
    max(e.at) as last_at
    into a
    from visitor_events e where e.session_id = s.id;

  -- the latest price shown, and the latest dates searched
  select e.at, e.vehicle_id, e.data into q from visitor_events e where e.session_id = s.id and e.kind = 'quote_seen' order by e.at desc limit 1;
  select e.data, e.vehicle_id into srch from visitor_events e where e.session_id = s.id and e.kind = 'search' and e.data ? 'pickup' order by e.at desc limit 1;
  begin
    v_pick := left(srch.data ->> 'pickup', 10)::date; v_ret := left(srch.data ->> 'return', 10)::date;
  exception when others then v_pick := null; v_ret := null;
  end;
  v_days := coalesce((q.data ->> 'days')::integer, case when v_ret > v_pick then v_ret - v_pick end);
  v_car := coalesce(s.current_vehicle_id, q.vehicle_id, srch.vehicle_id, s.cars_viewed[cardinality(s.cars_viewed)]);
  v_carname := case when v_car is not null then app.vehicle_name(v_car) end;
  v_first := nullif(split_part(coalesce(s.known_name, (select r.legal_name from renters r where r.id = s.renter_id), ''), ' ', 1), '');
  -- the topics of the questions opened, the pages read and the visitor's chat messages (key words only)
  v_topics := array(select distinct t from unnest(coalesce(a.topics, '{}') || coalesce(a.page_topics, '{}') || coalesce((
    select array_agg(distinct w) from (
      select unnest(array[
        case when m.body ~* '\m(deposit|hold)\M' then 'deposit' end,
        case when m.body ~* '\m(insurance|coverage|insured)\M' then 'insurance' end,
        case when m.body ~* '(under 25|young driver|\m(18|19|20|21|22|23|24) ?(years? old|yo)\M)' then 'young' end,
        case when m.body ~* '\m(additional|second|extra|another|add a) driver' then 'drivers' end,
        case when m.body ~* '\mcancel' then 'cancel' end,
        case when m.body ~* '\mdeliver' then 'delivery' end]) as w
        from chat_messages m join chat_conversations cc on cc.id = m.conversation_id
       where cc.visitor_id = s.visitor_id and m.sender = 'visitor' and m.at > p_now - interval '7 days') z where w is not null), '{}')) t where t is not null);

  -- ------------------------------------------------ intent
  if (R -> 'dates_repeat' ->> 'on')::boolean and a.searches >= coalesce((R -> 'dates_repeat' ->> 't1')::numeric, 3) then
    v_out := v_out || jsonb_build_object('dates_repeat', jsonb_build_object('why', format('Searched dates %s times this visit', a.searches), 'data', jsonb_build_object('n', a.searches)));
  end if;
  if (R -> 'price_seen' ->> 'on')::boolean and q.at is not null then
    v_out := v_out || jsonb_build_object('price_seen', jsonb_build_object('vehicle', q.vehicle_id,
      'why', format('Saw %s for %s %s%s', coalesce('$' || to_char((q.data ->> 'total')::integer, 'FM999,999'), 'the price'), q.data ->> 'days',
                    case when (q.data ->> 'days')::integer = 1 then 'day' else 'days' end, coalesce(', ' || app.vehicle_name(q.vehicle_id), '')),
      'data', jsonb_build_object('total', '$' || to_char((q.data ->> 'total')::integer, 'FM999,999'), 'days', q.data ->> 'days')));
  end if;
  if (R -> 'form_reached' ->> 'on')::boolean and a.form_first is not null then
    v_out := v_out || jsonb_build_object('form_reached', jsonb_build_object('why',
      case when a.max_step is not null then format('Reached step %s of the request form', a.max_step) else 'Started the request form' end));
  end if;
  if (R -> 'same_car_return' ->> 'on')::boolean then
    select e.vehicle_id into v_other from visitor_events e
     where e.session_id = s.id and e.kind = 'car_view' and e.vehicle_id is not null
       and exists (select 1 from visitor_sessions o join visitor_events x on x.session_id = o.id
                    where o.visitor_id = s.visitor_id and o.id <> s.id and x.kind = 'car_view' and x.vehicle_id = e.vehicle_id
                      and app.local_date(x.at) < app.local_date(e.at))
     order by e.at desc limit 1;
    if v_other is not null then
      v_out := v_out || jsonb_build_object('same_car_return', jsonb_build_object('vehicle', v_other,
        'why', format('Looked at the %s again, first seen on an earlier day', app.vehicle_name(v_other)), 'data', jsonb_build_object('car', app.vehicle_name(v_other))));
    end if;
  end if;
  if (R -> 'comparing' ->> 'on')::boolean then
    v_seq := array(select e.vehicle_id from visitor_events e where e.session_id = s.id and e.kind = 'car_view' and e.vehicle_id is not null order by e.at limit 60);
    v_cars := (select count(distinct x) from unnest(v_seq) x);
    if cardinality(v_seq) > 1 then
      for i in 2 .. cardinality(v_seq) loop
        if v_seq[i] <> v_seq[i - 1] and v_seq[i] = any (v_seq[1:i - 1]) then v_returns := v_returns + 1; end if;
      end loop;
    end if;
    if v_cars between 2 and coalesce((R -> 'comparing' ->> 't2')::numeric, 4) and v_returns >= coalesce((R -> 'comparing' ->> 't1')::numeric, 2) then
      select x into v_other from unnest(v_seq) x group by x order by count(*) desc, max(array_position(v_seq, x)) desc limit 1;
      select x into v_car from unnest(v_seq) x where x <> v_other group by x order by count(*) desc limit 1;
      v_out := v_out || jsonb_build_object('comparing', jsonb_build_object('vehicle', v_other,
        'why', format('Went back and forth between the %s and the %s', app.vehicle_name(v_other), app.vehicle_name(v_car)),
        'data', jsonb_build_object('car', app.vehicle_name(v_other), 'other', app.vehicle_name(v_car))));
      v_car := coalesce(s.current_vehicle_id, v_other);
    end if;
  end if;
  if (R -> 'policy_check' ->> 'on')::boolean and 'cancel' = any (v_topics) then
    v_out := v_out || jsonb_build_object('policy_check', jsonb_build_object('why', 'Read about cancelling'));
  end if;
  if (R -> 'help_read' ->> 'on')::boolean and v_topics && array['price', 'deposit', 'requirements', 'insurance', 'km', 'faq'] then
    v_x := app.visitor_topic_words(v_topics);
    v_out := v_out || jsonb_build_object('help_read', jsonb_build_object('why', 'Read about ' || v_x, 'data', jsonb_build_object('topics', v_x)));
  end if;
  if (R -> 'contact_tap' ->> 'on')::boolean and a.contacts > 0 then
    v_out := v_out || jsonb_build_object('contact_tap', jsonb_build_object('why', 'Tapped to ' || (
      select string_agg(case w when 'call' then 'call' when 'whatsapp' then 'WhatsApp' when 'sms' then 'text' when 'email' then 'email' when 'copy' then 'copy our number' end, ', ')
        from unnest(string_to_array(a.vias, ',')) w)));
  end if;
  if (R -> 'delivery_check' ->> 'on')::boolean and ('delivery' = any (v_topics) or q.data ->> 'deliv' = '1') then
    v_out := v_out || jsonb_build_object('delivery_check', jsonb_build_object('why', case when q.data ->> 'deliv' = '1' then 'Priced delivery to an address' else 'Read about delivery' end));
  end if;
  if (R -> 'photo_dwell' ->> 'on')::boolean and (coalesce(a.photos, 0) >= coalesce((R -> 'photo_dwell' ->> 't1')::numeric, 6)
       or coalesce(a.car_ms, 0) >= 1000 * coalesce((R -> 'photo_dwell' ->> 't2')::numeric, 90)) then
    v_other := case when coalesce(a.photos, 0) >= coalesce((R -> 'photo_dwell' ->> 't1')::numeric, 6) then a.photo_car else a.dwell_car end;
    v_out := v_out || jsonb_build_object('photo_dwell', jsonb_build_object('vehicle', v_other,
      'why', case when coalesce(a.photos, 0) >= coalesce((R -> 'photo_dwell' ->> 't1')::numeric, 6)
                  then format('Looked through %s photos of the %s', a.photos, coalesce(app.vehicle_name(v_other), 'car'))
                  else format('Stayed %s on the %s', case when a.car_ms >= 120000 then (a.car_ms / 60000) || ' minutes' else (a.car_ms / 1000) || ' seconds' end, coalesce(app.vehicle_name(v_other), 'car page')) end,
      'data', jsonb_build_object('car', app.vehicle_name(v_other))));
  end if;

  -- ------------------------------------------------ urgency
  if (R -> 'soon_pickup' ->> 'on')::boolean and v_pick is not null and v_pick >= app.local_date(p_now)
     and app.local_midnight(v_pick) + interval '10 hours' <= p_now + make_interval(hours => coalesce((R -> 'soon_pickup' ->> 't1')::integer, 72)) then
    v_out := v_out || jsonb_build_object('soon_pickup', jsonb_build_object('why',
      format('Pickup %s', case v_pick - app.local_date(p_now) when 0 then 'today' when 1 then 'tomorrow' else 'on ' || to_char(v_pick, 'FMDay') || ', ' || app.visitor_date_words(v_pick) end),
      'data', jsonb_build_object('pickup', case v_pick - app.local_date(p_now) when 0 then 'today' when 1 then 'tomorrow' else app.visitor_date_words(v_pick) end)));
  end if;
  if (R -> 'weekend_trip' ->> 'on')::boolean and v_pick is not null and v_ret is not null and v_ret >= v_pick
     and ((extract(isodow from v_pick) in (4, 5, 6) and v_ret - v_pick <= 4)
          or exists (select 1 from holidays h where h.holiday_on between v_pick and least(v_ret, v_pick + 14))) then
    v_out := v_out || jsonb_build_object('weekend_trip', jsonb_build_object('why',
      coalesce((select 'Dates over ' || h.name from holidays h where h.holiday_on between v_pick and least(v_ret, v_pick + 14) order by h.holiday_on limit 1),
               format('%s to %s', to_char(v_pick, 'FMDay'), to_char(v_ret, 'FMDay')))));
  end if;
  v_hour := app.local_hour(coalesce(s.last_seen_at, p_now));
  if (R -> 'late_night' ->> 'on')::boolean and s.device = 'phone' and a.browsing > 0
     and (case when coalesce((R -> 'late_night' ->> 't1')::integer, 22) > coalesce((R -> 'late_night' ->> 't2')::integer, 5)
               then v_hour >= coalesce((R -> 'late_night' ->> 't1')::integer, 22) or v_hour < coalesce((R -> 'late_night' ->> 't2')::integer, 5)
               else v_hour >= coalesce((R -> 'late_night' ->> 't1')::integer, 22) and v_hour < coalesce((R -> 'late_night' ->> 't2')::integer, 5) end) then
    v_out := v_out || jsonb_build_object('late_night', jsonb_build_object('why', format('On a phone at %s', to_char(coalesce(s.last_seen_at, p_now) at time zone 'America/Toronto', 'FMHH12:MI am'))));
  end if;
  if (R -> 'local_search' ->> 'on')::boolean and (s.landing_path ~ '^/(car-rental|rent)/' or (s.utm ->> 'term') ~* 'near me|nearby|close to me') then
    v_out := v_out || jsonb_build_object('local_search', jsonb_build_object('why',
      case when (s.utm ->> 'term') ~* 'near me|nearby|close to me' then 'Searched "' || left(s.utm ->> 'term', 60) || '"' else 'Landed on ' || coalesce(app.path_label(s.landing_path), s.landing_path) || ' (' || s.landing_path || ')' end));
  end if;

  -- ------------------------------------------------ value
  if (R -> 'long_rental' ->> 'on')::boolean and v_days >= coalesce((R -> 'long_rental' ->> 't1')::numeric, 7) then
    v_out := v_out || jsonb_build_object('long_rental', jsonb_build_object('why',
      format('%s days%s', v_days, case when v_days >= coalesce((R -> 'long_rental' ->> 't2')::numeric, 28) then ' (monthly)' else ' (weekly)' end),
      'data', jsonb_build_object('days', v_days)));
  end if;
  if (R -> 'premium_class' ->> 'on')::boolean and nullif(R -> 'premium_class' ->> 'param', '') is not null then
    select x into v_other from unnest(s.cars_viewed || array_remove(array[q.vehicle_id], null)) x
     where app.vehicle_in_classes(x, string_to_array(replace(R -> 'premium_class' ->> 'param', ' ', ''), ','))
     order by array_position(s.cars_viewed, x) desc nulls first limit 1;
    if v_other is not null then
      v_out := v_out || jsonb_build_object('premium_class', jsonb_build_object('vehicle', v_other, 'why', format('Looked at the %s (%s)', app.vehicle_name(v_other),
        (select string_agg(k.label, ', ') from vehicle_class_links l join vehicle_classes k on k.code = l.class_code
          where l.vehicle_id = v_other and l.class_code = any (string_to_array(replace(R -> 'premium_class' ->> 'param', ' ', ''), ',')))),
        'data', jsonb_build_object('car', app.vehicle_name(v_other))));
    end if;
  end if;
  if (R -> 'extra_driver' ->> 'on')::boolean and ('drivers' = any (v_topics) or q.data ->> 'xdrv' = '1') then
    v_out := v_out || jsonb_build_object('extra_driver', jsonb_build_object('why', case when q.data ->> 'xdrv' = '1' then 'Priced an additional driver' else 'Asked about an additional driver' end));
  end if;
  if (R -> 'young_driver' ->> 'on')::boolean and 'young' = any (v_topics) then
    v_out := v_out || jsonb_build_object('young_driver', jsonb_build_object('why', 'Read about drivers under 25'));
  end if;
  if (R -> 'business_email' ->> 'on')::boolean then
    v_email := lower(coalesce(s.known_email,
      (select cc.email from chat_conversations cc where cc.visitor_id = s.visitor_id and cc.email is not null order by cc.created_at desc limit 1),
      (select g.email from game_claims g where g.visitor_id = s.visitor_id order by g.play_id limit 1),
      (select r.email from renters r where r.id = s.renter_id)));
    if v_email ~ '@' and not (split_part(v_email, '@', 2) = any (string_to_array(replace(lower(coalesce(R -> 'business_email' ->> 'param', '')), ' ', ''), ','))) then
      v_out := v_out || jsonb_build_object('business_email', jsonb_build_object('why', 'Email at ' || split_part(v_email, '@', 2)));
    end if;
  end if;

  -- ------------------------------------------------ hesitation
  if (R -> 'price_sensitive' ->> 'on')::boolean and (a.sort_price or a.maxp or a.filters >= coalesce((R -> 'price_sensitive' ->> 't1')::numeric, 3)) then
    v_out := v_out || jsonb_build_object('price_sensitive', jsonb_build_object('why',
      concat_ws(', ', case when a.sort_price then 'Sorted by lowest price' end, case when a.maxp then 'lowered the price limit' end,
                case when a.filters >= coalesce((R -> 'price_sensitive' ->> 't1')::numeric, 3) then format('changed filters %s times', a.filters) end)));
  end if;
  if (R -> 'left_at_price' ->> 'on')::boolean and q.at is not null and (a.form_at is null or a.form_at < q.at)
     and (exists (select 1 from visitor_events e where e.session_id = s.id and e.at > q.at + interval '2 seconds' and e.kind in ('page_view', 'car_view') and coalesce(e.path, '') !~ '^/book/')
          or s.last_seen_at < p_now - make_interval(mins => coalesce((R -> 'left_at_price' ->> 't1')::integer, 10))) then
    v_out := v_out || jsonb_build_object('left_at_price', jsonb_build_object('vehicle', q.vehicle_id,
      'why', format('Saw %s for the %s and did not start a request', coalesce('$' || to_char((q.data ->> 'total')::integer, 'FM999,999'), 'the price'), coalesce(app.vehicle_name(q.vehicle_id), 'car')),
      'data', jsonb_build_object('car', app.vehicle_name(q.vehicle_id))));
  end if;
  if (R -> 'deposit_worry' ->> 'on')::boolean and 'deposit' = any (v_topics) and a.form_at is null then
    v_out := v_out || jsonb_build_object('deposit_worry', jsonb_build_object('why', 'Read about the deposit, no request yet'));
  end if;
  if (R -> 'friction' ->> 'on')::boolean and (a.errors >= coalesce((R -> 'friction' ->> 't1')::numeric, 2) or a.rages > 0) then
    v_out := v_out || jsonb_build_object('friction', jsonb_build_object('why',
      concat_ws(', ', case when a.errors > 0 then format('%s form %s', a.errors, case when a.errors = 1 then 'error' else 'errors' end) end,
                case when a.rages > 0 then 'tapped again and again on something' end)));
  end if;
  if (R -> 'unavailable' ->> 'on')::boolean and q.data ->> 'avail' = '0' then
    v_out := v_out || jsonb_build_object('unavailable', jsonb_build_object('vehicle', q.vehicle_id,
      'why', format('The %s is not free%s', coalesce(app.vehicle_name(q.vehicle_id), 'car'), coalesce(' from ' || app.visitor_date_words(v_pick) || ' to ' || app.visitor_date_words(v_ret), '')),
      'data', jsonb_build_object('car', app.vehicle_name(q.vehicle_id))));
  end if;

  -- ------------------------------------------------ context
  if (R -> 'from_ad' ->> 'on')::boolean and (s.from_ad or lower(coalesce(s.utm ->> 'medium', '')) in ('cpc', 'ppc', 'paid', 'paidsocial', 'paid_social', 'display', 'ads')) then
    v_out := v_out || jsonb_build_object('from_ad', jsonb_build_object('why', case when s.from_ad then 'Clicked one of our ads' else 'Paid campaign ' || coalesce(s.utm ->> 'source', '') || coalesce('/' || (s.utm ->> 'campaign'), '') end));
  end if;
  if s.renter_id is not null then
    if (R -> 'known_renter' ->> 'on')::boolean then
      v_n := (select count(*) from bookings b where b.renter_id = s.renter_id and b.status in ('returned', 'closed'));
      if v_n > 0 then
        v_out := v_out || jsonb_build_object('known_renter', jsonb_build_object('why', format('%s finished %s with us', v_n, case when v_n = 1 then 'trip' else 'trips' end)));
      end if;
    end if;
    if (R -> 'open_offer' ->> 'on')::boolean then
      select b.booking_number into v_x from bookings b where b.renter_id = s.renter_id and b.status in ('offered', 'pending_payment') order by b.pickup_at limit 1;
      if v_x is not null then
        v_out := v_out || jsonb_build_object('open_offer', jsonb_build_object('why', format('Booking %s waits for them', v_x), 'data', jsonb_build_object('booking', v_x)));
      end if;
    end if;
  end if;
  if (R -> 'game_code' ->> 'on')::boolean then
    select pc.code, pc.valid_until into v_x, v_pick from game_claims g join promo_codes pc on pc.id = g.promo_code_id
     where g.visitor_id = s.visitor_id and pc.is_active and (pc.valid_until is null or pc.valid_until > p_now)
       and not exists (select 1 from promo_redemptions pr where pr.promo_code_id = pc.id and pr.status in ('applied', 'redeemed'))
     order by pc.valid_until nulls last limit 1;
    if v_x is not null then
      v_out := v_out || jsonb_build_object('game_code', jsonb_build_object('why', 'Code ' || v_x || coalesce(', valid until ' || app.visitor_date_words(v_pick), '')));
    end if;
  end if;
  if (R -> 'popular_car' ->> 'on')::boolean and s.current_vehicle_id is not null then
    v_n := coalesce((select viewers from vehicle_interest_daily x where x.vehicle_id = s.current_vehicle_id and x.day = app.local_date(p_now)), 0);
    if v_n >= coalesce((R -> 'popular_car' ->> 't1')::numeric, 5) then
      v_out := v_out || jsonb_build_object('popular_car', jsonb_build_object('vehicle', s.current_vehicle_id,
        'why', format('%s people looked at the %s today', v_n, app.vehicle_name(s.current_vehicle_id)), 'data', jsonb_build_object('car', app.vehicle_name(s.current_vehicle_id))));
    end if;
  end if;

  -- ------------------------------------------------ store: the set is replaced (first_at kept), the reasons gone become inactive
  insert into visitor_live_signals as g (session_id, kind, visitor_id, why, data, vehicle_id, first_at, last_at, active)
  select s.id, k, s.visitor_id, left(x ->> 'why', 200),
         jsonb_build_object('car', coalesce(v_carname, ''), 'first_name', v_first, 'first_name_sp', ' ' || v_first) || coalesce(x -> 'data', '{}'::jsonb),
         nullif(x ->> 'vehicle', '')::uuid, p_now, p_now, true
    from jsonb_each(v_out) y(k, x)
  on conflict (session_id, kind) do update set why = excluded.why, data = excluded.data, vehicle_id = excluded.vehicle_id, active = true,
    last_at = case when g.why is distinct from excluded.why or not g.active then excluded.last_at else g.last_at end,
    first_at = case when g.active then g.first_at else excluded.first_at end;
  update visitor_live_signals set active = false where session_id = s.id and active and not (v_out ? kind);

  -- the score: the points of every current signal of this visit (0086's and 0060's), capped to 0..100
  with cur as (
    select r.code, r.label, l.why, r.weight from visitor_live_signals l join visitor_signal_rules r on r.code = l.kind
     where l.session_id = s.id and l.active and r.enabled
    union all
    select r.code, g.label, g.label, r.weight from visitor_signals g join visitor_signal_rules r on r.code = g.kind
     where g.visitor_id = s.visitor_id and g.resolved_at is null and g.last_at > p_now - interval '7 days' and r.enabled
       and (r.scope = 'visitor' or g.session_id = s.id))
  select least(100, greatest(0, coalesce(sum(weight), 0)))::integer,
         coalesce((select jsonb_agg(jsonb_build_object('kind', code, 'label', label, 'why', why, 'weight', weight) order by weight desc, label)
                     from (select * from cur where weight > 0 order by weight desc, label limit 3) t), '[]'::jsonb)
    into v_score, v_reasons from cur;
  update visitor_sessions set score = v_score, score_reasons = v_reasons, score_at = p_now, audience = 'renter',
         hot_at = case when hot_at is null and v_score >= c.hot_score then p_now else hot_at end
   where id = s.id;
  return v_score;
end $$;

-- time-based rules (left after the price, a pickup getting closer) for visits active in the last hour, every 5 minutes
create or replace function app.job_visitor_signals(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  x uuid;
  v_n integer := 0;
begin
  if not (app.settings(app.local_date(p_now))).visitor_tracking_enabled then return 'off'; end if;
  for x in select s.id from visitor_sessions s
            where s.last_seen_at > p_now - interval '60 minutes' and (s.score_at is null or s.score_at < p_now - interval '4 minutes')
            order by s.last_seen_at desc limit 300 loop
    perform app.visitor_live_eval(x, p_now);
    v_n := v_n + 1;
  end loop;
  return 'evaluated ' || v_n;
end $$;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-visitor-signals', '*/5 * * * *', 'select app.job_visitor_signals()');
  end if;
end $$;

-- every signal of a visit for staff, strongest first: label, why, strength, the suggested action and its message
create or replace function app.visitor_signals_all(s visitor_sessions) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(x order by (x ->> 'weight')::integer desc, x ->> 'at' desc), '[]'::jsonb) from (
    select jsonb_build_object('kind', r.code, 'grp', r.grp, 'label', r.label, 'why', l.why, 'at', l.last_at, 'weight', r.weight,
             'strength', app.visitor_strength(r.weight), 'action', r.action, 'message', app.visitor_fill(r.message, l.data),
             'booking_number', null, 'task_id', null, 'source', 'live') as x
      from visitor_live_signals l join visitor_signal_rules r on r.code = l.kind
     where l.session_id = s.id and l.active and r.enabled
    union all
    select jsonb_build_object('kind', g.kind, 'grp', coalesce(r.grp, 'intent'), 'label', g.label, 'why', g.label, 'at', g.last_at, 'weight', coalesce(r.weight, 0),
             'strength', app.visitor_strength(coalesce(r.weight, 0)), 'action', coalesce(r.action, 'chat'),
             'message', app.visitor_fill(r.message, jsonb_build_object('booking', b.booking_number,
                          'car', case when coalesce(g.vehicle_id, s.current_vehicle_id) is not null then app.vehicle_name(coalesce(g.vehicle_id, s.current_vehicle_id)) end,
                          'first_name_sp', ' ' || nullif(split_part(coalesce(s.known_name, ''), ' ', 1), ''))),
             'booking_number', b.booking_number, 'task_id', g.task_id, 'source', '0060')
      from visitor_signals g left join bookings b on b.id = g.booking_id left join visitor_signal_rules r on r.code = g.kind
     where g.visitor_id = s.visitor_id and g.resolved_at is null and g.last_at > now() - interval '7 days' and coalesce(r.enabled, true)
       and (g.kind not in ('viewing_spree', 'request_stopped') or g.session_id = s.id)) y
$$;

-- ================================================================ 6. reads for staff
-- 0060's row, with the score, its band and reasons, the full signals, the suggested action, who it is assigned to,
-- the last action taken, the ad flag and the others looking at the same car now.
create or replace function app.visitor_session_row(s visitor_sessions) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with sig as (select app.visitor_signals_all(s) as j)
  select jsonb_build_object('id', s.id, 'visitor_id', s.visitor_id, 'who', app.visitor_who(s), 'known', s.renter_id is not null or s.known_email is not null,
    'renter_id', s.renter_id, 'email', s.known_email, 'identified_by', s.identified_by, 'consent', s.consent,
    'city', s.city, 'region', s.region, 'device', s.device, 'referrer', s.referrer, 'utm_source', s.utm ->> 'source', 'utm_campaign', s.utm ->> 'campaign',
    'utm_medium', s.utm ->> 'medium', 'from_ad', s.from_ad, 'landing', app.path_label(s.landing_path),
    'started_at', s.started_at, 'last_seen_at', s.last_seen_at, 'page_views', s.page_views, 'visit_number', s.visit_number,
    'current_path', s.current_path, 'current_page', app.path_label(s.current_path),
    'car', case when s.current_vehicle_id is not null then app.vehicle_name(s.current_vehicle_id) end, 'vehicle_id', s.current_vehicle_id,
    'booking_number', (select b.booking_number from bookings b where b.id = s.current_booking_id),
    'cars_viewed', cardinality(s.cars_viewed),
    'signals', sig.j,
    'score', s.score, 'band', app.visitor_band(s.score), 'reasons', s.score_reasons, 'hot_at', s.hot_at, 'audience', s.audience,
    'suggested', (select x from jsonb_array_elements(sig.j) x where x ->> 'action' <> 'none' and (x ->> 'message' <> '' or x ->> 'action' in ('discount', 'assign'))
                   order by (x ->> 'weight')::integer desc limit 1),
    'others_on_car', case when s.current_vehicle_id is not null then (select count(*) from visitor_sessions o where o.current_vehicle_id = s.current_vehicle_id and o.id <> s.id
                       and o.last_seen_at > now() - make_interval(mins => (app.settings()).visitor_live_minutes) and o.ended_at is null) end,
    'assigned', case when s.assigned_to is not null then jsonb_build_object('id', s.assigned_to, 'name', (select u.full_name from users u where u.id = s.assigned_to), 'at', s.assigned_at) end,
    'last_action', (select jsonb_build_object('action', va.action, 'at', va.at, 'by', split_part(u.full_name, ' ', 1)) from visitor_actions va join users u on u.id = va.by_user
                     where va.visitor_id = s.visitor_id and va.at > now() - interval '24 hours' order by va.at desc limit 1),
    'chat', (select jsonb_build_object('id', c.id, 'number', c.number, 'status', c.status) from chat_conversations c
              where c.visitor_id = s.visitor_id and c.status <> 'closed' order by c.created_at desc limit 1))
  from sig
$$;

create or replace function app.visitor_live_cfg(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('hot', c.hot_score, 'warm', c.warm_score, 'notify_hot', c.notify_hot,
    'discount', jsonb_build_object('enabled', c.discount_enabled, 'percent', c.discount_percent, 'days', c.discount_valid_days,
      'can', c.discount_enabled and (app.user_is_admin(p_by) or app.user_va_has(p_by, 'sales') or (c.discount_cs and app.user_va_has(p_by, 'cs')))),
    'is_admin', app.user_is_admin(p_by), 'quiet', app.uptime_quiet(now()),
    'me', (select split_part(u.full_name, ' ', 1) from users u where u.id = p_by),
    'alerts', coalesce((select x.desktop_alerts from chat_staff_prefs x where x.user_id = p_by), false))
    from visitor_signal_config c where c.id
$$;

create or replace function app.live_visitors(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings();
  v_cfg visitor_signal_config := app.visitor_sig_cfg();
  v_day date := app.local_date(now());
begin
  perform app.assert_live_staff(p_by);
  return jsonb_build_object(
    'live_minutes', ps.visitor_live_minutes, 'tracking', ps.visitor_tracking_enabled, 'at', now(), 'cfg', app.visitor_live_cfg(p_by),
    'now', coalesce((select jsonb_agg(app.visitor_session_row(s) order by s.score desc nulls last, (s.renter_id is not null) desc, s.last_seen_at desc)
                       from visitor_sessions s where s.last_seen_at > now() - make_interval(mins => ps.visitor_live_minutes) and s.ended_at is null), '[]'::jsonb),
    'signals', coalesce((select jsonb_agg(x order by x ->> 'at' desc) from (select x from (
                  select jsonb_build_object('kind', g.kind, 'label', g.label, 'at', g.last_at, 'who',
                           coalesce((select app.visitor_who(s) from visitor_sessions s where s.id = g.session_id), 'Visitor'),
                           'session_id', g.session_id, 'renter_id', g.renter_id, 'booking_number', b.booking_number, 'task_id', g.task_id,
                           'strength', app.visitor_strength(coalesce(r.weight, 0)), 'why', g.label) as x
                    from visitor_signals g left join bookings b on b.id = g.booking_id left join visitor_signal_rules r on r.code = g.kind
                   where g.resolved_at is null and g.last_at > now() - interval '24 hours'
                  union all
                  select jsonb_build_object('kind', l.kind, 'label', r.label, 'at', l.last_at, 'who', app.visitor_who(s), 'session_id', l.session_id,
                           'renter_id', s.renter_id, 'booking_number', null, 'task_id', null, 'strength', app.visitor_strength(r.weight), 'why', l.why)
                    from visitor_live_signals l join visitor_signal_rules r on r.code = l.kind join visitor_sessions s on s.id = l.session_id
                   where l.active and r.enabled and r.weight >= v_cfg.medium_weight and l.last_at > now() - interval '24 hours') u(x)
                   order by x ->> 'at' desc limit 60) y), '[]'::jsonb),
    'hot', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'who', app.visitor_who(s), 'score', s.score, 'hot_at', s.hot_at, 'reasons', s.score_reasons,
                       'online', s.last_seen_at > now() - make_interval(mins => ps.visitor_live_minutes) and s.ended_at is null,
                       'renter_id', s.renter_id, 'acted', exists (select 1 from visitor_actions va where va.visitor_id = s.visitor_id and va.at >= s.hot_at))
                       order by s.hot_at desc)
                       from (select * from visitor_sessions where hot_at > now() - interval '24 hours' order by hot_at desc limit 20) s), '[]'::jsonb),
    'most_viewed', app.most_viewed_cars(7, 8),
    'today', jsonb_build_object(
      'sessions', (select count(*) from visitor_sessions s where s.started_at >= app.local_midnight(v_day)),
      'known', (select count(*) from visitor_sessions s where s.started_at >= app.local_midnight(v_day) and s.renter_id is not null),
      'hot', (select count(*) from visitor_sessions s where s.hot_at >= app.local_midnight(v_day)),
      'chats', (select count(*) from chat_conversations c where c.created_at >= app.local_midnight(v_day))));
end $$;

-- an event's details in words, for the visit's pages and events
create or replace function app.visitor_event_detail(p_kind text, d jsonb) returns text
language sql immutable as $$
  select case p_kind
    when 'quote_seen' then concat_ws(', ', coalesce('$' || to_char((d ->> 'total')::integer, 'FM999,999'), null) || coalesce(' for ' || (d ->> 'days') || case when d ->> 'days' = '1' then ' day' else ' days' end, ''),
                                     case when d ->> 'avail' = '0' then 'not free' end, case when d ->> 'deliv' = '1' then 'delivery' end, case when d ->> 'xdrv' = '1' then 'an additional driver' end)
    when 'request_step' then 'step ' || (d ->> 'step')
    when 'help_open' then case d ->> 'topic' when 'price' then 'the price' when 'deposit' then 'the deposit' when 'requirements' then 'requirements' when 'insurance' then 'insurance'
                            when 'cancel' then 'cancelling' when 'delivery' then 'delivery' when 'young' then 'young drivers' when 'drivers' then 'an additional driver' when 'km' then 'kilometres' else 'another question' end
    when 'contact_click' then case d ->> 'via' when 'call' then 'call' when 'whatsapp' then 'WhatsApp' when 'sms' then 'text' when 'email' then 'email' when 'copy' then 'copied our number' end
    when 'photos' then (d ->> 'n') || ' photos'
    when 'browse' then concat_ws(', ', case d ->> 'sort' when 'price-asc' then 'lowest price first' when 'price-desc' then 'highest price first' when 'other' then 'sorted' end,
                                 case when d ->> 'filter' = '1' then 'filters' end, case when d ->> 'maxp' = '1' then 'a lower price limit' end)
    when 'friction' then case d ->> 'type' when 'error' then 'a form error' else 'repeated taps' end
  end
$$;

-- 0060's visit in full, with the details of the 0086 events in words
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
                          'ms', e.ms, 'pickup', e.data ->> 'pickup', 'return', e.data ->> 'return', 'detail', app.visitor_event_detail(e.kind, e.data)) order by e.at desc)
                         from (select * from visitor_events where session_id = s.id order by at desc limit 60) e), '[]'::jsonb),
    'visits', (select count(*) from visitor_sessions o where o.visitor_id = s.visitor_id),
    'visits_7d', (select count(*) from visitor_sessions o where o.visitor_id = s.visitor_id and o.started_at > now() - interval '7 days'));
end $$;

-- the cars most often viewed in the same visit as this one (per day counts, no person)
create or replace function app.vehicle_compared(p_vehicle uuid, p_days integer default 30, p_limit integer default 3) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('vehicle_id', o, 'car', app.vehicle_name(o), 'sessions', n) order by n desc), '[]'::jsonb) from (
    select case when p.vehicle_a = p_vehicle then p.vehicle_b else p.vehicle_a end as o, sum(p.sessions)::integer as n
      from vehicle_pairs_daily p
     where (p.vehicle_a = p_vehicle or p.vehicle_b = p_vehicle) and p.day > app.local_date(now()) - p_days
     group by 1 order by 2 desc limit p_limit) y
$$;

create or replace function app.most_viewed_cars(p_days integer default 7, p_limit integer default 8) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(x order by (x ->> 'views_7d')::integer desc), '[]'::jsonb) from (
    select jsonb_build_object('vehicle_id', d.vehicle_id, 'car', app.vehicle_name(d.vehicle_id),
             'views_today', coalesce(sum(d.views) filter (where d.day = app.local_date(now())), 0),
             'views_7d', sum(d.views), 'viewers_7d', sum(d.viewers), 'quotes_7d', sum(d.quotes), 'requests_7d', sum(d.requests),
             'compared', app.vehicle_compared(d.vehicle_id, p_days, 1) -> 0,
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
  v_quotes30 bigint;
begin
  perform app.assert_live_staff(p_by);
  select coalesce(sum(viewers), 0), coalesce(sum(requests), 0), coalesce(sum(quotes), 0) into v_viewers30, v_req30, v_quotes30
    from vehicle_interest_daily where vehicle_id = v and day > v_day - 30;
  return jsonb_build_object(
    'views_today', (select coalesce(sum(views), 0) from vehicle_interest_daily where vehicle_id = v and day = v_day),
    'views_7d', (select coalesce(sum(views), 0) from vehicle_interest_daily where vehicle_id = v and day > v_day - 7),
    'viewers_7d', (select coalesce(sum(viewers), 0) from vehicle_interest_daily where vehicle_id = v and day > v_day - 7),
    'requests_30d', v_req30, 'viewers_30d', v_viewers30, 'quotes_30d', v_quotes30,
    'bookings_30d', (select count(*) from bookings b where b.vehicle_id = v and b.booked_at > now() - interval '30 days' and b.booking_type <> 'owner'),
    'conversion_bps', case when v_viewers30 > 0 then round(10000.0 * v_req30 / v_viewers30)::integer end,
    'quote_bps', case when v_viewers30 > 0 then round(10000.0 * v_quotes30 / v_viewers30)::integer end,
    'looking_now', (select count(*) from visitor_sessions s where s.current_vehicle_id = v and s.last_seen_at > now() - make_interval(mins => (app.settings()).visitor_live_minutes) and s.ended_at is null),
    'compared', app.vehicle_compared(v, 30, 3),
    'days', coalesce((select jsonb_agg(jsonb_build_object('day', d, 'views', coalesce(x.views, 0)) order by d)
                        from generate_series(v_day - 13, v_day, interval '1 day') d
                        left join vehicle_interest_daily x on x.vehicle_id = v and x.day = d::date), '[]'::jsonb));
end $$;

-- the rules and the settings, for the settings page (every live staff member may read them; only Admins change them)
create or replace function app.live_signal_rules(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_live_staff(p_by);
  return jsonb_build_object(
    'rules', (select jsonb_agg(to_jsonb(r) - 'updated_by' order by r.sort, r.code) from visitor_signal_rules r),
    'config', (select to_jsonb(c) - 'id' - 'updated_by' from visitor_signal_config c where c.id),
    'can_edit', app.user_is_admin(p_by),
    'week', jsonb_build_object(
      'hot', (select count(*) from visitor_sessions where hot_at > now() - interval '7 days'),
      'acted', (select count(*) from visitor_actions where at > now() - interval '7 days'),
      'discounts', (select count(*) from visitor_actions where action = 'discount' and at > now() - interval '7 days'),
      'discounts_used', (select count(*) from visitor_actions va join promo_redemptions pr on pr.promo_code_id = va.promo_code_id
                          where va.action = 'discount' and va.at > now() - interval '30 days' and pr.status in ('applied', 'redeemed'))));
end $$;

-- a car like theirs (a class in common, closest daily rate) that is free for the dates they searched
create or replace function app.live_similar(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s visitor_sessions;
  v_car uuid;
  v_pick date;
  v_ret date;
  v_site text := coalesce((select nullif(site_url, '') from site_settings limit 1), 'https://carmacars.ca');
  v_list jsonb;
  v_rate bigint;
begin
  perform app.assert_live_staff(p_by);
  select * into s from visitor_sessions where id = (p ->> 'session_id')::uuid;
  if s.id is null then raise exception 'That visit is no longer kept' using errcode = 'P0002'; end if;
  select coalesce(q.vehicle_id, s.current_vehicle_id) into v_car from (select 1) one
    left join lateral (select e.vehicle_id from visitor_events e where e.session_id = s.id and e.kind = 'quote_seen' order by e.at desc limit 1) q on true;
  v_car := coalesce(v_car, s.cars_viewed[cardinality(s.cars_viewed)]);
  begin
    select left(e.data ->> 'pickup', 10)::date, left(e.data ->> 'return', 10)::date into v_pick, v_ret
      from visitor_events e where e.session_id = s.id and e.kind = 'search' and e.data ? 'pickup' order by e.at desc limit 1;
  exception when others then v_pick := null; v_ret := null;
  end;
  if v_pick is null or v_ret is null or v_ret <= v_pick then v_pick := app.local_date(now()) + 1; v_ret := v_pick + 3; end if;
  v_rate := (select l.daily_rate_cents from public_vehicle_listings l where l.vehicle_id = v_car);
  select coalesce(jsonb_agg(jsonb_build_object('vehicle_id', x.vehicle_id, 'car', app.vehicle_name(x.vehicle_id), 'daily_cents', x.daily_rate_cents,
                     'url', v_site || '/cars/' || x.slug) order by x.d), '[]'::jsonb) into v_list
    from (select l.vehicle_id, l.slug, l.daily_rate_cents, abs(l.daily_rate_cents - coalesce(v_rate, l.daily_rate_cents)) as d
            from public_vehicle_listings l
           where l.vehicle_id is distinct from v_car
             and (v_car is null or exists (select 1 from vehicle_class_links a join vehicle_class_links b on b.class_code = a.class_code
                                            where a.vehicle_id = v_car and b.vehicle_id = l.vehicle_id))
             and app.vehicle_is_available(l.vehicle_id, app.local_midnight(v_pick) + interval '10 hours', app.local_midnight(v_ret) + interval '10 hours')
           order by 4 limit 3) x;
  return jsonb_build_object('car', case when v_car is not null then app.vehicle_name(v_car) end, 'pickup', v_pick, 'return', v_ret, 'cars', v_list,
    'message', app.visitor_fill((select message from visitor_signal_rules where code = 'unavailable'), jsonb_build_object(
      'car', case when v_car is not null then app.vehicle_name(v_car) end,
      'similar', case when jsonb_array_length(v_list) = 0 then null else
        (select string_agg(format('%s from %s a day (%s)', y ->> 'car', app.money_text((y ->> 'daily_cents')::bigint), y ->> 'url'), '; ') from jsonb_array_elements(v_list) y) end)));
end $$;

-- ================================================================ 7. actions
create or replace function app.live_action(p_by uuid, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c visitor_signal_config := app.visitor_sig_cfg();
  s visitor_sessions;
  r jsonb;
  pc promo_codes;
  v_body text := left(btrim(coalesce(p ->> 'body', '')), 1000);
  v_to uuid;
  v_task uuid;
  v_n integer;
  v_first text;
begin
  perform app.assert_live_staff(p_by);
  perform app.chat_presence(p_by);
  if p_name = 'live_rules_save' then
    perform app.assert_admin(p_by);
    update visitor_signal_rules x set
      enabled = coalesce((y ->> 'enabled')::boolean, x.enabled),
      weight = coalesce((y ->> 'weight')::integer, x.weight),
      t1 = case when y ? 't1' then nullif(y ->> 't1', '')::numeric else x.t1 end,
      t2 = case when y ? 't2' then nullif(y ->> 't2', '')::numeric else x.t2 end,
      param = case when y ? 'param' and x.param is not null then left(btrim(y ->> 'param'), 2000) else x.param end,
      label = coalesce(nullif(btrim(y ->> 'label'), ''), x.label),
      action = coalesce(nullif(y ->> 'action', ''), x.action),
      message = case when y ? 'message' then left(btrim(y ->> 'message'), 600) else x.message end,
      updated_at = now(), updated_by = p_by
      from jsonb_array_elements(coalesce(p -> 'rules', '[]'::jsonb)) as j(y)
     where x.code = j.y ->> 'code';
    get diagnostics v_n = row_count;
    return jsonb_build_object('ok', true, 'saved', v_n);
  end if;
  if p_name = 'live_config_save' then
    perform app.assert_admin(p_by);
    update visitor_signal_config set
      hot_score = coalesce((p ->> 'hot_score')::integer, hot_score), warm_score = coalesce((p ->> 'warm_score')::integer, warm_score),
      strong_weight = coalesce((p ->> 'strong_weight')::integer, strong_weight), medium_weight = coalesce((p ->> 'medium_weight')::integer, medium_weight),
      notify_hot = coalesce((p ->> 'notify_hot')::boolean, notify_hot), discount_enabled = coalesce((p ->> 'discount_enabled')::boolean, discount_enabled),
      discount_percent = coalesce((p ->> 'discount_percent')::integer, discount_percent),
      discount_max_cents = case when p ? 'discount_max_cents' then nullif(p ->> 'discount_max_cents', '')::bigint else discount_max_cents end,
      discount_valid_days = coalesce((p ->> 'discount_valid_days')::integer, discount_valid_days),
      discount_daily_cap = coalesce((p ->> 'discount_daily_cap')::integer, discount_daily_cap), discount_cs = coalesce((p ->> 'discount_cs')::boolean, discount_cs),
      discount_message = coalesce(nullif(left(btrim(p ->> 'discount_message'), 600), ''), discount_message),
      updated_at = now(), updated_by = p_by
     where id;
    return jsonb_build_object('ok', true);
  end if;

  select * into s from visitor_sessions where id = (p ->> 'session_id')::uuid;
  if s.id is null then raise exception 'That visit is no longer kept' using errcode = 'P0002'; end if;
  v_first := nullif(split_part(coalesce(s.known_name, (select r2.legal_name from renters r2 where r2.id = s.renter_id), ''), ' ', 1), '');

  if p_name = 'live_invite' then
    -- the suggested message (or the one written), through 0060's proactive chat
    v_body := replace(v_body, '{staff}', coalesce((select split_part(full_name, ' ', 1) from users where id = p_by), ''));
    r := app.chat_staff_do(p_by, 'chat_start', jsonb_build_object('session_id', s.id, 'body', v_body));
    insert into visitor_actions (session_id, visitor_id, action, signal, by_user, chat_id, score)
    values (s.id, s.visitor_id, case when p ->> 'kind' = 'unavailable' then 'similar' else 'chat' end, left(p ->> 'kind', 40), p_by, (r ->> 'id')::uuid, s.score);
    return r;
  end if;

  if p_name = 'live_discount' then
    if not c.discount_enabled then raise exception 'Discount codes from Live visitors are off in Signal settings' using errcode = '22023'; end if;
    if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'sales') or (c.discount_cs and app.user_va_has(p_by, 'cs'))) then
      raise exception 'Only Admins and Sales send discount codes (Signal settings)' using errcode = '42501';
    end if;
    if s.last_seen_at < now() - interval '30 minutes' then raise exception 'That visitor has left the site' using errcode = '22023'; end if;
    select count(*) into v_n from visitor_actions where by_user = p_by and action = 'discount' and at >= app.local_midnight(app.local_date(now()));
    if v_n >= c.discount_daily_cap then raise exception 'You reached today''s limit of % discount codes', c.discount_daily_cap using errcode = '22023'; end if;
    if exists (select 1 from visitor_actions where visitor_id = s.visitor_id and action = 'discount' and at > now() - interval '7 days') then
      raise exception 'This visitor already got a discount code this week' using errcode = '22023';
    end if;
    insert into promo_codes (code, description, percent_bps, valid_from, valid_until, max_uses, once_per_renter, renter_id, source, created_by, max_discount_cents)
    values ('LIVE' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6)),
            format('Live visitors: %s%% offered by %s to %s', c.discount_percent, coalesce((select full_name from users where id = p_by), 'staff'), app.visitor_who(s)),
            c.discount_percent * 100, now(), now() + make_interval(days => c.discount_valid_days), 1, true, s.renter_id, 'live_visitors', p_by, c.discount_max_cents)
    returning * into pc;
    v_body := app.visitor_fill(coalesce(nullif(v_body, ''), c.discount_message), jsonb_build_object('code', pc.code, 'percent', c.discount_percent,
      'valid_until', app.visitor_date_words(app.local_date(pc.valid_until)), 'first_name_sp', ' ' || v_first));
    if position(pc.code in v_body) = 0 then v_body := v_body || ' Code: ' || pc.code; end if;
    r := app.chat_staff_do(p_by, 'chat_start', jsonb_build_object('session_id', s.id, 'body', v_body));
    insert into visitor_actions (session_id, visitor_id, action, signal, by_user, promo_code_id, chat_id, score)
    values (s.id, s.visitor_id, 'discount', left(p ->> 'kind', 40), p_by, pc.id, (r ->> 'id')::uuid, s.score);
    return r || jsonb_build_object('code', pc.code, 'percent', c.discount_percent, 'valid_until', pc.valid_until);
  end if;

  if p_name = 'live_assign' then
    -- to the person chosen, else to the caller when they work Sales, else to the Sales person on shift with the fewest visits assigned today
    v_to := nullif(p ->> 'to', '')::uuid;
    if v_to is null and app.user_va_has(p_by, 'sales') then v_to := p_by; end if;
    if v_to is null then
      select x.user_id into v_to from chat_staff_prefs x
       where x.last_seen_at > now() - make_interval(mins => (app.settings()).chat_shift_minutes) and app.user_va_has(x.user_id, 'sales')
       order by (select count(*) from visitor_sessions o where o.assigned_to = x.user_id and o.assigned_at >= app.local_midnight(app.local_date(now()))), x.last_seen_at desc
       limit 1;
    end if;
    if v_to is not null and not (app.user_is_admin(v_to) or app.user_va_has(v_to, 'sales')) then raise exception 'Assign to Sales or an Admin' using errcode = '22023'; end if;
    update visitor_sessions set assigned_to = v_to, assigned_at = now() where id = s.id;
    -- a task for Sales: with the contact when we know who they are, or to reach them on the site now
    v_task := app.raise_task(p_type => 'visitor_follow_up',
      p_title => left(format('%s %s: booking likelihood %s%s', case when s.renter_id is not null or s.known_email is not null then 'Call or message' else 'Chat with' end,
                        app.visitor_who(s), coalesce(s.score, 0), coalesce(', ' || (select string_agg(x ->> 'label', ', ') from jsonb_array_elements(s.score_reasons) x), '')), 200),
      p_detail => format('Assigned from Live visitors by %s. %s%s', coalesce((select full_name from users where id = p_by), 'staff'),
                         coalesce('Contact: ' || coalesce((select r2.mobile from renters r2 where r2.id = s.renter_id), 'no phone') || ', ' || coalesce(s.known_email, (select r2.email from renters r2 where r2.id = s.renter_id)) || '. ',
                                  'Not known by name: open Live visitors and start a chat while they are on the site. '),
                         coalesce('Note: ' || nullif(left(btrim(p ->> 'note'), 300), '') || '.', '')),
      p_renter => s.renter_id, p_vehicle => s.current_vehicle_id, p_queue => 'sales', p_related_table => 'visitor_sessions', p_related_id => s.id,
      p_dedupe => 'live-assign:' || s.id || ':' || coalesce(v_to::text, 'queue'), p_created_by => p_by);
    if v_to is not null and v_task is not null then update tasks set assigned_to = v_to where id = v_task and assigned_to is null; end if;
    insert into visitor_actions (session_id, visitor_id, action, signal, by_user, to_user, task_id, score)
    values (s.id, s.visitor_id, 'assign', left(p ->> 'kind', 40), p_by, v_to, v_task, s.score);
    return jsonb_build_object('ok', true, 'to', v_to, 'name', (select full_name from users where id = v_to), 'task_id', v_task);
  end if;
  raise exception 'Unknown action %', p_name using errcode = '22023';
end $$;

-- ================================================================ 8. housekeeping: the new rows follow the visits' retention
create or replace function app.job_visitor_signals_housekeeping(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  v_a integer;
begin
  delete from visitor_actions where at < p_now - make_interval(days => ps.visitor_events_keep_days);
  get diagnostics v_a = row_count;
  -- the pairs are counts without a person: kept a year
  delete from vehicle_pairs_daily where day < app.local_date(p_now) - 365;
  return format('actions %s', v_a);
end $$;
do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-visitor-signals-housekeeping', '29 8 * * *', 'select app.job_visitor_signals_housekeeping()');
  end if;
end $$;

-- ================================================================ 9. the privacy policy (section 10), flagged for the lawyer
-- The live copy changes only where it still carries our text; an Admin's own edit is left as it is.
update site_content_blocks
   set body = replace(body,
     'We do not store your network address for this.',
     'We do not store your network address for this. With the same consent we also note a few actions on those pages: the prices you are shown for your dates, how far you get in the booking form, the questions you open, how many photos of a car you look through, how you sort or filter the cars, when you tap to call, text, WhatsApp or email us or copy our phone number, when a form shows an error or does not respond to repeated taps, and whether you arrived from one of our ads (not the ad''s own identifier). We never record what you type in a form, and we do not record your screen. From these records we estimate how ready to book a visit looks, so our staff can offer help at the right moment, for example a chat or a discount code; this estimate is never used to approve, refuse or price a booking.')
 where block_key = 'legal.privacy' and body like '%We do not store your network address for this.%'
   and body not like '%With the same consent we also note a few actions%';
update site_content_blocks set data = data || jsonb_build_object('last_updated', 'October 21, 2026')
 where block_key = 'legal.meta' and (data ->> 'last_updated') in ('October 19, 2026');

-- ================================================================ 10. the doors and privileges
create or replace function app.ops86(p_user uuid, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  case p_name
  when 'live_signal_rules' then return app.live_signal_rules(p_user, p);
  when 'live_similar' then return app.live_similar(p_user, p);
  when 'live_rules_save', 'live_config_save', 'live_invite', 'live_discount', 'live_assign' then return app.live_action(p_user, p_name, p);
  else raise exception 'Unknown action %', p_name using errcode = '22023';
  end case;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0086;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  v jsonb;
begin
  if (p_call in ('va_read', 'admin_read', 'ops_read') and p_name in ('live_signal_rules', 'live_similar'))
     or (p_call in ('va_do', 'admin_do', 'ops_do') and p_name in ('live_rules_save', 'live_config_save', 'live_invite', 'live_discount', 'live_assign')) then
    if p_ ? '_va' then perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.ops86(p_user, p_call, p_name, p_ - '_va');
  end if;
  v := app.door_pre0086(p_user, p_aal, p_call, p_name, p);
  -- the menus' counts: hot visitors on the site now beside the chats waiting
  if p_name = 'chat_counts' and jsonb_typeof(v) = 'object' and app.live_staff_ok(p_user) then
    v := v || jsonb_build_object('hot', (select count(*) from visitor_sessions s where s.hot_at is not null and s.score >= (app.visitor_sig_cfg()).hot_score
                                           and s.last_seen_at > now() - make_interval(mins => (app.settings()).visitor_live_minutes) and s.ended_at is null));
  end if;
  return v;
end $$;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array[
             'visitor_sig_cfg', 'visitor_strength', 'visitor_band', 'visitor_fill', 'visitor_path_topic', 'visitor_topic_words', 'visitor_date_words',
             'track_ingest', 'visitor_live_eval', 'job_visitor_signals', 'visitor_signals_all', 'visitor_session_row', 'visitor_live_cfg', 'live_visitors',
             'vehicle_compared', 'most_viewed_cars', 'visitor_event_detail', 'live_session', 'vehicle_interest', 'live_signal_rules', 'live_similar', 'live_action',
             'job_visitor_signals_housekeeping', 'ops86', 'door'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- the renamed door keeps its privileges; the door in its place gets the same
do $$
declare
  r record;
  v_new regprocedure;
  g text;
begin
  for r in select p.oid, oidvectortypes(p.proargtypes) as args from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = 'door_pre0086' loop
    v_new := format('app.door(%s)', r.args)::regprocedure;
    execute format('revoke all on function %s from public, anon, authenticated', v_new);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;

-- ================================================================ 11. the visits already on record get their score
do $$
declare x uuid;
begin
  for x in select id from visitor_sessions where last_seen_at > now() - interval '7 days' order by last_seen_at desc limit 2000 loop
    perform app.visitor_live_eval(x);
  end loop;
end $$;

-- ================================================================ 12. the guides for this release
create or replace function app.guide_release_0086(p_portal text, p_slug text, p_kind text, p_after text, p_base_md text, p_title text, p_blurb text,
                                                  p_md text, p_html text) returns text
language sql security definer set search_path = public, app as $$
  select app.guide_release_section(p_portal, p_slug, p_kind, p_after, p_base_md, p_title, p_blurb, p_md, p_html)
$$;
revoke all on function app.guide_release_0086(text, text, text, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function app.guide_release_0086(text, text, text, text, text, text, text, text, text) to service_role;
-- GUIDES 0086 START (generated by supabase/seed/0086_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_0086('admin', 'live-visitors-and-live-chat', 'chapter', 'tolls-and-tickets', 'See who is on the site right now and what they look at, with buying signals, and answer the live chat. The CarmaCars assistant answers the chat first; you take over whenever you want, and it hands over by itself for complaints, damage, payments and anything it should not answer.

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

## Recovery emails

Known renters who stop before finishing get one polite reminder, and at most one more a day later.

- An offer opened and not answered: after 4 hours. The pay page left without paying: after an hour. A change proposal opened and not answered: after 4 hours.
- A booking request started and not sent: after 2 hours, and only to renters who agreed to hear from us (marketing consent).
- Sent only between 9:00 and 21:00 Toronto time, never to someone who unsubscribed, and never while a staff member is handling the renter (a task they took, a chat with a person, a message from staff).
- They stop as soon as the renter answers, pays or sends the request; a reminder still waiting is not sent. The delays and hours are in Program settings, "Booking recovery emails".

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
', 'Live visitors and live chat', 'Who is on the site now, how likely each visitor is to book and why, one-click actions, follow-ups, interest per car, the chat inbox.',
  'See who is on the site right now and what they look at, with buying signals, and answer the live chat. The CarmaCars assistant answers the chat first; you take over whenever you want, and it hands over by itself for complaints, damage, payments and anything it should not answer.

## Live visitors

Visitors who accepted analytics (or got the notice in Canada outside Quebec and the US), known customers on their own booking pages and anyone in a chat.

1. Open **Today** > **Live visitors**. The tiles count who is on the site now, hot visitors now, known customers, visits and chats today. The menu shows how many hot visitors are on the site.
2. Each visitor shows a booking likelihood from 0 to 100, with Hot (60 or more), Warm (30 or more) or Cold. The list is sorted by it; choose "Most recent" in Sort, or tick "Hot and warm only".
3. "Why" gives the three strongest reasons, for example "Pickup tomorrow · Reached step 3 of the request form · Tapped to call". The badges are all the signals of the visit; the dots say how strong each is.
4. Each visitor also shows their name when known (signed in, or arrived from one of our emails), otherwise "Visitor from Toronto, phone"; the page and car they are on, and how many others look at that car now; the device, city, the site or campaign that sent them and "from an ad".
5. Suggested: the best next step and the message to send. Press **Invite to chat with this message** to send it at once, **Edit the message** to change it first, **Offer a 10% discount code**, **Assign to Sales** or, when their dates are taken, **Suggest a similar free car**.
6. Press **Pages** for every page and event of the visit with each signal''s points, or **Start a chat** to write your own message. They see it in a bubble and reply from it.
7. Below: hot visitors today (and whether someone acted), the signals of the last 24 hours, and the most viewed cars of the week with prices shown and the car most compared with each. The page refreshes by itself every few seconds.

## The signals

Each signal adds points to the booking likelihood. They come from what the visitor does on the site, never from what they type.

- Intent: dates searched again and again, saw the full price, reached the booking form (and which step), came back for the same car on another day, comparing two or three cars, read the cancellation policy, read about the deposit, insurance or requirements, tapped to call, text or WhatsApp us or copied our number, checked delivery, looked through many photos or stayed long on one car.
- Urgency: pickup within 72 hours, weekend or holiday dates, on a phone late at night, came from a city or model page or a "near me" search.
- Value: a weekly or monthly rental, a premium car, SUV or van, adding a driver, asked about young drivers, a business email.
- Hesitation: watching the price (sorted by lowest price, lowered the price limit), left after seeing the price, unsure about the deposit, trouble with a form, the car not free for their dates.
- Context: came from an ad, a past renter, an offer or payment waiting, a game code not used yet, a popular car. The signals of known customers (offer opened, pay page left, change proposal, request stopped, returning visitor, viewing spree) count too.

## Hot visitors and the actions

- When a visitor turns hot, everyone with Live visitors open sees an alert at the top of the page. Turn on desktop alerts in Live chat to get one on your computer too; none come in the quiet hours (11 pm to 7 am). No email is sent.
- A discount code is single use, 10% off the rental charge (at most $75), valid 3 days, one per visitor a week and 10 a day per person. Admins and Sales send them; the code goes in the chat with the message.
- Assign to Sales gives the visitor to the Sales person on shift (or to you if you work Sales) and raises a task with the reasons and the contact when we know who they are.
- Each action shows on the visitor ("Invited by Lena, 2 min ago") so two people do not write to the same visitor.

## Signal settings

1. Open **Today** > **Live visitors** and press **Signal settings**.
2. Score and actions: from how many points a visitor is hot or warm, when a signal is strong or medium, the hot alert, and the discount code (percent, most off a booking, days valid, codes a day per person, whether customer service may send codes, and the message).
3. Each signal: on or off, its points, its thresholds (for example 72 hours for "Pickup soon", 3 searches for "Searching dates again and again"), the suggested action and the message. {car}, {days}, {pickup} and the other words in braces are filled in from the visit.
4. Press **Save the signals**. The next look at each visit uses them.

## Follow-up tasks

Signals of known visitors become tasks with a suggested action, for example "Call or message Maya Chen: opened offer CC-1042 twice, no answer for 6 hours".

- An offer opened and not answered: after 6 hours, to Sales when the booking is credited to someone in Sales, otherwise customer service.
- The pay page left without paying: after 30 minutes, customer service. The change proposal opened twice: customer service.
- A booking request started and stopped, or a viewing spree, by a known visitor: Sales.
- A task closes by itself when the renter answers the offer, pays or answers the proposal. Each signal raises one task only.
- The thresholds are in **Settings** > **Program**, group "Live visitors and live chat". Follow-ups done count in My sales.

## Recovery emails

Known renters who stop before finishing get one polite reminder, and at most one more a day later.

- An offer opened and not answered: after 4 hours. The pay page left without paying: after an hour. A change proposal opened and not answered: after 4 hours.
- A booking request started and not sent: after 2 hours, and only to renters who agreed to hear from us (marketing consent).
- Sent only between 9:00 and 21:00 Toronto time, never to someone who unsubscribed, and never while a staff member is handling the renter (a task they took, a chat with a person, a message from staff).
- They stop as soon as the renter answers, pays or sends the request; a reminder still waiting is not sent. The delays and hours are in Program settings, "Booking recovery emails".

## Interest in a car

**Cars** > **Vehicles**, a car, Overview: "Interest on the site" shows who is looking now, views today and in 7 days, the people who saw the price for their dates, conversion over 30 days (requests from the people who viewed it), the cars most often compared with it, and the last 14 days. The Vehicles list has "Most viewed cars this week".

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
  '<p class="gd-p">See who is on the site right now and what they look at, with buying signals, and answer the live chat. The CarmaCars assistant answers the chat first; you take over whenever you want, and it hands over by itself for complaints, damage, payments and anything it should not answer.</p><section class="gd-task" id="live-visitors-and-live-chat-live-visitors" data-gd-task><h2 class="gd-h2">Live visitors</h2><p class="gd-p">Visitors who accepted analytics (or got the notice in Canada outside Quebec and the US), known customers on their own booking pages and anyone in a chat.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Today</b> &gt; <b class="gd-ui">Live visitors</b>. The tiles count who is on the site now, hot visitors now, known customers, visits and chats today. The menu shows how many hot visitors are on the site.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each visitor shows a booking likelihood from 0 to 100, with Hot (60 or more), Warm (30 or more) or Cold. The list is sorted by it; choose &quot;Most recent&quot; in Sort, or tick &quot;Hot and warm only&quot;.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">&quot;Why&quot; gives the three strongest reasons, for example &quot;Pickup tomorrow · Reached step 3 of the request form · Tapped to call&quot;. The badges are all the signals of the visit; the dots say how strong each is.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Each visitor also shows their name when known (signed in, or arrived from one of our emails), otherwise &quot;Visitor from Toronto, phone&quot;; the page and car they are on, and how many others look at that car now; the device, city, the site or campaign that sent them and &quot;from an ad&quot;.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Suggested: the best next step and the message to send. Press <b class="gd-ui">Invite to chat with this message</b> to send it at once, <b class="gd-ui">Edit the message</b> to change it first, <b class="gd-ui">Offer a 10% discount code</b>, <b class="gd-ui">Assign to Sales</b> or, when their dates are taken, <b class="gd-ui">Suggest a similar free car</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Press <b class="gd-ui">Pages</b> for every page and event of the visit with each signal&#39;s points, or <b class="gd-ui">Start a chat</b> to write your own message. They see it in a bubble and reply from it.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Below: hot visitors today (and whether someone acted), the signals of the last 24 hours, and the most viewed cars of the week with prices shown and the car most compared with each. The page refreshes by itself every few seconds.</div></li></ol></div></section><section class="gd-task" id="live-visitors-and-live-chat-the-signals" data-gd-task><h2 class="gd-h2">The signals</h2><p class="gd-p">Each signal adds points to the booking likelihood. They come from what the visitor does on the site, never from what they type.</p><ul class="gd-ul"><li>Intent: dates searched again and again, saw the full price, reached the booking form (and which step), came back for the same car on another day, comparing two or three cars, read the cancellation policy, read about the deposit, insurance or requirements, tapped to call, text or WhatsApp us or copied our number, checked delivery, looked through many photos or stayed long on one car.</li><li>Urgency: pickup within 72 hours, weekend or holiday dates, on a phone late at night, came from a city or model page or a &quot;near me&quot; search.</li><li>Value: a weekly or monthly rental, a premium car, SUV or van, adding a driver, asked about young drivers, a business email.</li><li>Hesitation: watching the price (sorted by lowest price, lowered the price limit), left after seeing the price, unsure about the deposit, trouble with a form, the car not free for their dates.</li><li>Context: came from an ad, a past renter, an offer or payment waiting, a game code not used yet, a popular car. The signals of known customers (offer opened, pay page left, change proposal, request stopped, returning visitor, viewing spree) count too.</li></ul></section><section class="gd-task" id="live-visitors-and-live-chat-hot-visitors-and-the-actions" data-gd-task><h2 class="gd-h2">Hot visitors and the actions</h2><ul class="gd-ul"><li>When a visitor turns hot, everyone with Live visitors open sees an alert at the top of the page. Turn on desktop alerts in Live chat to get one on your computer too; none come in the quiet hours (11 pm to 7 am). No email is sent.</li><li>A discount code is single use, 10% off the rental charge (at most $75), valid 3 days, one per visitor a week and 10 a day per person. Admins and Sales send them; the code goes in the chat with the message.</li><li>Assign to Sales gives the visitor to the Sales person on shift (or to you if you work Sales) and raises a task with the reasons and the contact when we know who they are.</li><li>Each action shows on the visitor (&quot;Invited by Lena, 2 min ago&quot;) so two people do not write to the same visitor.</li></ul></section><section class="gd-task" id="live-visitors-and-live-chat-signal-settings" data-gd-task><h2 class="gd-h2">Signal settings</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Today</b> &gt; <b class="gd-ui">Live visitors</b> and press <b class="gd-ui">Signal settings</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Score and actions: from how many points a visitor is hot or warm, when a signal is strong or medium, the hot alert, and the discount code (percent, most off a booking, days valid, codes a day per person, whether customer service may send codes, and the message).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each signal: on or off, its points, its thresholds (for example 72 hours for &quot;Pickup soon&quot;, 3 searches for &quot;Searching dates again and again&quot;), the suggested action and the message. {car}, {days}, {pickup} and the other words in braces are filled in from the visit.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Save the signals</b>. The next look at each visit uses them.</div></li></ol></div></section><section class="gd-task" id="live-visitors-and-live-chat-follow-up-tasks" data-gd-task><h2 class="gd-h2">Follow-up tasks</h2><p class="gd-p">Signals of known visitors become tasks with a suggested action, for example &quot;Call or message Maya Chen: opened offer CC-1042 twice, no answer for 6 hours&quot;.</p><ul class="gd-ul"><li>An offer opened and not answered: after 6 hours, to Sales when the booking is credited to someone in Sales, otherwise customer service.</li><li>The pay page left without paying: after 30 minutes, customer service. The change proposal opened twice: customer service.</li><li>A booking request started and stopped, or a viewing spree, by a known visitor: Sales.</li><li>A task closes by itself when the renter answers the offer, pays or answers the proposal. Each signal raises one task only.</li><li>The thresholds are in <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>, group &quot;Live visitors and live chat&quot;. Follow-ups done count in My sales.</li></ul></section><section class="gd-task" id="live-visitors-and-live-chat-recovery-emails" data-gd-task><h2 class="gd-h2">Recovery emails</h2><p class="gd-p">Known renters who stop before finishing get one polite reminder, and at most one more a day later.</p><ul class="gd-ul"><li>An offer opened and not answered: after 4 hours. The pay page left without paying: after an hour. A change proposal opened and not answered: after 4 hours.</li><li>A booking request started and not sent: after 2 hours, and only to renters who agreed to hear from us (marketing consent).</li><li>Sent only between 9:00 and 21:00 Toronto time, never to someone who unsubscribed, and never while a staff member is handling the renter (a task they took, a chat with a person, a message from staff).</li><li>They stop as soon as the renter answers, pays or sends the request; a reminder still waiting is not sent. The delays and hours are in Program settings, &quot;Booking recovery emails&quot;.</li></ul></section><section class="gd-task" id="live-visitors-and-live-chat-interest-in-a-car" data-gd-task><h2 class="gd-h2">Interest in a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, a car, Overview: &quot;Interest on the site&quot; shows who is looking now, views today and in 7 days, the people who saw the price for their dates, conversion over 30 days (requests from the people who viewed it), the cars most often compared with it, and the last 14 days. The Vehicles list has &quot;Most viewed cars this week&quot;.</p></section><section class="gd-task" id="live-visitors-and-live-chat-a-renter-s-visits" data-gd-task><h2 class="gd-h2">A renter&#39;s visits</h2><p class="gd-p">On a renter&#39;s page (People &gt; Renters, the name) and on a booking&#39;s History tab, &quot;On the site&quot; lists when they viewed the offer, opened the change proposal, viewed or left the pay page, which cars they looked at, and their chats.</p></section><section class="gd-task" id="live-visitors-and-live-chat-live-chat" data-gd-task><h2 class="gd-h2">Live chat</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Live chat</b>. The menu counts chats waiting for a person. Open chats come first, those waiting for a person on top, with their minutes against the first reply target (5 minutes).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose a conversation. Beside it you see the visitor&#39;s page, pages, signals, and the renter with their bookings when known.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Take over</b>: the assistant stops and the visitor reads that you joined. Writing a reply also takes over. Press <b class="gd-ui">Send</b> (or Enter).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Hand back to the assistant</b> lets it answer again. <b class="gd-ui">Close</b> ends the chat; if the visitor gave an email they get a copy. <b class="gd-ui">Email the transcript</b> sends it any time.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Notify me: &quot;Email me when a chat waits (while I am on shift)&quot; and desktop alerts in this browser. You are on shift while Live chat or Live visitors is open.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The assistant only repeats prices from our pricing (a quote or the car&#39;s rates), never offers discounts or promises a car, never talks about insurance and never names a provider. Each reply it was not allowed to send says so in the conversation. When nobody is on shift, the chat asks for the visitor&#39;s name, email or phone and raises a task. A booking from a chat you handled is credited only when you choose &quot;I sourced this client&quot; on the quote or offer.</div></aside></section><section class="gd-task" id="live-visitors-and-live-chat-the-assistant-s-settings" data-gd-task><h2 class="gd-h2">The assistant&#39;s settings</h2><p class="gd-p">In Program settings, &quot;Live visitors and live chat&quot;: the chat on or off, the AI first or not, its model, the neurons it may use a day (6,000, about 10 chats; then chats wait for a person), the greeting on car pages after some seconds (off by default), how long chats and visits are kept (12 months and 90 days, as the privacy policy says).</p></section>');
select app.guide_release_0086('va', 'live-visitors-and-live-chat', 'chapter', 'commissions', 'Customer service and Sales see who is on the site now and answer the live chat. The CarmaCars assistant answers first; you take over whenever you want.

## Live visitors

1. Open **My work** > **Live visitors**. Each visitor shows a name when known, otherwise "Visitor from Toronto, phone", the page and car they are on, and this visit''s pages.
2. Badges are buying signals: "Viewing spree: 6 cars in 10 minutes", "Opened offer CC-1042, not answered", "Left the pay page", "Started a request and stopped" and more.
3. Press **Pages** for the whole visit. Press **Start a chat**, write a short friendly message and press **Send**: the visitor sees it in a bubble.

## Follow-ups

Signals of known visitors raise tasks on To do with what to do, for example "Call or message Maya Chen: opened offer CC-1042 twice, no answer for 6 hours". Call or message, then mark the task done. A task closes by itself when the renter answers or pays. Follow-ups done count in My sales.

Renters also get one polite reminder email (and at most one more) when they leave an offer, the pay page or a change unanswered. Taking the follow-up task, a chat with you or a message from you stops these reminders: you are handling it.

## Live chat

1. Open **My work** > **Live chat**. The menu counts chats waiting for a person. Reply within 5 minutes.
2. Choose a conversation. Beside it: the visitor''s page, pages and signals, and the renter''s bookings when known.
3. Press **Take over** (or just write a reply): the assistant stops. Write and press **Send** or Enter. The visitor sees when you type.
4. **Hand back to the assistant** when you are done, or **Close**. A visitor who gave an email gets a copy of the chat.
5. Tick "Email me when a chat waits (while I am on shift)" or desktop alerts if you want them.

> Tip: Prices: send a quote from New quote, never a price from memory. If you handled the chat, choose "I sourced this client" on the quote; nothing is credited by itself.
', 'Live visitors and live chat', 'Who is on the site, how likely each visitor is to book, one-click actions, follow-ups, the chat inbox.',
  'Customer service and Sales see who is on the site now and answer the live chat. The CarmaCars assistant answers first; you take over whenever you want.

## Live visitors

1. Open **My work** > **Live visitors**. The menu shows how many hot visitors are on the site. Each visitor shows a booking likelihood from 0 to 100 (Hot, Warm or Cold); the most likely to book come first.
2. "Why" gives the three strongest reasons, for example "Pickup tomorrow · Saw $320 for 3 days · Tapped to call". The badges are all the signals; the dots say how strong each is.
3. Each visitor shows a name when known, otherwise "Visitor from Toronto, phone", the page and car they are on, how many others look at that car now, and this visit''s pages.
4. Suggested: the next step and a message. Press **Invite to chat with this message**, or **Edit the message** first. Sales can **Offer a 10% discount code** (one per visitor a week). **Assign to Sales** hands the visitor to Sales with a task. When their dates are taken, **Suggest a similar free car** writes the message for you.
5. Press **Pages** for the whole visit. Press **Start a chat** to write your own short friendly message and press **Send**: the visitor sees it in a bubble.
6. A hot visitor raises an alert at the top of the page. Each action shows on the visitor ("Invited by Lena, 2 min ago"), so check it before writing.

## Follow-ups

Signals of known visitors raise tasks on To do with what to do, for example "Call or message Maya Chen: opened offer CC-1042 twice, no answer for 6 hours". Call or message, then mark the task done. A task closes by itself when the renter answers or pays. Follow-ups done count in My sales.

Renters also get one polite reminder email (and at most one more) when they leave an offer, the pay page or a change unanswered. Taking the follow-up task, a chat with you or a message from you stops these reminders: you are handling it.

## Live chat

1. Open **My work** > **Live chat**. The menu counts chats waiting for a person. Reply within 5 minutes.
2. Choose a conversation. Beside it: the visitor''s page, pages and signals, and the renter''s bookings when known.
3. Press **Take over** (or just write a reply): the assistant stops. Write and press **Send** or Enter. The visitor sees when you type.
4. **Hand back to the assistant** when you are done, or **Close**. A visitor who gave an email gets a copy of the chat.
5. Tick "Email me when a chat waits (while I am on shift)" or desktop alerts if you want them.

> Tip: Prices: send a quote from New quote, never a price from memory. If you handled the chat, choose "I sourced this client" on the quote; nothing is credited by itself.
',
  '<p class="gd-p">Customer service and Sales see who is on the site now and answer the live chat. The CarmaCars assistant answers first; you take over whenever you want.</p><section class="gd-task" id="live-visitors-and-live-chat-live-visitors" data-gd-task><h2 class="gd-h2">Live visitors</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">My work</b> &gt; <b class="gd-ui">Live visitors</b>. The menu shows how many hot visitors are on the site. Each visitor shows a booking likelihood from 0 to 100 (Hot, Warm or Cold); the most likely to book come first.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">&quot;Why&quot; gives the three strongest reasons, for example &quot;Pickup tomorrow · Saw $320 for 3 days · Tapped to call&quot;. The badges are all the signals; the dots say how strong each is.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each visitor shows a name when known, otherwise &quot;Visitor from Toronto, phone&quot;, the page and car they are on, how many others look at that car now, and this visit&#39;s pages.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Suggested: the next step and a message. Press <b class="gd-ui">Invite to chat with this message</b>, or <b class="gd-ui">Edit the message</b> first. Sales can <b class="gd-ui">Offer a 10% discount code</b> (one per visitor a week). <b class="gd-ui">Assign to Sales</b> hands the visitor to Sales with a task. When their dates are taken, <b class="gd-ui">Suggest a similar free car</b> writes the message for you.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Pages</b> for the whole visit. Press <b class="gd-ui">Start a chat</b> to write your own short friendly message and press <b class="gd-ui">Send</b>: the visitor sees it in a bubble.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A hot visitor raises an alert at the top of the page. Each action shows on the visitor (&quot;Invited by Lena, 2 min ago&quot;), so check it before writing.</div></li></ol></div></section><section class="gd-task" id="live-visitors-and-live-chat-follow-ups" data-gd-task><h2 class="gd-h2">Follow-ups</h2><p class="gd-p">Signals of known visitors raise tasks on To do with what to do, for example &quot;Call or message Maya Chen: opened offer CC-1042 twice, no answer for 6 hours&quot;. Call or message, then mark the task done. A task closes by itself when the renter answers or pays. Follow-ups done count in My sales.</p><p class="gd-p">Renters also get one polite reminder email (and at most one more) when they leave an offer, the pay page or a change unanswered. Taking the follow-up task, a chat with you or a message from you stops these reminders: you are handling it.</p></section><section class="gd-task" id="live-visitors-and-live-chat-live-chat" data-gd-task><h2 class="gd-h2">Live chat</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">My work</b> &gt; <b class="gd-ui">Live chat</b>. The menu counts chats waiting for a person. Reply within 5 minutes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose a conversation. Beside it: the visitor&#39;s page, pages and signals, and the renter&#39;s bookings when known.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Take over</b> (or just write a reply): the assistant stops. Write and press <b class="gd-ui">Send</b> or Enter. The visitor sees when you type.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Hand back to the assistant</b> when you are done, or <b class="gd-ui">Close</b>. A visitor who gave an email gets a copy of the chat.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Tick &quot;Email me when a chat waits (while I am on shift)&quot; or desktop alerts if you want them.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Prices: send a quote from New quote, never a price from memory. If you handled the chat, choose &quot;I sourced this client&quot; on the quote; nothing is credited by itself.</div></aside></section>');
-- GUIDES 0086 END
