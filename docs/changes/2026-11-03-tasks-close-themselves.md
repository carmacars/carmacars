# Tasks of a rental already underway close themselves (0235)

The owner: "<car> is out on rental ...: set its status to On rent" stayed open after the car was set to On rent.

- live_rental_car_status: done when the car is set to On rent, when the booking moves to another car, or when the rental
  ends; cancelled with the booking.
- live_rental_condition: done when a pickup condition report is recorded. live_rental_coverage: done when the coverage is
  confirmed with a confirmed proof. live_rental_insurance: done when the booking moves to another car.
- Every live_rental_* task is cancelled when its booking is cancelled, declined or expired. The agreement, drivers,
  deposit and insurance tasks already closed themselves (0072, 0078, 0148, 0185). Open ones already met close now.
- Tests: `supabase/tests/99_release_23.sql` section 9.

## Guides

No guide change: the tasks look the same; they now close by themselves.
