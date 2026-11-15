# Long-term rentals paid weekly stay on the calendar (Release 48: 2981)

Migration `2981_r48_rolling_weekly.sql`.

A renter on a long rental pays week by week. The booking's return was the end of the week paid, so once that time passed the car showed free on the calendar and on the site while it was still out.

- A booking can be **Long-term, paid weekly** (the booking page card, Admin, customer service, finance and fleet; the connector: `change_booking` with `changes.rolling_weekly`). `rolling_rentals` keeps who turned it on, the notice and the reminder.
- The calendar: a block on the car from the current return until the notice date (no date: until notice), kept by itself as the return moves. The calendar, the site's search and every booking check see the car out; the booking's own next week is never refused because of it. Turning it on is refused, with the booking or block named, when the car is already taken after the return.
- Each week is a 7-day extension (`booking_extensions.rolling`), priced like any extension from the booking's rates, up to the notice date. **Record a payment** of the rental, with nothing of the rental open, records the next week: the amount is the week's price and the return moves 7 days (the payment is the extension's; the usual checks, limits and receipt). The renter's pay link confirms the week the same way.
- Before the return (Program settings `rolling_weekly_lead_hours`, 48 by default) with the next week unpaid: an Admin To do (`rolling_week_due`) and the renter's pay link for the next week by text, else email (the deposit job sends it). Paid either way: the To do closes and an unpaid link is cancelled.
- **End rental on** (`rolling_weekly_end {booking, end_on}`, or `changes.rolling_end_on`): the last day, at the return's time of day. Not before the paid return. The block ends there and the last week stops there. Empty: until notice again.
- Turned off, or the car back: the block goes and the car shows free after the return.
- Tests: `supabase/tests/99_r48_rolling_weekly.sql`; unit: `features/rolling-weekly/model.test.ts`.

## Guides

- `admin/requests-offers-and-bookings`: Long-term rentals paid weekly.
- `va/customer-service`: Long-term rentals paid weekly.
