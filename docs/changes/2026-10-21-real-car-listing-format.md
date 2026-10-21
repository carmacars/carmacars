# Real cars look like the sample cars (migration 0073)

The owner, October 21, 2026: the first real car on the site, a 2022 Chevrolet Malibu LS, had a page that looked very
different from the 20 sample cars, and its stand-in photo looked nothing like theirs. Every real car, this one and
every future one, now gets the sample cars' format by itself: the same page, the same kind of text, a clean web
address, and stand-in images drawn by the same studio system as the samples, with the car's own model name.

## 1. What differed (the Toyota Camry sample against the Malibu, end to end)

| Part | Sample car (`/cars/toyota-camry`) | Malibu before | Now |
| --- | --- | --- | --- |
| Heading | Make small above the model in large type | A sentence in a smaller style: "2022 Chevrolet Malibu LS rental in Toronto" (the car copy's `h1`) | The samples' heading for every car |
| Blurb | One short human sentence | Two robotic paragraphs, "kept in Pickering" twice | A short blurb in the samples' voice, nothing about where the car is kept |
| About section | None | "About this Malibu" (highlights that were specs, Good for, What's included) and an "About" link in the page menu | Not shown, for any car |
| Features ("In this car") | Six selling features | "5 seats", "Continuously Variable Transmission", "Gas fuel", "FWD drivetrain" | Six selling features from the VIN decode and the trim |
| Classes | "Standard, Sedan" | "Standard" | The class of its body joins by itself (sedan, SUV, van, pickup, coupe, convertible) |
| Key specs | Gearbox "Auto" | Gearbox "Continuously Variable Transmission (CVT)" | "Auto" for every automatic |
| Spec table | Body "Sedan", Drive "Front-wheel drive" | Body "Sedan/Saloon", Drive "FWD/Front-Wheel Drive" | The samples' words, stored that way |
| What you need | The table | An extra bullet list repeating the table | The table |
| Pickup and delivery | The table, with "Where the car is kept" | An extra paragraph naming "our location in Pickering", and "Where the car is kept: Pickering, Toronto" | The table without the storage row, for every car (a real owner's address area stays private) |
| Questions | The common questions | The common ones, then four more from the copy repeating them ("How many kilometres are included?" twice) | The common ones, then only the car's own questions, never the same one twice; the plain copy adds only the seats question, and a car needs none of its own, like the samples |
| Gallery | Eight studio shots, 1800 x 1200, black studio, model name lettered behind the car | One light grey picture of a generic sedan (1600 x 1067), a black "Sample photo. Photos of this car are coming soon." banner | Eight studio shots in the same style with "MALIBU" behind the car, a quiet "Representative photo" note |
| Fleet card | Studio lead shot | The grey picture, "Sample photo" | The studio lead shot, "Representative photo" |
| Search title and description | Built from the car and its price ("Rent a 2023 Toyota Camry in Toronto from $79 a day") | The car copy's own ("2022 Chevrolet Malibu Rental in Toronto", "...for a daily fee...") | Built the same way for every car; a person's locked text still wins |
| JSON-LD | `driveWheelConfiguration`, five studio images, the blurb | No drive (the decoder's words did not map), one picture, the robotic text | The same fields as the samples |
| Web address | `toyota-camry` | `2022-chevrolet-malibu-ls-black-d537` | `2022-chevrolet-malibu-ls`, the old one answers 301 |
| Example car badge | Shown (it is a sample) | Not shown | Not shown for real cars (unchanged) |
| Price display and rates | From the rate card | The same component | Unchanged |

## 2. Why the Malibu got the template text

Not a budget, provider or error problem: `provider_calls` shows every Workers AI call answered (the listing draft on
October 18, 152 neurons; the car copy on October 19, 110 neurons, published; the rewrite on October 21 after publishing,
325 neurons), and the day's search budget (4,000 neurons) was far from used. The text came from the rules:

- The car copy prompt (`car-copy-v1`, 0061) asked for a 60 to 110 word intro in two paragraphs naming "its colour and
  the area it is kept in", a heading "<car> rental in Toronto", and highlights "each a fact from the facts (seats,
  transmission, fuel, drivetrain...)". The facts carried no equipment (the VIN decode's equipment never reached them)
  and the checks refuse any equipment the facts do not name, so the model could only restate the specs. That passed the
  checks on October 19 and went live as written.
- The rewrite after publishing failed the length rules (an intro of 44 words against 50, a search description of 82
  characters against 90) and waits 6 hours between tries, so the October 19 text stayed.
- The listing draft step and the plain template wrote "It is kept in <area>" by design, and the description rules asked
  for at least 40 words, so a sample-style blurb could not even pass them.
- The page showed the car copy's extra parts (About, requirements, pickup paragraph), which the sample cars never had.

## 3. The fix

| Where | What |
| --- | --- |
| `web/src/features/seo/copy.ts` | `car-copy-v2`: the intro is 1 or 2 sentences (8 to 40 words) in the voice of the sample blurbs given as examples; never "This car", never where it is kept (checked). The highlights are six features copied from two lists in the facts: known (VIN decode standard items, the drivetrain, the third row, a backup camera from 2019, Bluetooth from 2012, the basics) and possible (Apple CarPlay and Android Auto, heated seats and the like), which the model takes only when sure they are standard on that trim in Canada; anything else is refused, and the list is filled from the known items. The headline, search title and description, pickup, included and requirements are written by the site, not the model. Every equipment mention is checked, not only the first |
| `supabase/migrations/0073_real_car_listing_format.sql` | The specs in the samples' words (a trigger on the listing); `app.vehicle_equipment` and the facts' equipment lists, the storage area out of the facts; the plain template in the new format (`app.car_copy_blurb`, the samples' headline); every copy put live carries the samples' headline; the description rule starts at 8 words; `copy_locked` on the car page |
| `web/src/app/cars/[slug]/page.tsx` | One layout for every car: the samples' heading, the listing's blurb and features, no About, requirements or pickup paragraph from the copy; "Auto" for any automatic; the drive mapped for the table and JSON-LD; the search text built from the car unless a person locked it |
| Web address | `app.listing_slug`: year, make, model, trim; the colour only when another car (live or redirected) has that address, then a short code. `app.listing_move_to_clean_slug` moves a live car and keeps the old address as a 301 (`listing_redirects`), redirects that pointed at it follow, both go to IndexNow |
| Stand-in images | `web/src/features/car/studio.ts` is the sample cars' drawing code (`prototype/tools/make-standins.mjs`) as a module of the site; a unit test checks it draws the Camry's eight files byte for byte. `/sample-photos/studio/<shape>/<paint>/<shot>/<NAME>.svg` serves a real car's stand-ins: its body shape (sedan, compact, fastback, SUV, large SUV, van, roadster), its paint (the five of the samples plus blue, green, beige, brown, orange, yellow), its model's name behind the car, the slate reads "REPRESENTATIVE PHOTO" instead of "STAND-IN", cached for a year. `app.vehicle_sample_photos` returns the eight shots (lead, side, rear three-quarter, front, rear, dashboard, seats, wheel) unless an Admin added library photos (Admin > Settings > Sample photos). Once a real photo is approved, the car shows its own photos only (0054, unchanged) |
| Real photos | The photo worker places the car on `studio_v2` (the samples' black studio as pixels, `web/scripts/gen-backdrop.mjs`), with the model's name drawn behind the car as on the samples: `lettering.ts` draws the outline from Inter Display ExtraBold (`presets/ghost-glyphs.json`, `scripts/gen-ghost-glyphs.py`) into a transparent PNG band, kept once per model at `site/backdrop/lettering-v1-<model>.png`, and Cloudflare's `draw` puts it under the shadow and the car. The car stands on the samples' floor line (26% from the bottom, 80% of the width). Interiors are unchanged. The job's photo now carries the model (`app.listing_job_context`). The deploy uploads `studio_v2.png` with the other presets |
| Refresh | `app.listing_format_refresh()` (run by the migration): every real listing gets the specs in the new words, its clean address with the 301, the new plain copy at once (a person's locked fields kept), and its AI copy queued first in line with `car-copy-v2` |

## 4. The Malibu after the migration

- Address: `/cars/2022-chevrolet-malibu-ls` (the old `/cars/2022-chevrolet-malibu-ls-black-d537` answers 301).
- Headline: "2022 Chevrolet Malibu LS for rent in Toronto".
- Blurb (plain, until the AI copy replaces it within minutes): "A comfortable Chevrolet sedan with room for five and a
  proper trunk. Easy to park in the city and quiet on the highway."
- Features (from its VIN decode): Backup camera, Push-button start, Turbocharged engine, Automatic high beams, LED
  headlights, Bluetooth. The AI copy may put Apple CarPlay and Android Auto first (standard on the 2022 Malibu).
- Specs: Sedan, Automatic (CVT), Front-wheel drive.
- Photos: eight studio stand-ins of a black sedan with "MALIBU" behind it, noted "Representative photo".

## 5. Tests

- Unit: `web/src/features/car/studio.test.ts` (the Camry's eight files byte for byte, the Malibu stand-in, mappings),
  `web/src/features/seo/copy.test.ts` (v2 format and checks), `web/src/features/listing/worker.test.ts` (studio_v2,
  the lettering band, the draw order and the floor line).
- Database: `supabase/tests/51_real_car_listing_format.sql`; suite 11 follows the new address and spec words.
- End to end: `web/tests/e2e/real-car-format.spec.ts` (a real car's page against a sample car's: the same sections,
  no example badge, eight studio images with the model's name, the samples' headline and words, the 301 from an old
  address); `sample-cars.spec.ts` reads "Representative photo".

## 6. Not done

- The sample cars keep their own photos and text; nothing about them changed.
- Consumption and luggage rows appear only when the listing has them (the samples have them typed in); nothing is
  invented for a real car.
