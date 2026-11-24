# Why the cars still showed drawn sample photos, and the photo steps that looped (Release 50: 3700)

Migration `3700_r50ph_photo_loops.sql`. Test `supabase/tests/99_r50ph_photo_loops.sql`.

The owner (Nov 24): the car photos "are still not as they should be". The audit of every live car (connector `photo_standard`):
no car had a studio render on the site (renders done 0, studio covers 0), most covers were the drawn sample of the model, and
18 published cars with real photos had an empty gallery (a grey box on the car page).

- **A render that timed out looped for ever.** The sweep fails a step the worker never answered through `fail_listing_job`,
  which the photo standard never saw: no try counted, the view left "queued" with no step, queued again with fresh attempts.
  Twelve such steps filled the batch and nothing else was queued. Now a timeout counts as a try; three flag the view on
  Photo standard with the reason ("did not finish in time"), and the batch frees itself.
- **A refused render kept its tries at 0.** `photo_r48_queue` restarted the tries of a view refused by the check, so it was
  never flagged. Only a made or flagged view, or Make again, starts them again.
- **Stranded real photos.** A real photo left "queued" with no step is due again (the job puts it back to redo).
- **"Other detail" photos never sorted again** since Release 45 removed the r44 re-sort. The job sorts them again (cars with
  no outside cover first, 8 a run), so an imported outside photo becomes the car's cover.
- **Never an empty gallery.** A published car whose own photos are all inside or detail photos shows its model's
  representative photos first (captioned), then its own photos.
- **Connector.** `photo_standard`: the cover is `studio` when the listing's cover is a render (the side profile since 3150);
  `details_unsorted` and `resorting` per car.

## Guides

No guide change: nothing a person does changes.
