# A cleaner fleet calendar for the Admin and staff (Release 48)

No migration. The calendar reads the same data as before.

The fleet calendar (Admin > Calendar, every staff portal's Calendar, and a car page's Calendar tab: one shared component, `web/src/features/admin/MasterCalendar.tsx`) was hard to read: car names cut after a few letters, bar words that showed only a surname or a single letter, hatching behind the words, the now line drawn over the bars, and a car column that took two thirds of a phone screen.

- One stylesheet, `web/src/features/admin/master-calendar.css`, imported by the component, so every portal gets the same look; the old calendar rules in `admin.css` and `bookings-now.css` are gone. Colours come from the site's tokens, set once as `--cal-*` pairs (fill and words) that pass AA.
- Each car is a row: photo, the full name on up to two lines (never squeezed), code and plate, and its status in red when it is not available. The car column keeps one width (15rem; 8.75rem on a phone, without the photo).
- Bars show the renter first and the booking number after (`calendar-label.ts`): requests, offers and payment due say so; placeholders, not blocking and insurer follow. A bar too short for words shows none; the full words stay in its title. The words stay at the visible edge when the days scroll.
- Bookings out are red, booked black, done grey, requests light grey with a dashed edge, offers and holds light amber (payment due with a solid left edge), maintenance light blue, other blocks lightly striped, placeholders dashed. Turo trips and car moves stay thin strips at the foot of a row.
- Today: the date in a red circle in the header, and the now line under the bars. Weekends shaded in the header.
- The date header shows the weekday over the date, the month on the 1st, and the month and year in the corner with the number of cars. Wider days: a week 132px a day, two weeks 80px, a month 44px.
- Only the calendar scrolls sideways (the page never does, at 360 or 1280); the car column and the date header stay put.
- Is the car free? (owner follow-up) Each car shows a badge for right now: **Available now** (green), **Out now: renter until date** or **Booked now** (red), **In shop until date**, a block's reason, **On Turo** (grey), or **Not bookable** / **In shop** for a car that cannot be booked, and under it how many of the days shown from today on are free (`availability` in `calendar-label.ts`).
- What takes the car (a blocking booking, a block, a Turo trip; not requests, offers, placeholders or non-blocking bookings) is tinted across the whole row height: red out, grey booked, blue maintenance, beige other blocks, teal Turo. White is free. A car that cannot be booked (onboarding, ready to list, out of service, exited) is greyed out across its row.
- **Only cars free for these dates** keeps the cars free every day shown from today on; the corner says how many cars are free today ("4 of 6 free today"). The legend starts with white: free, tinted: taken, not bookable.
- Rows are a little taller (bars 22px with a 4px gap) so overlapping bars stack without touching.
- Tests: `web/src/features/admin/calendar-label.test.ts` (bar words, day widths, the one stylesheet, sticky rules); `calendar-stack.test.ts` updated for the new row height; `web/tests/e2e/fleet-calendar.spec.ts` (Admin and Fleet staff at 360 and 1280, each view: no page overflow, sticky car column and header, today marked, no bar on another, a badge on every car, the free count and the free filter).

## Guides

No guide change: the calendar does the same things, it only reads better.
