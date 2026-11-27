# Hotfix 2 R50: the causes behind the errors, Data health, To do's and alerts (5100 to 5103)

Migrations `5100_r50h2_connector_listing_files.sql`, `5101_r50h2_data_health_causes.sql`, `5102_r50h2_todo_noise.sql`,
`5103_r50h2_push_checkin_copy.sql`. From the owner's "problems found" emails and the live lists of Nov 25 to 27
(connector: site_errors 48 h, site_health, heal_status, list_todos, bug_reports_list).

## What was wrong, and the change

- **"The database is busy" on public pages (373 server errors in 48 h, all from 16:20 UTC on Nov 25).** The website's
  health check (`/healthz`) waited for `/robots.txt`, which reads the whole sitemap (4 to 8 s) within 5 s, and gave up
  after 240 tries: the container stayed "unhealthy" while it served pages (the home check answered 200), and the heal
  agent restarted it 5 times. Each restart emptied the shared reads (`site_settings_public`, `vehicle_tiers`), so every
  page then waited on the same cold reads while crawlers (US and Mexican places on `/t/...` and `/buy/...`) kept the
  20 database API connections busy. Now: ready means the app answers a static file (`web/scripts/vps-server.mjs`); at most
  6 long-tail renders at once for visitors without a session (`RenderGate`, `LONGTAIL_RENDERS`), the rest get the kept copy
  or 503 with Retry-After; a vehicle-tree page of a place outside the market answers 404 before the app
  (`web/src/lib/edge/scraper-guard.ts`); a shared read gets 20 s (one call answers everyone), and `seo_page` is shared.
  No page that earns clicks is deindexed. No missing index was found for these reads.
- **Connector `photo_standard`: "syntax error at or near )" (5100).** One parenthesis too many in
  `app.comms_listing_files` (3870, written with function bodies unchecked). The DB suite now parses every function body.
- **React #441 and #418.** #441 is a server render that failed: on the public pages, the busy database above. The quiz
  countdown (`Study.tsx`) and focus mode (`AlertSettings.tsx`) used the clock before hydration (#418); the social queue's
  load had no error handler.
- **Pickups and returns staff could not record (5101).** Data health "Mark picked up" and "Close", and Bookings > Now
  "Close", recorded the pickup through the gated handover: no deposit held, no signed report or no tracker reading refused
  it, for exactly the cars already out. They now record it at the booked time as 4730 does (audited, To do's for what is
  owed, no money written).
- **Assigned to someone gone (5101).** Ending access left open work on the person. A trigger hands it back to its queue;
  the Data health fixes and the self-healing playbook clear what is left.
- **Leads not followed up (5101).** The count included follow-ups that ended as designed (all sent, replied, a referral's
  one message, no consent, a later stage). It no longer does; a follow-up that never started now starts.
- **Data health notice (5101).** Only when the problems changed since the run before, one line and one link each.
- **To do's and alerts piling up (5102).** To do's close when their subject is settled, one booking's one problem keeps
  one To do, week-old follow-ups expire, every hour (`app.job_todo_sweep_all`, pg_cron `carmacars-todo-sweep`), each with
  its reason. Self-healing's "Jobs locked and left behind" took a retried photo for a stuck one (the claim keeps the first
  start time) and escalated it 130 times: it now looks at the worker's lock, and a problem escalated in the last day is not
  escalated again. Verify and test accounts are never suspended for inactivity. A card hold past its expiry is recorded
  as lapsed; a toll statement read that passed every check is confirmed. Admin and Fleet hear 30 minutes before a car is
  due back and at the return time; a new request tells Admin, Sales and customer service at once.
- **Phone alerts turning off (5103).** Signing out of the app recorded "turned off", which the site never undoes by itself;
  and the 10-device limit removed the oldest device first, the owner's phone. A sign-out is now a sign-out (the app turns
  alerts back on after the next sign-in, `apps/carmacars-native/src/push/index.ts`), and phones stay first.
- **Visitor counts.** A browser driven by a script (`navigator.webdriver`) and more named crawlers are not counted.
- **Check-in visit emails (5103).** They now say it is a free mid-rental car check and the renter keeps the car.
- **Server alert email (`.github/workflows/vps-health.yml`).** Sent when problems start, change and end, never the same
  list again; a link on each problem line.

## Guides

No guide change: the screens and their steps are the same; the changes are in what the site does by itself.

## Tests

- DB: `supabase/tests/99_r50h2_errors.sql` (new, fixtures `rq50e_`).
- Unit: `scraper-guard.test.ts` (vehicle-tree places off the market), `node-edge.test.ts` (the render gate).
