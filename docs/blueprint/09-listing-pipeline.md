# 09. Listing pipeline

Owner: workstream F (`src/features/listing/`, `supabase/functions/photo-worker/`), integrations `vin`, `photos`, `llm` in `src/integrations/` (workstream A provides the interfaces and fakes; F writes the adapters).

The owner's requirement: a VA, field staff member, admin or car owner enters the plate or VIN and uploads photos; the details are drafted with AI (VIN decode plus generated headline, description and features); the photos are edited with AI to a consistent background; and the car is added to the website and database automatically after a review step. It must be smooth.

## 1. The pipeline at a glance

```
 capture            decode             draft              photos                 review            publish
 (person)           (vin module)       (llm module)       (photos module)        (person)          (system)
 plate or VIN  -->  year, make,   -->  headline,     -->  cut out, backdrop, --> approve or   -->  listing live,
 14 photos          model, specs       description,       shadow, variants,      edit              pages rebuilt,
                                       features, FAQ      alt text                                 sitemap updated
```

One person does the capture (about 6 minutes at the car). One person does the review (about 3 minutes at a desk). Everything between runs by itself in about 2 to 4 minutes.

## 2. Who can start it, and where

| Who | Route | Notes |
| --- | --- | --- |
| Field staff | `/field/list-a-car`, or a `photo_shoot` job in `/field/jobs/[id]` | The usual path: at the car, after detailing (procedure 17) |
| Fleet VA, admin | `/admin/vehicles/new`, or "Start listing" on `/admin/vehicles/[id]` | Photos can be uploaded from a computer |
| CS VA | Review and publish only | Procedure 17 step 5 |
| Owner | `/owner/vehicles/new` (as part of onboarding) or "Add listing photos" on an enrolled vehicle | An owner's submission always goes to staff review; the owner never publishes |

## 3. Step 1: identify the car

| Field | Type | Validation | Behaviour |
| --- | --- | --- | --- |
| Plate or VIN | one text field with a camera button | A 17-character value is treated as a VIN (check digit verified). Anything else is treated as a plate | **Plate:** looks up `vehicles` by `upper(plate)`. Found: the car's record loads ("2022 Toyota Corolla, grey, owner A. Singh") and the capture attaches to it. Not found: "We do not have this plate yet. Enter the VIN." There is no service that turns an Ontario plate into a VIN for a private business; vehicle records are released only to the Ministry's authorized requesters ([Ontario data catalogue](https://data2.ontario.ca/dataset/current-authorized-requesters)). **VIN:** looks up `vehicles` by `upper(vin)`. Found: attaches. Not found: decodes and creates a `listing_intakes` **[new]** row; an owner in the onboarding wizard gets a `vehicles` row instead because the owner is known |
| VIN scan | camera | Reads the door-frame barcode or printed VIN (`08-forms.md` section 5) | Fills the field |

### VIN decoding

| Item | Decision |
| --- | --- |
| Recommended provider | **NHTSA vPIC** `DecodeVinValues` endpoint. Free, no key, no monthly fee; batch decode of up to 50 VINs; traffic is rate-controlled automatically ([vPIC API](https://vpic.nhtsa.dot.gov/api/)) |
| Coverage in Canada | Canadian-market vehicles share manufacturer VIN submissions with the United States, so most decode correctly. One Canadian data vendor puts accuracy at "95%+" and notes vPIC misses Canadian-exclusive trims and equipment packages ([Cardog, Canadian vehicle data APIs](https://cardog.app/blog/canadian-vehicle-data-apis)). The reviewer therefore confirms trim and features, and every decoded field stays editable |
| Fallback | Manual entry (always available). Optional second adapter for VINs vPIC cannot resolve: Cardog, whose free tier is 50 credits a month at 2 credits per decode, about 25 decodes, with no card required; its paid plans are monthly subscriptions and are not used (same source) |
| Price | $0 per car |
| Fields kept | `ModelYear`, `Make`, `Model`, `Trim`, `Series`, `BodyClass`, `FuelTypePrimary`, `FuelTypeSecondary`, `ElectrificationLevel`, `DriveType`, `TransmissionStyle`, `Doors`, `Seats`, `EngineCylinders`, `DisplacementL`, `EngineHP`, `PlantCountry`, `ErrorCode` |
| Mapping | `fuel`: gasoline, diesel, hybrid (electrification level hybrid), plug_in_hybrid, electric (battery electric) -> `vehicles.fuel`. `seats`, `transmission` -> `vehicle_listings`. The rest -> `vehicle_listings.specs`. `class` is suggested from body class and make (a lookup table in `src/features/listing/class-rules.ts`) and confirmed by the reviewer because it sets the deposit |
| Cache | Raw responses stored in `vin_decodes` **[new]** (`vin, provider, raw jsonb, decoded_at`), so a VIN is decoded once |
| Failure | `ErrorCode` not 0, a timeout over 5 seconds, or year, make or model missing: the form shows the manual fields with "We could not read this VIN automatically. Enter the details from the ownership permit." The pipeline continues |

**Module interface** (`src/integrations/vin/index.ts`)

```ts
export interface VinDecoder {
  decode(vin: string): Promise<VinDecodeResult>;
}
export type VinDecodeResult =
  | { ok: true; provider: string; vehicle: DecodedVehicle; raw: unknown }
  | { ok: false; provider: string; reason: 'invalid_vin' | 'not_found' | 'incomplete' | 'unavailable'; raw?: unknown };
export interface DecodedVehicle {
  year: number; make: string; model: string; trim?: string;
  bodyClass?: string; fuel?: FuelType; drive?: string; transmission?: string;
  doors?: number; seats?: number; engine?: string;
}
```

Adapters: `vpic`, `cardog`, `fake` (tests). Chosen by `VIN_PROVIDER` with `VIN_FALLBACK_PROVIDER` optional.

## 4. Step 2: capture the photos

The fixed list from procedure 17, in order, with an on-screen outline for each (`PhotoSet`, `06-field.md` section 6 describes the capture behaviour).

| Seq | `vehicle_photos.angle` | Background replaced | Notes |
| --- | --- | --- | --- |
| 1 | `front_left` | Yes | The cover photo by default (three-quarter front) |
| 2 | `front` | Yes | |
| 3 | `left` | Yes | |
| 4 | `rear_left` | Yes | |
| 5 | `rear` | Yes | |
| 6 | `rear_right` | Yes | |
| 7 | `right` | Yes | |
| 8 | `front_right` | Yes | |
| 9 | `dashboard` | No | Colour and exposure normalized only |
| 10 | `front_seats` | No | |
| 11 | `rear_seats` | No | |
| 12 | `trunk` | No | |
| 13 | `wheel` | No | |
| 14 | `odometer` | No | Not published; stored for the record and to set `vehicles.odometer_km` |
| 15+ | `other` (optional, up to 6) | No | Sunroof, screen, charging port, third row |

Capture rules: daylight, landscape, the whole car in frame with space around it, no people, no other plates readable. In-browser checks: resolution at least 2000 px on the long side, blur, darkness, tilt (horizon within 5 degrees). The shooter can retake or keep. Photos are resized to 3000 px on the long side, re-encoded at quality 90 and uploaded directly to the `vehicle-originals` bucket at `vehicles/{vehicle_id}/original/{seq}-{angle}.jpg` (or under `intakes/{intake_id}/` before a vehicle exists). Each upload inserts `vehicle_photos (angle, original_path, status = 'uploaded', sort_order, uploaded_by)`.

Also captured on the last screen (optional, each pre-filled where known): odometer reading (typed; compared with the odometer photo by the reviewer), colour (select), number of keys, notes for the reviewer ("small scratch on rear bumper, already on the baseline report"). The same photo set and readings create the baseline Condition Report (`condition_reports (kind = 'baseline')`) so the car is not photographed twice.

Button "Submit for listing": `submitListingCapture` -> `app.submit_listing_capture()` **[new]**: checks the 13 published angles exist, creates the `listing_jobs` **[new]** row in `queued`, and calls the worker once immediately.

## 5. Steps 3 to 5: the automatic part

### 5.1 Queue and worker

| Item | Design |
| --- | --- |
| Queue table | `listing_jobs` **[new]**: `id, vehicle_id, intake_id, state, step_states jsonb, attempts, next_attempt_at, locked_at, error, cost_microusd, requested_by, created_at, finished_at`. One row per run. Per-photo work is tracked in the existing `photo_jobs` table, extended with `vehicle_photo_id`, `provider`, `next_attempt_at` and `cost_microusd` (one row per photo) |
| Worker | Supabase Edge Function `photo-worker`. Started two ways: directly by `submitListingCapture`, and every minute by `pg_cron` through `pg_net` as a sweep. Each call claims work with `select ... for update skip locked`, so two calls never take the same job |
| Budget per call | At most 4 photos per invocation, in parallel, then the function re-invokes itself if work remains. This keeps each run inside the Edge Function limits |
| Idempotency | Each photo step writes its output to a path derived from the photo id and the preset version. A repeated run overwrites the same object and the same row |
| Order | Decode (if not done), then the text draft and the photos in parallel, then alt text, then `needs_review` |

### 5.2 States

`listing_jobs.state`:

| State | Meaning | Next |
| --- | --- | --- |
| `capturing` | Photos are being uploaded (a draft exists) | `queued` on submit |
| `queued` | Waiting for the worker | `decoding` |
| `decoding` | VIN decode | `drafting` (or straight on with a `decode_failed` flag) |
| `drafting` | Text generation and photo processing running | `needs_review` when every step is `done` or `skipped` |
| `needs_review` | A person must look | `approved`, `changes_requested` |
| `changes_requested` | Sent back to the shooter for specific retakes | `queued` when the retakes arrive |
| `approved` | Review passed; publish preconditions being checked | `published`, `waiting` |
| `waiting` | Approved but a precondition is missing (not enrolled, no rate card) | `published` automatically when the last one is met |
| `published` | Live | end |
| `failed` | An unrecoverable error after retries | A person restarts or completes by hand |
| `cancelled` | Abandoned | end |

`photo_jobs.status` per photo: `queued`, `processing`, `succeeded`, `failed`, `cancelled` (existing). `vehicle_photos.status`: `uploaded`, `processing`, `processed`, `approved`, `rejected` (existing).

### 5.3 Text draft

Input to the `llm` module: the decoded facts, colour, class, the fleet's rate for context, the features the manufacturer data lists, and the house style rules. Output is structured (JSON schema enforced):

| Field | Rule | Stored |
| --- | --- | --- |
| `headline` | 40 to 70 characters; year, make, model and one true differentiator. No superlatives | `vehicle_listings.headline` |
| `description` | 120 to 220 words in two or three short paragraphs: what the car is like to drive and live with, who it suits, what is included. Facts only from the input. No claims about fuel economy, safety ratings or range unless present in the input | `vehicle_listings.description` |
| `features` | 8 to 14 items, each 2 to 5 words, only features supported by the decoded data or ticked by the shooter | `vehicle_listings.features` |
| `faq` | 4 questions and answers specific to this model (luggage capacity, child seats, charging for an EV, winter suitability), flagged "check" where the model is unsure | `vehicle_listings.faq` |
| `seo_title`, `seo_description` | From the patterns in `14-seo.md` section 5, filled in, within length | `vehicle_listings.seo_title`, `seo_description` |
| `slug` | `{year}-{make}-{model}-{trim?}-{colour}-{4-character id}` in lower case with hyphens; unique | `vehicle_listings.slug` |
| `alt_text` per photo | "2022 Toyota Corolla LE in grey, front left view" pattern, generated from facts and the angle, not by a vision model | `vehicle_photos.alt_text` **[new]** |

Controls so the copy does not read as machine-written: the prompt carries the style rules (plain Canadian English, short sentences, no em dashes, no filler) and three approved human-written examples; the output passes the copy lint before it is saved (banned characters and a banned-phrase list such as "look no further", "elevate", "seamless", "whether you are"); a draft that fails is regenerated once, then saved with a "needs rewrite" flag; and nothing is published without a person reading and approving it. The reviewer's edits are stored as examples for later prompts.

| Item | Decision |
| --- | --- |
| Provider | Any hosted text model with pay-per-token pricing and JSON output, behind the `llm` module. Launch adapter: Cloudflare Workers AI through its REST API, which includes 10,000 Neurons a day free on the Workers Free plan; a 120-billion-parameter open model is priced at US$0.35 per million input tokens and US$0.75 per million output tokens ([Workers AI pricing](https://developers.cloudflare.com/workers-ai/platform/pricing/)). A premium model from another provider can be swapped in by changing `LLM_PROVIDER` |
| Size of one draft | About 2,500 input tokens (facts, rules, examples) and 900 output tokens |
| Cost | About US$0.0016 per car at the prices above; within the free daily allowance at launch volume |
| Failure | Timeout 60 seconds; two retries. Then the review screen opens with empty text fields and the facts table, and the reviewer writes the copy. A failed draft never blocks publishing |

**Module interface** (`src/integrations/llm/index.ts`)

```ts
export interface TextGenerator {
  generate<T>(req: {
    task: 'listing_draft' | 'toll_notice_fields' | 'review_reply_suggestion';
    system: string; input: unknown; schema: JsonSchema; maxOutputTokens: number;
  }): Promise<{ ok: true; data: T; usage: { inputTokens: number; outputTokens: number; costMicroUsd: number } }
            | { ok: false; reason: 'timeout' | 'invalid_output' | 'quota' | 'unavailable' }>;
}
```

### 5.4 Photo editing to a consistent background

| Step | Detail |
| --- | --- |
| 1. Normalize | Auto-orient, crop to 3:2 (exteriors) or 4:3 (interiors) |
| 2. Cut out and re-background (the 8 exterior angles) | The car is separated from its surroundings and placed on the CarmaCars backdrop preset `brand_background_v1`: a light grey studio floor fading to white, the same horizon height in every photo, with a soft ground shadow under the car. The licence plate is covered with a plain CarmaCars plate graphic placed by the provider's mask or, failing that, flagged for the reviewer (plates must not be readable on the public site) |
| 3. Interiors | No background change. Exposure and white balance normalized |
| 4. Variants | Each published photo is rendered at 480, 800, 1200, 1600 and 2400 px wide in AVIF and WebP, plus one 1600 px JPEG, and written to the `vehicle-public` bucket as `vehicles/{vehicle_id}/{angle}-{width}.{ext}`. The file name of the JPEG follows `14-seo.md` section 8 |
| 5. Record | `vehicle_photos.processed_path` (the base path), `status = 'processed'`, width, height, `quality_flags` |

| Option (pay per use, no monthly fee) | What it does | Price | Notes |
| --- | --- | --- | --- |
| **Photoroom Image Editing API (Plus), recommended for the 8 exterior angles** | Background removal, background replacement, generated shadows in one call | US$0.10 per image; the Basic remove-background API is US$0.02 per image. 1,000 sandbox calls a month for testing with watermarks. The pricing page states no monthly subscription minimum for Basic or Plus ([Photoroom API pricing](https://www.photoroom.com/api/pricing)) | Best result for a car on a floor because of the shadow. Confirm at sign-up that billing is strictly per image; if a minimum monthly purchase applies, use the next option |
| **Cloudflare Images, recommended as the second adapter and for all resizing** | `segment=foreground` isolates the subject with the open BiRefNet model and returns a transparent image; the Images binding's `.draw()` composes it over our backdrop image; the same service produces the size and format variants ([transform options](https://developers.cloudflare.com/images/transform-images/transform-via-url/), [bindings](https://developers.cloudflare.com/images/transform-images/bindings/)) | 5,000 unique transformations a month free; on the free plan new transformations beyond that return an error rather than a charge; on the paid tier US$0.50 per 1,000 ([Images pricing](https://developers.cloudflare.com/images/pricing/)) | No generated shadow: the backdrop preset includes a neutral floor gradient and a pre-made soft shadow image placed under the car. Already inside the stack, no new account |
| remove.bg | Background removal | Not evaluated further | Its site states the standalone service is moving to Canva and will be unavailable from December 1, 2026 ([remove.bg pricing page](https://www.remove.bg/pricing)); not suitable for a new build |

**Decision.** `PHOTO_PROVIDER=photoroom` for the exterior cut-out and backdrop, `PHOTO_RESIZE_PROVIDER=cloudflare` for variants, and `PHOTO_FALLBACK_PROVIDER=cloudflare` used automatically when the first provider fails twice or is not configured. The backdrop and shadow assets are versioned in the repository under `src/features/listing/presets/`.

**Transformation budget on Cloudflare's free tier.** 13 published photos by 11 variants is 143 unique transformations per car. 5,000 a month covers about 34 new cars a month. Past that, the worker stops creating variants, the review screen shows "Image quota reached; variants will finish on the 1st", and the admin dashboard shows the choice: wait, or enable the paid tier at US$0.50 per 1,000.

**Module interface** (`src/integrations/photos/index.ts`)

```ts
export interface PhotoEditor {
  /** Cut the vehicle out and place it on a preset backdrop. */
  rebackground(req: { source: SignedUrl; preset: 'brand_background_v1'; aspect: '3:2'; coverPlate: boolean })
    : Promise<PhotoResult>;
  /** Exposure and white balance only. */
  normalize(req: { source: SignedUrl; aspect: '3:2' | '4:3' }): Promise<PhotoResult>;
}
export interface PhotoResizer {
  variants(req: { source: SignedUrl; widths: number[]; formats: ('avif' | 'webp' | 'jpeg')[] })
    : Promise<{ ok: true; files: { width: number; format: string; bytes: Uint8Array }[] } | PhotoFailure>;
}
export type PhotoResult =
  | { ok: true; provider: string; bytes: Uint8Array; width: number; height: number; costMicroUsd: number; flags: string[] }
  | PhotoFailure;
export type PhotoFailure = { ok: false; provider: string; reason: 'no_subject' | 'low_quality' | 'quota' | 'timeout' | 'unavailable'; retryable: boolean };
```

Adapters: `photoroom`, `cloudflare`, `passthrough` (publishes the cropped original; used by the "Use original" button), `fake`.

### 5.5 Failure handling

| Failure | Automatic response | What the person sees |
| --- | --- | --- |
| Provider timeout or 5xx | Retry after 1, 5 and 30 minutes (`photo_jobs.attempts`, `next_attempt_at`), then the fallback provider once | The photo tile shows "Retrying", then "Used fallback" |
| Provider says no subject found, or the cut-out covers under 15% or over 95% of the frame | No retry. `quality_flags` gets `bad_cutout` | Tile flagged red on the review screen with "Use original", "Retry", "Ask for a retake" |
| Quota reached | Job waits; `next_attempt_at` is the next quota reset | Banner with the reset date |
| Upload of a variant fails | Retry the write three times | Usually nothing |
| Text draft fails | Section 5.3 | Empty text fields |
| VIN decode fails | Section 3 | Manual fields |
| Worker crash mid-run | `locked_at` older than 10 minutes is released by the next sweep | Nothing |
| Four failed attempts on a photo | `photo_jobs.status = 'failed'`; the listing still reaches `needs_review` | The reviewer decides per photo |
| Whole job stuck over 30 minutes | A `fleet` task `listing_stuck` | Task in the queue |
| Cost guard | A daily ceiling in `program_settings.photo_daily_budget_microusd` **[new]** (default US$10). Past it, jobs queue until the next day and an admin is told | Banner |

Every provider call is logged in `provider_calls` **[new]** (`provider, purpose, entity, status, duration_ms, cost_microusd, created_at`), which feeds the cost line in the company report.

## 6. Step 6: the review screen (`/admin/listings` and `/admin/listings/[id]`; the same under `/va/cs` and `/va/fleet`)

List: vehicles with a job in `needs_review` or `changes_requested`, oldest first, with the cover photo, shooter, waiting time and flags (decode failed, photos flagged, needs rewrite, rates missing).

| Area | P layout | D layout |
| --- | --- | --- |
| Photos | A swipe strip; tap for before and after | Left 55%: a grid of all photos. Each tile has a before and after slider (original against processed), the angle label, flags, and buttons |
| Details | Sections stacked under the photos | Right 45%: the form, with the public car page preview in a tab |
| Actions | Fixed bar at the bottom | Fixed bar at the bottom of the right column |

**Per photo:** Approve (default for unflagged photos), Use original (`passthrough`), Retry processing, Reject (not published), Ask for a retake (adds the angle to the change request), Set as cover, drag to reorder, edit alt text.

**Details form**

| Label | Type | Validation | Pre-filled from | Stored |
| --- | --- | --- | --- | --- |
| Year, make, model, trim | text | Required except trim | Decode (edited values flagged) | `vehicles.year, make, model, trim` |
| Colour | select | Required | Capture | `vehicles.colour` |
| Fuel | select | Required | Decode | `vehicles.fuel` |
| Class | select: economy, standard, premium, suv, luxury, exotic | Required; changing it shows the deposit default that follows | Class rules | `vehicles.class` |
| Seats | number 2 to 9 | Required | Decode | `vehicle_listings.seats` |
| Transmission | select: automatic, manual | Required | Decode | `vehicle_listings.transmission` |
| Specifications (doors, drivetrain, body style, luggage, fuel economy or range) | fields | Optional | Decode | `vehicle_listings.specs` |
| Headline | text | 40 to 70 characters; copy lint | Draft | `vehicle_listings.headline` |
| Description | textarea with a word count | 120 to 220 words; copy lint; must differ from every other listing's description by a similarity check (under 60% shared 5-word sequences) | Draft | `vehicle_listings.description` |
| Features | chip editor | 6 to 14 | Draft | `vehicle_listings.features` |
| FAQ | repeatable question and answer | 3 to 8; "check" flags must be cleared | Draft | `vehicle_listings.faq` |
| Home area | select of published location pages | Required | Owner's city | `vehicle_listings.home_area` |
| Drivers aged 18 to 20 allowed | switch | Admin decides | Off | `vehicles.allows_18_to_20` |
| Slug | text | Unique; lower case, hyphens; locked after first publish | Draft | `vehicle_listings.slug` |
| Search title and description | text | Lengths per `14-seo.md` section 5 | Draft | `seo_title`, `seo_description` |
| Channels | checkboxes: website, classified sites, social pages | Website required to publish | Website | `vehicle_listings.channels` |
| Odometer | number | Matches the odometer photo (the reviewer confirms) | Capture | `vehicles.odometer_km` |

**Publish checklist** (read-only, shown above the buttons; each line green or red with a link to fix it):

| Check | Source |
| --- | --- |
| Vehicle is enrolled (T22 sent) or Turo-Only documents complete | `vehicles.status = 'ready_to_list'` or later |
| Rate card set | Current `rate_cards` row |
| Deposit set for the class | `rate_cards.deposit_cents` |
| At least 10 approved photos including all 8 exterior angles, and a cover | `vehicle_photos` |
| No readable plate in any approved photo | Reviewer tick |
| Copy passes the lint | Section 5.3 |
| Baseline Condition Report filed | `condition_reports (kind = 'baseline')` |
| Tracker reporting | `tracker_status` |

| Button | Action -> database | Result |
| --- | --- | --- |
| Save | `saveListingDraft` | Stays in `needs_review` |
| Request changes | `requestListingChanges` (angles to retake, note) | `changes_requested`; a field job or an owner notice with the list; emits `staff_field_job_assigned` or `owner_listing_changes_requested` |
| Approve and publish | `publishListing` -> `app.publish_listing()` **[new]** | See section 7 |
| Approve, publish later | Same with a date-time | `vehicle_listings.publish_at` **[new]**; a sweep publishes it |

## 7. Step 7: added to the website and database automatically

`app.publish_listing(p_vehicle, p_by)` in one transaction:

1. Verifies the publish checklist (raises the first failing line).
2. `vehicle_listings`: `status = 'published'`, `published_at`, `published_by`.
3. `vehicle_photos`: approved photos `status = 'approved'`, `approved_by`.
4. `vehicles.status`: `ready_to_list -> available` (an allowed transition) when it was `ready_to_list`.
5. `listing_jobs.state = 'published'`.
6. Writes the audit entries and completes the `list_vehicle` and `review_listing` tasks.

Then the server action, outside the transaction: `revalidateTag` for the car page, `/cars`, the category page, the home-area location pages and the sitemap; emits `owner_vehicle_listed` (with the public link) and `staff_vehicle_listed` (digest). The car is searchable on the site within seconds and in the sitemap at once.

If the checklist is not yet met (for example the vehicle is not enrolled), the job waits in `waiting` and publishes itself when `vehicle_onboardings.status` reaches `enrolled` and a rate card exists; the trigger that sets the Enrollment Date calls `app.publish_listing()` for a waiting job. This is what lets the photo shoot happen before the paperwork finishes.

**Unpublish, pause, re-shoot.** Pause (`status = 'paused'`): the page stays up with "Not taking requests right now". Unpublish (`unpublished`, with a reason and a redirect target): `14-seo.md` section 11. A re-shoot starts a new `listing_jobs` row; the live listing keeps its current photos until the new set is approved.

## 8. Cost per car

| Item | Units | Unit price | Cost (USD) |
| --- | --- | --- | --- |
| VIN decode (vPIC) | 1 | $0 | $0.00 |
| Exterior cut-out, backdrop and shadow (Photoroom Plus) | 8 | $0.10 | $0.80 |
| Interior normalization and all variants (Cloudflare Images) | 143 transformations | $0 within 5,000 a month; $0.0005 each beyond on the paid tier | $0.00 (or $0.07) |
| Text draft (Workers AI) | about 2,500 in, 900 out | $0.35 and $0.75 per million tokens | $0.002 (free within the daily allowance) |
| Allowance for retries and one re-shot angle | | | $0.20 |
| **Total** | | | **About US$1.00 per car**, about US$0.00 with the Cloudflare-only adapter |
| Storage (R2) | about 60 MB of originals and variants per car | First 10 GB free | $0.00 at launch volume |

No monthly fee is introduced by any item.

## 9. Database additions needed

| Addition | Purpose |
| --- | --- |
| `listing_jobs` (section 5.1) with staff policies | Pipeline runs |
| `listing_intakes (id, vin, plate, decoded jsonb, colour, odometer_km, notes, created_by, vehicle_id, created_at)` | A capture before the vehicle and owner exist |
| `photo_jobs`: `vehicle_photo_id`, `provider`, `next_attempt_at`, `cost_microusd` | Per-photo tracking and retries |
| `vehicle_photos`: `alt_text`, `width`, `height`, `quality_flags jsonb`, `preset_version`, `provider`; widen `angle` use to allow several `other` | Review screen and SEO |
| `vehicle_listings`: `specs jsonb`, `faq jsonb`, `home_area`, `seo_title`, `seo_description`, `publish_at`, `unpublished_reason`, `redirect_to`, `needs_rewrite boolean` | Sections 5.3, 6, 7 |
| `vin_decodes`, `provider_calls` | Cache and cost log |
| `app.submit_listing_capture(p jsonb)`, `app.publish_listing(p_vehicle uuid, p_by uuid)`; a call from `app.vehicle_onboarding_after_status()` to publish a waiting listing | Sections 4 and 7 |
| `program_settings.photo_daily_budget_microusd` | Cost guard |
| Policies: owners may insert `vehicle_photos` for their own vehicles through the server action only; field insert already exists for job vehicles | Section 2 |
| `pg_cron` schedule `carmacars-photo-sweep` every minute calling the `photo-worker` function through `pg_net` | Section 5.1 |
| Environment variables `VIN_PROVIDER`, `VIN_FALLBACK_PROVIDER`, `PHOTO_PROVIDER`, `PHOTO_RESIZE_PROVIDER`, `PHOTO_FALLBACK_PROVIDER`, `PHOTOROOM_API_KEY`, `CLOUDFLARE_IMAGES_*`, `LLM_PROVIDER`, `LLM_API_KEY` replace `PHOTO_PIPELINE_URL` and `PHOTO_PIPELINE_KEY` | Provider-neutral configuration |
