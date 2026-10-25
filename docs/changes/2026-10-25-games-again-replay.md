# The discount game comes back, and one prize is another go (0171)

The owner: "It should pop up again and one of the prizes should actually be to play again."

## What changed for the visitor
- A prize won and not claimed pops up again. The full card opens by itself with the prize and its form to get the
  code, titled "Your 5% off is still waiting" (never "You won" a second time), at the moments a game would show: on a
  later visit the 2nd page view or 30 seconds, after a close the 3rd page view or 2 minutes, at most 4 cards a visit.
  The small "Your 5% off is saved" badge stays between pops. It ends when the code is claimed or when the visitor's
  prize ends (14 days, `game_dismiss_days`).
- A game closed before its prize showed comes back on the next visit (it already did: the browser keeps no wait after a
  close, and `game_dismiss_days` is how long a visitor keeps the prize drawn for them, not a wait). That setting stays
  at 14 days: at 1 day a visitor's saved prize would end after a day and a new prize would be drawn every day, which
  changes the odds. The within-visit re-show is unchanged.
- A new prize, another go: "You won another go!" with a **Play again** button. It starts a second game, always a
  different one, whose prize is drawn from the discounts only, so it always ends in a code. One replay per chain; a
  replay prize is never a code. Closed before pressing it, the card offers it again ("You still have another go").
- Unchanged: never for signed-in visitors on the site, never on excluded pages, never over the cookie banner, never
  after a claim; known by email or a booking request in progress still stops new games (a prize already won stays
  claimable; the in-progress rule also keeps the card from popping by itself, the badge and the request-to-book form
  still offer it).

## The prize table
5% off 54, 10% off 25, another go 15, 15% off 4, $50 off 3+ days 1, 25% off up to $150 0.6, $100 off 4+ days 0.3,
one free day on 3+ days 0.1 (100 in all). The 15 come from 5% off; the three rare prizes of 0081 stay. Live rows and
the column default move the same way (a table an Admin edited gets the replay prize from its most common prize; a
table of 8 prizes is left as is). Admins can change it under Settings, Discount games ("Play again (another go)" in the
prize kind, at most one, never the only prize).

## How it works
- Migration 0171: `game_prizes_ok` accepts `{"key", "replay": true, "weight"}`; `game_prize_label` says "another go"
  ("REPLAY" on a wheel slice, a reel, a Plinko slot); the short terms add "or another go (a second game, which always
  ends in a discount)"; `game_plays.replayed_at` and `game_plays.replay_of`.
- `app.game_start_core`: `p.replay_of` (the browser's RPC on the site, `/api/games` in the request-to-book form)
  checks the play is this visitor's (or this account's) in the same context, revealed, not claimed, a replay prize and
  not replayed; marks it and starts the second play (another game, a prize from `app.game_prizes_real`). Outside the
  per-visitor start limit. The saved play is the latest play: a revealed replay not used yet comes back as saved (to
  play again); a dry check names only a discount; a second game closed before its prize comes back as it was.
- `app.server_game_claim` refuses a replay prize (`error: replay`).
- Report: plays by prize, a "Play again" row, the number of second games. Leads list only codes.
- Browser: `ineligible` no longer stops the card for a saved prize; `GamePopup` shows the saved card on any trigger
  and the replay panel; `rememberWon` never keeps a replay. Every game shows the replay prize's words; longer short
  words are drawn smaller.

## Tests
`supabase/tests/99_games_again_replay.sql` (new); 48, 53, 67 and 99_game_saved_claim updated to the new table (their
claims run on the table without the replay prize, then the owner's table is back). `rules.test.ts`; the e2e spec
`games-0100.spec.ts` (the card pops up again, Play again to a code) and `discount-games.spec.ts` (eight prizes).

## Guides
- `admin/discount-games-and-leads`: the games, when they show and come back, the waiting card, the prize table with
  another go, Play again, the report and the settings.
- `va/discount-game-leads`: a visitor who wins another go plays a second game; only the code shows in Game leads.
