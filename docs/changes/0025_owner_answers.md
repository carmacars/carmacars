# 0025: the owner's answers

Migration `supabase/migrations/0025_owner_answers.sql`, tests `supabase/tests/13_owner_answers.sql` (104 assertions). The owner answered every open question; this migration applies the answers. No earlier migration was edited. Functions created again keep their signatures; each change is marked `0025` in the code.

## 1. Vehicle swap: revenue follows the car

**Segments.** `app.booking_segments(booking)` cuts a booking into one segment per car the renter actually had, by time, from `booking_vehicle_swaps`. A swap is a segment boundary only when it happened after the pickup time (a change of car before pickup moves the whole booking, see below). The first segment carries the booking's snapshot (Owner, management mode, Revenue Share); each later segment carries the replacement car's terms as they stood at the swap, kept on the swap row (`to_owner_id`, `to_management_mode`, `to_company_share_bps`, `to_is_shareholder`, filled by the trigger `booking_vehicle_swaps_terms` through `app.vehicle_split_terms()`).

**Billable days per segment (the rule).** The whole days (Toronto clock) completed before a swap belong to the car swapped out; the day in which the swap happens, and every day after it, belong to the replacement car: "the day of the swap counts for the new car". The segments always add up to the booking's billable days. A swap 23 hours into a rental therefore gives the whole first day to the new car.

**What goes where** (`app.booking_line_allocation`, cumulative weights cut by `app.cut()`, so the parts of any amount add up to it exactly):

| Line | Car |
| --- | --- |
| Rental charge and its discounts (non-refundable, staff, promo) | Shared by billable days of each car |
| Extra days after a late return | The car the rental ended on |
| Mileage overage | The car on which the kilometres over the allowance were driven: the allowance is used up in the order the cars were driven, from the pickup, swap-out, swap-in and return odometers (`app.segment_overage_km`). The last car when a reading is missing |
| Any line with `booking_line_items.arose_vehicle_id` | That car (staff or the assessment may pin a line) |
| Every other line (company fees, pass-through) | The last car |

Refunds follow their line. Amounts that belong to the booking as a whole (collected, refunded, charged back, withheld in a dispute) are shared in proportion to each car's Owner Revenue before refunds.

**Split.** `booking_splits` now has one row per booking and car (primary key `booking_id, vehicle_id`; new `segment_days`, `segment_starts_at`, `segment_ends_at`). `app.compute_booking_split()` works out the kickback on the whole rental charge (one `referral_kickbacks` row per booking, as before), shares it in proportion to each car's rental charge, and applies 0007's split to each part with that car's Owner and Revenue Share. A part already paid out is not rewritten: the Owner's share of a later refund or chargeback becomes a deduction on that Owner's next statement, per car. A booking that stayed on one car gets exactly the split of 0016 and 0021 (every existing statement test passes, including the worked owner month of $1,922.25).

**Statements and reports.** `app.build_owner_statement()` also recomputes bookings with a segment on the Owner's cars and dates each rental line from the segment's start; `app.approve_owner_statement()` marks only that Owner's part as paid out; `app.sync_later_owner_revenue()` credits later Owner Revenue per car; `app.company_month_lines()` shares each line between the cars as the split does, so CarmaCars' statement per vehicle and per owner (and the reconciliation checks) use the segments; `app.build_company_statement()` counts each car's billable days of its segment; `app.vehicle_month_days()` counts rented time per car from the segments, so utilization follows the car; the `owner_bookings` view shows each Owner their own part.

**Moving a confirmed booking to another Owner's car.** 0019's change flow and 0020's calendar refused it. Now `app.preview_booking_change()` and `app.calendar_preview_change()` refuse only an Owner Booking leaving its Owner's cars, and `app.booking_before_write()` gives a confirmed booking moved to another car (before pickup, with the renter's agreement through the change request, or an Admin recording it on the calendar's insurer path) that car's Owner, management mode and Revenue Share. Its stored rates stay. The whole booking becomes one segment on the new car.

Worked example (tested): 4 days at $100 Monday to Friday, swapped Wednesday 13:00 from a 35% car to another Owner's 20% car, a $35 overage without readings and a $100 late day, referred by an Owner: kickback $100 shared $40 and $60; first Owner $160 Owner Revenue, $56 to CarmaCars, $104 paid; second Owner $275, $55, $220. Both statements, the referrer's kickback line and CarmaCars' statement (per car, per Owner, reconciled) tie; utilization 2.13 and 1.88 days.

## 2. Expired offers

`app.expire_offers()` now closes the request: the offer is `expired`, the booking `expired` (its deadline cleared), the history gets `offer_expired` (which sends `renter_offer_expired` once per offer version, 0023), and `app.raise_task('offer_expired', ...)` gives customer service a task from its `task_rules` row (one per offer version). 0016's behaviour (back to `requested`) is replaced. New `app.reopen_expired_request(booking, by, note)`: staff only, `expired` to `requested` (new status transition; `offered` to `expired` is added too), history kind `reopened`, the task resolved; then the normal offer flow. The email catalogue (`emails/src/emails/renter_offer_expired.mjs`, rebuilt) and `notification_catalogue.trigger_text` describe the new event.

## 3. Timing

| Answer | Where |
| --- | --- |
| Minimum notice 2 hours | `booking_min_notice_minutes = 120` (was already 120), enforced by `app.submit_booking_request` |
| Turnaround 2 hours | `turnaround_buffer_minutes = 120` on every dated row and as the column default. `app.vehicle_is_available()` applies it on both sides of every confirmed or on-rent booking, so availability, the public calendar, quotes and search, `send_offer` and `approve_offer`, confirmation (`finalize_booking`), calendar moves, change requests, extensions and swaps all apply it |
| Always open | `opening_hours.always_open = true`: `app.add_opening_minutes()` (created again) counts every minute. `open` and `close` (09:00 and 18:00) stay as the times of the daily opening and closing checks of 0020's ops-watch job. Site: `opening_hours_text` "Open 24 hours", `handover_any_time` true, no fixed slots |
| Deposit 1 hour before pickup | `take_deposit_lead_minutes = 60` (already 60), also the column default |
| Reply target 2 hours | `task_rules.booking_request` due in 120 opening minutes (was 15); `notify_request_waiting_minutes` was already 120 |

**The race of 0016 (assumption 16).** With a buffer above 0, two confirmations for back-to-back slots inside the buffer could both pass, because the exclusion constraint `bookings_no_double_booking` knows nothing of the buffer. 0019's `record_booking_payment` confirms through `app.finalize_booking`, which takes `for no key update` on the vehicle row before re-checking availability, and `confirm_extension_payment` and `apply_booking_change` lock the same way; under read committed the second writer waits, then sees the first booking. Every other writer (a staff edit, the 0020 calendar's direct path) now goes through the same lock: `app.booking_before_write()` checks a booking that starts or moves while blocking the car with `app.vehicle_free_locked()`, which locks the vehicle row first. So the buffer holds under concurrency.

## 4. Classes

`vehicle_classes` (editable: code, label, order, active; seeded economy, standard, premium, luxury, SUV, convertible, coupe, sedan, van, pickup, and the existing exotic) and `vehicle_class_links` (many to many). Every vehicle's existing class became a link. `vehicles.class` stays as the pricing class (fee defaults and photo lists by class) and is always one of the car's classes (trigger `vehicles_class_link`). `app.set_vehicle_classes(vehicle, by, classes)` (Fleet or an Admin), `app.vehicle_class_list()`, `app.vehicle_in_classes()`, `public.vehicle_classes()`. `app.search_available()` (`class` or `classes`), `app.public_fleet()` (`class` or `classes`) accept any of several classes; `app.public_listing_row()` (and so `car_page`) returns `classes`. The listing pipeline: `listing_drafts.proposed_classes` (`app.propose_listing_classes`, worker; unknown classes dropped) and `app.review_listing_classes(draft, by, approve, classes)` (Fleet, customer service or an Admin) adds the approved ones.

## 5 and 6. Deposits and kilometres

`deposit_tiers` ($500, $1,000, $2,500 and the new $5,000) and `km_allowance_choices` (400, 300, 200, 150 km a day), both editable; `app.rate_card_choices()` for the rate screen. The Deposit, the daily allowance and the overage rate were already per car on `rate_cards` (confirmed); `app.set_vehicle_deposit(vehicle, admin, amount)` sets a tier or any amount by closing the card in force and opening a copy.

## 7. Age

`min_renter_age` 18 and `accepted_licence_classes` G, G2 were already set. `vehicles.allows_18_to_20` defaults to true and every car was set to true (the flag stays; every check that reads it now passes). The caps of `young_driver_18_20`, `young_driver_21_25` and `additional_driver` in `fee_defaults` are null: no maximum. The fees stay variable per car (`fee_types.change_vehicle` now true, so `vehicle_fee_overrides` apply) and per booking (`booking_fee_terms`).

## 8. Additional driver

`fee_defaults.additional_driver`: no amount, `percent_bps` 2500, no cap. The pricer (`app.price_lines`, shared by quote and booking) reads every fee term through `app.fee_per_day(term, daily_rate)`: the amount when there is one, otherwise the percentage of the car's daily rate. Any fee can use the basis later by setting `percent_bps` without an amount on a default, a car override or a booking term. `app.price_quote` and `app.booking_price_spec` now pass `percent_bps`. A $120 car: $30 a day per additional driver.

## 9. Coverage sold through CarmaCars

No longer refused: `app.submit_booking_request` accepts option 3 without a price, and the quote no longer reports `coverage_not_sold_yet`. Price, in order: the booking's own term (customer service with `app.set_coverage_price(booking, by, amount, reason)` on a request, the price for the whole booking; or an Admin with `app.set_booking_fee_term`; on an offer, withdraw it first), else `coverage_prices` (editable default table by car or class and age band, per day or per booking, dated; `app.coverage_term()` takes the most specific row), else none: the quote says "Priced in your offer" (`coverage.priced_in_offer`, `price_note`). `app.guard_booking_override()` (0012) was created again with one exception: customer service may set the `coverage_sold` term. The charge is labelled "Coverage sold through CarmaCars"; the provider is named nowhere.

## 10. Delivery, airports, places

Settings: `company_latitude`, `company_longitude`, `delivery_per_km_cents` (0 until an Admin sets it), `delivery_min_cents`, `delivery_max_cents`, `delivery_round_cents` (100). `app.delivery_fee(vehicle, leg, place)`: our location or the Owner's location nothing; the renter's address = the car's delivery fee (pickup fee on the return leg) + rate x distance, held between the minimum and maximum, rounded to the dollar; an airport = the same with the airport's distance (or the straight line from the company's location) plus its surcharge. The distance comes from the server's maps call: a distance sent by a browser session is ignored and the quote says `needs_distance`. `airports` (editable: code, name, coordinates, distance, surcharge; seeded YYZ and YTZ with no surcharge); `site_settings.airport_delivery` is now true. On bookings: `pickup_location_kind` and `return_location_kind` (`our_location`, `owner_location`, `delivery`, `airport`), `pickup_distance_km`, `return_distance_km`, `pickup_airport_id`, `return_airport_id`, with the address in `pickup_place` and `return_place`. On vehicles: `owner_pickup_address` and its coordinates. `app.apply_booking_places()` (called by the public request) and `app.set_booking_places(booking, by, places)` (staff, on a request) store them; the Owner's location is allowed for Self-Managed cars and cars with an Owner address. A delivery term set on the booking wins over the computed fee.

## 11. Reviews

`review_request_decisions` (booking, problems, `pending`, `send` or `skip`, task, who, when). A problem is an incident (open or past), a dispute, an unpaid balance, or a damage charge (`damage_at_cost`, `deductible`, `loss_of_use` lines, or a matched damage intake) (`app.booking_review_problems`). When a booking with a problem closes, the decision opens with a `review_request_decision` task for customer service (rule row); the automatic request of 0023's follow-up job is not recorded for it (trigger `marketing_sends_review_guard`), so it is not sent. `app.decide_review_request(booking, by, send, note)`: yes sends it at once (once, with the usual implied consent), no leaves it. Bookings without problems get the request automatically as before. `site_settings.google_place_id` is a public site setting for showing Google reviews.

## 12. Site settings and reply-to

Data in `site_settings` (still editable): public email contact@carmacars.ca, owners email owners@carmacars.ca; phone, WhatsApp and roadside +16475753377 with `*_display` 647-575-3377; "Open 24 hours"; reply wording "within 2 hours"; Instagram and TikTok handle carmacars.ca and the profile addresses https://instagram.com/carmacars.ca and https://tiktok.com/@carmacars.ca in `social_links`; `show_street_address` true; `listing_time_promise` "1 business day"; `featured_mode` random (`public.featured_cars()` picks at random on each call). Street and mailing address stay blank; `mailing_address_required` flags the mailing address and `app.site_setup_problems()` lists it as blocking marketing emails until entered. `email_aliases` holds contact@, bookings@, owners@, billing@, privacy@, investors@ (all at carmacars.ca); `email_reply_to` maps each email audience (and money codes) to an alias: renters to bookings@, Owners to owners@, investors to investors@, money emails to billing@, staff to contact@. `notification_outbox.reply_to` is filled on insert (`app.email_reply_to_for`); the sender uses it. `program_settings` company email, phone, incident line and privacy email were filled where blank. `emails/catalogue.json` keeps `info@carmacars.ca` as the template default because `emails/check.mjs` requires it; the outbox value is the one sent. (Superseded by 0026: the catalogue now names the desk per email and info@ is retired.)

## 13. Investors

Checked, nothing to change: investor tables have no anonymous privilege; a renter, owner or staff member reads nothing (only `admin_all` and the investor's own `self_read` policies, keyed on `investors.user_id`); no function the anonymous role may execute reads investor records (the only anon function mentioning investments is the pure calculator `calc_investment_return`, which reads no row); no public site content holds terms. The tests prove each, and that a signed-in investor reads only their own investor row, agreements, investments and terms.

## 14. Cookies

Consent code `necessary_cookies` added (`analytics_cookies` existed). `cookie_consents` (anonymous visitor id, user if signed in, choice `accept_all`, `necessary_only` or `custom`, analytics yes or no, the codes, wording version, time, browser). `public.record_cookie_choice(visitor_id, choice, wording_version, analytics, user_agent)` (anonymous and signed in; rate limited like the other public calls) stores the banner's answer; a signed-in visitor's analytics consent is also a `consents` row. `public.cookie_choice(visitor_id)` returns the latest answer. Nobody but an Admin reads the stored answers.

## 15. Objects

| Kind | Objects |
| --- | --- |
| Tables (10) | `vehicle_classes`, `vehicle_class_links`, `deposit_tiers`, `km_allowance_choices`, `coverage_prices`, `airports`, `email_aliases`, `email_reply_to`, `review_request_decisions`, `cookie_consents`. Each has row-level security, `admin_all`, privileges revoked then granted, and an audit trigger (`app.attach_audit()`). 171 tables in `public` |
| Columns | `booking_vehicle_swaps.to_owner_id`, `to_management_mode`, `to_company_share_bps`, `to_is_shareholder`; `booking_line_items.arose_vehicle_id`; `booking_splits.segment_days`, `segment_starts_at`, `segment_ends_at` (primary key now `booking_id, vehicle_id`); `bookings` place columns (section 10); `vehicles.owner_pickup_*`; `listing_drafts.proposed_classes`, `classes_decided_by`, `classes_decided_at`, `classes_approved`; `program_settings` delivery columns; `site_settings.phone_display`, `whatsapp_display`, `roadside_phone_display`, `handover_any_time`, `google_place_id`, `listing_time_promise`, `featured_mode`, `mailing_address_required`; `notification_outbox.reply_to` |
| Functions added | `vehicle_split_terms`, `vehicle_free_locked`, `booking_vehicle_swap_terms`, `whole_days_between`, `booking_segments`, `segment_overage_km`, `cut`, `booking_line_allocation`, `booking_split_parts`, `fee_per_day`, `vehicle_class_link_main`, `vehicle_class_list`, `vehicle_in_classes`, `public_vehicle_classes`, `set_vehicle_classes`, `propose_listing_classes`, `review_listing_classes`, `rate_card_choices`, `set_vehicle_deposit`, `coverage_term`, `set_coverage_price`, `distance_km`, `delivery_fee`, `apply_booking_places`, `set_booking_places`, `site_setup_problems`, `public_featured_cars`, `email_reply_to_for`, `outbox_reply_to`, `reopen_expired_request`, `booking_review_problems`, `hold_review_request`, `review_request_on_close`, `review_request_guard`, `decide_review_request`, `record_cookie_choice`, `cookie_choice`; wrappers `public.record_cookie_choice`, `public.cookie_choice`, `public.vehicle_classes`, `public.featured_cars` |
| Functions replaced (same signature) | `compute_booking_split`, `sync_later_owner_revenue`, `build_owner_statement`, `approve_owner_statement`, `company_month_lines`, `vehicle_month_days`, `build_company_statement`, `booking_before_write`, `preview_booking_change`, `calendar_preview_change`, `expire_offers`, `add_opening_minutes`, `guard_booking_override`, `price_lines`, `price_quote`, `booking_price_spec`, `submit_booking_request`, `search_available`, `public_fleet`, `public_listing_row`, `public_site_settings`; view `owner_bookings` |
| Triggers | `booking_vehicle_swaps_terms`, `vehicles_class_link`, `bookings_review_request_hold`, `marketing_sends_review_guard`, `notification_outbox_reply_to` |
| Data | settings (sections 3, 10, 12), fee defaults and fee types (7, 8, 9), task rules `booking_request`, `offer_expired`, `review_request_decision`, status transitions, booking history kinds `reopened` and `review_request`, consent code `necessary_cookies`, catalogue text of `renter_offer_expired` and `renter_review_request` |

Privileges: every new function is revoked from public, anon and authenticated and granted to `service_role`; opened to anon and authenticated: the cookie functions and wrappers, `public.vehicle_classes`, `public.featured_cars` and the helpers they call; to authenticated: `rate_card_choices`, `site_setup_problems`. Replaced functions keep their grants.

## 16. Existing test assertions changed

| File | Assertion | Was | Now | Why |
| --- | --- | --- | --- | --- |
| 03 | P2 18 to 20 only on a flagged car | refused | `lives`: accepted | Decision 7 (every car allowed) |
| 06 | S expiry and turnaround | `24/0` | `24/120` | Decision 3 |
| 06 | S the status flow lists the request steps | 7 steps | adds `expired>requested`, `offered>expired` | Decision 2 |
| 06 | SW the switch-off booking does not take the car | checked from the return time | from 2 hours after it | Decision 3 (buffer) |
| 06 | AV true right after a booking | right after | from the end of the 2-hour buffer | Decision 3 |
| 06 | X the expired offer goes back to requested | `requested/expired/none` | `expired/expired/none` | Decision 2 |
| 06 | X back to requested (x2) | `requested` | `expired` | Decision 2 |
| 06 | X staff send an expired offer again | `send_offer` | `reopen_expired_request` then `send_offer`; x2 is reopened before its 48-hour offer | Decision 2 |
| 06 | the AV cleanup (not an assertion) | resets the buffer to 0 | resets it to 120 | Decision 3; it restores the migration's value |
| 06 | PC public calendar for June 2029 | stretches from 10:00 | include the 2-hour buffer (08:00, 12:00) | Decision 3 |
| 08 | S consent codes | `9/4` | `10/4` | Decision 14 |
| 08 | S booking history kinds | `25/4` | `27/4` | Decisions 2 and 11 |
| 08 | Q 12 days, every per-day fee at its cap | young capped $350/$200, additional $70 | $420/$240 uncapped, additional $300 each (25% of $100) | Decisions 7, 8 |
| 08 | Q total of that quote | $1,940.00 + $252.20 | $2,510.00 + $326.30 | Same |
| 08 | Q fees per day, 3 days | additional $30 | $75 | Decision 8 |
| 08 | Q an 18 to 20 driver on a car not offered | two problems | only `driver_under_minimum_age` | Decision 7 |
| 08 | Q coverage has no price | not available, `coverage_not_sold_yet` | available, no problem, "Priced in your offer" | Decision 9 |
| 08 | SR filters (young filter) | only the flagged car | every car | Decision 7 |
| 08 | R every line of the request | additional $70 | $250 | Decision 8 |
| 08 | R totals | $1,365.00 + $177.45 | $1,545.00 + $200.85 | Decision 8 |
| 08 | R fee terms snapshot | caps $350, $200, additional $10 | no caps, additional "not priced" (a percentage) | Decisions 7, 8 |
| 08 | R renter of 18 to 20 refused; additional driver of 18 to 20 refused | `throws` | `lives` | Decision 7 |
| 08 | R coverage cannot be chosen without a price | `throws` | `lives` | Decision 9 |
| 08 | R a refused request leaves nothing behind | all `x.` addresses | excludes the three requests now accepted | Decisions 7, 9 |
| 08 | F, P (three), renter cancellation preview | $711.90 | $830.55 | Decision 8 ($25 a day additional driver) |
| 08 | E extension to 12 days | fee +$60 (cap), $519.80 | fee +$100, $565.00 | Decision 7 |
| 08 | renter: extension preview | `10:27120` | `10:35595` | Decision 8 |
| 08 | CH another Owner's car is refused (preview) | `false/other_owner_vehicle` | no Owner problem | Decision 1 |
| 08 | CH and asking for it is refused | `throws` | removed (proven in 13 instead; leaving a request open would change the rest of the CH steps) | Decision 1 |
| 08 | CH applied, the calendar follows | free the day before the new pickup | not free (inside the 2-hour buffer) | Decision 3 |
| 09 | C the new request task's due time | 15 | 120 | Decision 3 |
| 09 | O 15 and 30 opening minutes after closing | next morning | plain minutes (always open) | Decision 3 |
| 09 | P a confirmed booking cannot move to another Owner's car | refusal | no refusal for that car (the other three refusals unchanged) | Decision 1 |
| 11 | A the audit log has the phone change | before null | before +16475753377 | Decision 12 |
| 11 | A the public settings hide the street address | hidden | shown (9 Hidden Lane) | Decision 12 |

The suite ran 2,132 assertions before; files 01 to 12 now run 2,131 (one removed, above) and file 13 adds 104.

## 17. Not done, and decisions to confirm

1. **Per-km rate, company location, minimum and maximum** are empty or 0 until an Admin enters them; delivery then costs the car's fee, as before. The two seeded airports have no surcharge and no driving distance.
2. **No coverage default prices are seeded**: every coverage request is "Priced in your offer" until rows are added to `coverage_prices`.
3. **A swapped booking counts as a rental on each car** in `rentals_ended` of CarmaCars' statement (per car); the total level therefore counts it once per car. Billable days and revenue are not double counted.
4. **Company-only fees and pass-through lines** of a swapped booking sit on the last car (unless pinned); insurer invoices, refunds paid, Deposits and processor fees follow the booking's current car, as before.
5. **A part is gated separately**: each car's part reaches its Owner's statement once the Owner Revenue on that part is collected.
6. **Per-booking coverage price** is the price for the whole booking; the default table may be per day. Customer service may set it only on a request (withdraw an offer first).
7. **The reply-to of the email catalogue** stays `info@carmacars.ca` (the email checker requires it); the sender must use `notification_outbox.reply_to`. (Superseded by 0026.)
8. **The mailing address flag** is reported by `app.site_setup_problems()`; the marketing senders of 0023 do not yet refuse to send without it.
9. **Owner Bookings** still move only within their Owner's cars.
10. **pg_cron** is absent where the tests run; nothing new is scheduled.
