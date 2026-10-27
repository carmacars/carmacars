# The saved prize pops up once a visit, small, with Play again (0176)

The owner, on the live site: "Why is the CarmaCars giveaway popup full screen showing your '5% off is still waiting'
every single time you open a car page rather than letting you play again like what we agreed on." What was agreed: the
game pops up again and people can play again.

## Why it happened
- **Every car page.** 0171 treated a prize won and not claimed like a new game: its card came back on the re-show rules
  after every close (the 3rd page view or 2 minutes later), up to 4 times a visit, and on the first-show rules on every
  new visit (every new tab: the 2nd page view or 30 seconds). Browsing cars, that is every few car pages, and on any car
  page left open for 2 minutes.
- **Full screen.** The card that came back was the full card with the claim form (first name, email, mobile, consent):
  on a phone the bottom sheet is up to 85% of the screen high, so it covered the page.
- **No play again.** It only ever showed the same saved prize; there was no way to play another game.

## The rules now
- A visitor with a prize won and not claimed sees it pop up by itself **once a visit**, at the moment a first game
  would show (the 2nd page view or 30 seconds), never in the visit it was won in, never again in that visit once closed
  (the re-show rules and the cap of 4 do not apply to it: its cap is 1). Between, only the small badge.
- It is the small slide-in at the bottom (phone and computer): "Your 5% off is still waiting" with **Get my code** and
  **Play again**. The full card opens only from those buttons. The badge "Your 5% off is saved" has the same two
  buttons (Play again while it is allowed).
- **Play again**: a new play from the server, another kind of game, a new draw from the whole prize table (another go
  included: its second game is compared the same way). The visitor keeps the better of the two prizes (the value on an
  average 4-day rental at the published rates; a tie keeps the saved one); the other play is closed, so there are never
  two open prizes: "You won 15% off" with "Better than your 5% off: this prize replaces it.", or "You keep your 5% off"
  with "This game gave 5% off, so you keep your 10% off.".
- Play again on a saved prize: once a visit and once a Toronto day per visitor, enforced by the server. A new setting,
  **Settings** > **Discount games**, "Play again on a prize not claimed, once every (days; 0: off)":
  `program_settings.game_saved_again_days`, 1 by default, 0 to 30. Not for a visitor known by email or with a booking
  request in progress (as for any new game), never in the request-to-book form, never signed in.
- Unchanged: new visitors' first game and re-show after a close; never for signed-in visitors on the site, never on
  excluded pages, never over the cookie banner; the wait after a claim (0172); the request-to-book form.

## How it works
- Migration 0176: the setting; `game_plays.again_of` (the saved play a Play again came from) and `dropped_at` (closed:
  the other prize was better); `app.game_prize_value`, `app.game_saved_again_after`, `app.game_saved_again_json`,
  `app.game_keep_better`; `app.game_start_core` changed in place: `p.again_of` (refusals `again_not_found`,
  `again_limited` with `again_after`, `known`, `in_progress`; the per-visitor start limit), the answer's `keep`
  (`from`, `token` to claim, `prize`, `other`), the second game of another go compared with the saved prize, a closed
  play never the open play, a saved play's answer with `again: {ok, again_after}`; `app.server_game_claim` refuses a
  closed play (`kept_other`).
- Browser (`web/src/features/games`): `rules.ts` `trigger`/`nextCheck`/`ineligible` take `saved` (cap 1, first-show
  rules, `slim` and `repop`), `visitCap`, `mayPlayAgain` (memory `againDay`, visit `again`), `keptWords`; `GameGate`
  passes whether a prize is saved, the badge's Play again; `GamePopup` the two-button slide-in (`data-repop`,
  `data-slim`), Play again (`again_of`), the kept prize in the claim form (the kept play's token); a saved play
  returned to an automatic pop-up in a browser that forgot it is shown small too. `games.css`: `.ccg--two`.

## Tests
`supabase/tests/99_games_repop_play_again.sql` (new): the setting, prize values, the saved answer, Play again with the
new prize better and worse and equal, the closed play never claimed, once a day (again from tomorrow's start in
Toronto) and once a visit, the next day on a new visit, another go's second game, only the visitor's own open saved
discount, the request-to-book form, known visitors, the setting at 0, privileges. `rules.test.ts`: once a visit on the
first-show rules, never on every car page, not in the visit it was won, Play again's browser hint. e2e
`games-0100.spec.ts` at 375 and 1440 with axe: the small slide-in (never the full card), no re-pop on later car pages
(badge only), the badge's Play again, the better prize kept and claimed, Play again used today then back the next day
with the saved prize kept.

## Guides
- `admin/discount-games-and-leads`: the saved prize pops up once a visit as a small slide-in with Get my code and Play
  again; Play again keeps the better prize, once a visit and once a day; the new setting; the re-show rules are for new
  games only.
