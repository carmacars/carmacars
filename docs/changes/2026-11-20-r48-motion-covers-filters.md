# Renders first with the side profile as the cover, cars that drive off their cards, the logo drawn, micro-interactions everywhere, one model per family (Release 48, part AN: 3150, 3151)

Migrations `3150_r48an_renders_first.sql`, `3151_r48an_car_identity.sql`.

## 1. Every car rendered, the side profile first (3150)

The owner: every car's first photo is a clean side profile, the nose pointing the same way for every car, the front three-quarter second. Then: AI renders the whole photo-standard set of every car from its own photos (same colour, wheels and trim), so every car is framed the same; the renders first, then the car's real photos on the same branded background; renders go live at once (no approval step), staff can make any of them again or replace it; a backfill for every published car; new cars get renders on upload; spend capped by the existing guard; a small note on the car page; the real photos never hidden.

- **Gallery order** (`app.public_listing_photos`): the passed renders in `app.photo_render_order()`: side profile (nose to the left), front three-quarter, front, rear three-quarter, rear, dashboard, front seats, rear seats, trunk; then the car's real photos (their processed version) in the car's own order. Renders are marked `generated`, real photos `real`. A car with no render yet keeps its gallery as before. A flagged or hidden render is never shown.
- **Cover** (the listing row: cache, search, cards, partner feeds, sitemap): the gallery's first photo, so the side render; `cover.cutout` is its side cutout (3080's `site_cutouts`, rembg), `rendered` counts the renders.
- **Live at once.** A render is on the site as soon as it passes the existing check (3030). Staff: **Studio photos** on a car (3030): **Make again**, **Take off the site**, **Put on the site**; taking the side render off makes the next render the cover.
- **The job** (`app.job_photo_r48`, every 5 minutes, on by default): the backfill's cars first, then the most viewed; per pass the side profile of every car, then the front three-quarter, then the other angles; then, for a car whose renders are made, its real photos get the branded background (2840's r45 edit; Program settings `listing_photo_real_bg_auto`, on). New cars are picked up by the same job as soon as they have a photo.
- **The render chain** (`web/src/integrations/renders/chain.ts`, `server/render-providers.ts`, used by `makeR48` through `angleAi`): Workers AI image-to-image first, only for a restyle of a real photo already at that angle and only on the first try (it cannot turn a car; a refused result goes to the next provider); then Gemini image, given only non-sensitive photos (a check-in or check-out photo is never sent to it; with only those it is not asked). The r48-ai branch's AI chain is not on this branch; the chain is the small interface asked for, ready to merge behind it.
- **Spend.** Gemini: the existing gate (`server_showroom_ai_gate`: Program settings' daily limit less the reserve, `app.photo_gemini_left`); Workers AI: the existing usage guard (`aiRoom`). One car: 9 renders at Gemini 2.5 Flash Image's paid rate (about US$0.039 an image) plus the checks (text answers, about US$0.001 each) is about **US$0.36**; with the two retries a refused view may take, at most about US$1.10; each real photo's branded background about US$0.04. Nothing within the free daily allowance.
- **Backfill** (one shot, safe to run again): `npm run photos:render-backfill` in `web/` (`DATABASE_URL`, or `NEXT_PUBLIC_SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`), or `select public.photo_render_backfill();`, or the Admin door `ops_do photo_render_backfill`. It lists every published real car (`photo_render_backfill`), turns the switches on (`listing_photo_r48_auto`, `listing_showroom_ai`, `listing_photo_real_bg_auto`) and queues the first batch. Progress: `--status`, or `ops_read photo_render_backfill`.
- **Car page only:** above the gallery, "**Rendered photos.** The first N photos are studio renders made from this car's own photos." with **See its real photos (M)**, which moves the gallery to the first real photo (the phone number box still applies past the free photos, as for any photo). The photo count line says "(rendered)" or "(real photo)".
- A saved cutout refreshes the car's listing row.

## 2. Drive-off on the car cards

Home, Cars, similar cars, the landing, area and SEO pages and the language pages (every `CarCard`): a car whose cover has its side cutout stands on the card's own studio floor. Hover (mouse) or keyboard focus: the car accelerates off the left of its frame (its nose leads) with a slight squat and a trailing ghost for motion blur, the floor stays still; leaving the card, it eases back in from the right. Touch: once, when the card comes into view. Transforms and opacity only, no layout shift; reduced motion or the pause control: nothing moves. No cutout yet: the cover photo and the card's gentle lift, as before. (`portable/motion/react.tsx` `DriveFrame`, `motion.css` `.mo-drive`; `styles/motion-kit.css` `.car-stage`.)

## 3. The logo drawn in the home hero

The CarmaCars logo above the hero's heading: its outline strokes draw along their lines (SVG `stroke-dashoffset`, 1.5 s), then the fill fades in and the strokes fade out. Once a session (sessionStorage), decided by an inline script before the first paint; reduced motion or the pause control: shown at once. (`portable/motion/line-draw.tsx`, `features/home/logo-paths.ts`.)

## 4. Micro-interactions, site-wide and in every portal

Shared, in `web/src/portable/motion/` (tokens `--mo-fast` 120 ms, `--mo-base` 180 ms, `--mo-slow` 250 ms; standard, decelerate, accelerate and spring easings, after Material 3 and Apple HIG), mounted once in the root layout (`MotionRuntime`), CarmaCars' hooks in `styles/motion-kit.css` and `MOTION_HOOKS` (layout):

- buttons press down (scale 0.97, 120 ms) and spring back (250 ms) with the `scale` property, so a button's own transform is kept; the existing ripple stays;
- card links lift 2 px on hover (fine pointers only), with `translate`;
- focus rings on every focusable element (keyboard focus only, `:focus-visible`), the brand's red;
- checkboxes and radios pop when checked; switches slide;
- a status that says "Saved" gets a tick that pops in (`[data-mo-saved]`; `SuccessTick` for new code);
- dashboard figures count up once when in view (`.pu-stat__value`, owner amounts, totals; the existing `data-count` and `AnimatedNumber` stay);
- tab bars get a pill that slides to the clicked tab (`[role=tablist]` and the style guide's tab bars);
- toasts slide in (250 ms);
- list items added after the first paint stagger in (40 ms apart: admin tables, To do's, the fleet grid);
- content replacing a skeleton fades in (`.mo-fade-in`).
- **WCAG 2.2:** nothing flashes; a **Pause animations** control in every footer (site and portals) stops all motion and is remembered (2.2.2 Pause, Stop, Hide); the system's reduced-motion setting is honoured everywhere, including the older `motionOK()` scripts.

The route loading skeletons, `<BrandLoader/>` and the route progress bar are another part's (r48-pf) and are not touched; `LineDraw` and the tokens are ready for `<BrandLoader/>` to use.

## 5. One model per family in the filters (3151, urgent)

The filters split "CLA 250" and "CLA-Class", "3 Series" and "330i". The Cars filter listed every trim as its own option under its family; makes, trims and bodies were written several ways.

- `app.car_identity(make, model, trim)` → make, model family, trim: the make by `car_make_names` (Mercedes, MB, Chevy, VW, Rolls Royce ...); Mercedes-Benz and BMW by 0520's model codes (also "CLA-Class CLA250", "3 Series 330i"); other makes by the longest family in `car_model_families` the model starts with (the rest goes to the trim: "Range Rover Sport V6", "Escalade ESV", "911 Turbo S"); the trim cleaned (`CLA250-4M` → `CLA250 4MATIC`, `GC` → `Gran Coupe`, `Sle` → `SLE`, `AMG GT C` under AMG GT → `GT C`). A model it cannot read with certainty is kept as typed.
- On every save (the `vehicles_a1_model_family` trigger, widened) and for every car on file now (audit log `car_identity`, the listing copy and cache refreshed; the public address never changes).
- Bodies: the listing's body (`app.listing_norm_body`, widened): Sedan, Coupe, Convertible, SUV, Hatchback, Wagon, Minivan, Pickup truck, Van ("Compact SUV", "Mid-size sedan", "Four-door coupe" folded in); `vehicles.body_type` keeps the decoder's answer.
- Years: the table already refuses a year outside its range; `app.car_identity_issues()` lists a year that looks wrong and a model family not recognised, for a person to fix.
- **The filter** (`features/fleet/FleetBrowser.tsx`): makes and model families only, with the number of cars; the trim shows on the card. Old links (`?model=C300`, `?model=C-Class&trim=C300`) open the family.
- The same rule in the web: `features/vin/car-identity.ts` (+ `car-identity-data.ts`, generated from the migration's seed).
- Not changed: the vehicle catalog's SEO pages (/cars/<make>/<model>), which list the catalog's own models.

## Portable modules (for the other Almash brand builds)

No CarmaCars import, React and the DOM only: `web/src/portable/motion/tokens.css`, `motion.css`, `runtime.ts`, `react.tsx` (`MotionRuntime`, `MotionPauseToggle`, `SuccessTick`, `DriveFrame`), `line-draw.tsx` (`LineDraw`, BrandLoader-compatible); `web/src/features/vin/car-identity.ts` with `model-family.ts` and `car-identity-data.ts` (relative imports only); `web/src/integrations/renders/chain.ts`.

## Tests

- `supabase/tests/99_r48an_renders_identity.sql`: the gallery's order (side, front three-quarter, then real photos), a flagged render never shown, a car with no render unchanged, the cover and its cutout, hiding and showing a render, the job's order, the backfill and who may run it; the identity rule's cases, every save, the listing body, the filter's one family, no car left to change.
- `web/src/features/vin/car-identity.test.ts`, `web/src/integrations/renders/chain.test.ts`.
- Screenshots: `/home/claude/almash/work/hotfix-notes/r48-an-shots/` (the hero's logo mid-draw and done, a card at rest, mid drive-off and easing back, the filters before and after, the car page's note, the hero on a phone with reduced motion).

## Guides

- `admin/fleet-and-listings` should say: renders come first (side profile the cover), real photos after; renders go live at once; the backfill. Not written in this part (the guide generator is run with the release's guide pass).
