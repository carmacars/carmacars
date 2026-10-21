# VIN-first entry (October 21, 2026; migration 0082)

The owner, October 21, 2026: "Put in a VIN and the description and title and everything gets generated automatically
from that rather than having to type in any details manually."

Every place a car is added now starts from the VIN. At the 17th character the car is looked up (once per VIN, kept in
`vin_decodes`) and shown as one line with an Edit link instead of a dozen inputs; the class is inferred from the make,
model, trim, body and age and sets the starting rates; the colour is one tap (or read from the cover photo); the title,
description and features are written by the listing pipeline (car-copy-v2, 0073, unchanged) right after the car is
added.

## 1. Each entry point

| Entry point | Before | Now | Still asked |
| --- | --- | --- | --- |
| Admin > Vehicles > Add a car (`/admin/vehicles/new`) | Supplier first, then VIN, plate, year, make, model, trim, colour, odometer, class, home area typed by hand; the class defaulted to Standard and was dropped for a program owner's car; the daily rate pre-filled once, from Standard | The car first: the VIN, decoded at once into "2016 Porsche Macan S" and "SUV · 5 seats · 5 doors · Gas · All-wheel drive · Automatic · 3.0 L, V6, turbo" (Edit opens year, make, model, trim and fuel); a car already in the fleet is named with a link; colour swatches; the class inferred with the reason ("Premium: a Porsche, 10 years old (Luxury when newer)"), editable; the daily rate pre-filled from similar cars or that class, and again when the class or model changes, unless a person typed a rate | Who supplies it (and the owner or partner); optional: plate, colour, odometer and home area (behind a link) |
| Add a car for an owner, Admin (`/admin/owners/add-car`) | VIN, a Decode button, then year, make, model, trim, plate, colour typed | The same VIN entry, swatches and class; the plate when the VIN is not at hand | The owner, plate (optional), odometer, insurer, owned/financed/leased, documents, terms and invoices (unchanged) |
| Add a car for an owner, customer service and fleet (`/va/owners/add-car`) | As the Admin's | As the Admin's (the class they choose goes to the Admin with the proposal) | As the Admin's |
| The owner's application (`/list-your-car/apply`) | VIN and a Look up button, then year, make, model, trim, colour and fuel inputs to check | Looked up at the 17th character; one line with Edit; colour swatches; the fuel is no longer asked (the decode or gasoline). Not decoded: year, make and model from lists. The class is never shown to an owner (inferred) | Plate, odometer, insurer, the ownership and history questions (unchanged) |

Adding by plate (0070) is a link under the VIN for staff: year, make and model from lists, and the details fill in when
the VIN is entered and decoded later. A VIN whose check digit (position 9) does not add up shows "This VIN does not add
up: one character may be misread (0 and D, 1 and L, 5 and S, 8 and B are the usual ones). Check it against the
ownership permit. You can still save it." Letters a VIN never has are named ("O is probably 0").

## 2. When the decoder cannot read the VIN

The form asks only the year, make and model, from lists: the years, the common makes (or "Another make", typed), and
the models of that make and year from NHTSA vPIC (`GetModelsForMakeYear`; "Another model" types one). Saving is never
blocked by the decoder. The listing worker's five-minute run (`/api/jobs/listing`, `web/src/server/car-details.ts`)
decodes such VINs again (at most 5 tries, 6 hours apart) and the car fills itself (`app.vin_decoded_apply`).

## 3. The class

`vehicle_class_rules` (Admins edit; staff read): the active rule of the lowest rank that matches the make (letters
and digits, any spelling), model, trim and body wins; `aged_class` applies from `aged_years`. No rule: Standard.

| Rank | Rules |
| --- | --- |
| 10 | Exotic makes (Ferrari, Lamborghini, McLaren, Rolls-Royce, Bentley, Aston Martin, Bugatti); Lotus Luxury |
| 15 to 20 | Luxury models, Premium once older: Porsche (sports cars 12 years, others 8), flagship Mercedes-Benz (S, GLE, GLS, G, EQS, SL, AMG, Maybach), BMW (7, 8, X5 to X7, M cars, iX, i7), Audi (A8, Q7, Q8, R8, RS), Lexus (LS, LX, LC, GX), Range Rover, Escalade, Navigator, Genesis G90 and GV80, Tesla Model S and X, Corvette, GT-R, Maserati, Lucid |
| 40 | Premium makes: Mercedes-Benz, BMW, Audi, Lexus, Acura, Infiniti, Cadillac, Lincoln, Genesis, Volvo, Land Rover, Jaguar, Alfa Romeo, Tesla, Polestar, Rivian |
| 45 | Sports and premium models of other makes: Mustang, Camaro, Challenger, MX-5, Supra, Z, Pacifica |
| 50 | Any other SUV, crossover, minivan, van or pickup (by the decoded body): SUV |
| 60 | Small cars: Rio, Forte, Soul, Accent, Elantra, Venue, Yaris, Corolla, Versa, Sentra, Micra, Spark, Sonic, Cruze, Mirage, Fit, Fiesta, Focus |

Examples: a 2016 Porsche Macan is Premium, a new one Luxury; a 2015 Cadillac CTS is Premium; a Ford Explorer is SUV; a
Chevrolet Malibu is Standard. A class a person chooses is kept (`vehicles.spec_sources.class.source = 'person'`); an
inferred one says so (`'inferred'`, with the rule and the reason). Changing the class replaces the old class link the
schema added (a person's extra classes stay).

The daily rate starts from `app.listing_default_daily` (0070, unchanged): the median of real cars of the same model,
else of the same class, else Program settings by class. With the right class, a Macan or a CTS starts from Premium cars
or the Premium default ($109), not Standard ($89).

## 4. After the car is added

`app.vehicle_after_add` runs on every path (`app.add_owner_vehicle` for owners' cars, `app.vehicle_add_core` for
CarmaCars-owned and partner cars) and never refuses the car:

1. the decoded details it is missing: trim, body and fuel on the car; seats, doors, gearbox, drive, body and engine on
   the listing, in the samples' words (0073 trigger). Only empty fields; nothing a person entered
   (`spec_sources.<field>.source = 'person'`) is replaced (`app.vin_fill_missing`)
2. the class (above)
3. the copy queued at once: the car's `car_copy` row asked for (the search job takes asked rows first), the plain copy in
   place meanwhile (`app.car_copy_queue`). The web app then runs the search job right after the response
   (`web/src/server/car-added.ts`), so the AI title, description and features (car-copy-v2) follow within seconds; the
   five-minute tick does it otherwise. The copy generation itself is unchanged.

## 5. The colour

Swatches (Black, White, Grey, Silver, Blue, Red, Green, Brown, Beige, Gold, Orange, Yellow, Purple, or Other, typed).
Optional for staff; the owner taps one. When a real car has no colour (and none entered by a person) and has a cover
photo, the listing worker's run sends that photo (the smallest JPEG or PNG of 400 pixels or more) to the vision model
of Program settings (Workers AI, the same allowance as plate suggestions; `app.colour_read_due`), and stores the answer
when it is one of the swatches with confidence 60 or more (`spec_sources.colour.source = 'detected'`). A photo is read
once (a failed read up to 3 times an hour apart); a new cover photo is read again. Calls are counted in
`provider_calls` as `colour_read`.

## 6. The real cars on file

The migration fills every real car's missing decoded details from the decode on file (nothing entered by a person is
touched), and gives program owners' cars whose class nobody ever chose (the application and Add a car for an owner had
no class field, and Add a car dropped it for program owners) the inferred class. On the live data that is the
2016 Porsche Macan and the 2015 Cadillac CTS (Premium) and the 2021 Kia Forte (Economy); their rates are unchanged.
CarmaCars-owned and partner cars keep the class staff chose. The search job rewrites the copy of cars whose facts
changed, as it does for any change.

## 7. Guides

Admin: Add a car, Add a car for an owner. Assistants: Add a car for an owner. Owners: Apply to list your car
(`docs/guides/src/guides/*.py` and `docs/guides/content/*.json`).

## Tests

- `web/src/features/vin/vin.test.ts`: the check digit, the messages while typing, the vPIC mapping (makes, trims,
  fuel, engine, gearbox), the summary line, the colour words and the vision answer, the year list, and what the form
  sends (only the VIN and what a person changed; year, make and model when not decoded or by plate).
- `supabase/tests/52_vin_first_entry.sql`: class inference (Macan, CTS, flagships, exotic, SUVs, minivans and pickups,
  sports models, small cars, rule rank and inactive rules, who may change the rules), `app.vin_facts` (check digit,
  decode in the listing's words, class, starting rate, a failed decode, the car already in the fleet), Add a car from
  the VIN alone (details, class, copy queued and taken first by the search job, published), a person's class and trim
  kept, by plate, a VIN not decoded, the car added for an owner by customer service, the owner's own application, the
  fill of empty fields only, a VIN decoded later, the colour from the cover photo, privileges.
- `web/tests/e2e/vin-first.spec.ts` at 375 and 1440: Admin > Add a car decoded (summary, class, rate, colour, the copy
  written by the search job, the VIN already in the fleet), not decoded and by plate, Add a car for an owner by an Admin
  and by customer service, the owner's application decoded and not decoded; axe and no horizontal scroll. The specs that
  typed the year, make and model (rates-form, seo, supply-rentals, owner-terms, owner, signup) use the new entry.

## Not done

- The class rules have no Admin screen yet (they are rows in `vehicle_class_rules`; an Admin can change them in the
  database). The Vehicle classes settings page is unchanged.
- With few real cars, "similar cars of the same class" can be one or two cars (0070's rule): the first BMW 3 Series
  starts from the median of the Premium cars on file. Staff see the source under the class and can change the rate.
