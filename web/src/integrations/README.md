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
| llm | Workers AI text model (listing copy) | writes a plain draft from the facts | `LLM_PROVIDER` |
| vision | Workers AI vision model through the Worker's AI binding: scanned toll notices, plate boxes (model and fallback in Program settings; the Llama 3.2 licence is accepted on first use) | a fixed parking notice and a plate box | `LLM_PROVIDER` (and the binding) |
| crm | GoHighLevel API v2 with each partner's Private Integration token from the vault (migration 0147) | an in-memory GoHighLevel (`src/features/partner-crm/fake-ghl.ts`) | `CRM_PROVIDER` (unset: real in production) |
| tracker | none yet: the vendor's documentation is needed. `none` answers every call (locate, immobilize request, mileage) with "not connected" | none | `tracker()` |
