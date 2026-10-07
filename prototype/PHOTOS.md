# CarmaCars photo shot list

Every image on the site is a slot in `assets/photos.json`. Today each slot holds a drawn stand-in (black studio, a generic car silhouette, the slot name in the corner). Real photos replace them one at a time.

## How to swap a photo in

1. Export the photo to the size in the tables below. JPEG at quality 80, or AVIF or WebP if you have them.
2. Drop the file in `assets/photos/`, for example `assets/photos/mercedes-benz-c300-lead.jpg`.
3. In `assets/photos.json`, find the slot, point `src` at the new file, set `width` and `height` to its real pixel size, and set `"standIn": false`. Rewrite `alt` if the photo shows something different.
4. Run `node tools/build.mjs`. Every page and the single-file build pick it up. Slots marked `"standIn": false` are never overwritten by `tools/make-standins.mjs`.

No HTML or CSS changes are needed. Every frame crops with `object-fit: cover`, so keep the car inside the middle 80% of the picture.

## The look

- **Background:** dark and plain. A black or charcoal studio wall, an underground garage, or a wet street at night. The site is black where photos sit, so bright daylight backgrounds will look cut out.
- **Light:** one soft light from above and slightly in front. Keep a visible reflection or shadow under the car.
- **Angle:** camera at headlight height, never from standing eye level. Wheels turned slightly toward the camera on three-quarter shots.
- **Car:** just detailed, plates on, no people, no stickers, fuel door shut, windows up, headlights on for the lead shot.
- **Framing:** landscape always. Leave empty space on the left third of scene photos; headlines sit there.
- **Consistency:** same spot, same lens, same height for every car. That is what makes a fleet page look like one fleet.
- **Not allowed:** AI-generated images, manufacturer press photos, stock photos, or photos of a different car of the same model.

## A. Per car: 8 photos (96 for the 12 sample cars)

All 3:2 landscape, at least 2400 x 1600 px (the site shows them up to 1200 px wide on high-density screens). The order is the gallery order.

| # | Slot key | Shot | Notes |
| --- | --- | --- | --- |
| 1 | `lead` | Front three-quarter, driver's side | The hero of the car page, the fleet card and search results. Headlights on. This one matters most |
| 2 | `side` | Full side profile | Dead level, whole car with space at both ends |
| 3 | `rear34` | Rear three-quarter, passenger side | |
| 4 | `front` | Straight on, front | |
| 5 | `rear` | Straight on, rear | |
| 6 | `dash` | Dashboard from the back seat, centred | Ignition on, screen lit, steering wheel straight |
| 7 | `seats` | Front seats through the open driver's door, or the rear seats | Pick whichever shows the cabin better; for 7 seaters show the third row |
| 8 | `wheel` | A detail: wheel, badge, shifter or open roof | The one shot with personality |

These are a subset of the listing photo set in operating procedure 17 (eight exterior angles, dashboard, front seats, rear seats, trunk, one wheel, odometer). Shoot the full set once; the site uses these eight.

## B. Scene photos: 9 slots, 6 distinct scenes

Each slot needs two crops of the same scene: **wide** for desktop and **tall** for phones.

| Slot key | Where it shows | Scene | Wide (min px) | Tall (min px) |
| --- | --- | --- | --- | --- |
| `home.hero` | Home, top | A fleet car parked on a Toronto street at night, low angle, city lights behind. Car in the right half, dark space on the left | 2:1, 2880 x 1440 | 4:5, 1200 x 1500, car in the lower third |
| `home.delivery` | Home, delivery band | A car arriving in a residential driveway at dusk, front door light on, staff member holding keys | 21:9, 2880 x 1234 | 4:5, 1200 x 1500, subject in the lower half |
| `delivery.hero` | Delivery page, top | A second frame from the same delivery shoot: the handover at the door | 21:9, 2880 x 1234 | 1:1, 1200 x 1200 |
| `home.owner` | Home, owner band | Three or more fleet cars lined up nose to tail or side by side | 21:9, 2880 x 1234 | 1:1, 1200 x 1200 |
| `owners.hero` | List your car, top | The same line-up from a second angle, or an owner handing over a key | 21:9, 2880 x 1234 | 1:1, 1200 x 1200 |
| `how.handover` | How it works, return band | Close on keys passing between two hands, car out of focus behind | 3:2, 2400 x 1600 | 1:1, 1200 x 1200 |
| `requirements.band` | Reserved | A second close detail: licence and card on a counter, or a hand on a fob | 21:9, 2880 x 1234 | 1:1, 1200 x 1200 |
| `fleet.band` | Fleet page, lower band | A fleet car moving on an Ontario highway, slight motion blur | 3:1, 2880 x 960 | 4:3, 1200 x 900 |
| `contact.city` | Contact page, lower band | Toronto street or skyline at dusk, no car needed | 21:9, 2880 x 1234 | 1:1, 1200 x 1200 |

Scene photos sit under text with a dark gradient over them. Underexpose slightly and keep the left third (wide) or top half (tall) free of bright objects.

## Summary

| Set | Count | Ratio | Minimum size |
| --- | --- | --- | --- |
| Car gallery | 8 per car (96 for 12 cars) | 3:2 | 2400 x 1600 |
| Scenes, wide crops | 9 | 2:1 to 3:1 | 2880 px wide |
| Scenes, tall crops | 9 (crops of the same frames) | 4:5 or 1:1 | 1200 px wide |
| Distinct scenes to shoot | 6 | | |

Priority if time is short: (1) the `lead` photo for every car, (2) `home.hero`, (3) the rest of each car's gallery, (4) delivery and owner scenes.

Later, for sharing links: one 1200 x 630 social card per car can be cropped from its `lead` photo. No slot exists for it in the prototype.
