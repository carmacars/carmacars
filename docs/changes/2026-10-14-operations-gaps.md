# Operations gaps: booking changes proposed by staff, amendments, cleaning blocks, similar listings, account links, driver links, Forms C and D, field photo shoots, October 14, 2026

Migrations `supabase/migrations/0040_operations_gaps.sql` and `0041_sample_cars_not_compared.sql`, tests `supabase/tests/25_operations_gaps.sql`, end to end
`web/tests/e2e/ops.spec.ts`, catalogue generator `supabase/seed/0040_gen_catalogue.mjs`. No earlier migration was
edited; the functions it changes are wrapped (renamed `_00NN` and called from a new function of the same name) or
replaced with the same signature, as 0029 to 0039 did.

## 1. What was missing, and what there is now

| # | Launch audit row | Now |
| --- | --- | --- |
| 1 | 0024: a staff proposal to change a confirmed booking sent the renter no email; customer service called | Staff propose new dates, times, car or rental charge from the booking (Admin and customer service). The renter gets `renter_change_proposed` and answers on the change page by a deadline, with one reminder; the difference is charged to the card on file or refunded; the owner is told; the calendar moves only on acceptance (section 2) |
| 2 | 0019: change requests produced no amendment document | A booking amendment PDF (pdf-lib, CarmaCars header), signed by the renter with the built-in signature (drawn or typed), stored with the booking, in the renter's documents and linked from the confirmation email (section 3) |
| 3 | 0020: no automatic cleaning block at return | A cleaning block after every confirmed trip, length in Program settings with a per-car override, on every calendar, blocking availability, removable by staff (section 4) |
| 4 | 0022: no copy similarity between listings | VIN, plate, year/make/model/colour, photo fingerprint and listing text compared with the cars on file; a likely duplicate waits for staff before it is published (section 5) |
| 5 | 0027: linking an account to an earlier request with the same email was done by hand | Earlier requests and driver places are attached once the sign-in's email address is verified, with a notice in the renter portal (section 6) |
| 6 | 0028: no "Resend link" for additional drivers | The renter (booking page) and customer service or an Admin (booking screen) send a new link; links expire after Program settings hours, and a new link ends every older one (section 7) |
| 7 | 0029: Form C and D upload and review | Owners download the pre-filled Form C or D, sign it with witnesses, upload the scan; customer service or an Admin approves it or sends it back with what to fix; emails both ways; status in the owner portal and Admin (section 8) |
| 8 | 0032: no field capture screen on a photo shoot job | The listing capture inside the photo-shoot job: camera input per shot, shot list, progress bar, retry, the photos stored and fed to the listing worker, each with its SHA-256 for the similarity check (section 9) |

Not done here (another agent owns them, as asked): reading toll notices, covering plates, filling the ServiceOntario
PDFs, the tracker integration. Also not done: the pending payment row at PaymentIntent creation and Forms A and B on
screen (section 12).

## 2. A change staff propose to a confirmed booking

- Admin > Bookings > a booking > Changes, and the same tab for customer service: "Propose a change" (new pickup,
  new return, another car of the fleet, or a new rental charge before tax), "Preview the price" (the database's own
  price and problems: availability, the 2-hour notice, the car's rules), a reason the renter reads, "Send to the
  renter". Only customer service, Fleet and Admins may set a rental charge by hand (`request_booking_change` refuses it
  for anyone else); the renter's own preview never shows that key.
- The proposal (`app.propose_booking_change`) gets `accept_by` = now + `booking_change_accept_hours` (48), never later
  than the pickup less `booking_change_lead_hours` (2), and a `booking_change_approval` task for customer service due
  then. `renter_change_proposed` is emailed once the proposal is committed (a deferred trigger, so a proposal withdrawn
  in the same transaction sends nothing).
- `app.job_booking_changes` (pg_cron `carmacars-booking-changes`, every 15 minutes): one
  `renter_change_proposal_reminder` `booking_change_reminder_hours` (12) before the deadline; at the deadline the
  proposal expires (`renter_change_proposal_expired`, `staff_change_proposal_answered`, the task closed, an open
  amendment voided). The booking is never touched.
- The renter's change page shows what changes (before and after), the reason, the money line and the time left. Accept
  = sign the amendment (section 3); then any extra amount is charged to the card on file with an off-session
  PaymentIntent (idempotency key `booking-change:<id>`, so a retry never charges twice) and the change is applied at
  exactly that amount. A refund (a lower price) is raised for an Admin's approval as 0019 does. A declined card leaves
  the amendment signed and the booking as it was, with "Pay and apply the change" to try again. Decline = an optional
  reason, `staff_change_proposal_answered` to customer service.
- Applied: the booking, its price lines, the calendar and the cleaning block move; `renter_change_applied` (with the
  signed amendment attached as a 7-day link), `owner_booking_changed` to each owner whose car or income changed (the old
  and the new car's owner on a car change), `staff_change_proposal_answered`.
- Settings (Admin > Settings > Program settings > Booking requests and offers): `booking_change_accept_hours`,
  `booking_change_reminder_hours`, `booking_change_lead_hours`.

## 3. The booking amendment

- `web/src/features/agreement/amendment.ts` (text version `amend-v1-2026-10`): the amendment number (the agreement
  number with `-A1`, `-A2`, ...), what changes, the reason, the payment line, the new total, "everything else stays the
  same", the lapse date, signatures. The page and the PDF render the same blocks; the parties line names CarmaCars (the
  numbered company name is not shown on renter pages).
- `app.open_booking_amendment` stores the unsigned PDF's SHA-256 (private `agreements` bucket); `app.sign_booking_amendment`
  writes the signature record (statement, typed name or drawn image, IP address, device, document hash) and agrees the
  change; the signed copy (signature and record page) is attached by `app.attach_signed_amendment`. A change agreed on
  the phone (0019's path) records the amendment as `recorded` without a signature.
- The renter reads both copies under the booking's Documents and Your documents (the renter's row-level security list
  now includes `rental_amendment`); staff see them with the booking's documents.

## 4. The cleaning block after each trip

- `turnaround_block_enabled` (on) and `turnaround_block_minutes` (120) in Program settings; `vehicles.turnaround_block_minutes`
  overrides per car (Admin > Vehicles > a car > Calendar, "Cleaning time after each trip"; Fleet and Admins).
- `app.sync_turnaround_block` keeps one block (`source = 'turnaround'`, reason `cleaning`, note "Cleaning after booking
  CC-...") from the return for that length, clipped at the next pickup; it follows a change or an extension, goes away
  with a cancellation, and is not put back once staff removed it. It shows on the master calendar, the car's calendar
  and the staff calendars; it blocks availability (the booking's own block never blocks the booking itself).
- Removing: the calendar's side panel, "Remove the block" with a reason (`app.remove_turnaround_block`, customer
  service, Fleet or an Admin).
- Note: this is a second buffer on top of 0025's 2-hour turnaround in availability; with both at 2 hours they cover the
  same time. Set `turnaround_block_minutes` to the real cleaning time.

## 5. Listing similarity

- Compared on every change of a car, its photos and its drafted copy (`app.check_listing_similarity`), with every car
  not exited: the same VIN, or one character apart when at least one of the two is a real VIN (its check digit is
  right; placeholder numbers like the sample cars' `SAMPLE01XXXXXXXXX` are not compared that way); the same plate; the
  same photo (SHA-256 of the uploaded file) as a listed car; listing text alike at `listing_similarity_copy_bps` (60%,
  three-word runs) with a listed car of another model (twins of one model may share text, 0022's canonical rule); the
  same year, make, model and colour (shown, does not stop publishing).
- A flag that stops publishing raises a `listing_similarity` task for Fleet and `staff_listing_similarity` (Fleet
  digest). `publish_listing` refuses while one is open or confirmed. Admin > Fleet > Similar cars and VA Fleet > Similar
  cars: "Not a duplicate" or "Same car", each with a note; the listing review screens show the flags of that car.
- `listing_similarity_enabled` turns it off. Cars already on file were compared once without tasks or emails.
- Sample cars (`vehicles.is_sample`) are never compared (0041): on the live database the first comparison flagged 20
  pairs of sample cars whose placeholder VINs are one character apart and happen to carry a right check digit; 0041
  removed those flags.

## 6. Earlier requests on a verified sign-in

- `users.email_verified_at` is set when the address is proven: the confirmation or invitation link (`/auth/callback`),
  a password link, or a password sign-in (the sign-in service lets only confirmed addresses sign in).
  `app.account_email_verified` then attaches the renter records, bookings and driver places made with that address
  (`account_links`); two different renter records for one address go to customer service (`account_link_review` task).
- The renter portal shows "We found earlier requests made with your email" with the booking numbers until dismissed.
- An owner applying with an address already on file from a booking request: the application goes on that record and the
  owner receives a link to choose their password (0036's `email_on_record` path finished).

## 7. Additional drivers' signing links

- `rental_agreement_signers` carries `link_version`, `link_expires_at` (`booking_driver_link_hours`, 72), and who sent
  it how often. A link is valid only for its version and before its expiry; the driver's page says "This link has
  expired" otherwise.
- The first link goes to each driver with an email when the agreement opens (`renter_driver_link`; the renter's
  `renter_agreement_ready` no longer goes to drivers). "Send a new link": the renter on the booking page, customer
  service or an Admin on the booking screen; the driver is emailed when we have their address, and the link can be
  copied.

## 8. Forms C and D

- Who needs what (`app.owner_witnessed_forms`): Form D (limited power of attorney, two witnesses) for an owner with any
  car not Turo-only; Form C (lender or lessor permission acknowledgment, one witness) for each financed or leased car.
  Owner > Documents: "Forms to sign with witnesses": download the pre-filled PDF (generated from
  `scripts/gen-owner-agreements.mjs` text), the witnesses' names, upload a PDF or photo (re-encoded as JPEG).
- Review: Admin > People > Owner forms, VA customer service > Owner forms, and the owner's Admin page ("Forms C and
  D"): open the scan, Approve, or Send back with what to fix. Emails: `staff_owner_form_uploaded` (customer service
  digest, with an `owner_form_review` task), `owner_form_approved`, `owner_form_rejected`. The onboarding checklist has
  a `witnessed_forms` step after the signatures.

## 9. Field photo shoot

The photo-shoot job's page (`/field/jobs/<id>`) starts the listing and shows the same capture as owners and Fleet:
"Take photo" (camera) and "From photos" per shot, a progress bar of required shots, "Send again" on a failed upload,
and Submit. Each upload records its SHA-256; a photo already on another listed car is flagged.

## 10. Emails added (catalogue 142)

`renter_change_proposed`, `renter_change_proposal_reminder`, `renter_change_proposal_expired`, `renter_change_applied`,
`owner_booking_changed`, `staff_change_proposal_answered` (customer service digest), `renter_driver_link`,
`staff_listing_similarity` (Fleet digest), `staff_owner_form_uploaded` (customer service digest), `owner_form_approved`,
`owner_form_rejected`. Link paths added: `va_similar_cars`, `va_owner_forms`. Rows generated by
`supabase/seed/0040_gen_catalogue.mjs` into the migration; templates built by `emails/build.mjs`.

## 11. Existing assertions changed

| File | Was | Now | Why |
| --- | --- | --- | --- |
| `06_request_to_book.sql` | calendar blocks listed every block | blocks other than `cleaning` | the cleaning block after a confirmed trip |
| `07_notifications.sql` | catalogue 131/1, 63 link paths; the synthetic `renter_agreement_ready` went to a driver | 142/1, 65; it goes to the renter; the 11 new codes are emitted in the completeness block | the new emails; drivers get `renter_driver_link` |
| `08_booking_app.sql` | a staff proposal emitted no event | one (`renter_change_proposed`) | item 1 |
| `09_operations.sql` | calendar kinds without `block`; the repair block counted every block | with `block`; `source = 'staff'` | the cleaning block |
| `11_owners_forms_listings.sql` | checklist without `witnessed_forms` | `witnessed_forms:open:owner` after the signatures | item 7 |
| `12_end_to_end.sql` | renter emails of the second booking | plus `renter_change_applied=2`, `renter_change_proposed=1` | the calendar change is a staff proposal |
| `17_admin_portal.sql` | blocks counted | `source = 'staff'` blocks counted | the cleaning block |
| `web/tests/e2e/admin.spec.ts` (master calendar) | clicked the car's first block | the block whose text is the one it made | the car may also carry a cleaning block |

## 12. Not done, and why

- **Pending payment row at PaymentIntent creation** (0028): the payment row is still written at authorization. Changing
  the live payment path's order needs its own race tests; behaviour today is correct, only the audit trail of an
  abandoned card form is missing.
- **Forms A and B on screen** (0029): they stay data sheet PDFs.

## 13. Tests and live results

| Check | Result |
| --- | --- |
| Database suite (`scripts/test.sh`) | 25 files, 2,962 assertions, 0 failed; `25_operations_gaps.sql` 122 (proposals, deadline, reminder, expiry, decline, rental charge rights, amendment open, sign, hash, typed name, recorded path, money both ways, owner emails, cleaning block follow, clip, remove, override, availability, similarity by VIN, plate, photo, copy and specs, placeholder VINs, publish refusal, decisions, account links and staff review, driver link versions, expiry, renew and send rights, Forms C and D needs, upload, review, checklist, emails and payloads, the server's service-role reads, the renter's row-level security on amendments) |
| Unit (`npm run test:unit`) | pass |
| Types, lint, build | `npm run db:types` unchanged, `tsc` clean, `eslint --max-warnings=0` clean, `next build` green |
| Text and emails | `scripts/check-text.sh` passed; `emails/check.mjs` 15 checks passed (142 emails); `0040_gen_catalogue.mjs --check` up to date |
| End to end (local, fake Stripe), 375 and 1440 | `ops.spec.ts` 6 of 6: Admin proposes a day longer, the renter signs the amendment by typed name, the difference is charged once, the booking moves, the signed PDF downloads and is under Your documents, renter and owner emails; a second proposal declined; the cleaning block follows and is removed from the car's calendar; renter and customer service send new driver links, the older link says expired; a guest request attached after sign-in with the notice; a VIN one character from a real VIN cleared; Form D downloaded, uploaded, sent back, uploaded again, approved, with the emails; a field photo shoot captured with the camera inputs and submitted. axe, overflow and the copy rules on every page. The whole suite: 135 passed before the last fixes; the four tests that failed then (the cleaning block in `admin.spec.ts` master calendar, a hydration error from a form inside a paragraph on the car's calendar tab, the decline landing, a run-order flake in `gaps.spec.ts` messages) pass on a rerun |

LIVE

## 14. For the owner

- **Read the new legal text**: the booking amendment (`web/src/features/agreement/amendment.ts`) and the Form C and D
  wording (`scripts/gen-owner-agreements.mjs`) should be read by the lawyer.
- **Cleaning time**: `turnaround_block_minutes` is 120 by default, the same as the 2-hour turnaround buffer in
  availability; set it to the real cleaning time (Admin > Settings > Program settings), and per car where it differs.
- **Similar listings**: the year/make/model/colour match is shown but does not stop publishing (twins are common in a
  fleet). Say if it should.
- **Supabase "Confirm email" must stay on**: a password sign-in is treated as a verified address because unconfirmed
  addresses cannot sign in.
