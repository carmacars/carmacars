# Owners see every rental their cars have been on (Release 44: 2830)

Migration `2830_r44_owner_rental_history.sql`.

The owner portal's Cars > Bookings tab has a **Rental history**: every rental on the owner's cars, oldest first, with **Newest first**, a car filter and 50 rentals a page, and at the top the number of rentals, rental days, what their statements carried and how many are not yet on a statement.

- **Each rental**: booking number, car (name and plate), pickup and return in Toronto time, rental days, status (Upcoming, On rent, Completed, or Cancelled, charge kept) and the owner's earnings for it: the rental lines of their approved statements, the same figure the statement shows (Owner Revenue less the Revenue Share). Not on an approved statement yet: "Not yet on a statement"; part of a long rental approved: that amount, "more on a later statement".
- **Only what an owner may see**: no renter name, phone, email, licence or address, no insurer, claim, adjuster, deposit, payment details, notes or fee lines CarmaCars keeps. The read goes through the same privacy filter as every owner read (1830).
- **Which bookings**: never one hidden from the owner (`app.booking_visible_to_owner`), a test booking, a request, an offer, a hold or an unpaid checkout, or the owner's own booking of their car. A cancelled or no-show booking is listed only when a charge was kept for it (on an approved statement, or on the next one).
- **Security**: `public.owner_portal_rental_history` is server only (the service role with the owner's user id, like every owner read); another owner's car is never listed.

## Guides

No guide change: no step changes; the new section explains itself on the page.
