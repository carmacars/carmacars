# The discount game on every visit, and its preview (0353)

The owner, November 1, 2026: "i feel like the game still isnt popping up for me", then, in a private window, "only
twice". His standing requests (October 25 and 26): winners can play again, it pops up again, a "play again" prize, and
later visits get new codes.

**What stopped it.**
- For him: he is known to the site (signed in, his chats and requests), and the game never shows to someone signed in
  or known. Worse, the server's "known" or "signed in" answer was kept in the browser for good, so a browser that once
  played while signed in, or before a sign-out, never saw a game again. It is now kept for a day, then the server is
  asked again (old answers without a time no longer count).
- For everyone ("only twice"): a visit was the browser tab's session, so a tab kept open was one visit for as long as it
  stayed open; a prize won and not claimed allowed one card a visit. The game, then its one pop-up, then nothing.

**Now.**
- A visit ends after 30 minutes away (`game_visit_gap_minutes`, a Program setting): the next page starts a new visit.
- At most one game a visit by default (`game_max_per_visit` 1, a setting; the daily cap `game_max_per_day` 0, none).
  Closed without playing, it comes back on the next visit. A prize won and not claimed pops up once each visit as the
  small slide-in with Get my code and Play again (a new game; the better prize is kept; once a day). After a claim, the
  wait of `game_replay_after_claim_days` (a day), then a new game and a new code on their next visit.
- **Preview**: Settings > Discount games > **Preview the game**, or any page with `?preview=game` (and `&game=wheel`
  for one game). The card opens at once for anyone, signed in or not, plays a game to a sample prize and shows the code
  screen: no play on the server, no code, nothing remembered or captured.

**Every rule that decides when it shows** (site game; the request-to-book form has its own):
1. The games are on (`game_enabled`) and the settings could be read.
2. Not signed in (the Supabase session cookie, or the local stack's hint), and the server does not know the visitor
   (a user, a renter with a booking, an email from the chat or a request); its answer is kept a day.
3. No code claimed in this visit, and the wait after the last claim is over.
4. Not on booking, pay, sign, sign-in or portal pages; not while a booking request is in progress in this browser.
5. The cookie banner answered first (in the notice-only regions it is answered by itself).
6. The trigger: the 2nd page view (`game_trigger_car_pages`), 30 seconds on the site (`game_trigger_seconds`) or, on a
   computer, the mouse leaving for the tabs (`game_exit_intent`), whichever first. The first page of a phone visit from
   a search engine waits for the 2nd page, or comes 15 seconds later as the small slide-in.
7. At most `game_max_per_visit` a visit (1); with more, the next after a close on the 3rd page view after it or 2
   minutes later (`game_reshow_car_pages`, `game_reshow_seconds`); at most `game_max_per_day` a day in the browser (0:
   no cap).
8. A visit ends after `game_visit_gap_minutes` away (30).
9. Never for automated browsers (tests, screenshots, audits) unless a test lets it; reduced motion only calms the
   games' animation, it never hides the game.
10. Never two games at once; the chat's greeting waits for it.

`tests/e2e/games-0100.spec.ts`: a fresh anonymous visitor gets the game on the 2nd page view under the live settings,
not again in that visit after a close, and again (another game) after 30 minutes away. `tests/e2e/games-preview.spec.ts`:
the preview plays through with nothing recorded. The suites with a re-show inside a visit keep 0100's 4 a visit.

## Guides

- `admin/discount-games-and-leads`: once a visit and again on every new visit, and Preview the game.
