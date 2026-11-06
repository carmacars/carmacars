# Runbook: the site or the server is not answering

## What heals by itself

- **Edge copies.** The Worker serves the last good copy of a public page when the app or the database is slow or fails
  (x-edge-stale, 7 days), so a short database outage does not blank the public pages.
- **Crawlers.** The bot shield (403 for scrapers) and day-long edge copies keep crawler load off the Worker
  (docs/changes/2026-11-03-crawl-scope.md, docs/changes/2026-11-06-hotfix-load-email.md).
- **Email.** The outbox sends transactional email first, expires old reminders and marketing, and paces the rest across
  the day. A provider limit holds the email without spending its tries; when the provider refuses, the Cloudflare email
  binding sends instead.
- **self-heal (GitHub Actions, every 15 minutes; learns since release 28).** Probes from outside: the site's health
  (down, its database down, slow), the server API, email at its limit, both certificates, the server's own checks
  (vps-health), the backup and the scheduled workflows. Each failure has a signature with a known safe action in
  `.github/self-heal/runbook.json`: wait (crawler load, email limit, a deploy on its way: an issue only if it lasts),
  vps-ops `reboot` (API down for about 45 minutes) or `apply-retention` (server disk, WAL or backup space), re-run a
  failed scheduled workflow, start a backup. vps-ops actions only when the server is the live backend and never more than
  one in 6 hours. A signature it does not know opens one issue (label `self-heal`; `outage` for the site and the API);
  close it with a line `self-heal: <signature> => <action>` and that action is used the next time. An action that did not
  help twice opens an issue instead of a third try. Every incident (signature, action, outcome) is in the open issue
  labelled `self-heal-ledger`. It never runs SQL.
- **vps-health (every 5 minutes)** emails the site-check address about the server and its API.

## What the owner does

1. Open the open `outage` issue (GitHub notifies you) and the run it links. Site down and API fine: the Worker or
   Cloudflare. Check the Cloudflare dashboard status, then Actions > ci > Run workflow with the last good commit.
2. API down for over an hour after the automatic reboot: Actions > vps-ops > backup-report to see the server answers over SSH,
   then infra/vps/CUTOVER.md, section Upkeep.
3. Traffic spike (Worker requests or CPU): Actions > cf-logs (hours: 1); add the offending bot to BLOCKED_BOT in web/src/lib/edge/bot-shield.ts.
4. Email not going out: Admin > Messages. Held for the limit is normal late in the day; transactional email keeps priority.
5. Never run SQL by hand to fix an outage without a backup (Actions > backup).
