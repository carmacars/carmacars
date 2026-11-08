# The Admin override of a pickup or a return, Record a past trip, Book it now (Release 33, part K: 0770 and 0771)

Branch `r33-k` (on `r33`). Migrations `supabase/migrations/0770_r33k_overrides_book_now.sql` and
`0771_r33k_overrides_guides.sql` (guide text only, `supabase/seed/0771_gen_guides.mjs`). SCHEMA_MARKER 0771. Tests:
`supabase/tests/99_r33k_overrides_book_now.sql` (32 assertions), `web/src/features/handover/override.test.ts`. No applied
migration is edited: the guards are patched in place around each refusal (`pg_temp.wrap_raise`), the door is wrapped
(`door_pre0770`).

## The owner's requests (November 7, 2026)

| Item | How it works |
| --- | --- |
| 1. Admin override on handovers ("manually entering the vehicle pickups/returns still doesn't let staff/admin override stuff when we absolutely need the trip to start") | `booking_overrides`: one row per override, scoped to a booking, an action (pickup, return, past trip, book now) and the list of checks it passes, with the reason. It is one-shot: applied (status `applying`) inside the one transaction that records the pickup or the return, then `used`. `app.override_skips(booking, check)` is true only for that booking, that row and its checks, so a guard passes nothing else (never a global bypass; a used override passes nothing even with its id set). The checks, each a guard patched to ask it: the deposit (`booking_before_write`, `booking_app_before`, `handover_record_now`, without waiving it), the signed agreement (`booking_signature_guard`), the renter's signature on the check-in report and the agreement's claim details and the tracker (`handover_record_now`), identity and licence, coverage (`booking_before_write`), the additional drivers and the calendar switch (`booking_app_before`), payment due (the booking is confirmed with its balance open, as `confirm_offline_booking` does, then on rent), the car's status (`booking_after_status`, and the car's status flow for that car only), maintenance, the Ontario licence, the fleet insurance policy rule (`booking_handover_on_policy`: the override skips it; the hotfix's Program setting `field_handover_requires_fleet_policy` still decides whether it applies at all, and the list shows it only when it applies), at a return the odometer below pickup. `app.handover_blockers` lists what stops it now in plain words (`app.override_label`); a placeholder, a wrong status or a time in the future are never overridden. **An Admin**: Override and record (time, km and fuel if known, reason required), one step. **Staff** (Fleet, customer service, Sales, field staff): Ask an Admin to override, from the same card (the booking page of every staff portal, and the field job); the Admin gets the alert **Override asked for** and a To do line (`override_approve`, admin queue) and approves in one tap (To do, the booking page); it is then recorded as the person who asked, with the time they entered (the checks as they stand at approval). Every use: the booking's history (`handover_override`), the audit log (`booking_override_used`), and the alert **Override used** to Admins |
| 2. Record a past trip (a trip Oct 31 to Nov 3 never recorded) | **Record a past trip** on a confirmed (or waiting for payment) booking whose pickup time passed: both times, the km and fuel at each if known, the reason. One override covers the pickup and the return: the pickup is recorded at its time, then the return at its time (late charges follow it), the booking lands in **Returned** so the deposit can be settled. The car's status today is put back as it was (it may be on another rental now), and the renter's "your rental started" email of a trip long over is skipped. The photos and readings come later (the Fleet task of Record now). Staff ask for it the same way |
| 3. Book it now (no renter approval) | A tick box above Send on **Send an offer** (no request, `offer_create`) and on a request's **Send the offer** (`send_offer`). The door sends the offer and books it in the same transaction (`app.offer_book_now`). An Admin: the offer is approved at once as the current version by the Admin (`approve_offer`'s own checks: not expired, charges unchanged, the car still free; the licence is asked on the Sign and pay page before payment), the booking waits for payment and holds the car as an approved offer does (overlapping offers are pushed back, a new overlapping offer is refused); the "approve your offer" email is skipped and the site makes the agreement as the renter at once (`src/server/book-now.ts`, `ensureAgreement`), whose email opens the **Sign and pay** page (`/account/bookings/<n>/checkout`); staff can collect the signature and the card on their device (Sign now on this device, Take the card). Staff: the offer goes out as usual and an Admin approves Book it now in one tap (alert, To do, the booking page); the renter may still approve it themselves meanwhile |

Where it shows: `src/features/handover/HandoverOverride.tsx` (the card, its words in `override.ts`) on the booking page
(`BookingPage.tsx`, the Admin's and every staff portal's) for offered, waiting for payment, confirmed and on rent
bookings, and on the field job (`app/staff/field/jobs/[id]/page.tsx`); the To do's one-tap Approve and Decline
(`features/admin/todo/registry.tsx`, `override_approve`). Door names: `handover_blockers` (ops_read), `handover_override`
and `override_decide` (ops_do: approve, decline, cancel).

## Decisions

- The record runs as the person who entered it (the report says who did the handover); the Admin's approval and the
  override are on the history and the audit log.
- A payment overridden is not waived: the booking is confirmed with the balance open (the Money tab shows it). A deposit
  overridden is not waived either (it stays to collect); an Admin's deposit waiver with a reason still works as before.
- The checks are taken again at approval: what is overridden is what blocks at that moment (recorded on the row).

## Existing assertions changed

| File | Was | Now | Why |
| --- | --- | --- | --- |
| `supabase/tests/08_booking_app.sql` | 57 booking history kinds | 59 | 0770's `handover_override` and `offer_booked_now` |
| `web/src/lib/schema-marker.ts` | 0761 | 0771 | the new migrations |

## Not done here

- The end-to-end specs were not added or run (CI only); the pages were not opened in a browser. Type check, lint, unit
  tests and the database suite ran.
- The text sent with an Admin's Book it now offer (when Text was ticked) is not withdrawn; the email is. The text's link
  opens the offer page, which then shows Sign and pay.
- Book it now from the API connector and the assistant (`send_offer` tools) is not offered.

## Guides

- `admin/requests-offers-and-bookings`: Override a pickup or a return, Record a past trip, Book it now.
- `va/customer-service`, `va/sales`: Book it now; when a check stops the pickup or the return.
- `va/fleet`: when a check stops the pickup or the return.
- `field/a-handover`: when a check stops the handover.

Exported to `docs/guides/content`; migration 0771 publishes the 5 changed chapters (`supabase/seed/0771_gen_guides.mjs`).
