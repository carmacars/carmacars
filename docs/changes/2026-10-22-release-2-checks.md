# Release 2: the full suite (October 22, 2026)

## What changed

- The car page lists no "Dates and price" link under On this page for a car that is not taking requests: it has no booking box, so the #dates anchor is missing (from the maintenance branch; the link check failure on main).
- The local stand-in for the AI writer (`web/src/integrations/llm/fake.ts`) writes a car's intro from three short sentences picked from separate lists. With one pick from five sentences, the end-to-end site (dozens of cars) soon had no intro left that did not repeat another car's, so new cars kept their plain copy. The stand-in for the chat assistant quotes the car on the visitor's page when several cars share the name (since 0087 a car added by hand goes live at once). Neither runs on the live site.
- End to end: the rates form's "Add a rental for a car whose listing is not finished" takes back the rate card and the publishing 0087 now gives a car added without rates.
- Suite 56: the late-night visit is put back in the past after its checks, so the job test passes just after local midnight.
- Settings > Search opens in a few seconds again: the overview reads the public fleet once instead of once for each of the 25 landing pages (0087 section 8; a minute on the larger fleet now that every car added goes live at once).
- The car a person just added (or asked to write again) gets its AI copy first: the search job took the asked cars oldest first, and cars added straight in the database are asked with no job right after them, so they piled up ahead of it now that every car added goes live at once (0087 section 9).
- The owner application: a saved draft with no car opens at step 1, never on the review, so an owner whose account opened without a car lands on adding one.
- The portal headers wrap a long sign-in email instead of widening the page on a phone.
- Texts and calls: for Sales, a renter's booking that Sales cannot open (anything but a request, an offer or a booking waiting for payment) is named without a link, so it never leads to a missing page.
- End to end: the proof of coverage of the guided actions test has a real file behind it; the usage guard tests and the car copy tests no longer overlap (a lock in `tests/e2e/helpers.ts`); the discount game's retry asks for other dates.
- CI: the full job may run 100 minutes (the release 2 end-to-end suite runs about 45).

## Guides

No guide change: nothing a person sees or does changes, apart from links that led nowhere and a faster settings page.
