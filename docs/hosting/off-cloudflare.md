# Moving the website off Cloudflare Workers (release 42)

Owner decision, November 12, 2026: stop paying for Cloudflare. The website moves from Cloudflare Workers (OpenNext) to
the company's own server, the OVH VPS that already runs the database (self-hosted Supabase under `/opt/carmacars`,
`infra/vps/CUTOVER.md`).

This document is the inventory of everything in the code and CI that depends on Cloudflare, what replaces each item,
what each costs, and the order that moves the site without downtime. Release 42 ships everything the switch needs
(sections 4 and 5), tested on GitHub's runner before any DNS change, and section 6 is the owner's short list of
button presses for the switch itself. Only Cloudflare's **paid** plan goes; its free plan stays in front of the server.

## 1. Summary

| | Today | After |
|---|---|---|
| Website | Next.js 16 on a Cloudflare Worker (OpenNext), Workers Paid | The same Next.js app as a Node server in Docker on the VPS, behind Caddy (TLS by Let's Encrypt) |
| Page cache | R2 or KV, D1 tags, a Durable Object queue | Next.js's own cache on the server's disk |
| Files | Supabase Storage on the VPS, or R2 through Worker bindings | Supabase Storage on the VPS |
| Scheduled jobs | Worker cron trigger, every minute | The same plan from the Node entry (`CRON_ENABLED=1`) |
| AI | Workers AI binding, Gemini | Workers AI over its REST API (same free daily allowance), Gemini |
| Bot check on forms | Turnstile | Turnstile (free, works on any host) |
| Email out | Amazon SES, Resend (release 41) | unchanged |
| Email in | Cloudflare Email Routing to the Worker | Email Routing (free) to a small forwarder Worker on the free plan, which posts each message to the server (section 5.1) |
| DNS | Cloudflare | Cloudflare, free plan, proxied (orange cloud): free CDN for static files, DDoS protection, the visitor's country and city |

**Monthly cost after the move: 0 USD of new fixed fees.** The VPS is already paid for (the database lives there).
Cloudflare goes back to the free plan: Workers Paid (5 USD a month plus usage: 0.30 USD per million requests above
10 million, 0.02 USD per million CPU milliseconds above 30 million; November's crawl ran at about 785 million CPU ms a
month) is cancelled.

## 2. Inventory: every Cloudflare dependency and its replacement

Found by searching the repository for `wrangler`, `getCloudflareContext`, `@opennextjs/cloudflare`, the binding names
of `web/wrangler.jsonc`, `caches.`, `request.cf`, `cf-` headers, `api.cloudflare.com` and `challenges.cloudflare.com`.

### 2.1 Runtime (the Worker and its bindings)

| Cloudflare piece | Where in the code | Replacement on the VPS | Cost | Status in r42 |
|---|---|---|---|---|
| Worker runtime, OpenNext build (`cf:build`, `wrangler deploy`) | `web/wrangler.jsonc`, `web/open-next.config.ts`, `scripts/deploy/open-next/`, `scripts/deploy/wrangler-config.mjs`, `web/scripts/worker-size.mjs`, `ci.yml` deploy | `next build` with `output: 'standalone'` (`HOSTING_TARGET=node`, `npm run build:node`), run under Node 22 in Docker (`infra/vps/web/Dockerfile`) | 0 | done (build flag, image, compose) |
| Worker entry: security headers, script nonce and content security policy (HTMLRewriter), view-as and cross-site guards, session refresh, scanner 404s, crawler shield | `web/custom-worker.ts` | `web/scripts/vps-server.mjs`, a Node front for the app that imports the same modules (`src/lib/security`, `src/lib/auth/edge-refresh.ts`, `src/lib/edge`) | 0 | done, not yet run through the e2e suite |
| Custom domains, certificate, http to https, compression | `routes` in `wrangler.jsonc`, Cloudflare's edge | Caddy (already on the VPS for the API): Let's Encrypt certificates, redirect, zstd and gzip (`infra/vps/web/site.caddy`) | 0 | done |
| Cron trigger `* * * * *` | `wrangler.jsonc` `triggers`, `custom-worker.ts` `scheduled` | The minute tick inside the Node entry (`src/lib/platform/cron-plan.ts`), on only with `CRON_ENABLED=1` | 0 | done; off until the DNS switch |
| Service binding to itself (`WORKER_SELF_REFERENCE`) | `src/server/pdf-jobs.ts`, `src/server/drive-import.ts`, warm-up in `custom-worker.ts` | A plain request to the app's own port (`selfFetcher`, `INTERNAL_ORIGIN`) | 0 | done |
| Version metadata (`CF_VERSION_METADATA`) | `src/app/api/bug-report/route.ts`, `src/lib/edge/page-cache.ts` | `DEPLOY_VERSION` (the commit the image was built from) | 0 | done |
| Workers AI binding (`AI`): listing copy, live chat and auto-replies, photo gates and plate checks (vision), transcripts, the staff assistant, car values | `src/integrations/llm`, `vision`, `transcribe`, `src/server/assistant.ts` | See 2.2 | 0 | done (REST adapter) |
| R2 bindings for files (`R2_VEHICLE_PUBLIC`, `R2_DOCUMENTS`, `R2_IDENTITY`, ...), `/media` | `src/integrations/storage/r2-binding.ts`, `src/app/api/storage/[...key]/route.ts`, `custom-worker.ts` `media` | Supabase Storage on the VPS (`STORAGE_PROVIDER=supabase`, the existing adapter). `r2` (R2's S3 API, existing adapter) also works from the server and stays free up to 10 GB | 0 | done; production is on `supabase` already, nothing to copy (section 5.6) |
| OpenNext page cache: R2 or KV (`NEXT_INC_CACHE_*`), D1 or KV tags (`NEXT_TAG_CACHE_*`), Durable Object queue (`NEXT_CACHE_DO_QUEUE`) | `open-next.config.ts`, `scripts/deploy/cloudflare.sh resources` | Next.js's built-in cache (disk and memory, one server); `revalidateTag` works as is | 0 | nothing to build |
| Cache API copies of public pages, last good copy, global copies in R2 | `src/lib/edge/page-cache.ts`, `global-store.ts`, `tag-cache-gen.ts`, `warm.ts` | Not needed for cost (no CPU billing). The "last good copy when the app fails" safety net is not ported | 0 | done: last good copies on the server's disk (section 5.4) |
| Rate limiting binding (`CRAWL_RL`, Bytespider pacing) | `custom-worker.ts`, `src/lib/edge/bot-shield.ts` | A counter in the Node entry: 60 pages a minute | 0 | done (section 5.3) |
| `request.cf` (bot data, country, region, city) and `cf-ipcountry`, `cf-ipcity`, `cf-region-code` headers | `custom-worker.ts` (scraper guard, geo cookie), `src/server/request.ts`, `/api/chat`, `/api/games`, `src/features/live-map` | Country and region from a free GeoIP file on the server (DB-IP Lite or GeoLite2). The visitor's address comes from Caddy (`CF-Connecting-IP` is set by Caddy, never taken from the visitor) | 0 | done through Cloudflare's free proxy and its location headers (section 5.2); the scraper guard's browser check is ported, its hosting-network rule is not (section 5.3) |
| Images transformations (`fetch` with `cf.image`: cut-out, HEIC to JPEG, resize) | `src/integrations/photos/cloudflare.ts` | The local photo steps that already exist (`photos/local.ts`, the default since release 35). Cut-out and HEIC then need `sharp` with libheif and a background remover (rembg in a container) | 0 | done: the cut-out and HEIC are asked for by address on the zone (`/cdn-cgi/image/...`, free up to 5,000 a month), everything else locally (section 5.5) |
| Email Service binding (`EMAIL`) for sending | `src/app/api/email/send/route.ts`, `scripts/deploy/email-binding.sh` | Amazon SES then Resend (release 41). The route answers 503 on Node and the sender moves on | SES 0.10 USD per 1,000 emails | done |
| Email Routing to the Worker (`email` handler: Turo emails to `trips@in.carmacars.ca`, questions with automatic answers) | `custom-worker.ts` `email`, `scripts/deploy/cloudflare.sh email` | Option A: keep Email Routing (free) and a 30-line forwarding Worker on the free Workers plan that POSTs the raw message to `/api/inbound/turo` or `/api/inbound/ask` on the VPS. Option B: SES inbound to an HTTPS endpoint (0.10 USD per 1,000 emails) | 0 (A) | done, option A (section 5.1) |
| Turnstile | `src/features/forms/Turnstile.tsx`, `src/integrations/turnstile`, `src/lib/security/csp.ts` | Stays. Turnstile is free and independent of where the site is hosted | 0 | nothing to change |
| DNS, zone settings | `scripts/deploy/cloudflare.sh dns`, `vps-provision.yml` | Stays on Cloudflare's free plan. Website records become DNS-only A records to the VPS (as `api` already is) | 0 | owner step at the switch |

### 2.2 AI: which replacement is free

- **Workers AI over the REST API: free.** The 10,000 neurons a day are included on the free Workers plan and do not
  need Workers Paid. Above the allowance the free plan refuses the call (it does not bill), and the app's usage guard
  already treats that as "paused". Same models, same prompts, same quality as today: `src/lib/platform/runtime.ts`
  `restAi` gives the app the same `run(model, input)` it has in the Worker. Needs one API token with Workers AI Read.
- **Gemini (already used for the photo checks and the showroom photos): free tier** on Google AI Studio for the Flash
  models, with per-minute and per-day limits; requests on the free tier may be used by Google to improve its models,
  so it is not the place for customer documents. The paid tier is billed per token.
- Decision in r42: keep Workers AI (REST) as the first choice because it is a like-for-like swap with no prompt
  changes, keep Gemini where it is used today. If the daily allowance becomes the limit, moving text generation to
  Gemini Flash is one new adapter next to `src/integrations/llm/workers-ai.ts`.

### 2.3 CI, scripts and reports

| Piece | Where | After the move |
|---|---|---|
| Worker build and deploy, R2, KV and D1 creation, Worker secrets | `ci.yml` deploy, `scripts/deploy/cloudflare.sh`, `keep-assets.mjs` | Replaced by `deploy-vps.yml` (`scripts/deploy/web-vps.sh`). Remove from `ci.yml` one release after the switch |
| Worker rollback, tail, logs | `worker-rollback.yml`, `worker-tail.yml`, `cf-logs.yml`, `web/scripts/cf-errors.mjs` | `deploy-vps` action `rollback`; logs are `docker logs carmacars-web` on the server |
| Usage figures and the usage guard (requests, CPU, neurons) | `usage.yml`, `src/features/usage/cloudflare.ts`, `web/scripts/cf-analytics.mjs`, `cf-traffic.mjs`, `/api/jobs/usage` | Requests and CPU no longer cost anything; keep the neurons part |
| Workers AI from scripts (translations, the investor video voice) | `web/scripts/seo-i18n.mjs`, `web/scripts/investor-video/tts.mjs` | Already REST calls: unchanged, free allowance |
| Turnstile widget and DNS through the API | `scripts/deploy/cloudflare.sh turnstile dns` | Unchanged (free plan API) |
| Server backups (wal-g, Storage files) in an R2 bucket | `infra/vps/bin/walg*`, `vps-backup.yml`, `docs/backups.md` | Unchanged. R2's free tier (10 GB, 1 million writes, 10 million reads a month) does not need Workers Paid. Any S3 bucket works if it is ever outgrown |
| Local development helper | `initOpenNextCloudflareForDev` in `web/next.config.ts`, `wrangler` and `@opennextjs/cloudflare` dev dependencies | Remove with the Worker build, one release after the switch |

### 2.4 What stays on Cloudflare, all on the free plan

DNS, Turnstile, Email Routing, Workers AI (10,000 neurons a day), the R2 backup bucket (under 10 GB), and optionally the
proxy (orange cloud) in front of the VPS, which is also free and gives a CDN, DDoS protection and the country headers.
The site runs behind the proxy from the start (section 5.2); `WEB_PROXY=off` is the DNS-only variant.

## 3. Cost

| Item | Today | After |
|---|---|---|
| Cloudflare Workers Paid | 5 USD a month plus usage | 0 (cancelled) |
| Cloudflare free plan: DNS, Turnstile, Email Routing, Workers AI allowance, R2 under 10 GB | 0 | 0 |
| OVH VPS | already paid (database) | same invoice, no change |
| TLS certificates (Let's Encrypt) | 0 | 0 |
| GitHub Actions (public repository) | 0 | 0 |
| Email: SES, Resend | per email | unchanged |
| Gemini, Stripe, phone | per use | unchanged |

What the move costs in other ways: the website and the database are then on one server, so a server outage takes both
down (today the Worker can still show cached pages), and visitors far from Canada are a little slower without the
edge unless the free proxy is turned on. `vps-health.yml` already watches the server.

## 4. What release 42 ships (safe to merge, no traffic moves)

- `web/next.config.ts`: `HOSTING_TARGET=node` adds `output: 'standalone'`. Without it the build is unchanged, and
  `cf:build` and the Cloudflare deploy in `ci.yml` are untouched. `npm run build:node`, `npm run start:node`.
- `web/src/lib/platform/runtime.ts`: the adapter. `aiBinding`, `selfFetcher`, `emailBinding`, `deploymentId`,
  `cloudflareEnv` and `storageProviderFor` give the Worker's bindings on Cloudflare and the Node equivalents with
  `HOSTING_TARGET=node`. The nine places that called `getCloudflareContext` for these now go through it. Unit tests:
  `runtime.test.ts`.
- `web/src/lib/platform/cron-plan.ts`: the Worker's cron plan as a pure function, used by the Node entry.
- `web/scripts/vps-server.mjs`: the Node entry (section 2.1). Health: `GET /healthz` (the container's health check;
  `{"ok", "target", "version", "schema", "cron"}`); `/api/health` still checks the database.
- `infra/vps/web/`: `Dockerfile`, `docker-compose.yml` (project `carmacars-web`, no published port), `site.caddy`
  (hostnames are a placeholder filled in at deploy), `web.env.example`. The Supabase stack's Caddyfile gains
  `import sites/*.caddy` and its Caddy a `sites` folder; nothing changes on the server until `deploy-vps` runs.
- `.github/workflows/deploy-vps.yml`, job `deploy-vps`: skipped unless the repository variable `WEB_ON_VPS` is `1`.
  It runs after the job `node-smoke` (section 5.7), builds the image, sends it over SSH, starts it, waits for healthy, loads Caddy's site file, then checks
  `/api/health` on the first hostname of `WEB_VPS_HOSTNAMES`. It never touches DNS or the Worker. Action `rollback`
  starts the previous image.

Settings on the server (`/opt/carmacars/web/web.env`, written by the job): the Worker's secrets plus
`STORAGE_PROVIDER=supabase`, `CLOUDFLARE_ACCOUNT_ID`, `WORKERS_AI_API_TOKEN`. Set by the image and compose:
`HOSTING_TARGET=node`, `DEPLOY_VERSION`, `CRON_ENABLED`.

## 5. The blockers closed in release 42

### 5.1 Inbound email without Workers Paid

- `infra/cloudflare/email-forwarder/` (`worker.js`, `wrangler.jsonc`): an Email Worker on the **free** plan. Email
  Routing hands it each message to `in.carmacars.ca`; it POSTs the raw message to `/api/inbound/email` on the server.
  Free plan limits: 100,000 Worker requests a day for the account and 10 ms of CPU time per invocation (the forwarder
  does one HMAC and one request; waiting does not count). Email Routing has no message quota; a message above 1 MB is
  refused, as before.
- Signed: `x-cc-signature: t=<seconds>,v1=<HMAC-SHA256>` over the time, the envelope and the message; older than five
  minutes is refused. The secret is derived from `LINK_SIGNING_KEY` by the deploy, so there is no new secret to create.
- The server (`web/scripts/vps-server.mjs`, `web/src/lib/platform/inbound-email.ts`) checks the signature and runs what
  the Worker's `email()` ran: `/api/inbound/ask` for the inboxes with automatic answers, else the Turo reader. An
  automatic answer goes back to the forwarder, which sends it with `message.reply`. If the server cannot take a
  message the forwarder fails and the sending mail server tries again.
- `deploy-vps` deploys the forwarder on every deploy (it receives nothing until the rules point at it). Input `email`:
  `forwarder` points every Email Routing rule that names the website Worker at the forwarder, `worker` points them back.

### 5.2 Geo: Cloudflare's free proxy in front of the server (recommended, and the default)

Evaluated: a GeoIP file on the server (GeoLite2 needs an account and a monthly download job) against keeping the
records proxied on Cloudflare's free plan. The proxy costs 0, keeps `CF-IPCountry` and, with the free managed transform
"Add visitor location headers", `cf-region-code`, `cf-ipcity`, `cf-iplatitude` and `cf-iplongitude`: exactly what the
cookie notice, the live map, the chat and the games already read. It also keeps DDoS protection and caches the static
files. No blocker found: uploads stay under the free plan's 100 MB (the site's limit is 70 MB) and no browser request
runs longer than its 100 seconds (the jobs call the app inside the server).

- `infra/vps/web/site.caddy`: requests from Cloudflare's published ranges (read at deploy time, never committed) keep
  Cloudflare's headers; any other request gets the address Caddy saw and none of them. `WEB_PROXY=off` gives a
  DNS-only site without location data.
- `web/src/lib/platform/node-edge.ts`: the region cookie (`cc_geo`) set by the Node entry; `/api/t` sends the live map
  the city, the rounded position and the salted address key, as the Worker did.
- Certificates stay Let's Encrypt by Caddy over port 80: keep the zone's "Always Use HTTPS" off (Caddy redirects) and
  SSL mode Full (strict).

### 5.3 Crawler load

Bytespider is paced at 60 pages a minute in the Node entry. The scraper guard's check (an agent posing as a browser on
a long-tail page with none of our cookies gets the kept copy, else the tiny page that sets a cookie and reloads) is
ported; `SCRAPER_GUARD=0` turns it off. Its hosting-network rule needs the network's name, which Cloudflare gives only
to Workers: not ported. Cached-only mode by usage is not needed (nothing is billed by CPU time).

### 5.4 Last good copy

Decided: Next.js's own page cache is not enough (it does not answer when the app or the database fails). The Node
entry keeps each public page's last good copy on disk (gzip, a Docker volume, a week, at most 20,000 pages) and
serves it when the app answers 5xx, cannot be reached (a restart) or takes more than 4 seconds, marked `x-edge-stale`.
Not ported: the post-deploy warm-up (first visits render) and the older build files kept 8 days (a page opened before
a deploy reloads once).

### 5.5 Photo cut-out and HEIC

`web/src/integrations/photos/cloudflare.ts` `urlFormatFetch`: on the server the same transformations are asked for by
address on the zone, which the free proxy answers (5,000 unique transformations a month free). The cut-out and HEIC to
JPEG go through; the composite steps, which an address cannot carry, are done locally as since release 35.

### 5.6 Files

Production uses `STORAGE_PROVIDER=supabase` (the deploy only chooses R2 with `FILES_ON_R2=yes`, which was never set):
the files are already on the server and nothing is copied. If they ever move to R2: variable `FILES_ON_R2=yes` and
secrets `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`; the server then uses R2's S3 API (free under 10 GB).

### 5.7 Tested before DNS changes

`deploy-vps`, job `node-smoke` (runs before every deploy, or alone with action `test`): builds `HOSTING_TARGET=node` on
GitHub's runner, starts the Node entry with the local stack, runs `web/scripts/node-smoke.mjs` (health, home, sign-in,
the fleet, a car page, the nonce policy, inbound email signed and unsigned) and the sign-in and Admin end-to-end tests
against it. The Cloudflare build and deploy in `ci.yml` are unchanged and remain the default.

## 6. Cutover: the owner's button presses

**A. Any day before (nobody is affected), about 10 minutes of clicking:**

1. Cloudflare > My Profile > API Tokens > Create Token > "Workers AI (Read)". Copy it. GitHub > the repository >
   Settings > Secrets and variables > Actions > New repository secret: `WORKERS_AI_API_TOKEN`.
2. Cloudflare > carmacars.ca > DNS > Add record: type A, name `new`, the server's address, Proxied.
3. Cloudflare > carmacars.ca > Rules > Settings > Managed Transforms: turn on "Add visitor location headers".
   SSL/TLS > Overview: Full (strict). SSL/TLS > Edge Certificates: "Always Use HTTPS" off.
4. GitHub > Settings > Secrets and variables > Actions > Variables: `WEB_VPS_HOSTNAMES` =
   `new.carmacars.ca,carmacars.ca,www.carmacars.ca` and `WEB_ON_VPS` = `1`.
5. GitHub > Actions > deploy-vps > Run workflow (action `deploy`, the rest as it is). When it is green, open
   https://new.carmacars.ca and look around (sign-in works there once the address is in the Auth redirect list).

**B. The switch, at a quiet hour (about 5 minutes; visitors may see an error page for up to 2 of them):**

1. GitHub > Variables: add `WEB_LIVE_ON` = `vps`.
2. Cloudflare > Workers & Pages > carmacars-prod > Settings: under Trigger Events delete the cron trigger; under
   Domains & Routes remove `carmacars.ca` and `www.carmacars.ca`.
3. Cloudflare > carmacars.ca > DNS > Add record, twice: type A, names `@` and `www`, the server's address, Proxied.
4. GitHub > Actions > deploy-vps > Run workflow: action `switch`, cron `on`, email `forwarder`. Green means: the
   certificates are issued, each address answers, the jobs run on the server, inbound mail goes to the server.

**C. After a clean day:** Cloudflare > Workers & Pages > Plans > change to Free. That ends the bill.

From then on a release is: `ci` with deploy (migrations; the Worker is kept as a standby without domains or cron
because of `WEB_LIVE_ON`), then `deploy-vps` with action `deploy`.

## 7. Rollback

- Before B there is nothing to roll back: the Worker serves every visitor. `WEB_ON_VPS` = `0` switches the job off.
- A bad image on the server: `deploy-vps`, action `rollback`.
- After B: delete the two A records, add `carmacars.ca` and `www.carmacars.ca` back under the Worker's Domains &
  Routes and its cron trigger `* * * * *`, remove the variable `WEB_LIVE_ON`, then run `deploy-vps` with action
  `switch`, cron `off`, email `worker`.
