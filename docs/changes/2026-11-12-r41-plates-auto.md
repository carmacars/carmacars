# Licence plates checked by themselves, and "Cover the plate" fixed (Release 41: 2530 to 2532)

Branch `r41-plates`. Migrations `2530_r41_plates_auto.sql`, `2531_r41_plates_backfill.sql`, `2532_r41_plates_guides.sql`.
Tests: `web/src/features/listing/plate-auto.test.ts`, `supabase/tests/99_r41_plates_auto.sql`.

The owner, Nov 12: every listing photo must have its licence plate covered or be marked "No plate visible" before it goes
public (0070, 0661), and about 85 cars of 10 to 30 photos each cannot be checked by hand. "Cover the plate" did nothing on
the Admin listing review (the Lamborghini Urus: no editor, no message, the photo still "Plate not checked").

## 1. "Cover the plate" works again

| What was wrong | Fix |
| --- | --- |
| The editor opened after the last photo of the grid: with 20 photos it was far below the screen, so the button seemed dead | The plate editor (and the cut-out editor) opens right under its photo, across the grid, scrolled into view with the focus on the photo (`features/listing/WideRow.tsx`), in Admin and in the staff portal (the same `ListingReview`) |
| Saving with the CARMA plate (the default style since 1056) was refused: `photo_plate_record` still allowed only cover, pixelate or blur | 2530: it takes `carma` too (also the cover carried over an edited photo, `PlateCarry`) |

## 2. The plate checked by itself

| Item | What changed |
| --- | --- |
| When | Every current, processed public photo of a real car whose plate is not checked gets a listing job `plate_auto` (trigger on `vehicle_photos`): after processing, after a photo is made again, after a check is reset. It runs after every other step of the queue |
| The model | The vision model through the marks' gate (`server_photo_mark_gate`: Workers AI within the day's free AI share, recorded in provider calls); the photo's 1,024 px size when it has one. The share used up: the job waits an hour without using an attempt |
| The decision (`features/listing/plate-auto.ts`) | A plate found with confidence at least `plate_auto_cover_min` (55): covered with the same cover as "Cover the plate" (`applyPlates`: the CARMA plate, the front plate edited out), the box moved onto the plate's edges as the editor does; the uncovered file kept privately; status covered. The model sure there is no plate (at least `plate_auto_clear_min`, 85), or an inside or detail shot (dashboard, seats, trunk, wheel, detail) where it sees none: No plate visible. Otherwise, or a weak box anywhere: left Plate not checked for a person |
| Safe by design | The decision applies only while the photo is still the file the model saw and nobody decided since; a cover that came too late removes its own files; the replaced public files are removed as the manual save does |
| Recorded | `vehicle_photos.plate_auto`: who `auto`, decision, confidence, model, time, the file, the files before. The review shows "Covered automatically (88% sure)", "No plate seen automatically" or "Checked automatically: not sure", and how many photos wait |
| Undo | **Undo** puts the photo as it was back (its sizes made again) and makes it Plate not checked; **Not a plate: no plate visible** does the same and marks it No plate visible; an automatic No plate visible goes back to Plate not checked. An undone photo is not checked by itself again until its file changes. Audited |
| Settings | Program settings: `plate_auto_enabled` (on), `plate_auto_cover_min`, `plate_auto_clear_min`. The browser's own box suggestion runs only when the automatic check is off |

## 3. Once (2531)

- The Lamborghini Urus (review `d7fb3388`): its front-left photo, marked No plate visible by hand by mistake on Nov 12, is Plate not checked again (the current front-left shot of the car; else its cover, else its first outside photo), only while it is still that hand decision. It leaves the site until the check covers it. Audited.
- Every photo whose plate is not checked is queued. Queuing again changes nothing (one open job a photo; an answer for the same file is not asked again).

## Guides

`admin/fleet-and-listings` and `va/fleet`: the plates are checked by themselves, the badges, Undo, the editor under its photo.
