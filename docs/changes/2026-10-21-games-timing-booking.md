# Discount games: sooner, again with a new game, and in the booking form (October 21, 2026)

Migration `0081_games_timing_booking.sql`; tests `supabase/tests/53_games_timing_booking.sql` (and the settings lines
of `48_discount_games.sql`); unit tests `web/src/features/games/rules.test.ts`; end to end
`web/tests/e2e/discount-games.spec.ts` (phone 375 and desktop 1440). No applied migration was edited.

The owner's requests about the discount games of 0069:

1. "The discount popups aren't showing up fast enough."
2. "When they get closed out, they should show up again later on but with a different popup that hasn't showed up yet."
3. "Also they should show up when making a booking."
4. Later the same day: a sixth game, a card pack rip, and bigger prizes with low odds (sections 6 and 7).

Unchanged on purpose: the draw in the database before the game starts, the $75 cap for a percentage prize without a
cap of its own, single-use codes good for 7 days, one claim per person, email, phone and device, never with another
code, the rate limits, and every rule of 0069 about who may never see a game on the site.

## 1. Sooner

| Rule | Before | Now |
| --- | --- | --- |
| First game of a visit | 2 car pages or 60 seconds | 1 car page or 15 seconds, whichever comes first (`game_trigger_car_pages` 1, `game_trigger_seconds` 15) |
| Exit intent | Computers only | Kept, for the first game of a visit |
| Phone visit from a search engine | Never on the first page | Never as a card on the first page: it waits for the second page, or comes 15 seconds after its rule as a small bar at the bottom (one line, Play and close, clear of the chat button) that opens the game when tapped. Google's rule against intrusive interstitials on a search landing page is kept |
| Never | Signed in, known by email, booking, pay, sign, sign-in and portal pages, over the cookie banner, automated browsers | The same on the site |

The live settings move to 1 and 15 only where they still hold 2 and 60 (each value on its own); a value an Admin changed
stays. The new column defaults are 1 and 15.

## 2. Again after a close, with a game not seen yet

| Rule | Default |
| --- | --- |
| After a close, the next game | After 2 more car pages or 180 seconds since the close, whichever comes first (`game_reshow_car_pages`, `game_reshow_seconds`) |
| Most in one visit | 3 (`game_max_per_visit`); a later visit starts again |
| Which game | One this visitor has not seen: all five before one repeats, never the same twice in a row, by the games' weights (a game at 0 is off and not waited for) |
| After a claim | Never again (this browser, and the database refuses another play or claim) |
| The 14-day wait after closing | Gone. `game_dismiss_days` (14) now says how long a visitor keeps the prize drawn for them |

The prize is drawn once per visitor (and per signed-in account) and kept for `game_dismiss_days`: closing a game and
seeing another one never draws again, so nobody can close games until a bigger prize comes up, and the odds are those
of the prize table. Each show is its own play (`game_plays`), so the report counts every show.

Which games were seen is kept in two places: the browser (`localStorage` `cc_game.seen`, read and written inside
try/catch as before; the visit's shows and the time of the last close are in `sessionStorage`) and the database
(`game_plays` of the visitor id, and of the account in the booking form). `app.game_next_kind` joins both: a browser that
lost its list still gets a game its plays have not shown. Reloading a page before a game was shown returns the same
play (no new play by reloading).

## 3. In the request-to-book form

| Point | How |
| --- | --- |
| Where | `/book` and `/book/<car>`, on the add-ons step and the review step (before the price is confirmed in the offer and long before paying). Never on the sent page, pay or sign pages, the renter portal, or the staff screens for rentals added by hand (they do not use this form) |
| Who | Anyone who has not claimed a prize: visitors, visitors known by email, and signed-in renters (the one place they see a game). Never staff (Admin, assistants, field staff): the database says so. `game_booking_offer` turns it off |
| The card | "Play for a discount on this booking" with Play and No thanks, inside the step. The offer is decided in idle time when the form opens and drawn only with a step that starts after that, so nothing on the page moves |
| The game | The same card as on the site, over the page, with the fields filled from the form (a signed-in renter's code goes to the account's email; one press: Apply my discount) |
| The code | Goes in the promo code box at once; the quote applies it with its own rules (the $50 prize only on 3 days or more, $75 at most for a percentage) and the price beside the form changes. The card then says "Your game code WIN-... is on this booking" and what the quote says (applied with the amount, or why not; the code stays good until it expires) |
| Closing | Close, Esc or No thanks: the card goes away for this booking and the booking goes on exactly as before |
| One per person | A signed-in renter claims only a play of the booking form, with the account's email; never a second code for the account, its email or its renter. A visitor claims as on the site (one per email, phone and device) |

The booking form's play goes through `/api/games` (`{ action: 'start', p }`, the server passes who is signed in) to
`public.server_game_start`, which only the server may call. `public.game_start` (the browser's, for the site) ignores
any context it is sent and keeps the site's rules.

## 4. Fast to open

- The watcher still loads after the page is idle (with the beacon and the chat). Once the settings say this visitor can
  get a game, the card and the five games' code are fetched in idle time, so a game opens after one database call.
- The card is fixed in place (no layout shift on the page); the booking card is drawn with its step.
- Reduced motion: unchanged for the games (no spin, shuffle or bounce); the card and the small bar do not slide in.

## 5. Settings, guides, privacy

- Admin > Settings > Discount games: the new fields (next game after more car pages, after seconds since the close, most
  games in one visit, the booking form's offer) with labels and hints; "a visitor keeps the same prize for (days)".
- Admin guide, Discount games and leads; VA guide, Game leads: the new rules (`docs/guides/content`, published by the
  migration's guides block, `supabase/seed/0081_gen_guides.mjs`).
- Privacy policy (live copy only where it still has the words of 0069, and `docs/source/website_terms_policies.md`):
  the games are shown to visitors of the Site and offered in the booking request form, and the browser remembers which
  games were seen. Last updated October 21, 2026.

## 6. The card pack, a sixth game

A sealed CarmaCars foil pack (red, black and white, the CarmaCars wordmark; no real trading card design or brand).
The visitor tears the strip along the top: drag across it (mouse or touch), tap it (each tap tears a third) or press
**Tear it open** (keyboard). Five cards fan out and turn one by one: four CarmaCars picture cards ("City run",
"Road trip") and, last, the prize the database drew. A rare prize turns as a holographic card. With reduced motion the
pack opens and every card shows at once. It is its own small file, fetched in idle time with the others; the stage
keeps its height, so nothing moves. It is in the round of games (one not seen yet first) and in Settings > Discount
games with a weight of 1 (the live weights gain `"pack": 1` where they were still the defaults of 0069).

## 7. Bigger prizes with low odds

| Prize | Chance (in 100) | Minimum rental | Cap |
| --- | --- | --- | --- |
| 5% off | 69 (was 70) | | $75 (the games' cap) |
| 10% off | 25 | | $75 |
| 15% off | 4 | | $75 |
| $50 off | 1 | 3 days | its amount |
| 25% off | 0.6 | | $150 (its own) |
| $100 off | 0.3 | 4 days | its amount |
| One free day | 0.1 | 3 days | $150 (its own) |

- The prize table (Program settings, `game_prizes`) takes per prize `min_days` and `max_cents` (its own cap) and a
  third kind, `free_days` (1 to 7, with a minimum longer than the free days). The database checks the table
  (`app.game_prizes_ok`). The live table moves to this one only where it is still the table of 0069.
- The code carries the prize: `promo_codes.free_days` (new; a code is exactly one of a percentage, an amount or free
  days), `min_rental_days` and `max_discount_cents`. `app.promo_discount_cents(code, base, days)` applies them every
  time the database prices a booking (the quote and the booking's lines, an extension, a calendar change, which now
  pass the booking's length): nothing on a shorter booking than the minimum, never above the cap or the charge. A free
  day is the booking's average day of the net rental charge.
- Rare prizes (a chance of 1 in 100 or less: $50, 25%, $100, the free day) get confetti over the card (not with
  reduced motion), a holographic prize line and "A rare prize", in every game; the card pack turns a holographic card.
- The short terms list every prize and keep "The chances differ", with the caps: "Prizes: 5%, 10%, 15% or 25% off, or
  $50 off 3+ day rentals, or $100 off 4+ day rentals, or 1 free day on 3+ day rentals. The chances differ: most
  players win 5% off. Off the rental charge only, up to $75 per code (25% off: up to $150, 1 free day: up to $150)."
  The terms of use (section 14) and the privacy policy do not list prizes or odds, so they are unchanged by this.
- The code email and its reminder name the prize and what it applies to from the code itself (free days included).
- Admin > Settings > Discount games: each prize with its kind (percent, dollars, free days), minimum days, cap and
  chance, what it takes off the average booking, and **Expected cost per claimed code** under the table, worked out
  live as the table is edited. The average booking is the net rental charge and length of the confirmed bookings of
  the last 180 days (with fewer than 5, the cars' average daily rate for 4 days), from the games' report.

## 8. Tests

- `53_games_timing_booking.sql`: the new settings and defaults, the checks on them, the odds and cap unchanged; five
  shows give five games, the sixth is not the fifth, one prize for all; the server's memory; a game at weight 0 never
  chosen; claiming a re-shown play; the booking form: signed in may play, the site refuses them, the browser cannot ask
  for the booking rules, a dry check records nothing, the play recorded with its context and account, the same prize
  on another browser, a known visitor may, never staff, the offer turned off; the signed-in claim with the account's
  email, the code's rules, one per person, staff refused; privileges; the privacy text.
- `rules.test.ts`: the first game (1 car page, 15 seconds, exit intent on computers only, the timer), the phone search
  landing (nothing at first, the small bar 15 seconds after its rule, the card on the second page), the re-show (not
  while one is open, 2 more car pages, 3 minutes, exit intent only for the first, 3 a visit, a new visit), the round of
  five, the booking form's eligibility (signed in and known allowed there, claimed and staff not, the offer off, a code
  already on, only the form's paths).
- `discount-games.spec.ts`: the five games after one car page; the first game after 15 seconds without a car page; the
  phone search landing's small bar; closed, a different game after 2 more car pages with the same prize, a third, then
  none; the booking card plays, the code goes on the booking and the price changes, and the request is sent with the
  $50 off; closing the game leaves the booking as it was (no code, the same price); a signed-in renter sees no game on
  the site and is offered it in the booking form; the card pack (dragged on a computer, tapped on a phone) among the
  games; a rare prize (the free day in the pack: holographic card, confetti, the code with its minimum and cap); Admin
  shows seven prizes, the pack's weight and the expected cost; the earlier tests of 0069.
- 0081, later the same day: in `53_games_timing_booking.sql` six games in six shows, the chances adding up to 100,
  20,000 draws within about four standard deviations of every prize's chance, the table's checks, the words, caps and
  minimum days through `app.promo_discount_cents`, one kind per code, every pricing function passing the length, a
  rare prize claimed (the code and its email), the report's average booking; in `48_discount_games.sql` the new table,
  weights, draw boundaries and terms; in `rules.test.ts` the wheel and Plinko with seven prizes, caps, minimum days and
  the expected cost, the pack's cards and tearing.
