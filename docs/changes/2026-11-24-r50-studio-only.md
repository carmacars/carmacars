# One look: studio renders only, the studio gate, and why no render ever finished (Release 50: 3701, 3702)

Migrations `3701_r50ph_studio_only.sql`, `3702_r50ph_guides.sql`. Web `features/listing/studio-gate.ts`, `worker.ts` (makeR48),
`r48.ts` (r48.3), `components/SlotCars.tsx`, `CarCard.tsx`, `car/Gallery.tsx`, `listing/StudioGrid.tsx`, `public/studio/coming-soon.jpg`.

The owner (Nov 24): "Some of the backgrounds for the photos aren't consistent... makes us look like AI slop. And you still
aren't doing the consistent angles using AI." Then: the cropped cars and correct angles are not reaching the hero or the home page.

## Why no render ever finished

A render ran in the Cloudflare Worker's listing job, whose run is capped at 30 s of CPU (`wrangler.jsonc` `limits.cpu_ms`).
Each render decoded every reference photo with jpeg-js (about 3.4 s of CPU for a 12 MP phone photo, up to six of them), the
same-angle photo again for `borderDiff`, and two renders ran in one run. The run was killed before it answered, the sweep
failed the step after the lock time, and (3700) the view was queued again for ever. Gemini was billed for every try.

- References are sent to Gemini as they are (up to 3.5 MB each, four at most); one is made smaller only when none fits.
- The same-angle photo is no longer decoded (the gate compares with the plate instead).
- A run takes up to three small batches of renders (`R45_BATCHES_PER_RUN`, two renders each), and no new batch once 60% of
  the run's time is used: Gemini's wait is wall time, not CPU. The queue holds 24 steps (was 12), always within Gemini's daily
  limit less the reserve.
- No key or paid plan is missing: the image model, its daily limit (2000) and the Canada relay are set up.

## The studio gate (standard r48.3)

- One background plate per scene for every outside view (`photo_r48_family` is `side` for all five), so every view stands in
  the same room and floor.
- The image model is asked for the car a little smaller than the target (`FRAME_ASK`); the check model reads the car's box;
  `frameWindow` and `cropResize` put the car exactly on its view's target (`STUDIO_FRAME`: width, centre, floor line).
- `gateExterior` then measures: the car's box against the target, the wall and the floor against the plate, the contact
  shadow under the car, the view and the direction of the nose. Inside views: the view. A refusal names its reasons; the next
  try is told them; three tries, then flagged for an Admin with them. The verdict is kept on the photo (`r45.gate`).

## Renders made before r48.3: checked in place, not made again

Sending every existing render back would have put "Photos coming soon" on the whole site. Instead each render made before
r48.3 stays on the site (`r45.regate`) while the studio gate checks it as it is (job `photo_r45` with input `r45.regate`: one
check call, no new image). Passed: kept, cropped onto its view's target. Refused: off the site and made again from the start.
The checks and the renders go by demand (`app.photo_r48_cars`): the most viewed cars first, the bookable ones (published and
available) first among cars viewed alike. Flagged renders (never on the site) are made again.

## Studio renders only, everywhere

- `app.public_listing_photos`: only renders that passed the gate at r48.3 (`app.photo_render_live`), in the site's order; a car
  with none (and every example car) shows one placeholder, "Photos coming soon", in the scene's empty plate
  (`/studio/coming-soon.jpg` until a plate is made). Never the car's own photos, a drawn sample or another car's photo.
- The listing row's cover is the gallery's first photo, so the cards, landing, area and class pages (their snapshots are taken
  again), the Open Graph image, the JSON-LD, the partner feeds (and the channel API) and the sitemap agree; the placeholder is
  left out of the feeds and the sitemap.
- **The hero and the home sections.** They showed rembg cutouts of whatever photo `app.site_cutout_source` found (an owner's
  photo, a check-in photo, the model's stock photo) on drawn plates: never the renders. They now show the gated renders
  themselves in turn (`app.site_studio_covers`, the side profile), or the studio placeholder; cutouts (the cards' drive-off)
  are made only from live renders.
- The cards no longer show other cars' covers over a sample photo.
- **Emails**: the car picture is the car's first live render, else none (the name panel).
- **Admin and Fleet**: Photo standard > **Studio grid**: every published car's nine views side by side with the gate's verdict.

## Tests

- Unit: `studio-gate.test.ts` (framing, crop, wall, floor, shadow, view, direction), `r48.test.ts` (r48.3, one plate, the worker
  through the gate).
- DB: `supabase/tests/99_r50ph_studio_only.sql`.
- e2e: the car page and the cards show the placeholder (never a drawn sample or the car's own photo), the hero shows renders or
  the placeholder and no drawn plate.

## Guides

- `admin/fleet-and-listings`: studio renders only, the studio gate, Photos coming soon, the Studio grid.
- `va/fleet`: the same, short.
