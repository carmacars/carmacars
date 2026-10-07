# 0016: request to book

Migration `supabase/migrations/0016_request_to_book.sql`, tests `supabase/tests/06_request_to_book.sql`.

The booking model changes from "hold the car, pay, confirmed" to "request, offer, approve, sign and pay". This file is the full record of the change: what was added, how it behaves, what was decided where the brief left a choice, and what the shared documents still need. Nothing in `docs/data-model.md`, `docs/permissions.md`, `docs/architecture.md` or `README.md` was edited.

## 1. The flow

```
requested ──▶ offered ──▶ pending_payment ──▶ confirmed ──▶ on_rent ──▶ returned ──▶ closed
    ▲            │  │            │
    └────────────┘  │            │      requested, offered, pending_payment ──▶ declined
    └───────────────┼────────────┘      Owner Booking: requested ──▶ pending_payment (no offer, nothing to pay)
```

| Status | Meaning | Blocks the car |
| --- | --- | --- |
| `requested` | The renter has asked, or the request is back with staff. No payment, no card | No |
| `offered` | An offer (a numbered version) is with the renter | No |
| `pending_payment` | The renter approved the current offer; signing and payment in progress | No |
| `confirmed` | Signed and paid | Yes, when `blocks_calendar` is true |
| `on_rent` | Handed over | Yes, when `blocks_calendar` is true |

Rules the database enforces (trigger `app.booking_before_write()`, replaced in this migration):

- A booking becomes `offered` only when an offer row for its current version exists with status `sent`. Offers are written by the server only.
- `offered` to `pending_payment` needs that offer approved (`booking_offers.status = 'approved'` for the current version). Typing an approval into the booking row is not enough.
- A standard booking cannot go from `requested` to `pending_payment`. An Owner Booking can: it has nothing to pay, so it goes to signing without an offer.
- While an offer is out (`offered` or `pending_payment`), the terms on the booking cannot change. Staff withdraw the offer first (back to `requested`), change it, and send a new version.
- `confirmed` needs the signed agreement, the payment and a saved card as before, and now also a free car (section 3).
- Going back to `requested` clears the approval and the offer deadline.

Status transitions added to `status_transitions`: `requested` to `offered`, `pending_payment` (Owner Booking only) and `declined`; `offered` to `pending_payment`, `requested` and `declined`; `pending_payment` to `requested`.

**Nothing was removed from `status_transitions`.** The rows that start at `tentative` stay, for two reasons: the existing tests in `03_flows.sql` walk `tentative` to `pending_payment` to `confirmed`, and a record imported in the old shape must still be able to move. Their notes now start with "old flow (before request to book)". `tentative` stays in the enum because a value cannot be dropped. No function in this migration puts a booking into `tentative`, and a booking written with no status now starts as `requested`. `pending_payment` to `expired` also stays, unused by the new functions.

### Functions of the flow (server role only)

| Function | Does |
| --- | --- |
| `app.request_booking(renter, vehicle, pickup, return, type, note, source, created_by, referred_by, promo_code, pickup_method, return_method, pickup_place, return_place)` | Creates the request, priced from the rate card in force, with its charge lines, a history entry and a task for customer service. Also the staff path (phone, email, WhatsApp) and the Owner Booking path |
| `app.adjust_booking(booking, by, changes jsonb, note)` | Staff change a request: vehicle, dates and times, rates, rental charge, staff discount, Deposit, mileage, delivery or pickup, notes, who is billed and the insurer's authorization. Everything that follows (days, rate applied, rental charge, non-refundable discount, mileage total, lines, totals) is worked out again. Each call is kept in the history with the changes |
| `app.reprice_booking(booking)` | Brings the price lines and totals in step with the booking. Called by the functions above; HST is per line and the totals are the sum of the lines |
| `app.send_offer(booking, sent_by, message, expires_at)` | Sends the next offer version and returns its number. Refused when the car is not free for the dates |
| `app.approve_offer(booking, version, by, now)` | The renter (or staff on the renter's word) approves. A version that is not the current one, or an expired one, is refused |
| `app.request_offer_change(booking, by, note)` | The renter asks for a change: back to `requested` with the note, and a task for customer service |
| `app.decline_booking_request(booking, by, note)` | The renter declines or withdraws, or CarmaCars refuses: `declined` |
| `app.withdraw_offer(booking, by, note)` | Staff take an offer back to change it |
| `app.set_blocks_calendar(booking, blocks, by, reason)` | The calendar switch |
| `app.expire_offers(now)`, `app.job_offers_expire(now)` | Offer expiry and its scheduled wrapper |

### Offer versions

`booking_offers` holds one row per version sent: who sent it, when, the expiry, the message to the customer, the vehicle, dates, rental charge, discounts, Deposit, subtotal, HST, total, the insurer's part and what the renter owes, plus `terms` (every other term as JSON) and `line_items` (the charge lines as sent). A sent offer cannot be rewritten (trigger); only its status and the answer to it change. Statuses: `sent`, `approved`, `change_requested`, `declined`, `expired`, `superseded` (replaced by a later version), `withdrawn` (taken back by staff, or by the system when another booking took the car).

`booking_events` is the readable history of a request: requested, adjusted (with the changes), offer sent, approved, change requested, declined, withdrawn, expired, pushed back, calendar switch, promo code applied or removed. Each row says who (renter, staff or system). It is append-only.

### When a booking is confirmed

Every other booking on the same vehicle that is `offered` or `pending_payment`, has `blocks_calendar` true and overlaps the dates is moved back to `requested`. Its open offer is marked `withdrawn` with the reason, a system note goes in its history, and customer service gets a `reoffer_booking` task. If a payment had already been taken on it, the task is urgent and says so. A plain request, a booking on other dates and a booking whose switch is off are left alone. The same happens when a calendar switch is turned on or a blocking booking is moved.

### Offer expiry

- `program_settings.offer_expiry_hours`, default 24. `app.send_offer()` takes an expiry for one offer.
- **Decision: an expired offer goes back to `requested`, not to `expired`.** Reason: `expired` is a dead end, so staff would have to re-enter the booking to offer it again. Back in `requested`, everything staff worked out stays, and one call sends it again. The offer row is marked `expired`, the history gets a system note, and customer service gets an `offer_expired` task to follow up or decline. The cost is that a request nobody wants any more stays open until staff decline it.
- `app.job_offers_expire()` is scheduled with pg_cron every 5 minutes as `carmacars-offers-expire`, in the pattern of migration 0015 (nothing is scheduled where pg_cron is absent). It records a run in `job_runs` only when it has something to expire, keyed by the minute. It replaces the `holds-expire` job that 0015 listed as not written: there are no holds any more. `tentative_hold_minutes` is no longer used.
- A booking in `pending_payment` does not expire. The offer was answered in time; nothing in the brief sets a deadline for signing and payment. It does not block the car, and it is sent back to `requested` if another booking takes the dates.

### Owner Bookings

Request (by the Owner, or by staff for the Owner), then `pending_payment` while the agreement is out for signature, then `confirmed` once it is signed. No offer, no payment, no card, no charge line. It blocks the car like any confirmed booking and is refused if the car is not free.

## 2. Calendar blocking switch

`bookings.blocks_calendar boolean not null default true`.

- The table's exclusion constraint is now `bookings_no_double_booking`: one booking per vehicle per moment among `confirmed` and `on_rent` bookings with the switch on. (Before, `tentative` and `pending_payment` also counted.)
- With the switch off a booking can exist in any status, confirmed included, over other bookings.
- Turning it on runs the same check as confirmation and is refused if the car is not free.
- Every flip needs who and a reason for this change (a blank reason, or the same reason as last time, is refused). The row keeps the last who, why and when; `booking_events` keeps every flip; `audit_log` keeps before and after.
- Staff flip it through `app.set_blocks_calendar()` or, in the portal, by updating the row with a reason. In a browser session the "who" is always the signed-in user, whatever is typed.

## 3. Availability and calendars

| Object | For | Notes |
| --- | --- | --- |
| `app.vehicle_is_available(vehicle, from, to, ignore_booking default null)` | Anyone | True when no confirmed or on rent booking with the switch on overlaps (with `program_settings.turnaround_buffer_minutes` on each side, which already existed and is 0) and no calendar block that has not been removed overlaps |
| `app.public_vehicle_calendar(vehicle, from_date, to_date)` | Anyone, anonymous included | The unavailable stretches only, merged, as times and Toronto dates. No booking, person or reason. Answers only for a car on the public listing. At most 366 days |
| `calendar_entries` (view) | Staff and Owners | One row per booking (every status) and per calendar block. `calendar_state` is `pending` (requested, offered, tentative, pending_payment), `booked`, `out`, `done`, `void` or `blocked`. `is_blocking` says whether the entry keeps the car |
| `app.master_calendar(from, to)` | Staff and Owners | The entries touching the range, and a row with no entry for a vehicle that has none, so every vehicle is on the calendar |

Who sees what on the master calendar: admins and assistants in customer service, finance or fleet see everything, with the renter's full name, the insurer and the internal note. A sales assistant sees every entry with the renter's first name only. An Owner sees the entries of their own vehicles with the renter's first name only, no insurer and no note. Renters, field staff and the anonymous role see nothing.

The two public things are functions, not views, so the anonymous role still has select on exactly one object (`public_vehicle_listings`), as `04_rls.sql` asserts.

**Calendar blocks.** The table and its policies already let fleet and customer service assistants (and admins) create and edit blocks. Removing was not possible, because nobody deletes from a browser session. Added `removed_at`, `removed_by`, `removed_reason`: a block is removed by marking it, and a removed block no longer counts. `removed_by` must be the signed-in user.

## 4. Billing an insurer

- `insurers`: name (unique), billing contact, email, phone, address, notes.
- On `bookings`: `bill_to` (`renter`, `insurer`, `split`), `insurer_id`, `insurer_claim_number`, `insurer_adjuster_name`, `insurer_adjuster_email`, `insurer_adjuster_phone`, `insurer_authorized_daily_rate_cents`, `insurer_authorized_days`, `insurer_authorized_until`, `dates_provisional`, and the worked-out `insurer_share_cents`, `insurer_hst_cents` and `renter_due_at_booking_cents` (generated: total due at booking less the insurer's part).
- The driver is still the renter: they approve the offer (or staff record it), sign the agreement, and a saved card is still required.
- When the renter owes nothing at booking, the booking is confirmed without a card payment.

How the insurer's part is worked out (`app.booking_insurer_share()`):

| | The insurer pays | The renter pays |
| --- | --- | --- |
| `bill_to = 'insurer'` | The rental charge (after discounts) for the days it authorized, at no more than the daily rate it authorized; and the other fees charged at booking | Any rental amount above the authorization, the Deposit, every charge after the rental |
| `bill_to = 'split'` | The rental charge up to the authorization only | The fees charged at booking as well |

Days authorized are the lower of `insurer_authorized_days` and the rental days that start on or before `insurer_authorized_until`. With days but no daily rate, the insurer pays that fraction of the rental charge. With nothing limited, it pays all of it. HST follows each part.

**Provisional dates.** A booking with `dates_provisional` true and the switch off can be confirmed without blocking the car. While it is confirmed and provisional, `app.adjust_booking()` may correct the dates and the insurer's authorization (nothing else), and the price follows. Setting `dates_provisional` false in that call makes them final; staff then turn the switch on.

**Insurer invoices.** `insurer_invoices`: number (`INS-` and a sequence), booking, insurer, claim number, period, amount, HST, total and balance (generated), status (`draft`, `sent`, `part_paid`, `paid`, `written_off`), `sent_at`, `paid_cents`, `paid_at`, payment reference, write-off fields, document reference, and `lines` (what the amount is made of).

- `app.draft_insurer_invoice(booking, by)` drafts the invoice from the booking's lines for the insurer's part, less what earlier invoices on the booking already billed. Calling it again refreshes the same draft. Only for a confirmed (or later) booking.
- `app.record_insurer_payment(invoice, amount, by, method, paid_at, reference)` records a receipt: part paid or paid. Each receipt is also a row in `payments` (purpose `other`, method bank transfer or e-Transfer), so the books show everything collected. When an invoice on a booking billed wholly to the insurer is paid in full, the booking's unpaid Owner Revenue lines are tied to that payment. That is what lets the rental reach the Owner's statement, under the existing rule that a rental counts once it is collected.
- Finance assistants read invoices, correct a draft and mark it sent. Paid amounts are recorded by the server; a write-off is an admin's.

## 5. Promo codes and reviews

**Promo codes.** `promo_codes`: code (unique, capitals), a percentage (`percent_bps`) or a fixed amount (`amount_cents`), valid window, `max_uses`, `once_per_renter`, optional `renter_id`, `source` (`followup_7d`, `followup_30d`, `manual` or any other campaign name; not restricted, so the email work can add sources), `is_active`. `promo_redemptions`: one row per booking, with the discount and a status of `applied` (on a request or offer; counts as a use), `redeemed` (the booking was confirmed) or `released` (the booking was declined, or the code taken off; the use is given back).

- `app.promo_code_problem(code, renter, booking, at)` says why a code cannot be used, or null: not known, not active, not valid yet, expired, issued to another customer, used up, already used by this customer, nothing to discount.
- `app.apply_promo_code(booking, code, by)` checks and applies it to a request or an open offer and returns the discount. On an open offer it issues the next offer version at once, with the same expiry, so the renter approves the price they see.
- `app.remove_promo_code(booking, by)` for staff.
- The discount is stored in `bookings.promo_discount_cents` and as a `promo_discount` charge line. It comes off the rental charge only, after the non-refundable and staff discounts, never off fees, the Deposit or tax. A percentage follows the rental charge if staff change the booking. One code per booking.

**Who bears the discount.** The existing rule was read from the code and kept: `discount_cents` becomes a negative `non_refundable_discount` line classed as Owner Revenue, and `app.compute_booking_split()` adds it to the rental charge before the kickback, Owner Revenue and the Revenue Share are worked out. The two new discounts (`promo_discount`, `staff_discount`) are handled the same way: `compute_booking_split()` is recreated here word for word with those two charge types added to the rental charge. So a discount lowers Owner Revenue, and **the Owner and CarmaCars share it in the proportion of the split**: on a 65/35 car a $60 code costs the Owner $39 and CarmaCars $21. On a Self-Managed car (Revenue Share 0) the Owner bears all of it; on a shareholder car it is 90/10. A Referral Kickback is also worked out on the lower rental charge. If CarmaCars should instead absorb its own promo codes, that is a change to the split, not made here.

**Reviews.** `reviews`: booking (one per booking), renter, vehicle, rating 1 to 5, title, body, status (`pending`, `published`, `hidden`), staff reply, `published_at`. `app.submit_review(booking, by, rating, title, body)` accepts a review only from the renter of a closed booking (not an Owner Booking), once; the table's own trigger enforces the same. `app.public_reviews(vehicle, limit, offset)` returns published reviews to anyone, with the reviewer's first name and the month only. Customer service publishes, hides and replies, and cannot change the renter's rating or words.

## 6. Permissions

| Data | Admin | VA Finance | VA Fleet | VA CS | VA Sales | Field | Owner | Renter | Anonymous |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Offers (`booking_offers`) | R | R | R | R | R | none | none | own, R | none |
| Request history (`booking_events`) | R | R | R | R | R | none | none | none | none |
| Insurers | RW | RW | R | RW | R | none | none | none | none |
| Insurer invoices | RW, write off | R, edit draft, mark sent | none | none | none | none | none | none | none |
| Promo codes | RW | R | none | R | R | none | none | none | none |
| Promo code use | R | R | none | R | R | none | none | own, R | none |
| Reviews | RW | none | none | R, moderate | none | none | none | own, R | published, by function |
| Master calendar | all | all | all | all | all, first names | none | own vehicles, first names | none | none |
| Public calendar, is a car free | yes | yes | yes | yes | yes | yes | yes | yes | yes |
| Calendar switch | W with reason | none | W with reason | W with reason | on a request only, with reason | none | none | none | none |

- Row-level security and the `admin_all` policy are on all seven new tables; `app.attach_audit()` was called, so all seven are audited.
- `booking_offers`, `booking_events` and `promo_redemptions` have no insert or update privilege for a browser session at all: they are written by the server's functions.
- Every function that changes a booking's state, prices it, uses a code, files a review or records money is executable by `service_role` only. A browser session may call `app.vehicle_is_available()`, `app.public_vehicle_calendar()`, `app.public_reviews()` (anonymous too) and `app.master_calendar()` (signed in).
- Columns of the flow that a browser session may change only as an admin: staff discount, promo code and discount, offer version, expiry and approval.
- Bookings policies were recreated so that customer service may enter a `requested` booking and the sales role works on `requested` and `offered` as it did on quotes. `app.va_sees_renter()` counts requests and offers as live work. `owner_bookings` does not list a request or an offer (as it did not list a quote) and shows the rental charge after every discount. `renter_bookings` gained the request, offer and who-pays columns at the end.

## 7. Objects added

**Tables (7):** `insurers`, `promo_codes`, `promo_redemptions`, `booking_offers`, `booking_events`, `reviews`, `insurer_invoices`. The schema now has 108 tables.

**Columns:** on `bookings`: `requested_at`, `request_note`, `current_offer_version`, `offer_expires_at`, `offer_approved_version`, `offer_approved_at`, `offer_approved_by`, `staff_discount_cents`, `staff_discount_reason`, `promo_code_id`, `promo_discount_cents`, `blocks_calendar`, `blocks_calendar_changed_at`, `blocks_calendar_changed_by`, `blocks_calendar_reason`, `bill_to`, `insurer_id`, `insurer_claim_number`, `insurer_adjuster_name`, `insurer_adjuster_email`, `insurer_adjuster_phone`, `insurer_authorized_daily_rate_cents`, `insurer_authorized_days`, `insurer_authorized_until`, `dates_provisional`, `insurer_share_cents`, `insurer_hst_cents`, `renter_due_at_booking_cents`. On `vehicle_calendar_blocks`: `removed_at`, `removed_by`, `removed_reason`, `updated_at`. On `program_settings`: `offer_expiry_hours`.

**Other:** enum values `requested` and `offered`; charge types `staff_discount` and `promo_discount`; sequences `booking_number_seq` and `insurer_invoice_number_seq`; view `calendar_entries`; views `renter_bookings` and `owner_bookings` replaced.

**Functions replaced** (same name, from earlier migrations): `app.booking_before_write()` (0011), `app.resolve_referrer()` (0007; the referrer may still be set on a request or offer), `app.compute_booking_split()` (0007; the two new discounts), `app.va_sees_renter()` (0012).

**Functions added:** the ones in the tables above, and the helpers `app.user_is_admin()`, `app.user_is_staff()`, `app.is_booking_renter()`, `app.log_booking_event()`, `app.set_price_line()`, `app.issue_offer()`, `app.close_offer()`, `app.promo_discount_cents()`, `app.booking_insurer_share()`, and the trigger functions `app.booking_request_after()`, `app.guard_booking_offer()`, `app.guard_review()`.

## 8. Existing tests that were changed

| File | Test | Change | Reason |
| --- | --- | --- | --- |
| `03_flows.sql` | "B a vehicle holds only one live booking for any moment" | Moved to after the first booking is confirmed, and the second booking is inserted as `confirmed` instead of `tentative`. Renamed "only one confirmed booking" | It encoded the old rule that a hold blocks the car. A hold or request no longer blocks; the table still refuses two blocking bookings |
| `03_flows.sql` | "CAT owner revenue is exactly ..." | The expected list now includes `promo_discount` and `staff_discount` | Two new discount lines on the rental charge, classed as Owner Revenue like the existing discount |
| `05_jobs.sql` | "J without pg_cron ... the five jobs" | Expects 6 jobs where pg_cron is present | `carmacars-offers-expire` is scheduled by this migration |

No other existing test was touched; all of them pass.

## 9. Assumptions and decisions to confirm

1. **Expired offers go back to `requested`** (section 1), and a booking waiting for signature and payment never expires on its own.
2. **`declined` is the one end state for a request that does not go ahead**, whoever said no (the renter declining an offer, the renter withdrawing, CarmaCars refusing). The history says who. `cancelled` keeps its meaning for confirmed bookings, with its tiers and split.
3. **A change or decline after payment is refused** until the payment is refunded. The one exception is the system pushing a paid, unsigned booking back when another booking is confirmed first; staff get an urgent task.
4. **Only an admin gives a staff discount or types a rental charge by hand.** This follows the existing rule that discounts and per-booking prices are an admin's decision. Any assistant may change rates, Deposit, mileage, dates and the vehicle on a request, as assistants could on a quote before.
5. **Who may send an offer or record an approval:** any active admin or virtual assistant. The renter approves their own offer; staff may record an approval the renter gave by phone, and the history shows it was staff.
6. **An offer cannot be sent, or approved, for dates on which the car is not free** (unless the booking's switch is off). Staff change the car or the dates first.
7. **Insurer billing rules** in section 4: what `insurer` and `split` each cover, how "authorized until" counts days (rental days that start on or before that date), and that a saved card is still required from the driver.
8. **Insurer receipts are rows in `payments`.** The renter can see payments on their own booking under the existing policy, so the driver sees that the insurer paid and how much.
9. **On a split booking** the rental line is tied to the renter's card payment, so the Owner's statement treats the rental as collected when the renter pays, whether or not the insurer has paid yet. A booking billed wholly to the insurer waits for the insurer. Changing this needs the rental line divided in two.
10. **The discount is shared by the Owner and CarmaCars** (section 5). On a Self-Managed car a CarmaCars promo code comes entirely out of the Owner's revenue. This follows the existing rule and should be confirmed.
11. **Promo discount order:** after the non-refundable and staff discounts. One code per booking; a new code replaces the old one.
12. **Booking numbers** made by `app.request_booking()` are `CC-` and a sequence starting at 10001. No format was specified anywhere.
13. **Reviews:** the public month is the month the review was written. Owners have no table access to reviews; they read the public function.
14. **Calendar blocks are not checked against existing bookings** when created, and creating one does not push offers back. A block stops a later confirmation and a later offer.
15. **A direct status edit by an assistant** from `offered` or `pending_payment` back to `requested` is refused (it would clear admin-only columns); it goes through the server's functions. A direct edit to `declined` works and closes the open offer.
16. **The turnaround buffer** is applied by the availability functions and the confirmation check, not by the table's exclusion constraint. It is 0, so the two agree. If it is ever set above 0, two confirmations racing for back-to-back slots inside the buffer could both pass.
17. **Enum values and one transaction.** A new enum value cannot be used in the transaction that adds it. Views, policies, indexes, SQL-language functions and the column default therefore compare `status::text`; the plpgsql functions use the values normally. The migration applies in one transaction, as `scripts/test.sh` runs it.

## 10. Not done, or not verified

- **pg_cron is not installed where the tests run**, so the `cron.schedule` call for `carmacars-offers-expire` was not executed. The block is the same shape as migration 0015's. The wrapper function itself is tested.
- **The shared documents are out of date** and were left alone as instructed: `README.md` (15 migrations, five test files, 101 tables), `docs/data-model.md` (booking flow, table list), `docs/permissions.md` (role matrix; "the anonymous role can read one view" should mention the three public functions), `docs/architecture.md` section 5 (`holds-expire` should become `offers-expire`).
- **Calling the public functions from the browser** needs the `app` schema exposed in the Supabase API settings, or thin wrappers in `public`. That is an app decision; nothing here depends on it.
- **No emails or messages** are sent by this migration. The functions leave tasks and history rows; the app sends the offer, the reminder and the "car was taken" message.
- **Turo trips** are not on the master calendar.
- **Fee lines other than delivery and pickup** (young driver, additional driver, coverage sold and so on) are still entered by the app or staff as before; `app.reprice_booking()` adds them into the totals but does not create them.
- **Refunds** for a paid booking that is pushed back are not automated: staff get the task.
