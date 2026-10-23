# Moving CarmaCars off hosted Supabase onto the company's own server

The hosted project (Pro plan, Nano compute, 0.5 GB) keeps running out of memory. This folder holds a self-hosted
Supabase stack for an OVHcloud VPS-4 (8 vCPU, 24 GB RAM, about 200 GB NVMe, Ubuntu 24.04, Canada) and the GitHub
Actions workflows that build the server, copy the hosted project onto it, back it up, watch it and switch the site
over. Nothing here changes production until a switch below is run by hand.

## How it fits together

```
browser ─┐
         ├─> carmacars.ca (Cloudflare Worker) ──> https://api.carmacars.ca ──> Caddy (TLS, :443)
 Worker ─┘                                                                    └─> Kong (127.0.0.1:8000)
                                                                                   ├─ /auth/v1      GoTrue
                                                                                   ├─ /rest/v1      PostgREST
                                                                                   ├─ /storage/v1   Storage (files on disk)
                                                                                   └─ /functions/v1 edge-runtime
 GitHub Actions ── SSH (VPS_SSH_KEY) ── tunnels to Kong, pg-meta (SQL as JSON), Postgres 17
 pg_cron (in Postgres) ── pg_net ──> http://kong:8000/functions/v1/... (never leaves the machine)
 WAL ──> spool ──> wal-g ──> S3 bucket;  nightly wal-g base backup;  nightly logical dump (from Actions) ──> S3 bucket
```

- **Same keys.** The server uses the hosted project's JWT secret, anon key and service_role key, so the Worker's
  secrets, the anon key in the browser bundle and Admin "view as" tokens keep working. GoTrue signs new user tokens
  with an ES256 key of its own (published at `/auth/v1/.well-known/jwks.json`, which `web/src/lib/auth/jwt-verify.ts`
  reads), with issuer `https://api.carmacars.ca/auth/v1`. PostgREST and Storage also accept the hosted project's
  public signing keys, so a token the hosted project signed keeps working for the rest of its hour.
- **Sessions survive.** The refresh tokens are in the copied database. The Worker now refreshes a token from another
  issuer at once (`web/src/lib/auth/edge-refresh.ts`), and the deploy keeps the cookie name `sb-<ref>-auth-token`
  (`NEXT_PUBLIC_SUPABASE_AUTH_COOKIE`), so nobody is signed out by the switch.
- **One switch for every script.** `DB_BACKEND` (a repository variable, `supabase` when unset) decides whether the
  deploy and every workflow use the Management API and `<ref>.supabase.co`, or the server over SSH
  (`scripts/deploy/lib.sh`, `scripts/deploy/vps.sh`, `scripts/deploy/sb.sh`).
- **Left out:** Realtime, Analytics, Vector and imgproxy (the app uses none of them). Supavisor is there but off
  (compose profile `pooler`): nothing outside the server connects to Postgres directly. Studio is on 127.0.0.1 only.

### Files

| Path | What |
|---|---|
| `host` | the server's IPv4 address (commit it once the VPS exists) |
| `known_hosts` | the server's SSH host key (commit the line vps-provision prints) |
| `bootstrap.sh` | hardening (ufw 22/80/443, fail2ban, SSH keys only, unattended security upgrades), Docker, swap, sysctl, UTC, wal-g, the stack's files |
| `cloud-init.yaml` | optional user data at order time (the deploy key, no passwords, ufw) |
| `supabase/` | `docker-compose.yml`, `defaults.env` (non-secret settings, Postgres tuning), Kong, Caddy, the functions router |
| `bin/` | server scripts installed to `/opt/carmacars/bin` (`dc` is docker compose with both env files) |
| `systemd/` | WAL push every minute, wal-g base backup nightly |
| `scripts/` | run on the GitHub runner: `make-env.sh`, `copy.sh`, `cutover.sh`, `auth-env.mjs`, `jwt-keys.mjs`, `filter-data.py` |

On the server: `/opt/carmacars/supabase/.env` (secrets, mode 600, written by `make-env.sh`), `auth.env` and
`auth-config.json` (GoTrue's settings), `functions.env` (Edge Function secrets), `volumes/` (database, files).

## What is needed before starting

| Input | Where | Status |
|---|---|---|
| The VPS: OVHcloud VPS-4, Canada (Beauharnois), Ubuntu 24.04, SSH key `carmacars-deploy` for `ubuntu` | OVHcloud order | to order |
| Its IPv4 address | `infra/vps/host`, committed | after the order |
| `VPS_SSH_KEY` | repository secret | present (per the brief) |
| `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_REF` | repository secrets | present |
| `SUPABASE_DB_PASSWORD` (the hosted database's password, for `supabase db dump`) | repository secret | present (used by `backup.yml`, `catalog.yml`, `places.yml`) |
| `CLOUDFLARE_API_TOKEN` (DNS edit on carmacars.ca) | repository secret | present |
| `BACKUP_S3_ENDPOINT`, `BACKUP_S3_REGION`, `BACKUP_S3_BUCKET`, `BACKUP_S3_ACCESS_KEY_ID`, `BACKUP_S3_SECRET_ACCESS_KEY` | repository secrets | to add (OVHcloud Object Storage or Backblaze B2) |
| `BACKUP_WALG_KEY`: `openssl rand -hex 32`; also into the company password manager (wal-g backups cannot be read without it) | repository secret | to add |
| `RESEND_API_KEY` (optional: health alerts still go out when the server itself is down) | repository secret | optional |

The workflows are `workflow_dispatch` workflows: GitHub only offers them once they are on the default branch. Merge
branch `vps` into `main` first. That is safe: with `DB_BACKEND` unset everything works as before, and the new
schedules (vps-health, vps-backup) do nothing until `DB_BACKEND=vps`.

## Step by step

### 1. Order and address
1. Order the VPS-4 in Canada with Ubuntu 24.04 and the `carmacars-deploy` public key for `ubuntu`
   (`ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINm9cLr9zGAEbWvsZz8Bh8+vXNlEL7hi0vxXaWjKn/vG carmacars-deploy`).
   Optionally paste `cloud-init.yaml` as user data.
2. Put the IPv4 address on its own line in `infra/vps/host` and commit it to `main`.

### 2. Build the server: workflow **vps-provision**
1. Run it with the defaults. It bootstraps, writes `.env`, starts the stack and checks Auth, the database API,
   Storage, pg-meta, Kong's 404 for everything else and the Auth issuer through the tunnel.
2. Commit the host key line from the run summary as `infra/vps/known_hosts` (from then on a changed host key stops
   every workflow).
3. Run it again with **dns: true**: it creates the DNS-only A record `api.carmacars.ca` (a new name; no existing
   record is touched). A few minutes later run it once more: it then checks `https://api.carmacars.ca` too
   (Caddy gets the Let's Encrypt certificate on the first request).

DNS-only (grey cloud) is the default because Caddy then issues and renews certificates by itself and the Worker
talks to the server directly. Proxying (orange cloud) is possible later: set SSL/TLS to Full (strict) for the name
after the first certificate exists; renewals then depend on Cloudflare passing `/.well-known/acme-challenge/` on
port 80.

### 3. Rehearse the copy: workflow **vps-copy**
Run it with `steps: all`. It reads the hosted project only and rebuilds the server's database from nothing:
dump (Supabase CLI: roles, schema, data), restore, vault (re-created from decrypted values, so they decrypt with the
server's key), pg_cron jobs (re-created **paused**, function URL changed to `http://kong:8000/functions/v1/`), Auth
settings (`config/auth` rendered into GoTrue, the Resend SMTP password and SMS hook secret from the vault), the three
Edge Functions and their secrets, the stored files (bucket by bucket; `backups` skipped), then **verify**.

Read the summary:
- **Verify** must say "No problems found". Differences from the hosted project are expected while it is live.
- **Restore**: "columns dropped" and "tables the server does not have" mean the hosted Auth/Storage is newer than
  the pinned images. If anything is listed, raise `supabase/gotrue` / `supabase/storage-api` in
  `docker-compose.yml`, run vps-provision, and rehearse again.
- **Auth**: settings "not carried" are hosted settings without a GoTrue variable in `auth-env.mjs`.
- **TOTP**: if TOTP factors are stored encrypted with the hosted project's key, those people (Admin and staff) must
  enrol their authenticator again after the switch.
- The dump time plus restore time is the length of the write freeze on the day.

Run it as often as wanted. To try the stack with real data without risk, open Studio through a tunnel:
`ssh -L 3000:127.0.0.1:3000 ubuntu@<ip>` and browse http://localhost:3000.

### 4. Backups: workflow **vps-backup**
1. Create the bucket (private) and an access key limited to it; add the six `BACKUP_*` secrets.
2. Run **configure**: wal-g settings onto the server, WAL archiving on, first base backup.
3. Run **backup** (logical dump through the tunnel, encrypted to the vault's `backup_age_recipient`, restored and
   compared on the runner) and **pitr-test** (newest base backup plus every archived WAL file, replayed in a
   throwaway container on the server). Both must pass.

After the cutover these run by themselves: logical backup nightly at 07:23 UTC (30 days), base backup nightly at
06:10 UTC (7 kept, so point-in-time recovery over the last week), WAL within 5 minutes, PITR test on Mondays.
The hosted project's `backup.yml` backup and check jobs stop by themselves once `DB_BACKEND=vps`.

### 5. Cutover day (a quiet hour, e.g. 02:00 Toronto; about 30 to 60 minutes)
All in **vps-cutover** unless said otherwise; every switch but `status` needs `confirm: CUTOVER`.

| # | Action | Effect |
|---|---|---|
| 1 | `status` | both sides' state (read only) |
| 2 | `freeze-hosted` | hosted pg_cron jobs paused (their states kept on the server), the hosted database read-only by default, the API's pools closed. The site still reads; writes (bookings, sign-ups, uploads) fail until step 6 |
| 3 | `final-copy` | the full copy of the frozen project; verify requires exact counts (sign-in tables excepted when only the API role could be frozen) |
| 4 | `go-live` | the server's jobs that were active on the hosted project resume; the server is marked live (copy and reset refuse from now on) |
| 5 | Settings > Secrets and variables > Actions > Variables: **DB_BACKEND = vps** | every workflow now uses the server |
| 6 | workflow **ci**: deploy on, environment production (checks off saves time) | the Worker is rebuilt with `NEXT_PUBLIC_SUPABASE_URL=https://api.carmacars.ca`, the same keys and cookie name; functions, Auth settings, the SMS hook and the Stripe webhook secret are applied to the server |
| 7 | smoke tests (below) | |
| 8 | workflow **vps-health** by hand, then **verify** | from now on vps-health runs every 5 minutes and emails on trouble |

Smoke tests (a phone and a laptop):
1. Home, /cars and a car page load; photos show.
2. A signed-in session from before the switch is still signed in (the refresh happens on the first page).
3. Sign out, sign in by email; sign in by phone (code by SMS); an Admin with two-step sign-in passes it.
4. Make a test booking up to the payment screen; an Admin page with data opens; "view as" a renter works.
5. Upload a document (when Storage is in use) and open it.
6. Within 5 minutes: `cron.job_run_details` on the server shows the outbox job succeeding (Studio, or
   `scripts/deploy/sb.sh sql "select jobname, status, start_time from cron.job_run_details join cron.job using (jobid) order by start_time desc limit 10"` with `DB_BACKEND=vps`), and a test email arrives.
7. Admin > Today: the site check shows no new problem.

### 6. Rollback
- **Before go-live** (steps 2 to 3 went wrong): `unfreeze-hosted`. Nothing else changed; the site is back as before.
- **After go-live**: `rollback` (the server's jobs paused, not live, the hosted project unfrozen with its jobs
  resumed), set `DB_BACKEND=supabase` (or delete the variable) and run ci with deploy. **Data written on the server
  after go-live is not carried back**: before the rollback, list what changed (`created_at`/`updated_at` after the
  go-live time in bookings, payments, users and the outbox, from Studio on the server) and re-enter or script it on
  the hosted project. Roll back only for a failure found within the first hour.
- Keep the hosted project as it is (frozen) for two to four weeks as the fallback, then pause or delete it and
  downgrade the plan.

### 7. After the switch
- A day later run vps-provision with **trust_hosted_jwks: false** (the hosted signing keys are no longer needed).
- Keep `SUPABASE_PROJECT_REF` (the session cookie keeps its name from it). `SUPABASE_ACCESS_TOKEN` and
  `SUPABASE_DB_PASSWORD` are needed only for the hosted project.

## Upkeep
- **Updates:** security updates install themselves (no automatic reboot). `/var/run/reboot-required` means a reboot
  is due: do it in a quiet hour (`sudo reboot`; the containers come back by themselves, `restart: unless-stopped`).
  Docker itself is upgraded by hand (`sudo apt-get install --only-upgrade docker-ce ...`), since it restarts every container.
- **Supabase versions:** change the image tags in `supabase/docker-compose.yml` (keep the Postgres image: a major
  upgrade is a separate project), run vps-provision. A newer GoTrue or Storage runs its own migrations at start.
- **A container misbehaves:** `ssh ubuntu@<ip>`, `sudo /opt/carmacars/bin/dc ps`, `sudo /opt/carmacars/bin/dc logs --tail 100 auth`,
  `sudo /opt/carmacars/bin/dc restart rest`. `sudo /opt/carmacars/bin/health-local` gives the same report as vps-health.
- **Disk:** vps-health warns above 85%. Postgres data is `volumes/db/data`, files `volumes/storage`.
- **Restore from backup:** logical: `scripts/backup/restore-test.sh --dir <downloaded folder> --keep` gives a running
  copy; point in time: `bin/walg-restore-test` shows the procedure (backup-fetch, WAL into `pg_wal`, recovery).

## Cost (per month, before tax)

| | Hosted Supabase | Own server |
|---|---|---|
| Today | Pro US$25 (includes US$10 of compute; the current small instance) | |
| Comparable memory | Pro + compute: Medium 4 GB ≈ US$75, Large 8 GB ≈ US$125, XL 16 GB ≈ US$235 | VPS-4, 24 GB: €23.48 list before April 2026; OVHcloud raised VPS prices about 43% from April 1, 2026, so expect roughly €33 to €35 (confirm the Canadian price in CAD on the order page; 12-month commitment is cheaper) |
| Backups | included (7 days on Pro) | bucket: about 10 to 30 GB, under US$1 (Backblaze B2 US$6/TB; OVHcloud Object Storage similar) |
| During the fallback weeks | keep Pro US$25 | |
| **Steady state** | **≈ US$75 to 235** for 4 to 16 GB | **≈ US$40** for 24 GB |

The Supabase compute prices are the published ones (Medium US$60, Large US$110, XL US$210, minus the US$10 credit);
check supabase.com/pricing and the OVHcloud order page before deciding. GitHub Actions minutes are free while the
repository is public (vps-health every 5 minutes, the nightly backup).

## Status (October 23, 2026)
Server 54.39.111.152 (OVHcloud VPS-4, Beauharnois) is provisioned; host key pinned in `known_hosts`; DNS-only
`api.carmacars.ca` with a Let's Encrypt certificate. Backups go to the Cloudflare R2 bucket `carmacars-backups`
(settings read from the vault's `deploy_backup_*`). Proven on the server:
- vps-provision: every health check, inside and over https.
- vps-copy rehearsal: verify "the server matches" (327 tables, about 588,000 rows, 24 vault secrets that decrypt,
  45 pg_cron jobs paused, 1,317 stored files, Auth settings and RPC answers identical, Google sign-in carried).
- vps-backup: configure (wal-g on R2), logical backup + restore test (334 of 334 tables equal), PITR test
  (base backup + archived WAL replayed, ok).
Found and fixed on the way: COPY through the SSH tunnel ran under 1 MB/s (21 min), so schema and data now load inside the server from a compressed stream; the platform's own Postgres image (17.11.0.003) does not set up the self-hosted roles
(the stack uses the official self-hosted 17.6.1.136); the CLI's data dump leaves out the migration history (copied
separately, else the deploy would re-run migrations); a HEAD on Storage answers from the database row (files are
now checked by reading their first byte).

Left before the cutover:
- Google Cloud console: add `https://api.carmacars.ca/auth/v1/callback` to the OAuth client's authorised redirect
  URIs (Sign in with Google goes through Supabase Auth's callback, which moves).
- The freeze window: the last rehearsal's whole copy took about 6 minutes (dump 2 to 3.5 min, restore 35 s inside the
  server, 1,332 files about 1 min, verify, base backup). Plan 15 minutes of read-only site for steps 2 to 4.
- Compare two role settings by hand (the copy leaves list-valued settings to the image's defaults): the hosted
  project's `authenticator` `session_preload_libraries` and `postgres` `search_path` against the server's
  (`select rolname, rolconfig from pg_roles where rolname in ('authenticator','postgres')` on both).
- Hosted settings GoTrue has no variable for (listed by the copy's auth step: the security notification emails,
  `mfa_phone_*`, `rate_limit_web3`, `custom_oauth_max_providers`); none is used by the site today.

## Tested and not tested
Tested here (no server exists yet): `docker compose config` with the env files (including the quoting of JSON keys
and apostrophes in auth.env), `caddy validate`, YAML parsing, `actionlint` with `shellcheck` on every workflow,
`shellcheck` on every script, the server scripts that edit files (fn-secrets, fn-deploy, auth-config) against a
temporary directory, `auth-env.mjs --self-test` and a render of the real templates, `filter-data.py` on a sample
dump, `jwt-keys.mjs`, the vault and cron SQL builders, `tsc`, eslint and the unit tests (with a new test for the
issuer refresh).

Not tested, because they need the server or the hosted project: the bootstrap on a real Ubuntu 24.04, the stack
starting (image tags are those of the official compose of October 2026), Kong's routes, GoTrue with `GOTRUE_JWT_KEYS`
and the rendered `auth.env`, pg-meta's `/query` as the SQL path, the Supabase CLI dump of this project and its
restore, the vault and cron copies, the storage copy, wal-g against the bucket and the PITR test, the freeze and
unfreeze SQL on the hosted project (`alter database` may be refused to the `postgres` role; the script then freezes
the API's role instead), and the Worker against api.carmacars.ca. The rehearsal (step 3) and the backup runs (step 4)
are where these are proven; nothing in steps 1 to 4 touches production.
