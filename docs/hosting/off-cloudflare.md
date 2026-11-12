# Moving the website off Cloudflare Workers (release 42)

Owner decision, November 12, 2026: stop paying for Cloudflare. The website moves from Cloudflare Workers (OpenNext) to
the company's own server, the OVH VPS that already runs the database (self-hosted Supabase under `/opt/carmacars`,
`infra/vps/CUTOVER.md`).

This document is the inventory of everything in the code and CI that depends on Cloudflare, what replaces each item,
what each costs, and the order that moves the site without downtime. Release 42 ships the parts that are safe to merge
without moving a visitor (section 4). The DNS switch is a later, separate step, and section 5 lists what must be
finished before it.

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
| Email in | Cloudflare Email Routing to the Worker | Email Routing (free) to a small forwarder, or SES inbound: to build, section 5 |
| DNS | Cloudflare | Cloudflare, free plan |

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
| R2 bindings for files (`R2_VEHICLE_PUBLIC`, `R2_DOCUMENTS`, `R2_IDENTITY`, ...), `/media` | `src/integrations/storage/r2-binding.ts`, `src/app/api/storage/[...key]/route.ts`, `custom-worker.ts` `media` | Supabase Storage on the VPS (`STORAGE_PROVIDER=supabase`, the existing adapter). `r2` (R2's S3 API, existing adapter) also works from the server and stays free up to 10 GB | 0 | done in code; copy the files first if production is on `r2-binding` (section 5) |
| OpenNext page cache: R2 or KV (`NEXT_INC_CACHE_*`), D1 or KV tags (`NEXT_TAG_CACHE_*`), Durable Object queue (`NEXT_CACHE_DO_QUEUE`) | `open-next.config.ts`, `scripts/deploy/cloudflare.sh resources` | Next.js's built-in cache (disk and memory, one server); `revalidateTag` works as is | 0 | nothing to build |
| Cache API copies of public pages, last good copy, global copies in R2 | `src/lib/edge/page-cache.ts`, `global-store.ts`, `tag-cache-gen.ts`, `warm.ts` | Not needed for cost (no CPU billing). The "last good copy when the app fails" safety net is not ported | 0 | not ported (section 5) |
| Rate limiting binding (`CRAWL_RL`, Bytespider pacing) | `custom-worker.ts`, `src/lib/edge/bot-shield.ts` | A Caddy rate limit or an in-memory limiter in the Node entry | 0 | not ported (section 5) |
| `request.cf` (bot data, country, region, city) and `cf-ipcountry`, `cf-ipcity`, `cf-region-code` headers | `custom-worker.ts` (scraper guard, geo cookie), `src/server/request.ts`, `/api/chat`, `/api/games`, `src/features/live-map` | Country and region from a free GeoIP file on the server (DB-IP Lite or GeoLite2). The visitor's address comes from Caddy (`CF-Connecting-IP` is set by Caddy, never taken from the visitor) | 0 | address done; geo and the scraper guard not ported (section 5) |
| Images transformations (`fetch` with `cf.image`: cut-out, HEIC to JPEG, resize) | `src/integrations/photos/cloudflare.ts` | The local photo steps that already exist (`photos/local.ts`, the default since release 35). Cut-out and HEIC then need `sharp` with libheif and a background remover (rembg in a container) | 0 | falls back to local automatically; cut-out and HEIC to build |
| Email Service binding (`EMAIL`) for sending | `src/app/api/email/send/route.ts`, `scripts/deploy/email-binding.sh` | Amazon SES then Resend (release 41). The route answers 503 on Node and the sender moves on | SES 0.10 USD per 1,000 emails | done |
| Email Routing to the Worker (`email` handler: Turo emails to `trips@in.carmacars.ca`, questions with automatic answers) | `custom-worker.ts` `email`, `scripts/deploy/cloudflare.sh email` | Option A: keep Email Routing (free) and a 30-line forwarding Worker on the free Workers plan that POSTs the raw message to `/api/inbound/turo` or `/api/inbound/ask` on the VPS. Option B: SES inbound to an HTTPS endpoint (0.10 USD per 1,000 emails) | 0 (A) | to build (section 5) |
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
The site starts DNS-only (simplest for certificates); turning the proxy on later is a small Caddy change noted in
`infra/vps/web/site.caddy`.

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
  It builds the image, sends it over SSH, starts it, waits for healthy, loads Caddy's site file, then checks
  `/api/health` on the first hostname of `WEB_VPS_HOSTNAMES`. It never touches DNS or the Worker. Action `rollback`
  starts the previous image.

Settings on the server (`/opt/carmacars/web/web.env`, written by the job): the Worker's secrets plus
`STORAGE_PROVIDER=supabase`, `CLOUDFLARE_ACCOUNT_ID`, `WORKERS_AI_API_TOKEN`. Set by the image and compose:
`HOSTING_TARGET=node`, `DEPLOY_VERSION`, `CRON_ENABLED`.

## 5. Not ported yet: finish before the DNS switch (release 43)

1. **Inbound email** (Turo trip emails, automatic answers): the forwarder of section 2.1. Until it exists, switching
   DNS would stop inbound email processing.
2. **Files**: confirm which storage production uses (the deploy's "Cache and storage" annotation). On `supabase`
   nothing is needed. On `r2-binding`, copy the six buckets into Supabase Storage first, or run the server with
   `STORAGE_PROVIDER=r2` and R2 S3 keys.
3. **The full e2e suite against the Node entry** (`BASE_URL` at the temporary hostname) and a first real
   `deploy-vps` run. The standalone build could not be run in the authoring sandbox (out of memory), so the first
   run of the job is its first real build.
4. **Geo**: the cookie notice's region cookie (`cc_geo`) and the city on the live map and chat need a GeoIP lookup on
   the server (or the free proxy).
5. **Crawler load**: Bytespider pacing and the scraper guard are not ported. The crawler shield, the scanner 404s and
   the place and model-year 404s are. Add a Caddy rate limit before the switch.
6. **Last good copy** of public pages when the app or database is busy, the busy page, and the post-deploy warm-up.
   The page cache starts empty after each deploy (first visits render).
7. **Older build files**: the Worker keeps the previous deploys' scripts and styles for 8 days (`keep-assets.mjs`).
   On the server a page opened before a deploy reloads once (`src/lib/chunk-guard.ts`). Port by keeping
   `.next/static` in a Docker volume.
8. **Photo cut-out and HEIC** (section 2.1).

## 6. Cutover order (no downtime)

1. Merge release 42. Nothing changes for visitors.
2. Owner: create the Workers AI token and add it as the secret `WORKERS_AI_API_TOKEN`; add a DNS-only A record for a
   temporary hostname pointing at the VPS; set `WEB_VPS_HOSTNAMES` to it and `WEB_ON_VPS` to `1`.
3. Run `deploy-vps` (action `deploy`, cron `keep`). The site answers on the temporary hostname with the production
   database. Cron stays **off**: the Worker still runs the jobs, and they must never run twice (deposits, statements).
   Sign-in works on the temporary hostname only after it is added to the Auth redirect list; public pages need nothing.
4. Finish section 5, run the e2e suite and a manual pass of each portal against the temporary hostname.
5. Lower the TTL of the `carmacars.ca` and `www` records to 1 minute a day ahead. Add both names to
   `WEB_VPS_HOSTNAMES` and run `deploy-vps` again (Caddy can only get their certificates once DNS points at it, so
   the first minute after the switch is served as soon as the certificate is issued; to avoid even that, switch `www`
   first and the apex a few minutes later, or use the free proxy with Full (strict)).
6. The switch, in this order within a few minutes: remove the Worker's custom domains for `carmacars.ca` and `www`
   and create DNS-only A (and AAAA) records to the VPS; redeploy the Worker with its cron trigger removed; run
   `deploy-vps` with cron `on`. Webhooks (Stripe, Quo, Meta, Twilio) follow the hostname and need no change.
7. Keep the Worker deployed for one day as the rollback: put the custom domains back, restore its cron, run
   `deploy-vps` with cron `off`.
8. After a clean day: cancel Workers Paid (Cloudflare dashboard, Workers plans, change to Free). Then, in a later
   release, remove the Worker build from `ci.yml` and the unused workflows of section 2.3.

## 7. Rollback at any point

- Before the DNS switch there is nothing to roll back: the Worker serves every visitor. Set `WEB_ON_VPS` to `0` to
  switch the job off; `docker compose down` in `/opt/carmacars/web` stops the container.
- A bad image on the server: `deploy-vps` with action `rollback`.
- After the DNS switch: step 7 above.
