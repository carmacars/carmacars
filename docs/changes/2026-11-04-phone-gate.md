# The phone number box for renters (0280)

The owner, October 31, 2026: ask renters for their mobile number before parts of the site, so we have it, and keep it
light so it does not cost bookings.

- **Where it asks** (each an Admin setting, Settings, **Phone number box**):
  - **More photos** (on): past the first 6 photos of a car (`phone_gate_free_photos`), by the arrows, the thumbnails,
    the keys or a swipe. Never on a car with 6 photos or fewer. The number given goes on to the photo tapped.
  - **Full availability** (on): the booked days on a car's calendar (a "See full availability" link above it) and the
    cars booked for the chosen dates on the cars page ("Also show cars booked for my dates", "Show them anyway").
    Picking dates and seeing whether that car is free for them, with its price, is never asked.
  - **Booking request** (off): the request form asks for the mobile number itself. On: the box comes before the first
    step's Continue and the form shows the number given (with Change).
  - **Code by text** (off): a valid Canadian or US mobile number is enough. On: a 6-digit code (10 minutes, 5 tries, only
    its hash kept), texted from the CarmaCars number through Quo and logged with the sign-in codes. "Use without
    verifying" (off) can be offered with it. US numbers get no code until US texting is on (Text alerts): the number is
    enough for them.
- **The box:** "Your mobile number", the owner's line ("Put your phone number in to see more photos" or "... to see
  full availability"), the number formatted as typed, an unticked "Also text me deals from CarmaCars. Reply STOP to any
  text to stop them." and **Continue**. A native modal dialog (a sheet on phones): Tab stays inside, Escape and the close
  button close it and the focus goes back to what was tapped.
- **Who never sees it:** a signed-in renter with a verified mobile, and a device that gave a number in the last 90 days
  (the first-party cookie `cc_pg`: the visitor id and an expiry, no number) or typed one into the request form.
- **What is kept** (`phone_gate_contacts`): the number as a transactional contact, consent source "phone gate" (texts
  about availability and the bookings asked about), and marketing consent only when the box was ticked, with the words
  shown and the time (CASL). A later unticked box never withdraws it (STOP or the unsubscribe page do). Never the network
  address. The number is also a contact capture (form `phone_gate`, done at once so no follow-up To do) with its lead
  (source `unfinished_form`): staff see it on Renter leads, Live visitors ("Typed into the phone number box") and
  wherever unfinished-form leads are listed. The request form fills it in.
- **Cost:** codes only with the code setting on, about one cent a text: at most 3 a number, 10 a network address and 200
  for the site a day (each a setting). No new database call for a page view: the settings ride in `site_facts`, already
  read by the cached car and cars pages; the server is asked only after a tap (whether a signed-in renter has a verified
  mobile, then the number), plus one small count when a box opens or closes and one per request sent.
- **Search engines:** the gate is in the browser, on taps only. Every photo stays in the page HTML, the JSON-LD and the
  sitemaps; nothing is hidden or blurred.
- **Measuring it:** Settings, Phone number box shows per day how often a box was shown, a number given, closed without
  one, codes texted, the web booking requests and those from visitors who saw a box, and the web requests a day in the
  28 days before the box was first shown and since (`phone_gate_daily`, no personal data). One press per box turns it
  off or on (`phone_gate_switch`), and the pages are rebuilt at once.
- **Privacy policy:** one paragraph after the phone sign-in line.
- Code: `web/src/features/phone-gate/`, `web/src/server/actions/phone-gate.ts`, `web/src/app/api/phone-gate/route.ts`,
  `web/src/features/car/Gallery.tsx`, `web/src/features/car/CarBooking.tsx`, `web/src/features/fleet/FleetBrowser.tsx`,
  `web/src/features/booking/RequestWizard.tsx`.
- Tests: `supabase/tests/99_phone_gate.sql`, `web/src/features/phone-gate/rules.test.ts`, `web/tests/e2e/phone-gate.spec.ts`.

## Guides

No guide change: the settings page explains each box itself, and no staff steps change (the numbers show where leads
already show).
