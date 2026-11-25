-- 5040 (release 50; docs/changes/2026-11-25-r50-games-signed-in.md): the discount game on the site is for signed-in people
-- too. The owner: "everyone should see it". Until now the site's game (0069, 0081, 0100, 0170 to 0176) refused anyone signed
-- in ("signed_in"), and a signed-in renter only played inside the request-to-book form. Now:
--   * a signed-in renter plays on the site and claims with their account (name and email from the account, no typing): the
--     code is tied to their user and renter (game_claims.user_id, renter_id) so it shows in My discounts (2423) and applies
--     at checkout. The other limits hold: the wait after a claim (the account's, its email's, its renter's and the
--     browser's), the dismiss days, the visit rules in the browser.
--   * a signed-in person is not "known" (the rule that leaves visitors known by email alone is for people who are not
--     signed in; the account is the identity). Play again on a saved prize stays for visitors who are not signed in.
--   * staff and admin (Admin, Sales and other VA roles, field) may see and play it on the site, but never get a code:
--     their claim says "Staff can't use game codes: this is a preview of what visitors see." Enforced here, in
--     app.server_game_claim, before anything is created. The request-to-book form still turns staff away (it applies a
--     code to a booking).
-- SCHEMA_MARKER 5040.

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '5040: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. who is staff
create or replace function app.game_is_staff(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select p_user is not null and (app.user_is_staff(p_user)
         or exists (select 1 from user_roles ur where ur.user_id = p_user and ur.role::text in ('admin', 'va', 'field')))
$$;

-- ================================================================ 2. the play
select pg_temp.patch_fn('app.game_start_core(jsonb, uuid)'::regprocedure,
  $o$  v_first text;
  v_saved boolean;$o$,
  $n$  v_first text;
  v_staff boolean := app.game_is_staff(p_user);
  v_saved boolean;$n$);
select pg_temp.patch_fn('app.game_start_core(jsonb, uuid)'::regprocedure,
  $o$  if v_ctx = 'site' and p_user is not null then return jsonb_build_object('ok', false, 'reason', 'signed_in'); end if;
  if v_ctx = 'booking' then
    if not ps.game_booking_offer then return jsonb_build_object('ok', false, 'reason', 'off'); end if;
    if p_user is not null then
      if app.user_is_staff(p_user) or exists (select 1 from user_roles ur where ur.user_id = p_user and ur.role::text in ('admin', 'va', 'field')) then
        return jsonb_build_object('ok', false, 'reason', 'staff');
      end if;
      select lower(u.email), nullif(split_part(btrim(coalesce(u.full_name, '')), ' ', 1), '') into v_email, v_first from users u where u.id = p_user;
      select max(c.created_at) into v_last from game_claims c
       where c.user_id = p_user or c.email = v_email or c.renter_id = (select rr.id from renters rr where rr.user_id = p_user limit 1);
    end if;
  end if;
  -- 0172: the latest claim of this browser (or account): within the wait, no game; after it, a new one
  v_last := greatest(v_last, (select max(c.created_at) from game_claims c where c.visitor_id = v_vid));$o$,
  $n$  if v_ctx = 'booking' then
    if not ps.game_booking_offer then return jsonb_build_object('ok', false, 'reason', 'off'); end if;
    -- the request-to-book form applies a code to a booking: staff are turned away there
    if v_staff then return jsonb_build_object('ok', false, 'reason', 'staff'); end if;
  end if;
  -- 5040: a signed-in person plays on the site too (the site and the form alike): the account's name and email come with
  -- the play, and its claims (user, email, renter) set the wait after a claim
  if p_user is not null then
    select lower(u.email), nullif(split_part(btrim(coalesce(u.full_name, '')), ' ', 1), '') into v_email, v_first from users u where u.id = p_user;
    if not v_staff then
      select max(c.created_at) into v_last from game_claims c
       where c.user_id = p_user or c.email = v_email or c.renter_id = (select rr.id from renters rr where rr.user_id = p_user limit 1);
    end if;
  end if;
  -- 0172: the latest claim of this browser (or account): within the wait, no game; after it, a new one. Staff never claim:
  -- no wait for them, so they can always see the preview
  if not v_staff then
    v_last := greatest(v_last, (select max(c.created_at) from game_claims c where c.visitor_id = v_vid));
  end if;$n$);
-- the first-game rule for visitors known by email is for people who are not signed in (a signed-in renter is known by
-- definition); the booking request in progress still holds back a new game
select pg_temp.patch_fn('app.game_start_core(jsonb, uuid)'::regprocedure,
  $o$    if v_ctx = 'site' and app.game_known_visitor(v_vid) then
      return jsonb_build_object('ok', false, 'reason', 'known');$o$,
  $n$    if v_ctx = 'site' and p_user is null and app.game_known_visitor(v_vid) then
      return jsonb_build_object('ok', false, 'reason', 'known');$n$);
-- a replay prize's second game (0171) is checked against the account as before; Play again on a saved prize (0176) is
-- for visitors who are not signed in, as before

-- ================================================================ 3. the claim
-- Anyone signed in claims a play of the site or of the form with their account's email (one per person: the wait after a
-- claim counts the account, its email and its renter). Staff: nothing is created.
select pg_temp.patch_fn('app.server_game_claim_pre0171(jsonb, uuid)'::regprocedure,
  $o$  if g.id is null or g.context <> 'booking' then
    return jsonb_build_object('ok', false, 'error', 'signed_in', 'message', 'The game is for visitors who are not signed in.');
  end if;
  if app.user_is_staff(p_user) or exists (select 1 from user_roles ur where ur.user_id = p_user and ur.role::text in ('admin', 'va', 'field')) then
    return jsonb_build_object('ok', false, 'error', 'staff', 'message', 'The game is for renters.');
  end if;$o$,
  $n$  if g.id is null then
    return jsonb_build_object('ok', false, 'error', 'not_found', 'message', 'This game has ended. Reload the page.');
  end if;
  if app.game_is_staff(p_user) then
    return jsonb_build_object('ok', false, 'error', 'staff', 'message', 'Staff can''t use game codes: this is a preview of what visitors see.');
  end if;$n$);
create or replace function app.server_game_claim(p jsonb, p_user uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  -- 5040: staff get no code, whatever the play (checked first: before the replay and kept-prize words)
  if app.game_is_staff(p_user) then
    return jsonb_build_object('ok', false, 'error', 'staff', 'message', 'Staff can''t use game codes: this is a preview of what visitors see.');
  end if;
  if exists (select 1 from game_plays g where g.token = p ->> 'token' and app.game_prize_is_replay(g.prize)) then
    return jsonb_build_object('ok', false, 'error', 'replay', 'message', 'This prize is another go, not a code. Press Play again for your second game.');
  end if;
  -- 0176: after Play again the visitor keeps the better prize; the other play is closed
  if exists (select 1 from game_plays g where g.token = p ->> 'token' and g.dropped_at is not null) then
    return jsonb_build_object('ok', false, 'error', 'kept_other', 'message', 'You kept your other prize. Close this and open it from "Your prize is saved".');
  end if;
  return app.server_game_claim_pre0171(p, p_user);
end $$;

-- ================================================================ 4. privileges
revoke all on function app.game_is_staff(uuid) from public, anon, authenticated;
grant execute on function app.game_is_staff(uuid) to service_role;
revoke all on function app.server_game_claim(jsonb, uuid) from public, anon, authenticated;
grant execute on function app.server_game_claim(jsonb, uuid) to service_role;

-- ================================================================ 5. the guides
-- admin/discount-games-and-leads and va/discount-game-leads (docs/guides/content, generated by supabase/seed/5040_gen_guides.mjs)
-- GUIDES 5040 START (generated by supabase/seed/5040_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('admin', 'discount-games-and-leads', 'chapter', 'leads-and-sales-claims', 'Visitors who are not signed in get one quick game: spin the wheel, scratch to reveal, quick blackjack, cup shuffle, Plinko, the card pack, coin flip, dice roll, slot machine, prize drop or mystery box. Every play wins a promo code or another go. To see the code they give a first name and an email (a mobile number is optional), so you get a lead. It is on by default; nothing needs setting up.

## What the visitor sees

- On the 2nd page view (any page) or after 30 seconds on the site, whichever first, or (on a computer) when the mouse heads for the tabs. A card slides in at the bottom; on a phone it is a sheet at the bottom, never a full-screen block, and it always closes.
- Never for someone signed in, never on booking, pay, sign or sign-in pages, never on the first page of a visit from a search engine on a phone, never over the cookie banner; no new game for someone already known by email or with a booking request in progress. Once a visit by default, and again on every new visit (a visit ends after 30 minutes away), also when they closed it without playing. Settings > Discount games has Preview the game, to see it any time, signed in or not.
- After claiming a code: no game for the rest of that visit. A day after their latest claim the game comes back on their next visit with the usual timings, a new game and a new draw, and they can win another code. The day counts for the browser, the email, the mobile number and (in the request-to-book form) the account; within it the game says when they can play again. A visitor known only through their own claim still gets it; one known through a booking request, the chat, a sign-in or as a renter does not.
- Won and not claimed: a small badge "Your 5% off is saved" with **Get my code** and **Play again** stays on the pages. On a later visit, at the moment a first game would show, the prize pops up by itself once as a small slide-in at the bottom ("Your 5% off is still waiting", the same two buttons), never as a card over the page; closed, it does not come back in that visit. Until they claim it or the prize ends after 14 days.
- **Play again** on a prize not claimed: a new, different game with a new draw. They keep the better of the two prizes and the other is closed, so there is only ever one code to claim: the card says "You won 15% off" or "You keep your 5% off". Once a visit and once a day (a setting).
- Every play wins: 5% off (54 in 100), 10% off (25), another go (15), 15% off (4), $50 off a rental of 3 days or more (1), 25% off up to $150 (0.6), $100 off a rental of 4 days or more (0.3) or one free day on a rental of 3 days or more (0.1). The prize is decided before the game starts; the game only shows it. The short terms with the game list the prizes and say the chances differ.
- Another go: the card says "You won another go!" and **Play again** starts a second, different game whose prize is drawn from the discounts only, so it always ends in a code. One replay at a time; it is never a code itself. Closed before pressing it, the card offers it again next time.
- The code (for example WIN-7KQ4-XM2P) comes off the rental charge only, up to $75 for a percentage, on one booking, within 7 days, one code a day per person, email, phone and device, never with another code. An earlier code not used yet stays good until it ends. The email with the code goes either way; a reminder goes 3 days before its last day and another the day before (Promo codes). Offers only with the marketing box ticked.
- On this device the code fills itself into the promo code box of the request form. Like every promo code, the discount is shared with the owner in the split.

## Leads

**People** > **Renters**, the **Leads** tab.

1. The tiles: plays, claims, codes on booking requests, bookings, revenue and discounts from game codes in the last 30 days, then the same by game and by prize (Play again shows its plays; it has no claims).
2. Each claim: when, the name (and "on the site now"), email and phone, the prize and game, the code and whether it is used (with the booking), marketing consent, and the visit: cars and pages viewed, minutes, city and device. A person who won again shows "2nd code of 2" under the name on each of their lines.
3. Press **Call** or **Email**, then **Contacted** (it is yours). **Close** with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.
4. A visitor who viewed 3 cars or more also gets a Sales task, for example "Claimed 10% off, viewed 6 cars: Maya". It closes when the code goes on a request. A new code while that task is open is added to it, not a second task.

## Contact details typed into forms

**People** > **Renters**, the **Leads** tab, the card "Typed into forms" at the top.

1. When someone types a name, email or phone into the request to book, the contact form, List your car, the owner application, Create an account, the discount game or the chat, it is saved as soon as each field is valid, even if they never press Send.
2. Each line: when, the name (and "On the site now"), email and phone, the form, and Sent or Not sent. "Email not confirmed" means the account was opened from the form and the person has not opened the link we emailed them yet.
3. After 30 minutes without sending, Sales'' queue gets "Unfinished request from Maya Chen: follow up" (not raised from 23:00 to 07:00, the quiet hours of the site alerts); To do shows it on the Sales line of Your teams. Call or email them; the task closes by itself when they send the form, or after 7 days (Program settings, Forms: close a Sales follow-up nobody answered after). The person stays on this list.
4. Only what they typed is saved, and never used for offers without their consent.

> Good to know: A new email gets an account at once (no password, email not confirmed) and one email "Continue your request" 30 minutes later, between 9:00 and 21:00. Until they open its link they cannot accept an offer, sign, pay or upload documents. An account never confirmed closes after 30 days; the lead stays. It is on by default; the times and the To do are in **Settings** > **Program**, the card "Forms left unfinished".

## Settings

**Settings** > **Discount games**.

- On or off, the cap for percentage codes ($75), how long a code is good for (7 days), when it shows (2nd page view, 30 seconds, exit intent), the days a visitor keeps their prize (14: closing never draws a new one, and a prize not claimed pops up again until then), the days after a claim before the game comes back (1; 0 is one code per person ever), how often Play again works on a prize not claimed (once a day; 0 turns it off), and the cars viewed for a Sales task (3). The reminders before a code ends are under Promo codes.
- At most one game a visit by default (a setting), and a visit ends after 30 minutes away (a setting): the next page brings the game again. With more than one a visit, the next card shows on their 3rd page view after a close (any page) or 2 minutes later, whichever first; no daily cap unless you set one. A prize waiting for them pops up once a visit only. All are settings. Never on booking, payment or signing pages; the request-to-book form has its own game.
- Prizes and games: each prize with its percent, dollars or free days, a minimum rental length, its cap and its chance, or Play again (another go, at most one); each game''s weight (0 turns it off). Press **Save prizes and games**. Codes already sent keep their value.
', 'Discount games and leads', 'The giveaway game, the code it sends, game leads to call, and the report.',
  'Everyone gets one quick game, signed in or not: spin the wheel, scratch to reveal, quick blackjack, cup shuffle, Plinko, the card pack, coin flip, dice roll, slot machine, prize drop or mystery box. Every play wins a promo code or another go. To see the code they give a first name and an email (a mobile number is optional), so you get a lead. A signed-in renter has their name and email filled in from their account: one tap on **Get my code**, and the code is tied to their account (Rewards, Your discounts) and applies at checkout. It is on by default; nothing needs setting up.

## What the visitor sees

- On the 2nd page view (any page) or after 30 seconds on the site, whichever first, or (on a computer) when the mouse heads for the tabs. A card slides in at the bottom; on a phone it is a sheet at the bottom, never a full-screen block, and it always closes.
- Never inside a portal (account, admin, staff, owner, investor, field) or on booking, checkout, pay, sign or sign-in pages, never on the first page of a visit from a search engine on a phone, never over the cookie banner; no new game for someone already known by email or with a booking request in progress. Once a visit by default, and again on every new visit (a visit ends after 30 minutes away), also when they closed it without playing. Settings > Discount games has Preview the game, to see it any time, signed in or not. Staff and admin see and play the game on the site too, as a preview of what visitors see: their claim says "Staff can''t use game codes: this is a preview of what visitors see." and no code is made.
- After claiming a code: no game for the rest of that visit. A day after their latest claim the game comes back on their next visit with the usual timings, a new game and a new draw, and they can win another code. The day counts for the browser, the email, the mobile number and the account; within it the game says when they can play again. A visitor known only through their own claim still gets it; one known through a booking request or the chat, not signed in, does not.
- Won and not claimed: a small badge "Your 5% off is saved" with **Get my code** and **Play again** stays on the pages. On a later visit, at the moment a first game would show, the prize pops up by itself once as a small slide-in at the bottom ("Your 5% off is still waiting", the same two buttons), never as a card over the page; closed, it does not come back in that visit. Until they claim it or the prize ends after 14 days.
- **Play again** on a prize not claimed: a new, different game with a new draw. They keep the better of the two prizes and the other is closed, so there is only ever one code to claim: the card says "You won 15% off" or "You keep your 5% off". Once a visit and once a day (a setting).
- Every play wins: 5% off (54 in 100), 10% off (25), another go (15), 15% off (4), $50 off a rental of 3 days or more (1), 25% off up to $150 (0.6), $100 off a rental of 4 days or more (0.3) or one free day on a rental of 3 days or more (0.1). The prize is decided before the game starts; the game only shows it. The short terms with the game list the prizes and say the chances differ.
- Another go: the card says "You won another go!" and **Play again** starts a second, different game whose prize is drawn from the discounts only, so it always ends in a code. One replay at a time; it is never a code itself. Closed before pressing it, the card offers it again next time.
- The code (for example WIN-7KQ4-XM2P) comes off the rental charge only, up to $75 for a percentage, on one booking, within 7 days, one code a day per person, email, phone and device, never with another code. An earlier code not used yet stays good until it ends. The email with the code goes either way; a reminder goes 3 days before its last day and another the day before (Promo codes). Offers only with the marketing box ticked.
- On this device the code fills itself into the promo code box of the request form. Like every promo code, the discount is shared with the owner in the split.

## Leads

**People** > **Renters**, the **Leads** tab.

1. The tiles: plays, claims, codes on booking requests, bookings, revenue and discounts from game codes in the last 30 days, then the same by game and by prize (Play again shows its plays; it has no claims).
2. Each claim: when, the name (and "on the site now"), email and phone, the prize and game, the code and whether it is used (with the booking), marketing consent, and the visit: cars and pages viewed, minutes, city and device. A person who won again shows "2nd code of 2" under the name on each of their lines.
3. Press **Call** or **Email**, then **Contacted** (it is yours). **Close** with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.
4. A visitor who viewed 3 cars or more also gets a Sales task, for example "Claimed 10% off, viewed 6 cars: Maya". It closes when the code goes on a request. A new code while that task is open is added to it, not a second task.

## Contact details typed into forms

**People** > **Renters**, the **Leads** tab, the card "Typed into forms" at the top.

1. When someone types a name, email or phone into the request to book, the contact form, List your car, the owner application, Create an account, the discount game or the chat, it is saved as soon as each field is valid, even if they never press Send.
2. Each line: when, the name (and "On the site now"), email and phone, the form, and Sent or Not sent. "Email not confirmed" means the account was opened from the form and the person has not opened the link we emailed them yet.
3. After 30 minutes without sending, Sales'' queue gets "Unfinished request from Maya Chen: follow up" (not raised from 23:00 to 07:00, the quiet hours of the site alerts); To do shows it on the Sales line of Your teams. Call or email them; the task closes by itself when they send the form, or after 7 days (Program settings, Forms: close a Sales follow-up nobody answered after). The person stays on this list.
4. Only what they typed is saved, and never used for offers without their consent.

> Good to know: A new email gets an account at once (no password, email not confirmed) and one email "Continue your request" 30 minutes later, between 9:00 and 21:00. Until they open its link they cannot accept an offer, sign, pay or upload documents. An account never confirmed closes after 30 days; the lead stays. It is on by default; the times and the To do are in **Settings** > **Program**, the card "Forms left unfinished".

## Settings

**Settings** > **Discount games**.

- On or off, the cap for percentage codes ($75), how long a code is good for (7 days), when it shows (2nd page view, 30 seconds, exit intent), the days a visitor keeps their prize (14: closing never draws a new one, and a prize not claimed pops up again until then), the days after a claim before the game comes back (1; 0 is one code per person ever), how often Play again works on a prize not claimed (once a day; 0 turns it off), and the cars viewed for a Sales task (3). The reminders before a code ends are under Promo codes.
- At most one game a visit by default (a setting), and a visit ends after 30 minutes away (a setting): the next page brings the game again. With more than one a visit, the next card shows on their 3rd page view after a close (any page) or 2 minutes later, whichever first; no daily cap unless you set one. A prize waiting for them pops up once a visit only. All are settings. Never in the portals or on booking, checkout, payment or signing pages; the request-to-book form has its own game.
- Prizes and games: each prize with its percent, dollars or free days, a minimum rental length, its cap and its chance, or Play again (another go, at most one); each game''s weight (0 turns it off). Press **Save prizes and games**. Codes already sent keep their value.
',
  '<p class="gd-p">Everyone gets one quick game, signed in or not: spin the wheel, scratch to reveal, quick blackjack, cup shuffle, Plinko, the card pack, coin flip, dice roll, slot machine, prize drop or mystery box. Every play wins a promo code or another go. To see the code they give a first name and an email (a mobile number is optional), so you get a lead. A signed-in renter has their name and email filled in from their account: one tap on <b class="gd-ui">Get my code</b>, and the code is tied to their account (Rewards, Your discounts) and applies at checkout. It is on by default; nothing needs setting up.</p><section class="gd-task" id="discount-games-and-leads-what-the-visitor-sees" data-gd-task><h2 class="gd-h2">What the visitor sees</h2><ul class="gd-ul"><li>On the 2nd page view (any page) or after 30 seconds on the site, whichever first, or (on a computer) when the mouse heads for the tabs. A card slides in at the bottom; on a phone it is a sheet at the bottom, never a full-screen block, and it always closes.</li><li>Never inside a portal (account, admin, staff, owner, investor, field) or on booking, checkout, pay, sign or sign-in pages, never on the first page of a visit from a search engine on a phone, never over the cookie banner; no new game for someone already known by email or with a booking request in progress. Once a visit by default, and again on every new visit (a visit ends after 30 minutes away), also when they closed it without playing. Settings &gt; Discount games has Preview the game, to see it any time, signed in or not. Staff and admin see and play the game on the site too, as a preview of what visitors see: their claim says &quot;Staff can&#39;t use game codes: this is a preview of what visitors see.&quot; and no code is made.</li><li>After claiming a code: no game for the rest of that visit. A day after their latest claim the game comes back on their next visit with the usual timings, a new game and a new draw, and they can win another code. The day counts for the browser, the email, the mobile number and the account; within it the game says when they can play again. A visitor known only through their own claim still gets it; one known through a booking request or the chat, not signed in, does not.</li><li>Won and not claimed: a small badge &quot;Your 5% off is saved&quot; with <b class="gd-ui">Get my code</b> and <b class="gd-ui">Play again</b> stays on the pages. On a later visit, at the moment a first game would show, the prize pops up by itself once as a small slide-in at the bottom (&quot;Your 5% off is still waiting&quot;, the same two buttons), never as a card over the page; closed, it does not come back in that visit. Until they claim it or the prize ends after 14 days.</li><li><b class="gd-ui">Play again</b> on a prize not claimed: a new, different game with a new draw. They keep the better of the two prizes and the other is closed, so there is only ever one code to claim: the card says &quot;You won 15% off&quot; or &quot;You keep your 5% off&quot;. Once a visit and once a day (a setting).</li><li>Every play wins: 5% off (54 in 100), 10% off (25), another go (15), 15% off (4), $50 off a rental of 3 days or more (1), 25% off up to $150 (0.6), $100 off a rental of 4 days or more (0.3) or one free day on a rental of 3 days or more (0.1). The prize is decided before the game starts; the game only shows it. The short terms with the game list the prizes and say the chances differ.</li><li>Another go: the card says &quot;You won another go!&quot; and <b class="gd-ui">Play again</b> starts a second, different game whose prize is drawn from the discounts only, so it always ends in a code. One replay at a time; it is never a code itself. Closed before pressing it, the card offers it again next time.</li><li>The code (for example WIN-7KQ4-XM2P) comes off the rental charge only, up to $75 for a percentage, on one booking, within 7 days, one code a day per person, email, phone and device, never with another code. An earlier code not used yet stays good until it ends. The email with the code goes either way; a reminder goes 3 days before its last day and another the day before (Promo codes). Offers only with the marketing box ticked.</li><li>On this device the code fills itself into the promo code box of the request form. Like every promo code, the discount is shared with the owner in the split.</li></ul></section><section class="gd-task" id="discount-games-and-leads-leads" data-gd-task><h2 class="gd-h2">Leads</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Renters</b>, the <b class="gd-ui">Leads</b> tab.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The tiles: plays, claims, codes on booking requests, bookings, revenue and discounts from game codes in the last 30 days, then the same by game and by prize (Play again shows its plays; it has no claims).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each claim: when, the name (and &quot;on the site now&quot;), email and phone, the prize and game, the code and whether it is used (with the booking), marketing consent, and the visit: cars and pages viewed, minutes, city and device. A person who won again shows &quot;2nd code of 2&quot; under the name on each of their lines.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Call</b> or <b class="gd-ui">Email</b>, then <b class="gd-ui">Contacted</b> (it is yours). <b class="gd-ui">Close</b> with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A visitor who viewed 3 cars or more also gets a Sales task, for example &quot;Claimed 10% off, viewed 6 cars: Maya&quot;. It closes when the code goes on a request. A new code while that task is open is added to it, not a second task.</div></li></ol></div></section><section class="gd-task" id="discount-games-and-leads-contact-details-typed-into-forms" data-gd-task><h2 class="gd-h2">Contact details typed into forms</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Renters</b>, the <b class="gd-ui">Leads</b> tab, the card &quot;Typed into forms&quot; at the top.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When someone types a name, email or phone into the request to book, the contact form, List your car, the owner application, Create an account, the discount game or the chat, it is saved as soon as each field is valid, even if they never press Send.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each line: when, the name (and &quot;On the site now&quot;), email and phone, the form, and Sent or Not sent. &quot;Email not confirmed&quot; means the account was opened from the form and the person has not opened the link we emailed them yet.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">After 30 minutes without sending, Sales&#39; queue gets &quot;Unfinished request from Maya Chen: follow up&quot; (not raised from 23:00 to 07:00, the quiet hours of the site alerts); To do shows it on the Sales line of Your teams. Call or email them; the task closes by itself when they send the form, or after 7 days (Program settings, Forms: close a Sales follow-up nobody answered after). The person stays on this list.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Only what they typed is saved, and never used for offers without their consent.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A new email gets an account at once (no password, email not confirmed) and one email &quot;Continue your request&quot; 30 minutes later, between 9:00 and 21:00. Until they open its link they cannot accept an offer, sign, pay or upload documents. An account never confirmed closes after 30 days; the lead stays. It is on by default; the times and the To do are in <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>, the card &quot;Forms left unfinished&quot;.</div></aside></section><section class="gd-task" id="discount-games-and-leads-settings" data-gd-task><h2 class="gd-h2">Settings</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Discount games</b>.</p><ul class="gd-ul"><li>On or off, the cap for percentage codes ($75), how long a code is good for (7 days), when it shows (2nd page view, 30 seconds, exit intent), the days a visitor keeps their prize (14: closing never draws a new one, and a prize not claimed pops up again until then), the days after a claim before the game comes back (1; 0 is one code per person ever), how often Play again works on a prize not claimed (once a day; 0 turns it off), and the cars viewed for a Sales task (3). The reminders before a code ends are under Promo codes.</li><li>At most one game a visit by default (a setting), and a visit ends after 30 minutes away (a setting): the next page brings the game again. With more than one a visit, the next card shows on their 3rd page view after a close (any page) or 2 minutes later, whichever first; no daily cap unless you set one. A prize waiting for them pops up once a visit only. All are settings. Never in the portals or on booking, checkout, payment or signing pages; the request-to-book form has its own game.</li><li>Prizes and games: each prize with its percent, dollars or free days, a minimum rental length, its cap and its chance, or Play again (another go, at most one); each game&#39;s weight (0 turns it off). Press <b class="gd-ui">Save prizes and games</b>. Codes already sent keep their value.</li></ul></section>');
select app.guide_release_section('va', 'discount-game-leads', 'chapter', 'texts-and-calls', 'Visitors who are not signed in play a quick game on the site and win a promo code. To get it they give a first name, an email and sometimes a mobile number. Customer service and Sales follow them up.

## Game leads

**More customer service** > **Renters**, the **Leads** tab (Sales: **More sales**).

1. Each claim: when, the name (and "on the site now"), email and phone, the prize, the code and whether it is used, marketing consent, and the cars and pages they viewed.
2. Press **Call** or **Email**. Help them pick a car and send a request; the code goes in the promo code box (on their own device it is filled in). Then press **Contacted**.
3. **Close** with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.

A visitor who viewed 3 cars or more also raises a Sales task, for example "Claimed 10% off, viewed 6 cars: Maya". It closes when the code goes on a request. A visitor who wins another go plays a second game first; only the code they end with shows here.

People can win again: a day after their last code the game comes back on their next visit, and a new code is a new line with "2nd code of 2" under the name. It is the same person: one call covers both codes, and while their Sales task is open the new code is added to it instead of a second task. Each code is for one booking and never combined with another; an earlier code they have not used stays good until it ends.

> Tip: Without marketing consent, talk only about their request and the code they asked for: no other offers. The code takes up to $75 off the rental charge (a percentage), or $50 off a rental of 3 days or more, on one booking within 7 days.

## Contact details typed into forms

The card "Typed into forms" above the game leads lists the name, email and phone people typed into a form on the site without sending it, with "On the site now" and "Email not confirmed". Call or email to help them finish. Only what they typed; no offers without their consent.
', 'Discount game leads', 'Game leads to call or email, the code they won, whether it is used, and the Sales task.',
  'Everyone who visits the site, signed in or not, plays a quick game and wins a promo code. Staff see it as a preview and never get a code. To get it they give a first name, an email and sometimes a mobile number. Customer service and Sales follow them up.

## Game leads

**More customer service** > **Renters**, the **Leads** tab (Sales: **More sales**).

1. Each claim: when, the name (and "on the site now"), email and phone, the prize, the code and whether it is used, marketing consent, and the cars and pages they viewed.
2. Press **Call** or **Email**. Help them pick a car and send a request; the code goes in the promo code box (on their own device it is filled in). Then press **Contacted**.
3. **Close** with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.

A visitor who viewed 3 cars or more also raises a Sales task, for example "Claimed 10% off, viewed 6 cars: Maya". It closes when the code goes on a request. A visitor who wins another go plays a second game first; only the code they end with shows here.

People can win again: a day after their last code the game comes back on their next visit, and a new code is a new line with "2nd code of 2" under the name. It is the same person: one call covers both codes, and while their Sales task is open the new code is added to it instead of a second task. Each code is for one booking and never combined with another; an earlier code they have not used stays good until it ends.

> Tip: Without marketing consent, talk only about their request and the code they asked for: no other offers. The code takes up to $75 off the rental charge (a percentage), or $50 off a rental of 3 days or more, on one booking within 7 days.

## Contact details typed into forms

The card "Typed into forms" above the game leads lists the name, email and phone people typed into a form on the site without sending it, with "On the site now" and "Email not confirmed". Call or email to help them finish. Only what they typed; no offers without their consent.
',
  '<p class="gd-p">Everyone who visits the site, signed in or not, plays a quick game and wins a promo code. Staff see it as a preview and never get a code. To get it they give a first name, an email and sometimes a mobile number. Customer service and Sales follow them up.</p><section class="gd-task" id="discount-game-leads-game-leads" data-gd-task><h2 class="gd-h2">Game leads</h2><p class="gd-p"><b class="gd-ui">More customer service</b> &gt; <b class="gd-ui">Renters</b>, the <b class="gd-ui">Leads</b> tab (Sales: <b class="gd-ui">More sales</b>).</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each claim: when, the name (and &quot;on the site now&quot;), email and phone, the prize, the code and whether it is used, marketing consent, and the cars and pages they viewed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Call</b> or <b class="gd-ui">Email</b>. Help them pick a car and send a request; the code goes in the promo code box (on their own device it is filled in). Then press <b class="gd-ui">Contacted</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Close</b> with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.</div></li></ol></div><p class="gd-p">A visitor who viewed 3 cars or more also raises a Sales task, for example &quot;Claimed 10% off, viewed 6 cars: Maya&quot;. It closes when the code goes on a request. A visitor who wins another go plays a second game first; only the code they end with shows here.</p><p class="gd-p">People can win again: a day after their last code the game comes back on their next visit, and a new code is a new line with &quot;2nd code of 2&quot; under the name. It is the same person: one call covers both codes, and while their Sales task is open the new code is added to it instead of a second task. Each code is for one booking and never combined with another; an earlier code they have not used stays good until it ends.</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Without marketing consent, talk only about their request and the code they asked for: no other offers. The code takes up to $75 off the rental charge (a percentage), or $50 off a rental of 3 days or more, on one booking within 7 days.</div></aside></section><section class="gd-task" id="discount-game-leads-contact-details-typed-into-forms" data-gd-task><h2 class="gd-h2">Contact details typed into forms</h2><p class="gd-p">The card &quot;Typed into forms&quot; above the game leads lists the name, email and phone people typed into a form on the site without sending it, with &quot;On the site now&quot; and &quot;Email not confirmed&quot;. Call or email to help them finish. Only what they typed; no offers without their consent.</p></section>');
-- GUIDES 5040 END
