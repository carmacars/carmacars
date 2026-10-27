-- 0176_games_repop_play_again.sql
-- The prize that pops up again is a chance to play again (docs/changes/2026-10-27-games-repop-play-again.md). The owner:
-- "Why is the CarmaCars giveaway popup full screen showing your '5% off is still waiting' every single time you open a
-- car page rather than letting you play again like what we agreed on."
--
-- 0171 made a prize won and not claimed pop up again as the full card of that same prize, on the rules of a new game
-- (the first-show rules on every visit, the re-show rules after each close, up to 4 a visit). The browser now shows it
-- once a visit, as the small slide-in, with Get my code and Play again (web/src/features/games). This migration gives
-- Play again its server side:
--
-- 1. A new setting, program_settings.game_saved_again_days (1 by default, 0 to 30; 0 turns Play again on a saved prize
--    off): a visitor may play again on their saved prize once in that many days (Toronto days: with 1, once a day), and
--    once a visit (the session).
-- 2. game_start with p.again_of = the token of the visitor's saved play (revealed, not claimed, not another go, still
--    kept, since their latest claim; the site only, never signed in) starts a new play: another kind of game and a new
--    draw from the whole prize table (another go included). The visitor keeps the better of the two prizes (its value on
--    an average 4-day rental, app.game_prize_value; a tie keeps the saved one): the other play is closed
--    (game_plays.dropped_at) and is never claimed, never the saved prize again. The answer carries keep: {from: 'new' or
--    'saved', token (the play to claim), prize, other (the other prize's words)}. Another go as the new prize waits: its
--    second game (p.replay_of) is compared with the saved prize the same way. Refused: reason again_limited (with
--    again_after when a day is the reason), again_not_found, and as for any new game on the site known and in_progress.
--    The start limit per visitor applies.
-- 3. A saved play's answer says whether Play again may start now: again: {ok, again_after}.
-- 4. The claim refuses a closed play (error kept_other).
-- 5. The guides.
-- No applied migration is edited (functions of earlier migrations are changed in place, as 0171 and 0172 do).

-- ================================================================ 1. the setting and the closed play
alter table program_settings add column if not exists game_saved_again_days integer not null default 1
  check (game_saved_again_days between 0 and 30);
comment on column program_settings.game_saved_again_days is 'Discount games (0176): a visitor with a prize won and not claimed may press Play again (a new game; the better prize is kept) once in this many days (Toronto days) and once a visit. 0: no Play again on a saved prize.';

alter table game_plays
  add column if not exists again_of uuid references game_plays (id) on delete set null,
  add column if not exists dropped_at timestamptz;
create index if not exists game_plays_again_idx on game_plays (visitor_id, created_at desc) where again_of is not null;
comment on column game_plays.again_of is '0176: the saved play (won, not claimed) whose Play again started this one, or for a second game of another go, the saved play of its first.';
comment on column game_plays.dropped_at is '0176: closed after Play again because the other prize was better (or as good): never claimed, never saved again.';

-- ================================================================ 2. the value of a prize, the limit, the better prize
-- What a prize takes off an average rental (the published cars' average daily rate for 4 days, $400 without rates), as
-- the code applies it: never on a shorter booking than its minimum, never above its cap; another go: 0. Only used to
-- compare two prizes.
create or replace function app.game_prize_value(p jsonb) returns numeric
language sql stable security definer set search_path = public, app as $$
  with b as (
    select coalesce((select avg(rc.daily_rate_cents) * 4 from rate_cards rc
                      where rc.daily_rate_cents > 0 and rc.effective_from <= app.today() and (rc.effective_to is null or rc.effective_to >= app.today())), 40000)::numeric as c,
           4::numeric as d
  )
  select case
    when app.game_prize_is_replay(p) then 0
    when (p ->> 'min_days') is not null and b.d < (p ->> 'min_days')::numeric then 0
    else least(
      case when p ? 'percent_bps' then b.c * (p ->> 'percent_bps')::numeric / 10000
           when p ? 'free_days' then b.c * least((p ->> 'free_days')::numeric, b.d) / b.d
           else coalesce((p ->> 'amount_cents')::numeric, 0) end,
      b.c,
      coalesce(app.game_prize_cap(p)::numeric, b.c))
  end
  from b
$$;

-- When this visitor may press Play again on a saved prize: null when they may now; 'infinity' when the setting is 0 or
-- they already did in this visit (the session); otherwise the start of the Toronto day they may again.
create or replace function app.game_saved_again_after(p_vid uuid, p_sid uuid) returns timestamptz
language sql stable security definer set search_path = public, app as $$
  select case
    when s.d = 0 then 'infinity'::timestamptz
    when l.last is not null and app.local_date(l.last) > app.today() - s.d then ((app.local_date(l.last) + s.d)::timestamp at time zone app.tz())
    when p_sid is not null and exists (select 1 from game_plays x where x.visitor_id = p_vid and x.session_id = p_sid and x.again_of is not null) then 'infinity'::timestamptz
  end
  from (select (app.settings()).game_saved_again_days as d) s,
       (select max(x.created_at) as last from game_plays x where x.visitor_id = p_vid and x.again_of is not null) l
$$;

-- {ok, again_after} for a saved play's answer.
create or replace function app.game_saved_again_json(p_vid uuid, p_sid uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('ok', a is null) || case when a is not null and a <> 'infinity'::timestamptz then jsonb_build_object('again_after', a) else '{}'::jsonb end
    from (select app.game_saved_again_after(p_vid, p_sid) as a) x
$$;

-- The saved play p_saved against the new play p_new (a discount, revealed or not): the better prize stays open, the other
-- play is closed. Returns keep: {from, token, prize, other}; null when the saved play is no longer open (the new stands).
create or replace function app.game_keep_better(p_saved uuid, p_new uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s game_plays;
  n game_plays;
  k game_plays;
  o game_plays;
  v_from text;
begin
  select * into s from game_plays where id = p_saved for update;
  select * into n from game_plays where id = p_new for update;
  if s.id is null or n.id is null or s.claimed_at is not null or s.dropped_at is not null or app.game_prize_is_replay(n.prize) then return null; end if;
  if app.game_prize_value(n.prize) > app.game_prize_value(s.prize) then
    update game_plays set dropped_at = clock_timestamp() where id = s.id;
    k := n; o := s; v_from := 'new';
  else
    update game_plays set dropped_at = clock_timestamp() where id = n.id;
    k := s; o := n; v_from := 'saved';
  end if;
  return jsonb_build_object('from', v_from, 'token', k.token, 'prize', app.game_play_json(k) -> 'prize', 'other', app.game_prize_label(o.prize));
end $$;

-- ================================================================ 3. the play: Play again on a saved prize
create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0176: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- Play again on a saved prize: before the replay branch
select pg_temp.patch_fn('app.game_start_core(jsonb, uuid)'::regprocedure,
  $o$  -- 0171: Play again on a replay prize: the second game$o$,
  $n$  -- 0176: Play again on a saved prize (won, not claimed): a new game and a new draw; the better prize is kept
  if p ? 'again_of' then
    if v_ctx <> 'site' or p_user is not null then return jsonb_build_object('ok', false, 'reason', 'again_not_found'); end if;
    select * into o from game_plays where token = p ->> 'again_of' for update;
    if o.id is null or o.visitor_id <> v_vid or o.user_id is not null or o.context <> 'site' or o.revealed_at is null or o.claimed_at is not null
       or o.dropped_at is not null or app.game_prize_is_replay(o.prize) or o.created_at <= coalesce(v_last, '-infinity'::timestamptz)
       or o.created_at <= now() - make_interval(days => ps.game_dismiss_days) then
      return jsonb_build_object('ok', false, 'reason', 'again_not_found');
    end if;
    -- as for any new game on the site: not for a visitor known by email, nor with a booking request in progress
    if app.game_known_visitor(v_vid) then return jsonb_build_object('ok', false, 'reason', 'known'); end if;
    if exists (select 1 from contact_captures cc where cc.visitor_id = v_vid and cc.form = 'booking_request' and cc.last_at > now() - interval '30 days') then
      return jsonb_build_object('ok', false, 'reason', 'in_progress');
    end if;
    v_again := app.game_saved_again_after(v_vid, v_sid);
    if v_again is not null then
      return jsonb_build_object('ok', false, 'reason', 'again_limited')
             || case when v_again <> 'infinity'::timestamptz then jsonb_build_object('again_after', v_again) else '{}'::jsonb end;
    end if;
    if coalesce((p ->> 'dry')::boolean, false) then return jsonb_build_object('ok', true, 'dry', true, 'again', true); end if;
    if not app.rate_limit('game-start:' || v_vid, 10, interval '1 hour') or not app.rate_limit('game-start', 3000, interval '1 hour') then
      return jsonb_build_object('ok', false, 'reason', 'limited');
    end if;
    v_kind := app.game_next_kind(v_vid, null, v_seen || o.game, o.game);
    if v_kind = o.game then
      v_kind := coalesce((select k from unnest(app.game_kinds_on()) k where k <> o.game order by random() limit 1), v_kind);
    end if;
    insert into game_plays (visitor_id, session_id, game, prize, device, path, trigger, context, again_of, created_at)
    values (v_vid, coalesce(v_sid, o.session_id), v_kind, app.game_draw(ps.game_prizes),
            coalesce(case when p ->> 'device' in ('phone', 'tablet', 'desktop') then p ->> 'device' end, o.device), coalesce(left(p ->> 'path', 300), o.path),
            case when p ->> 'trigger' in ('pages', 'time', 'exit') then p ->> 'trigger' else o.trigger end, 'site', o.id, clock_timestamp())
    returning * into g;
    r := app.game_play_json(g) || jsonb_build_object('context', g.context);
    -- another go waits for its second game; a discount is compared now (the game only shows the draw)
    if not app.game_prize_is_replay(g.prize) then r := r || jsonb_strip_nulls(jsonb_build_object('keep', app.game_keep_better(o.id, g.id))); end if;
    return r;
  end if;

  -- 0171: Play again on a replay prize: the second game$n$);

-- the second game of another go won by Play again on a saved prize: compared with that saved prize
select pg_temp.patch_fn('app.game_start_core(jsonb, uuid)'::regprocedure,
  $o$            o.trigger, o.context, o.user_id, o.id, clock_timestamp())
    returning * into g;
    r := app.game_play_json(g) || jsonb_build_object('context', g.context);$o$,
  $n$            o.trigger, o.context, o.user_id, o.id, clock_timestamp())
    returning * into g;
    r := app.game_play_json(g) || jsonb_build_object('context', g.context);
    -- 0176: another go won by Play again on a saved prize: its second game against that saved prize
    if o.again_of is not null then
      update game_plays set again_of = o.again_of where id = g.id;
      r := r || jsonb_strip_nulls(jsonb_build_object('keep', app.game_keep_better(o.again_of, g.id)));
    end if;$n$);

-- a closed play is never the visitor's open play
select pg_temp.patch_fn('app.game_start_core(jsonb, uuid)'::regprocedure,
  $o$   where (visitor_id = v_vid or (p_user is not null and user_id = p_user)) and claimed_at is null
     and created_at$o$,
  $n$   where (visitor_id = v_vid or (p_user is not null and user_id = p_user)) and claimed_at is null and dropped_at is null
     and created_at$n$);

-- a saved prize says whether Play again may start now
select pg_temp.patch_fn('app.game_start_core(jsonb, uuid)'::regprocedure,
  $o$    r := app.game_play_json(g) || jsonb_build_object('saved', true);$o$,
  $n$    r := app.game_play_json(g) || jsonb_build_object('saved', true);
    -- 0176: Play again on it (the site, a discount): once a visit and once in game_saved_again_days
    if v_ctx = 'site' and p_user is null and not app.game_prize_is_replay(g.prize) then
      r := r || jsonb_build_object('again', case when app.game_known_visitor(v_vid) then '{"ok": false}'::jsonb else app.game_saved_again_json(v_vid, v_sid) end);
    end if;$n$);

-- ================================================================ 4. the claim: never a closed play
create or replace function app.server_game_claim(p jsonb, p_user uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if exists (select 1 from game_plays g where g.token = p ->> 'token' and app.game_prize_is_replay(g.prize)) then
    return jsonb_build_object('ok', false, 'error', 'replay', 'message', 'This prize is another go, not a code. Press Play again for your second game.');
  end if;
  -- 0176: after Play again the visitor keeps the better prize; the other play is closed
  if exists (select 1 from game_plays g where g.token = p ->> 'token' and g.dropped_at is not null) then
    return jsonb_build_object('ok', false, 'error', 'kept_other', 'message', 'You kept your other prize. Close this and open it from "Your prize is saved".');
  end if;
  return app.server_game_claim_pre0171(p, p_user);
end $$;

-- ================================================================ 5. privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['game_start_core', 'server_game_claim', 'game_prize_value', 'game_saved_again_after', 'game_saved_again_json', 'game_keep_better'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ================================================================ 6. the guides
-- GUIDES 0176 START (generated by supabase/seed/0176_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('admin', 'discount-games-and-leads', 'chapter', 'text-alerts-email-text-or-both', 'Visitors who are not signed in get one quick game: spin the wheel, scratch to reveal, quick blackjack, cup shuffle, Plinko, the card pack, coin flip, dice roll, slot machine, prize drop or mystery box. Every play wins a promo code or another go. To see the code they give a first name and an email (a mobile number is optional), so you get a lead. It is on by default; nothing needs setting up.

## What the visitor sees

- On the 2nd page view (any page) or after 30 seconds on the site, whichever first, or (on a computer) when the mouse heads for the tabs. A card slides in at the bottom; on a phone it is a sheet at the bottom, never a full-screen block, and it always closes.
- Never for someone signed in, never on booking, pay, sign or sign-in pages, never on the first page of a visit from a search engine on a phone, never over the cookie banner; no new game for someone already known by email or with a booking request in progress. Closed, another game comes back on the 3rd page view after the close or 2 minutes later, at most 4 in a visit, and again on their next visit.
- After claiming a code: no game for the rest of that visit. A day after their latest claim the game comes back on their next visit with the usual timings, a new game and a new draw, and they can win another code. The day counts for the browser, the email, the mobile number and (in the request-to-book form) the account; within it the game says when they can play again. A visitor known only through their own claim still gets it; one known through a booking request, the chat, a sign-in or as a renter does not.
- Won and not claimed: a small badge "Your 5% off is saved" stays on the pages, and the card itself pops up again with the prize ("Your 5% off is still waiting", with the form to get the code) at the moments a game would, until they claim it or the prize ends after 14 days.
- Every play wins: 5% off (54 in 100), 10% off (25), another go (15), 15% off (4), $50 off a rental of 3 days or more (1), 25% off up to $150 (0.6), $100 off a rental of 4 days or more (0.3) or one free day on a rental of 3 days or more (0.1). The prize is decided before the game starts; the game only shows it. The short terms with the game list the prizes and say the chances differ.
- Another go: the card says "You won another go!" and **Play again** starts a second, different game whose prize is drawn from the discounts only, so it always ends in a code. One replay at a time; it is never a code itself. Closed before pressing it, the card offers it again next time.
- The code (for example WIN-7KQ4-XM2P) comes off the rental charge only, up to $75 for a percentage, on one booking, within 7 days, one code a day per person, email, phone and device, never with another code. An earlier code not used yet stays good until it ends. The email with the code goes either way; a reminder goes 3 days before its last day and another the day before (Promo codes). Offers only with the marketing box ticked.
- On this device the code fills itself into the promo code box of the request form. Like every promo code, the discount is shared with the owner in the split.

## Leads

**Bookings** > **Renter leads**.

1. The tiles: plays, claims, codes on booking requests, bookings, revenue and discounts from game codes in the last 30 days, then the same by game and by prize (Play again shows its plays; it has no claims).
2. Each claim: when, the name (and "on the site now"), email and phone, the prize and game, the code and whether it is used (with the booking), marketing consent, and the visit: cars and pages viewed, minutes, city and device. A person who won again shows "2nd code of 2" under the name on each of their lines.
3. Press **Call** or **Email**, then **Contacted** (it is yours). **Close** with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.
4. A visitor who viewed 3 cars or more also gets a Sales task, for example "Claimed 10% off, viewed 6 cars: Maya". It closes when the code goes on a request. A new code while that task is open is added to it, not a second task.

## Contact details typed into forms

**Bookings** > **Renter leads**, the card "Typed into forms" at the top.

1. When someone types a name, email or phone into the request to book, the contact form, List your car, the owner application, Create an account, the discount game or the chat, it is saved as soon as each field is valid, even if they never press Send.
2. Each line: when, the name (and "On the site now"), email and phone, the form, and Sent or Not sent. "Email not confirmed" means the account was opened from the form and the person has not opened the link we emailed them yet.
3. After 30 minutes without sending, To do shows "Unfinished request from Maya Chen: follow up" (not raised from 23:00 to 07:00, the quiet hours of the site alerts). Call or email them; the task closes by itself when they send the form.
4. Only what they typed is saved, and never used for offers without their consent.

> Good to know: A new email gets an account at once (no password, email not confirmed) and one email "Continue your request" 30 minutes later, between 9:00 and 21:00. Until they open its link they cannot accept an offer, sign, pay or upload documents. An account never confirmed closes after 30 days; the lead stays. It is on by default; the times and the To do are in **Settings** > **Program**, the card "Forms left unfinished".

## Settings

**Settings** > **Discount games**.

- On or off, the cap for percentage codes ($75), how long a code is good for (7 days), when it shows (2nd page view, 30 seconds, exit intent), the days a visitor keeps their prize (14: closing never draws a new one, and a prize not claimed pops up again until then), the days after a claim before the game comes back (1; 0 is one code per person ever), and the cars viewed for a Sales task (3). The reminders before a code ends are under Promo codes.
- After a visitor closes a game (or the card of a prize waiting for them), the next card shows on their 3rd page view after the close (any page) or 2 minutes later, whichever first; at most 4 in one visit, no daily cap unless you set one. All are settings. Never on booking, payment or signing pages; the request-to-book form has its own game.
- Prizes and games: each prize with its percent, dollars or free days, a minimum rental length, its cap and its chance, or Play again (another go, at most one); each game''s weight (0 turns it off). Press **Save prizes and games**. Codes already sent keep their value.
', 'Discount games and leads', 'The giveaway game, the code it sends, game leads to call, and the report.',
  'Visitors who are not signed in get one quick game: spin the wheel, scratch to reveal, quick blackjack, cup shuffle, Plinko, the card pack, coin flip, dice roll, slot machine, prize drop or mystery box. Every play wins a promo code or another go. To see the code they give a first name and an email (a mobile number is optional), so you get a lead. It is on by default; nothing needs setting up.

## What the visitor sees

- On the 2nd page view (any page) or after 30 seconds on the site, whichever first, or (on a computer) when the mouse heads for the tabs. A card slides in at the bottom; on a phone it is a sheet at the bottom, never a full-screen block, and it always closes.
- Never for someone signed in, never on booking, pay, sign or sign-in pages, never on the first page of a visit from a search engine on a phone, never over the cookie banner; no new game for someone already known by email or with a booking request in progress. Closed, another game comes back on the 3rd page view after the close or 2 minutes later, at most 4 in a visit, and again on their next visit.
- After claiming a code: no game for the rest of that visit. A day after their latest claim the game comes back on their next visit with the usual timings, a new game and a new draw, and they can win another code. The day counts for the browser, the email, the mobile number and (in the request-to-book form) the account; within it the game says when they can play again. A visitor known only through their own claim still gets it; one known through a booking request, the chat, a sign-in or as a renter does not.
- Won and not claimed: a small badge "Your 5% off is saved" with **Get my code** and **Play again** stays on the pages. On a later visit, at the moment a first game would show, the prize pops up by itself once as a small slide-in at the bottom ("Your 5% off is still waiting", the same two buttons), never as a card over the page; closed, it does not come back in that visit. Until they claim it or the prize ends after 14 days.
- **Play again** on a prize not claimed: a new, different game with a new draw. They keep the better of the two prizes and the other is closed, so there is only ever one code to claim: the card says "You won 15% off" or "You keep your 5% off". Once a visit and once a day (a setting).
- Every play wins: 5% off (54 in 100), 10% off (25), another go (15), 15% off (4), $50 off a rental of 3 days or more (1), 25% off up to $150 (0.6), $100 off a rental of 4 days or more (0.3) or one free day on a rental of 3 days or more (0.1). The prize is decided before the game starts; the game only shows it. The short terms with the game list the prizes and say the chances differ.
- Another go: the card says "You won another go!" and **Play again** starts a second, different game whose prize is drawn from the discounts only, so it always ends in a code. One replay at a time; it is never a code itself. Closed before pressing it, the card offers it again next time.
- The code (for example WIN-7KQ4-XM2P) comes off the rental charge only, up to $75 for a percentage, on one booking, within 7 days, one code a day per person, email, phone and device, never with another code. An earlier code not used yet stays good until it ends. The email with the code goes either way; a reminder goes 3 days before its last day and another the day before (Promo codes). Offers only with the marketing box ticked.
- On this device the code fills itself into the promo code box of the request form. Like every promo code, the discount is shared with the owner in the split.

## Leads

**Bookings** > **Renter leads**.

1. The tiles: plays, claims, codes on booking requests, bookings, revenue and discounts from game codes in the last 30 days, then the same by game and by prize (Play again shows its plays; it has no claims).
2. Each claim: when, the name (and "on the site now"), email and phone, the prize and game, the code and whether it is used (with the booking), marketing consent, and the visit: cars and pages viewed, minutes, city and device. A person who won again shows "2nd code of 2" under the name on each of their lines.
3. Press **Call** or **Email**, then **Contacted** (it is yours). **Close** with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.
4. A visitor who viewed 3 cars or more also gets a Sales task, for example "Claimed 10% off, viewed 6 cars: Maya". It closes when the code goes on a request. A new code while that task is open is added to it, not a second task.

## Contact details typed into forms

**Bookings** > **Renter leads**, the card "Typed into forms" at the top.

1. When someone types a name, email or phone into the request to book, the contact form, List your car, the owner application, Create an account, the discount game or the chat, it is saved as soon as each field is valid, even if they never press Send.
2. Each line: when, the name (and "On the site now"), email and phone, the form, and Sent or Not sent. "Email not confirmed" means the account was opened from the form and the person has not opened the link we emailed them yet.
3. After 30 minutes without sending, To do shows "Unfinished request from Maya Chen: follow up" (not raised from 23:00 to 07:00, the quiet hours of the site alerts). Call or email them; the task closes by itself when they send the form.
4. Only what they typed is saved, and never used for offers without their consent.

> Good to know: A new email gets an account at once (no password, email not confirmed) and one email "Continue your request" 30 minutes later, between 9:00 and 21:00. Until they open its link they cannot accept an offer, sign, pay or upload documents. An account never confirmed closes after 30 days; the lead stays. It is on by default; the times and the To do are in **Settings** > **Program**, the card "Forms left unfinished".

## Settings

**Settings** > **Discount games**.

- On or off, the cap for percentage codes ($75), how long a code is good for (7 days), when it shows (2nd page view, 30 seconds, exit intent), the days a visitor keeps their prize (14: closing never draws a new one, and a prize not claimed pops up again until then), the days after a claim before the game comes back (1; 0 is one code per person ever), how often Play again works on a prize not claimed (once a day; 0 turns it off), and the cars viewed for a Sales task (3). The reminders before a code ends are under Promo codes.
- After a visitor closes a game, the next card shows on their 3rd page view after the close (any page) or 2 minutes later, whichever first; at most 4 in one visit, no daily cap unless you set one. A prize waiting for them pops up once a visit only. All are settings. Never on booking, payment or signing pages; the request-to-book form has its own game.
- Prizes and games: each prize with its percent, dollars or free days, a minimum rental length, its cap and its chance, or Play again (another go, at most one); each game''s weight (0 turns it off). Press **Save prizes and games**. Codes already sent keep their value.
',
  '<p class="gd-p">Visitors who are not signed in get one quick game: spin the wheel, scratch to reveal, quick blackjack, cup shuffle, Plinko, the card pack, coin flip, dice roll, slot machine, prize drop or mystery box. Every play wins a promo code or another go. To see the code they give a first name and an email (a mobile number is optional), so you get a lead. It is on by default; nothing needs setting up.</p><section class="gd-task" id="discount-games-and-leads-what-the-visitor-sees" data-gd-task><h2 class="gd-h2">What the visitor sees</h2><ul class="gd-ul"><li>On the 2nd page view (any page) or after 30 seconds on the site, whichever first, or (on a computer) when the mouse heads for the tabs. A card slides in at the bottom; on a phone it is a sheet at the bottom, never a full-screen block, and it always closes.</li><li>Never for someone signed in, never on booking, pay, sign or sign-in pages, never on the first page of a visit from a search engine on a phone, never over the cookie banner; no new game for someone already known by email or with a booking request in progress. Closed, another game comes back on the 3rd page view after the close or 2 minutes later, at most 4 in a visit, and again on their next visit.</li><li>After claiming a code: no game for the rest of that visit. A day after their latest claim the game comes back on their next visit with the usual timings, a new game and a new draw, and they can win another code. The day counts for the browser, the email, the mobile number and (in the request-to-book form) the account; within it the game says when they can play again. A visitor known only through their own claim still gets it; one known through a booking request, the chat, a sign-in or as a renter does not.</li><li>Won and not claimed: a small badge &quot;Your 5% off is saved&quot; with <b class="gd-ui">Get my code</b> and <b class="gd-ui">Play again</b> stays on the pages. On a later visit, at the moment a first game would show, the prize pops up by itself once as a small slide-in at the bottom (&quot;Your 5% off is still waiting&quot;, the same two buttons), never as a card over the page; closed, it does not come back in that visit. Until they claim it or the prize ends after 14 days.</li><li><b class="gd-ui">Play again</b> on a prize not claimed: a new, different game with a new draw. They keep the better of the two prizes and the other is closed, so there is only ever one code to claim: the card says &quot;You won 15% off&quot; or &quot;You keep your 5% off&quot;. Once a visit and once a day (a setting).</li><li>Every play wins: 5% off (54 in 100), 10% off (25), another go (15), 15% off (4), $50 off a rental of 3 days or more (1), 25% off up to $150 (0.6), $100 off a rental of 4 days or more (0.3) or one free day on a rental of 3 days or more (0.1). The prize is decided before the game starts; the game only shows it. The short terms with the game list the prizes and say the chances differ.</li><li>Another go: the card says &quot;You won another go!&quot; and <b class="gd-ui">Play again</b> starts a second, different game whose prize is drawn from the discounts only, so it always ends in a code. One replay at a time; it is never a code itself. Closed before pressing it, the card offers it again next time.</li><li>The code (for example WIN-7KQ4-XM2P) comes off the rental charge only, up to $75 for a percentage, on one booking, within 7 days, one code a day per person, email, phone and device, never with another code. An earlier code not used yet stays good until it ends. The email with the code goes either way; a reminder goes 3 days before its last day and another the day before (Promo codes). Offers only with the marketing box ticked.</li><li>On this device the code fills itself into the promo code box of the request form. Like every promo code, the discount is shared with the owner in the split.</li></ul></section><section class="gd-task" id="discount-games-and-leads-leads" data-gd-task><h2 class="gd-h2">Leads</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Renter leads</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The tiles: plays, claims, codes on booking requests, bookings, revenue and discounts from game codes in the last 30 days, then the same by game and by prize (Play again shows its plays; it has no claims).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each claim: when, the name (and &quot;on the site now&quot;), email and phone, the prize and game, the code and whether it is used (with the booking), marketing consent, and the visit: cars and pages viewed, minutes, city and device. A person who won again shows &quot;2nd code of 2&quot; under the name on each of their lines.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Call</b> or <b class="gd-ui">Email</b>, then <b class="gd-ui">Contacted</b> (it is yours). <b class="gd-ui">Close</b> with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A visitor who viewed 3 cars or more also gets a Sales task, for example &quot;Claimed 10% off, viewed 6 cars: Maya&quot;. It closes when the code goes on a request. A new code while that task is open is added to it, not a second task.</div></li></ol></div></section><section class="gd-task" id="discount-games-and-leads-contact-details-typed-into-forms" data-gd-task><h2 class="gd-h2">Contact details typed into forms</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Renter leads</b>, the card &quot;Typed into forms&quot; at the top.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When someone types a name, email or phone into the request to book, the contact form, List your car, the owner application, Create an account, the discount game or the chat, it is saved as soon as each field is valid, even if they never press Send.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each line: when, the name (and &quot;On the site now&quot;), email and phone, the form, and Sent or Not sent. &quot;Email not confirmed&quot; means the account was opened from the form and the person has not opened the link we emailed them yet.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">After 30 minutes without sending, To do shows &quot;Unfinished request from Maya Chen: follow up&quot; (not raised from 23:00 to 07:00, the quiet hours of the site alerts). Call or email them; the task closes by itself when they send the form.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Only what they typed is saved, and never used for offers without their consent.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A new email gets an account at once (no password, email not confirmed) and one email &quot;Continue your request&quot; 30 minutes later, between 9:00 and 21:00. Until they open its link they cannot accept an offer, sign, pay or upload documents. An account never confirmed closes after 30 days; the lead stays. It is on by default; the times and the To do are in <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>, the card &quot;Forms left unfinished&quot;.</div></aside></section><section class="gd-task" id="discount-games-and-leads-settings" data-gd-task><h2 class="gd-h2">Settings</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Discount games</b>.</p><ul class="gd-ul"><li>On or off, the cap for percentage codes ($75), how long a code is good for (7 days), when it shows (2nd page view, 30 seconds, exit intent), the days a visitor keeps their prize (14: closing never draws a new one, and a prize not claimed pops up again until then), the days after a claim before the game comes back (1; 0 is one code per person ever), how often Play again works on a prize not claimed (once a day; 0 turns it off), and the cars viewed for a Sales task (3). The reminders before a code ends are under Promo codes.</li><li>After a visitor closes a game, the next card shows on their 3rd page view after the close (any page) or 2 minutes later, whichever first; at most 4 in one visit, no daily cap unless you set one. A prize waiting for them pops up once a visit only. All are settings. Never on booking, payment or signing pages; the request-to-book form has its own game.</li><li>Prizes and games: each prize with its percent, dollars or free days, a minimum rental length, its cap and its chance, or Play again (another go, at most one); each game&#39;s weight (0 turns it off). Press <b class="gd-ui">Save prizes and games</b>. Codes already sent keep their value.</li></ul></section>');
-- GUIDES 0176 END
