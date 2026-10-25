# Winners play again on a later visit (0172)

The owner: "People that win a prize should be able to play again." Clarified: on a later visit. Even after claiming a
code, the game shows again on a later visit and they can win another code. Until now a claim ended the games for good
(one claim ever per browser, email, phone and device).

## The rules
- A new setting, **Settings** > **Discount games**, "after claiming a code, play again after (days)":
  `program_settings.game_replay_after_claim_days`, 1 by default, 0 to 90. 0 is the old rule: one code per person, ever.
- After a claim: no game for the rest of that visit. Once the setting's days have passed since the person's latest
  claim, the game shows again on a later visit with the usual triggers, as a fresh play: a new game and a new draw from
  the whole prize table, another go included. Plays from before the claim are left behind.
- A person (the browser, the email, the mobile number and, in the request-to-book form, the account with its email and
  renter) may claim a new code once their latest claim is that old. Within the wait the friendly refusals stay and say
  when: "This email already has a code. We sent it to that inbox again. You can play again after Mon, Oct 26 at 5:51
  pm." (likewise "This mobile number already has a code.", "A code was already claimed on this device.", "Your account
  already has a code."); at 0 they end with "One per person." as before. The server returns `again_after` with these
  and with reason `claimed` from the play.
- Each code is still single use, on one booking, never combined with another code, good for 7 days with its reminders.
  Earlier unused codes stay valid until they end.
- "Known by email" (0100, 0170): a visitor known only through their own claim is not blocked: the claim's email on
  their visits (identified by the game), a click on the code email's link with that email, or the bare account and
  renter the game's own form opens for a brand-new email (contact capture 0090) while it has no booking. Signed in, a
  real renter (a booking request, or a claim with an email that already belongs to a renter), or an email from a
  booking request, the chat, a sign-in link or anything else: no site game, as before (signed-in renters get the
  request-to-book form's game only). The claim no longer marks a visit "identified by the game" when the visit was
  already known by an email from elsewhere.
- Terms: the game's short terms say "One code a day per person, email, phone and device." ("every N days" for another
  setting, "One per person, email, phone and device." at 0). The site terms, section 14, now read "Each person, email
  address, mobile number and device may claim one code a day, or less often as shown with the game, and one code applies
  per booking." (the live text where it still carries our sentence, and `docs/source/website_terms_policies.md`; last
  updated October 25, 2026). Worth a look by the lawyer with the next batch.

## Fixed on the way
While 0171 was in place a brand-new play never drew the replay prize ("another go"): the open-play lookup came back
empty and the draw without the replay was taken. A new play now draws from the whole table, as 0171 meant. The DB
suites that claim whatever was drawn (07, 99_promo_expiry) now play on the table without the replay prize, as the other
game suites do.

## How it works
- Migration 0172: the setting; the unique indexes on `game_claims` (email, phone, visitor) become plain indexes (a
  code and a play still belong to one claim); `app.game_again_after`, `app.game_again_words`, `app.game_used`,
  `app.game_known_visitor`; `app.game_start_core` redefined (the wait, plays since the latest claim, the fresh draw, the
  known rule); `app.server_game_claim_pre0081` and `_pre0171` changed in place (the wait with advisory locks per
  browser and email, `again_after`, the Sales task); `app.game_consent_carry` takes every claim of the email.
- Staff: `app.game_leads` adds `claim_no` and `claims_total` per email; the leads show "2nd code of 2" under the name.
  A repeat claim joins the person's open Sales task (a line "Another code: ...") instead of a second task; once that
  task is done the next claim raises its own. The report adds `people` (the claims tile keeps counting claims and shows
  the people when fewer).
- Browser: the memory `cc_game` keeps `claimedAt` and `againAt` (the server's `again_after`; with none, the browser asks
  again after 30 days); an old `claimed: true` or `never: 'claimed'` without a time no longer stops a game (the server
  decides). The visit (`cc_game_visit`) keeps `claimed`, so no game shows for the rest of that visit. The
  request-to-book form uses the same wait.

## Tests
`supabase/tests/99_games_repeat_after_claim.sql` (new); 48 (the unique index check is now the code's; the terms), 53,
67, 99_game_saved_claim and 99_games_again_replay (within the day still "claimed"; the terms), 07 and 99_promo_expiry
(the table without the replay prize for their claims). `rules.test.ts` (the wait, the old memory, the booking form).
The e2e spec `games-0100.spec.ts`: claim, no game for the rest of the visit, a day later (the claim backdated, a new
tab) a new game and a second code for the same email.

## Guides
- `admin/discount-games-and-leads`: after claiming, no game that visit, back a day later with a new code; who still
  does not get it; one code a day; "2nd code of 2" in the leads; the Sales task; the new setting.
- `va/discount-game-leads`: people can win again; the same person on several lines; one Sales task.
