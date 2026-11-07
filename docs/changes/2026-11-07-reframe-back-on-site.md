# Reframed photos go back on the site once their plate is checked (0661)

Hotfix of 0660. "Frame the outside photos again" took a published listing's outside photos off the site until they were
approved again, but a published listing shows no review controls, so the photos stayed off the site (seen on the four
Mercedes listings, November 7).

- A photo made again by that button is marked (`vehicle_photos.reframed_at`). Once its plate is checked on the new file
  (covered, or marked "No plate visible") while the listing is published or paused, it is approved and goes back on the
  site by itself, as an approved photo already does after its plate check (0070).
- A photo nobody approved and nobody asked to frame again still waits for the review.
- The photos made again and checked before this fix are put back on the site by the migration.
- The message after pressing the button says so.

Checks: `supabase/tests/99_reframe_back_on_site.sql`.

## Guides

No guide change: the guides say a reframed photo needs its plate checked again; it now also goes back on the site then.
