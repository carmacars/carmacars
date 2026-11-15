# A plate is only covered where the car has one, and only over the plate (Release 48: 3040)

Migration `3040_r48_plates_present.sql`.

The owner: many cars have no front licence plate, yet the studio photos showed a blurred box where a plate would have been, and the blur boxes were large enough to make the photo look odd.

## Why

- The r48.2 words told Gemini to show "a clean, smooth, blank plate holder" on every car, so a front bumper without a plate got a blank rectangle.
- The check then boxed that rectangle as a plate, and the site blurred it with a quarter of its size added on every side: a hard square larger than the plate.

## What changed

- **No plate, nothing done.** `app.photo_r48_plate_end` says whether the car's own photos show a plate at the end a view shows (`yes`, `no` or not known), and the r48 step gets it as `plate_end`. The words (`web/src/features/listing/r48.ts` `plateRule`) say: where the car has no plate (common on Ontario front bumpers), the bumper stays exactly as in the real photos, with no plate, holder, rectangle, blur or box; a front view says so even when it is not known. Where there is a plate, Gemini takes it off cleanly: the bare bumper or plate recess, never a blank plate.
- **The check knows.** It answers `plate_present` (a real plate with characters), `plate_cover` (a blur, box or blank patch where a plate is or would be) and `real_plate` (whether the real photos show a plate at that end). Its plate boxes are kept only when a plate is there, tight to the plate (`readPlates` in `r45.ts`).
- **Refused, every try:** a blur, box or blank patch (`plate_patch`), a plate box larger than a plate can be in that view (`plate_oversized`), a plate on an end of the car that has none (`plate_added`). A real plate left on the car is refused the first two tries (`plate_left`), then blurred by the site.
- **A smaller blur.** The site's blur (`blurPlates`) covers only the plate with a small pad, at most a plate's size, with rounded corners and a soft edge that fades into the bumper. The same mask is used by the plate editor's blur and pixelation (`plate-cover.ts`). A box a person drew is kept as drawn. The new uploads' check (r45) also refuses a blur where no plate is or a cover larger than the plate, and the plate finder no longer boxes an empty bumper.
- **Fixed on the fleet.** Every studio view that may carry such a patch or blur (the front and rear views, and any view with a blurred plate) is made again by the fleet job (`app.photo_r48_plate_requeue`, run once by the migration, no try counted); the version on the site stays until the new one passes. A view made after 3040 is marked `plate_rule` 3040 and never taken again.
- Tests: `supabase/tests/99_r48_plates_present.sql`; `r48.test.ts`, `r45.test.ts`.

## Guides

- `admin/fleet-and-listings`: the blur covers only the plate, with a soft edge; no box where a car has no front plate; studio photos have the plate taken off cleanly.
- `va/fleet`: the same for covering plates, and Redo photos with Gemini blurs a plate only where the car has one.
