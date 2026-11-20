# Operations screens: a calendar that works with 100+ cars, check-outs, one portal, the owner's bookings (Release 48, part OPS)

Migrations 3290 (the calendar's read), 3291 (the earnings calculator's settings), 3299 (guides and academy). Branch `r48-ops`
(on `r48-int`). The owner's list of November 20, 2026 ("UI/UX"): the calendar is unusable with the long car list; a return is
a check-out, show its time, and make the return check-out and the post-trip cleaning two jobs; the owner's bookings page is
confusing; several portal accesses should be one portal; the onboarding screens show no button; text is squished; Unfinished
rentals sits where it makes no sense; the host calculator is too optimistic; and with the call-helper panel open, More
actions > Decline did nothing.

## 1. The fleet calendar (Admin, every staff function, the car page's Calendar tab)

One component (`web/src/features/admin/MasterCalendar.tsx`) serves all of them, so each change is in every portal.

- **Find a car in a long list.** Search (car, plate, fleet number, booking, surname), filters by **Car status**, **Class**,
  **Owned by** and **Availability** (available now, free today, free every day shown, out or booked now, blocked or on hold,
  not bookable), with the less used ones (Not blocking, Insurer, who supplies the car) under **More filters**. A filter that is on
  is marked; **Clear** takes them all off; the count says "23 of 140 cars, 9 free today". Customer service and Sales are not
  given owners (the database leaves them out), so they get no owner filter or grouping.
- **Groups that fold.** **Group by** class, owner, car status or availability: a heading per group with its car count and how
  many are free today; press it to fold its cars; **Fold every group** / **Open every group**. The grouping and the folded
  groups are kept in the browser (`localStorage`), nothing on the server.
- **Rows drawn near the screen only.** Above 40 rows the calendar draws the rows that touch the visible part (600 px either
  side) and leaves space of the same height for the rest; each drawn row's real height is measured, so the list does not
  jump (`calendar-fleet.ts`: `windowOf`, `topsOf`). A fleet of 40 cars or fewer is drawn whole, as before. The phone agenda
  lays out only the days near the screen (`content-visibility`).
- **A return is a check-out.** The booking panel says **Pickup (check-in)** and **Return (check-out)**; once the car is back
  it shows the time it actually came back, with the time it was due. The field portal's return steps read "Return check-out:
  photos and readings" and "Post-trip cleaning: clean check" (they said "Return photos and check-in").
- **Two jobs at the end of a trip.** Under the bars, each trip that ends in the days shown has two named chips: **Check-out**
  with its time (the actual time and a tick once the car is back) and **Cleaning** (the post-trip cleaning, with its window; a
  tick once the clean check after the return is recorded). They come from the return field job and the cleaning block the
  trip leaves (0040); a trip with neither on file (jobs made by hand, or a role that is not given field jobs, such as Sales)
  gets both from the booking itself. Every other field job is a chip with its name too (they were unnamed pins). Chips at the
  same time sit one above the other. The cleaning block is no longer drawn as a bar; its chip opens the same panel, with
  Remove the block.
- **The read is fast** (3290). `app.admin_calendar` read the `calendar_entries` view through `app.master_calendar` (asking
  who may see what again for every row), built the JSON, then took it apart car by car for the placeholder flag, the clashes
  (the turnaround looked up for every pair of bars) and each offer's hold. It is now one set-based read of the base tables:
  who is asking is worked out once, each table is read once for the dates asked (new indexes: bookings by return, field jobs
  by time and by completion, Turo trips by end), the clashes are one join. Measured on this machine while it was busy: the
  seeded fleet (82 cars, 2 weeks) 410 to 520 ms before, 21 to 52 ms after; 242 cars with 1,642 bookings, 2 weeks: 7.6 to 8.7 s
  before, 142 to 148 ms after; a month: 12.8 to 17.7 s before, 229 to 303 ms after. What each role is given is unchanged: the
  old read stays as `app.admin_calendar_pre3290` and the DB test compares the two, entry for entry, for an Admin, Fleet,
  customer service, Sales, Finance and an owner. New fields only: `returned_at`, `cleaned_at`, `for_booking`, `done_at`, `job`.

## 2. The owner's Bookings page (Cars > Bookings)

It was a short "Coming up" list, the rental history table, then "All bookings" in one undivided list. Now, in order:

- **Your cars, the next six weeks**: a row a car, a bar a booking (on a trip, booked, finished, your own use, unavailable),
  today as a line; a free car says so.
- **Filter by car**: a chip per car (it filters the lists, the timeline and the rental history together).
- **On a trip / Upcoming / Past**: three tabs with their counts, opening on the first that has a booking; switching is instant
  (the lists are already on the page) and the address keeps the choice (`?when=`).
- **One card a booking**: its dates, the car, the number, the status in plain words, and its money on the right. The money
  follows the revenue-visibility rules of 0156 exactly as before (`viewOf`, `amountText`): the rental charge before tax when
  the owner may see it; **Booked**, "the amount comes with your approved statement", while it is held; **Unavailable**, "not
  part of your revenue", for a booking not shown to them (never an amount, a number or a renter); **Your booking** for their
  own use. A line above each list adds up the bookings, the days and only the amounts shown. Booking expenses and a booking's
  own Revenue Share stay on its card.
- Past shows the 12 most recent with the last six weeks as a timeline; every rental stays in the paged Rental history under
  it. The month calendar and Book my own car are unchanged.

## 3. One portal, several roles

A person with more than one role (Sales and Field work, an owner who is also staff, an Admin who owns a car) got a "Choose a
portal" page after sign-in, an "Also:" row of portal links, and inside the staff portal a second switcher for the function.

- **One role switcher** in every frame (Admin, staff, owner, investor, renter): **Working as** lists every role of the
  account: Admin, each office function, Field work, Investor, Owner, My rentals. The current one is marked. It replaces both
  the "Also:" row and the staff frame's function switcher.
- **Merged navigation**: under it, **Pages of your other roles** opens the most used pages of each role the person is not in
  (a short list per role, `features/access/roles.ts`); a page of another office function opens in that function
  (`/staff/switch?fn=&to=`, a staff address only).
- **No chooser stop**: sign-in opens the role used last on the device (a cookie with the role's key), else the first role.
  `/choose-portal` still answers for a bookmark.
- **Permissions exactly as they were.** The switcher only lists links; every page still checks the role and the second
  factor itself, and the database decides. Nothing in `door`, `vaPage`, `requireOwner`, `requireStaff` or any policy changed.
  The e2e test opens an Admin page as staff plus owner and is still refused.

## 4. Staff onboarding screens (layout only)

`/staff/welcome`, coordinated with r48-fe (agreement, then academy, then WhatsApp with the member tag): no file r48-fe edits
is touched and no step, order or action changed; the polish is CSS in `styles/va.css`. The step to do now is the one card
that stands out ("Do this now", a 52 px primary button, full width on a phone); done steps go quiet; steps still to come are
dashed; the WhatsApp step is one tile a group (Join, then its member tag) and one confirm button with its own line; and a
current step that has nothing to press (the agreement being made) says so instead of showing a blank card.

## 5. Squished text: the sweep

`web/scripts/squish-audit.mjs` (r48) now also runs at 1280, and the people and cars it makes carry long names and large
numbers (a 60-letter renter name, a 50-letter model name, a five-figure rental charge). On a small machine it runs in
chunks (`--chunk=i/n`) against a restarted app, and `--seen=` reads each page once across the staff roles. What it found and
what was fixed is listed under "Sweep results" below.

## 6. Unfinished rentals, only where it belongs

It sat above every Add a rental and Send an offer form (Admin, staff, field) and on every staff function's Today. It is now
on the **Admin's Today and Bookings** and on **Sales' Today and Bookings**, redesigned: who saved it last and when, the car
held until when, what is still missing as chips (five, then "+n more"), one primary button a row, older ones under "Show
older". The forms keep one quiet line with the person's **own** drafts ("You have an unfinished one"), so nobody loses what
they typed; field staff still reach their quick-start drafts from Add a rental.

## 7. The host earnings calculator: conservative and seasonal (3291)

It started at 18 rented days a month at the full listed rate, and showed a year as twelve of that month.

- The slider is the **days rented in an average month**, 4 to 22, starting at **12** (Program setting).
- Each rented day earns the listed rate **less 15%** (weekly and monthly rates, promo codes, offers; Program setting).
- The year is worked **month by month** over the GTA season (Program setting, the calculator's own curve): June 1.10, July
  and August 1.30 (summer busiest); December 0.85, January and February 0.75 (winter slow); March and October 0.70, April
  and November 0.65 (the shoulder months slowest); May and September 0.85. The page shows the average month, the year as the
  twelve months added up, the range from the slowest month to the busiest, and the rented days of each month as bars.
- With the fees set, it says in how many months the share does not cover them.
- **A clear disclaimer**: "A rough estimate, not a promise. We lean low on purpose..." in its own box, above Apply.
- Example, a $100 a day car at a 70% share: before, $1,260 a month and $15,120 a year; now about $620 a month and $7,438 a year (before fees).

## 8. Admin booking: Decline with the call-helper panel open

Cause: the caller panel is fixed at the bottom right and, with the Call helper showing, as tall as the window. It sat on
top of the page's action row, so a press on **More actions**, or on **Decline** in its menu, landed on the panel and nothing
opened (a press inside the panel does not minimize it). Fix (`features/caller/caller.css`): on a wide screen the portal's
page moves over and the panel is docked beside it, so nothing of the page is under it; between a phone and that, the panel
takes at most 56% of the height, so the page's heading and buttons stay free (a phone already had 50%). Admin and staff
alike (the same frame). The e2e test checks that neither More actions nor Decline is under the panel, then declines.

## 9. Admin changes reach the staff portals

The calendar, its filters and jobs: one component for Admin, every staff function and the car page. Unfinished rentals:
Sales' Today and Bookings. The call panel fix: the staff frame too. The role switcher: every frame.

## 10. The pickup identity check (3292, 3293)

The owner (Nov 20): at the pickup, confirm that the person taking the car is the renter. Optional, always offered, and it
never stops a check-in.

- Where: the field checklist (**Renter, licence and card**, under the tick "I checked the original licence"), the
  one-screen check-in on the booking page (Admin and every staff portal), and the renter's own check-in.
- Staff photograph the licence the person is holding (the back is optional: its barcode is read exactly). The renter at a
  self check-in photographs the licence and takes a selfie at that moment. The photos are kept as their own kind
  (`licence_front_pickup`, `licence_back_pickup`, `selfie_pickup`, status `at_pickup`), with the ID images (private bucket,
  deleted with them after 90 days). They never replace the licence on file and never reset the identity check.
- Side by side: the step, and **Review the licence** on the booking, list the pickup photos with the licence and selfie on
  file; each opens with View (logged, one minute).
- The automatic check (`app.pickup_identity_record`, all comparing in SQL): the name against the driver on the booking,
  the licence number and the expiry against the ones on file (an expired licence is a mismatch), and the face against the
  selfie or licence on file. The reading uses the existing vision adapter under the purpose `licence_read`, which is never
  sent to Gemini. The face answer is kept only when the model is sure ("different" at 80 or more); anything else is
  "Could not tell" and flags nothing.
- The payment card: the step shows the card on file (brand, last four, cardholder name) and the name on the booking.
  **The card is not photographed.** A photo would have to pass through the server and a vision provider, and an image of a
  card (full number, sometimes the security code) cannot be handled there within PCI rules; so the owner's fallback is
  used: the staff member looks at the card and answers Yes or No for its last four digits and its name. Only the last four
  digits of a confirmed card are kept (a constraint refuses anything longer). The cardholder name on file is also
  compared with the name read from the ID automatically.
- A mismatch: an urgent To do "Possible wrong person at pickup" for Fleet and one for Admin (one each per booking, not one
  per check), the staff alert `pickup_wrong_person` (Admins and Fleet on duty, urgent), and the booking is marked: the
  booking page shows the mark and each line of the check while a To do is open. On a card-coverage rental (option 2) a
  card not in the renter's name is also raised as "Coverage problem at pickup". On a match in the field, the licence tick
  is set for the staff member.
- Evidence: every check (matched or not) is a row of `pickup_identity_checks` (RLS on; functions for the server only), in
  the audit log, and in the dispute pack ("Identity check at the pickup", with the photos among the licence images).
- Tests: `supabase/tests/99_r48ops_checkin_id.sql` (48 assertions), `features/pickup-identity/model.test.ts`.
- To confirm with the owner: the wording renters agreed to covers licence and selfie photos for verifying identity; a line
  naming the comparison at pickup would make that explicit. Automatic face comparison by a general vision model is a
  help, not proof: the staff member's own look at the licence stays the check that counts.

## Sweep results

What was run, and what was not. The machine this was built on (2 CPUs shared, the app killed for memory at 4 GB) cannot
hold a production build, and against the development server the sweep reads about one page a minute, so the full run of
every route at five widths was not completed here. It is one command on a build (`node scripts/squish-audit.mjs`, in
chunks with `--chunk=i/n`), and it should be run on the integration branch before the release.

- Checked at 320, 375, 768, 1280 and 1440 with long names and large numbers (the e2e of this change fails on any
  horizontal overflow, and takes the screenshots): the fleet calendar (Admin and Sales, timeline and agenda), the owner's
  Bookings (three lists, car filter, timeline), Unfinished rentals on Today and Bookings, the role switcher in the staff
  and owner frames, the Welcome steps, the earnings calculator, the Admin booking page with the pickup identity step
  open and with the mark. The whole spec also passes on the 375 phone project.
- The owner portal, first pass of the sweep tool: 11 findings, fixed in `portal-ui.css` and `owner.css` (money columns,
  bar values at the edge, a car's stats under 26rem, the hero cars stacking, the forecast table scrolling inside its card,
  the months table's car column). The second pass to confirm them did not finish (the pages did not load in time).
- Found by the checks above and fixed: the calendar toolbar and the agenda cards pushed the page wider than a 320 phone
  (grid columns sized by their content); "Possible duplicates" on a booking did not wrap a long name or email; the pickup
  identity step's file fields.
- Not swept here: the rest of Admin, the staff portals beyond the screens above, the field portal, the renter account and
  the public site.

## Definition of done

- Notifications: one new staff alert, `pickup_wrong_person` (urgent; Admins and Fleet on duty; on the Text alerts list like
  the others), with its two urgent To do's (section 10). Nothing else here sends, bills or changes a booking; the calendar
  jobs are a reading of the return and the cleaning that already exist (their own alerts are unchanged).
- Design: the existing tokens and components; borders in alpha, fields at 16 px, hover only under `(hover: hover)`, motion
  120 to 220 ms with ease-in-out and off under reduced motion, 44 px targets, no `100vh`; plain-word empty states (no car
  matches, no booking in a list); the portal skeletons (r48-pf) cover the pages. No animation was added to the rows staff use
  all day.
- Layout: checked at 320, 375, 768, 1280 and 1440 (Playwright screenshots of every changed screen at the five widths, in the release notes folder `hotfix-notes/r48-ops-shots/`; not in this public repository).
- Tests: unit (`calendar-fleet`, `owner/bookings`, `access/roles`, `supply/unfinished`, `owner/earnings`), DB
  (`99_r48ops_calendar.sql`, `99_r48ops_checkin_id.sql`), e2e (`tests/e2e/r48-ops.spec.ts`, and the changed `signin`, `owner-calculator` specs).
- Evidence and audit: no money or fee is created here. Each pickup identity check is kept, written to the audit log and
  put in the dispute pack.

## Guides

`admin/calendars` (find a car in a long fleet, check-out wording, the two jobs), `admin/getting-around-admin` (one portal,
several roles; Unfinished rentals), `admin/owners-and-onboarding` (the calculator's three new settings), `va/shared-tools`
(the calendar; one portal), `va/add-a-rental-by-hand` (your own unfinished ones), `owner/bookings-and-your-own-use` (the
Bookings page), `owner/quick-reference`. The pickup identity check: `admin` (the bookings chapter), `va/shared-tools`, `field/a-handover`, `renter/before-pickup`.
Academy: the section "The calendar, check-outs and one portal" on every staff path
(4 lessons, 7 questions; staff who had passed everything get 7 days). The guide screenshots of the Calendar and of the
owner's Bookings are retaken by the guides workflow after the deploy.

## For the merge

- `owner/bookings-and-your-own-use` in `docs/guides/content/owner.json` is also edited by r48-fe (Book your own car): both
  edits are needed (this one rewrites "See your bookings").
- `web/src/app/owner/vehicles/BookingsTab.tsx`: r48-fe changes the `bookable` line; this branch leaves that line as it was.
- `web/src/lib/schema-marker.ts` is 3299 here.
- r48-fe is not merged into this branch (it is not in r48-int yet, and merging it here gave 13 conflicts that belong to the
  integration). `web/src/features/field/Checklist.tsx` gets two added lines here (an import and the step under the licence
  tick), away from r48-fe's hunks.
- `docs/guides/content/field.json` (a-handover) and `renter.json` (before-pickup) each get one sentence block here.
