# A car's own photos stay on the site while their new versions are made (Release 47: 2890)

Migration `2890_r47_photos_stay_live.sql`.

Since Release 45 a car's real photo was taken off the site once its Gemini remake was refused or failed three times, and the cover and the gallery looked only at the single first photo: when that one was an inside photo, or a car's outside photos had been taken off, the site showed the drawn sample of the model instead of the car.

- A refused or failed remake of a real photo keeps the photo as it was, on the site; it is flagged on Photo standard for **Redo this car now**. Only a generated view that fails stays off the site.
- **Once**: every real photo taken off the site this way is put back (approved, with its file and a checked plate).
- The cover is the first outside photo in the standard order wherever it sits, and the gallery is put in that order; a car shows no photo only when it has no outside photo at all. The Admin flag and the publish guard read the same rule.
- A flagged real photo still on the site is that angle's photo: no generated view is made beside it.
- Test: `supabase/tests/99_r45_photos.sql`.

## Guides

No guide change: the guides already say the first photo is always an outside one and a refused photo is flagged on Photo standard.
