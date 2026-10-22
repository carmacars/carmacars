# Standard settings for every car entered (October 21, 2026; migration 0087)

The owner: "every car that's entered gets standard settings automatically based on what the car is, and a number right away."

## What changed

- **Fleet number at once.** Every real car gets one when it is added (`app.next_fleet_number`, a sequence that never gives a number twice), in the real cars' own range: Program settings `fleet_number_prefix` ("CC ") and `fleet_number_first` (101). The 22 sample cars keep CC 01 to CC 22. The real cars on file got theirs in the order they were added. Internal only: staff screens show it; the public reference is the car code (0079).
- **Standard settings at creation**, by the car's class, all read from Program settings and Fee defaults: a complete rate card when no rates are typed (the suggested daily rate of 0070; weekend, weekly and monthly by the rate form's rule; the kilometres a day; the extra kilometre rate, the deposit and the delivery fee of the class, pickup the same as delivery, within the delivery range). A rate card typed in the same step replaces it and keeps the defaulted deposit, delivery and pickup; a typed card's empty delivery and pickup ($0) take the class default. Program settings `car_defaults_rates_on_add` (on) turns the rate card off.
- **Drivers 18 to 20 allowed on every car by default** (`young_driver_classes`, every class; take a class out to switch it off, or switch it off on one car). The real cars on file were switched on unless the audit log shows a person switched them off.
- Add-ons (each with its own class and fuel exclusions: no prepaid fuel for an electric car), winter tires (a seasonal add-on), the Protection Plan price (by class) and the fuel from the VIN already follow the car; suite 58 checks them for a new car.
- A car staff add for an owner with no onboarding method chosen and none recommended (an individual who owns the car outright) gets the open method with the lowest estimate, marked, so the Admin's approval in the same step can set the terms (0077 refuses terms without a method; the Add a car for an owner screen has no method field).
- One function, `app.apply_car_defaults`, called by every add path through 0082's `app.vehicle_after_add` (Add a car, Add a car for an owner, Fleet, the owner's application, `vehicle_add`, `staff_add_owner_car`). The real cars on file: only what is empty was filled.
- The Admin car page shows "(Set automatically)" next to the fleet number and the young driver setting, and lists the rate card's automatic values on the Rates tab, until a person changes them (`vehicles.auto_defaults`, `rate_cards.auto_defaults`).

## Note

A new car added without rates now has a rate card at once, so with "Publish new cars automatically" on it goes on the site at the suggested rates as soon as its basics are complete (0070's rule). The values are marked for review.

## Tests

Suite 58 (`supabase/tests/58_car_defaults.sql`); suite 43 turns the rate card from the defaults off while it tests cars added without rates. Unit test `web/src/features/supply/auto-defaults.test.ts`.

## Guides

- `admin/partners-company-cars-and-rentals-added-by-hand`
