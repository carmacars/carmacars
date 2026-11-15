# Real studio photos where a sample photo was shown (Release 48: 3040)

Migration `3040_r48_plates_present.sql` (section 5).

The owner: wherever the site shows a sample photo, it should rotate through real photos taken in exactly the same angle, so it looks clean.

- **The covers.** `public.site_studio_covers` lists the studio covers of published real cars (photo standard r48.2: the front three-quarter with the nose to the left, as the sample covers), only covers that passed the check and are on the site, most viewed first. Read once when a page is built (`getStudioCovers`); a failed read keeps the sample photos.
- **Matched to the slot** (`web/src/lib/studio-covers.ts`): an example car's card shows real cars of the same body style, else of the same class; a real car with no photo of its own yet shows only real cars of the same make and model; nothing matches, the sample photo stays. Up to 4 a card, each card starting at another car.
- **Where.** The home hero (the studio covers first; the older studio photos only when no car has one yet; the Site content photo when neither), and every car card whose photo is a sample photo: home, Cars, similar cars, the landing, area and SEO pages, the language pages.
- **Light.** A CSS cross-fade (5 seconds a photo, no script) in the photo's own box: no layout shift, the sample photo shows through until the first loads, the hero's first photo is loaded first. Reduced motion: the first photo only. The card keeps "Representative photo".
- Tests: `supabase/tests/99_r48_plates_present.sql` (section 4); `web/src/lib/studio-covers.test.ts`.

## Guides

No guide change: nothing a person does changes.
