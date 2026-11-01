# Seats from the VIN or a seat table, never a guessed 5 for an SUV (0350, 0351)

The owner, November 1, 2026: the GMC Yukon XL is an 8 seater, but "7+ seats" on /cars did not show it. Live, the Yukon
XL had no seats and the 2026 Hyundai Palisade SEL showed 5.

**Cause.** Since 0094 a car whose VIN decode gave no seat count got "the usual number for the body", and
`app.body_default_seats` answered 5 for every SUV and MPV: a 3-row SUV or a minivan became a 5 seater (the Palisade). A
car added without a body (the owner, permit and plate flows) got nothing (the Yukon XL), and nothing filled it later.

**Now** (`supabase/migrations/0350_seat_counts.sql`), the seats of a listing come from, in this order:
1. a person (Admin > Today "Confirm gearbox and seats", the listing review, a partner's sheet): never changed;
2. the VIN decode's seat count when it has one (2 to 9);
3. `app.seat_counts`, a maintained table by make, model and trim: the 3-row SUVs and minivans (Yukon and Yukon XL 8,
   Denali 7; Tahoe and Suburban 8, Premier and High Country 7; Escalade and ESV 7; Palisade 8, Calligraphy and Limited 7;
   Telluride 8, SX and X-Pro 7; Highlander, Grand Highlander, Pilot, Sequoia, Sienna, Odyssey and Carnival 8 with their
   captain's chair trims at 7; Traverse, Enclave, Expedition, Pathfinder, Armada, QX80, CX-90, Ascent, Wagoneer;
   Atlas, Explorer, Pacifica, Voyager, Grand Caravan, Durango, Grand Cherokee L, GLS, Q7, X7, Navigator, Aviator, MDX,
   XC90, Sorento, EV9, R1S, Model X and others at 7). A longer model name still matches ("Palisade SEL");
4. the body only where it cannot be wrong: 4 for a coupe or convertible, 5 for a sedan, hatchback or wagon;
5. otherwise empty, never 5.

It runs when a listing is made, when a car's make, model, trim, body or VIN changes, and after every VIN fill. A car
with no seat count shows **Seats missing** (red) in Admin > Cars > Vehicles, its listing checklist says "Details not
shown: seats" (it may still be published, as before: the page leaves the seats out), and Admin > Today asks to confirm
them. The backfill corrected every car whose seats were empty or came from the body default (a 5 on an SUV with no
table entry is emptied); each change is in the audit log as `seats_backfill_0350` (from, to, source) and the migration
prints the list. A value of unknown origin or typed by a person is never changed: a car still wrong after the deploy
is one of those and is fixed on its listing.

One value everywhere: the fleet filter (7+ seats), the JSON-LD (seatingCapacity) and the car page all read the
listing's seats (the public row's `seats`); the car page leaves the Seats line out when it is not known.

`supabase/tests/99_seat_counts.sql`: a Palisade added by its VIN gets 8 from the table and shows under 7+, a decode's
seats win, an unknown SUV has none and is flagged, a person's value stays, the backfill corrects a body default, a trim
change follows the table. `66_release_3_car_facts.sql`: the body no longer gives an SUV 5.

## Guides

- `admin/partners-company-cars-and-rentals-added-by-hand`: where the seats come from, and Seats missing.
