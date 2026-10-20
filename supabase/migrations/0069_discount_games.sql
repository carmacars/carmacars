-- 0069_discount_games.sql
-- The owner's request of October 19, 2026 (docs/changes/2026-10-19-discount-games.md): collect contact details from
-- visitors who browse a lot with a discount game for people who are not signed in: spin the wheel, scratch to reveal,
-- quick blackjack, cup shuffle and Plinko, one chosen at random per visitor (equal weights by default, a setting).
--   A. every play wins: the prize is drawn by the database from the prize table in Program settings (5% off 70%, 10% off
--      25%, 15% off 4%, $50 off a rental of 3 days or more 1%) before the game starts; the game only shows it.
--   B. to claim the code the visitor gives a first name, an email and (optional) a mobile number, with an unticked
--      marketing box. The code is a promo code of 0016 (single use, rental charge only, at most game_max_discount_cents
--      for a percentage, expires after game_code_valid_days, one per email, phone and device, never with another code),
--      so the discount is shared with the owner in the split like every promo code (0016, the owner's decision).
--   C. the claim is a lead linked to the visitor's session (known on Live visitors), a Sales task for high intent,
--      the code by email (transactional) and one reminder before it expires (transactional); marketing consent, when
--      given, opts an existing account in and carries over to an account opened later with the same email.
--   D. Admin > Bookings > Leads (and the assistants' Leads), Settings > Discount games, the report.
-- No applied migration is edited. Every new table has row-level security with the Admin policy; the browser reaches
-- them only through the functions below.

-- ================================================================ 1. settings
create or replace function app.game_kinds() returns text[]
language sql immutable as $$ select array['wheel', 'scratch', 'blackjack', 'cups', 'plinko'] $$;

-- The prize table: 1 to 8 prizes, each a weight above 0 and either a percentage or an amount off the rental charge.
create or replace function app.game_prizes_ok(p jsonb) returns boolean
language plpgsql immutable as $$
declare
  x jsonb;
  v_keys text[] := '{}';
begin
  if jsonb_typeof(p) <> 'array' or jsonb_array_length(p) not between 1 and 8 then return false; end if;
  for x in select value from jsonb_array_elements(p) loop
    if jsonb_typeof(x) <> 'object' then return false; end if;
    if coalesce(x ->> 'key', '') !~ '^[a-z0-9_]{1,20}$' or (x ->> 'key') = any (v_keys) then return false; end if;
    v_keys := v_keys || (x ->> 'key');
    if jsonb_typeof(x -> 'weight') <> 'number' or (x ->> 'weight')::numeric <= 0 then return false; end if;
    if (x ? 'percent_bps') = (x ? 'amount_cents') then return false; end if;
    if x ? 'percent_bps' and (jsonb_typeof(x -> 'percent_bps') <> 'number' or (x ->> 'percent_bps')::numeric not between 1 and 5000) then return false; end if;
    if x ? 'amount_cents' and (jsonb_typeof(x -> 'amount_cents') <> 'number' or (x ->> 'amount_cents')::numeric not between 100 and 100000) then return false; end if;
    if x ? 'min_days' and (jsonb_typeof(x -> 'min_days') <> 'number' or (x ->> 'min_days')::numeric not between 1 and 30) then return false; end if;
  end loop;
  return true;
end $$;

-- The games and their weights: an object of the five games, weights 0 or more, at least one above 0.
create or replace function app.game_weights_ok(p jsonb) returns boolean
language sql immutable as $$
  select jsonb_typeof(p) = 'object'
     and not exists (select 1 from jsonb_each(p) e where e.key <> all (app.game_kinds()) or jsonb_typeof(e.value) <> 'number' or (e.value::text)::numeric < 0)
     and exists (select 1 from jsonb_each(p) e where jsonb_typeof(e.value) = 'number' and (e.value::text)::numeric > 0)
$$;

alter table program_settings
  add column if not exists game_enabled boolean not null default true,
  add column if not exists game_weights jsonb not null default '{"wheel": 1, "scratch": 1, "blackjack": 1, "cups": 1, "plinko": 1}'::jsonb
    check (app.game_weights_ok(game_weights)),
  add column if not exists game_prizes jsonb not null default
    '[{"key": "pct5", "percent_bps": 500, "weight": 70}, {"key": "pct10", "percent_bps": 1000, "weight": 25},
      {"key": "pct15", "percent_bps": 1500, "weight": 4}, {"key": "amt50", "amount_cents": 5000, "min_days": 3, "weight": 1}]'::jsonb
    check (app.game_prizes_ok(game_prizes)),
  add column if not exists game_max_discount_cents bigint default 7500 check (game_max_discount_cents is null or game_max_discount_cents > 0),
  add column if not exists game_code_valid_days integer not null default 7 check (game_code_valid_days between 1 and 90),
  add column if not exists game_trigger_car_pages integer not null default 2 check (game_trigger_car_pages between 0 and 20),
  add column if not exists game_trigger_seconds integer not null default 60 check (game_trigger_seconds between 0 and 1800),
  add column if not exists game_exit_intent boolean not null default true,
  add column if not exists game_dismiss_days integer not null default 14 check (game_dismiss_days between 1 and 365),
  add column if not exists game_task_min_cars integer not null default 3 check (game_task_min_cars between 0 and 50),
  add column if not exists game_reminder_hours integer not null default 24 check (game_reminder_hours between 0 and 168);

comment on column program_settings.game_enabled is 'Discount games (0069): show a discount game to visitors who browse a lot and are not signed in. On by default.';
comment on column program_settings.game_weights is 'Discount games: how often each game is chosen (wheel, scratch, blackjack, cups, plinko). 0 turns a game off. Equal by default.';
comment on column program_settings.game_prizes is 'Discount games: the prize table. Each prize: key, weight (its chance), percent_bps or amount_cents, and min_days for a minimum rental length. Every play wins one.';
comment on column program_settings.game_max_discount_cents is 'Discount games: the most a percentage code takes off one booking ($75 by default). Empty: no cap.';
comment on column program_settings.game_code_valid_days is 'Discount games: a code expires this many days after it is claimed (7 by default).';
comment on column program_settings.game_trigger_car_pages is 'Discount games: show the game after this many car pages in a visit (0: not by pages).';
comment on column program_settings.game_trigger_seconds is 'Discount games: or after this many seconds on the site (0: not by time).';
comment on column program_settings.game_exit_intent is 'Discount games: or when the mouse leaves the page towards the tabs (computers only).';
comment on column program_settings.game_dismiss_days is 'Discount games: after the visitor closes the game, it stays away this many days (14 by default). Never again after a claim.';
comment on column program_settings.game_task_min_cars is 'Discount games: a claim from a visitor who viewed this many cars raises a Sales follow-up task (0: every claim).';
comment on column program_settings.game_reminder_hours is 'Discount games: the reminder email goes this many hours before an unused code expires (0: no reminder).';

-- ================================================================ 2. promo codes: a cap and a minimum rental length
alter table promo_codes
  add column if not exists max_discount_cents bigint check (max_discount_cents > 0),
  add column if not exists min_rental_days integer check (min_rental_days between 1 and 30);
comment on column promo_codes.max_discount_cents is '0069: the most a percentage code takes off one booking (empty: no cap).';
comment on column promo_codes.min_rental_days is '0069: the code applies only to a booking of at least this many billable days.';

-- A promo code's discount on a rental charge of p_base_cents (already net of other discounts), never above its cap.
create or replace function app.promo_discount_cents(p_promo uuid, p_base_cents bigint) returns bigint
language sql stable security definer set search_path = public, app as $$
  select case when p_base_cents <= 0 then 0
              when pc.percent_bps is not null then least(public.calc_bps(p_base_cents, pc.percent_bps), p_base_cents, coalesce(pc.max_discount_cents, p_base_cents))
              else least(pc.amount_cents, p_base_cents) end
    from promo_codes pc where pc.id = p_promo
$$;

alter function app.promo_code_problem(text, uuid, uuid, timestamptz) rename to promo_code_problem_pre0069;
create or replace function app.promo_code_problem(p_code text, p_renter uuid, p_booking uuid default null,
                                                  p_at timestamptz default now())
returns text language plpgsql stable security definer set search_path = public, app as $$
declare
  v text := app.promo_code_problem_pre0069(p_code, p_renter, p_booking, p_at);
  pc promo_codes;
begin
  if v is not null or p_booking is null then return v; end if;
  select * into pc from promo_codes where code = upper(btrim(coalesce(p_code, '')));
  if pc.min_rental_days is not null and (select b.billable_days from bookings b where b.id = p_booking) < pc.min_rental_days then
    return format('This code is for rentals of %s days or more', pc.min_rental_days);
  end if;
  return null;
end $$;

-- The minimum rental length of a code, for the public quote (no other detail of the code).
create or replace function app.promo_min_days(p_code text) returns integer
language sql stable security definer set search_path = public, app as $$
  select min_rental_days from promo_codes where code = upper(btrim(coalesce(p_code, '')))
$$;

-- The public quote: a code with a minimum rental length is not applied to a shorter quote, and says why.
create or replace function public.quote_booking(p_vehicle uuid, p_pickup timestamptz, p_return timestamptz, p_options jsonb default '{}'::jsonb)
returns jsonb language plpgsql security invoker set search_path = public, app as $$
declare
  q jsonb := app.quote_booking(p_vehicle, p_pickup, p_return, p_options);
  v_min integer;
begin
  if nullif(btrim(coalesce(p_options ->> 'promo_code', '')), '') is null then return q; end if;
  v_min := app.promo_min_days(p_options ->> 'promo_code');
  if v_min is null or coalesce((q ->> 'billable_days')::integer, 0) >= v_min then return q; end if;
  q := app.quote_booking(p_vehicle, p_pickup, p_return, p_options - 'promo_code');
  return q || jsonb_build_object('promo', jsonb_build_object('code', upper(btrim(p_options ->> 'promo_code')), 'applied', false,
    'problem', format('This code is for rentals of %s days or more', v_min)));
end $$;

-- ================================================================ 3. tables
create table game_plays (
  id          uuid primary key default gen_random_uuid(),
  token       text not null unique default (replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')),
  visitor_id  uuid not null,                               -- the browser's id (cookie cc_vid)
  session_id  uuid,
  game        text not null check (game = any (app.game_kinds())),
  prize       jsonb not null,                              -- the prize drawn, as it was in the table
  device      text check (device in ('phone', 'tablet', 'desktop')),
  path        text,
  trigger     text check (trigger in ('pages', 'time', 'exit')),
  created_at  timestamptz not null default now(),
  revealed_at timestamptz,
  claimed_at  timestamptz
);
create index game_plays_visitor_idx on game_plays (visitor_id, created_at desc);
create index game_plays_created_idx on game_plays (created_at);
comment on table game_plays is 'Discount games (0069): one game shown to a visitor, with the prize drawn by the database before it starts. No personal information.';
comment on column game_plays.token is 'The visitor''s secret for this play (kept in their browser). Never shown to staff.';

create table game_claims (
  id                uuid primary key default gen_random_uuid(),
  play_id           uuid not null unique references game_plays (id) on delete restrict,
  visitor_id        uuid not null,
  session_id        uuid references visitor_sessions (id) on delete set null,
  first_name        text not null check (length(first_name) between 1 and 60),
  email             text not null check (email = lower(email)),
  phone             text,
  marketing_consent boolean not null default false,
  consent_text      text,
  consent_version   text,
  promo_code_id     uuid not null unique references promo_codes (id),
  lead_id           uuid references leads (id) on delete set null,
  renter_id         uuid references renters (id) on delete set null,
  user_id           uuid references users (id) on delete set null,
  cars_viewed       integer not null default 0 check (cars_viewed >= 0),
  pages_viewed      integer not null default 0 check (pages_viewed >= 0),
  seconds_on_site   integer not null default 0 check (seconds_on_site >= 0),
  task_id           uuid references tasks (id) on delete set null,
  expires_at        timestamptz not null,
  resent_at         timestamptz,
  reminder_sent_at  timestamptz,
  created_at        timestamptz not null default now(),
  check (not marketing_consent or consent_text is not null)
);
create unique index game_claims_email_key on game_claims (email);
create unique index game_claims_phone_key on game_claims (phone) where phone is not null;
create unique index game_claims_visitor_key on game_claims (visitor_id);
create index game_claims_created_idx on game_claims (created_at desc);
comment on table game_claims is 'Discount games (0069): a prize claimed with a first name and email (one per email, phone and device), its promo code and the lead.';

do $$
declare t text;
begin
  foreach t in array array['game_plays', 'game_claims'] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('revoke all on %I from anon, authenticated', t);
  end loop;
end $$;
create trigger audit_game_claims after insert or update or delete on game_claims for each row execute function app.audit_row();

-- a claim makes the visitor known on Live visitors
alter table visitor_sessions drop constraint if exists visitor_sessions_identified_by_check;
alter table visitor_sessions add constraint visitor_sessions_identified_by_check check (identified_by in ('sign_in', 'email_link', 'chat', 'request', 'game'));

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, description) values
  ('game_lead_follow_up', 'sales', 'Follow up a discount game lead', 'normal', 'opening_minutes', 60,
   'A visitor who browsed several cars claimed a discount game code: call or message them and help them book')
on conflict (task_type) do update set queue = excluded.queue, title = excluded.title, priority = excluded.priority,
  due_kind = excluded.due_kind, due_amount = excluded.due_amount, description = excluded.description;

-- ================================================================ 4. prizes, words and settings for the browser
-- "10% off", "$50 off"
create or replace function app.game_prize_label(p jsonb) returns text
language sql immutable as $$
  select case when p ? 'percent_bps' then trim(trailing '.' from trim(trailing '0' from to_char((p ->> 'percent_bps')::numeric / 100, 'FM990.00'))) || '% off'
              else '$' || trim(trailing '.' from trim(trailing '0' from to_char((p ->> 'amount_cents')::numeric / 100, 'FM999990.00'))) || ' off' end
$$;
-- the words on a wheel slice or a Plinko slot: "10%", "$50"
create or replace function app.game_prize_short(p jsonb) returns text
language sql immutable as $$ select replace(app.game_prize_label(p), ' off', '') $$;

-- "the rental charge, up to $75.00", "the rental charge of a rental of 3 days or more"
create or replace function app.game_applies_to(p_percent boolean, p_max bigint, p_min_days integer) returns text
language sql stable security definer set search_path = public, app as $$
  select 'the rental charge'
    || case when p_min_days is not null then format(' of a rental of %s days or more', p_min_days) else '' end
    || case when p_percent and p_max is not null then ', up to ' || app.fmt_money(p_max) else '' end
$$;

-- The short terms shown with the game: the prizes, that the chances differ, the rules.
create or replace function app.game_terms_text() returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings();
  v_pct text[];
  v_amt text[];
  v_list text;
  v_top jsonb;
  v_total numeric;
begin
  select array_agg(replace(app.game_prize_label(x), ' off', '') order by (x ->> 'percent_bps')::numeric) filter (where x ? 'percent_bps'),
         array_agg(app.game_prize_label(x) || case when x ? 'min_days' then format(' %s+ day rentals', x ->> 'min_days') else ' your rental' end
                   order by (x ->> 'amount_cents')::numeric) filter (where x ? 'amount_cents'),
         sum((x ->> 'weight')::numeric)
    into v_pct, v_amt, v_total
    from jsonb_array_elements(ps.game_prizes) x;
  select x into v_top from jsonb_array_elements(ps.game_prizes) x order by (x ->> 'weight')::numeric desc limit 1;
  v_list := concat_ws(', or ',
    case when cardinality(v_pct) = 1 then v_pct[1] || ' off'
         when cardinality(v_pct) > 1 then array_to_string(v_pct[1:cardinality(v_pct) - 1], ', ') || ' or ' || v_pct[cardinality(v_pct)] || ' off' end,
    array_to_string(v_amt, ', or '));
  return 'Prizes: ' || v_list || '. '
    || case when (v_top ->> 'weight')::numeric * 2 > v_total then 'The chances differ: most players win ' || app.game_prize_label(v_top) || '. '
            else 'The chances differ by prize. ' end
    || 'Off the rental charge only' || case when ps.game_max_discount_cents is not null then ', up to ' || replace(app.fmt_money(ps.game_max_discount_cents), '.00', '') || ' per code' else '' end
    || format('. One use, on one booking, within %s days. One per person, email, phone and device. Not combinable with other promo codes.', ps.game_code_valid_days);
end $$;

-- What the browser needs before it shows a game (no secret).
create or replace function app.game_cfg() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('on', s.game_enabled, 'car_pages', s.game_trigger_car_pages, 'seconds', s.game_trigger_seconds,
    'exit', s.game_exit_intent, 'dismiss_days', s.game_dismiss_days)
    from (select (app.settings()).*) s
$$;

-- A weighted draw: the key of one entry of p (an array of objects with "weight", or an object of weights).
create or replace function app.game_draw(p jsonb, p_r double precision default random()) returns jsonb
language plpgsql volatile as $$
declare
  v_total numeric := 0;
  v_at numeric;
  x record;
begin
  if jsonb_typeof(p) = 'array' then
    select sum((e ->> 'weight')::numeric) into v_total from jsonb_array_elements(p) e;
    v_at := p_r::numeric * v_total;
    for x in select e as v, (e ->> 'weight')::numeric as w from jsonb_array_elements(p) e loop
      if v_at < x.w then return x.v; end if;
      v_at := v_at - x.w;
    end loop;
    return p -> (jsonb_array_length(p) - 1);
  end if;
  select sum((e.value::text)::numeric) into v_total from jsonb_each(p) e;
  v_at := p_r::numeric * v_total;
  for x in select to_jsonb(e.key) as v, (e.value::text)::numeric as w from jsonb_each(p) e where (e.value::text)::numeric > 0 order by e.key loop
    if v_at < x.w then return x.v; end if;
    v_at := v_at - x.w;
  end loop;
  return (select to_jsonb(e.key) from jsonb_each(p) e where (e.value::text)::numeric > 0 order by e.key desc limit 1);
end $$;

-- The marketing consent wording, word for word as the booking form shows it (legal.marketing_opt_in, tokens filled
-- from Site settings the way the site fills them), with its version. Shown with the game and recorded with a claim.
create or replace function app.game_marketing_text() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'text', btrim(replace(replace(regexp_replace(coalesce(b.body, ''), '\{\{(?!mailingAddress|contactEmail)\w+\}\}', '', 'g'),
                  '{{mailingAddress}}', coalesce(', ' || nullif(s.mailing_address, ''), '')), '{{contactEmail}}', coalesce(s.public_email, ''))),
    'version', coalesce(b.data ->> 'version', (select m.data ->> 'last_updated' from site_content_blocks m where m.block_key = 'legal.meta'), ''))
    from (select 1) one
    left join site_content_blocks b on b.block_key = 'legal.marketing_opt_in'
    left join site_settings s on true
$$;

-- The prize as the browser sees it: words and the slices of the wheel and the slots of Plinko.
create or replace function app.game_play_json(g game_plays) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('ok', true, 'token', g.token, 'game', g.game,
    'prize', jsonb_build_object('key', g.prize ->> 'key', 'label', app.game_prize_label(g.prize), 'short', app.game_prize_short(g.prize),
                                'min_days', (g.prize ->> 'min_days')::integer),
    'prizes', (select jsonb_agg(jsonb_build_object('key', x ->> 'key', 'short', app.game_prize_short(x), 'label', app.game_prize_label(x)) order by o)
                 from jsonb_array_elements((app.settings()).game_prizes) with ordinality t(x, o)),
    'terms', app.game_terms_text(), 'consent', app.game_marketing_text() ->> 'text', 'revealed', g.revealed_at is not null)
$$;

-- ================================================================ 5. play and claim
-- A visitor qualifies: the games are on, not signed in, not known by email, never claimed. The same visitor gets the
-- same game and prize again while their last play is within the dismiss period (no new draw by reloading).
create or replace function app.game_start(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings();
  v_vid uuid := case when p ->> 'vid' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then (p ->> 'vid')::uuid end;
  v_sid uuid := case when p ->> 'sid' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then (p ->> 'sid')::uuid end;
  g game_plays;
begin
  if not ps.game_enabled then return jsonb_build_object('ok', false, 'reason', 'off'); end if;
  if v_vid is null then return jsonb_build_object('ok', false, 'reason', 'bad ids'); end if;
  if app.uid() is not null then return jsonb_build_object('ok', false, 'reason', 'signed_in'); end if;
  if exists (select 1 from game_claims c where c.visitor_id = v_vid) then return jsonb_build_object('ok', false, 'reason', 'claimed'); end if;
  if exists (select 1 from visitor_sessions s where s.visitor_id = v_vid and (s.renter_id is not null or s.user_id is not null or s.known_email is not null)) then
    return jsonb_build_object('ok', false, 'reason', 'known');
  end if;
  select * into g from game_plays where visitor_id = v_vid and claimed_at is null and created_at > now() - make_interval(days => ps.game_dismiss_days)
   order by created_at desc limit 1;
  if g.id is not null then return app.game_play_json(g); end if;
  if not app.rate_limit('game-start:' || v_vid, 10, interval '1 hour') or not app.rate_limit('game-start', 3000, interval '1 hour') then
    return jsonb_build_object('ok', false, 'reason', 'limited');
  end if;
  insert into game_plays (visitor_id, session_id, game, prize, device, path, trigger)
  values (v_vid, v_sid, app.game_draw(ps.game_weights) #>> '{}', app.game_draw(ps.game_prizes),
          case when p ->> 'device' in ('phone', 'tablet', 'desktop') then p ->> 'device' end, left(p ->> 'path', 300),
          case when p ->> 'trigger' in ('pages', 'time', 'exit') then p ->> 'trigger' end)
  returning * into g;
  return app.game_play_json(g);
end $$;

-- The visitor finished the game (the prize is on screen).
create or replace function app.game_reveal(p_token text) returns boolean
language sql security definer set search_path = public, app as $$
  update game_plays set revealed_at = coalesce(revealed_at, now()) where token = p_token returning true
$$;

-- "+16475551234" from what the visitor typed; null when it is not a phone number.
create or replace function app.game_phone(p text) returns text
language sql immutable as $$
  select case
    when d ~ '^[2-9][0-9]{9}$' then '+1' || d
    when d ~ '^1[2-9][0-9]{9}$' then '+' || d
    when btrim(p) like '+%' and length(d) between 8 and 15 then '+' || d
  end
  from (select regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g') as d) x
$$;

-- A short, unambiguous code: WIN-7KQ4-XM2P.
create or replace function app.game_code() returns text
language plpgsql volatile as $$
declare
  a text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  c text;
begin
  loop
    c := 'WIN-' || (select string_agg(substr(a, 1 + floor(random() * 32)::integer, 1), '') from generate_series(1, 4))
         || '-' || (select string_agg(substr(a, 1 + floor(random() * 32)::integer, 1), '') from generate_series(1, 4));
    exit when not exists (select 1 from promo_codes where code = c);
  end loop;
  return c;
end $$;

-- Claim the prize (the site's /api/games, as the server). One per email, phone and device; the code by email.
create or replace function app.server_game_claim(p jsonb, p_user uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings();
  g game_plays;
  c game_claims;
  pc promo_codes;
  v_name text := nullif(left(btrim(regexp_replace(coalesce(p ->> 'first_name', ''), '\s+', ' ', 'g')), 60), '');
  v_email text := lower(nullif(btrim(coalesce(p ->> 'email', '')), ''));
  v_phone text := app.game_phone(p ->> 'phone');
  v_consent boolean := coalesce((p ->> 'marketing')::boolean, false);
  v_sid uuid := case when p ->> 'sid' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then (p ->> 'sid')::uuid end;
  v_cars integer := least(greatest(coalesce(case when p ->> 'cars_viewed' ~ '^\d{1,4}$' then (p ->> 'cars_viewed')::integer end, 0), 0), 500);
  v_pages integer := least(greatest(coalesce(case when p ->> 'pages_viewed' ~ '^\d{1,4}$' then (p ->> 'pages_viewed')::integer end, 0), 0), 5000);
  v_secs integer := least(greatest(coalesce(case when p ->> 'seconds' ~ '^\d{1,7}$' then (p ->> 'seconds')::integer end, 0), 0), 86400);
  v_renter uuid;
  v_user uuid;
  v_lead uuid;
  v_label text;
  v_applies text;
  v_task uuid;
  v_session_cars integer;
  v_mk jsonb;
begin
  if not ps.game_enabled then return jsonb_build_object('ok', false, 'error', 'off', 'message', 'The game is closed for now.'); end if;
  if p_user is not null then return jsonb_build_object('ok', false, 'error', 'signed_in', 'message', 'The game is for visitors who are not signed in.'); end if;
  select * into g from game_plays where token = p ->> 'token' for update;
  if g.id is null then return jsonb_build_object('ok', false, 'error', 'not_found', 'message', 'This game has ended. Reload the page.'); end if;
  if g.claimed_at is not null then return jsonb_build_object('ok', false, 'error', 'claimed', 'message', 'This prize was already claimed. The code is in your email.'); end if;
  if v_name is null then return jsonb_build_object('ok', false, 'error', 'first_name', 'message', 'Enter your first name.'); end if;
  if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]{2,}$' or length(v_email) > 200 then
    return jsonb_build_object('ok', false, 'error', 'email', 'message', 'Enter an email address like name@example.com.');
  end if;
  if nullif(btrim(coalesce(p ->> 'phone', '')), '') is not null and v_phone is null then
    return jsonb_build_object('ok', false, 'error', 'phone', 'message', 'Enter a mobile number with area code, or leave it empty.');
  end if;
  v_mk := app.game_marketing_text();
  if v_consent and nullif(v_mk ->> 'text', '') is null then v_consent := false; end if;
  if not app.rate_limit('game-claim:' || g.visitor_id, 8, interval '1 hour')
     or (nullif(p ->> 'ip_key', '') is not null and not app.rate_limit('game-claim-ip:' || (p ->> 'ip_key'), 20, interval '1 hour')) then
    return jsonb_build_object('ok', false, 'error', 'limited', 'message', 'Too many tries. Please wait a few minutes.');
  end if;

  -- one per email, phone and device
  select * into c from game_claims where email = v_email;
  if c.id is not null then
    -- the code goes again to its own address (never shown here), at most once a day, while it can still be used
    if c.expires_at > now() and (c.resent_at is null or c.resent_at < now() - interval '1 day')
       and not exists (select 1 from promo_redemptions r where r.promo_code_id = c.promo_code_id and r.status in ('applied', 'redeemed')) then
      perform app.emit_event('renter_game_code', 'game_claim', c.id, '{}'::jsonb, 'renter_game_code:' || c.id || ':resend:' || app.local_date(now()));
      update game_claims set resent_at = now() where id = c.id;
    end if;
    return jsonb_build_object('ok', false, 'error', 'email_used', 'message', 'This email already has a code. We sent it to that inbox again.');
  end if;
  if v_phone is not null and exists (select 1 from game_claims where phone = v_phone) then
    return jsonb_build_object('ok', false, 'error', 'phone_used', 'message', 'This mobile number already has a code. One per person.');
  end if;
  if exists (select 1 from game_claims where visitor_id = g.visitor_id) then
    return jsonb_build_object('ok', false, 'error', 'device_used', 'message', 'A code was already claimed on this device. One per person.');
  end if;

  v_label := app.game_prize_label(g.prize);
  insert into promo_codes (code, description, percent_bps, amount_cents, valid_from, valid_until, max_uses, once_per_renter, source, max_discount_cents, min_rental_days)
  values (app.game_code(), format('Discount game (%s): %s', g.game, v_label), (g.prize ->> 'percent_bps')::integer, (g.prize ->> 'amount_cents')::bigint,
          now(), now() + make_interval(days => ps.game_code_valid_days), 1, true, 'discount_game',
          case when g.prize ? 'percent_bps' then ps.game_max_discount_cents end, (g.prize ->> 'min_days')::integer)
  returning * into pc;
  v_applies := app.game_applies_to(pc.percent_bps is not null, pc.max_discount_cents, pc.min_rental_days);

  v_user := (select u.id from users u where lower(u.email) = v_email limit 1);
  v_renter := coalesce((select r.id from renters r where r.user_id = v_user), (select r.id from renters r where lower(r.email) = v_email limit 1));

  -- the visitor's session: kept as one essential row if the beacon did not record it (no analytics consent)
  if v_sid is not null and not exists (select 1 from visitor_sessions where id = v_sid) then
    insert into visitor_sessions (id, visitor_id, consent, device, city, region, country, landing_path, current_path)
    values (v_sid, g.visitor_id, 'essential', g.device, left(nullif(p ->> 'city', ''), 80), left(nullif(p ->> 'region', ''), 80), left(nullif(p ->> 'country', ''), 2),
            g.path, g.path)
    on conflict (id) do nothing;
  end if;
  update visitor_sessions set known_name = coalesce(known_name, v_name), known_email = coalesce(known_email, v_email),
         renter_id = coalesce(renter_id, v_renter), identified_by = coalesce(identified_by, 'game')
   where visitor_id = g.visitor_id;
  v_session_cars := coalesce((select max(cardinality(s.cars_viewed)) from visitor_sessions s where s.visitor_id = g.visitor_id), 0);
  v_cars := greatest(v_cars, v_session_cars);

  insert into leads (kind, name, email, phone, message, payload, source, source_url, consent_marketing, consent_text, consent_at)
  values ('other', v_name, v_email, v_phone, format('Discount game: claimed %s (%s)', v_label, pc.code),
          jsonb_build_object('game', g.game, 'prize_key', g.prize ->> 'key', 'prize_label', v_label, 'code', pc.code, 'cars_viewed', v_cars, 'pages_viewed', v_pages),
          'discount_game', g.path, v_consent, case when v_consent then v_mk ->> 'text' end, case when v_consent then now() end)
  returning id into v_lead;

  insert into game_claims (play_id, visitor_id, session_id, first_name, email, phone, marketing_consent, consent_text, consent_version, promo_code_id, lead_id,
                           renter_id, user_id, cars_viewed, pages_viewed, seconds_on_site, expires_at)
  values (g.id, g.visitor_id, case when exists (select 1 from visitor_sessions where id = v_sid) then v_sid end, v_name, v_email, v_phone, v_consent,
          case when v_consent then v_mk ->> 'text' end, case when v_consent then nullif(v_mk ->> 'version', '') end,
          pc.id, v_lead, v_renter, v_user, v_cars, v_pages, v_secs, pc.valid_until)
  returning * into c;
  update game_plays set claimed_at = now(), revealed_at = coalesce(revealed_at, now()) where id = g.id;

  -- marketing consent: an existing account is opted in (unless it unsubscribed); a later account by app.game_consent_carry
  if v_consent and v_user is not null then perform app.game_consent_apply(v_user, c); end if;

  perform app.emit_event('renter_game_code', 'game_claim', c.id, '{}'::jsonb, 'renter_game_code:' || c.id);

  if v_cars >= ps.game_task_min_cars then
    v_task := app.raise_task(p_type => 'game_lead_follow_up',
      p_title => left(format('Claimed %s, viewed %s %s: %s', v_label, v_cars, case when v_cars = 1 then 'car' else 'cars' end, v_name), 200),
      p_detail => format('Discount game lead. Contact: %s%s. Code %s (%s), expires %s.%s Help them pick a car and send a request; the code goes in the promo code box.',
                         v_email, coalesce(', ' || v_phone, ''), pc.code, v_applies, app.fmt_date(pc.valid_until),
                         case when v_consent then ' Agreed to marketing.' else ' No marketing consent: about this request only.' end),
      p_renter => v_renter, p_related_table => 'game_claims', p_related_id => c.id, p_dedupe => 'game-lead:' || c.id);
    update game_claims set task_id = v_task where id = c.id;
  end if;

  return jsonb_build_object('ok', true, 'code', pc.code, 'prize_label', v_label, 'applies_to', v_applies,
    'expires', app.fmt_date(pc.valid_until), 'expires_at', pc.valid_until, 'min_days', pc.min_rental_days, 'email', v_email);
end $$;

-- Marketing consent from a claim, on an account: opted in with the claim's wording (never over an unsubscribe).
create or replace function app.game_consent_apply(p_user uuid, c game_claims) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if not c.marketing_consent then return; end if;
  if exists (select 1 from users u where u.id = p_user and (u.marketing_opt_in or u.marketing_unsubscribed_at is not null)) then return; end if;
  update users set marketing_opt_in = true, marketing_opt_in_at = c.created_at where id = p_user;
  insert into consents (user_id, consent_code, text_version, text_shown, given_at)
  values (p_user, 'marketing', coalesce(c.consent_version, 'discount-game'), c.consent_text, c.created_at);
  update game_claims set user_id = p_user where id = c.id and user_id is null;
end $$;

-- An account opened later with a claim's email: the claim's consent and the renter link carry over.
create or replace function app.game_consent_carry() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  c game_claims;
begin
  if new.email is null then return new; end if;
  select * into c from game_claims where email = lower(new.email);
  if c.id is null then return new; end if;
  update game_claims set user_id = coalesce(user_id, new.id) where id = c.id;
  if c.marketing_consent then perform app.game_consent_apply(new.id, c); end if;
  return new;
end $$;
create trigger game_consent_carry after insert on users for each row execute function app.game_consent_carry();

-- A game code on a booking: the lead is converted when the booking is confirmed; the follow-up task closes.
create or replace function app.game_redemption_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  c game_claims;
begin
  select * into c from game_claims where promo_code_id = new.promo_code_id;
  if c.id is null then return new; end if;
  update game_claims set renter_id = coalesce(renter_id, new.renter_id) where id = c.id;
  if new.status = 'redeemed' then
    update leads set status = 'converted', updated_at = now() where id = c.lead_id and status <> 'converted';
  end if;
  if new.status in ('applied', 'redeemed') and c.task_id is not null then
    update tasks set status = 'done', completed_at = now(), completion_note = coalesce(completion_note, 'The code is on booking request ' || (select b.booking_number from bookings b where b.id = new.booking_id))
     where id = c.task_id and status in ('open', 'in_progress', 'waiting');
  end if;
  return new;
end $$;
create trigger game_redemption_after after insert or update of status on promo_redemptions for each row execute function app.game_redemption_after();

-- ================================================================ 6. the reminder, and housekeeping
create or replace function app.job_game_reminders(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings();
  c game_claims;
  n integer := 0;
  v_gone integer;
begin
  if ps.game_reminder_hours > 0 then
    for c in select gc.* from game_claims gc
              where gc.reminder_sent_at is null and gc.expires_at > p_now and gc.expires_at - make_interval(hours => ps.game_reminder_hours) <= p_now
                and gc.created_at < gc.expires_at - make_interval(hours => ps.game_reminder_hours)
                and not exists (select 1 from promo_redemptions r where r.promo_code_id = gc.promo_code_id and r.status in ('applied', 'redeemed'))
                and exists (select 1 from promo_codes pc where pc.id = gc.promo_code_id and pc.is_active)
              for update skip locked loop
      perform app.emit_event('renter_game_code_reminder', 'game_claim', c.id, '{}'::jsonb, 'renter_game_code_reminder:' || c.id);
      update game_claims set reminder_sent_at = p_now where id = c.id;
      n := n + 1;
    end loop;
  end if;
  -- a claim is kept 24 months after its code expired, unless the person became a customer (the privacy policy)
  delete from leads l using game_claims gc where gc.lead_id = l.id and gc.renter_id is null and gc.expires_at < p_now - interval '24 months';
  with gone as (delete from game_claims gc where gc.renter_id is null and gc.expires_at < p_now - interval '24 months' returning gc.play_id)
  delete from game_plays g using gone where g.id = gone.play_id;
  -- plays never claimed carry no personal information; they go after the visit records' period
  delete from game_plays g where g.claimed_at is null and g.created_at < p_now - make_interval(days => ps.visitor_events_keep_days);
  get diagnostics v_gone = row_count;
  return format('%s reminders, %s old plays removed', n, v_gone);
end $$;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-game-reminders', '*/30 * * * *', $q$select app.job_game_reminders()$q$);
  end if;
end $$;

-- ================================================================ 7. the emails
alter function app.notification_recipients(app_events, notification_catalogue) rename to notification_recipients_pre0069;
create or replace function app.notification_recipients(p_event app_events, p_c notification_catalogue)
returns table (audience text, user_id uuid, email text, name text, renter_id uuid, owner_id uuid, immediate boolean)
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_c.code in ('renter_game_code', 'renter_game_code_reminder') then
    return query select 'renter'::text, c.user_id, c.email, c.first_name, c.renter_id, null::uuid, true
                   from game_claims c where c.id = p_event.entity_id;
    return;
  end if;
  return query select * from app.notification_recipients_pre0069(p_event, p_c);
end $$;

alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre0069;
create or replace function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_pre0069(p_code, p_event, p_to);
  c game_claims;
  pc promo_codes;
begin
  if p_code in ('renter_game_code', 'renter_game_code_reminder') then
    select * into c from game_claims where id = p_event.entity_id;
    select * into pc from promo_codes where id = c.promo_code_id;
    x := x || jsonb_build_object(
      'first_name', coalesce(nullif(split_part(c.first_name, ' ', 1), ''), 'there'),
      'prize_label', app.game_prize_label(case when pc.percent_bps is not null then jsonb_build_object('percent_bps', pc.percent_bps) else jsonb_build_object('amount_cents', pc.amount_cents) end),
      'discount_code', pc.code,
      'discount_expires', app.fmt_date(pc.valid_until),
      'discount_applies_to', app.game_applies_to(pc.percent_bps is not null, pc.max_discount_cents, pc.min_rental_days),
      'discount_terms', 'Off the rental charge only, not fees, the Deposit or tax.'
                        || case when pc.min_rental_days is not null then format(' For rentals of %s days or more.', pc.min_rental_days) else '' end);
  end if;
  return x;
end $$;

-- ================================================================ 8. staff: leads, the report, the lead's next step
create or replace function app.game_claim_status(c game_claims) returns text
language sql stable security definer set search_path = public, app as $$
  select case
    when exists (select 1 from promo_redemptions r where r.promo_code_id = c.promo_code_id and r.status = 'redeemed') then 'used'
    when exists (select 1 from promo_redemptions r where r.promo_code_id = c.promo_code_id and r.status = 'applied') then 'on_request'
    when c.expires_at <= now() then 'expired'
    else 'unused' end
$$;

create or replace function app.game_leads(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_limit integer := least(greatest(coalesce((p ->> 'limit')::integer, 100), 1), 500);
  v_q text := nullif(btrim(lower(coalesce(p ->> 'q', ''))), '');
begin
  perform app.assert_live_staff(p_by);
  return jsonb_build_object('rows', coalesce((
    select jsonb_agg(r order by r ->> 'created_at' desc) from (
      select jsonb_build_object(
        'claim_id', c.id, 'lead_id', c.lead_id, 'created_at', c.created_at, 'first_name', c.first_name, 'email', c.email, 'phone', c.phone,
        'game', g.game, 'prize_label', app.game_prize_label(g.prize), 'code', pc.code, 'expires_at', c.expires_at,
        'status', app.game_claim_status(c),
        'booking_number', (select b.booking_number from promo_redemptions r join bookings b on b.id = r.booking_id
                            where r.promo_code_id = c.promo_code_id and r.status in ('applied', 'redeemed') order by r.applied_at desc limit 1),
        'marketing_consent', c.marketing_consent, 'cars_viewed', c.cars_viewed, 'pages_viewed', c.pages_viewed, 'seconds_on_site', c.seconds_on_site,
        'visits', (select count(*) from visitor_sessions s where s.visitor_id = c.visitor_id),
        'city', s.city, 'device', s.device, 'session_id', c.session_id,
        'on_site_now', s.last_seen_at > now() - make_interval(mins => (app.settings()).visitor_live_minutes) and s.ended_at is null,
        'lead_status', l.status, 'assigned_name', (select u.full_name from users u where u.id = l.assigned_to),
        'task_id', c.task_id, 'task_status', (select t.status from tasks t where t.id = c.task_id), 'renter_id', c.renter_id,
        'reminder_sent_at', c.reminder_sent_at) as r
        from game_claims c
        join game_plays g on g.id = c.play_id
        join promo_codes pc on pc.id = c.promo_code_id
        left join leads l on l.id = c.lead_id
        left join lateral (select * from visitor_sessions x where x.visitor_id = c.visitor_id order by x.last_seen_at desc limit 1) s on true
       where (v_q is null or c.email like '%' || v_q || '%' or lower(c.first_name) like '%' || v_q || '%' or coalesce(c.phone, '') like '%' || v_q || '%' or lower(pc.code) like '%' || v_q || '%')
         and (nullif(p ->> 'status', '') is null or app.game_claim_status(c) = p ->> 'status')
       order by c.created_at desc limit v_limit) x), '[]'::jsonb),
    'report', app.game_report(p_by, jsonb_build_object('days', coalesce((p ->> 'days')::integer, 30))));
end $$;

-- Plays, claims, codes used, bookings and revenue from game codes over the last p.days days (30 by default).
create or replace function app.game_report(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_days integer := least(greatest(coalesce((p ->> 'days')::integer, 30), 1), 730);
  v_from timestamptz := now() - make_interval(days => v_days);
  v jsonb;
begin
  perform app.assert_live_staff(p_by);
  with plays as (select * from game_plays where created_at >= v_from),
       claims as (select c.*, g.game, g.prize from game_claims c join game_plays g on g.id = c.play_id where c.created_at >= v_from),
       red as (select r.*, cl.game, cl.prize, b.rental_charge_cents - b.discount_cents - b.staff_discount_cents - b.promo_discount_cents as net_rental
                 from promo_redemptions r join claims cl on cl.promo_code_id = r.promo_code_id join bookings b on b.id = r.booking_id
                where r.status in ('applied', 'redeemed'))
  select jsonb_build_object(
    'days', v_days,
    'plays', (select count(*) from plays),
    'revealed', (select count(*) from plays where revealed_at is not null),
    'claims', (select count(*) from claims),
    'claim_rate_bps', case when (select count(*) from plays) > 0 then round((select count(*) from claims) * 10000.0 / (select count(*) from plays)) else 0 end,
    'with_consent', (select count(*) from claims where marketing_consent),
    'on_requests', (select count(*) from red),
    'bookings', (select count(*) from red where status = 'redeemed'),
    'redemption_rate_bps', case when (select count(*) from claims) > 0 then round((select count(*) from red where status = 'redeemed') * 10000.0 / (select count(*) from claims)) else 0 end,
    'revenue_cents', (select coalesce(sum(net_rental), 0) from red where status = 'redeemed'),
    'discount_cents', (select coalesce(sum(discount_cents), 0) from red where status = 'redeemed'),
    'by_game', (select coalesce(jsonb_agg(jsonb_build_object('game', k, 'plays', (select count(*) from plays where game = k), 'claims', (select count(*) from claims where game = k),
                 'bookings', (select count(*) from red where game = k and status = 'redeemed')) order by o), '[]'::jsonb)
                  from unnest(app.game_kinds()) with ordinality u(k, o)),
    'by_prize', (select coalesce(jsonb_agg(jsonb_build_object('prize', app.game_prize_label(x), 'claims', (select count(*) from claims where prize ->> 'key' = x ->> 'key'),
                 'bookings', (select count(*) from red where prize ->> 'key' = x ->> 'key' and status = 'redeemed')) order by o), '[]'::jsonb)
                   from jsonb_array_elements((app.settings()).game_prizes) with ordinality t(x, o)))
    into v;
  return v;
end $$;

-- Mark a game lead contacted, take it, or close it (Admins, customer service and Sales).
create or replace function app.game_lead_do(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
begin
  perform app.assert_live_staff(p_by);
  update leads set status = coalesce(case when p ->> 'status' in ('new', 'contacted', 'qualified', 'converted', 'closed', 'spam') then p ->> 'status' end, status),
                   assigned_to = case when coalesce((p ->> 'take')::boolean, false) then p_by else assigned_to end,
                   closed_reason = coalesce(nullif(left(btrim(p ->> 'closed_reason'), 300), ''), closed_reason), updated_at = now()
   where id = (p ->> 'id')::uuid and source = 'discount_game'
  returning id into v_id;
  if v_id is null then raise exception 'Lead not found' using errcode = 'P0002'; end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'UPDATE', 'leads', v_id, jsonb_strip_nulls(jsonb_build_object('status', p ->> 'status', 'take', p ->> 'take')));
  return jsonb_build_object('id', v_id);
end $$;

-- ================================================================ 9. the doors and privileges
create or replace function app.ops69(p_user uuid, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  case p_name
  when 'game_leads' then return app.game_leads(p_user, p);
  when 'game_report' then return app.game_report(p_user, p);
  when 'game_lead_update' then return app.game_lead_do(p_user, p);
  else raise exception 'Unknown action %', p_name using errcode = '22023';
  end case;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0069;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
begin
  if (p_call in ('va_read', 'admin_read', 'ops_read') and p_name in ('game_leads', 'game_report'))
     or (p_call in ('va_do', 'admin_do', 'ops_do') and p_name = 'game_lead_update') then
    if p_ ? '_va' then perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.ops69(p_user, p_call, p_name, p_ - '_va');
  end if;
  return app.door_pre0069(p_user, p_aal, p_call, p_name, p);
end $$;

-- public wrappers: three for the browser (anon), the claim for the server
create or replace function public.game_cfg() returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.game_cfg() $$;
create or replace function public.game_start(p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.game_start(p) $$;
create or replace function public.game_reveal(p_token text) returns boolean
language sql security definer set search_path = public, app as $$ select coalesce(app.game_reveal(p_token), false) $$;
create or replace function public.server_game_claim(p jsonb, p_user uuid default null) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_game_claim(p, p_user) $$;
create or replace function public.game_terms() returns text
language sql stable security definer set search_path = public, app as $$ select app.game_terms_text() $$;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array[
              'game_kinds', 'game_prizes_ok', 'game_weights_ok', 'promo_discount_cents', 'promo_code_problem', 'promo_min_days', 'game_prize_label',
              'game_prize_short', 'game_applies_to', 'game_terms_text', 'game_marketing_text', 'game_cfg', 'game_draw', 'game_play_json', 'game_start', 'game_reveal', 'game_phone',
              'game_code', 'server_game_claim', 'game_consent_apply', 'game_consent_carry', 'game_redemption_after', 'job_game_reminders',
              'notification_recipients', 'notification_payload', 'game_claim_status', 'game_leads', 'game_report', 'game_lead_do', 'ops69', 'door']))
        or (n.nspname = 'public' and p.proname = any (array['server_game_claim']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
  -- the check constraints of program_settings call these two for every role that writes settings
  grant execute on function app.game_prizes_ok(jsonb), app.game_weights_ok(jsonb), app.game_kinds() to authenticated;
  -- the browser's: the settings, a play, the reveal, the terms; the public quote reads a code's minimum length
  revoke all on function public.game_cfg(), public.game_start(jsonb), public.game_reveal(text), public.game_terms() from public;
  grant execute on function public.game_cfg(), public.game_start(jsonb), public.game_reveal(text), public.game_terms() to anon, authenticated, service_role;
  grant execute on function app.promo_min_days(text) to anon, authenticated;
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
             join (values ('door_pre0069', 'door'), ('notification_recipients_pre0069', 'notification_recipients'), ('ntf_payload_pre0069', 'notification_payload'),
                          ('promo_code_problem_pre0069', 'promo_code_problem')) m(old_name, new_name)
               on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    execute format('revoke all on function %s from public, anon, authenticated', v_new);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;
-- promo_discount_cents was replaced in place: the same privileges as before (create or replace keeps them)

-- ================================================================ 10. the privacy policy and the terms
-- The live copy changes only where it still carries our text; an Admin's own edit is left as it is.
update site_content_blocks
   set body = replace(body,
     'Live chat is answered first by an automated assistant',
     'Discount games are shown to visitors who browse several cars or stay a while. To decide when, your browser counts the pages and cars you view and the time on the Site, and remembers whether you closed or played a game. This stays on your device and is not sent to us unless you claim a prize. When you claim a prize, we keep your first name, email, mobile number if you give it, the code, the game and the pages and cars you viewed in that visit, so we can send the code and help you book. We send the code and one reminder before it expires. We send offers only if you tick the marketing box.

Live chat is answered first by an automated assistant')
 where block_key = 'legal.privacy' and body like '%Live chat is answered first by an automated assistant%' and body not like '%Discount games are shown%';
update site_content_blocks
   set body = replace(body,
     '| Live chat: the conversation and the page you were on, and your name, email or phone if you give them | To answer you and follow up on your request |',
     '| Live chat: the conversation and the page you were on, and your name, email or phone if you give them | To answer you and follow up on your request |
| Discount games: your first name, email, mobile number if given, the code and the pages and cars you viewed in that visit | To send the code and a reminder, and to help you book; offers only with your consent |')
 where block_key = 'legal.privacy' and body like '%| Live chat: the conversation and the page you were on%' and body not like '%| Discount games:%';
update site_content_blocks
   set body = replace(body, '| Marketing contact details | Until you unsubscribe |',
     '| Discount game claims | 24 months after the code expires, unless you become a customer |
| Marketing contact details | Until you unsubscribe |')
 where block_key = 'legal.privacy' and body like '%| Marketing contact details | Until you unsubscribe |%' and body not like '%Discount game claims%';
update site_content_blocks
   set body = body || '

**14. Promo codes and discount games.** A discount game on the Site is a free giveaway: no purchase or payment is needed to play, and every play wins a promo code. The prizes and that their chances differ are shown with the game. A code comes off the rental charge only, never fees, the Deposit or tax, up to the maximum shown with it, on one booking request, and cannot be combined with another promo code. It expires on the date in the email that delivers it, and a code for a minimum rental length applies only to a booking that long. One code per person, email address, mobile number and device. A code has no cash value, cannot be sold or transferred, and is void if claimed with false details or by automated means. We may end a game at any time; codes already sent stay valid until they expire.'
 where block_key = 'legal.terms' and body not like '%Promo codes and discount games%';
update site_content_blocks set data = data || jsonb_build_object('last_updated', 'October 19, 2026')
 where block_key = 'legal.meta' and (data ->> 'last_updated') in ('October 8, 2026', 'October 16, 2026');

-- ================================================================ 11. the email catalogue
-- CATALOGUE 0069 START (generated by supabase/seed/0069_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('renter_game_code', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Your CarmaCars code: {{prize_label}}', 'Code {{discount_code}}, good until {{discount_expires}}.', 'Immediate', 'A visitor plays a discount game on the site (spin the wheel, scratch to reveal, quick blackjack, cup shuffle or Plinko) and claims the prize with their first name and email. One email to that address with the single-use code. Transactional: it is the code they asked for, sent with or without marketing consent.', null, '/cars', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"discount_applies_to","type":"string"},{"name":"discount_code","type":"string"},{"name":"discount_expires","type":"string"},{"name":"discount_terms","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"prize_label","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_game_code.html', 'templates/renter_game_code.txt'),
  ('renter_game_code_reminder', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Your {{prize_label}} code ends tomorrow', 'Code {{discount_code}} is good until {{discount_expires}}.', '24 hours before the code expires', 'A code won in a discount game on the site has not been used and runs out in game_reminder_hours (24 by default). Sent once per code, to the address that claimed it. Transactional: a reminder of the code they asked for. Not sent once the code is on a booking request.', null, '/cars', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"discount_applies_to","type":"string"},{"name":"discount_code","type":"string"},{"name":"discount_expires","type":"string"},{"name":"discount_terms","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"prize_label","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_game_code_reminder.html', 'templates/renter_game_code_reminder.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 0069 END
update notification_catalogue set emitted_by = 'app.server_game_claim (0069)' where code = 'renter_game_code';
update notification_catalogue set emitted_by = 'app.job_game_reminders (0069)' where code = 'renter_game_code_reminder';

-- ================================================================ 12. the guides for this release
create or replace function app.guide_release_0069(p_portal text, p_slug text, p_kind text, p_after text, p_base_md text, p_title text, p_blurb text,
                                                  p_md text, p_html text) returns text
language sql security definer set search_path = public, app as $$
  select app.guide_release_section(p_portal, p_slug, p_kind, p_after, p_base_md, p_title, p_blurb, p_md, p_html)
$$;
revoke all on function app.guide_release_0069(text, text, text, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function app.guide_release_0069(text, text, text, text, text, text, text, text, text) to service_role;

-- GUIDES 0069 START (generated by supabase/seed/0069_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_0069('admin', 'discount-games-and-leads', 'chapter', 'live-visitors-and-live-chat', null, 'Discount games and leads', 'The giveaway game, the code it sends, game leads to call, and the report.',
  'Visitors who are not signed in and browse a few cars get one quick game: spin the wheel, scratch to reveal, quick blackjack, cup shuffle or Plinko. Every play wins a promo code. To see the code they give a first name and an email (a mobile number is optional), so you get a lead. It is on by default; nothing needs setting up.

## What the visitor sees

- After 2 car pages, or 60 seconds on the site, or (on a computer) when the mouse heads for the tabs. A card slides in at the bottom; on a phone it is a sheet at the bottom, never a full-screen block, and it always closes.
- Never for someone signed in or already known by email, never on booking, pay, sign or sign-in pages, never on the first page of a visit from a search engine on a phone, never over the cookie banner. After closing it, not again for 14 days; after claiming, never again.
- Every play wins: 5% off (70 in 100), 10% off (25), 15% off (4) or $50 off a rental of 3 days or more (1). The prize is decided before the game starts; the game only shows it. The short terms with the game list the prizes and say the chances differ.
- The code (for example WIN-7KQ4-XM2P) comes off the rental charge only, up to $75 for a percentage, on one booking, within 7 days, one per person, email, phone and device, never with another code. The email with the code goes either way; one reminder goes 24 hours before it expires. Offers only with the marketing box ticked.
- On this device the code fills itself into the promo code box of the request form. Like every promo code, the discount is shared with the owner in the split.

## Leads

**Bookings** > **Leads**.

1. The tiles: plays, claims, codes on booking requests, bookings, revenue and discounts from game codes in the last 30 days, then the same by game and by prize.
2. Each claim: when, the name (and "on the site now"), email and phone, the prize and game, the code and whether it is used (with the booking), marketing consent, and the visit: cars and pages viewed, minutes, city and device.
3. Press **Call** or **Email**, then **Contacted** (it is yours). **Close** with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.
4. A visitor who viewed 3 cars or more also gets a Sales task, for example "Claimed 10% off, viewed 6 cars: Maya". It closes when the code goes on a request.

## Settings

**Settings** > **Discount games**.

- On or off, the cap for percentage codes ($75), how long a code is good for (7 days), when it shows (2 car pages, 60 seconds, exit intent), the days before it shows again after closing (14), the cars viewed for a Sales task (3) and the reminder (24 hours).
- Prizes and games: each prize with its percent or dollars, a minimum rental length and its chance; each game''s weight (0 turns it off). Press **Save prizes and games**. Codes already sent keep their value.
',
  '<p class="gd-p">Visitors who are not signed in and browse a few cars get one quick game: spin the wheel, scratch to reveal, quick blackjack, cup shuffle or Plinko. Every play wins a promo code. To see the code they give a first name and an email (a mobile number is optional), so you get a lead. It is on by default; nothing needs setting up.</p><section class="gd-task" id="discount-games-and-leads-what-the-visitor-sees" data-gd-task><h2 class="gd-h2">What the visitor sees</h2><ul class="gd-ul"><li>After 2 car pages, or 60 seconds on the site, or (on a computer) when the mouse heads for the tabs. A card slides in at the bottom; on a phone it is a sheet at the bottom, never a full-screen block, and it always closes.</li><li>Never for someone signed in or already known by email, never on booking, pay, sign or sign-in pages, never on the first page of a visit from a search engine on a phone, never over the cookie banner. After closing it, not again for 14 days; after claiming, never again.</li><li>Every play wins: 5% off (70 in 100), 10% off (25), 15% off (4) or $50 off a rental of 3 days or more (1). The prize is decided before the game starts; the game only shows it. The short terms with the game list the prizes and say the chances differ.</li><li>The code (for example WIN-7KQ4-XM2P) comes off the rental charge only, up to $75 for a percentage, on one booking, within 7 days, one per person, email, phone and device, never with another code. The email with the code goes either way; one reminder goes 24 hours before it expires. Offers only with the marketing box ticked.</li><li>On this device the code fills itself into the promo code box of the request form. Like every promo code, the discount is shared with the owner in the split.</li></ul></section><section class="gd-task" id="discount-games-and-leads-leads" data-gd-task><h2 class="gd-h2">Leads</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Leads</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The tiles: plays, claims, codes on booking requests, bookings, revenue and discounts from game codes in the last 30 days, then the same by game and by prize.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each claim: when, the name (and &quot;on the site now&quot;), email and phone, the prize and game, the code and whether it is used (with the booking), marketing consent, and the visit: cars and pages viewed, minutes, city and device.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Call</b> or <b class="gd-ui">Email</b>, then <b class="gd-ui">Contacted</b> (it is yours). <b class="gd-ui">Close</b> with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A visitor who viewed 3 cars or more also gets a Sales task, for example &quot;Claimed 10% off, viewed 6 cars: Maya&quot;. It closes when the code goes on a request.</div></li></ol></div></section><section class="gd-task" id="discount-games-and-leads-settings" data-gd-task><h2 class="gd-h2">Settings</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Discount games</b>.</p><ul class="gd-ul"><li>On or off, the cap for percentage codes ($75), how long a code is good for (7 days), when it shows (2 car pages, 60 seconds, exit intent), the days before it shows again after closing (14), the cars viewed for a Sales task (3) and the reminder (24 hours).</li><li>Prizes and games: each prize with its percent or dollars, a minimum rental length and its chance; each game&#39;s weight (0 turns it off). Press <b class="gd-ui">Save prizes and games</b>. Codes already sent keep their value.</li></ul></section>');
select app.guide_release_0069('admin', 'settings', 'chapter', 'search-car-pages-landing-pages-and-guides', 'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

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
7. Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).
8. Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.
9. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

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
  '<p class="gd-p">Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.</p><section class="gd-task" id="settings-the-settings-page" data-gd-task><h2 class="gd-h2">The Settings page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Site setup lists what is still missing on the public site, with <b class="gd-ui">Open site settings</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Program settings: every timing and policy value.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Forms: the official ServiceOntario PDFs and what goes in each field.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Insurers: insurance companies billed for bookings.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-24-settings-desktop-89b31691.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:32.6%;top:33%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.8%;top:40.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.4%;top:40.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:25.8%;top:73.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:25.8%;top:84.9%" aria-hidden="true">5</span></div></div></figure></div><p class="gd-p">The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Coverage prices, Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.</p></section><section class="gd-task" id="settings-program-settings" data-gd-task><h2 class="gd-h2">Program settings</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month&#39;s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press <b class="gd-ui">Save the defaults</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Change a value and press <b class="gd-ui">Save</b>. It is saved as a new row from today; the rows before stay as they were.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/program</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/admin-25-program-settings-desktop-d16b066c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:25.8%;top:22%" aria-hidden="true">1</span><span class="gd-pin" style="left:27.8%;top:49%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="settings-official-serviceontario-forms" data-gd-task><h2 class="gd-h2">Official ServiceOntario forms</h2><p class="gd-p">The five official forms are loaded with a draft mapping to the owner, car, company and lender details. Until you check a form, owners get a data sheet with the values.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. Each form shows &quot;Mapping to check&quot; (a draft is ready) or &quot;Official PDF in use&quot;. Its notes say what the form is for and which boxes are left blank on purpose.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download a filled preview</b> for one car and check each value against the form.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Change a field if needed: What goes in it (or &quot;The owner signs here&quot;), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for owners</b>. Every owner&#39;s form of that kind is filled again, except ones already signed or filed, and owners sign it with their other documents.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A new version from ServiceOntario? Press <b class="gd-ui">Upload the official fillable PDF</b>: the fields of the same name keep their mapping.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company&#39;s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner&#39;s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person.</div></aside></section><section class="gd-task" id="settings-agreements-to-sign-investors-and-staff" data-gd-task><h2 class="gd-h2">Agreements to sign: investors and staff</h2><p class="gd-p">Investment agreements and staff agreements are made from the person&#39;s record and signed in their own portal, or on paper.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Investor: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Investors</b> and the investor. Under Investment agreement, press <b class="gd-ui">Send the agreement to sign</b>. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press <b class="gd-ui">Send to sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Once the investor signs, the agreement shows <b class="gd-ui">Awaiting countersignature</b> on the investor&#39;s page and on To do. It is not countersigned automatically: check it and press <b class="gd-ui">Countersign</b>. CarmaCars is bound once it has countersigned and the funds clear.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Staff: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Staff</b>. Under Staff agreements, press <b class="gd-ui">Send the agreement to sign</b> beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A field staff member&#39;s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Your own PDF instead? <b class="gd-ui">Send a PDF to sign</b> still works.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Signed on paper instead? Press <b class="gd-ui">Record paper signature</b> in the same place and upload the scan.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Sent by mistake? Press <b class="gd-ui">Withdraw</b> and give the reason.</div></li></ol></div></section><section class="gd-task" id="settings-the-user-guides" data-gd-task><h2 class="gd-h2">The user guides</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Guides</b>. The guide of each portal, as people read it under Guide.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each guide shows its version, when it was published and whether there are unpublished changes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a guide and press a section. Change its text and press <b class="gd-ui">Show the preview</b> to see it as people will. Press <b class="gd-ui">Save the draft</b>; each save is kept in the section&#39;s history.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Move a section with the arrows, hide it, or press <b class="gd-ui">Add a chapter</b>. Upload a screenshot under Screenshots and paste the line it gives you.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Publish version</b> (the next number). The portals show the new version at once.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.</div></li></ol></div></section><section class="gd-task" id="settings-the-guides-keep-up-by-themselves" data-gd-task><h2 class="gd-h2">The guides keep up by themselves</h2><p class="gd-p">After every update of the site that changes the portals, the guides are checked without anyone asking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal&#39;s own labels and menu, checked, and published. The PDFs of those guides are printed again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Such a section says <b class="gd-ui">Changed automatically on</b> and the date, in the list of guides and in the guide&#39;s editor. Not right? Open the section and press <b class="gd-ui">Revert</b>: the text it replaced comes back, published at once.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section&#39;s history. There is nothing to review.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The card &quot;The guides keep up by themselves&quot; at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.</div></aside></section><section class="gd-task" id="settings-insurers-and-the-other-lists" data-gd-task><h2 class="gd-h2">Insurers and the other lists</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press <b class="gd-ui">Add</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.</div></li></ol></div></section>');
select app.guide_release_0069('va', 'your-workday', 'chapter', 'start-here', 'Every function works the same way: start on To do, take the oldest task, finish it, and check Today for pickups and returns. The menu keeps your own work first, then the screens of your function in a few groups.

## The menu

My work comes first: To do, Today, My scorecard and My sales (customer service and Sales also have Live visitors and Live chat). Then the groups of your function. The current group is open; press another to open it. On a phone the whole menu sits behind one Menu button.

| Function | Groups and pages |
| --- | --- |
| Customer service | Bookings (Requests, New quote, Add a rental, Calendar), Renters (Messages, Find a renter), Cars (Listings, Similar cars), Owners (Owners and enquiries, Add a car for an owner, Owner forms) |
| Sales | Bookings (Requests and offers, New quote, Add a rental, Calendar), Owners (Owner leads) |
| Finance | Money (Payments, deposits and refunds, Tolls and tickets, Reconciliation, Turo trips), Renters and bookings (Find a renter, Calendar), Rentals (Add a rental, New quote) |
| Fleet | Field work (Field jobs, Daily checks, Photo reviews), Cars (Listings, Similar cars, Calendar, Calendar sync, Add a car for an owner), Renters (Find a renter), Rentals (Add a rental, New quote) |

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

My work comes first: To do, Today, My scorecard and My sales (customer service and Sales also have Live visitors, Live chat and Game leads). Then the groups of your function. The current group is open; press another to open it. On a phone the whole menu sits behind one Menu button.

| Function | Groups and pages |
| --- | --- |
| Customer service | Bookings (Requests, New quote, Add a rental, Calendar), Renters (Messages, Find a renter), Cars (Listings, Similar cars), Owners (Owners and enquiries, Add a car for an owner, Owner forms) |
| Sales | Bookings (Requests and offers, New quote, Add a rental, Calendar), Owners (Owner leads) |
| Finance | Money (Payments, deposits and refunds, Tolls and tickets, Reconciliation, Turo trips), Renters and bookings (Find a renter, Calendar), Rentals (Add a rental, New quote) |
| Fleet | Field work (Field jobs, Daily checks, Photo reviews), Cars (Listings, Similar cars, Calendar, Calendar sync, Add a car for an owner), Renters (Find a renter), Rentals (Add a rental, New quote) |

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
  '<p class="gd-p">Every function works the same way: start on To do, take the oldest task, finish it, and check Today for pickups and returns. The menu keeps your own work first, then the screens of your function in a few groups.</p><section class="gd-task" id="your-workday-the-menu" data-gd-task><h2 class="gd-h2">The menu</h2><p class="gd-p">My work comes first: To do, Today, My scorecard and My sales (customer service and Sales also have Live visitors, Live chat and Game leads). Then the groups of your function. The current group is open; press another to open it. On a phone the whole menu sits behind one Menu button.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Function</th><th scope="col">Groups and pages</th></tr></thead><tbody><tr><td>Customer service</td><td>Bookings (Requests, New quote, Add a rental, Calendar), Renters (Messages, Find a renter), Cars (Listings, Similar cars), Owners (Owners and enquiries, Add a car for an owner, Owner forms)</td></tr><tr><td>Sales</td><td>Bookings (Requests and offers, New quote, Add a rental, Calendar), Owners (Owner leads)</td></tr><tr><td>Finance</td><td>Money (Payments, deposits and refunds, Tolls and tickets, Reconciliation, Turo trips), Renters and bookings (Find a renter, Calendar), Rentals (Add a rental, New quote)</td></tr><tr><td>Fleet</td><td>Field work (Field jobs, Daily checks, Photo reviews), Cars (Listings, Similar cars, Calendar, Calendar sync, Add a car for an owner), Renters (Find a renter), Rentals (Add a rental, New quote)</td></tr></tbody></table></div></section><section class="gd-task" id="your-workday-to-do" data-gd-task><h2 class="gd-h2">To do</h2><p class="gd-p">Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The top line shows your function and how many tasks are open.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Filter: All, Mine, Unassigned or Waiting; Any time, Overdue, Due today or Escalated; and by type.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each row has a priority, the task, its record, when it is due and how long it has waited. The oldest due is first.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Take it</b> to make it yours. <b class="gd-ui">Sheet</b> opens the step-by-step procedure.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/640"><img src="/guides/img/va-cs-01-queue-desktop-c36a8e2d.jpg" alt="" loading="lazy" decoding="async" width="1440" height="640"><span class="gd-pin" style="left:13.9%;top:5%" aria-hidden="true">1</span><span class="gd-pin" style="left:36.1%;top:17.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:31.9%;top:43.8%" aria-hidden="true">3</span><span class="gd-pin" style="left:91.7%;top:52.3%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="your-workday-work-a-task" data-gd-task><h2 class="gd-h2">Work a task</h2><p class="gd-p">Open the task. The buttons along the top move it on.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Button</th><th scope="col">What it does</th></tr></thead><tbody><tr><td><b class="gd-ui">Open the working screen</b></td><td>Jumps to the booking, car or owner the task is about.</td></tr><tr><td><b class="gd-ui">Done</b></td><td>You finished it. It leaves the queue.</td></tr><tr><td><b class="gd-ui">Waiting</b></td><td>You are waiting on someone (a renter, an owner). It stays yours.</td></tr><tr><td><b class="gd-ui">Escalate</b></td><td>It needs an Admin. Add why.</td></tr><tr><td><b class="gd-ui">Hand over</b></td><td>Give it to someone else on the team.</td></tr><tr><td><b class="gd-ui">Add a note</b></td><td>Leave a note for whoever looks next.</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Work oldest due first. A task meets its target when it is done by its due time; that is what your scorecard counts.</div></aside></section><section class="gd-task" id="your-workday-today" data-gd-task><h2 class="gd-h2">Today</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Today lists pickups and returns, and what is due, for your function.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press a booking number to open it. <b class="gd-ui">To do</b> takes you back to your tasks.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/today</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/700"><img src="/guides/img/va-cs-02-today-desktop-dfd277b7.jpg" alt="" loading="lazy" decoding="async" width="1440" height="700"><span class="gd-pin" style="left:20.8%;top:14.3%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="your-workday-documents-to-sign" data-gd-task><h2 class="gd-h2">Documents to sign</h2><p class="gd-p">Your staff agreement, when CarmaCars sends it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The queue shows &quot;You have a document to sign&quot;. Press <b class="gd-ui">Read and sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the key values at the top (your role, hours, rate and start date), then press <b class="gd-ui">Read the PDF</b> and read it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Sign</b>. Your full legal name is your signature (or press <b class="gd-ui">Draw instead</b>). Several documents? One signature covers all of them. The signed copy stays on the same page.</div></li></ol></div></section><section class="gd-task" id="your-workday-several-functions-switch-with-working-as" data-gd-task><h2 class="gd-h2">Several functions? Switch with Working as</h2><p class="gd-p">If you cover more than one function, <b class="gd-ui">Working as</b> above the menu lists them: Customer service, Finance, Fleet and Sales. Choose one; the menu, To do and Today change to that function.</p></section><section class="gd-task" id="your-workday-your-scorecard" data-gd-task><h2 class="gd-h2">Your scorecard</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">My work</b> &gt; <b class="gd-ui">My scorecard</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">By week shows each measure, its target and your result for each week.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A task meets its target when done by its due time. Daily checks count when done by 9:00 and 18:00.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The first reply target is 5 minutes: a new booking request, an enquiry, a change the renter asked for or a renter message is due 5 minutes after it comes in. An Admin sets it in Program settings, and the target column shows the one in force.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/scorecard</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/360"><img src="/guides/img/va-sales-05-scorecard-desktop-78ec1b03.jpg" alt="" loading="lazy" decoding="async" width="1440" height="360"><span class="gd-pin" style="left:4.2%;top:39.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:62.5%;top:58.3%" aria-hidden="true">2</span></div></div></figure></div></section>');
select app.guide_release_0069('va', 'discount-game-leads', 'chapter', 'live-visitors-and-live-chat', null, 'Discount game leads', 'Game leads to call or email, the code they won, whether it is used, and the Sales task.',
  'Visitors who are not signed in play a quick game on the site and win a promo code. To get it they give a first name, an email and sometimes a mobile number. Customer service and Sales follow them up.

## Game leads

**My work** > **Game leads**.

1. Each claim: when, the name (and "on the site now"), email and phone, the prize, the code and whether it is used, marketing consent, and the cars and pages they viewed.
2. Press **Call** or **Email**. Help them pick a car and send a request; the code goes in the promo code box (on their own device it is filled in). Then press **Contacted**.
3. **Close** with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.

A visitor who viewed 3 cars or more also raises a Sales task, for example "Claimed 10% off, viewed 6 cars: Maya". It closes when the code goes on a request.

> Tip: Without marketing consent, talk only about their request and the code they asked for: no other offers. The code takes up to $75 off the rental charge (a percentage), or $50 off a rental of 3 days or more, on one booking within 7 days.
',
  '<p class="gd-p">Visitors who are not signed in play a quick game on the site and win a promo code. To get it they give a first name, an email and sometimes a mobile number. Customer service and Sales follow them up.</p><section class="gd-task" id="discount-game-leads-game-leads" data-gd-task><h2 class="gd-h2">Game leads</h2><p class="gd-p"><b class="gd-ui">My work</b> &gt; <b class="gd-ui">Game leads</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each claim: when, the name (and &quot;on the site now&quot;), email and phone, the prize, the code and whether it is used, marketing consent, and the cars and pages they viewed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Call</b> or <b class="gd-ui">Email</b>. Help them pick a car and send a request; the code goes in the promo code box (on their own device it is filled in). Then press <b class="gd-ui">Contacted</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Close</b> with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.</div></li></ol></div><p class="gd-p">A visitor who viewed 3 cars or more also raises a Sales task, for example &quot;Claimed 10% off, viewed 6 cars: Maya&quot;. It closes when the code goes on a request.</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Without marketing consent, talk only about their request and the code they asked for: no other offers. The code takes up to $75 off the rental charge (a percentage), or $50 off a rental of 3 days or more, on one booking within 7 days.</div></aside></section>');
-- GUIDES 0069 END
