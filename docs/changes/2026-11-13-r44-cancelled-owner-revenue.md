# Owner statements count only what a cancellation kept (Release 44: 2781)

Migration `2781_r44_cancelled_owner_revenue.sql`.

A cancelled booking with nothing paid put its whole Owner Revenue on the owner's statement. A cancelled or no-show booking now counts only the rental charge actually kept (collected less refunded, before HST): nothing kept, no line; a kept cancellation charge, a line for the kept amount. A charge collected later reaches a later statement. Bookings kept off the owner's revenue stay off; returned and closed rentals are unchanged.

## Guides

No guide change: the statement's screens and steps are the same, only the amounts of cancelled bookings are corrected.
