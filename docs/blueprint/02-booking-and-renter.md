# 02. Booking and the renter portal

Owner: workstream C. Routes under `src/app/book/` and `src/app/account/`. Features in `src/features/booking/` and `src/features/payments/`. Staff screens for the same flow are in `03-admin.md` section 3 and 4.

## 1. Rules this file implements

| Rule | Source |
| --- | --- |
| Request to book, never instant book. No payment and no card at request | Owner requirement 3 |
| Staff confirm, may contact the renter and adjust, then send an offer | Owner requirement 3 |
| The renter approves, signs and pays. Only then is the booking confirmed and live on the calendar | Owner requirement 3; `app.booking_before_write()` already refuses `confirmed` without a completed signature, a succeeded `booking_total` payment and a saved card |
| One transaction is 1 to 30 days | `bookings.billable_days` check, `calc_rental_charge()` |
| The deposit is taken at pickup, not at booking | Renter billing specification section 3 |
| Identity and a coverage option are confirmed before the car is released | `app.booking_before_write()` on `on_rent` |
| The four consents are shown word for word, unticked | `docs/source/website_terms_policies.md` Part 4; stored in `consents` |

## 2. The sequence: request, offer, approve, sign, pay

Statuses are `bookings.status`. Offer statuses are `booking_offers.status`. Database functions are those of migration 0016 (`00-overview.md` section 8) unless marked **[new]**. A request, an offer and a booking awaiting signature and payment never block the car; only a `confirmed` or `on_rent` booking with `blocks_calendar = true` does.

| # | Who | Screen | Action (server action -> database) | Booking status after | Offer row | Emails (catalogue codes, `12-notifications.md`) |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Visitor | `/cars/[slug]` | Picks dates; sees the live quote | none | none | none |
| 2 | Visitor | `/book/[slug]` steps 1 to 4 | `submitBookingRequest` -> `app.submit_booking_request()` **[new]**, one transaction: creates or finds `users`, `renters`, `drivers`; calls `app.request_booking()` (booking priced from the rate card in force, `status = 'requested'`, booking number `CC-...`, a `booking_request` task for CS); inserts `booking_drivers`; adds the fee lines the request needs (young driver, additional driver, winter tire, baby seat) and calls `app.reprice_booking()`; stores `bookings.request_details` **[new]** and `consents` | `requested` | none | `renter_account_created` (first time), `renter_request_received`, `staff_booking_request_new` |
| 3 | Staff (CS, Sales, Admin) | `/admin/requests`, `/admin/bookings/[id]` | Reviews. May ask the renter a question (`sendBookingMessage`). Adjusts the booking itself with `adjustBooking` -> `app.adjust_booking()`: car, dates, times, places, rates, Deposit, mileage, who is billed. A staff discount or a hand-typed rental charge is an admin's | `requested` | none | `renter_request_needs_info` when a question is sent |
| 4 | Staff | Booking review screen | `sendOffer` -> `app.send_offer(booking, sent_by, message, expires_at)`: refused when the car is not free for the dates; writes offer version n; sets `offer_expires_at` (default `program_settings.offer_expiry_hours`, 24) | `offered` | `sent` v1 | `renter_offer_ready` |
| 4a | Staff | same | `declineRequest` -> `app.decline_booking_request()` with a reason | `declined` | none | `renter_request_declined` |
| 5 | Renter | `/account/bookings/[id]/offer` | Reads the offer; what differs from the request is highlighted | `offered` | `sent` | `renter_offer_reminder` 6 hours before expiry |
| 5a | Renter | same | `requestOfferChange` (note required) -> `app.request_offer_change()` | `requested` | `change_requested` | `renter_change_request_received`, `staff_change_request_received` |
| 5b | Renter | same | `declineOffer` -> `app.decline_booking_request()` | `declined` | `declined` | in-app `staff_offer_declined`; `renter_request_withdrawn` when that template exists |
| 5c | System | job `carmacars-offers-expire`, every 5 minutes | `app.job_offers_expire()`: the offer row expires and the booking goes back to `requested` with an `offer_expired` task for CS | `requested` | `expired` | `renter_offer_expired` |
| 5d | Staff | Booking review screen | `withdrawOffer` -> `app.withdraw_offer()` to change the terms; then adjust and send version n+1 (the old row becomes `superseded` or `withdrawn`) | `requested`, then `offered` | `withdrawn`, new `sent` | `renter_offer_withdrawn`, then `renter_offer_ready` |
| 5e | System | Another booking for the same car and overlapping dates is confirmed first | Trigger `app.booking_request_after()`: this booking goes back to `requested`, its offer is `withdrawn`, CS gets a `reoffer_booking` task | `requested` | `withdrawn` | `renter_offer_withdrawn` (the copy explains the car was taken and that we will offer another) |
| 6 | Renter | `/account/bookings/[id]/offer` -> "Approve and continue" | `approveOffer` -> `app.approve_offer(booking, version, by)`: a stale or expired version is refused. Then `app.open_rental_agreement()` **[new]**: assigns `agreement_number`, builds the agreement PDF from the booking and its lines, creates the `signature_requests` row (`provider = 'builtin'`) | `pending_payment` | `approved` | none (the renter is in the flow) |
| 7 | Renter | `/account/bookings/[id]/sign` | Completes "Your details" (address, licence), ticks the four consents, signs. `signRentalAgreement` -> `app.record_signature()` **[new]** writes `signature_records` (renter), `consents` (four rows) | `pending_payment` | `approved` | `renter_agreement_ready` to each additional driver |
| 8 | Renter | `/account/bookings/[id]/pay` | `createBookingPayment`: checks `app.vehicle_is_available()` once more, then creates a Stripe PaymentIntent for `renter_due_at_booking_cents` with manual capture, saving the card. The browser confirms it (the card is authorized, not yet charged) | `pending_payment` | `approved` | none |
| 9 | Stripe | Edge Function `stripe-webhook` | On the authorization: `app.record_booking_payment()` **[new]** in one transaction locks the vehicle's calendar, re-checks availability, and if free: the function captures the payment, writes `payments` (succeeded), `payment_processor_details`, `payment_methods` and its secret row, sets `bookings.card_on_file_id`, records the CarmaCars countersignature, completes the `signature_requests` row with the signed PDF and its hash, then sets `status = 'confirmed'` (the database checks signature, payment, saved card and a free car, and pushes competing offers back) | `confirmed` | `approved` | `renter_agreement_signed`, `renter_booking_confirmed` (with the receipt), `renter_identity_needed` if not carried by the confirmation, `owner_new_booking`, `staff_offer_approved_paid` |
| 9a | Stripe | same | The car was taken in the last moments: the authorization is cancelled (nothing is charged), the booking is pushed back to `requested`, CS gets an urgent `reoffer_booking` task | `requested` | `withdrawn` | `renter_offer_withdrawn` |
| 9b | Stripe | same | On `payment_intent.payment_failed`: a `payments` row `failed`; no fee (renter specification section 7) | `pending_payment` | `approved` | `renter_payment_failed` with `is_booking_payment = true` |
| 10 | Renter | `/account/bookings/[id]/verify` | Uploads licence front, back and selfie per driver; chooses and proves a coverage option | `confirmed` | | `staff_identity_review`; after review `renter_identity_approved` (T4) or `renter_identity_rejected` |
| 11 | Field and staff | `06-field.md` | Deposit taken, handover, pickup Condition Report | `on_rent` | | `renter_booking_reminder` and `renter_pickup_details` beforehand; `renter_rental_started` |
| 12 | Field and staff | `06-field.md` | Return Condition Report, Check-in | `returned` | | `renter_return_reminder` beforehand; `renter_return_complete` |
| 13 | Finance | `05-va.md` section 2 | Statement, deposit settlement | `closed` | | `renter_final_statement` (T9), `renter_deposit_released`, then `renter_review_request` |

**Why authorize first, then capture.** Offers do not hold the car, so two renters can reach the pay step for the same dates. Authorizing the card and capturing only after the database has confirmed the booking means the loser of that race is never charged and needs no refund. If Stripe cannot authorize separately for a card, the fallback is charge then refund, which the `reoffer_booking` task already covers.

**Timers.** `offer_expires_at` applies while the booking is `offered`. Once the renter approves, the booking is `pending_payment` and does not expire by itself; it is listed in the CS digest ("approved, not yet signed and paid") and is pushed back if another booking takes the dates. Staff can re-send an offer with a later expiry by withdrawing and sending again.

**Idempotency.** `submitBookingRequest` carries a client-generated `request_key` (`bookings.request_key` **[new]**, unique); a retry returns the same booking. The webhook keys on Stripe's event id in `webhook_events` **[new]**.

**What the renter can do when.** `requested`: edit the note, withdraw (`declined`). `offered`: approve, ask for a change, decline. `pending_payment`: sign, pay, ask for a change, withdraw (no money has moved). `confirmed`: verify, cancel under the tiers, ask for a date change (section 7.4). `on_rent`: extend, report a problem. `returned`: view the Condition Report. `closed`: view statements, pay a balance, leave a review.

## 3. `/book/[slug]` Booking request wizard

| Item | Detail |
| --- | --- |
| Who | Anyone. A signed-in renter skips the fields we already hold |
| Purpose | Collect the least needed to price and confirm a request. No card, no licence photo, no address at this stage |
| P layout | One step per screen. Top: car thumbnail, dates, running total (tap to expand `PriceBreakdown`). Bottom: sticky "Continue". Progress "Step 2 of 4" as text and a bar |
| D layout | Left: the step. Right: sticky summary card with photo, dates, `PriceBreakdown`, "No card needed to request" |
| Autosave | Draft in `form_drafts` **[new]** for signed-in users and in `localStorage` for visitors; resumes on return (`08-forms.md` section 3) |
| Live price | Every change calls `app.quote_booking()`; the total updates without moving the layout |

### Step 1. Trip

| Label | Type | Validation | Default | Stored |
| --- | --- | --- | --- | --- |
| Pickup date and time | date-time, 30-minute steps | Required; at least 2 hours ahead; inside opening hours unless delivery; range available per `app.public_vehicle_calendar()` | From the car page | `bookings.pickup_at` |
| Return date and time | date-time | After pickup; at most 30 days later | From the car page | `bookings.return_at`, `original_return_at`, `billable_days` |
| How will you get the car | radio: I will collect it / Deliver it to me ($X) | Delivery option shown when the car's delivery fee is above 0 | Collect | `bookings.pickup_method` |
| Delivery address | address lookup | Required when delivery is chosen; must be in Ontario; a place outside the delivery area shows "We will confirm whether we can deliver here" and is still accepted | Empty | `bookings.pickup_place` |
| How will you return it | radio: I will return it / Collect it from me ($X) | As above | Return | `bookings.return_method` |
| Return address | address lookup | Required when collection is chosen; "Same as delivery address" tick | Same | `bookings.return_place` |
| Rate | radio: Standard (cancel under our policy) / Non-refundable (save 10% on the rental charge) | Required | Standard | `bookings.booking_type` |
| If this car is taken, a similar car is fine | checkbox | none | Ticked | `bookings.request_details.accepts_similar` |

A range longer than 30 days cannot be selected; the helper text explains renewals and links to `/long-term-car-rental`.

### Step 2. Drivers

| Label | Type | Validation | Default | Stored |
| --- | --- | --- | --- | --- |
| Your full legal name | text | Required; as on the licence | From the account | `renters.legal_name`, `drivers.full_name` |
| Date of birth | date (three selects on a phone) | Required; 18 or older at pickup. Aged 18 to 20 on a car without `allows_18_to_20`: blocked with "This car is for drivers 21 and over. See cars for 18 to 20" linking to `/cars?young=1` | From the account | `drivers.date_of_birth`; `booking_drivers.age_at_pickup`, `age_band` |
| Licence | radio: Ontario G / Ontario G2 / Another province or country | Required. G1 is not offered. "Another" asks for the issuer and adds the note "We will confirm we can accept this licence" (staff escalate per procedure 2) | none | `drivers.licence_class`, `licence_issuer` |
| Add another driver | repeatable group, up to 4 | Each: full name (required), date of birth (required, 18 or older; same age rule), email (required, for their acceptance link) | none | `drivers`, `booking_drivers (role = 'additional')` |

The price updates with the young driver and additional driver fees per driver.

### Step 3. Extras and coverage

| Label | Type | Validation | Default | Stored |
| --- | --- | --- | --- | --- |
| Winter tires ($15 a day, up to $150) | checkbox | Shown October to April | Off | `request_details.extras.winter_tire`, and a `winter_tire` line |
| Baby seats ($12 a day each, up to $70 each) | stepper 0 to 3 | none | 0 | `request_details.extras.baby_seats`, and `baby_seat` lines |
| How will you cover damage to the car | radio: My own auto policy (OPCF 27) / My credit card's rental coverage / Buy coverage through CarmaCars | Required. The third option appears only when `coverage_sold` has a price. Helper: "You will upload proof after you book. Liability coverage is included in the rate." | none | `bookings.coverage_option` |
| Travelling outside Ontario | checkbox | When ticked: "We need to approve this. Tell us where." and a text field | Off | `request_details.outside_ontario` |
| Bringing a pet | checkbox | When ticked: "We need to approve this." | Off | `request_details.pet` |
| Referral code | text | Optional; checked against `owners.referral_code` and `staff_profiles.referral_code`; pre-filled from the `/r/` cookie | Cookie | `bookings.referred_by_code` |
| Promo code | text | Optional; validated by `app.promo_code_problem()`; shows the saving or the reason it does not apply | Empty | Applied by `app.request_booking()` (`bookings.promo_code_id`, `promo_discount_cents`) |
| Anything we should know | textarea | Max 500 characters | Empty | `bookings.request_note` |

### Step 4. Contact and send

| Label | Type | Validation | Default | Stored |
| --- | --- | --- | --- | --- |
| Email | email | Required; one account per email (an existing email prompts "You already have an account. We will send a sign-in link and attach this request to it.") | Account | `users.email`, `renters.email` |
| Mobile number | tel | Required; E.164 after formatting | Account | `users.phone`, `renters.mobile` |
| I am 18 or older and agree to the Terms of Use and Privacy Policy | checkbox | Required | Unticked | `bookings.request_details.terms_version` and `terms_accepted_at` |
| Send me CarmaCars offers and news | checkbox | Optional; never pre-ticked; wording from Part 4 including the sender identification | Unticked | `consents (marketing)`, `users.marketing_opt_in`, `marketing_opt_in_at` |

Review block above the button: car, dates, places, drivers, extras, `PriceBreakdown`, deposit at pickup, and the sentence: "This is a request. Nothing is charged now. We will confirm availability and send you an offer to approve."

| Button | Action |
| --- | --- |
| Send request | `submitBookingRequest` (Turnstile; rate limit 5 an hour per IP and 3 open requests per email). On success go to `/book/sent/[bookingNumber]` |
| Back | Previous step; nothing is lost |

| State | Behaviour |
| --- | --- |
| Dates became unavailable while filling | The request is still accepted (it does not block the calendar); the confirmation says "Another booking was confirmed for part of these dates while you were filling this in. We will offer the closest alternative." and `request_details.conflict_at_submit = true` so staff see it |
| Car unpublished during the wizard | "This car has just left our fleet." with similar cars; the draft keeps the dates |
| Blocked renter (`renters.is_blocked`) | The request is accepted and flagged for an admin; the renter sees the normal confirmation. No reason is shown |
| Turnstile fails | "We could not confirm you are a person. Try again." The form stays filled |

### `/book/sent/[bookingNumber]`

Shows: "Request received", the booking number, what happens next (three numbered steps with expected times: a reply within 15 minutes during opening hours from `program_settings`), a "Check your email to finish setting up your account" line for new accounts, and a link to `/account/bookings/[id]` once signed in. A visitor who is not yet signed in sees only the booking number and the next steps, nothing personal.

## 4. `/account/bookings/[id]/offer` Review the offer

| Item | Detail |
| --- | --- |
| Who | The renter of the booking (`app.is_my_booking()`); opened from the email through `/go/[token]` |
| Data | The `booking_offers` row for `bookings.current_offer_version` with `status = 'sent'` (renters may read the offers of their own bookings), and the request columns on `renter_bookings` |
| P layout | Countdown bar ("Offer held until Oct 9, 4:30 pm"); message from staff; "What changed" list when `changes` is not empty (old value struck through, new value in bold); car card; trip summary; `PriceBreakdown`; deposit; cancellation summary for the chosen rate; buttons stacked at the bottom |
| D layout | Two columns: details left, sticky price and buttons right |

| Button | Action | Result |
| --- | --- | --- |
| Approve and continue | `approveOffer(bookingNumber, version)` | Step 6 of the sequence; goes to `/sign`. Refused with "This offer was updated. Review the new version." if the version is stale |
| Ask for a change | Opens a sheet: message (required, 10 to 500 characters), optional new dates. `requestOfferChange` | Booking back to `requested`; the note is stored in `bookings.request_note` and the offer's `response_note` |
| Decline | `declineOffer` with an optional reason (select: found another car, price, dates changed, other) | Booking `declined` |

| State | Behaviour |
| --- | --- |
| Offer expired | The booking is back in `requested`. The page shows "This offer has expired." with "Ask us to send it again" (`requestOfferRenewal` adds a note to the existing `offer_expired` task) |
| Already approved | Redirect to the next incomplete step (sign or pay) |
| Car taken by another booking | "Someone else confirmed this car for these dates first. We are looking at alternatives and will send you a new offer." Nothing was charged |
| Substituted car | The car card shows both cars side by side on desktop, stacked on a phone, with the reason from `booking_offers.message` |

## 5. `/account/bookings/[id]/sign` Your details and signature

Two parts on one route. The agreement is pre-filled from the booking; the renter types only what we do not have.

### Part A. Your details (skipped when everything is on file and unchanged)

| Label | Type | Validation | Stored |
| --- | --- | --- | --- |
| Home address | address lookup with manual fallback | Required: line 1, city, province or state, postal code, country | `renters.address_line1, address_line2, city, province, postal_code, country` |
| Licence number | text | Required; Ontario format check `^[A-Z]\d{4}-?\d{5}-?\d{5}$` when the issuer is Ontario, otherwise 5 to 25 characters | `drivers.licence_number`, copied to `booking_drivers.licence_number` |
| Licence class | select | From step 2; editable | `drivers.licence_class` |
| Issued by | select (provinces, then countries) | Required | `drivers.licence_issuer` |
| Licence expiry | date | Required; after the return date | `drivers.licence_expiry` |
| Each additional driver: licence number, class, issuer, expiry | same | Optional here; the driver can fill their own through their link. Required before pickup | `drivers`, `booking_drivers` |

Action `saveRenterDetails` -> updates the rows and calls `render-document` to rebuild the agreement PDF with the new details.

### Part B. Read and sign

| Element | Detail |
| --- | --- |
| Document | The Rental Agreement for this booking: Part 1 Summary filled from `bookings`, `booking_drivers`, `booking_line_items`, `vehicles`; Parts 2, 3, 5 (owner rentals only) and 6. Shown as HTML sections for reading on a phone, with "Download PDF" for the identical PDF (`documents.kind = 'rental_agreement'`, `template_version` set) |
| Reading aid | A summary strip pinned at the top: car, dates, total due now, deposit at pickup, deductible $2,500, cancellation rule for this booking type |
| Consents | The four statements from Part 6, word for word, each with its own unticked checkbox. All four are required. Each tick stores `consents (consent_code, text_version, text_shown, ip_address, user_agent, booking_id, driver_id)` |
| Signature | `SignaturePad`: draw with a finger or type the full legal name (typed names must match `renters.legal_name` ignoring case and spacing). `08-forms.md` section 8 |
| Button "Sign and continue to payment" | `signRentalAgreement` -> `app.record_signature()` **[new]**: `signature_records` row (`signer_role = 'renter'`, `signed_at`, `method`, `ip_address`, `user_agent`, `provider_signature` = storage path of the signature image, `initials` = the four consent codes with times). Goes to `/pay` |

| State | Behaviour |
| --- | --- |
| Terms change after signing but before payment | Staff must withdraw the offer first (the database refuses changes while an offer is out). The signature request is voided (`signature_requests.status = 'voided'`), the booking goes back to `requested`, and the renter approves and signs the new version. After confirmation, changes follow `03-admin.md` section 4.5 |
| Renter under 18 by the pickup date after a date change | Blocked by the database (`booking_drivers.age_at_pickup >= 18`); message explains |
| Additional driver has not accepted | Does not block the renter's signature or payment. The booking page shows "Waiting for [name] to accept". The handover is refused for that driver until `booking_drivers.accepted_at` is set |

**Additional driver acceptance** (`/go/[token]` -> `/account/driver/[bookingDriverId]`): the driver confirms name and date of birth, enters licence details, ticks consents 1 to 3, signs. Action `signAsAdditionalDriver` writes `signature_records (signer_role = 'additional_driver')`, `consents`, `booking_drivers.signature_record_id` and `accepted_at`. No account is required beyond the signed link; a `drivers.user_id` is created only if they later sign up.

## 6. `/account/bookings/[id]/pay` Pay

| Element | Detail |
| --- | --- |
| Summary | `PriceBreakdown` from `booking_line_items` (not recomputed): each line, HST, total due now. Then: "Refundable deposit of $X is taken at pickup, not today." |
| Card form | Stripe Payment Element (card only) in Stripe's frame. Cardholder name field above it, required, compared with `renters.legal_name`; a mismatch shows "The card must be in the renter's name" and blocks |
| Card rule | Before charging, the browser creates a confirmation token and `createBookingPayment` reads the card's funding type. Not a credit card: refused with "Please use a credit card. Debit and prepaid cards cannot be used for a rental." (rental agreement section 5.3) |
| Save card | Not a choice: the text under the form reads "This card becomes your Card on File for the deposit and any later charges, as you authorized when signing." |
| Button "Pay $X" | `createBookingPayment(bookingNumber)` -> Stripe PaymentIntent with `amount = renter_due_at_booking_cents`, `capture_method = 'manual'`, `setup_future_usage = 'off_session'`, `metadata.booking_id`, idempotency key `booking:{id}:total:{offer_version}`. The amount is captured by the webhook only once the database has confirmed the booking (section 2, step 9). Inserts `payments (purpose = 'booking_total', kind = 'charge', status = 'pending')`. The browser confirms; on success the page polls `renter_bookings.status` until `confirmed` (up to 30 seconds) then goes to the booking page with a success panel |

| State | Behaviour |
| --- | --- |
| Declined | Stripe's decline message in plain words, the form stays; no fee is added (renter specification section 7). After three declines a `cs` task is created |
| 3-D Secure challenge | Handled by the Payment Element; the page waits |
| Authorized but the webhook is late | "Card approved. We are finalizing your booking." The page keeps polling; the booking page shows the same until confirmed. A job reconciles any PaymentIntent left authorized without a webhook within 10 minutes (`payments-reconcile`, part of `reconcile`) |
| Car no longer free | `createBookingPayment` refuses when `app.vehicle_is_available()` is false: "This car has just been confirmed for someone else. We will send you a new offer." Nothing is authorized |
| Nothing to pay (an Owner Booking) | No offer and no pay step: `requested -> pending_payment` while the agreement is out, then `confirmed` on signature |
| Insurer pays (`bill_to` insurer or split) | The page shows what the insurer is billed (`insurer_share_cents` plus `insurer_hst_cents`) and what the renter owes now (`renter_due_at_booking_cents`). When that is $0 the page collects the card with a SetupIntent only ("for the deposit and any charges your insurer does not cover") and the booking is confirmed on the saved card and the signature, as migration 0016 allows. When it is above $0 the renter pays that amount as usual |

## 7. Renter portal

All routes need the `renter` role. Data comes from `renter_bookings` and the renter's own rows under row-level security. Phone navigation: Trips, Documents, Charges, Profile.

### 7.1 `/account` and `/account/bookings`

| Item | Detail |
| --- | --- |
| Purpose | Show the next thing to do |
| Layout | P: a "Next step" card for the nearest active booking (for example "Approve your offer", "Sign and pay", "Upload your licence", "Pickup tomorrow at 10:00", "Return by 6:00 pm"), then Upcoming, Current, Past lists. D: the same in two columns with the next-step card top left |
| Card content | Car photo, dates, status badge, one primary button for the next step |
| Empty | "No trips yet." and "Find a car" |

### 7.2 `/account/bookings/[id]` Booking detail

| Section | Content | Buttons |
| --- | --- | --- |
| Header | Car, booking number, status, dates and places | Add to calendar (downloads an `.ics` built in the browser) |
| Progress | Checklist: Request sent, Offer approved, Agreement signed, Paid, Drivers verified, Coverage confirmed, Pickup, Return, Statement | Each incomplete item links to its route |
| Pickup details (from 24 hours before) | Time, place or delivery window, the field staff member's first name once assigned, what to bring (original licence, the card ending in the stored last four), deposit amount | "Call us" |
| Price | `PriceBreakdown` from `booking_line_items`; payments list with status | "Download receipt" (our PDF, `documents.kind = 'receipt'`) |
| Drivers | Each driver: accepted or not, verified or not | "Resend link" for an additional driver (`resendDriverLink`, limit 3 a day) |
| Documents | Signed agreement, Condition Reports (pickup, return) with photos, statements | Open in `DocumentViewer` |
| Messages | Thread of `messages` for this booking (email and portal) | Reply box (`sendRenterMessage`: writes `messages (direction = 'inbound', channel = 'portal')`, creates or updates a `cs` task) |
| Actions | Depends on status | Withdraw request, Cancel booking, Change dates, Extend, Report a problem, Leave a review |

### 7.3 `/account/bookings/[id]/verify` Licence, selfie and coverage

Opened after confirmation; must be complete 24 hours before pickup (procedure 2). Capture details are in `08-forms.md` section 7.

| Block | Fields | Stored |
| --- | --- | --- |
| For each driver: licence front | Photo (camera or file) | `documents (kind = 'id_front', retention = 'id_face_90d', bucket identity)`, `identity_verifications.id_front_document_id` |
| Licence back | Photo | `id_back_document_id` |
| Selfie holding the licence | Photo, front camera | `face_document_id` |
| Coverage option 1 | Insurer name, policy number, expiry date (must be on or after the return date), upload of the policy page or insurer letter showing OPCF 27 | `coverage_proofs (coverage_option = 1, insurer_name, policy_number, policy_expiry, proof_document_id)` |
| Coverage option 2 | Card issuer, last four digits (must equal the Card on File's last four), upload of the benefits certificate | `coverage_proofs (2, card_issuer, card_last4, proof_document_id)` |
| Coverage option 3 | Shown only when priced: the terms document to read first, then "Add coverage for $X" which adds the line and charges the Card on File (`buyCoverage`, a server money action). The provider is never named | `coverage_proofs (3, terms_sent_at, activated_at)`, `booking_line_items (coverage_sold)` |

Button "Submit for review": `submitVerification` sets `identity_verifications.status = 'pending'` and `method = 'staff_review'`, `coverage_proofs.status = 'submitted'`, creates a `cs` task (`verify_renter`, due 24 hours before pickup or in 2 hours if pickup is sooner), emits `staff_identity_review`. The renter sees "In review" then "Verified" or the problem to fix with a re-upload button. An additional driver can upload through their own link. Consent 2 (given at signing) covers this collection; the page repeats: "We delete licence and face photos 90 days after your rental ends."

### 7.4 `/account/bookings/[id]/cancel` and date changes

| Element | Detail |
| --- | --- |
| Before confirmation | "Withdraw request": one confirm; `withdrawRequest` -> `app.decline_booking_request()`; status `declined`; no money involved. Refused by the database if a payment was already taken (it is refunded first) |
| After confirmation | Shows the three times (booked, now, pickup), the tier that applies and the refund amount, from `app.preview_cancellation(booking_id)` **[new]** which wraps `calc_cancellation()`. Non-refundable bookings show "This booking is non-refundable." |
| Button "Cancel booking" | Type-to-confirm. `cancelBooking` -> inserts `booking_cancellations` (`channel = 'portal'`, `cancelled_by = 'renter'`, `received_at = now()`; `app.booking_cancellation_fill()` computes the tier), sets `status = 'cancelled'`, inserts `refunds (status = 'pending_approval', reason = 'cancellation', due_by = 10 business days)`, runs `app.allocate_refund()` after approval, creates a `finance` task. Emits `renter_booking_cancelled` (T12), `staff_cancellation_received`, `owner_booking_cancelled` |
| Change dates | Not self-service. "Ask to change dates" opens a form with the new dates and a note (`requestDateChange` -> `booking_change_requests` **[new]**, `status = 'requested'`; emits `renter_change_request_received` and `staff_change_request_received`). Staff approve, price and apply it, or decline (`03-admin.md` section 4.5) |
| Edge cases | Cancelling inside 24 hours shows "No refund applies" before the confirm. A deposit already taken is shown as returned in full |

### 7.5 `/account/bookings/[id]/extend`

| Field | Type | Validation | Stored |
| --- | --- | --- | --- |
| New return date and time | date-time | After the current return; total length at most 30 days (beyond that the page offers a renewal: a new request with `renews_booking_id`); must be requested before the current return time | `booking_extensions.new_return_at` |

The page shows the repriced total and the difference from `app.preview_extension()` **[new]** (wraps `calc_extension()` and the per-day fee caps). Button "Request extension": `requestExtension` inserts `booking_extensions (status = 'requested')`, creates a `cs` task, emits `staff_extension_requested`. The renter gets `renter_extension_requested` as an acknowledgement. When staff approve (calendar free, no unpaid charges, coverage valid to the new date; `booking_extensions.status = 'approved'` **[new value]**), the renter gets `renter_extension_approved` with a pay link; `payExtension` charges the Card on File; on success the webhook sets `paid_at`, `confirmed_in_writing_at`, `status = 'confirmed'`, updates `bookings.return_at` and emits `renter_extension_confirmed` (T11). Not paid before the current return time: `lapsed`. If the new total passes 7 days, the deposit hold is captured first (`app.booking_before_write()` enforces it).

### 7.6 `/account/bookings/[id]/photos`

For an approved unattended handover or a renewal day: the guided photo set (`PhotoSet`, fixed order of procedure 3). Action `submitRenterPhotoSet` writes `condition_reports (performed_by_role = 'renter')` and `condition_report_photos`. Shown only when staff set `bookings.unattended_handover` or a renewal exists.

### 7.7 `/account/bookings/[id]/review`

| Field | Type | Validation | Stored |
| --- | --- | --- | --- |
| Rating | 1 to 5 stars (radio group) | Required | `reviews.rating` |
| Title | text | Optional, max 80 | `reviews.title` |
| Your review | textarea | Required, 20 to 2,000 characters | `reviews.body` |
| I agree this review can be published | checkbox | Required | `reviews.publish_consent_at` **[new]** |

Available once per booking, once the booking is `closed` (the database refuses earlier, and refuses an Owner Booking). Action `submitReview` -> `app.submit_review()` (`status = 'pending'`); creates a `cs` task and emits `staff_review_received`. The public site shows the reviewer's first name and the month. Staff publish, hide or reply and cannot change the rating or the words (`03-admin.md` section 14). Every renter with a completed rental is asked, whatever the rental was like; the request never depends on how the rental went (`14-seo.md` section 15). After submitting, the page offers "Also post on Google" with the Business Profile review link.

### 7.8 `/account/statements`, `/account/tolls-and-charges`

| Route | Content |
| --- | --- |
| `/account/statements` | Each `booking_statements` row: number, kind, date, charges, deposit applied, held back, returned, charged to card, PDF link. A balance owing shows "Pay now" (`payStatementBalance`, charges a new or saved card) |
| `/account/tolls-and-charges` | Each `toll_tickets` row matched to the renter's bookings: date, place, amount, administration fee, how it was charged, the notice (`DocumentViewer`). Each after-return `booking_line_items` row with its supporting document. "Question this charge" opens a message to Finance (`disputeCharge` creates a `finance` task and marks the toll `disputed`) |

### 7.9 `/account/drivers`, `/account/payment`, `/account/documents`, `/account/profile`, `/account/notifications`

| Route | Content and actions |
| --- | --- |
| `/account/drivers` | Saved drivers (`drivers`). Add, edit name and licence details. A driver on a live booking cannot be removed |
| `/account/payment` | Card on File: brand, last four, expiry. "Replace card" runs a SetupIntent (`replaceCard`); the credit-card and name rules apply. A card cannot be removed while a booking is live or a balance is owing |
| `/account/documents` | Every document the renter may read: agreements, Condition Reports, statements, receipts. ID images show "Uploaded [date], deleted after [purge date]" and are viewable by the renter until purged |
| `/account/profile` | Name (locked after verification; "Ask us to change it"), email (change needs confirmation by link), mobile, address, password, two-step sign-in (optional), "Download my information" (creates an admin task for the Privacy Officer), "Close my account" (blocked while a booking is live or money is owed) |
| `/account/notifications` | Marketing emails on or off (express consent recorded on turning on). A note that booking, payment and safety messages are always sent |

## 8. Edge cases across the flow

| Case | Handling |
| --- | --- |
| Two renters request the same car and dates | Both are accepted as `requested`, and both may be offered. The request inbox shows a "conflicts with" chip. The first to sign and pay is confirmed; the database pushes the other back to `requested` and CS re-offers another car or declines |
| Staff create the request by phone | `/admin/bookings/new` creates the same `requested` booking with `source = 'phone'`; the renter still approves, signs and pays online through the emailed link |
| Renter has no email access at pickup time | Everything needed is also on the booking page; staff can resend any email from the booking's Messages tab |
| Price changed between request and offer (rate card edited) | The offer uses the rates snapshotted on the booking at request unless staff press "Use current rates"; the change list shows the difference |
| Daylight-saving change inside the rental | Billable days use the Toronto clock (`calc_billable_days()`); the UI shows local times only |
| Renter is also an owner booking their own car | `/owner/bookings/new` (Owner Booking): no price, no deposit, no coverage; signs the agreement with Part 5; confirmed on signature |
| Self-Managed vehicle | The owner creates the request for their renter from `/owner/bookings/new`; the renter still approves, signs and pays through CarmaCars' checkout |
| Renewal past 30 days | A new request with `renews_booking_id`; must be made before the current rental ends; deposit carries (`booking_renewals`) |
| Chargeback | `disputes` row from the webhook; the renter portal shows the booking as "Payment disputed"; no self-service |

## 9. Database additions needed

Migration 0016 already provides the statuses, `booking_offers`, `booking_events`, offer expiry, `blocks_calendar`, `app.vehicle_is_available()`, `app.public_vehicle_calendar()`, promo codes and reviews.

| Addition | Purpose |
| --- | --- |
| `bookings.request_details jsonb` (extras asked for, similar car accepted, outside Ontario, pet, terms version, conflict at submit, landing path, referrer, UTM values), `bookings.request_key text unique` | Request snapshot and idempotency |
| `app.submit_booking_request(p jsonb) returns uuid`: wraps `app.request_booking()` and also writes drivers, `booking_drivers`, the per-driver and extras fee lines and consents in one transaction | Step 2. Today `app.request_booking()` creates only delivery and pickup lines |
| `app.quote_booking()` (see `01-public-site.md`), sharing its fee logic with `app.reprice_booking()` so a quote and a booking can never disagree | One pricing source |
| Fee lines for young driver, additional driver, winter tire, baby seat and coverage sold created and kept in step by `app.reprice_booking()` from `booking_drivers` and `request_details.extras` | 0016 leaves these to the app; they belong in SQL with the other prices |
| `app.open_rental_agreement(p_booking uuid)`, `app.record_signature(p_request uuid, p_signer jsonb)`, `app.complete_signature_request(p_request uuid, p_signed_document uuid, p_sha256 text)` | Built-in signing |
| `app.record_booking_payment(p_event jsonb)` with the availability lock; table `webhook_events (provider, event_id primary key, received_at, processed_at, error)` | Webhook, idempotent, race-safe |
| `app.preview_cancellation(p_booking uuid)`, `app.preview_extension(p_booking uuid, p_new_return timestamptz)` callable by the renter for their own booking | Read-only previews |
| Thin wrappers in `public` for the functions the browser calls: `public_vehicle_calendar`, `vehicle_is_available`, `public_reviews`, `quote_booking`, `search_available`, `promo_code_problem` (own bookings) | The `app` schema is not exposed in the API |
| Guard: `on_rent` requires every `booking_drivers` row with `role = 'additional'` to have `accepted_at` | Additional drivers must accept the agreement |
| `booking_change_requests` (`03-admin.md` section 4.5); `booking_extensions.status` value `approved` | Changes to a confirmed booking; the extension step between request and payment |
| `reviews.publish_consent_at` | Consent to publish |
| `form_drafts` (`08-forms.md`) | Autosave |
