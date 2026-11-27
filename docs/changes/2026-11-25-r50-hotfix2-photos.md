# Hotfix 2 R50: studio photos that can pass, and a cost guard (5080, 5089)

Migrations `5080_r50h2_studio_composite.sql`, `5089_r50h2_photo_guides.sql`. The owner (Nov 25): the Gemini studio renders keep failing the gate and cost money; production has no passed r48 render. "Generate each vehicle in every single angle using the photos that are provided to you, and if those photos aren't there, then you can use the check-in and check-out photos instead. And the vehicles should all be in the exact same angles as the sample photos, and in the same order as well. And if real photos are available, then they can be added after all of the correct angles. But they still have to have the cutouts and be on the same background."

## What was wrong (the code around Gemini)

- **The prompt asked for something the gate then refused.** r48.3 (3701) asked Gemini to paint the car into the background plate. The studio gate then compared the wall, the floor and a contact shadow with the plate (mean colour within 0.085 and 0.11, `studio-gate.ts` before 5080). An image model redraws the whole frame. Also, the worker cropped the render onto its target and compared it with the plate not cropped (`worker.ts` before 5080: `cropResize` on the render, `fitFrame` only on the plate), so the compared regions were different parts of the room. The check let a nose "camera" pass that the gate refused (`r48.test.ts` before 5080: "a direction the check cannot place is not a refusal"; `studio-gate.ts`: `o.nose !== face`). Each refusal came after the image and the check were paid.
- **The images did not match the words.** The render chain (r48 AN, `integrations/renders/chain.ts`) took the check-in and check-out photos out before Gemini, while `imageRoles` still numbered them as the car. The drawing and the stock photo were then "THIS car". A car with only those photos could not be made. A car with no photo sent the guide first while the words said image 1 was the stock photo. The chain's first step (Workers AI image-to-image) could not make the asked view and spent a try of every view.
- **The same paid input was sent again.** When the check did not answer, the step was a free wait (3030: up to 8 a try), and each wait made and paid the image again.
- **Gemini's cost was not counted.** `app.showroom_ai_gate` recorded every call at 0, and the photo budget (`photo_daily_budget_microusd`) held only upload steps (2530), so the 10 USD a day never held a studio step.
- **The connector's `photo_standard` failed on every call.** `app.comms_listing_files` (3870) had one ")" too many ("syntax error at or near )").

## Changes

- **Standard r48.4.** Gemini makes only the car, alone on a flat key colour (green; magenta for a green car), from the car's listing photos; when it has none of the view's side, from its check-in and check-out photos (`app.photo_r48_refs`). Every image is sent as the words number it. The site keys the car out (`studio-gate.ts chromaKey`) and puts it on its own drawn dealership with the CarmaCars sign and the car's name, at the view's size and place (`studio-composite.ts`). Inside views are kept as made.
- **The gate and the words agree.** The gate checks what the words ask: a flat key and the whole car in the frame. It runs on the site's CPU before the check is paid. The view and the direction follow one rule (`r48.ts viewReasons`), used by the check's verdict. The framing words no longer ask for a floor or a share of the frame.
- **Order.** The views show in the sample photos' order (`features/car/studio.ts SHOTS`: front three-quarter, side, rear three-quarter, front, rear, dashboard, seats), then rear seats and trunk (`app.photo_render_order`). The front three-quarter is the cover; the cards' drive-off uses the cover's cutout (`app.photo_shot_cutout`). Then up to `listing_photo_r48_extras` (6) of the car's real outside photos, each cut out on the same dealership (shot `studio_extra`, `app.photo_r48_extra_queue`).
- **No paid call twice for the same input.** A render whose check did not answer is kept privately and checked on the next try. A photo gets at most `listing_photo_r48_daily_tries` (3) image calls a day (in the gate). A refused view waits 20 minutes, then an hour. Nothing is called when the car's photos cannot be read. The check in place of 3701 is over (its refusal restarted the tries).
- **Cost.** Each image made costs `listing_showroom_ai_call_microusd` (39000, 0.039 USD) in `provider_calls`, with the photo it was for; the photo budget holds the studio steps. The cost guard (`app.photo_r48_cost_guard`, every job run) pauses the studio for 24 hours and alerts the Admins (`photo_studio_paused`) when the image calls of the last 24 hours are more than `listing_photo_r48_max_calls_per_pass` (8) for each view that passed. Photo standard shows the calls, the spend and the pause.
- **Connector.** `photo_standard` reads again.

## Not checked here

- A real Gemini render: the tests use a fake image model. After the deploy, the first live renders show whether Gemini keeps a flat key and the whole car (the gate's refusal reasons on Photo standard), and whether the check's view and nose answers pass.
- The CI e2e failures outside this change (guide-me, owner portal, oauth and others) and `r50-cards.spec.ts:177` (the vertical scroll on a phone).

## Tests

- DB: `supabase/tests/99_r50h2_studio_composite.sql` (new): the order, the references and their fallback, the cap a photo a day, the cost, the photo budget, the pause, the backoff, only r48.4 renders live, the extras, the cost guard and its alert, the connector. The 3701, 3150 and 5064 tests follow the new rules (`99_r47_photo_r48`, `99_r48_photo_studio`, `99_r48an_renders_identity`, `99_r48o_cutouts_forecast`, `99_r48_plates_present`, `99_r50ph_studio_only`, `99_r36b`, `99_r36x`, `99_r40`, `99_r43`, `11`, `19`, `34`, `44`, `51`).
- Unit: `r48.test.ts`, `studio-gate.test.ts`. e2e: `r50-cards.spec.ts` (the cover's matte), `real-car-format.spec.ts` (8 stand-ins).

## Guides

- `admin/fleet-and-listings`, `va/fleet`: the studio views, their order, the cut-out on the dealership background, the real photos after them and the cost guard (5089).
