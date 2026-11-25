# The Admin's inbox goes quiet, and one crash To do per error (Release 50: 5051, 5052)

The owner (Nov 25): "admin is getting absolutely spammed with emails which isnt really necessary", and the Admin's To do's
and alerts are cluttered (about 151 open "Website crash" To do's, one per page, almost all React error #441 or #418).

Migrations `5051_r50_admin_email_quiet.sql` and `5052_r50_crash_todo_groups.sql`, the Notifications page
(`web/src/features/notifications/NotificationPrefs.tsx`, `prefs.ts`), test `supabase/tests/99_r50_admin_email_quiet.sql`
(and `99_email_volume.sql`, whose staff-inbox assertions now use a staff member: an Admin follows the new rules).

## What emailed an Admin before

Every email reaches an Admin through `notification_outbox` (audience `staff_%`, the Admin as recipient). Staff alert rules
(`staff_alert_*`) have no email (`has_email = false`): in-app and phone only. About 60 catalogue types with an email
reach Admins (audience `staff_admin`, or `also_sent_to` it), among them: new reviews, refunds issued, owner debits,
statements, payouts due, listings to review, exit notices, calendar conflicts, late returns, tracker and border alerts,
resignations, email limits, data health, approvals, disputes, failed payments. Non-urgent ones went into the person's
digest (0583) **every hour** by default; on top came the Admin morning (07:30) and end of day (18:15) digests, the weekly
summary, the weekly search digest and the urgent ones. How many each sent in production is not known here: the local
database has no send history, and `notification_outbox` in production is the place to count (code, recipient, `sent`).

## What it does

- **Now** (`app.admin_email_now`): a card dispute, a failed payment on a confirmed booking (`confirmed`, `on_rent`), card
  payments paused, the site down, a car at a pound or leaving Canada, documents to review for a pickup within 2 hours,
  an approval or a car disable that waits for an Admin, a request waiting 2 hours that no salesperson holds
  (`sales_staff_id` and `sales_claim_by` empty). These go at once (`status_reason` urgent), at most 3 an hour per
  Admin; more go into the digest.
- **Needs you now with no email of its own**: a booked live interview (`live_call_booked`), a dispute's evidence due soon
  (`dispute_deadline`) and a To do created or raised to `urgent` email every active Admin once
  (`app.admin_now_email`, the staff digest's template with the one line), except an Admin whose alert emails are Off,
  who turned every optional notification off, or who switched that kind's email off.
- **Everything else**: the gate (`app.admin_email_gate`, a trigger that runs before the preferences and the staff
  digest) keeps it in the bell and puts a line in the person's digest. The Admins' digest moves from hourly to **daily at
  7:00 Toronto** (only Admins still on the old default; one the audit log shows choosing hourly keeps it; a new Admin
  starts on daily). The Admin digest (`app.admin_email_digests`, run first by the 0583 job) is a count by type and one
  line per kind with its link ("and 3 more like it"), skipped when empty. The Admin morning, end of day, weekly and
  search digests become lines in it.
- **Each person's settings**: a kind an Admin switched off stays off (no email, no line). Switching **Email** on for a
  kind (`notify_prefs.email_set_at`, stamped by the Notifications page) sends each one on its own; switching it off puts
  it back in the 7:00 email. Rows that exist only because of an email switch were stamped once. The Admin's
  Notifications page shows Email on only where chosen, with one line that explains the rules. Locked kinds (security,
  legal, receipts, assigned jobs, onboarding), calendar invites and a person's own pay emails are unchanged.
- **Unchanged**: every email to renters, owners, investors and staff.
- **Crash To do's (5052)**: `app.client_error_signature` takes addresses, page paths and numbers out of the message and
  keeps an error code (`#441` and `#418` stay two errors: they are different React errors). A crash adds to the open To do
  of its signature (`crash_groups`: reports, the first 10 pages, first and last seen; title "Website crash (N times on P
  pages): ...") instead of one To do per page and day. A crash To do stays at priority high, so it never
  emails the Admins. `app.crash_todos_sweep` (pg_cron, hourly) closes an open one (not one in progress) with no
  report for 24 hours: "No new reports for 24 hours". Once, `app.crash_todos_fold` merged the open per-page To do's into
  one per signature: the newest kept with the others' counts and pages, the rest closed "Merged into <title>". The fold changes no priority and sends no email.
- **Security**: every new function `security definer`, `search_path = public, app, pg_temp`, the server role only;
  `crash_groups` has RLS with `admin_all` and nothing for browser roles; every UPDATE has a WHERE.

## Guides

- `admin/alerts-the-bell-and-your-phone`: Alerts by email, the Admin rules.
- `admin/email-backups-and-site-health`: Website crash To do's.
