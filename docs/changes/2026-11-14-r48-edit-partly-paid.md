# Change the car or the dates of a booking partly paid (Release 48: 3011)

Migration `3011_r48_edit_partly_paid.sql`.

A booking waiting for payment with a payment already could not move to another car: Edit the offer refused it ("has a payment for its total already") and Edit booking refused it ("not confirmed yet"), and so did the connector's `change_booking`.

- `app.booking_edit_refusal`: such a booking is edited like a confirmed one (Edit booking on its Overview, the same roles; the connector's `change_booking` runs the same step). A booking waiting for payment with nothing paid still changes through Edit the offer.
- `app.booking_staff_edit`: the new car, and new dates, are checked free (the car is held for the booking while it waits for payment). The car changes with the price as it is, new dates are priced at the booking's own rates, and every payment stays recorded. The offer's terms otherwise stand still while it is out (`app.booking_before_write`); only this edit passes.
- Edit the offer's refusal now says to use Edit booking. The booking page loads Edit booking for a booking waiting for payment (the database decides whether it shows).
- Test: `supabase/tests/99_r48_plan_edit_licence.sql`.

## Guides

- `admin/requests-offers-and-bookings`: change the car of a booking partly paid.
