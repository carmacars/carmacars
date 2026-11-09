# Release 35, part L: the Live map loads again, and payments taken outside the platform are linked (1080, 1081)

Migrations `supabase/migrations/1080_r35l_live_map_speed.sql` and `1081_r35l_stripe_link.sql`. SCHEMA_MARKER 1081.

## 1. Today > Visitors: the map drew with no data (production)

`/api/staff/live-map` took about 25 seconds and answered 503 "The map could not be read"; the page's first read failed the
same way and showed nothing. The read (`admin_read live_map`, and `va_read live_map` for customer service and Sales) ran
past the database's statement timeout. On a test database seeded like a busy site (20,000 visits, 200,000 visit events,
3,000 renters, 3,000 leads, 8,000 games) it took 46.7 seconds:

- 31 s: the roles on each pin (`app.person_tags`, 0470), about 65 ms a pin for up to 500 pins: every renter, owner,
  partner and investor compared by a lowered email and a normalized phone, a sequential scan of each table with a
  function on every row. Now each match is a lookup of an expression index, and the map asks for all its pins in one
  statement (`app.person_tags_many`, the same answers, checked person by person in the tests).
- 13.5 s: PostgreSQL's JIT compiler. The base read is one large statement whose estimated cost (a sequential scan of
  `contact_captures` for each lead) passed the JIT thresholds, so 434 functions were compiled before a 2-second query ran.
  The map's functions (and Live now's and the captured contacts') run with `jit = off`; the lead's capture has an index.
- The rest: the KPI tiles' counts (bookings by `booked_at` and `confirmed_at`, payments by `processed_at`), a renter's
  latest visit, the game prize words for rows that are never shown, and the studio photo of a car with no photo of its own
  (eight made for one used).

Now 0.4 to 0.5 s on the same data (about 0.27 s when the cars have their photos); the KPI tiles 2 ms and the fleet 5 ms.

Each layer stands alone. The website reads the KPI tiles, the pins and the fleet as three calls at once
(`{part: 'kpi' | 'pins' | 'fleet'}`); in the database each layer is its own block, and one that fails is named in
`failed` while the others are drawn (the roles on the pins too, as `roles`). The map then says "Couldn't load the visitors
and leads. Trying again in 30 seconds." instead of showing zeros; a failed read is not kept in the 20-second cache.

React error 418 on the page: the times were written by `toLocaleTimeString('en-CA')`, whose words ("p.m.", the space before
it) differ between the Worker's ICU and the browser's. Times on the Visitors page, the Live map, Live now, History and the
chat are now written by `web/src/lib/clock.ts` from Intl's numbers only, the same on the server and in every browser.

Tests: `supabase/tests/99_r35l_live_map_speed.sql` seeds the busy site and checks the budget (2 s, for slow CI runners),
that the lookups use their indexes, `jit = off`, one layer at a time, a failed layer named with the others drawn, and the
same roles and photos as before; `web/src/lib/clock.test.ts`, `model.test.ts` (merging the layers).

## 2. Link a payment taken outside the platform

On a booking's Money tab, the Admin has **Link a payment taken outside the platform** in the rental panel and in the
deposit panel: a charge taken in the Stripe Dashboard or through a Stripe payment link, or a card deposit taken that way.
The Admin pastes the Stripe payment id (pi_... or ch_...); the server reads it at Stripe (the lookup of 0201) and the
database checks it (`admin_do link_stripe_payment`):

- Canadian dollars only; not already a payment, a payment link or an owner debit of ours (by its PaymentIntent or charge);
  a card Stripe can name.
- As the rental: paid at Stripe, no more than is open for the rental and fees; recorded as "Rental and fees" by 0201's
  record_card_payment (same-card rule of a card-coverage rental included), so a booking waiting for payment is confirmed.
- As the deposit: the whole deposit. A hold waiting to be captured is kept as held (settled, captured or released like any
  hold); a deposit charged is kept as captured.
- Audited (`link_stripe_payment`) and on the booking's history.

The nightly "unlinked Stripe payments" check (from 3 a.m. Toronto; the deposit guard's job, started by the cron gate when it
is due; a failed run is tried again an hour later) lists the succeeded Stripe charges of the last 60 days that nothing on
the platform knows, with a best guess of the booking: the booking number a payment link kept, the renter's email, or a
booking with that amount open or that deposit not taken (pickup within 30 days). **Money > Unlinked Stripe** shows them to
the Admin and Finance (`ops_read stripe_unlinked`); one that is not a booking's payment is put aside with the reason
(`ops_do stripe_unlinked_dismiss`). Linking one takes it off the list. Tables `stripe_unlinked`, `stripe_unlinked_checks`
(audited, service role only).

Tests: `supabase/tests/99_r35l_stripe_link.sql` (the checks, a rental payment, a deposit held and captured, the list,
the guesses, put aside, the nightly timing); `web/src/integrations/payments/terminal.test.ts` (listing charges at Stripe,
mocked fetch) and `web/src/features/money/stripe-unlinked.test.ts`.

## Guides

- `admin/requests-offers-and-bookings`: Link a payment taken outside the platform.
- `admin/live-visitors-and-live-chat`: a layer of the map that could not be read says so.
- `va/finance`: Money > Unlinked Stripe.
