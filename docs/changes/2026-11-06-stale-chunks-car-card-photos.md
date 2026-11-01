# The public site: stale pages after a deploy, the date picker, car card photos, motion, the phone box

The owner, November 1, 2026: "hovering a cursor over a car on the website should do something cool too, maybe it can
like start scrolling through the pics automatically whenever a cursor is hovering over a photo. In general the front end
could use some love and animations and interactive effects". The same day, at 13:08, his car page's date picker showed
"October 2026" with no day numbers and its buttons stacked, and later: "make the phone number box cooler and simpler".

## 1. A page from before a deploy (the broken date picker)

**Cause.** Workers static assets belong to one Worker version: each deploy uploads its own `/_next/static` files and the
files of the build before stop being served. A page whose HTML is older than the deploy then asks for scripts and
stylesheets that answer 404, and the Worker answered those misses with the app's HTML 404 page. The page stays half
styled and its scripts never run. Three ways to hold such a page: a tab left open across the deploy of 12:30 (the
owner's case: the tab was opened before midnight, so its calendar still showed October), the browser's own copy (public
pages are cached in the browser with stale-while-revalidate) and the last good copy of 0106 (kept a week, served when
the database is slow).

**Fix.**
- `scripts/deploy/keep-assets.mjs`, run by the deploy job after the Worker build: the live site serves
  `_next/static/kept-assets.json` (every build file and when it was last part of a deploy); the script downloads each
  file the new build no longer has and that left a deploy less than 8 days ago (`KEEP_ASSET_DAYS`), puts it next to the
  new build's files and writes the new list. File names carry their content hash, so they never clash; Wrangler uploads
  only files it does not have. The first deploy with it carries the files the live home, fleet and car pages name. It
  never fails a deploy (a file that cannot be read is a warning).
- The Worker (and `scripts/serve.mjs` locally) answers a `/_next/static/` file it does not have with a plain 404, before
  the session refresh and the app: no HTML for a script, no render cost.
- The stale page guard (`src/lib/chunk-guard.ts`), inline first in `<head>`: a `/_next/` script or stylesheet that fails
  to load, a chunk error on a client navigation or a lazy component, or (at load) a build file answered with an error
  reloads the page once, after refetching it with `cache: 'reload'`; at most once a minute per tab. A client navigation
  to a page of another build is already a full load (Next compares the build id).
- The calendar: a page left open past midnight into a new month now moves to the first day that can be picked (the
  focus and the month shown never sit before it), and the car page's "today" is worked out again when the tab comes back
  (`useToday`).
- The date picker was checked at 375, 1024, 1152, 1280 and 1440, the car page's month and the request's two months: with
  the site's styles the layout holds at every width (cells 43 to 74 px wide, nothing past the window). The broken layout
  was the page without its stylesheet, fixed above. `tests/e2e/calendar-widths.spec.ts` keeps it so.

## 2. Car card photos

- Hovering a car card (the fleet page, the home rail, class and SEO pages, similar cars, the vehicle pages) shows the
  car's other photos in turn, one every 0.9 s, as a crossfade, with thin progress segments at the bottom of the photo.
  Leaving the card fades back to the cover.
- Nothing more loads with the page: the card carries an empty deck (`.car-card__deck`, React renders it empty and never
  touches it again). After 120 ms of hover the car's photo list is read once (`public.vehicle_photos_public`, straight
  to the database API with the anon key: no Worker CPU, no new host, no CSP change) and only the next photo is
  downloaded ahead.
- At most 5 photos, the cover included, and never past the photos the phone number box leaves free (0280).
- On a phone, a sideways swipe on the photo of a card in a grid moves to the next or previous photo; the tap that ends a
  swipe opens nothing, a plain tap opens the car. Cards in the home rail keep the rail's swipe.
- prefers-reduced-motion: nothing cycles (a swipe still changes the photo, at once).
- One delegated listener set (`src/lib/card-photos.ts`, started by `Effects`), no hydration per card.

## 3. Motion and polish

All in CSS and the existing `Effects` runtime: transform and opacity only, nothing above the fold hidden, nothing moves
under reduced motion.
- Cards: a 3 px lift with a soft shadow and one band of light across the photo on hover (fine pointers).
- The primary button: the same band of light on hover.
- The car page's photo: a 1.1 zoom toward the pointer (fine pointers).
- The home page photo settles in from 1.07 as the page opens (scale only: the LCP image is never faded).
- Reveals on scroll also for the coverage options and the hub cards; the delivery fee on the home page counts up.
- The booking widget: the days between the dates fill in, the price lines arrive in turn, a changing total runs to its
  new value in red (the estimate and the sticky bar).
- The navigation progress line has a soft red glow.

## 4. The phone number box

"What's your number? 😉", one line on what it opens ("See every photo of this car.", "See the full calendar, every
day."), one big number field (the phone's number pad, formatted as typed, focused at once) and the close button at the
top right. No Continue button and no deals box: the number is sent by itself at the tenth digit of a valid Canadian or
US mobile number, with a small spinner and then "Thanks". With the code setting on, the code step works the same way
(sent at six digits). The field has its label, errors are announced, Escape closes and the focus goes back to what was
tapped; the box keeps its light colours over the dark car header. Without the deals box the box never records a
marketing opt-in.

## Checks

- `tests/e2e/card-photos.spec.ts`: hover cycles, leave resets, a swipe moves and opens nothing, reduced motion reads and
  moves nothing, no console error.
- `tests/e2e/calendar-widths.spec.ts`: the date pickers at 375 and 1024 to 1280; a missing build file is a plain 404;
  the guard is in the head with the nonce.
- `src/lib/chunk-guard.test.ts`; `tests/e2e/phone-gate.spec.ts` follows the new box.

## Guides

No guide change: the guides describe what staff do, and none of these screens' steps changed (the phone box's
steps for a visitor are in the box itself).
