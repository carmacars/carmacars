# Integrations

One folder per outside service (docs/architecture.md section 4). Each has `types.ts` (the interface the
app may use), a real adapter, a fake adapter for local work and tests, and `index.ts`, which picks one from
the environment. Nothing outside these folders imports a provider's SDK or calls its API.

| Module | Real | Fake | Chosen by |
| --- | --- | --- | --- |
| payments | Stripe (pay per transaction; no Billing, no Invoicing) | in-memory ledger | `PAYMENTS_PROVIDER` |
| storage | Cloudflare R2 (S3 API, presigned links) | files under `public/_local` | `STORAGE_PROVIDER` |
| maps | Google Maps Platform: Places Autocomplete (New), Place Details, Routes | sample Toronto landmarks, straight-line distance | `MAPS_PROVIDER` |
| email | Resend (used by the `send-outbox` Edge Function; the app only writes the outbox) | records messages | `EMAIL_PROVIDER` |
| turnstile | Cloudflare Turnstile siteverify | accepts Cloudflare's documented test token only | `TURNSTILE_PROVIDER` |
