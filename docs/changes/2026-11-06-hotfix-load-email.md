# Hotfix of November 6: scraper load, the email backlog, error alert spam, wording, self-healing (migration 0432)

The owner reported the site slow or down: website requests had gone from about 630,000 to 1.5 million a day, Worker CPU was
over its limit, the server load was 7.4, hiring emails were not going out and error alerts arrived one email at a time.

## What changed

1. **Load.** Search engines keep full access (owner's decision: no noindex, no sitemap or robots.txt cuts; the search scope
   stays as the owner set it). The load is cut at the edge: the edge copy of the place pages and of the programmatic vehicle
   pages is kept for a day instead of six hours (s-maxage 86400, stale for a week while it is read again), and the non-search
   scrapers are refused 403 at the Worker entry before the app loads and disallowed in robots.txt: the existing list plus
   MauiBot, AspiegelBot, LinkpadBot, Exabot, CCBot and GPTBot.
2. **Email backlog.** `app.outbox_claim` (0432) now moves queued reminders (not hiring ones) to the digest class, skips a
   reminder, digest or marketing email still waiting 48 hours after it was due ("expired"), and paces those low classes:
   at most half of the day's cap, released with the clock, so a midnight backlog cannot spend the quota before customer,
   owner and hiring emails. The Edge Function no longer parks a quota refusal until midnight (all rows came due together):
   the row waits 2 to 2.5 hours with its attempts untouched, and on a Resend rate or quota refusal the email goes through
   the Cloudflare email binding first (already wired, 0222).
3. **Error alerts.** The site check's alert and recovery, a failed job and a usage alert are digest items (morning slot): the
   admins get the in-app notice at once and one line in the morning digest. A digest line with the same text still waiting is
   not added again (`staff_digest_items_fingerprint`).
4. **Wording.** The sign-in emails' sender name is set to CarmaCars (scripts/deploy/auth-templates.mjs; the service's default
   reads "Supabase Auth"), the server alert emails of vps-health say "CarmaCars server", and the Admin texts and a fallback
   error message say "sign-in service".
5. **Self-healing.** `.github/workflows/self-heal.yml` (every 15 minutes) checks the site and the server API, opens or
   updates one `outage` issue, closes it on recovery and, after about 45 minutes of API failure, starts the existing vps-ops
   reboot action (once per 6 hours). It runs no SQL. See docs/runbook-outage.md.
6. **Email budget (migration 0433).** 300 a day: the send-outbox function sends through the Cloudflare email binding first (200 a
   day, `notify_cf_daily_budget`) and through Resend after (100 a day, `notify_resend_daily_budget`); once both are used the
   rest waits for tomorrow, the highest priority and oldest first. The binding is added by the production deploy when the
   repository variable CF_EMAIL_BINDING is on (scripts/deploy/email-binding.sh); the deploy annotation says whether it was.
7. **Test dates.** 99_now_board no longer puts its pickups in the future when the suite runs before 10:00 Toronto time, and
   99_lead_time_partner_pricing is skipped (with a notice) when its 30 to 78 hour window touches a weekend, where the weekend
   rate changes its amounts; both failed on main at those times.

Not in this change: the renter's "I've returned the car" link and form (photos, odometer, fuel, time) with the staff
Confirm or Deny, and a limit on repeated overdue emails. Overdue emails, texts and notices go on as before until it is built.

## Guides

No guide change: no screen's steps changed.
