# Listing photos made to one standard with Gemini (Release 44: 2780, 2782)

Migrations `2780_r44_photo_spec.sql` and `2782_r44_photo_guides.sql`. The owner's four points on the photos made with Gemini.

- **Backgrounds not replaced**: an outside photo whose cut-out was poor (or failed) went on the site as taken, with the place it was photographed in. Now Gemini replaces its background from the original photo with the same empty CarmaCars room every car has, and the answer is used only when the room shows around the car (a bright sky or a street at the edges is refused). The prompts say no trace of the place may remain.
- **Plate text somewhere random**: the CarmaCars plate was drawn wherever the vision model saw "a plate", including the lit logo sign and the model name on the showroom wall, and Gemini was told to drop the plate, so it wrote plate text elsewhere. Now Gemini keeps the plate holder where it is with a blank face and writes no text anywhere else; the plate check asks Gemini first in its own box format, and a box where no plate can be (high in the frame, or wider than a plate) is never drawn on.
- **First photo not the same on every car**: outside photos the sorter could not read were filed as **Other detail**, kept as taken, so 22 cars showed an inside photo first and **Redo photos with Gemini** found nothing to redo. The same press now sorts those photos again (Gemini first): an outside view is filed under its shot, the front three-quarter becomes the first photo, and it is made in the showroom. Photos added outside a listing are no longer skipped.
- **Blurred interiors**: when the cut-out of an inside photo failed the window check, everything the segmenter did not keep was blurred (often all but the steering wheel). An inside photo is never blurred now; the old blurred ones are made again sharp. Every prompt asks for a photo sharp from front to back, no bokeh.
- **The photo standard** (`app.photo_spec()`, `PHOTO_SPEC` in showroom.ts): every photo records the standard it was made under, so a photo made before is made again. **Redo every car with Gemini** (Listings, Admin and Fleet) and a job every 20 minutes bring the fleet to it within Gemini's daily allowance (10 calls a day kept for new photos); a step stopped by the daily limit waits for the next day instead of failing.

## Guides

- `admin/fleet-and-listings`: the background, the plate, the sharp interiors, the detail photos checked again, Redo every car with Gemini
- `va/fleet`: what Redo photos with Gemini now also does
