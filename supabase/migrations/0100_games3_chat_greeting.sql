-- 0100_games3_chat_greeting.sql
-- The owner's requests of October 22, 2026 about the discount games (0069, 0081, 0094) and the live chat (0060).
--   1. "The CarmaCars discount popup shows you won 5% off right away, before a game." Live (read-only check, October
--      22): every play of a visitor after the first carries the prize drawn for them (game_dismiss_days, 14 days), so
--      a visitor who had played once got "You won 5% off" again from every later game; and a play already revealed came
--      back from game_start with revealed = true, which opened the card on its claim form ("You won 5% off") with no
--      game at all. Now a game is always played first and the prize shows only as its outcome: once a visitor has seen
--      their prize (revealed, not claimed), game_start returns that play with saved = true and the site shows the
--      small badge "Your 5% off is saved" (its claim form opens from it), never a new win and never a new game. The
--      draw, the odds and the one-prize-per-visitor rule are unchanged.
--   2. Fewer games (the owner's defaults, each an Admin setting under the keys it already had; the live values move
--      too): the first game on the 2nd page view (any page; game_trigger_car_pages now counts every page view) or
--      after 30 seconds on the site, whichever first; exit intent off; after a close the next game on the 3rd page
--      view after the close or 2 minutes later, whichever first; at most 4 a visit; no daily cap (game_max_per_day 0:
--      no cap). None once a booking request is in progress for the visitor (the browser knows its own request; the
--      database knows a booking request the visitor started, contact capture 0090); never on checkout or payment pages
--      (the request-to-book form keeps its own game).
--   3. Five more games with the same prize table and odds: coin flip, dice roll, slot machine, prize drop (a capsule
--      machine) and mystery box. Added to the rotation at the same weight (game weights an Admin set stay as set). The
--      rotation never gives one visitor the same game twice in a row.
--   4. The chat greeting: 45 seconds on the site (chat_greeting_seconds, was 0: off), on every public page, never in
--      the portals or in booking, checkout, pay or sign pages. Context-aware: on a car page it names the car, on the
--      chauffeur, detailing and body shop pages the service (chat_greeting_topic_text, "{topic}" is replaced); else
--      chat_greeting_text. A reply opens the chat with the greeting the visitor saw as its first message.
-- No applied migration is edited (functions of earlier migrations are changed in place, as 0081 does).

-- ================================================================ 1. settings: the owner's defaults, live too
alter table program_settings drop constraint if exists program_settings_game_max_per_day_check;
alter table program_settings add constraint program_settings_game_max_per_day_check check (game_max_per_day between 0 and 50);
alter table program_settings
  add column if not exists chat_greeting_topic_text text not null
    default 'Hi! Questions about {topic}? Ask me anything: prices, availability, or how to book.'
    check (length(chat_greeting_topic_text) between 1 and 300);
alter table program_settings
  alter column game_trigger_car_pages set default 2,
  alter column game_trigger_seconds set default 30,
  alter column game_exit_intent set default false,
  alter column game_reshow_car_pages set default 3,
  alter column game_reshow_seconds set default 120,
  alter column game_max_per_visit set default 4,
  alter column game_max_per_day set default 0,
  alter column chat_greeting_seconds set default 45,
  alter column chat_greeting_text set default 'Hi! Looking for a car? Ask me anything: prices, delivery, or what you need to rent.';
-- the owner set these values: every settings row (the current one included) takes them
update program_settings set game_trigger_car_pages = 2, game_trigger_seconds = 30, game_exit_intent = false, game_reshow_car_pages = 3,
  game_reshow_seconds = 120, game_max_per_visit = 4, game_max_per_day = 0, chat_greeting_seconds = 45;
-- the greeting's words move only where they are still 0060's
update program_settings set chat_greeting_text = 'Hi! Looking for a car? Ask me anything: prices, delivery, or what you need to rent.'
 where chat_greeting_text = 'Hi! Questions about this car? I can check dates and prices for you.';

comment on column program_settings.game_trigger_car_pages is 'Discount games (0100): the first game of a visit shows on this page view, any page (2 by default; 0: not by pages). The name is from 0069, when it counted car pages.';
comment on column program_settings.game_trigger_seconds is 'Discount games (0100): or after this many seconds on the site, whichever first (30 by default; 0: not by time).';
comment on column program_settings.game_exit_intent is 'Discount games (0100): also when the mouse heads for the tabs on a computer (off by default).';
comment on column program_settings.game_reshow_car_pages is 'Discount games (0100): after the visitor closes a game, the next one shows on this page view after the close, any page (3 by default; 0: not by pages).';
comment on column program_settings.game_reshow_seconds is 'Discount games (0100): or this many seconds after the close, whichever first (120 by default; 0: not by time).';
comment on column program_settings.game_max_per_visit is 'Discount games (0100): the most games shown in one visit (4 by default). Later visits start again. Never again after a claim.';
comment on column program_settings.game_max_per_day is 'Discount games (0100): the most games shown in one day in one browser, counted in the browser (0 by default: no daily cap).';
comment on column program_settings.chat_greeting_seconds is 'Live chat (0100): after this many seconds on the site a small preview opens on the chat button with a first message from CarmaCars, once a visit, never over a game and never in the portals (45 by default; 0: off).';
comment on column program_settings.chat_greeting_text is 'Live chat (0100): the greeting on pages about nothing in particular.';
comment on column program_settings.chat_greeting_topic_text is 'Live chat (0100): the greeting on a car page or a service page; {topic} becomes the car ("the 2021 Mercedes-Benz A220") or the service ("our chauffeur service").';

-- ================================================================ 2. five more games
create or replace function app.game_kinds() returns text[]
language sql immutable as $$ select array['wheel', 'scratch', 'blackjack', 'cups', 'plinko', 'pack', 'coin', 'dice', 'slots', 'drop', 'mystery'] $$;
alter table program_settings alter column game_weights set default
  '{"wheel": 1, "scratch": 1, "blackjack": 1, "cups": 1, "plinko": 1, "pack": 1, "coin": 1, "dice": 1, "slots": 1, "drop": 1, "mystery": 1}'::jsonb;
-- on at the same weight; a weight an Admin already set for a game stays as it is
update program_settings set game_weights = '{"coin": 1, "dice": 1, "slots": 1, "drop": 1, "mystery": 1}'::jsonb || game_weights;
comment on column program_settings.game_weights is 'Discount games: how often each game is chosen (wheel, scratch, blackjack, cups, plinko, pack, coin, dice, slots, drop, mystery). 0 turns a game off. Equal by default.';

-- The next game: one this browser and this visitor's plays have not shown in the current round, drawn by the games'
-- weights; once every game on was shown a new round starts. 0100: never the game shown last while another is on, so
-- one visitor never gets the same game twice in a row (the last play of this visitor, or p_last).
create or replace function app.game_next_kind(p_vid uuid, p_user uuid, p_seen text[], p_last text) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_on text[] := app.game_kinds_on();
  v_seen text[] := '{}';
  v_left text[];
  v_last text;
  x record;
begin
  for x in select g.game from game_plays g where g.visitor_id = p_vid or (p_user is not null and g.user_id = p_user) order by g.created_at, g.id loop
    if x.game = any (v_on) and not x.game = any (v_seen) then v_seen := v_seen || x.game; end if;
    if v_on <@ v_seen then v_seen := '{}'; end if;
    v_last := x.game;
  end loop;
  v_last := coalesce(v_last, p_last);
  v_seen := v_seen || coalesce((select array_agg(s) from unnest(p_seen) s where s = any (v_on)), '{}');
  if v_on <@ v_seen then v_seen := '{}'; end if;
  v_left := coalesce((select array_agg(k order by o) from unnest(v_on) with ordinality t(k, o) where not k = any (v_seen)), '{}');
  if cardinality(v_left) = 0 then v_left := v_on; end if;
  if cardinality(v_left) > 1 and v_last is not null then v_left := array_remove(v_left, v_last); end if;
  if cardinality(v_left) = 0 then return app.game_draw((app.settings()).game_weights) #>> '{}'; end if;
  return app.game_draw((select jsonb_object_agg(k, ((app.settings()).game_weights ->> k)::numeric) from unnest(v_left) k)) #>> '{}';
end $$;

-- ================================================================ 3. a play: the prize only as a game's outcome
-- As 0081, with: a visitor with a booking request in progress gets no game on the site (reason in_progress); a play
-- whose prize the visitor has already seen (revealed, not claimed) comes back as saved, never as something to play or
-- a new win (the browser shows "Your 5% off is saved" and its claim form); a dry check says whether a prize is saved.
create or replace function app.game_start_core(p jsonb, p_user uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings();
  v_vid uuid := case when p ->> 'vid' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then (p ->> 'vid')::uuid end;
  v_sid uuid := case when p ->> 'sid' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then (p ->> 'sid')::uuid end;
  v_ctx text := case when p ->> 'context' = 'booking' then 'booking' else 'site' end;
  v_seen text[] := coalesce((select array_agg(x) from jsonb_array_elements_text(case when jsonb_typeof(p -> 'seen') = 'array' then p -> 'seen' else '[]'::jsonb end) x
                              where x = any (app.game_kinds())), '{}');
  v_email text;
  v_first text;
  v_saved boolean;
  g game_plays;
  r jsonb;
begin
  if not ps.game_enabled then return jsonb_build_object('ok', false, 'reason', 'off'); end if;
  if v_vid is null then return jsonb_build_object('ok', false, 'reason', 'bad ids'); end if;
  if v_ctx = 'site' and p_user is not null then return jsonb_build_object('ok', false, 'reason', 'signed_in'); end if;
  if v_ctx = 'booking' then
    if not ps.game_booking_offer then return jsonb_build_object('ok', false, 'reason', 'off'); end if;
    if p_user is not null then
      if app.user_is_staff(p_user) or exists (select 1 from user_roles ur where ur.user_id = p_user and ur.role::text in ('admin', 'va', 'field')) then
        return jsonb_build_object('ok', false, 'reason', 'staff');
      end if;
      select lower(u.email), nullif(split_part(btrim(coalesce(u.full_name, '')), ' ', 1), '') into v_email, v_first from users u where u.id = p_user;
      if exists (select 1 from game_claims c where c.user_id = p_user or c.email = v_email
                    or c.renter_id = (select rr.id from renters rr where rr.user_id = p_user limit 1)) then
        return jsonb_build_object('ok', false, 'reason', 'claimed');
      end if;
    end if;
  end if;
  if exists (select 1 from game_claims c where c.visitor_id = v_vid) then return jsonb_build_object('ok', false, 'reason', 'claimed'); end if;
  if v_ctx = 'site' and exists (select 1 from visitor_sessions s where s.visitor_id = v_vid and (s.renter_id is not null or s.user_id is not null or s.known_email is not null)) then
    return jsonb_build_object('ok', false, 'reason', 'known');
  end if;
  -- 0100: a booking request in progress (the request form's details typed in, contact capture 0090): no game on the site
  if v_ctx = 'site' and exists (select 1 from contact_captures cc where cc.visitor_id = v_vid and cc.form = 'booking_request' and cc.last_at > now() - interval '30 days') then
    return jsonb_build_object('ok', false, 'reason', 'in_progress');
  end if;

  -- the prize drawn for this visitor (or account), still open
  select * into g from game_plays
   where (visitor_id = v_vid or (p_user is not null and user_id = p_user)) and claimed_at is null
     and created_at > now() - make_interval(days => ps.game_dismiss_days)
   order by created_at desc limit 1;
  v_saved := g.id is not null and g.revealed_at is not null and g.user_id is not distinct from p_user and (g.context = v_ctx or p_user is null);
  if coalesce((p ->> 'dry')::boolean, false) then
    return jsonb_build_object('ok', true, 'dry', true, 'saved', case when v_saved then app.game_prize_label(g.prize) end);
  end if;

  if v_saved then
    -- 0100: already won and seen: the same play, as a saved prize (no game, no new draw, no "You won")
    r := app.game_play_json(g) || jsonb_build_object('saved', true);
  elsif g.id is not null and g.revealed_at is null and g.context = v_ctx and not g.game = any (v_seen) and g.user_id is not distinct from p_user then
    -- the same page again before this browser showed it: the same play (no new play by reloading)
    r := app.game_play_json(g);
  else
    if not app.rate_limit('game-start:' || v_vid, 10, interval '1 hour') or not app.rate_limit('game-start', 3000, interval '1 hour') then
      return jsonb_build_object('ok', false, 'reason', 'limited');
    end if;
    insert into game_plays (visitor_id, session_id, game, prize, device, path, trigger, context, user_id, created_at)
    values (v_vid, v_sid, app.game_next_kind(v_vid, p_user, v_seen, g.game), coalesce(g.prize, app.game_draw(ps.game_prizes)),
            case when p ->> 'device' in ('phone', 'tablet', 'desktop') then p ->> 'device' end, left(p ->> 'path', 300),
            case when v_ctx = 'booking' then 'booking' when p ->> 'trigger' in ('pages', 'time', 'exit') then p ->> 'trigger' end, v_ctx, p_user, clock_timestamp())
    returning * into g;
    r := app.game_play_json(g);
  end if;
  r := r || jsonb_build_object('context', g.context);
  if p_user is not null then r := r || jsonb_build_object('account', jsonb_build_object('first', v_first, 'email', v_email)); end if;
  return r;
end $$;

-- ================================================================ 4. the chat greeting, by page
-- The greeting for a page: none in the portals, sign-in, booking, checkout, pay or sign pages; on a published car's
-- page the car ("the 2021 Mercedes-Benz A220"); on the chauffeur, detailing and body shop pages the service; else the
-- general greeting. The browser shows it in the preview; the chat's first message is the same text.
create or replace function app.chat_greeting_for(p_page text) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings();
  v_path text := split_part(split_part(coalesce(nullif(p_page, ''), '/'), '?', 1), '#', 1);
  v_topic text;
begin
  if v_path ~ '^/(account|owner|admin|va|field|investor|partner|portal|staff|sign|sign-in|sign-document|create-account|reset-password|update-password|two-step|choose-portal|read-only|link-expired|guide-pdf|files|d|r|auth|book|my-request|continue|checkout|pay|payment)(/|$)'
     or v_path ~ '/(pay|payment|sign|checkout)(/|$)' then
    return null;
  end if;
  if v_path ~ '^/cars/[a-z0-9-]+/?$' then
    select concat_ws(' ', v.year, v.make, v.model) into v_topic
      from vehicle_listings l join vehicles v on v.id = l.vehicle_id
     where l.slug = substring(v_path from '^/cars/([a-z0-9-]+)') and l.status::text = 'published' limit 1;
    if nullif(btrim(v_topic), '') is not null then v_topic := 'the ' || btrim(v_topic); else v_topic := null; end if;
  elsif v_path ~ '^/chauffeur(/|$)' then v_topic := 'our chauffeur service';
  elsif v_path ~ '^/detailing(/|$)' then v_topic := 'our car detailing';
  elsif v_path ~ '^/body-shop(/|$)' then v_topic := 'our body shop';
  end if;
  if v_topic is null or position('{topic}' in ps.chat_greeting_topic_text) = 0 then return ps.chat_greeting_text; end if;
  return replace(ps.chat_greeting_topic_text, '{topic}', v_topic);
end $$;

-- the browser's: when the greeting opens (seconds on the site; 0: off) and its words for this page (null: none here).
-- The chat button asks for itself: the beacon's reply (which also carries the setting) does not come without
-- analytics consent.
create or replace function public.chat_greeting(p_page text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('after', case when s.chat_enabled then s.chat_greeting_seconds else 0 end,
                            'text', case when s.chat_enabled and s.chat_greeting_seconds > 0 then app.chat_greeting_for(left(p_page, 300)) end)
    from (select (app.settings()).*) s
$$;

-- a chat opened from the greeting starts with the greeting the visitor saw (its page: greeting_page)
create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0100: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;
select pg_temp.patch_fn('app.server_chat_open(jsonb, uuid)'::regprocedure,
  'values (c.id, ''ai'', ps.chat_greeting_text, ''{"greeting": true}'')',
  'values (c.id, ''ai'', coalesce(app.chat_greeting_for(coalesce(nullif(p ->> ''greeting_page'', ''''), p ->> ''page'')), ps.chat_greeting_text), ''{"greeting": true}'')');

-- ================================================================ 5. privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['game_next_kind', 'game_start_core', 'chat_greeting_for', 'server_chat_open'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
  revoke all on function public.chat_greeting(text) from public;
  grant execute on function public.chat_greeting(text) to anon, authenticated, service_role;
end $$;
