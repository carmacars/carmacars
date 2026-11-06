# Release 28, operations, bookings, agreements and money (migrations 0540 to 0548)

Branch `r28` (agent A of release 28). SCHEMA_MARKER 0548 (the merge with agent B's 0560 to 0579 sets the highest).

## A1. Booked when the renter accepts (0540)

- A booking the renter accepted (status `pending_payment`: the offer approved) is booked: it takes the car in
  `app.vehicle_is_available`, the public and Admin calendars, the car's calendar, calendar feeds, the fleet board, the
  date-conflict check, the partner availability, and `app.booking_is_booked` (reports). Confirmed and on rent as before.
- The first renter to accept gets the car: accepting already checks availability; the other open offers on the car and
  dates go back to Requests at once with a "Re-offer" To do (`bookings_accepted_takes_car`).
- Payment and the handover are badges, never the reason: "Booked, payment due" (staff lists, the Now board, the
  calendar, the booking summary, next step), "Booked" for the renter. To do `booked_unpaid` for a booked rental still
  unpaid within 48 hours of the pickup (run by the staff notification job); "Record the pickup" as before.
- Data fix: an accepted booking paid in full but never confirmed is confirmed (each in the audit log, `0540_booked_data_fix`).
- Wording: the offer screens, the renter's offer page, the offer emails (`renter_offer_ready`, `renter_offer_reminder`).

## A2, A3. One screen, the renter's own check-in and checkout, many photos (0545)

- `app.handover_one_screen`: the check-out or check-in on one screen for Admin, Fleet, Sales, Customer service and field
  (the time, km, fuel, any photos, a note; only the time is needed). The renter's own photos join the same report.
  Complete (km, fuel, a photo): no "add the details" To do. The checklist stays one tap away ("Full checklist").
- The renter's own check-in (`/account/bookings/<n>/pickup`, from 24 hours before pickup): recorded at once as an
  unattended handover when the booking is ready (the pickup's own checks), else a `self_handover_review` To do.
- The renter's own checkout is r27's "I've returned the car" form (the same component, from the booking page any time
  the car is out, and from the overdue link): with km, fuel and a photo the trip is completed at once at the renter's
  time (late charges follow it); otherwise r27's review. Overdue messages stop either way.
- Photos (`PhotoPicker`): many at once from the camera roll or camera, made smaller JPEGs on the phone, each tagged with
  an angle if wanted; the 15 suggested angles are a checklist that ticks itself. `condition_report_photos.angle`, who
  took each (`uploaded_by`). Upload route `/api/handover-photo`.
- The pickup and return reminders (`renter_pickup_soon`, `renter_return_soon`) ask the renter to take the photos and
  check in or return the car themselves. The checklist screens themselves are unchanged.

## A4. Pickup from owner, return to owner (0546)

- `vehicle_owner_handoffs`: time, km, fuel, photos with angles, notes, who. Admin vehicle page, staff Fleet vehicle page;
  read only for the owner on their car page. Admins void a mistaken record.

## A5. Deposits stay holds (0541)

- `calc_deposit_method` answers `card_hold` for any length; an extension past 7 days keeps the hold.
- `deposit_auto_capture` off (audited); a hold nearing expiry with the car out or tickets possible raises
  `deposit_hold_expiring` (Finance) instead of a capture. Booking > Money: "hold expires <date>", **Re-authorize the
  hold** (`hold_reauth_begin`/`finish`: a new off-session hold on the saved card, then the old one released).
- Stripe's `capture_before` is kept on the deposit (`server_deposit_hold_expiry`), with whether the hold was extended.
- Program settings **Extended deposit holds** (off): `request_extended_authorization=if_available` on the off-session
  deposit hold only, retried without it when Stripe refuses (unit tests). Never on the rental charge. Pay-link holds
  (confirmed in the renter's browser) and the Terminal reader stay standard holds.
- Terms, site pages, FAQ and Academy say "a hold, renewed before it lapses".

## A6. Send-offer layout

The offer as the renter sees it sits right under **Send the offer** (Admin and staff: `OfferComposer`, `BookingReview`).

## A7. Cleaning fee (0542)

`cleaning_heavy` $300 from today as a fee default (editable in Admin fees), relabelled "excessively dirty"; the rental
terms' schedule says $300 (smoking was $300 already). Charged at check-in and taken from the deposit as before.

## A8. Amendments without re-signing (0542)

Rental terms 15.4 (new): booking updates keep the signed agreement in force. `app.agreement_plan`: a change after
signing is a version marked "Amended <date>", not signed again (only an additional driver who never signed signs);
the renter gets it (`renter_agreement_version`). A change of the clauses' wording itself still asks for signatures.

## A9. Owner agreements

`v2_enrollment.md` 11.1 and `v2_flat_rate_enrollment.md` 9.1: CarmaCars does not cover engine blowups, transmission or
major suspension problems. Agreement text only; no site page.

## A10. Referral links between owners (0543)

`owner_referral_links` (Admin, the referrer's Terms tab): share in basis points, read-only view. The referrer's
statement gets a `referral_share` line per referred car (`owner_referral_shares`, paid once, from CarmaCars' share),
added to the payout; a referrer without cars gets a statement when the referred owner's is built. Owner portal: Cars >
**Cars you referred**. Max's 40% and $350 a month are set on his cars' terms in Admin (no names in the repository).

## A11. Blind Spot form (0544)

Renter signature also on the x line below box 2 and in box 40; box 34's per-hour late charge from the booking's late fee;
VLF, LDW, T&LDW, PAP/PEC, Waiver Saver, underage, CDW and winter tires each in their box with the rate a day left of it
(also when typed by hand as "other"); km and fuel out and in from the booking when the reports have none; totals
checked against the ledger (unit test). **Type into the Blind Spot agreement**: typed values per box
(`blindspot_box_overrides`), written back to the booking where they have a home, preview PDF. Not done: a visual
rasterized comparison (the form is private; the position tests run on the stand-in).

## A12. Invoices to partners (0547)

`partner_invoices`, lines, payments; PI-numbered; percentage of the partner's total or fixed lines, HST per line;
email `partner_invoice` with the PDF link; one reminder before and after due; ledger per partner and claim; CSV;
Admin (Referral partners > Invoices, the Overview tile) and Finance (Money > Partner invoices); the partner's page
lists them. Not done: the cheque photo upload (the payment has its field).

## Tests

`supabase/tests/99_r28_operations.sql`; older suites follow the new rules (06 and 08: the first to accept gets the car;
01, 03, 08, 09: deposits stay holds; 07: the partner invoice email; 99_overdue_returns: the self checkout).
Unit: `blindspot/fill.test.ts`, `payments/stripe.test.ts`, `handover/angles.test.ts`, `partner-invoices/model.test.ts`.

## Guides

`admin/requests-offers-and-bookings`, `admin/owner-money`, `admin/fleet-and-listings`,
`admin/referral-partners-and-rentalcoverage`, `admin/settings`, `va/finance`, `va/customer-service`, `va/fleet`,
`field/a-handover`, `field/a-return`, `renter/your-offer`, `renter/before-pickup`, `renter/during-your-trip`,
`owner/home-and-your-vehicles`. Academy: the offer rule and the deposit lesson and question (0548).
