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

## Guides

No guide change: no screen's steps changed.
