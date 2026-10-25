# The saved discount's "Get my code" works again (0170)

The owner: "When clicking onto the website it just says the discount is saved and when u click get my code, nothing
happens. And it never pops up again after that."

## What was wrong
A visitor who wins a prize and closes the card sees "Your 5% off is saved" on later pages. "Get my code" asks the
database for that saved play. The database refused any visitor known by email (an email typed into any form here,
the game's own claim form included, or a past sign-in on that browser) and any visitor with a booking request in
progress, before it looked for the saved play. So the card closed at once and the badge came back: a button that did
nothing, on every page, for 14 days.

## What changed
- `app.game_start_core` (migration 0170): a prize already won and not claimed is returned as the saved play to
  anyone who has not claimed one. Being known by email, or a booking request in progress, still stops a new game.
- `GamePopup.tsx`: if the database no longer holds the saved prize (claimed, lapsed, games off), the browser forgets
  it, so the badge goes away instead of doing nothing. If the prize lapsed, the visitor gets a new game.
- Test `supabase/tests/99_game_saved_claim.sql`.

## Why it "never pops up again"
That part is by design: a browser that already won shows the saved badge rather than a new game, and a visitor who
is signed in, or known by email (a staff member testing on their own browser), never gets the site's game. To see it
as a visitor would, use a private window that has never signed in.

## Guides
No guide text changes: the Admin "Discount games and leads" chapter already says known visitors get no game, and
leads are under Bookings > Leads (Renter leads).
