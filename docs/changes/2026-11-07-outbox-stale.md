# Stale emails are never sent (release 30 follow-up, migration 0601)

Branch `r30-stale`. SCHEMA_MARKER 0601. The owner, November 7: the email backlog is about a week old.

## What changed

- **The rule** (`app.outbox_stale_reason`, run by `app.outbox_claim` before every send): an email still waiting (queued
  or delayed) is skipped with status_reason `stale: <age>` or what made it stale, never sent late:
  - staff and Admin alerts (audience `staff_%`, the digests): older than 12 hours. Every alert is also an in-app notice
    and a phone alert, so nothing is lost.
  - customer, owner, investor, hiring and partner emails tied to an event, as soon as the event is no longer current: an
    offer email when the booking is no longer offered; a pickup reminder, the licence or coverage request or the driver
    link after the pickup time; a return reminder or late notice a day after the return time or once the rental is over;
    a payment reminder or failure once the booking owes nothing; the interview invitation once its link expired.
    Otherwise older than 72 hours.
  - records always go, whatever their age: receipts, signed agreements and signed copies, statements, invoices, payouts,
    refunds, payments recorded or received, the chat transcript.
  - A claim played at another time (the tests' simulated days) ages nothing: the clock is the earlier of the claim's
    time and now.
- **The backlog**: the migration applies the rule once to every waiting email (a notice with the count).
- **The deploy** prints one annotation (`scripts/deploy/outbox-stale.sh`, `public.server_outbox_stale_report`, service
  key only): the emails skipped as stale in the last day, by audience and by code, and how many still wait. Counts only,
  never an address.
- **The fee check (0584)** now charges the Tracker Fee only from the tracker's installation, as the invoices do (0239).
  The first production check (November 7) flagged 29 November invoices as billed below the terms: none of those cars has
  a tracker installed, so the invoices were right; nothing was changed. `99_owner_debit_amounts` has a car without a
  tracker.
- Tests: `supabase/tests/99_outbox_stale.sql` (a week-old staff alert and an offer email for an offer no longer open are
  skipped, a week-old receipt still goes, a renter email over 72 hours is skipped and one under it goes);
  `web/src/lib/deploy-scripts.test.ts` (the annotation).

## Guides

No guide change: nothing on a screen changes (the Email log shows the reason of each skipped email, as for every skip).
