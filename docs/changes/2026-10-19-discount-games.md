# Discount games (October 19, 2026)

Migration `0069_discount_games.sql`; tests `supabase/tests/45_discount_games.sql`; unit tests
`web/src/features/games/rules.test.ts`; end to end `web/tests/e2e/discount-games.spec.ts` (phone 375 and desktop 1440).
No applied migration was edited.

The owner's request: collect contact details from visitors who browse a lot, with an interactive discount game for
people who are not signed in, on by default with sensible settings and no setup. Later the same day: two more games (cup
shuffle and Plinko, five in all) and a cheaper prize table with a $75 cap per percentage code.

## 1. What the visitor sees

| Point | How |
| --- | --- |
| Games | Spin the wheel, scratch to reveal, quick blackjack (one hand, the dealer draws to 17), cup shuffle (about three seconds of swaps, then pick a cup), Plinko (8 rows of pegs, 9 slots). One at random per visitor, equal weights (`game_weights`) |
| Every play wins | The database draws the prize before the game starts (`app.game_draw` over `game_prizes`); the game only shows it. The wheel stops inside a slice of the prize (often close to a bigger one), Plinko's path stays near the middle and turns off late into a slot of the prize; blackjack and the cups win whatever happens ("Win or lose, you get a discount", "Every cup hides a discount"). No losing outcome: a giveaway, not a game of chance with stakes |
| Prizes (default) | 5% off (70), 10% off (25), 15% off (4), $50 off a rental of 3 days or more (1). The wheel has 12 slices (5% on every other one); the short terms list the prizes and say the chances differ: "Prizes: 5%, 10% or 15% off, or $50 off 3+ day rentals. The chances differ: most players win 5% off. Off the rental charge only, up to $75 per code. One use, on one booking, within 7 days. One per person, email, phone and device. Not combinable with other promo codes." |
| Unlock | First name, email, mobile (optional, "for a faster booking"), the marketing box unticked with the booking form's own wording (`legal.marketing_opt_in`), the short terms with links to Terms section 14 and the Privacy policy. Then the code (WIN-7KQ4-XM2P) with Copy and Choose a car; the same code by email either way |
| The card | A slide-in card at the bottom left on a computer (the chat is on the right), a bottom sheet (at most 85% of the screen) on a phone; never a full-screen block, never on load. Close button and Esc; focus moves to the card and back; live regions say what happens ("It stopped on 10% off"); every game plays by keyboard (Reveal it for me on the scratch card, the cups are buttons); reduced motion: no spin, shuffle or bounce, the result at once |

## 2. When it shows (Program settings, "Discount games")

| Rule | Default |
| --- | --- |
| On | `game_enabled` true |
| After car pages, or time, or exit intent | `game_trigger_car_pages` 2, `game_trigger_seconds` 60, `game_exit_intent` true (computers only) |
| Never | Signed in; known by email (a session with a renter, an account or an email); on booking, pay, sign, sign-in, portal and document pages; on the first page of a visit from a search engine on a phone (Google's intrusive interstitial rule); over the cookie banner (it waits for an answer); in automated browsers (tests, the guides' screenshots, audits) |
| After closing | `game_dismiss_days` 14; never again after a claim (this browser, and the database refuses a second claim from the device) |

The counting happens in the browser (`sessionStorage`, `localStorage`) and is not sent anywhere until a claim. That is
essential, first-party and stays on the device, so it does not need the analytics choice; the privacy policy says so.

## 3. The code

A promo code of 0016, `source = 'discount_game'`: single use (`max_uses` 1, once per renter), expires after
`game_code_valid_days` (7), off the rental charge only (never fees, the Deposit or tax), one code per booking (a second
code replaces the first, never adds to it), and two new columns on `promo_codes`:

- `max_discount_cents`: `app.promo_discount_cents` caps a percentage code (the game's codes take `game_max_discount_cents`, $75).
- `min_rental_days`: `app.promo_code_problem` refuses the code on a shorter booking ("This code is for rentals of 3 days or more"); `public.quote_booking` leaves it off a shorter quote with the same words.

The discount stays a `promo_discount` line of Owner Revenue, so it is shared with the owner in the split like every
promo code (the owner's decision); the test checks the split of a confirmed booking with a $50 code.

One per email, phone and device: unique indexes on `game_claims` (email, normalized phone, browser id). The same email
again: "This email already has a code. We sent it to that inbox again." (at most once a day, never shown on screen).

The request form has a promo code box (step 4), filled from `?promo=` or from the code won on this device; the quote
shows the "Promo code" line and "Code WIN-... applied: $50.00 off the rental charge." This box was also missing for the
come-back codes of 0018, whose emails said to enter the code at request.

## 4. The lead, the task, the emails

| What | How |
| --- | --- |
| Lead | `leads` (kind `other`, `source = 'discount_game'`, payload with the game, prize, code, cars and pages viewed), consent with the exact wording when ticked |
| Live visitors | The visitor's sessions get the name and email (`identified_by = 'game'`); without analytics consent one essential session row, like the chat |
| Task | `game_lead_follow_up` (Sales, due in an hour of opening time) when the visitor viewed `game_task_min_cars` (3) or more cars: "Claimed 10% off, viewed 6 cars: Maya". Closed when the code goes on a request |
| Converted | A confirmed booking with the code marks the lead converted |
| Emails | `renter_game_code` (immediate) and `renter_game_code_reminder` (`game_reminder_hours`, 24, before an unused code expires; once; `app.job_game_reminders`, pg_cron `carmacars-game-reminders` every 30 minutes). Both transactional: the code the visitor asked for |
| Marketing consent | An existing account with the claim's email is opted in with the claim's wording (never over an unsubscribe); an account opened later with that email takes it (`app.game_consent_carry` on `users`). Then the existing marketing and recovery flows apply |
| Retention | Plays never claimed go after `visitor_events_keep_days` (90); a claim goes 24 months after its code expired unless the person became a customer |

## 5. Staff

| Screen | Who | What |
| --- | --- | --- |
| Bookings > **Leads** (`/admin/leads`) | Admins | The report (plays, claims and claim rate, consent, codes on requests, bookings and redemption rate, revenue and discounts, 30 days; by game and by prize) and every claim: name, "on the site now", email and phone, prize and game, code, used or not (with the booking), consent, the visit (cars, pages, minutes, visits, city, device), the follow-up; Call, Email, Contacted, Close |
| My work > **Game leads** (`/va/game-leads`) | Customer service and Sales | The same list and report |
| Settings > **Discount games** (`/admin/settings/discount-games`) | Admins | On or off and the rules, the prize table (percent or dollars, minimum days, chance with its share shown) and the games' weights, the report |

## 6. Privacy and terms

`docs/source/website_terms_policies.md` and the live `legal.privacy` and `legal.terms` blocks (only where they still had
our text): section 10 explains when the game shows, that the counting stays on the device, and what a claim keeps; the
section 1 table has a "Discount games" row; section 6 keeps claims 24 months after the code expires unless the person
becomes a customer. Terms section 14, "Promo codes and discount games": a free giveaway, no purchase needed, every play
wins, prizes and chances shown with the game, rental charge only up to the cap shown, one booking, not combinable,
expiry in the email, one per person, email, phone and device, no cash value, void if claimed with false details or by
automated means, a game may end at any time. "Last updated" stays October 19, 2026.

## 7. Performance and search

Nothing loads with the page: the watcher (a few KB) loads after the page is idle; the card, its CSS and each game load
only when a rule fires. Fixed position, so no layout shift and no effect on LCP; the content is never blocked on load.
The settings, the play and the reveal go from the browser straight to the database (anon), not through the Worker; the
claim is the only Worker request, once per visitor at most. The per-page Worker CPU is unchanged.

## 8. Tests

| Suite | Result |
| --- | --- |
| Database (`scripts/test.sh`) | 4420 passed, 0 failed (new suite 48, 76 assertions; 03 lists `game_plays` among the tables not audited; 07 counts the 2 new emails and builds both) |
| Unit (`npm run test:unit`) | `rules.test.ts`: eligibility, triggers (pages, time, exit intent, the phone search landing), every game lands on the drawn prize (1,000 wheel stops and Plinko paths per prize), blackjack, the cups, the claim form |
| End to end, 375 and 1440 | `discount-games.spec.ts` 18 of 18 locally: each game shows after two car pages, plays (spin, scratch with the mouse or Reveal, a hand, the shuffle and a pick, a drop) and reveals; the code after the form (lead, code and email in the database); never again on the device; Esc closes for 14 days; the code fills the request form, takes $50 off a 4-day request and goes on the booking request; a signed-in visitor never sees a game; Leads and Settings for the Admin (axe on the card at each stage and on Leads) |

## 9. Guides

Admin: new chapter "Discount games and leads" and a line in Settings. VA: new chapter "Discount game leads" and the
menu line. Released by the 0069 guides block (`supabase/seed/0069_gen_guides.mjs`).

## 10. Deploy and checks

Not deployed yet: the branch `games` (one commit on top of 0068) waits to be pushed to main; then the deploy run with the full suite and verify (full).
