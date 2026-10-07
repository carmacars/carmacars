# 03. Admin portal

Owner: workstream D. Route files under `src/app/admin/`; components in `src/features/` (`bookings-admin`, `calendar`, `money`, `tolls`, `incidents`, `statements`, `insurers`). Every route in this file needs `user_roles.role = 'admin'` and a completed two-step sign-in (`13-security.md` section 4). The VA portals reuse these components with fewer capabilities (`05-va.md`).

Standard states, the server action contract and the shared components are in `00-overview.md` sections 2 and 6. Tolls and tickets are specified in `10-tolls-tickets-damages.md`, statements and reports in `11-statements-and-reports.md`, the listing pipeline in `09-listing-pipeline.md`. This file gives each of those a route entry and a pointer.

## 1. `/admin` Dashboard ("Today")

| Item | Detail |
| --- | --- |
| Purpose | What needs an admin now, and the state of today's operation |
| P layout | Stacked cards in priority order. Pull to refresh |
| D layout | Three columns: Needs you (left), Today (middle), Money and fleet (right) |

| Card | Content | Source | Click |
| --- | --- | --- | --- |
| Approvals | Count and total by kind: refunds, deposit releases, payouts, statements, price overrides, tracker disables, listings | `refunds`, `deposits`, `payouts`, `owner_statements`, `tracker_commands`, `vehicle_listings` where awaiting approval | `/admin/approvals` |
| Escalations | `tasks` with `escalated = true` and open, newest first, with the procedure number and reason | `tasks` | Opens the related record |
| New requests | Count of `requested` bookings (new, waiting on the renter, pushed back, offer expired) and the oldest waiting time; red after 15 minutes in opening hours | `bookings` | `/admin/requests` |
| Offers out | `offered` and `pending_payment` bookings with time left | `bookings`, `booking_offers` | Booking |
| Today's pickups and returns | Time, car, renter, field staff member, readiness (verified, coverage, deposit, car ready) | `bookings`, `field_jobs`, `booking_drivers`, `coverage_proofs`, `deposits` | Booking |
| Late now | `on_rent` bookings past `return_at`, minutes late, last tracker reading age | `bookings`, `tracker_status` | Incident or booking |
| Fleet | Cars by status; fleet policy count against the minimum of 10 (`app.fleet_count()`); trackers silent over 30 minutes | `vehicles`, `tracker_status` | `/admin/vehicles` with the filter |
| Money this month | Collected, refunds, company-only revenue, Revenue Share, owner payable, deposits held, renter receivables, owner arrears | Views in `11-statements-and-reports.md` section 3 | `/admin/reports` |
| Jobs | Any `job_runs` row failed in the last 24 hours | `job_runs` | `/admin/jobs` |
| Email quota | Sent today out of 100 | `notification_outbox` | `/admin/messages` |

Empty: each card shows its own zero state ("Nothing waiting"). The dashboard never shows a blank column.

## 2. `/admin/approvals`

One list of everything that needs an admin's approval, with the amount, who prepared it, the rule that applies and the evidence.

| Kind | Row shows | Approve (action -> database) | Reject |
| --- | --- | --- | --- |
| Refund | Booking, reason, tier and percentage, amount, requested by | `approveRefund` -> updates `refunds.status = 'approved'`, `approved_by`, `approved_at` (guarded by `app.guard_refund_approval()`), then the payments module issues the Stripe refund, inserts the refund `payments` row, runs `app.allocate_refund()`. Emits `renter_refund_issued` | `rejectRefund` with a reason; `refunds.status = 'rejected'` |
| Deposit release | Booking, deposit, applied, held back with reason, release amount, due date | `approveDepositRelease` -> `app.settle_deposit()` **[new]** (guarded by `app.guard_deposit_release()`), Stripe capture or cancel, `deposit_events`. Emits `renter_deposit_released` | Reason required |
| Owner statement | Owner, month, payout, a link to the statement | `approveStatement` -> `app.approve_owner_statement()` | Sends back to draft with a note |
| Payout | Payee, kind, amount, bank last four | `approvePayout` -> `payouts.status = 'approved'` (guarded by `app.guard_payout()`; a second admin for `requires_both_principals`) | `cancelPayout` |
| Price override | Booking, fee, default, requested value, reason | `approveBookingOverride` -> `booking_fee_terms (source = 'booking')` (guarded by `app.guard_booking_override()`) | Reason |
| Tracker disable | Vehicle, booking, grounds, T14 time, live reading | `approveTrackerDisable` (section 17) | Reason |
| Listing | Vehicle, cover photo | Opens `/admin/listings/[id]` | |

Bulk approve is offered for refunds from the cancellation table and deposit releases with nothing applied, in one daily batch (VA hiring package section 5). Each row is still written and audited separately. An admin cannot approve something they prepared when a second admin is required (`app.guard_approver()`).

## 3. `/admin/requests` Booking request inbox

| Item | Detail |
| --- | --- |
| Purpose | Work new requests oldest first until each is offered or declined |
| P layout | Cards: car thumbnail, dates, renter name, age band chips, waiting time, flags. Swipe left for "Decline", tap to open |
| D layout | Table left (60%), the selected request's review screen in a `SidePanel` right |
| Columns | Waiting, Booking number, Car, Pickup, Return, Days, Renter (new or returning), Drivers (age bands), Request total, Flags, Assigned to |
| Flags | Conflict (another request or booking overlaps), Under 21, Non-Ontario licence, Outside Ontario, Pet, Delivery outside area, Blocked renter, Unverified email, Insurer, Renewal, Self-Managed car |
| Filters | State (new, waiting on the renter, offer out, approved and awaiting signature and payment, offer expired, pushed back by another booking), assigned to me, car, flag |
| Row actions | Assign to me (`assignBooking` sets `tasks.assigned_to` on the request's task), Open, Decline |
| Empty | "No requests waiting." |
| Realtime | The list subscribes to Supabase Realtime on `bookings` where status is `requested`; a new row slides in with a sound off by default |

## 4. `/admin/bookings/[id]` Booking review and adjust

The same screen serves every status. Tabs: Review, Drivers, Agreement, Money, Condition, Messages, History. On a phone the tabs are a horizontal scroll strip and the action bar is fixed at the bottom.

### 4.1 Header (all tabs)

Booking number, status badge, `blocks_calendar` switch state, car (link), renter (link), dates, waiting or expiry timer, assigned staff member. Buttons depend on status (section 4.4).

### 4.2 Review tab: adjust the request, then send the offer

There is no separate offer draft. While a booking is `requested`, staff change the booking itself; each save goes through `app.adjust_booking()`, which works out everything that follows (billable days, rate applied, rental charge, non-refundable discount, mileage total, price lines, totals) and records the change in `booking_events`. Sending freezes those terms as an offer version. While an offer is out the form is read-only with one button: "Withdraw to edit".

Left: the request as the renter sent it (read-only: the first `booking_events` row, `bookings.request_note`, `bookings.request_details` **[new]**). Right: the booking as it now stands. Differences from the request, and from the last offer version, are highlighted; the renter sees the same list.

| Label | Type | Validation | Default | Stored (through `app.adjust_booking()` unless noted) |
| --- | --- | --- | --- | --- |
| Vehicle | search select of bookable vehicles, each showing whether it is free for the dates | Must pass `app.vehicle_bookable()`; a car without `allows_18_to_20` cannot be chosen for a driver aged 18 to 20. Moving to another vehicle takes that vehicle's rates unless rates are typed | Requested car | `bookings.vehicle_id` (owner, mode and company share follow) |
| Pickup | date-time | A pickup in the past is refused | Requested | `pickup_at` |
| Return | date-time | After pickup, 30 days maximum | Requested | `return_at`, `original_return_at` |
| Pickup method and place | radio and address | Place required for delivery | Requested | `pickup_method`, `pickup_place` |
| Return method and place | radio and address | | Requested | `return_method`, `return_place` |
| Booking type | radio: standard, non-refundable | | Requested | `booking_type` |
| Rates: daily, weekend, weekly, monthly, km per day, overage | money and number | Any assistant may change these on a request; "Use the current rate card" resets them | Rate card at request | rate columns |
| Rental charge typed by hand | money | Admin only | Computed | `rental_charge_cents` |
| Staff discount | money and reason | Admin only; reason required; discounts together cannot exceed the rental charge | 0 | `staff_discount_cents`, `staff_discount_reason` |
| Deposit | money | Default by class | Rate card | `deposit_cents` |
| Delivery fee, pickup fee | money | $75 to $200, or 0 | Vehicle's rate card | Price lines kept by `app.reprice_booking()` |
| Drivers and extras | Additional drivers (name, date of birth, email), winter tires, baby seats (count) | Age rules as the public wizard | Requested | `booking_drivers`; fee lines (`young_driver_18_20`, `young_driver_21_25`, `additional_driver`, `winter_tire`, `baby_seat`) through `app.reprice_booking()` once it covers them (**[new]**; until then the action writes the lines and calls reprice) |
| Promo code | text | `app.promo_code_problem()` explains a refusal | Requested | `applyPromoCode` -> `app.apply_promo_code()`; `removePromoCode` -> `app.remove_promo_code()` |
| Per-fee override for this booking | per fee: amount and reason | Admin only (`app.guard_booking_override()`); a VA sees "Ask an admin", which creates an approval | none | `booking_fee_terms (source = 'booking', override_by, override_reason)` |
| Outside Ontario approved; pet approved; unattended handover approved | checkboxes | Admin only | Off | `bookings.outside_ontario_consent`, `pets_approved`, `unattended_handover` |
| Bill to | radio: renter, insurer, split | Insurer fields appear (section 7) | Renter | `bill_to` and the insurer columns |
| Blocks calendar | switch with a reason | Section 7.2. Sales may flip it on a request only | On | `app.set_blocks_calendar()` |
| Offer valid until | date-time, with shortcuts 6, 12, 24, 48, 72 hours | 1 to 720 hours ahead; over 72 hours needs an admin | `program_settings.offer_expiry_hours` | `app.send_offer(..., p_expires_at)` |
| Message to the renter | textarea | Required when anything differs from the request; max 1,000 characters | Empty | `booking_offers.message` |
| Internal note | textarea | | Empty | `bookings.notes` |

Under the form: `PriceBreakdown` from the booking's own lines (so what staff see is what will be sent), the insurer's part and the renter's part when billed to an insurer (`app.booking_insurer_share()`), the availability strip for the chosen car (a 14-day slice of the vehicle calendar centred on the dates, conflicts in red, other open requests and offers for the same dates listed as "competing"), and for admins the split preview (kickback if a referrer applies, Owner Revenue, company share) from `calc_booking_split()`.

### 4.3 Contact the renter

| Button | Action |
| --- | --- |
| Call | `tel:` link; "Log call" opens a note form -> `messages (channel = 'phone', direction, body)` |
| Ask a question | `sendBookingMessage` with "Needs an answer" ticked: sends `renter_request_needs_info` (the question fills `info_request`), sets `bookings.awaiting_renter_since` **[new]**, logs to `messages`, shows in the renter's booking thread. The renter's reply clears the flag and returns the task to the queue |
| Quick replies | Stored snippets (admin-managed in settings): asking for licence type, proposing an alternative car, proposing other dates |

### 4.4 Buttons by status

| Status | Buttons | Action -> database | Emails |
| --- | --- | --- | --- |
| `requested` | Save | `adjustBooking` -> `app.adjust_booking()` | none |
| | Send offer | `sendOffer` -> `app.send_offer()`; refused when the car is not free for the dates (unless the booking's calendar switch is off) | `renter_offer_ready` |
| | Record approval by phone | After sending: `approveOffer` by staff on the renter's word; the history shows it was staff | none |
| | Decline | `declineRequest` (reason select: no availability, driver not eligible, outside service area, other; optional alternatives) -> `app.decline_booking_request()` -> `declined` | `renter_request_declined` |
| `offered` | Withdraw to edit | `withdrawOffer` -> `app.withdraw_offer()`; booking back to `requested`; edit, then send the next version | `renter_offer_withdrawn`, then `renter_offer_ready` |
| | Send again with a later expiry | Withdraw and send in one action (`resendOffer`); a new version with the same terms | `renter_offer_ready` |
| | Decline | As above | `renter_request_declined` |
| `pending_payment` | Resend the sign and pay link | `resendOfferLink` | `renter_offer_ready` |
| | Withdraw to edit | As above; the signature request is voided. Refused by the database if a payment was already taken: refund first | `renter_offer_withdrawn` |
| | Record payment received another way | Admin only. `recordManualPayment` (e-Transfer): inserts `payments (purpose = 'booking_total', method = 'e_transfer', status = 'succeeded')`. A saved card is still required to confirm, so the renter adds one by SetupIntent | `renter_booking_confirmed` once confirmed |
| `confirmed` | Change booking (section 4.5); Cancel for the renter; Cancel by CarmaCars (100% refund); Mark no-show (after the pickup time); Schedule field job; Take deposit; Blocks calendar switch | See sections 4.5, 4.6, 7.2, 11 | |
| `on_rent` | Extend; Swap vehicle; Open incident; Late-return panel | `05-va.md` section 3 | |
| `returned` | Price findings; Issue statement; Settle deposit; Close | Section 11 | |
| `closed` | Add a later charge (toll, ticket, damage); Reopen is not possible | Section 11.3 | |
| A `reoffer_booking` task | The booking was pushed back because another booking took the car | Offer another car (change the vehicle, send) or decline. If the task is marked "payment taken", refund first (`requestRefund`, reason `carmacars_cancelled`) | `renter_offer_ready` or `renter_request_declined` |

### 4.5 Changing a confirmed booking

A confirmed booking's rates cannot change (`app.booking_before_write()`), and the renter signed specific dates. So a change after confirmation is a recorded change request that the renter agrees to. One table serves a renter's request and a staff proposal: `booking_change_requests` **[new]** (`id, booking_id, requested_by ('renter', 'staff'), status ('requested', 'proposed', 'approved', 'declined', 'applied'), note, before jsonb, after jsonb, lines jsonb, difference_cents, hst_cents, payment_id, refund_id, amendment_document_id, signature_request_id, agreed_by_phone, decided_by, created_at, applied_at`).

| Step | Detail |
| --- | --- |
| 1a. Renter asks | `requestDateChange` from the portal (`02-booking-and-renter.md` section 7.4): `status = 'requested'`. Emits `renter_change_request_received`, `staff_change_request_received` |
| 1b. Staff propose | "Change booking" opens the editor limited to: dates and times, places and methods, vehicle (swap), drivers and extras. `proposeBookingChange` reprices at the booking's stored rates (`app.preview_booking_change()` **[new]**) and saves `status = 'proposed'` |
| 2. Decide | Staff approve a renter's request (`approveChangeRequest`: prices it, `status = 'approved'`) or decline it with a reason (`declineChangeRequest`, emits `renter_change_request_declined`) |
| 3. Renter agrees | For anything that changes dates, car or price: a one-page amendment to the agreement is opened for signature (`documents.kind = 'rental_agreement'`, title "Amendment n"); the renter gets `renter_agreement_ready` and signs at `/account/bookings/[id]/sign` |
| 4. Money | Difference above zero: charged to the Card on File (`purpose = 'extension'`). Below zero: a `refunds` row (`reason = 'other'`, needs approval). Zero: nothing |
| 5. Apply | `app.apply_booking_change()` **[new]** updates the booking, lines and field jobs in one transaction, re-checks availability (the database refuses an overlap with another blocking booking), writes history and audit entries, sets `status = 'applied'`. Emits `renter_change_request_approved`, and the in-app `owner_booking_changed` |
| Staff-only path | When the renter agreed by phone and the difference is zero, an admin may tick "Agreed by phone" (note required); the amendment is emailed for the record and the change applies at once |
| Provisional dates | A confirmed insurer booking with `dates_provisional = true` is the one case the database lets staff correct directly: `app.adjust_booking()` may change its dates and the insurer's authorization, and the price follows (section 7) |
| Vehicle swap after pickup | `swapVehicle` -> `booking_vehicle_swaps`, a `swap_out` and `swap_in` Condition Report by field staff (procedure 10) |

### 4.6 Cancel, no-show

| Button | Fields | Action |
| --- | --- | --- |
| Cancel for the renter | Channel (email, portal), received at (date-time, default now; an email's time counts), reason | `cancelBookingForRenter` -> `booking_cancellations` (tier computed by `app.booking_cancellation_fill()`), status `cancelled`, `refunds` row pending approval |
| Cancel by CarmaCars | Reason (no vehicle, driver not verifiable, pricing error, other) | `cancelBookingByCompany` -> `cancelled_by = 'carmacars'`, 100% refund including non-refundable bookings |
| Mark no-show | Confirm | `markNoShow` -> `no_show`, `booking_cancellations (reason = 'no_show')`, no refund |

Each shows the three times, the tier, the refund and the retained amount before the confirm, from `app.preview_cancellation()`.

### 4.7 Other tabs

| Tab | Content | Actions |
| --- | --- | --- |
| Drivers | Each `booking_drivers` row: age band, accepted, identity status, licence details. ID images open in `DocumentViewer` (every open is written to `data_access_log`) | Verify or reject a driver (`05-va.md` section 4.2); add or remove a driver before pickup (repriced through an adjustment) |
| Agreement | Signature request status, each signer with time, method, IP; the signed PDF and its SHA-256; consents with the exact wording stored | Resend signing link; void and re-issue (reason required) |
| Money | Line items grouped by stage with revenue class chips; payments; deposit card; refunds; statements; split (admin) | Section 11 |
| Condition | Pickup and return reports side by side with photo sets in the fixed order; differences flagged; kilometres, fuel, lateness computed | Mark reviewed (`reviewConditionReport` sets `reviewed_by`, `reviewed_at`); "Add damage found later" (`10-tolls-tickets-damages.md` section 7) |
| Messages | Every `messages` row for the booking, both directions | Send, resend, log a call |
| History | `Timeline` of `status_history`, `audit_log` for the booking and its children | none |

## 5. `/admin/calendar` Master calendar

Engine: `src/features/calendar/`. One timeline, vehicles as rows, time as columns. Data: `app.master_calendar(from, to)` (which reads the view `calendar_entries` and returns a row for every vehicle, with or without entries) for the visible range plus one screen either side, plus `field_jobs` and `turo_trips` fetched separately because the view does not include them; fetched in the browser and kept live by Realtime on `bookings`, `vehicle_calendar_blocks` and `field_jobs`.

### 5.1 Layout

| | Phone | Desktop |
| --- | --- | --- |
| Default view | Day list: today's pickups, returns, cars free, cars blocked, grouped by time. A "Timeline" toggle shows a 3-day horizontal timeline with sticky vehicle names | Timeline, 14 days, one row per vehicle (48 px), sticky left column (fleet number, year make model, plate, status dot) and sticky date header |
| Zoom | Day, 3 days, week | Day (hours), week, 2 weeks, month, quarter |
| Navigation | Swipe; "Today" button; date picker | Arrow keys, `T` for today, date picker, drag the header |
| Detail | Full-screen sheet | `SidePanel` on the right |

### 5.2 What is drawn

| Item | Appearance | Label |
| --- | --- | --- |
| Booking `requested` | Grey diagonal hatch, dashed border, on the pending lane | Renter surname, "request" |
| Booking `offered` | Amber diagonal hatch, solid amber border, on the pending lane; a clock icon with time left | Renter surname, "offer" |
| Booking `pending_payment` | Amber hatch with a filled left edge, on the pending lane | "signing and payment" |
| Booking `confirmed` | Solid black | Renter surname, booking number |
| Booking `on_rent` | Solid red | Same; a late booking pulses its right edge and extends in red stripes to now |
| Booking `returned` | Solid grey | |
| Booking `closed` | Light grey | |
| Pending lane | Requests, offers and bookings awaiting payment never block, so they are drawn on a second lane under the row's blocking items, where several may overlap each other and a confirmed booking. `calendar_entries.calendar_state = 'pending'` | |
| A confirmed or on-rent booking with `blocks_calendar = false` | Outline only, no fill, in the status colour, on the pending lane (`is_blocking = false`) | Adds "not blocking" |
| Insurer booking | A small shield mark; dotted right edge when `dates_provisional = true` | Insurer name (not shown to Sales or owners) |
| Owner Booking | Black outline with an "O" mark | Owner name |
| Calendar block | Diagonal stripes in grey; text is the reason | service, repair, owner, cleaning, exit, admin |
| Turo trip | Thin teal bar (status colour only) | "Turo" |
| Field job | A pin at its time on the vehicle's row | Kind, assignee initials |
| Turnaround buffer | A faint tail after each return of `program_settings.turnaround_buffer_minutes` | |
| Today | A red vertical line | |

Colour is never the only signal: every state also has a pattern or a text label.

### 5.3 Filters and search

Status (multi), vehicle class, owner, management mode, city or home area, "Has conflicts", "Not blocking", "Insurer", "Needs action" (unverified drivers or no deposit within 24 hours of pickup), field staff member. Search by plate, fleet number, booking number or surname jumps to the row and flashes the item. Filters live in the query string, so a filtered calendar can be bookmarked and shared.

### 5.4 Interactions

| Gesture | On | Result |
| --- | --- | --- |
| Click or tap | Any item | Opens the side panel (5.5) |
| Drag sideways (desktop: drag; phone: long-press then drag) | Booking in `requested`, `offered`, `pending_payment`, `confirmed` | Moves both times, snapping to 30 minutes. On drop a confirm dialog shows old and new times, whether the car is free (`app.vehicle_is_available()`), and the re-price (old total, new total, difference) from `app.preview_booking_change()` **[new]**, which uses the same pricing as `app.reprice_booking()` |
| Drag an edge | Same statuses; right edge only for `on_rent` | Resizes; same confirm. For `on_rent` it is an extension |
| Drag to another row | Same statuses | Changes the vehicle; the confirm shows the new car's rates and the re-price |
| Confirm the dialog | | `requested`: `adjustBooking` applies the change at once (`app.adjust_booking()` re-prices). `offered` or `pending_payment`: the dialog says "An offer is out. This withdraws it and sends a new version." and on confirm runs `withdrawOffer`, `adjustBooking`, `sendOffer`. `confirmed`: `proposeBookingChange` (section 4.5); nothing moves until the renter agrees, and the item shows a dashed "proposed" ghost at the new position; a confirmed insurer booking with provisional dates is adjusted at once. `on_rent` resize: `createStaffExtension` (the renter pays before it applies) |
| Cancel the dialog or press Esc | | The item snaps back |
| Drag across empty cells | Vehicle row | Opens "New" with Booking request, Block, Owner Booking pre-filled with the car and range |
| Drag or resize | Block | `updateCalendarBlock` at once after a confirm; refused if it would overlap a blocking booking |
| Double-click (desktop) | Item | Opens the full record |
| Keyboard | Focused item | Arrow keys move 30 minutes, Shift plus arrows resize, Enter opens the confirm, Esc cancels. Every drag action has this keyboard path |

Drops that the database would refuse are stopped before the dialog with the reason: overlap with a blocking item, past the vehicle's Exit Date, over 30 days, vehicle not bookable, driver under 21 on a car not flagged, in the past. Bookings in `returned`, `closed`, `cancelled` cannot be dragged.

### 5.5 Side panel

| For | Shows | Buttons |
| --- | --- | --- |
| Booking | Status, renter, phone, car, times and places, total, paid, deposit state, drivers verified, coverage, field jobs, flags; the "Blocks calendar" switch | Open booking; Message renter; Blocks calendar switch (`setBlocksCalendar`, section 7.2); Schedule field job; the status's primary action |
| Block | Reason, note, created by, range | Edit, End now (sets `ends_at`), Remove (`removeCalendarBlock`: sets `removed_at`, `removed_by`, `removed_reason`; a removed block no longer counts and is never hard deleted) |
| Field job | Kind, assignee, status, place | Reassign (`reassignFieldJob`), open |
| Empty slot | The car's rates and the quote for the selected range | New booking request, New block |

### 5.6 States

| State | Behaviour |
| --- | --- |
| Loading | Row skeletons with the vehicle column filled first |
| Empty fleet | "No vehicles yet." with "Add a vehicle" |
| Realtime lost | Banner "Live updates paused. Reconnecting." Drags are disabled until it returns, to avoid acting on stale positions |
| Large fleet | Rows are virtualized; 200 vehicles by 90 days stays under 16 ms a frame on a mid-range laptop |

## 6. Vehicle calendar and blocks

### 6.1 `/admin/vehicles/[id]/calendar`

The same engine with one row expanded: a month grid on desktop (with a timeline toggle), an agenda list on a phone. It shows everything the master calendar shows for this vehicle, plus: every past booking, cancelled bookings (struck through, toggle), field jobs, tracker access blocks (a thin line when the owner's controls are blocked), exit notice and Exit Date markers, service due notes. The public car page shows only the unavailable ranges from `public_vehicle_calendar`; the owner portal shows dates and statuses without renter details on managed rentals (`04-owner.md` section 5).

### 6.2 Calendar blocks

| Label | Type | Validation | Default | Stored |
| --- | --- | --- | --- | --- |
| Vehicle | select | Required | Current | `vehicle_calendar_blocks.vehicle_id` |
| Reason | select: service, repair, owner unavailable, cleaning, exit, Turo owner use, admin | Required | none | `reason` |
| From | date-time | Required | Selected range | `starts_at` |
| To | date-time, or "Until further notice" | After From | Selected range | `ends_at` (null when open-ended) |
| Note | text | Required for "admin" | Empty | `note` |

Actions: `createCalendarBlock`, `updateCalendarBlock`, `endCalendarBlock`, `removeCalendarBlock` (admins, Fleet and CS write blocks directly under row-level security; the action adds the checks). The database does not check a new block against existing bookings (0016 decision 14), so the action does: it lists confirmed, blocking bookings in the range and asks the user to confirm "Create anyway", which creates an urgent `fleet` task per conflicting booking; it also lists open requests and offers in the range so staff can re-offer another car. A block stops any later offer or confirmation on those dates. Blocks are created automatically when: an incident marks the car not drivable (repair, open-ended), an exit notice sets an Exit Date (exit, open-ended from that date), a return happens (cleaning, until the detail job is done). Emits `owner_vehicle_blocked` for repair and service blocks on managed cars.

## 7. Insurer bookings, the calendar switch and insurer invoices

The owner's requirement: bookings to insurance companies whose dates may not be correct yet must be able to exist without blocking the car, with a switch staff can change. Migration 0016 provides the data and rules (`00-overview.md` section 8); this section is the screens.

### 7.1 Insurer fields on a booking

Shown in the review form when "Bill to" is insurer or split. Saved through `app.adjust_booking()`.

| Label | Type | Validation | Stored on `bookings` |
| --- | --- | --- | --- |
| Insurer | search select of `insurers`, "Add new" inline | Required (the database requires it when `bill_to` is not renter) | `insurer_id` |
| Bill to | radio: insurer pays the rental and the booking fees / split: insurer pays the rental only | Required | `bill_to` |
| Claim number | text | Required before the first invoice is sent | `insurer_claim_number` |
| Adjuster name, email, phone | text, email, tel | Email required before the first invoice is sent | `insurer_adjuster_name`, `insurer_adjuster_email`, `insurer_adjuster_phone` |
| Authorized daily rate | money | Optional. Empty means the insurer pays the rental charge for the authorized days in full | `insurer_authorized_daily_rate_cents` |
| Authorized days | number, 1 or more | Optional | `insurer_authorized_days` |
| Authorized until | date | Optional. Days authorized are the lower of "authorized days" and the rental days that start on or before this date | `insurer_authorized_until` |
| Authorization document | upload | PDF or image | `documents` linked to the booking (`kind = 'other'`, title "Insurer authorization") |
| Dates are provisional | switch | On means the repair shop has not confirmed the dates | `dates_provisional` |
| Blocks calendar | switch with a reason | Section 7.2 | `blocks_calendar` |
| Insurer pays / renter pays | computed, read-only | From `app.booking_insurer_share()`: covered days, rental share, fees share, HST. The renter always pays anything above the authorization, the Deposit and every charge after the rental | `insurer_share_cents`, `insurer_hst_cents`, `renter_due_at_booking_cents` |

The driver is still the renter: they approve the offer (or staff record the approval), sign the agreement and save a card. When `renter_due_at_booking_cents` is 0 the booking is confirmed without a card payment (`confirmInsurerBooking`, after the signature and the saved card); otherwise the renter pays their part and the webhook confirms as usual.

### 7.2 The calendar switch: a booking that does not block the car

| Rule | Detail |
| --- | --- |
| What it is | `bookings.blocks_calendar`. With the switch off a booking can exist in any status, confirmed included, over other bookings, and the car stays bookable and shows as free on the public site |
| Who | Admin, CS and Fleet, with a reason each time; Sales on a `requested` booking only (0016 permissions) |
| Where | The booking header, the review form, the calendar side panel and the insurer list. `setBlocksCalendar(bookingNumber, value, reason)` -> `app.set_blocks_calendar()`. The database refuses a blank reason or the same reason as last time, records who and when on the row, and writes a `calendar_switch` event |
| Turning it on | Runs the same check as confirmation (`app.vehicle_is_available()`). Free: the booking starts blocking, the public calendar updates, and any competing offers on those dates are pushed back to `requested`. Not free: refused with the conflicting bookings listed and three choices: move this booking to another car, change its dates, or leave it not blocking |
| Turning it off | Reason required. Not allowed once the car is handed over (**[new]** guard: `on_rent` requires `blocks_calendar = true`, so a car is never released on a non-blocking booking) |
| Intended use | An insurer booking with `dates_provisional = true`: confirm it with the switch off; when the shop confirms the dates, correct them with `app.adjust_booking()` (allowed on a confirmed booking only while provisional), set `dates_provisional` false, then turn the switch on. The interface offers this as one guided action, "Dates are now final": dates, then the availability check, then the switch |
| On the calendar | Outline only, on a second lane, labelled "not blocking" (section 5.2) |
| Safety net | A daily job (`insurer-provisional-watch`, 08:00, **[new]**) lists confirmed bookings with the switch off whose pickup is within 3 days and creates a `cs` task to settle the dates. The CS morning digest carries the same list |

### 7.3 `/admin/insurers` and `/admin/insurers/[id]`

List: name, open bookings, unpaid invoice total, oldest unpaid in days. Detail: the fields of `insurers` (name, billing contact name, billing email, billing phone, billing address, notes, active), its bookings, its invoices, and adjusters seen on its bookings. Actions: `saveInsurer`, `deactivateInsurer`. CS and Finance may add and edit insurers; Fleet and Sales read.

### 7.4 `/admin/insurer-invoices` and `/admin/insurer-invoices/[id]`

| Item | Detail |
| --- | --- |
| Purpose | Bill the insurer for its part and track payment |
| Creating | `draftInsurerInvoice` -> `app.draft_insurer_invoice(booking)`: drafts from the booking's lines for the insurer's part, less what earlier invoices on the booking already billed; calling it again refreshes the same draft. Only for a confirmed or later booking. A draft is created automatically at Check-in for the final days; an interim invoice can be drafted by hand during a long repair |
| List columns | Invoice number (`INS-...`), insurer, claim number, booking, renter, period, amount, HST, total, paid, balance, status, sent date, days outstanding |
| Detail | Header (CarmaCars legal name, address, HST number; insurer and billing contact; claim number; adjuster; insured driver; vehicle; rental period), `lines` (what the amount is made of, as printed), totals, payments received |
| Buttons | Edit a draft's lines and notes (Finance); Send (`sendInsurerInvoice`: renders the PDF through `render-document`, stores `documents`, emails `insurer_invoice` to the adjuster and the billing contact, sets `sent`, `sent_at`, `sent_by`); Record payment (`recordInsurerPayment` -> `app.record_insurer_payment(invoice, amount, by, method, paid_at, reference)`: `part_paid` or `paid`, and a `payments` row so the books show it); Send reminder (`insurer_invoice_reminder`, also automatic 7 and 21 days after sending while unpaid); Write off (admin only: `written_off` with a reason) |
| Owner payout timing | On a booking billed wholly to the insurer, the rental reaches the owner's statement when the insurer's invoice is paid in full (the function ties the unpaid Owner Revenue lines to that payment). On a split booking the rental line is tied to the renter's card payment. The statement screen lists rentals "awaiting insurer payment" (`11-statements-and-reports.md` section 2.1) |
| Shortfall | When the insurer pays less than invoiced, the balance can be moved to the renter (`transferInsurerBalanceToRenter`: after-return line items and a `later_charge` statement, charged to the Card on File under consent 4), or written off by an admin. After a write-off the unpaid rental never reaches the owner's statement unless an admin chooses "Pay the owner anyway" (reason required), recorded as **[new]** `booking_line_items.covered_by_company_at` |
| No due date in the database | `insurer_invoices` has no terms or due date. The list shows days since `sent_at`; "overdue" in reminders and reports means more than 30 days (a setting, `program_settings.insurer_terms_days` **[new]**) |

## 8. Vehicles

### 8.1 `/admin/vehicles`

Columns: fleet number, photo, year make model, plate, owner, mode, status, listing status, next booking, tracker (last seen), arrears flag, on fleet policy. Filters: status, mode, owner, class, listing status, arrears, tracker silent. Buttons: "Add a vehicle" (-> `/admin/vehicles/new`, the listing pipeline in `09-listing-pipeline.md`), export CSV.

### 8.2 `/admin/vehicles/[id]` tabs

| Tab | Content | Actions |
| --- | --- | --- |
| Overview | Identity (VIN, plate, year, make, model, trim, colour, fuel, class, odometer), status with allowed next statuses, owner, mode, billing case, enrollment and exit dates, flags (`allows_18_to_20`, `bookings_enabled`, `in_arrears`, `on_fleet_policy`), next and current booking | `saveVehicle` (fleet VA cannot change owner, mode or dates: `app.guard_admin_columns()`); `setVehicleStatus` (only transitions in `status_transitions`) |
| Calendar | Section 6.1 | |
| Listing and photos | Listing status, headline, description, features, specs, FAQ, photos with cover and order, pipeline history | Opens the review screen (`09-listing-pipeline.md` section 6); Pause, Unpublish (reason, redirect target) |
| Rates | Current `rate_cards` row and history; fee overrides | Section 8.3 |
| Owner terms | Current `vehicle_schedules` row, `vehicle_fee_history`, prepaid months, invoices for this vehicle | Fee notice (30 days, `source = 'fee_notice'`), new schedule (re-sign) |
| Onboarding | The `vehicle_onboardings` record and checklist (`04-owner.md` section 4, staff side) | |
| Tracker | Device, last reading, map, command log, access blocks | Section 17 |
| Documents | Permit, insurer confirmation, schedules, forms, baseline report | Upload, open |
| Tolls and incidents | Lists filtered to the vehicle | |
| History | `status_history`, `audit_log` | |

### 8.3 Rates form

| Label | Type | Validation | Stored |
| --- | --- | --- | --- |
| Daily rate | money | Above 0 | `rate_cards.daily_rate_cents` |
| Weekend rate (Friday and Saturday) | money | Above 0 | `weekend_rate_cents` |
| Weekly rate | money | Above 0; warn if above 7 times daily or below daily | `weekly_rate_cents` |
| Monthly rate (30 days) | money | Above 0; warn if below weekly | `monthly_rate_cents` |
| Kilometres per day | number | 0 or more | `km_allowance_per_day` |
| Overage per km | money | $0.35 default; $0.75 to $1.50 for luxury and exotic (`fee_defaults` min and max) | `overage_cents_per_km` |
| Deposit | money | Default by class from `fee_defaults` | `deposit_cents` |
| Delivery fee, pickup fee | money | $75 to $200 or 0 for "not offered" | `delivery_fee_cents`, `pickup_fee_cents` |
| Effective from | date-time | Now or later | `effective_from` (the previous row's `effective_to` is set in the same transaction) |

Action `saveRateCard` -> `app.set_rate_card()` **[new]** (closes the old row, opens the new; the exclusion constraint forbids overlap). Existing bookings keep their snapshot. On a Self-Managed vehicle the owner sets rates (`04-owner.md` section 6) and `set_by_owner = true`. After saving, `revalidateTag('vehicle:' + id)` rebuilds the car page.

## 9. Owners and onboarding (staff side)

| Route | Content | Actions |
| --- | --- | --- |
| `/admin/owners` | Name, type, vehicles, status, arrears total, balance carried forward, last statement, HST registered | Add owner (same fields as the owner wizard step 1), export |
| `/admin/owners/[id]` | Tabs: Profile, Vehicles, Agreements and forms, Invoices, Statements, Payouts, Deductions, Banking, Referrals, Messages, History | Edit profile; set `is_shareholder` (admin); add deduction (`addOwnerDeduction`: kind, description, amount, HST on receipt, incurred on, receipt upload; "agreed in writing" needs the agreement document); change bank details (admin only, section 9.1) |
| `/admin/onboarding` | A board of `vehicle_onboardings` by status (intake to enrolled), one card per vehicle with the owner, situation, waiting time and the next action and who owns it | Each card opens the onboarding checklist |

The onboarding checklist, the six situations and the documents are specified once in `04-owner.md` sections 3 and 4, which lists the staff steps beside the owner steps.

### 9.1 Changing a payee's bank details

Admin only (`owner_payout_accounts` is admin-write). The form shows the current last four, takes the new details, requires a "Verified by" method (called the number on file, in person) and a note. `changeOwnerBankDetails` inserts a new `owner_payout_accounts` row (`account_no` encrypted with `FIELD_ENCRYPTION_KEY` in the server action), marks the old one not current, emits `owner_bank_details_changed` to the owner's old and new contact details, and holds any payout to that owner for 24 hours.

## 10. Renters

| Route | Content | Actions |
| --- | --- | --- |
| `/admin/renters` | Search first (name, email, phone, booking number). Admins see the list; VAs do not have this route and use `app.staff_find_renter()` | |
| `/admin/renters/[id]` | Profile, identity status, drivers, card on file (brand, last four), bookings, statements, tolls, messages, consents (with stored wording), marketing status, block flag | Block or unblock (`setRenterBlocked`, reason required), merge duplicate (admin, moves bookings; audit), export this renter's data (privacy request), set a legal hold on their documents |

## 11. Money

### 11.1 `/admin/money/payments`

Columns: date, booking or owner, purpose, kind, method, amount, status, card last four, declines, next retry, dispute. Filters: status, purpose, date range, "unmatched to a payout" (from the `reconcile` job). Row panel: attempts (`payment_attempts`), processor ids and fee (admin only, from `payment_processor_details`), receipt link, related line items. Actions: Retry now (`retryPayment`), Mark paid another way (admin), Refund (opens the refund form).

### 11.2 `/admin/money/deposits`

Columns: booking, renter, amount, method (hold or charged), status, hold expires, applied, held back until, release due, days to due. Filters: due within 2 business days, hold expiring within 48 hours, held back.

| Button | Fields | Action -> database |
| --- | --- | --- |
| Take deposit | Confirm amount and method (computed by `calc_deposit_method()`: hold for 7 days or less, charge for longer) | `takeDeposit` -> payments module places a hold or a charge on the Card on File; `deposits (status = 'held' or 'captured', hold_payment_id, taken_at, hold_expires_at)`, `deposit_events (taken)`. Declined: `status = 'failed'`, the handover checklist blocks, `renter_deposit_declined` is sent, the field staff member sees "Do not release the car" |
| Renew hold | none | Normally the `deposit-holds` job; the button runs it for one deposit |
| Capture | Amount | For an extension past 7 days, or at Check-in for what is owed plus the hold-back |
| Apply to charges | Select unpaid line items | `deposit_events (applied, line_item_id)`; `deposits.applied_cents` |
| Hold back | Amount, reason (pending claim, toll, ticket), until (max 30 days after Check-in) | `held_back_cents`, `held_back_reason`, `held_back_until` |
| Release | Amount = balance | `requestDepositRelease`; within the finance VA's Single Limit it executes, otherwise it waits in approvals (`app.guard_deposit_release()`). `released_cents`, `released_at`, `release_approved_by`; Stripe cancels the hold or refunds the charge |

### 11.3 `/admin/money/charges` Post-rental charges

A queue of `returned` bookings without a `check_in` statement, plus the entry point for later charges.

| Step | Screen | Detail |
| --- | --- | --- |
| 1. Findings | Pre-filled from the return Condition Report and the field job: km out and in, allowance, fuel out and in, cleaning grade, minutes late, keys, new damage | Read-only facts with links to the photos |
| 2. Proposed lines | `app.assess_check_in(booking_id)` **[new]** returns proposed lines using `calc_mileage_overage()`, `calc_late_return()`, `calc_fuel_charge()` (pump cost typed in), cleaning by grade, lost key (cost typed in plus fee), each with its fee term from `booking_fee_terms` | Finance ticks, edits quantities, attaches a supporting document to each line (photo, receipt, estimate). A line without a supporting record cannot be issued |
| 3. Deposit plan | Shows deposit amount, proposed apply, hold-back (amount and reason), release, and what goes to the card | Editable within the rules |
| 4. Issue | `issueBookingStatement` -> `app.issue_booking_statement()` **[new]**: inserts `booking_line_items` (stage `check_in` or `after_return`), `booking_statements (kind = 'check_in')`, deposit events, charges the Card on File for any excess, renders the statement PDF, emits `renter_final_statement` (T9) with the PDF and records. Sets `interest_starts_on` to 7 days later |
| Later charge | "Add a later charge" on a closed booking: one or more lines with records -> `booking_statements (kind = 'later_charge')`, charge the deposit if still held, else the card | Used by tolls and damage flows (`10-tolls-tickets-damages.md`) |
| Declined | The `payment-retries` job adds the $40 line once and retries after 1, 3 and 7 days; `renter_payment_failed` (T10) with a pay link | |
| Void a line | Reason required; `voided_at`, `void_reason`; a credit mirrors the charge; if already paid, a refund is created | |

### 11.4 `/admin/money/refunds`, `/admin/money/disputes`

| Route | Content | Actions |
| --- | --- | --- |
| Refunds | Booking, reason, percentage, amount, status, requested by, approved by, due by (10 business days), paid at | New refund (reason select from the schema; amount; note): `requestRefund`; approve, reject (section 2); retry a failed refund |
| Disputes | Payment, booking, amount, reason, status, evidence due, Owner Revenue withheld | "Build evidence pack" (`buildDisputeEvidence` collects the signed agreement, consents, Condition Reports, tracker proof, statement into `disputes.evidence_document_ids` and one merged PDF); mark submitted; outcome is written by the webhook (`won` or `lost`), which reverses or releases the withheld Owner Revenue through `app.compute_booking_split()` |

## 12. Incidents and claims

Routes `/admin/incidents`, `/admin/incidents/[id]`, `/admin/claims`, `/admin/claims/[id]`. Damage intake and billing to the renter are in `10-tolls-tickets-damages.md` sections 7 to 9. The claim screen:

| Section | Content | Actions |
| --- | --- | --- |
| Header | Claim number, path (at cost, fleet policy, total loss, Turo), status with allowed next statuses, vehicle, owner, booking, shareholder flag | `setClaimStatus` (only allowed transitions; `denied` needs a reason) |
| Damage cost | `incident_costs` not superseded: estimate or invoice, towing, storage, loss of use (days by daily rate, `calc_loss_of_use()`), total from `app.incident_damage_cost()` | Add cost (kind, amount, HST on invoice, shop, approved shop yes or no, document) |
| Ledger | `claim_ledger_entries` in and out with running balance | Add entry (kind, amount, date, document, linked payment or payout) |
| Result | Money in, repair, policy deductible, claim costs, result, owner part, company part (`calc_claim_result()`) | Settle: `settleClaim` -> `app.settle_claim()`; a shareholder vehicle needs a second admin. A shortfall on a third-party vehicle becomes an `owner_deductions (claim_shortfall)` row unless "Caused by CarmaCars" is ticked |
| Total loss | Insurer decision date, settlement, cleared date, lender due, owner owes, balance and its due date (`calc_total_loss()`) | `recordTotalLossSettlement` -> `app.record_total_loss_settlement()`; creates the `payouts (total_loss_balance)` row for approval |
| Owner | T17 sent time; what the owner sees (`owner_claims` view: status only) | Send T17 (`owner_incident_opened`) |

## 13. Owner billing, statements, payouts, reports

| Route | Purpose | Detail in |
| --- | --- | --- |
| `/admin/owner-billing/invoices` | Monthly and upfront invoices per vehicle: status, debit result, Late Fee, retry, arrears | `11-statements-and-reports.md` section 5 |
| `/admin/statements`, `/admin/statements/[id]` | Draft, review, approve the monthly owner statements | `11-statements-and-reports.md` section 2 |
| `/admin/payouts` | Approve and mark paid: owners, prepaid refunds, total-loss balances, claim profit, field staff kickbacks for payroll, investor returns | `11-statements-and-reports.md` section 6 |
| `/admin/reports` | CarmaCars' own monthly statements per vehicle, per owner and in total; exports | `11-statements-and-reports.md` sections 3 and 4 |

## 14. Reviews, promo codes, messages

| Route | Content | Actions |
| --- | --- | --- |
| `/admin/reviews` | Pending first: rating, text, renter, booking, car. Published and hidden tabs | Publish (`publishReview`: `status = 'published'`; the database stamps `published_at`; revalidates the car page and `/reviews`), Hide (`status = 'hidden'`, with a reason from: personal information, abusive, not about the rental; never because it is negative), Reply (`staff_reply`, shown publicly). CS cannot change the rating or the words |
| `/admin/promo-codes` | Code, value, valid dates, uses (from `promo_redemptions`: applied, redeemed, released), source (`manual`, `followup_7d`, `followup_30d`) | Create, deactivate. Fields (`promo_codes`): code (generated or typed, 3 to 40 characters, upper case), description, percent off the rental charge (`percent_bps`) or a fixed amount (`amount_cents`), valid from and until, maximum uses, once per renter, single renter (optional), source. Automatic come-back codes are created per renter by the job (`12-notifications.md` section 7.2). Admins create codes; CS, Sales and Finance read them |
| `/admin/messages` | The outbox and log: queued, sent, failed, suppressed; today's count against the 100 limit; digests | Resend, cancel a queued message, preview a template with a booking's data, edit template subject and body (`message_templates`, versioned) |

## 15. Investors

`/admin/investors` and `/admin/investors/[id]`: admin only; no VA can open them. Detail in `07-investor.md` section 4.

## 16. Staff, settings, audit, jobs

| Route | Content | Actions |
| --- | --- | --- |
| `/admin/staff` | Staff with role, function, active, two-step enrolled, last sign-in, limits | Invite (`inviteStaff`: email, name, type VA or field, function, start date; creates the auth user, `users (status = 'invited')`, `user_roles`, `staff_profiles`; field staff get a `referral_code`); set limits (`single_limit_cents`, `dual_approval_threshold_cents`; both start at 0); End access now (`endStaffAccess`: `staff_profiles.is_active = false`, `users.status = 'suspended'`, all sessions revoked; opens the leaver checklist from the VA hiring package section 8) |
| `/admin/settings/program` | A new dated `program_settings` row: company details, HST number, incident line, privacy officer, opening hours **[new column]**, offer expiry hours (`offer_expiry_hours`), turnaround buffer (keep at 0: 0016 notes that the buffer is not enforced by the table's constraint) | `saveProgramSettings` inserts a row with `effective_from`; never edits history |
| `/admin/settings/fees` | `fee_types` with current `fee_defaults`; set a new default with an effective date; price coverage Option 3 (blocked until an admin confirms legal clearance in a typed confirmation) | `saveFeeDefault` |
| `/admin/settings/holidays` | Ontario statutory holidays by year | `saveHolidays` |
| `/admin/settings/templates` | Agreement and form PDF templates with versions (`08-forms.md` section 9); email templates | Upload a new version, set current |
| `/admin/settings/quick-replies` | Snippets for staff messages | CRUD |
| `/admin/audit` | Search `audit_log` by table, record id, actor, date; before and after shown as a field diff. `data_access_log` tab | Read only; export CSV (admin) |
| `/admin/jobs` | `job_runs`: job, run key, status, started, finished, summary, error | "Run now" for a missed day (calls the wrapper with the intended instant; the run key stops a second run) |

## 17. Tracker and the fleet report

### 17.1 `/admin/tracker`

Map of all vehicles with the last reading (from `tracker_status`; the map tiles load only on this staff route). List: vehicle, last seen, speed, ignition, engine enabled, locked, tamper alert, current booking. Actions on a vehicle: Locate, Lock, Unlock, Alarm (`requestTrackerCommand` -> `tracker_commands`, executed by the tracker module); **Disable engine**:

| Step | Rule |
| --- | --- |
| Request | Fleet VA or admin: grounds (`reason_code`), reason in words, T14 notice time where the agreement requires one hour's notice |
| Reading | The server reads the tracker now and stores `observed_at`, `observed_speed_kmh`, `observed_ignition_on` and a screenshot document |
| Approval | An admin approves (`approveTrackerDisable`). The database refuses unless the approver is an admin, the reading is under 5 minutes old, speed is 0 and the ignition is off (`app.guard_tracker_command()`) |
| Send | The module sends the command; `status = 'sent'`, then `confirmed` or `failed` from the webhook. Emits `renter_vehicle_disabled` (T15) |
| Re-enable | One tap, any staff member, reason `safety_re_enable`; no approval |

### 17.2 `/admin/fleet-report`

The monthly franchisor report (procedure 20): `fleet_reports` and `fleet_report_vehicles` built by `app.build_fleet_report()`. Screen: count against the minimum, list with added and removed, "Matches the broker's list" yes or no with differences, Send (`sendFleetReport`: renders the PDF, emails `franchisor_fleet_report` with a copy to the admins, sets `sent`). Weekly recounts from `fleet_counts`.

## 18. Database additions needed

Migration 0016 already provides requests, offers, the calendar switch, insurer billing and invoices, promo codes, reviews and the calendar functions.

| Addition | Purpose |
| --- | --- |
| `booking_change_requests` (section 4.5), `app.preview_booking_change(p_booking uuid, p_changes jsonb) returns jsonb`, `app.apply_booking_change(p_change uuid, p_by uuid)` | Changes to a confirmed booking; calendar drag previews |
| `bookings.request_details jsonb`, `bookings.awaiting_renter_since timestamptz` | The request as sent; the "waiting on the renter" state |
| Guard that `on_rent` requires `blocks_calendar = true`; job `insurer-provisional-watch` | Section 7.2 |
| `booking_line_items.covered_by_company_at`; `program_settings.insurer_terms_days` | Section 7.4 |
| `calendar_entries` to include field jobs and Turo trips, or two small views `calendar_field_jobs`, `calendar_turo_trips` with the same visibility rules | Master calendar pins and Turo bars |
| `app.assess_check_in(p_booking uuid) returns jsonb`, `app.issue_booking_statement(p_booking uuid, p_lines jsonb, p_deposit_plan jsonb, p_by uuid)`, `app.settle_deposit(p_deposit uuid, p_plan jsonb, p_by uuid)` | Section 11 |
| `app.set_rate_card(p_vehicle uuid, p_rates jsonb, p_from timestamptz, p_by uuid)` | Section 8.3 |
| `program_settings`: `opening_hours jsonb` | Sections 1, 3, 16 |
| `quick_replies (id, title, body, audience, created_by)` | Section 4.3 |
| Job function not yet written: `deposits-due` (`holds-expire` was replaced by `carmacars-offers-expire` in 0016) | `docs/architecture.md` section 5 |
| A status for a review rejected for cause is not needed: `reviews.status` has `pending`, `published`, `hidden` | Section 14 uses `hidden` |
| Realtime publication on `bookings`, `vehicle_calendar_blocks`, `field_jobs`, `tasks`, `notifications` (row-level security applies to Realtime) | Live calendar and queues |
