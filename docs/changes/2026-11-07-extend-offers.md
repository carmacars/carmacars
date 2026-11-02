# Renter extension offers, the new late fee and a 90 minute buffer between trips (0480 to 0483)

The owner wants renters to extend themselves instead of returning late: six clear options with a discount, approved at
once when the car is free, even after the return time while the car is still out; a late fee that follows the price of
the car; and one buffer between trips that every availability check uses.

## Late fee (new bookings and offers only)

Per started hour after the 30 minute grace: 17.5% of the booking's daily rate (`late_fee_hourly_bps` 1750), at least
$25 (`late_fee_hourly_min_cents` 2500). The cap of 1.5 times the daily rate per 24 hours is unchanged. $850 a day:
$148.75 an hour; $80 a day: $25 an hour.

Every booking that existed when 0480 ran keeps the flat $25 it was given: its late fee term was frozen into
`booking_fee_terms` first (`app.freeze_late_fee_terms`). A new booking's term records the rate
(`booking_fee_terms.rate_bps`) when it is confirmed; until then the policy of the day it was booked applies.
`app.booking_fee_term` gives every caller (the check-in charge, the handover, the agreement, the emails' late fee) the
booking's own hourly amount. A car's own late fee and a fee set by hand for one booking stay flat.

Wording updated: the rental agreement (docs/source/v2_rental.md section 3.2 and the fee table, regenerated into
`source.generated.ts`), the renter billing specification, the operating procedures (late return steps, T13), the
Requirements page and the FAQ (`{{lateHr}}` now reads "17.5% of the daily rate, at least $25"), the info tip, the
academy lessons and quiz (seed files and the live rows, 0481), the agreement summary ("per started hour").

## Extensions

| Option | Price |
| --- | --- |
| 1 hour, 3 hours | The booking's hourly late fee for those hours, from the original return time and without the grace, less 10% (`extension_short_discount_bps`). Never more than the 1 day option: then the day is offered instead. Beside it: what being that late would really cost (late fee and the extra day, with HST). |
| 1 day, 3 days, 1 week, 1 month | The rate card's duration tier for the added days at the booking's stored rates (daily, 3-day, weekly, monthly), less 5% (`extension_discount_bps`), plus per-day fees and HST. |

Lead-time pricing never applies. Insurer-billed bookings, owner bookings and a car with its switch off
(`vehicles.extension_offers`, Fleet > car > Edit details > Renters extend themselves) get no offers and no discount:
they ask, and are priced as before (the whole booking repriced at its new length).

After the return time, while the car is still out (`app.booking_is_out`, no return recorded): the renter can still
extend. It counts from the original return time; the late charges so far are shown and stay owed until the extension
is paid. Once paid the return time moves, so the reminders of the end are sent again for the new time and T13 and T14
for the old time stop. An approved extension not paid stays open while the car is out and lapses once it is back.

Self-serve (`extension_auto_approve`, on): approved at once when the car is free for the added time with the buffer,
nothing is unpaid or there is a card on file, every driver's licence is valid to the new return, the coverage lasts, the
length is within the maximum and no deposit hold must be captured first. Otherwise customer service gets the request
(task `review_extension`) as before; staff approval keeps the offer's price.

The renter's Extend page (`/account/bookings/<number>/extend`, the portals' card look): the six options with the new
return, the price, the regular price struck through and "You save 5%"; one the car cannot take is disabled with the
reason ("Booked from Tue 9:00 am", "Blocked for maintenance") and the page says "Available until ...". One tap pays with
the card on file ("Pay $X with Visa ending 4242"); the confirmation shows the new return. With no card on file the same
tap ("Pay $X by card") opens Stripe's secure pay page for the approved extension (0482), and a declined card offers "Pay
with another card"; paying there confirms the extension like the card on file does, and a payment that can no longer
confirm it (the extension lapsed, the car was taken) is refunded at once. Another date and time stays
in a disclosure below (the request form as before).

Messages: `renter_return_soon` and `renter_return_due` (email and text) carry `{{extend_offer}}`: "Extend at 5% off:
from $X for 1 more day" for the booking, or "Need more time? Extend" when it has no offer. Texts an Admin changed are
left as they are.

## Buffer between trips

`booking_buffer_minutes` (90) is the one time between trips; `turnaround_buffer_minutes` follows it both ways (whichever
an Admin changes), so every check that already used the turnaround (new requests, offers, date changes, extensions,
the calendar sync, rentals added by hand, the placeholders' date conflicts) uses 90 minutes before and after each trip.
It was 120. Existing bookings closer than that are not changed: the calendar's clash ring now counts the buffer
between two bookings, so they are flagged. A date change's list of what it clashes with counts it too.

## Settings

Program settings > Booking requests and offers: Buffer between trips, Late fee per started hour (share of the daily
rate, at least), Extension of a day or more: discount, Extension of 1 or 3 hours: discount on the late fee, Approve a
renter's extension at once.

## Database

0480: settings, `vehicles.extension_offers`, `booking_extensions` (option_code, pricing, regular_total_cents,
auto_approved; the checks allow a few hours that add no billable day and a payment after the return while out),
`booking_fee_terms.rate_bps`, `app.preview_extension` (the pricing), `app.extension_offers`, `app.request_extension`
(approval at once), `app.request_extension_option`, `app.extension_auto_refusal`, `app.extension_offer_line`,
`app.vehicle_free_until`, `app.lapse_extensions`, patches of `app.approve_extension`, `app.confirm_extension_payment`,
`app.admin_calendar` and `app.calendar_preview_change`; `public.my_extension_offers` and `public.renter_extend_option`
for the portal; `public.site_facts` gives the late fee and discounts to the site. 0481: the words in the database.
0482: the pay link of an approved extension (`payment_requests.covers` 'extension' with `extension_id`,
`public.renter_extension_payreq`, `public.server_payreq_settle` confirms the extension or refunds). 0483: the guides.

Tests: supabase/tests/99_extend_offers.sql (late fee, old booking unchanged, extend after return while out, pricing from
the original return, each option's math with the short-or-day fallback, approval at once and its refusals, insurer
excluded, buffer 89/90/91 minutes both ways, the clash ring, T13 and T14 stop after payment, the offer line, the pay link without a card);
web/tests/e2e/extend-offers.spec.ts (the panel at 375 and 1440 with axe, one tap with the card on file, the pay page without one).

## Guides

- `renter/during-your-trip`: Extend with the six options, paying at once, extending after the return time, the late fee.
- `admin/settings`: the buffer between trips, the late fee and extension settings, the car's switch.
- `admin/text-alerts-email-text-or-both`: the extend offer in the end-of-booking messages.
- `va/customer-service`: a late return can still be extended by the renter.
