# Release 31, studio framing and plate boxes on listing photos (migration 0660)

Branch `r31-photos`. SCHEMA_MARKER 0660. Two bugs seen on the four Mercedes listings (Admin > Listings, a 2020 CLA among
them): the car a quarter of the frame wide, floating above the floor line, a large faint "CLA CLASS" behind it; and the
suggested plate box beside the front plate, on the bumper.

## 1. Framing (worker preset studio_v4)

- Root cause: the framing step (`web/src/features/listing/subject-frame.ts`) counted every pixel at alpha 48 or more as
  car. The segmenter's cut-out carries a faint haze over the frame and the floor's reflection under the car above that
  alpha, so the "car" was the whole cut-out: nothing was cropped, and `placeSubject` placed the whole frame (the car
  about 40% of it, the empty floor below it) at 80% of the width, so the car came out about a quarter wide and above
  the floor line. The stand-in drawings (`web/src/features/car/studio.ts`) were not involved.
- Now the car is found at alpha 128, then at 192 and 232 while it keeps at least half its cells (what falls away is
  haze, reflection and soft shadow) or while it is still the whole frame. Edge rows and columns holding under 2% of the
  fullest one are trimmed. What is drawn is the car at the first alpha that is not haze, one cell of soft edge kept, so a
  half clear window stays. The car is then about 80% of the width, centred, its wheels on the floor line.
- No model name is lettered behind a real car (`LETTER_REAL_PHOTOS = false` in `worker.ts`); the stand-ins keep theirs.
- An outside photo whose cut-out cannot be framed is placed the old way and its result flags `not_framed`.
- Tests: `subject-frame.test.ts` (a hazy cut-out with a reflection, a half clear window, a solid car unchanged at every
  alpha), `worker.test.ts` (studio_v4, no lettering, the flag).

## 2. Plate box

- Root causes: (a) a photo made again keeps its file name, so while its job was queued the review sent the old framing
  to the vision model and kept the answer, and the new photo landed with that suggestion still on it: the box sat where
  the plate was on the old framing; (b) the box was then "placed on the plate's edges" by `refineBox`, which looked 1.2
  box widths to each side and took the bumper's intake slats beside the plate (denser edges) for it.
- `app.photo_plate_suggestion` keeps no answer while the photo has a queued or running `process_photo` job; a new
  outside photo (`worker_listing_result`, preset `studio%`) drops its suggestion (and the boxes of an unchecked plate);
  the suggestions kept already that are older than their photo's last finished job are cleared once by 0660 and asked
  again when the review opens.
- `refineBox` looks only a third of the box's width to each side (`REFINE_ACROSS`), still well up and down (the model's
  error). Test: a grille beside the plate no longer pulls the box (`plate-cover.test.ts`).

## 3. Framing existing photos again

- `app.listing_photos_reframe` (ops_do `listing_photos_reframe`, Admin, Fleet and Customer service): every outside photo
  of the listing's car not framed `studio_v4` (or every one with `all`) is made again, off the site until approved again,
  its plate unchecked with no boxes or suggestion. Nothing is queued by the migration itself.
- Admin > Listings > a listing (and Staff > Listings > a listing): **Frame the outside photos again** above the photos,
  then **Yes, frame again**. When the photos are ready: approve them again; the plate boxes are suggested by themselves
  on the new photos; check each and Cover.
- Database test `supabase/tests/99_studio_framing_plates.sql`.

## Guides

- `admin/fleet-and-listings`: Frame the outside photos again.
- `va/fleet`: the same, in short. Published by the guides block of 0600 (regenerated).
