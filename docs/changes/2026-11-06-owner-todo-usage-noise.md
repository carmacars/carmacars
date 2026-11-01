# To do that fits a day, usage in money, and the causes of the CPU, storage and email overruns (0320, 0322, 0323)

What the owner saw on November 1, 2026 on Admin > To do, on his phone: a red banner "Over the included allowance"
(website CPU time 123%, about US$0.14 over; photo and document storage 103%, about US$0.005 over), a black banner
"Close to the included allowance" (emails today 98 of 100) and "To do: 380 things need you". His words: "I thought we
resolved the email issues. And why do I have 380 items outstanding." And: "we shouldn't be going over on stuff anyways,
we're literally brand new. If we're going over this early there's probably an issue."

We cannot read production from here, so each cause below is from the code, with how sure we are.

## 1. "380 things need you"

- **Cause (sure, from the code):** the headline added `prompts.length` to the raw count of every count line. Three things
  multiplied it:
  - **Unfinished forms.** Each visitor who typed a name, email or phone into a form and left gets an Admin task
    "Unfinished request from <name>: follow up" (0090), open until the person sends the form, kept up to 24 months. Each
    counted twice: once as its own prompt (an Admin queue task) and once in the line "Unfinished requests to follow up".
    A site that crawlers and casual visitors reach every day piles these up: 150 of them alone make 300.
  - **Every staff queue's tasks.** While no real assistant held customer service, sales, finance or fleet (0078), each of
    their tasks came to the Admin as a prompt of its own.
  - **Per-record count lines.** "Cars with no service record yet" added one per car, "Tolls and tickets to review" one
    per notice, and so on.
- **Now (app.admin_todo, 0320; web/src/features/admin/todo/need.ts):**
  - The follow-ups of unfinished forms are Sales' work: new ones go to Sales' queue, the open ones moved there, and each
    closes by itself after **7 days** (Program settings, `capture_followup_days`). The person and what they typed stay on
    Admin > Leads; nothing is deleted.
  - Every count line belongs to the Admin or to a team (sales: unfinished forms, chauffeur quotes; fleet: maintenance due
    and unknown, listings to review, calendar links, Turo emails, insurance; finance: services to bill, tolls, commissions
    to pay, deposits due back, failed payments). **Your teams**, under the list: one quiet line per team ("Customer
    service has 42 open, 3 overdue") with its count lines underneath, linked to its queue. Never in "need you".
  - A staff queue's tasks no longer come to the Admin as prompts, staffed or not; they are in the team's line.
  - "Need you" counts lines, not records: work of one kind that repeats is one line (the page's grouping, group.ts), a
    count line is one line whatever its count. The database computes it (`app.todo_need`) and the page and the assistant
    read it. The page shows the first 8 lines; the rest are under "N more, less urgent".
  - The staff assistant's "things need you" says the same number and lists the same lines (src/server/assistant.ts).
- Every queue stays reachable: Staff tasks (per queue), Leads, Maintenance, Tolls, each linked from its line.

## 2. Usage banners in money

- A service that is never paused and is billed by use (Worker CPU time, requests, R2 storage, Quo texts) is **red only
  when this month's projected cost above the allowance reaches US$5** (Program settings, `usage_banner_red_usd`). The
  projection: a month figure by the share of the month gone (at least three days), a size as it stands, a day figure as
  if every day were like today (`app.usage_money`). Under the line: one quiet grey line with the cost and no card, email
  or text (`app.usage_quiet`; the alert row is kept on Settings > Usage with "not emailed: projected about US$0.88 ...").
  Nothing at all before the allowance is used up.
- Unchanged: Workers AI, images and Claude (hard stops and pauses) and the email holds (Resend's 100 a day), which stay
  visible red and amber, because hitting 100 holds emails.
- **No usage alert is emailed any more (0323).** Settings > Usage showed "Emails today at 80%" and "at 100%" emailed
  almost every day, with the CPU and storage alerts, each one counting against the same 100 emails a day. Every usage
  alert is now kept with "not emailed: usage alerts are in the app only" and shown on To do and Settings > Usage; the
  texts to the Admins (once per figure and level a month, outside the quiet hours, none under the red line) stay.
- **The CPU figure is real, not a period error.** Settings > Usage showed 40.37 million CPU ms on November 1 (135%) for
  the month that resets December 1. The usage workflow adds up Cloudflare's per-invocation CPU time per Toronto day
  (src/features/usage/cloudflare.ts, workersInvocationsAdaptive `cpuTimeUs`), and only November 1 counts in November:
  about 366,000 requests by 13:10 at about 110 ms each. Cloudflare bills Workers Paid by its own billing period, so the
  dashboard's figure can differ by a few days; the projection (`app.usage_money`) uses the calendar month.

## 3. Worker CPU over its allowance: the cause and the fix

- **Likely cause (fairly sure; Cloudflare's per-path figures are not readable from here):** crawlers rendering the deep
  programmatic pages. Each of those millions of addresses is a fresh render of about 100 ms that no cache can absorb (no
  two requests share an address), and the training crawlers were invited to read every one of them at one page every
  10 seconds (robots.txt Crawl-delay): one crawler honouring it is about 260,000 renders a month, about 26 million CPU ms,
  most of the 30 million included. GPTBot does not honour Crawl-delay at all. Second, smaller: the staff screens that ask
  the server every few seconds all day (live chat inbox every 5 s, a chat every 2 s, the phone inbox every 6 s, a thread
  every 4 s, Live visitors every 15 s, the live map wall screen every 30 s): one VA with live chat open for a shift is over
  14,000 Worker invocations a day.
- **Cloudflare's own figures (November 1 to 2):** 633,000 requests and 584,000 Worker invocations in 24 hours (1.6
  million the day before), 7.4% answered from a cache, CPU P90 177 ms: crawler volume with almost no caching. The edge
  copy belonged to one deployment, and several deploys a day emptied it.
- **Now:**
  - A crawler (never a person, never a session) gets the page's last good copy, which outlives a deploy, instead of a
    render while it is under 3 days old and no page was rebuilt on demand since, with Last-Modified; a crawler asking
    "changed since?" (If-Modified-Since) gets 304 with no body (`crawlerCopy`, src/lib/edge/page-cache.ts). Every second
    visit of a page by any crawler, Google's mobile and desktop crawlers included, is then answered without a render.
  - The search and answer crawlers that bring visitors (Google, Bing, DuckDuckGo, Apple, ChatGPT search and its user
    fetches, Claude search and user, Perplexity, Amazon and Meta user fetches, Mistral, DuckAssist, Google's Vertex and
    Deep Research) keep every public page, as the owner chose; their scope still follows Settings > Vehicle pages. Every
    other crawler (training crawlers, the foreign search engines, open crawls, any crawler not named) reads the crawl
    scope only (src/lib/edge/crawl-scope.ts: the fleet, landing pages, guides, the vehicle tree to the trim): robots.txt
    says so in their groups, and the Worker answers a deep page 403 before the app loads, with no tag store read
    (`keptToScope`, src/lib/edge/bot-shield.ts). Nothing leaves search.
  - Staff screens ask at their pace while someone uses them and at most once a minute after two minutes untouched (a
    wall screen, a tab left open); any touch brings the pace back; hidden tabs never ask (src/lib/poll/poll.ts). The chat
    thread asks every 3 s (was 2), the phone inbox every 10 s (was 6), a phone thread every 5 s (was 4).
  - Already in place and kept: the edge copy of public pages (6 hours for the programmatic ones, `s-maxage` 21,600 to
    browsers and the CDN), the crawler guard at 70% of the month, the idle cron gate.
  - Not changed: the site check's page probes (4 pages every 5 minutes, about 1,150 Worker requests a day, a few percent of
    the CPU): slowing them would delay outage alerts.

- **Guide upkeep spent the AI background share (663 neurons and 9 calls on November 1, 2,913 in a week).** It ran after
  every deploy that touched anything under web/src, and every run tried again each section the last one could not
  rewrite. Now it starts only when a page, a component, a style or the guide content changed (`*.tsx`, `*.css`,
  docs/guides; .github/workflows/guides.yml), and a section whose only reason is an earlier failure is tried at most once
  a run, after the sections that changed (`rewriteTargets`, src/features/guides/upkeep.ts; web/scripts/guide-upkeep.mjs).

## 4. R2 storage over 10 GB: the cause and the fix

- **Likely cause (sure about the retention, fairly sure about the volume):** the storage figure is every R2 bucket of the
  account together, and the backup bucket held, by its own settings: wal-g's base backups and **7 to 13 days of WAL** (a
  weekly full backup with six nightly deltas, `retain FIND_FULL 7` keeps the previous full and the WAL from it), **30
  nightly logical backups**, the Storage files' copy and **30 days** of their trash. The retention plan that keeps it
  under the 10 GB existed (vps-ops apply-retention) but ran only by hand. Write churn adds WAL: every deploy rewrote all
  200 email templates (a few MB each time, several deploys a day), and every ten minutes the search snapshots locked and
  stamped every landing page and rental term even when nothing changed (a row lock is a write), the place roots and the
  sitemap shape were rewritten whole.
- **Now:**
  - The vps-backup workflow applies the retention plan **every night** after the logical backup (infra/vps/scripts/
    backup-retention.sh apply): wal-g's kept backups and the logical days set on the server, and what is beyond them
    deleted; the run's annotation says the bucket's size and what was kept and deleted. Its ladder starts at 7 wal-g
    backups and 7 logical days.
  - Logical backups: the last **7 nights and each Sunday of the last 4 weeks** (scripts/backup/keep.sh; was 30 days).
  - The Storage copy's trash: **14 days** (was 30).
  - Nothing written when nothing changed: email templates at deploy (scripts/deploy/email-templates-sql.mjs), the search
    snapshots (`app.seo_snapshot_refresh`, no row lock, no stamp-only update), the place roots and the sitemap shape.
  - Photos are already shrunk in the browser before upload (2026-10-30-photo-shrinking.md: 2,048 px, 80%).
  - Never live data: only retention, the backups' own folders and what wal-g's retention removes.

## 5. Emails: the cause and the fix

- **Cause (sure):** Cloudflare Email Service never sent. Cloudflare's side is set up (carmacars.ca enabled, DNS
  configured), and the repository variable exists, but its value is `EMAIL`; the deploy added the Worker's `EMAIL`
  binding only for `1`, and said nothing either way, so every email went through Resend's 100 a day. The volume: while no real assistant holds a
  function, 0078 sends each customer service, sales, finance and fleet email to the Admins too, **immediately** when the
  assistant would have had it immediately, so on a new business every staff email was one more email to each Admin; and
  the outbox tried Cloudflare first for every email and failed. The live verification's sign-ups (verify workflow, full)
  send real emails to resend.dev test addresses that count against the same 100 when it is run.
- **Now:**
  - While nobody holds a function, its emails still reach the Admins, **in their digest**, not one by one. Immediate
    stays only for what cannot wait: a visitor waiting in live chat, a late return, a breakdown, an incident, a dispute and
    an approval due (`app.staff_fallback_urgent`). An email the Admins get in their own right (a refund that needs
    approval, an exit below the fleet minimum) is unchanged. Renter, owner, applicant, investor and legal emails are
    untouched.
  - Settings > Usage opens with an **Emails** card: whether Cloudflare Email Service sends (`app.cf_email_setup`: set up
    and sending, refused with its reason, or not set up) and, when it does not, the four exact steps. The emails banner
    says the same with a link to them.
  - The deploy takes `1`, `true`, `yes`, `on` or `EMAIL` (any case) as on (scripts/deploy/email-binding.sh), so the
    next production deploy adds the binding with the variable as it is, and says whether it was added and, when not, why.

## Owner steps (Cloudflare email)

Nothing more: Email Sending is enabled for carmacars.ca with its DNS, and `CF_EMAIL_BINDING` is `EMAIL`, which the deploy
now takes as on. The next production deploy says "EMAIL binding added"; Settings > Usage then shows Cloudflare sending.
On a new account the steps are the four on Settings > Usage (enable Email Service, add carmacars.ca and its DNS records,
set `CF_EMAIL_BINDING`, deploy).

## Tests

- DB: `supabase/tests/99_owner_todo_usage_noise.sql` (200 unfinished forms add nothing to "need you" and go to Sales; 30
  Admin tasks of one kind are one line; 40 customer service tasks count on the team line only; follow-ups close after 7
  days and the people stay; the CPU banner is a note at a few cents and red past the line; the email banner stays with
  the Cloudflare state; the email setup states; a customer service email's Admin copy goes to the digest; a second
  snapshot run rewrites no rental term). `62_contact_capture.sql`: the follow-up is in Sales' queue.
- DB: `60_usage_guard_assistant.sql` (0323: no usage alert is emailed, each says why; the email still builds).
- Unit: `web/src/features/guides/upkeep.test.ts` (the sections rewritten), `web/src/lib/edge/page-cache-stale.test.ts`
  (crawlers get the last good copy or a 304), `web/src/features/admin/todo/need.test.ts`, `web/src/lib/poll/poll.test.ts`, `web/src/lib/edge/bot-shield.test.ts`
  (crawl scope), `web/src/features/usage/usage.test.ts` (the banner's words, the email steps),
  `web/src/lib/deploy-scripts.test.ts` (the backups kept).
- E2E: `guided-actions.spec.ts` (a customer service task stays on its team's line), `release-23.spec.ts` (robots.txt: the
  search crawlers' group keeps every page, GPTBot's the crawl scope), `legal-admin-redesign.spec.ts`.

## Guides

- `admin/getting-around-admin`: To do counts lines; Your teams; unstaffed teams' emails in the digest.
- `admin/discount-games-and-leads`: unfinished forms are Sales' follow-up and close after 7 days.
- `admin/usage-and-paid-usage`: the banner in money; usage alerts in the app only; the Emails card and its steps.
- `admin/email-backups-and-site-health`: the backups kept and the nightly retention.
