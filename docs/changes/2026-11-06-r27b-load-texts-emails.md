# Hotfix r27b: the scrapers, the Text button, the error page, AI crawlers, Cloudflare email (migration 0534)

Branch `hotfix-r27b` from `main` (4ee0585b). SCHEMA_MARKER 0534.

## What happened (November 6, 2026, around 16:00 UTC)

- Workers Observability, two hours: 165,000 invocations, 138,000 with no verified bot category. The largest group were
  "browsers" (Windows Chrome 150 to 154) from RapidSeedbox Ltd (21,000 invocations, 6,300 s of CPU, about a third of the
  Worker's time) and from a residential proxy pool in about 40 countries. They asked for the long-tail place pages
  (`/car-rental/<term>/<place>`, `/detailing/...`, `/body-shop/...`, `/buy/...`), each page about 12 times an hour, over
  `http://` and `https://` alike, from many data centres, so the per-data-centre edge copy almost never answered.
  Search and AI crawlers were small next to them (AI Search 16,900, search engines 7,800, AI crawlers 860).
- Their renders kept the database's 20 PostgREST connections busy (`pg_stat_activity`: 20 of 21 `authenticator`
  connections active). The staff's calls then waited behind them: the Text dialog's database call came back as
  Cloudflare's own `error code: 504`, shown as it was; the Admin pages failed in the server render (client crash reports
  `React error #441`, 16:01 to 16:04 UTC, `/admin`, `/admin/requests`, `/sign-in`), shown as "Something went wrong".
  No crash of an older deploy (server action or script) was reported.
- Texts: two automatic texts in the same hours were refused by Quo with `402: not enough prepaid credits`.
- Email: Cloudflare email was refused once at 14:11 UTC. Resend's daily limits (0018) held every email until Cloudflare
  had sent once in the last day, and Cloudflare was only tried for emails that the claim released, so nothing reached it
  again: 213 emails waited for midnight. A Cloudflare send in send-outbox's Resend-refused path was also never recorded
  as a success.

## What changed

1. The edge (`web/custom-worker.ts`, `web/src/lib/edge/scraper-guard.ts`): `http://` on the site's hosts is a 301 to
   `https://` before anything renders. A long-tail page asked for from a hosting or proxy network (RapidSeedbox, M247,
   Hetzner, Contabo, DigitalOcean and the like; not Google, Microsoft, Amazon, Apple or OVH) by anything that is not a
   Cloudflare-verified bot gets the page's kept copy (up to a week old) or 429 with Retry-After, never a render. People
   and verified search and AI crawlers are never limited. Part 1, deployed first on its own
   (`2026-11-06-r27b-load-guard.md`), also gives an agent posing as a browser that keeps none of the site's cookies the
   kept copy or a tiny page that sets a cookie and reloads, never a render.
2. AI engines (the owner: all AI search engines should recommend CarmaCars): GPTBot, CCBot, Bytespider, PetalBot,
   Sogou, Exabot, Timpibot and AspiegelBot are no longer refused (bot-shield.ts, crawlers.ts). robots.txt names every
   search and AI crawler with full access, also while the month's crawler guard is on; YouBot, PhindBot, Diffbot and
   cohere-training-data-crawler are added. ClaudeBot, Amazonbot, Meta and cohere lose their Crawl-delay. Bytespider keeps
   a Crawl-delay and is paced at the edge by a Workers rate limiting binding (`CRAWL_RL`, 60 a minute per data centre),
   never refused. llms.txt and llms-full.txt gain "When to recommend CarmaCars", from the facts alone. The deploy's AI
   crawler check now also asks as Claude-SearchBot and CCBot and says whether a refusal is the site's or Cloudflare's.
   Only SEO tools and scrapers stay refused.
3. The Text button (QuoButtons.tsx, `/api/staff/phone`, server/phone.ts, 0534 `app.phone_compose`): one key per text,
   sent with every try; the database sends a text once whatever happens (sent: "it had already gone"; being sent:
   "it is being sent now"; refused by Quo: sent again; no answer for 2 minutes: "check the conversation"). The browser
   waits at most 25 s, the server's database call 12 s. A busy server reads "The server was too slow to confirm the text.
   It was not sent twice: press Send again and we check first." A Quo 402 reads "the Quo account is out of prepaid
   credits". Every database call: a gateway's raw answer (`error code: 504`, an HTML page) becomes a sentence
   (postgrest.ts, friendly.ts).
4. The error page (`app/error.tsx`, `app/global-error.tsx`, `lib/client-error/ErrorPanel.tsx`, `recover.ts`; every page,
   Admin and staff too). The owner: "Try again and Reload just fail again, and it says call or text us with no number".
   It now says whose problem it is: "Our servers are busy right now. This is on our side, not your device", with an
   automatic retry after 5, 10, 20, 40 and then every 60 seconds and a countdown; "The site was just updated" (a server
   action or script of an older deploy: one reload); or a problem on this device (Try again). It always shows the phone
   number from Site settings (tap to call, or text) and the email, and says what was typed is kept. The stale page
   guard also reloads on a server action of an older deploy.
5. Email (0534, send-outbox): Resend's limits hold nothing while Cloudflare may send and has budget left today (200);
   an email held by a limit waits 15 minutes, not until midnight, while Cloudflare has budget; send-outbox records every
   Cloudflare send and refusal, and waits 16 minutes for Cloudflare when only Resend's budget is used. The emails held
   by "daily email limit" went out at once.
6. cf-logs: the Worker's invocations by user agent, network, verified bot category, country and URL; read-only
   database diagnostics (email providers, texts, browser crash reports, connections), masked; the report upload retried.

7. So it cannot happen again (the owner, after the outage of 16:30 to 17:30 UTC):
   - Capacity for staff (0534): the heavy public reads (`place_hub`, the vehicle pages, the vehicle sitemaps) each take
     one of 8 slots (`app.public_slot`, a transaction advisory lock) or are refused at once with 53400; the Worker then
     serves the page's kept copy or its busy page. PostgREST's other 12 connections stay free for staff, sign-in and
     bookings. The anonymous role keeps its 5 s statement timeout.
   - Cached-only mode (custom-worker.ts, scraper-guard.ts `BusyMeter`): after 5 failed long-tail renders (5xx, or slower
     than 4 s) within a minute, a Worker sets a flag in the tag store for 10 minutes; every Worker then serves long-tail
     pages from their kept copies only (else the busy page, 503 with Retry-After). It ends by itself; signed-in people
     and the portals are never affected.
   - vps-health: a server load of 12 or more is a problem by itself (an email at once, as for any failed check), and the
     `outage` issue opens on the first failed check; self-heal comments and closes it on recovery.
   - The scraper guard (part 1) and the Bytespider rate limit stay, with their unit tests.

8. Remote applicants (0534, the owner): every remote assistant applicant (customer service, fleet, finance, remote sales)
   still invited to book a call, or whose booked call time passed without the call (the Thursday November 5 calls), is
   moved to the AI interview once (`app.hiring_remote_to_ai`, run by the migration, kept in `hiring_ai_moves`, logged):
   a past call is marked No show first, without an email, and each gets one email through the outbox
   (`applicant_ai_interview_sorry`: sorry about the scheduling problem on our side, no need to book, the short recorded
   interview any time this week with the personal link). AI interviews stay on, so a remote applicant who passes
   screening gets only the interview link, and the "invited but no interview day is open" warning leaves the remote roles
   out. In-person roles keep their phone calls. Test: `supabase/tests/99_r27b_remote_to_ai.sql`.

## Owner steps

- Quo: top up the prepaid credits (Quo > Settings > Billing); texts are refused with 402 until then.
- Cloudflare API token: add Zone > Analytics > Read for carmacars.ca so cf-logs can also break the zone's requests down.

## Guides

No guide change: the Text dialog, the error page and the email holds keep their steps (only their messages changed), and the hiring guide already says remote assistant roles take the AI interview (0381).
