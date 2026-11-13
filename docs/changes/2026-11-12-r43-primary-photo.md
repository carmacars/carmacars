# The primary photo of every car is its front exterior (Release 43: 2690)

Migration `2690_r43_primary_photo.sql`.

The first photo of every listing is the exterior at the standard angle (front three-quarter). The order is fixed at the source,
so the cards, the feeds, the share image and the Marketplace kit agree, and the cover mark follows by itself. Cars whose first
photo was an inside one were put right once.

- **Primary photo is not exterior**: a flag and a filter in Admin > Vehicles for a car whose best outside photo is not on the site yet
- **Redo photos with Gemini**: on the car page, makes every outside photo again in the showroom with the image model; the photos stay as they were if it cannot finish

## Guides

- `admin/fleet-and-listings`: the primary photo, the flag and Redo photos with Gemini
- `va/fleet`: what the flag means and the button
