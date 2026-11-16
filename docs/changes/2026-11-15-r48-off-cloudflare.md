# The move off Cloudflare finished inside release 48, with no dashboard click (Release 48: 3070)

No migration. Owner decision, November 15: the R48 deploy also moves carmacars.ca onto the company's server, with the
Cloudflare API token CI already has, and no manual Cloudflare clicks. docs/hosting/off-cloudflare.md, sections 5.8, 6, 7.

- Why the first try failed: deploy-vps run 43702475958 stopped at `https://new.carmacars.ca/api/health` answering 525.
  Caddy asked Let's Encrypt for certificates over HTTP-01, which cannot reach the server through a proxied record or
  while the apex and www still point at the Worker.
- **Certificates:** a Cloudflare Origin CA certificate for `carmacars.ca` and `*.carmacars.ca` (15 years), made by the
  deploy through the API (`scripts/deploy/cf-site.sh origin-cert`), kept on the server and reused while it covers the
  domain for 30 days or more; Caddy loads it (`infra/vps/web/site.caddy`). Chosen over DNS-01 because nothing renews,
  no DNS-editing token lives on the server and the stock Caddy image stays (the comparison is in section 5.8). Fallback
  when the token may not make one: Let's Encrypt over HTTP-01 with Always Use HTTPS turned off.
- **Step A, on every deploy-vps deploy:** the `new` A record proxied to the server, "Add visitor location headers" on,
  SSL Full (strict) (Full with a warning when another proxied host of the zone has no valid certificate at its origin).
- **Step B, action `switch`:** the Worker's cron trigger deleted, its carmacars.ca and www custom domains and routes
  removed, A records proxied to the server; then the server's cron on, only when the Worker's cron is confirmed gone,
  and inbound mail to the forwarder. Action `rollback` reverses B (the server's cron off first); the image rollback is
  now `rollback-image`.
- A permission the token lacks is named (job warning and summary), its step is skipped and the rest goes on.
- **No new secret or variable:** deploy-vps takes `web_on_vps` (on) and `hostnames` as inputs, the address comes from
  `DEPLOY_HOST` (or `infra/vps/host`). `ci.yml` has the input `web_live_on` (auto, worker, vps); auto reads the zone (the
  apex on the server: vps), so a deploy after the switch keeps the Worker a standby without domains or cron, and still
  runs the migrations. Unreadable: the deploy stops rather than guess.
- **AI without a Workers AI token:** the server uses Gemini (the key it already has) for text and vision; identity
  documents and recordings are never sent to Gemini's free tier (a person types or listens). The staff assistant uses
  its Claude fallback when allowed.
- Tests: `scripts/deploy/cf-site.test.mjs` (a stand-in of Cloudflare's API: A and B twice with the same result, the
  rollback, the Origin CA certificate made once then reused, a token without permissions), run by deploy-vps's
  node-smoke job; `web/src/integrations/llm/gemini.test.ts`.

## Guides

No guide change: the hosting move changes no screen's steps; the release-day sequence is in docs/hosting/off-cloudflare.md.
