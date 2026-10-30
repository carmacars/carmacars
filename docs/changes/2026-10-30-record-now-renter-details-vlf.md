# Record a pickup or return now, renters complete the agreement's details, the VLF (0195)

The owner, October 30. Migration `supabase/migrations/0195_record_now_renter_details_vlf.sql`, SCHEMA_MARKER 0195.

## 1. Record the pickup or the return now, photos later

**Before.** A renter returned CC-10012, but the car could not be marked returned nor the deposit settled: check-in
(`app.complete_return`) needs the photo set, fuel, km, keys, cleanliness and signatures, and the statement and deposit
settlement need a reviewed check-in report.

**Now.** On the booking's "Check-out, check-in and signing" card (Admin and assistant booking pages, anyone who may hand
over): **Record the pickup now (details later)** on a confirmed booking, **Record the return now (details later)** while
on rent. The actual time (now by default, may be earlier, never later), km and fuel if known, and a reason
(`ops_do handover_record_now`, `app.handover_record_now`).
- The booking moves (confirmed to on rent, on rent to returned) with the actual time; a return's lateness, extra days and
  the late return lines are worked out from that time as at a check-in (`app.return_auto_charges`).
- The report of that leg is kept open with `condition_reports.details_pending` and `recorded_now` (who, when, why, any
  override). Fleet gets the task **Add the photos and readings for CC-...** (`handover_details`), which cannot be closed by
  hand while the report waits.
- Later, **Add the check-out / check-in photos and readings** opens the usual checklist (`handover_open` gives the job
  again). The checklist skips the ready check, the tracker step and the renter's signature; completing it
  (`complete_handover` / `complete_return`, through `app.handover_details_complete`) applies the field checks (readings,
  keys, cleanliness, photo set, staff signature), updates the booking's km and fuel, opens an incident for new damage,
  writes the km and fuel charges again and closes the task. The booking does not move.
- Money guards kept: a pickup without the deposit taken needs an Admin and a reason (the existing deposit waiver); a pickup
  without the renter's signature on the check-out report needs an Admin and a reason (kept on the report and the booking's
  history); the agreement's claim check (0154) and its Admin override are unchanged; staff other than an Admin need the
  tracker reporting, as at a check-out. The booking's own triggers (identity, coverage, calendar) still apply.
- After a return recorded this way the check-in statement can be issued before the photos are reviewed, and the deposit
  settled (Money, Settle). A release before the photos are in shows the blocker "The return's photos and readings are not
  added yet": Finance may apply or hold back; an Admin releases with the reason (the 0155 deposit guard).

## 2. Renters complete the agreement's missing details

`app.agreement_renter_missing` lists the blanks of `app.agreement_missing` the renter gives: date of birth, home address,
mobile, their own licence number, issuer and expiry, the coverage's insurer, policy number and expiry, or the card's
issuer and last four digits. In the renter's account a blocking **Complete your details** form (exactly those fields; the
insurer from the shared insurer list) shows at the top of the booking, and in place of the signature on the signing page
and of the card form on the payment page, while the booking waits for payment, is confirmed or on rent. It saves through
`public.renter_agreement_fill` (the renter of the booking only, those keys only, blanks only: a value on file is not
overwritten), into the same columns `app.agreement_fill` writes (renters, the renter's driver and the booking's copy,
coverage_proofs, made when none exists). An open agreement is made again; a signed one follows by itself (0154). Staff see
**Waiting for the renter's details** on the Agreement card (`agreement_state.renter_missing`). No email or text is sent.

## 3. VLF on insurer-billed rentals

Release 20's 0191 (charges to the insurer) already prices a VLF a day on an insurer-billed booking
(`booking_insurer_fees`): rate x days with HST, paid by the insurer also when it pays the rental only, its own insurer
invoice line, Blind Spot's box 43 and the CarmaCars agreement's charges. 0195 adds the default:
- `program_settings.vlf_daily_cents` (0 by default: none), on Settings (Insurer-billed rentals: VLF a day).
- When a booking is first billed to an insurer (made so, or switched to the insurer) and has no VLF, that rate a day is
  put on it (`app.booking_vlf_default_trg`). Staff change or remove it under Charges to the insurer, like the others.
- As in 0191, a booking goes back to the renter only once its charges to the insurer are removed.

## Judgement calls
- Late return charges use the fee defaults as `handover_time_correct` does (a missing default counts as 0) rather than
  refusing the return.
- Renters fill blanks only; corrections of values on file stay with staff or Your details.
- The VLF follows the days on the booking (not extension days added later) and is recalculated whenever the booking is
  priced again; a change of the program setting reaches a booking the next time it is priced.
- HST applies to the VLF line.
- Merged into Release 20 after 0191: the VLF is 0191's charge to the insurer; 0195 keeps only the program default (no
  `bookings.vlf_daily_cents`, no second VLF line or invoice line, no VLF field on the Insurance claim card).

## Files
- `supabase/migrations/0195_record_now_renter_details_vlf.sql`; `supabase/tests/99_record_now_renter_details_vlf.sql`
- `web/src/features/handover/HandoverPanel.tsx`, `panel.ts` (+ test), `web/src/features/field/Checklist.tsx`, `types.ts`
- `web/src/features/portal/CompleteDetails.tsx`, `renter-details.ts` (+ test), `web/src/server/portal/renter-details.ts`,
  `web/src/server/actions/portal.ts`, `web/src/app/account/bookings/[number]/page.tsx`, `sign/page.tsx`, `pay/page.tsx`
- `web/src/features/agreements/AgreementPanel.tsx`
- `web/src/app/admin/bookings/[number]/page.tsx`, `web/src/features/admin/fields.ts`
- `web/src/lib/db/types.ts`, `web/src/lib/schema-marker.ts`

## Guides
- `admin/requests-offers-and-bookings`: Record the pickup or the return now; Waiting for the renter's details
- `admin/insurance-replacements-rates-and-billing`: VLF
- `va/fleet`: Add the photos and readings
- `renter/sign-and-pay`: Complete your details
