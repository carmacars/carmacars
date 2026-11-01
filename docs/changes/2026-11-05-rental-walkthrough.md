# The rental walkthrough (0291)

Release 24b's list kept "rental walkthrough" for later; the owner's own words for it were not in the saved record (only
that line of the release list), so it is built on what 0263 made a hard priority (the licence, the signed agreement and
the check-out photos) and on the handover screens: the renter is guided through the whole rental, one step at a time,
and field staff see how far they got. On by default.

- **Where:** the renter's booking has a card **Your rental, step by step** (a ring with the steps done and the stage),
  with **Start the walkthrough** (then **Continue**). It opens `/account/bookings/<number>/walkthrough`.
- **The four stages and their steps:**
  - Before pickup: upload your licence, sign the rental agreement, pay (after we confirm), the deposit hold on the morning
    of pickup (its amount and the card; left out when the rental has no deposit), what to bring.
  - At pickup: where and when we meet (with the map), the walk-around of the car with our staff (every side photographed,
    km and fuel, marks on the diagram, the condition report signed on the phone; then **See the photo report**), and
    taking your own photos too.
  - On the road: the kilometres included and the price of each one over, the fuel rule (prepaid fuel says so), no
    smoking, tolls and tickets as the agreement says, only the drivers on it; what to do if something goes wrong (roadside
    help, an accident, our number; **Report a problem** while on rent).
  - The return: the return time and place, the fuel, belongings and garbage (**Ask for more time** while on rent), the
    check-in, and the deposit released.
- **Done or not:** tasks are done when the database says so (`app.handover_essentials`: the licence approved, the
  agreement signed, the deposit held; paid; the check-out and check-in reports complete; the deposit released). Steps to
  read are done when the renter presses **Got it**. The step to do now is shown first, in black, with its button; every
  stage follows with its steps.
- **Field staff:** the job's header reads "Renter's walkthrough: read 2 of 6 steps", with a line to walk them through
  the rest at the car when it is short.
- **Kept:** `booking_walkthrough_steps` (booking, step, when, who). Off: `field_renter_walkthrough` (Settings > Field jobs
  and handovers). Not shown for cancelled, expired or declined bookings, nor an owner's own use of their car.

Files: `supabase/migrations/0291_rental_walkthrough.sql`, `web/src/features/walkthrough/` (model, page component),
`web/src/app/account/bookings/[number]/walkthrough/page.tsx`. Tests: `supabase/tests/99_permit_read_walkthrough.sql`,
`web/src/features/walkthrough/model.test.ts`, `web/tests/e2e/r25b-permit-walkthrough.spec.ts`. The guide chapters: `0292_r25b_guides.sql`.

## Guides

- `renter/before-pickup`: Your rental, step by step.
- `field/a-handover`: the renter's walkthrough on the job.
