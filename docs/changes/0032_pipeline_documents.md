# 0032: the listing worker, generated documents, signed file links, and the money gaps

Migration `supabase/migrations/0032_pipeline_documents.sql`, tests `supabase/tests/19_pipeline_documents.sql` (69 assertions). Builds on 0001 to 0031. No earlier migration was edited. Three functions are replaced with their behaviour kept and one branch added: `app.door` (0031: the calls `ops_read` and `ops_do`), `app.notification_recipients` (0018: the `insurer` audience) and `app.notification_catalogue_refresh` (0018: `invoice_url` is a sender value). `app.notification_payload` is wrapped as 0024 did (renamed `app.ntf_payload_0024`) for the `insurer_invoice` email.

## 1. The listing pipeline's worker (docs/blueprint/09-listing-pipeline.md section 5)

The queue, its states, back-off, budgets and publish rules are 0022's. What was missing was the worker and the screens.

| Piece | Where | Does |
| --- | --- | --- |
| Worker | `web/src/features/listing/worker.ts` (pure, every provider passed in), wired in `web/src/server/listing-worker.ts` | Claims due jobs (`public.server_listing_claim`), runs each, reports (`public.server_listing_result`). The copy and the photos of a car run side by side; reports go one at a time |
| Schedule | Cloudflare cron trigger on the site's Worker, every five minutes (`web/wrangler.jsonc` `triggers.crons`, `custom-worker.ts` `scheduled`), calling the protected route `POST /api/jobs/listing` (bearer: HMAC of a fixed label with `LINK_SIGNING_KEY`); and once right after a capture is submitted or a step is retried (`after()` in the server action) | Free plans: the cron counts as one request every five minutes; each run stops after about 25 seconds |
| `decode_vin` | NHTSA vPIC (`web/src/integrations/vin.ts`, free, no key) | An unreachable decoder is retried; any answer, even "not found", is final and the reviewer types the facts |
| `draft_copy` | Cloudflare Workers AI through the Worker's `AI` binding, `@cf/meta/llama-3.3-70b-instruct-fp8-fast` in JSON mode (`web/src/integrations/llm/`); prompt and checks in `web/src/features/listing/prompt.ts` (`listing-draft-v1`) | Headline, description, features, FAQ, SEO title and description, proposed classes. Plain Canadian English, no long dashes, CarmaCars only (never the numbered company), facts only from the decoded specs and the staff notes; a draft that breaks the rules is rewritten once with the problems listed, then stored as it is (the database flags it `needs_rewrite`). Stored with model and prompt version (0022's `app.store_listing_draft`); classes through 0025's `app.propose_listing_classes` |
| `process_photo` | Cloudflare Images transformations from the Worker (`web/src/integrations/photos/cloudflare.ts`): `segment=foreground` gives the car as a PNG, then `draw` places the soft shadow and the car on the studio backdrop `brand_background_v1` (1800 x 1200 JPEG). Interiors are normalized (1600 x 1200). The cut-out stays private (`vehicle-originals`), the result is public (`vehicle-public`) under an SEO file name | **Fallback** when transformations are not enabled on the zone (the answer is not the PNG or JPEG asked for, or an error page): the original is kept on the site as it was taken, `background_status = original_used` and the flag `background_not_replaced`, and the review screen shows it for staff. No car found in the frame: the flag `bad_cutout`. A provider outage (5xx, timeout) is retried |
| `resize` | Same service: 480, 800 and 1200 px WebP next to the master (the site's `srcset`) | Without transformations the master stands alone |
| `publish` | Only through `app.publish_listing` (0022), after review where the starter's role needs one | |
| Presets | `web/src/features/listing/presets/` (built by `web/scripts/gen-backdrop.mjs`), uploaded to the public bucket under `site/backdrop/` by the deploy | |

**Budgets and cost.** `provider_calls` gains `units` and `unit` (`neurons`, `transformations`, `requests`). New settings: `listing_ai_daily_neurons` (default 9,000 of the free 10,000 a day; past it copy drafts wait for the next Toronto day) and `images_free_monthly_transformations` (5,000). Photo work still stops at 0022's `photo_daily_budget_microusd`. Cost is recorded at the paid rate only above the free allowances (US$0.011 per 1,000 neurons; US$0.50 per 1,000 transformations), so `app.listing_cost_report` and the company report show real spending.

**Ordering.** A copy draft waits while its VIN decode is open, so it is written from the decoded facts (`app.worker_claim_listing_jobs`, which otherwise claims as 0022's `app.claim_listing_jobs` does). Reports lock the intake first, which removes the deadlock two photos of one car finishing together caused in 0022's `app.complete_listing_job`.

**Screens.** Capture (`ListingCapture`: the shot list, a photo per shot from the camera or a file, re-encoded in the browser to 3000 px JPEG, `POST /api/listing/upload` into `vehicle-originals`, then "Submit for listing"), progress (`ListingProgress`: steps done, running, waiting and failed, flags, cost, and a Retry for each failure, reading again every 4 seconds while work runs) on `/admin/listings/[id]`, `/va/listings/[id]` and the owner's `/owner/vehicles/[id]` ("Add listing photos"); a progress column on `/admin/listings` and `/va/listings`.

| Function | Does |
| --- | --- |
| `app.listing_budget` | Today's photo spending, neurons, this month's transformations, against the limits |
| `app.listing_job_context` | What the worker needs for one job: the VIN (decode only), the facts and staff notes and copy rules and class list (draft only), the photo with its file name (photo jobs). Never a plate or an owner |
| `app.worker_claim_listing_jobs`, `app.worker_listing_result` | The worker's side (service role wrappers `public.server_listing_claim`, `server_listing_result`, `server_listing_budget`) |
| `app.retry_listing_job` | A failed step back to the queue with fresh attempts (a failed intake as a whole through 0022's `app.retry_listing_intake`); a waiting step made due now. An Admin, Fleet or customer service, or the person who started it |
| `app.listing_progress`, `app.listing_capture` | The screens' reads |

## 2. Generated documents and signed links

`generated_documents (kind, entity_key, document_id, sha256)` with row-level security, an admin policy and an audit trigger; `document_kind` gains `insurer_invoice`.

| Kind | Record (`entity_key`) | Final (rendered once and stored) | Who may download (`app.file_access`) |
| --- | --- | --- | --- |
| `owner_statement` | `owner_statements.id` | approved or paid | Finance, Admins; the owner when approved or paid |
| `renter_statement` | `booking_statements.id` | always | Finance, Admins; the renter of the booking |
| `receipt` | `payments.id` (a succeeded charge or capture) | always | Finance, Admins; the renter or owner who paid |
| `insurer_invoice` | `insurer_invoices.id` | once sent | Finance, Admins |
| `investor_statement` | `investment_returns.id` | always | Admins; the investor |
| `investor_year` | `<investor id>:<year>` | a past year | Admins; the investor |

`app.pdf_facts` gives everything a document prints (the legal name and HST number of CarmaCars are printed: these are invoices and statements); the web app lays it out with the agreements' pdf-lib renderer and the CarmaCars wordmark on every page (`web/src/features/documents/pdf.ts`), stores a final one in the private `documents` bucket and records it (`app.file_record`, which also fills the record's own document column). Routes: `/files/<kind>/<record>` for a signed-in person (portals and admin screens), `/d/<token>` for an email link, `/admin/documents/<id>` for any stored file.

**7-day links in emails.** The `send-outbox` Edge Function now gets `LINK_SIGNING_KEY` (set by the deploy from the vault's `deploy_link_signing_key`) and, for each email, `app.outbox_file_refs` says which record each link opens: `receipt_url` (renter receipt), `statement_url` (investor statement and return paid), `invoice_url` (insurer invoice), `signed_agreement_url` (the signed rental agreement), `supporting_document_url` (the toll or ticket notice, the later-charge statement). The token has the site's `signToken` form (purpose `doc`, 7 days). An expired or altered link answers 410 with a page that points to sign-in. Without a record yet, the link still goes to the portal behind sign-in, as before.

## 3. Money gaps

| Gap | Built |
| --- | --- |
| Issue an approved refund | `app.refund_issue_begin` (Finance or an Admin; approved, processing or failed; a card payment with processor ids; never more than what is left of the payment; marks it processing and gives the key `refund:<id>`), the payments module's new `refund()` (Stripe `POST /v1/refunds` with that idempotency key; the fake ledger in tests), `app.refund_issue_finish` (one refund transaction per refund, found again by the processor's id; refusal recorded as failed with the reason, issuable again with the same key). Button "Issue the refund" on `/admin/money?tab=refunds` and on the Finance board `/va/money` |
| Guided Deposit settlement | `app.deposit_preview` (what is owed, what the Deposit covers, the most that may be held back and until when); `DepositSettle` replaces the typed JSON on the admin and Finance booking pages; the settlement itself is 0020's `app.settle_deposit` (its approval rule for releases above the person's limit is unchanged) |
| Document on a single toll or ticket | `/admin/tolls/new` takes the notice (PDF, JPEG or PNG) and logs it with `document_id` (0021 already kept it); a notice logged without one can be attached on `/admin/tolls/[id]` (`ops_do toll_document`, notice documents only) |
| Insurer invoice email | Catalogue entry and template `emails/src/emails/insurer_invoice.mjs` (audience `insurer`: the insurer's billing contact; from and reply-to `billing@`), `app.send_insurer_invoice_email` (a draft is sent first; each send is one event; no billing email, no send), "Send by email" and "Email again" on `/admin/insurer-invoices`, plus a PDF link |

## 4. Maps

`web/src/integrations/maps/google.ts`: Places API (New) autocomplete and place details with one session token, Routes API driving distance from the company origin for the delivery fee; failures read as "not known" (no suggestions, no distance), never a made-up value. `MAPS_PROVIDER=google` with a key, otherwise the fake. The deploy reads `deploy_google_maps_api_key` from the vault: present, it sets the Worker secret `GOOGLE_MAPS_API_KEY` and `MAPS_PROVIDER=google`; absent, the fake. Unit tests with a mocked fetch: `google.test.ts`.

## 5. Deploy

- `web/wrangler.jsonc`: `ai` binding, `triggers.crons` (`*/5 * * * *`; none on staging), `NEXT_PUBLIC_APP_URL` var.
- `.env.production`: `LLM_PROVIDER=workers-ai`, `PHOTO_PROVIDER=cloudflare`, `MAPS_PROVIDER` from the vault step.
- `scripts/deploy/cloudflare.sh images`: turns image transformations on for the zone when the token may (Zone Settings edit); otherwise a warning, and the fallback above applies.
- `scripts/deploy/*.sh photos`: the two presets uploaded every deploy.
- `scripts/deploy/supabase.sh outbox`: `LINK_SIGNING_KEY` among the Edge Function secrets.
- CI: `npm run test:unit` in the web job.

## 6. Emails folder rules

`emails/build.mjs` and `emails/check.mjs` accept the audience `insurer` (the reply-to rule is unchanged: sent from billing, so replies go to `billing@`); `emails/src/layout.mjs` gives it its own footer reason. 124 emails, all 15 checks pass.

## 7. Existing test assertions changed

`supabase/tests/07_notifications.sql`: the catalogue count (123 to 124 emails) and the list of sender-supplied variables (adds `invoice_url`) are written into two assertions; both now include the new email. One insurer invoice email is sent in 07's completeness block so "every wired email code has been built" still holds. No other assertion changed.

## 8. Decisions

1. The worker runs in the site's Worker, not an Edge Function: Workers AI and image transformations are Worker bindings and features, and the cron trigger is free.
2. The blueprint's Photoroom adapter is not built: the owner's requirement is met inside the existing Cloudflare account at no monthly fee; `PhotoProcessor` takes another adapter without other changes.
3. A renter's statement or receipt and an insurer invoice are not tied to the booking in `documents` (they are listed from their records), so a renter never lists the insurer's invoice and a stored copy is not listed twice.
4. Only Admins (not Finance) download investor documents, as the investor area of 0031 allows.
5. `supabase/seed/0018_catalogue.sql` was not regenerated: the new catalogue row is in this migration, and `0018_gen_catalogue.mjs --check` (not run in CI) reports it as new.

## 9. Not done

- Field staff do not yet have the capture screen on a photo shoot job (`/field`); owners, Fleet and Admins capture. The worker and the database already accept a field staff member of the car's job.
- The licence plate is not covered by a graphic; the reviewer checks plates (09 section 5.4 step 2).
- The month-open, payouts and owner-billing job functions of 11 section 1 that would email statements with PDFs on their dates are not built; the emails that exist now carry signed links.
