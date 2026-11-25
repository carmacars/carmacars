# The discount game is for signed-in people too (Release 50: 5040)

Migration `5040_r50_games_signed_in.sql`, watcher `web/src/features/games/GameGate.tsx`, rules `web/src/features/games/rules.ts` (`ineligible`, `excludedPath`), card `web/src/features/games/GamePopup.tsx`, door `web/src/app/api/games/route.ts`. Tests: `supabase/tests/99_r50_games_signed_in.sql`, `web/tests/e2e/r50-games.spec.ts`, `web/src/features/games/rules.test.ts`.

## What changed

- **The owner**: "everyone should see it." The game popup used to skip anyone signed in (they only got it inside the request-to-book form). Now a signed-in renter gets it on the site like anyone else, on the same rules: once a visit, the dismiss days, the wait after a claim, the 30 seconds or 2 car pages trigger, never in an automated browser.
- **One tap for a renter**: the card opens with their name and email filled in from their account ("Get my code", no typing). The code is tied to their user and renter, so it shows under Rewards > Your discounts and applies at checkout. The claimed card says so.
- **Staff and admin** (Admin, Sales and the other VA roles, field) see and play it as a preview. Their claim says "Staff can't use game codes: this is a preview of what visitors see." and no code, lead or claim is made. This is enforced in the database (`app.server_game_claim`, `app.game_is_staff`), not only in the card. The request-to-book form still turns staff away.
- **Never inside a portal**: `/account`, `/admin`, `/staff`, `/staff-restore` (new), `/va`, `/field`, `/owner`, `/investor`, and booking, checkout, payment and signing pages.
- **Play again** stays for visitors who are not signed in; an old "signed in" answer kept by a browser is ignored.
- **Database**: `app.game_start_core` no longer refuses the site to a signed-in person (it returns their account for the prefill, counts their account's claims for the wait, and does not treat them as "known"); `app.server_game_claim_pre0171` accepts plays of the site; `app.server_game_claim` refuses staff first. Functions have `pg_temp` last in `search_path`; `service_role` may execute.
- **Tests**: unit tests of `ineligible` and `excludedPath`; a database suite (renter plays and claims, the claim is in My discounts, the wait, staff of every role get the message and nothing is made); an end-to-end spec (renter one tap and code in the account, staff preview, no game in portals or checkout).

## Guides

- `admin/discount-games-and-leads`: everyone gets the game, a signed-in renter's code is on their account, staff see a preview, the portals are excluded.
- `va/discount-game-leads`: the game is for everyone who visits; staff see a preview.
