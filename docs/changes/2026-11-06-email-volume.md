# Email volume: one daily cap, no bursts, staff alerts in one digest (release 29, C3, migration 0583)

Branch `r29`. SCHEMA_MARKER 0583. At 18:00 on November 6 the owner's inbox was flooded: 0535 released the whole held
backlog at once ("go out at once"), and the staff copies landed in his inbox.

## What changed

- **One daily cap, one place** (`app.email_day_cap`, used by `app.outbox_claim`): Program settings, Emails a day
  (`notify_daily_cap`, now 300), never more than the Cloudflare and Resend budgets together (200 + 100), and Resend's 100
  alone while Cloudflare email has never sent one. Every provider counts. What does not fit waits for the next day,
  paced, never failed. The class limits follow the cap (300, 300, 285, 285, 180).
- **No bursts** (the same claim): at most the day's even pace plus 30 an hour (`ceil(cap / 24) + 30`: 43 at 300),
  whatever a backlog release, a reset or a migration makes due at once; in priority order (customers, owners, hiring,
  staff, digests and reminders, marketing; hiring emails are put after customers and owners). No migration or function
  sets held emails to "now" any more (the 0535 pattern is not repeated).
- **The Admin usage card** (Settings > Usage, Emails) and Admin > Overview show today's emails against the cap and this
  hour's against the pace (ops_read `email_pace`).
- **Staff inboxes** (audience `staff_%`): an alert that is not urgent is kept for one digest email per person
  (`staff_digest_hourly`, `staff_email_digest_items`, `app.staff_email_digests` every 5 minutes with the scheduled
  notices): at most one an hour (default), one a day at 07:00, or none, as each person chooses (`users.staff_email_digest`,
  Profile > Notifications: alerts by email, for Admins Settings > My profile). Urgent alerts go on their own, at most 3
  an hour per person: a payment declined (`staff_payment_failed`), documents to review for a pickup within 2 hours
  (`staff_identity_review`), the site down (`staff_site_alert`). The scheduled lists and digests and a person's own pay
  and commission emails are unchanged. Every alert is still an in-app notice and a phone alert at once.
- Tests: `supabase/tests/99_email_volume.sql` (the cap with and without Cloudflare, 300 held emails released at once and
  spread at most 43 an hour, customers first, the staff digest, urgent alerts and their limit, Off, the setting);
  `07_notifications` counts the new email and builds the digest.

## Guides

- `admin/usage-and-paid-usage`
- `admin/alerts-the-bell-and-your-phone`
- `va/shared-tools`

Published by migration 0580 (`supabase/seed/0580_gen_guides.mjs`), the guide block of release 29.
