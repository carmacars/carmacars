# Every car photographed the same way, the same photos everywhere (Release 48: 3030)

Migration `3030_r48_photo_studio.sql`. Photo standard r48.2.

The owner asked for every car to look photographed in one studio: every standard view in the exact same angle and framing, generated when a view is missing and re-rendered when a real photo is off-angle, the covers facing the same way as the sample covers, a background that really changes, and the same processed cover on the home page, the cards and the car page.

## Why nothing was generated

The live fleet had no generated view at all and most cars had never run:

- The job queues views only while fewer than 12 photo steps wait. Twelve older steps of one car waited forever, so it never queued anything. Their quality check could not be asked, which was filed as a quota wait: queued again every 10 minutes, with no try counted and no end.
- Google refused some calls with "User location is not supported for the API use": the Cloudflare cron that runs the worker can start in any data centre. That was filed as a refusal of the photo.

## What changed

- **Gemini from an allowed place.** A call refused for its location is sent again through the company server in Canada (Kong route `/gemini/`, service key only; `web/src/integrations/photos/gemini-route.ts`), and the rest of that Worker's calls go straight there. `GEMINI_RELAY_URL` can point elsewhere. The Kong change goes live with the next `vps-provision` run; until then a refused call waits and tries again.
- **Retries that end.** A failure that is not the photo's (location, time-out, network, the model) waits 10 minutes, doubling up to 6 hours, with no try counted; the eighth wait in a row counts as a try, so a view is flagged rather than stuck. Only steps due within 10 minutes count against the batch, and the old endless waits are due now.
- **Studio standard r48.2** (`web/src/features/listing/r48.ts`): every view in the car's scene, the dark dealership with the CarmaCars sign by default (the model's name on the wall behind the car on the cover), or another scene per car or for the fleet (`program_settings.listing_photo_scene`, `vehicles.photo_scene`); plates per scene. The front three-quarter and the side face left like the sample covers, the rear three-quarter right; plates taken off cleanly. A car with no photo gets its outside views from the stock photo of its model. Every view is made again to r48.2; the versions on the site stay until the new ones pass.
- **The check.** Identity problems always refuse (another model or colour, warped, wrong view or direction, the old background still there, a readable plate, a misspelled model name). Looks (framing, parts the real photos may not show, wheels, render look) refuse only the first two tries. The site also measures that the edges of the result differ from the same-angle real photo.
- **One source of truth.** Once a car's front three-quarter is made, its public photos are its generated set only, in the standard order, the front three-quarter the cover. The listing row's cover is the gallery's first photo, so the home page, search, cards, the car page, partner feeds and sitemap image tags agree.
- **Order and budget.** Covers first, then the other views; published cars first, the most viewed first (`app.fleet_trend`), then the newest. Within Gemini's daily limit less the reserve for new uploads. On by default.
- **Admin.** On a car, **Studio photos**: each view beside the car's own photos of that angle (AI marked), **Make again**, **Take off the site**, **Put on the site**, and the car's scene. **Photo standard** shows the fleet's progress and the days left at the daily limit. **Background plates** per scene.
- **Connector.** `photo_standard`: spec r48.2, `auto` is the r48 job's switch, a car's cover is `studio` when it is the generated front three-quarter, `ai_angles` counts generated views on the site, `missing_angles` the views not yet on the site, plus the car's scene and its generated set.
- **Marketplace set.** Made from the studio set when the car has one: each outside view moved into the chosen scene (the same car, angle and direction), the cover with the sign and name in the dealership, the website's own scene copied as is; up to 3 lifestyle shots (an adult model, glamorous and ad-appropriate), marked AI, chosen per post (**In the ZIP**, `?pick=`); a lifestyle shot Gemini declines is skipped. The background is measured as changed. A set's copies are made one after another (one marketing step per listing can be open at a time; before, every copy of a set pointed at the one step and the rest stayed "Being made").
- Tests: `supabase/tests/99_r48_photo_studio.sql`; `r48.test.ts`, `marketing-studio.test.ts`, `gemini-route.test.ts`.

## Guides

- `admin/fleet-and-listings`: the studio set, the scene, Studio photos, the fleet progress, the marketing set's lifestyle shots and the plates per scene.
