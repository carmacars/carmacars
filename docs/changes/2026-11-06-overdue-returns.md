# Overdue returns: "I've returned the car" (migration 0532)

The owner (November 6): renters who really have not returned the car keep getting the escalating overdue emails, texts
and alerts; a renter who has returned it must be able to stop them at once with one tap. Also in 0532: one morning digest
line per kind of website crash a day. Migrations 0530 and 0531 are the hotfix of the same day
(docs/changes/2026-11-06-hotfix-load-email.md), renumbered after r27's 0529. SCHEMA_MARKER 0532.

## What changed

1. **The link.** Every booking has a `return_link_token`. The return time notice, T13, T14 and their texts carry
   `{{returned_url}}` (`/returned/<token>`): "Already returned the car? Tell us in one tap". Opening the page changes
   nothing (mail scanners open links); its one button sends the report. The renter's booking page has the button
   **I've returned the car** from 3 hours before the return time while the car is out (`/account/bookings/<n>/returned`
   opens the same page).
2. **The form.** All optional: photos (several at once from the camera roll; each made a smaller JPEG in the browser and
   uploaded to private storage under `bookings/<id>/return-claim/`), the odometer, the fuel level, the actual return time
   and a note. `public.server_return_claim_submit` accepts only photos of that booking's prefix.
3. **What sending does.** At once: the booking's `return_state` is `returned_pending_confirmation`; every overdue email,
   text and phone alert still waiting for the booking is skipped (`app.overdue_quiet`); `app.ntf_emit` emits no overdue
   notice (`app.overdue_codes()`) for it while the report waits (nothing is recorded, so a stage not sent yet goes later
   if the report is denied); the report is kept in `return_claims` as renter-provided; Fleet gets an urgent To do
   `return_claim_review` ("The renter says the car is back"); the booking history has `return_claimed`.
4. **Staff decide.** The booking page (Admin and staff portals, inside the check-in card) shows **The renter says the car
   is back** with the readings and photos to everyone who checks a car in (Admin, Fleet, Sales, Customer service, Field):
   - **Confirm**: the time, odometer and fuel may be corrected. The return is recorded with `app.handover_record_now`
     (the trip is completed, the late charges follow the confirmed time, Fleet's usual "Add the photos and readings" task
     follows), the renter's photos join the check-in report (shot `other`) and its notes say what was renter-provided.
   - **Deny**: the reason is required; the renter gets `renter_return_claim_denied` (email and text, with the link again)
     and the overdue notices resume.
5. **Completed another way.** A check-in, record now or any move of the booking to returned, closed or cancelled skips
   the overdue notices still waiting, settles a waiting report and closes its To do.
6. **Website crashes.** 0433's crash reports also add one line per kind a day to the Admins' morning digest (one email a
   day), besides the To do.

## Tests

`supabase/tests/99_overdue_returns.sql`: the link in the notices and texts, the page's read, privileges, the report's
checks, the overdue notices skipped and not emitted while it waits, the To do, Deny (reason, renter told, notices resume),
Confirm (readings corrected, trip completed, photos on the check-in report), completion by the usual check-in, the crash
digest line, the email budgets of 0531. `web/src/features/returns/claim.test.ts`: the form's payload and checks.

## Guides

- `renter/during-your-trip`: "Already brought the car back but still getting late notices?"
- `admin/requests-offers-and-bookings`: "The renter says the car is back" (Confirm or Deny).
- `va/fleet`: the To do and the decision.
- `field/a-return`: the report on the booking; the usual check-in settles it.
- `admin/quick-reference`: the sign-in factor line without the service's name.
