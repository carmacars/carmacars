# Discount games: sooner, again with a new game, and in the booking form (October 21, 2026)

Migration `0076_games_timing_booking.sql`; tests `supabase/tests/51_games_timing_booking.sql` (and the settings lines
of `48_discount_games.sql`); unit tests `web/src/features/games/rules.test.ts`; end to end
`web/tests/e2e/discount-games.spec.ts` (phone 375 and desktop 1440). No applied migration was edited.

The owner's requests about the discount games of 0069:

1. "The discount popups aren't showing up fast enough."
2. "When they get closed out, they should show up again later on but with a different popup that hasn't showed up yet."
3. "Also they should show up when making a booking."

Unchanged on purpose: the prize table and its odds (5% off 70, 10% off 25, 15% off 4, $50 off a rental of 3 days or
more 1), the $75 cap per percentage code, single-use codes good for 7 days, one claim per person, email, phone and
device, never with another code, the rate limits, and every rule of 0069 about who may never see a game on the site.

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
  migration's guides block, `supabase/seed/0076_gen_guides.mjs`).
- Privacy policy (live copy only where it still has the words of 0069, and `docs/source/website_terms_policies.md`):
  the games are shown to visitors of the Site and offered in the booking request form, and the browser remembers which
  games were seen. Last updated October 21, 2026.

## 6. Tests

- `51_games_timing_booking.sql`: the new settings and defaults, the checks on them, the odds and cap unchanged; five
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
  the site and is offered it in the booking form; the earlier tests of 0069.
