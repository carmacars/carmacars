# Offers and unpaid bookings stop holding the car on time (Release 48: 2961)

Migration `2961_r48_offer_hold_expiry.sql`.

An accepted offer that was never paid (waiting for payment) held the car with no end, so the car stayed off the site, and stale offers stayed open. The owner approved these defaults, all in Settings > Program settings > Booking requests and offers:

- An offer is open 12 hours (was 24) and never past 1 hour before the pickup (`offer_cutoff_before_pickup_minutes`); with the pickup closer than that it closes at the pickup.
- An accepted offer not paid yet holds the car 2 hours (`offer_unpaid_hold_minutes`, 0 for no limit). Then the hold ends: while the car is still free for those dates the renter gets a fresh offer at the same price and a text with the link to pay; otherwise the booking expires. Each step is written in the booking's history. Owner Bookings, placeholders, insurer and platform payments, offline payments (e-transfer, cash) and bookings with a payment in are not timed.
- Only confirmed and paid bookings and cars out block solidly. An accepted unpaid booking blocks only while its hold runs; an offer never blocks (the first to pay gets the car). The fleet calendar draws both as a light hatched hold until they end, says until when, and fades a lapsed one.
- The offers job (every 5 minutes) ends the holds. A one-time sweep expired the offers and holds already stale; an accepted booking whose dates are past and nothing paid was closed quietly.
- Tests: `supabase/tests/99_r48_offer_holds.sql`; `web/src/features/admin/calendar-label.test.ts` (the hold).

## Guides

`admin/requests-offers-and-bookings` and `va/sales`: an offer is open 12 hours (never past 1 hour before the pickup) and an accepted offer not paid holds the car 2 hours (migration `2962_r48_offer_hold_guides.sql`).
