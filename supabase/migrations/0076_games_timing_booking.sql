-- 0076_games_timing_booking.sql
-- The owner's requests of October 21, 2026 about the discount games of 0069 (docs/changes/2026-10-21-games-timing-booking.md):
--   1. "The discount popups aren't showing up fast enough." The first game comes after 1 car page or 15 seconds on the
--      site (whichever first), exit intent on computers kept. The live settings move to the new values only where they
--      still hold the old defaults (2 car pages, 60 seconds).
--   2. "When they get closed out, they should show up again later on but with a different popup that hasn't showed up
--      yet." After a close the game comes back later in the same visit (2 more car pages or 3 minutes, whichever first)
--      and on later visits, each time a game this visitor has not seen yet, all five before one repeats, at most 3 a
--      visit, never again after a claim. The prize stays the one drawn for the visitor (game_dismiss_days now says for
--      how long): closing and reopening shows another game, never a new draw, so the odds are exactly those of 0069.
--   3. "Also they should show up when making a booking." The request-to-book form offers the game to anyone who has
--      not claimed a prize, signed-in renters included (the only place they see it), never to staff. A won code goes on
--      that booking request at once.
-- The prize table and its odds, the $75 cap, the 7-day single-use codes and every one-per-person rule of 0069 stay as
-- they are. No applied migration is edited.

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists game_reshow_car_pages integer not null default 2 check (game_reshow_car_pages between 0 and 20),
  add column if not exists game_reshow_seconds integer not null default 180 check (game_reshow_seconds between 0 and 3600),
  add column if not exists game_max_per_visit integer not null default 3 check (game_max_per_visit between 1 and 10),
  add column if not exists game_booking_offer boolean not null default true;
alter table program_settings alter column game_trigger_car_pages set default 1, alter column game_trigger_seconds set default 15;
-- the live values move only where an Admin has not changed them
update program_settings set game_trigger_car_pages = 1 where game_trigger_car_pages = 2;
update program_settings set game_trigger_seconds = 15 where game_trigger_seconds = 60;

comment on column program_settings.game_trigger_car_pages is 'Discount games: the first game of a visit shows after this many car pages (1 by default; 0: not by pages).';
comment on column program_settings.game_trigger_seconds is 'Discount games: or after this many seconds on the site, whichever first (15 by default; 0: not by time).';
comment on column program_settings.game_reshow_car_pages is 'Discount games (0076): after the visitor closes a game, the next one shows after this many more car pages (2 by default; 0: not by pages).';
comment on column program_settings.game_reshow_seconds is 'Discount games (0076): or after this many seconds since the close, whichever first (180 by default; 0: not by time).';
comment on column program_settings.game_max_per_visit is 'Discount games (0076): the most games shown in one visit (3 by default). Later visits start again. Never again after a claim.';
comment on column program_settings.game_booking_offer is 'Discount games (0076): offer the game in the request-to-book form to anyone who has not claimed a prize, signed-in renters included (never staff). On by default.';
comment on column program_settings.game_dismiss_days is 'Discount games: a visitor keeps the prize drawn for them this many days (14 by default): closing a game and seeing another never draws again. 0076: no longer a wait after closing.';

-- ================================================================ 2. plays: where they were offered, and by whom
alter table game_plays
  add column if not exists context text not null default 'site' check (context in ('site', 'booking')),
  add column if not exists user_id uuid references users (id) on delete set null;
alter table game_plays drop constraint if exists game_plays_trigger_check;
alter table game_plays add constraint game_plays_trigger_check check (trigger in ('pages', 'time', 'exit', 'booking'));
create index if not exists game_plays_user_idx on game_plays (user_id, created_at desc) where user_id is not null;
comment on column game_plays.context is '0076: site (the card on the public site) or booking (the card in the request-to-book form).';
comment on column game_plays.user_id is '0076: the signed-in renter who played in the request-to-book form (empty for visitors).';

-- ================================================================ 3. what the browser needs
create or replace function app.game_cfg() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('on', s.game_enabled, 'car_pages', s.game_trigger_car_pages, 'seconds', s.game_trigger_seconds,
    'exit', s.game_exit_intent, 'reshow_pages', s.game_reshow_car_pages, 'reshow_seconds', s.game_reshow_seconds,
    'per_visit', s.game_max_per_visit, 'booking', s.game_booking_offer)
    from (select (app.settings()).*) s
$$;

-- The games turned on (weight above 0), in their fixed order.
create or replace function app.game_kinds_on() returns text[]
language sql stable security definer set search_path = public, app as $$
  select coalesce(array_agg(k order by o), '{}') from unnest(app.game_kinds()) with ordinality t(k, o)
   where coalesce(((app.settings()).game_weights ->> k)::numeric, 0) > 0
$$;

-- The next game for a visitor (and a signed-in renter): one this browser and this visitor's plays have not shown in
-- the current round, drawn by the games' weights; once every game on was shown a new round starts, never with the
-- game just shown. p_seen: the games this browser remembers; p_last: the game shown last.
create or replace function app.game_next_kind(p_vid uuid, p_user uuid, p_seen text[], p_last text) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_on text[] := app.game_kinds_on();
  v_seen text[] := '{}';
  v_left text[];
  x record;
begin
  -- the server's memory: this visitor's plays, oldest first, a fresh round each time all were shown
  for x in select g.game from game_plays g where g.visitor_id = p_vid or (p_user is not null and g.user_id = p_user) order by g.created_at, g.id loop
    if x.game = any (v_on) and not x.game = any (v_seen) then v_seen := v_seen || x.game; end if;
    if v_on <@ v_seen then v_seen := '{}'; end if;
  end loop;
  v_seen := v_seen || coalesce((select array_agg(s) from unnest(p_seen) s where s = any (v_on)), '{}');
  if v_on <@ v_seen then v_seen := case when p_last is null then '{}'::text[] else array[p_last] end; end if;
  v_left := coalesce((select array_agg(k order by o) from unnest(v_on) with ordinality t(k, o) where not k = any (v_seen)), '{}');
  if cardinality(v_left) = 0 then v_left := v_on; end if;
  if cardinality(v_left) = 0 then return app.game_draw((app.settings()).game_weights) #>> '{}'; end if;
  return app.game_draw((select jsonb_object_agg(k, ((app.settings()).game_weights ->> k)::numeric) from unnest(v_left) k)) #>> '{}';
end $$;

-- ================================================================ 4. a play
-- Who may play: the games are on; on the site, a visitor who is not signed in and not known by email; in the
-- request-to-book form, anyone who has not claimed (signed-in renters too), never staff. Never after a claim (this
-- browser, or this account). The prize is the one drawn for this visitor (or account) within game_dismiss_days, so
-- closing and opening again never draws again; the game is one this browser has not seen. p.seen: the games this
-- browser has shown; p.dry: only say whether a play is possible (nothing recorded).
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
  if coalesce((p ->> 'dry')::boolean, false) then return jsonb_build_object('ok', true, 'dry', true); end if;

  -- the prize drawn for this visitor (or account), still open
  select * into g from game_plays
   where (visitor_id = v_vid or (p_user is not null and user_id = p_user)) and claimed_at is null
     and created_at > now() - make_interval(days => ps.game_dismiss_days)
   order by created_at desc limit 1;
  -- the same page again before this browser showed it: the same play (no new play by reloading)
  if g.id is not null and g.context = v_ctx and not g.game = any (v_seen) and g.user_id is not distinct from p_user then
    r := app.game_play_json(g);
  else
    if not app.rate_limit('game-start:' || v_vid, 10, interval '1 hour') or not app.rate_limit('game-start', 3000, interval '1 hour') then
      return jsonb_build_object('ok', false, 'reason', 'limited');
    end if;
    -- clock_timestamp: plays of one transaction keep their order
    insert into game_plays (visitor_id, session_id, game, prize, device, path, trigger, context, user_id, created_at)
    values (v_vid, v_sid, app.game_next_kind(v_vid, p_user, v_seen, g.game), coalesce(g.prize, app.game_draw(ps.game_prizes)),
            case when p ->> 'device' in ('phone', 'tablet', 'desktop') then p ->> 'device' end, left(p ->> 'path', 300),
            case when v_ctx = 'booking' then 'booking' when p ->> 'trigger' in ('pages', 'time', 'exit') then p ->> 'trigger' end, v_ctx, p_user, clock_timestamp())
    returning * into g;
    r := app.game_play_json(g);
  end if;
  r := r || jsonb_build_object('context', g.context);
  -- a signed-in renter's code goes to their account's email
  if p_user is not null then r := r || jsonb_build_object('account', jsonb_build_object('first', v_first, 'email', v_email)); end if;
  return r;
end $$;

-- the site's: never as a signed-in person, never the booking form's rules
create or replace function app.game_start(p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.game_start_core(coalesce(p, '{}'::jsonb) - 'context', app.uid()) $$;

-- ================================================================ 5. the claim from the request-to-book form
-- A signed-in renter claims only a play of the booking form, with their account's email (one per person: never a
-- second code for the account, its email or its renter). Everything else is the claim of 0069, unchanged.
alter function app.server_game_claim(jsonb, uuid) rename to server_game_claim_pre0076;
create or replace function app.server_game_claim(p jsonb, p_user uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  g game_plays;
  u users;
  r jsonb;
begin
  if p_user is null then return app.server_game_claim_pre0076(p, null); end if;
  select * into g from game_plays where token = p ->> 'token';
  if g.id is null or g.context <> 'booking' then
    return jsonb_build_object('ok', false, 'error', 'signed_in', 'message', 'The game is for visitors who are not signed in.');
  end if;
  if app.user_is_staff(p_user) or exists (select 1 from user_roles ur where ur.user_id = p_user and ur.role::text in ('admin', 'va', 'field')) then
    return jsonb_build_object('ok', false, 'error', 'staff', 'message', 'The game is for renters.');
  end if;
  select * into u from users where id = p_user;
  if u.id is null or nullif(btrim(coalesce(u.email, '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'email', 'message', 'Your account has no email address.');
  end if;
  if exists (select 1 from game_claims c where c.user_id = p_user or c.email = lower(u.email)
                or c.renter_id = (select rr.id from renters rr where rr.user_id = p_user limit 1)) then
    return jsonb_build_object('ok', false, 'error', 'claimed', 'message', 'Your account already has a code. One per person.');
  end if;
  r := app.server_game_claim_pre0076(p || jsonb_build_object('email', lower(u.email),
         'first_name', coalesce(nullif(btrim(coalesce(p ->> 'first_name', '')), ''), nullif(split_part(btrim(coalesce(u.full_name, '')), ' ', 1), ''), 'Renter')), null);
  if coalesce((r ->> 'ok')::boolean, false) then update game_claims set user_id = p_user where play_id = g.id and user_id is null; end if;
  return r;
end $$;

-- ================================================================ 6. the doors and privileges
create or replace function public.game_start(p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.game_start(p) $$;
-- the request-to-book form's play goes through the site's server (/api/games), which knows who is signed in
create or replace function public.server_game_start(p jsonb, p_user uuid default null) returns jsonb
language sql security definer set search_path = public, app as $$ select app.game_start_core(p, p_user) $$;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['game_cfg', 'game_kinds_on', 'game_next_kind', 'game_start_core', 'game_start', 'server_game_claim', 'server_game_claim_pre0076']))
        or (n.nspname = 'public' and p.proname = any (array['server_game_start', 'server_game_claim']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
  revoke all on function public.game_start(jsonb) from public;
  grant execute on function public.game_start(jsonb) to anon, authenticated, service_role;
end $$;

-- ================================================================ 7. the privacy policy
-- When and where the games show now, and that the browser remembers which games were shown. The live copy changes
-- only where it still carries the words of 0069; an Admin's own edit is left as it is.
update site_content_blocks
   set body = replace(replace(body,
     'Discount games are shown to visitors who browse several cars or stay a while.',
     'Discount games are shown to visitors of the Site, and offered in the booking request form.'),
     'and remembers whether you closed or played a game.',
     'and remembers which games you have seen and whether you closed or played one.')
 where block_key = 'legal.privacy' and body like '%Discount games are shown to visitors who browse several cars or stay a while.%';
update site_content_blocks set data = data || jsonb_build_object('last_updated', 'October 21, 2026')
 where block_key = 'legal.meta' and (data ->> 'last_updated') = 'October 19, 2026'
   and exists (select 1 from site_content_blocks b where b.block_key = 'legal.privacy' and b.body like '%offered in the booking request form%');

-- ================================================================ 8. the guides for this release
create or replace function app.guide_release_0076(p_portal text, p_slug text, p_kind text, p_after text, p_base_md text, p_title text, p_blurb text,
                                                  p_md text, p_html text) returns text
language sql security definer set search_path = public, app as $$
  select app.guide_release_section(p_portal, p_slug, p_kind, p_after, p_base_md, p_title, p_blurb, p_md, p_html)
$$;
revoke all on function app.guide_release_0076(text, text, text, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function app.guide_release_0076(text, text, text, text, text, text, text, text, text) to service_role;

-- GUIDES 0076 START (generated by supabase/seed/0076_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_0076('admin', 'discount-games-and-leads', 'chapter', 'live-visitors-and-live-chat', 'Visitors who are not signed in and browse a few cars get one quick game: spin the wheel, scratch to reveal, quick blackjack, cup shuffle or Plinko. Every play wins a promo code. To see the code they give a first name and an email (a mobile number is optional), so you get a lead. It is on by default; nothing needs setting up.

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
', 'Discount games and leads', 'The giveaway game, the code it sends, game leads to call, and the report.',
  'Visitors who are not signed in get one quick game soon after they arrive: spin the wheel, scratch to reveal, quick blackjack, cup shuffle or Plinko. Anyone who has not claimed a prize, signed-in renters too, is also offered it in the request-to-book form. Every play wins a promo code. To see the code they give a first name and an email (a mobile number is optional), so you get a lead. It is on by default; nothing needs setting up.

## What the visitor sees

- The first game: after 1 car page or 15 seconds on the site, whichever comes first, or (on a computer) when the mouse heads for the tabs. A card slides in at the bottom; on a phone it is a sheet at the bottom, never a full-screen block, and it always closes.
- Closed? Another game they have not seen yet comes back after 2 more car pages or 3 minutes, whichever comes first, and again on later visits: all five games before one repeats, at most 3 in one visit. The prize stays the one drawn for them, so closing never gives a new chance at a bigger prize. After claiming, never again.
- On the first page of a phone visit from a search engine there is no popup: the game waits for the second page, or comes 15 seconds later as a small bar at the bottom that opens the game when tapped.
- Never for someone signed in or already known by email (on the site), never on pay, sign or sign-in pages, never over the cookie banner.
- In the request-to-book form, on the add-ons and review steps: a card "Play for a discount on this booking" for anyone who has not claimed, signed-in renters included (never staff). A won code goes on that booking at once and the price beside the form changes; the code''s own rules still apply (the $50 prize needs 3 days or more, $75 at most for a percentage). **No thanks** or closing the game goes on with the booking as before.
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

- On or off, the cap for percentage codes ($75), how long a code is good for (7 days), when the first game shows (1 car page, 15 seconds, exit intent), when another shows after a close (2 more car pages, 180 seconds), the most games in one visit (3), the offer in the request-to-book form (on), the days a visitor keeps the same prize (14), the cars viewed for a Sales task (3) and the reminder (24 hours).
- Prizes and games: each prize with its percent or dollars, a minimum rental length and its chance; each game''s weight (0 turns it off). Press **Save prizes and games**. Codes already sent keep their value.
',
  '<p class="gd-p">Visitors who are not signed in get one quick game soon after they arrive: spin the wheel, scratch to reveal, quick blackjack, cup shuffle or Plinko. Anyone who has not claimed a prize, signed-in renters too, is also offered it in the request-to-book form. Every play wins a promo code. To see the code they give a first name and an email (a mobile number is optional), so you get a lead. It is on by default; nothing needs setting up.</p><section class="gd-task" id="discount-games-and-leads-what-the-visitor-sees" data-gd-task><h2 class="gd-h2">What the visitor sees</h2><ul class="gd-ul"><li>The first game: after 1 car page or 15 seconds on the site, whichever comes first, or (on a computer) when the mouse heads for the tabs. A card slides in at the bottom; on a phone it is a sheet at the bottom, never a full-screen block, and it always closes.</li><li>Closed? Another game they have not seen yet comes back after 2 more car pages or 3 minutes, whichever comes first, and again on later visits: all five games before one repeats, at most 3 in one visit. The prize stays the one drawn for them, so closing never gives a new chance at a bigger prize. After claiming, never again.</li><li>On the first page of a phone visit from a search engine there is no popup: the game waits for the second page, or comes 15 seconds later as a small bar at the bottom that opens the game when tapped.</li><li>Never for someone signed in or already known by email (on the site), never on pay, sign or sign-in pages, never over the cookie banner.</li><li>In the request-to-book form, on the add-ons and review steps: a card &quot;Play for a discount on this booking&quot; for anyone who has not claimed, signed-in renters included (never staff). A won code goes on that booking at once and the price beside the form changes; the code&#39;s own rules still apply (the $50 prize needs 3 days or more, $75 at most for a percentage). <b class="gd-ui">No thanks</b> or closing the game goes on with the booking as before.</li><li>Every play wins: 5% off (70 in 100), 10% off (25), 15% off (4) or $50 off a rental of 3 days or more (1). The prize is decided before the game starts; the game only shows it. The short terms with the game list the prizes and say the chances differ.</li><li>The code (for example WIN-7KQ4-XM2P) comes off the rental charge only, up to $75 for a percentage, on one booking, within 7 days, one per person, email, phone and device, never with another code. The email with the code goes either way; one reminder goes 24 hours before it expires. Offers only with the marketing box ticked.</li><li>On this device the code fills itself into the promo code box of the request form. Like every promo code, the discount is shared with the owner in the split.</li></ul></section><section class="gd-task" id="discount-games-and-leads-leads" data-gd-task><h2 class="gd-h2">Leads</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Leads</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The tiles: plays, claims, codes on booking requests, bookings, revenue and discounts from game codes in the last 30 days, then the same by game and by prize.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each claim: when, the name (and &quot;on the site now&quot;), email and phone, the prize and game, the code and whether it is used (with the booking), marketing consent, and the visit: cars and pages viewed, minutes, city and device.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Call</b> or <b class="gd-ui">Email</b>, then <b class="gd-ui">Contacted</b> (it is yours). <b class="gd-ui">Close</b> with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A visitor who viewed 3 cars or more also gets a Sales task, for example &quot;Claimed 10% off, viewed 6 cars: Maya&quot;. It closes when the code goes on a request.</div></li></ol></div></section><section class="gd-task" id="discount-games-and-leads-settings" data-gd-task><h2 class="gd-h2">Settings</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Discount games</b>.</p><ul class="gd-ul"><li>On or off, the cap for percentage codes ($75), how long a code is good for (7 days), when the first game shows (1 car page, 15 seconds, exit intent), when another shows after a close (2 more car pages, 180 seconds), the most games in one visit (3), the offer in the request-to-book form (on), the days a visitor keeps the same prize (14), the cars viewed for a Sales task (3) and the reminder (24 hours).</li><li>Prizes and games: each prize with its percent or dollars, a minimum rental length and its chance; each game&#39;s weight (0 turns it off). Press <b class="gd-ui">Save prizes and games</b>. Codes already sent keep their value.</li></ul></section>');
select app.guide_release_0076('va', 'discount-game-leads', 'chapter', 'live-visitors-and-live-chat', 'Visitors who are not signed in play a quick game on the site and win a promo code. To get it they give a first name, an email and sometimes a mobile number. Customer service and Sales follow them up.

## Game leads

**My work** > **Game leads**.

1. Each claim: when, the name (and "on the site now"), email and phone, the prize, the code and whether it is used, marketing consent, and the cars and pages they viewed.
2. Press **Call** or **Email**. Help them pick a car and send a request; the code goes in the promo code box (on their own device it is filled in). Then press **Contacted**.
3. **Close** with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.

A visitor who viewed 3 cars or more also raises a Sales task, for example "Claimed 10% off, viewed 6 cars: Maya". It closes when the code goes on a request.

> Tip: Without marketing consent, talk only about their request and the code they asked for: no other offers. The code takes up to $75 off the rental charge (a percentage), or $50 off a rental of 3 days or more, on one booking within 7 days.
', 'Discount game leads', 'Game leads to call or email, the code they won, whether it is used, and the Sales task.',
  'Visitors play a quick game on the site, or in the request-to-book form, and win a promo code. To get it they give a first name, an email and sometimes a mobile number. Customer service and Sales follow them up.

## Game leads

**My work** > **Game leads**.

1. Each claim: when, the name (and "on the site now"), email and phone, the prize, the code and whether it is used, marketing consent, and the cars and pages they viewed.
2. Press **Call** or **Email**. Help them pick a car and send a request; the code goes in the promo code box (on their own device it is filled in). Then press **Contacted**.
3. **Close** with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.

A visitor who viewed 3 cars or more also raises a Sales task, for example "Claimed 10% off, viewed 6 cars: Maya". It closes when the code goes on a request.

> Tip: Without marketing consent, talk only about their request and the code they asked for: no other offers. The code takes up to $75 off the rental charge (a percentage), or $50 off a rental of 3 days or more, on one booking within 7 days.
',
  '<p class="gd-p">Visitors play a quick game on the site, or in the request-to-book form, and win a promo code. To get it they give a first name, an email and sometimes a mobile number. Customer service and Sales follow them up.</p><section class="gd-task" id="discount-game-leads-game-leads" data-gd-task><h2 class="gd-h2">Game leads</h2><p class="gd-p"><b class="gd-ui">My work</b> &gt; <b class="gd-ui">Game leads</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each claim: when, the name (and &quot;on the site now&quot;), email and phone, the prize, the code and whether it is used, marketing consent, and the cars and pages they viewed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Call</b> or <b class="gd-ui">Email</b>. Help them pick a car and send a request; the code goes in the promo code box (on their own device it is filled in). Then press <b class="gd-ui">Contacted</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Close</b> with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.</div></li></ol></div><p class="gd-p">A visitor who viewed 3 cars or more also raises a Sales task, for example &quot;Claimed 10% off, viewed 6 cars: Maya&quot;. It closes when the code goes on a request.</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Without marketing consent, talk only about their request and the code they asked for: no other offers. The code takes up to $75 off the rental charge (a percentage), or $50 off a rental of 3 days or more, on one booking within 7 days.</div></aside></section>');
-- GUIDES 0076 END
