# Two links that answered 404 (0310)

Found by the role crawls of the combined Release 25 run (41309625403): its new tests moved other specs between the
parallel parts of the end to end run, so two older tests now ran before the anonymous and the customer service crawls.
Both were product gaps, not test faults.

## 1. A published car at /cars/null

- **Cause:** a listing could be set to published without a slug. The publish screens always give one
  (`app.publish_listing`, `app.listing_slug`), but nothing in the database made sure of it. The owner portal tests'
  fixture (`web/tests/e2e/portal-design-seed.ts`) publishes its cars with a plain update, the way an import or a
  script would; the fleet then listed them with no slug and the home page, Cars, Cars by delivery, Delivery,
  Requirements and the luxury class page linked `/cars/null`.
- **Now:** a listing that becomes published without a slug gets one at once, by the publish screens' own rule
  (trigger `a0_listing_slug_on_publish`). The published listings without one got theirs in the migration. The site also
  leaves out any fleet row without a valid slug (`getFleet`, `web/src/lib/car-address.ts`), so no page links
  `/cars/null` even if one slips through.

## 2. "Review the licence" in customer service's queue answered 404

- **Cause:** a renter's licence task (`verify_renter` and the other review tasks) stays in customer service's queue
  while the request is still with Sales, and Sales may review the photos themselves (0169). Once Sales had reviewed
  them, nothing was waiting, and the review page opened for customer service only on a booking awaiting payment,
  confirmed or on rent, or with photos waiting. The queue still linked the page, and it answered 404.
- **Now:** customer service may open the review of a booking whose review task is open in their queue
  (`app.doc_review_can`). Once the task is done the usual rule applies again.

## Tests

- DB: `supabase/tests/99_listing_slug_verify_link.sql` (published without a slug gets one, the fleet has no car without
  an address, a draft keeps none; the review opens for the task in the queue and closes again when it is done).
- Unit: `web/src/lib/car-address.test.ts`.
- The role crawls (anonymous and customer service) of the full run.

## Guides

No guide change: no step changes; the links now open what they always named.
