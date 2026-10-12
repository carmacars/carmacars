# Decision 0001: zero fixed monthly fees at launch

Date: 2026-10-07. Decided by: Abbas. Supersedes any line in `architecture.md`, `setup.md`, `README.md` or `docs/source/payment_esign_setup.md` that says otherwise.

## Decision

| Piece | Choice | Fixed fee | Replaces |
| --- | --- | --- | --- |
| App hosting | Cloudflare Workers (Next.js through the OpenNext adapter), free plan | $0 | Vercel (its free plan bans commercial use) |
| Scheduled jobs | `pg_cron` in Supabase calling SQL functions directly, or a Supabase Edge Function where an outside call is needed | $0 | Vercel Cron and `/api/cron/*` |
| Webhooks (Stripe, tracker) | Supabase Edge Functions | $0 | `/api/webhooks/*` on Vercel |
| Database, sign-in | Supabase free plan, Canada (Central) | $0 | unchanged |
| Files (photos, signed documents, ID images) | Cloudflare R2, private buckets, short-lived signed links | $0 | Supabase Storage (1 GB on the free plan) |
| Backups | Nightly `pg_dump` by a GitHub Actions job, encrypted, stored in R2; restore tested before go-live | $0 | Supabase paid backups |
| Payments | Stripe, pay per transaction. No Stripe Billing, no Stripe Invoicing: recurring owner fees are charged by our own `owner-billing` job against saved payment methods | $0 | unchanged, minus Billing |
| Signatures | Built in: `signature_requests` and `signature_records` hold the typed or drawn signature, time, IP address and a hash of the signed PDF. Witnessed forms are signed on paper and uploaded | $0 | Dropbox Sign |
| Identity | Staff review of licence photo and selfie. Stripe Identity stays behind the `identity` module, off by default | $0 | Stripe Identity as the default |
| Platform email (notifications, marketing) | Resend free plan (3,000 a month, 100 a day) | $0 | unchanged |
| Staff mailbox `info@carmacars.ca` | Google Workspace, bought by the company | Paid, by choice | Cloudflare Email Routing |
| SMS and WhatsApp | Not at launch; the `messaging` module sends email only | $0 | SMS provider |

## Design consequences

1. Cloudflare's free plan allows 10 ms of processing per request and 100,000 requests a day. Pages are static or cached where possible; pricing, availability and money logic stay in SQL functions, which the plan does not count.
2. The `storage` module gets an R2 adapter. The bucket layout in `architecture.md` section 6 is unchanged.
3. Platform mail is sent from carmacars.ca through Resend (changed October 12, 2026: the owner verified the root domain in Resend). Resend's records sit on `send.carmacars.ca` and `resend._domainkey`, so they do not collide with Google Workspace's MX on the root domain.
4. Card deposit holds are re-placed every 7 days unless Stripe approves extended holds.

## When a fee starts

| Trigger | Cost |
| --- | --- |
| Requests fail on the 10 ms limit under real traffic | Cloudflare Workers Paid, US$5 a month |
| Database nears 500 MB, or point-in-time recovery is wanted | Supabase Pro, US$25 a month |
| More than 100 emails a day | Resend Pro, US$20 a month |
