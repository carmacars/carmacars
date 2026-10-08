# 0022: owners, forms and listings

Migration `supabase/migrations/0022_owners_forms_listings.sql`, tests `supabase/tests/11_owners_forms_listings.sql` (200 assertions). Builds on migrations 0001 to 0017, 0019 and 0020; it does not need 0018 (notifications) or 0021 (tolls and statements). No earlier migration, shared document, email, prototype or blueprint file was edited, and no existing test assertion was changed.

The migration was started against an older base without 0019 and 0020 and finished here. What changed in the earlier part to fit 0019 and 0020:

| Earlier draft | Now |
| --- | --- |
| Defined `app.user_va_has` and `app.user_is_field` | Removed: 0019 and 0020 define them |
| Inserted tasks straight into `tasks` (`owner_application`, `owner_lead`, `enquiry`, `onboarding_disclosure`, `approve_vehicle_terms`) with due times typed in the code | Every task goes through 0020's `app.raise_task` with a dedupe key; seven rows added to 0020's `task_rules` (queue, priority, due time editable). The application-level task was dropped: 0020's trigger already raises one `owner_intake` task per vehicle onboarding row |
| `app.submit_lead(p)` assumed the server rate-limited | `app.submit_lead(p, p_ip)` calls 0019's `app.rate_limit` with `program_settings.lead_hourly_limit`; over the limit it returns `{ok: false, error: 'rate_limited'}` |
| The six ownership situations were a `values` list inside `app.onboarding_options` | Table `onboarding_situations`, editable by an Admin |
| "30 days' notice" and "7 days" written in messages and the purge | `fee_change_notice_days` and `form_submitted_keep_days` settings |

## 1. Site settings and editable content (part A of the brief)

`site_settings` is one row (a `singleton` column that can only be true). It covers every field of `prototype/tools/src/site.mjs` and the "Admin-editable content" table of `prototype/DESIGN.md`: brand name, site address, tagline, logo file keys for light and dark backgrounds with size and alt text, the text wordmark used when no logo is set, favicon, sharing image, city, region, service area, delivery area text and `delivery_areas` (`[{"area", "fee_cents"}]`, the fee optional), airport delivery (true, false or not decided), phone, WhatsApp, 24-hour line, public and owner emails, mailing address, street address with a `show_street_address` switch (service-area business by default), opening hours text, handover time slots, social links, review source, reply wording and SEO defaults. A trigger checks the delivery areas and the `HH:MM` slots and records who edited.

The legal company name stays where it already was, `program_settings.company_legal_name`, because invoices and registry forms print it. `site_settings.legal_name_displayed` can only be false (check constraint). `app.public_site_settings()` returns the public fields only (plus `program_settings.opening_hours` and the HST number once set); a test proves the payload contains neither the numbered corporation nor "Canada Inc", nor who edited.

`site_content_blocks (block_key, page, kind, body, data, sort_order, is_published, updated_by)` holds headings, paragraphs and FAQs; `app.public_site_content(page)` returns the published blocks. Version history is the audit log: every insert and update of both tables is in `audit_log` with the row before and after (tested).

## 2. Forms (part B)

`form_drafts` and its functions were in the earlier draft and are kept: `app.save_form_draft`, `app.load_form_draft`, `app.request_draft_resume_link` (returns a one-time token for the server to email; only its hash is stored), `app.resume_form_draft` (a visitor's new device gets its own token and the first keeps working; a signed-in user takes the draft into the account), `app.submit_form_draft` (a second press returns the first result), `app.purge_form_drafts`. Bank, licence, card and social insurance numbers are removed from every draft on write, at any depth. Expiry and resume-link lifetimes are settings. Drafts are audited without their values (trigger `audit_form_drafts` with `redact`).

`leads (kind, contact fields, payload, source, source_url, referrer, UTM fields, consent with its wording and time, status, assigned_to, owner_id)`. An owner program enquiry goes to the sales assistant with the fewest open leads and raises `owner_lead`; anything else raises `enquiry` for customer service.

## 3. Owner onboarding (part C)

- **Owner record.** `owners` gains first, middle and last name, signing officer name and title, and a mailing address. The driver's licence number, its province and the date of birth go in `owner_private_details` (the owner and an Admin only; audited without values), because row-level security on `owners` cannot hide columns from the three assistant roles that read it.
- **One application, many vehicles.** `app.submit_owner_application(p, p_by)` creates or completes the owner (`app.save_application_owner`), writes `owner_applications`, and adds each vehicle with `app.add_owner_vehicle`: VIN (cleaned and checked), plate, year, make, model, trim, colour, odometer, body type, fuel, registration status, who holds it, owned outright, financed or leased, lender or lease company and account, permission, management mode, disclosures, new corporation details. Values typed by a person win over a cached VIN decode, and `vehicles.spec_sources` records which is which. A branded title declines that vehicle only; a disclosed recall or damage raises an Admin task.
- **Situation, forms, estimate.** `app.onboarding_options(held_by, title_status, mode)` reads `onboarding_situations` joined to `onboarding_method_info`: S1 to S6 and Turo-Only, the registry forms (the method's list, or none for the sign-back on the permit of a Transfer that is not leased, as operating procedure 12 says), the CarmaCars forms (A, B, D, plus C when financed or leased), the Owner's Lien option, and the estimate the owner pays third parties directly. `app.onboarding_plan` refuses a method that is not open. Each vehicle onboarding row keeps the situation, forms, sign-back flag and estimate.
- **Terms.** `app.standard_terms` reads `owner_fee_grid` for the owner's vehicle count and the Install Fee from settings. `app.set_vehicle_terms` takes the grid by default; anything off the grid entered by an assistant waits for `app.approve_vehicle_terms` (Admin). `app.apply_vehicle_terms` writes the Enrollment Agreement (one per owner), the Title-Holding Agreement (not for Turo-Only) and the Vehicle Schedule row (an Additional Vehicle Schedule once the Enrollment Agreement is signed).
- **Upfront invoice.** `app.issue_upfront_invoices(owner)` issues, per vehicle whose documents are signed, the existing `app.issue_upfront_invoice` (Install Fee and first and last month's Insurance Fee with HST); never registry costs, never for Turo-Only or shareholder-owned vehicles. 0020's trigger raises the Finance `collect_upfront` task.
- **Checklist.** `onboarding_checklist_items` (label, order, who it waits on, owner and staff wording, editable) and `app.onboarding_checklist(vehicle)`: owner details, ownership permit, registry forms, agreements signed, upfront payment, registry visit, Tracker, insurer confirmation, listing photos, listing; each with status (done, open, not applicable), who it waits on now and the next action, worked out from the records. `app.mark_onboarding_item` lets staff mark an item by hand (`vehicle_onboardings.checklist_marks`).
- **Exit.** `app.give_exit_notice(vehicle, by, p)`: notice period `notice_period_days`; the Exit Date is the end of notice or, if later, the end of a confirmed or on-rent booking running then; months on the fleet policy and `calc_retransfer_payer` with `free_retransfer_months` decide who pays the transfer-back fees; re-transfer due after `retransfer_business_days`; vehicle `exit_notice`, an open-ended `exit` block. `app.withdraw_exit_notice` before the Exit Date. `app.complete_exit` (Fleet or Admin, on or after the Exit Date) records the hand-back facts, moves the vehicle to `exited` and takes its listing off the website with its redirect.
- **Fee change.** `app.give_fee_change_notice` (Admin): at least `fee_change_notice_days` after the notice date, Revenue Share unchanged, the current `vehicle_fee_history` row closed and a `fee_notice` row opened. A Revenue Share change is `app.propose_schedule_change` then `app.record_schedule_change_signed`: a new signed Vehicle Schedule supersedes the old one and opens its fee history row. Both are recorded in `vehicle_term_changes`.
- **Bank and payment method change.** `app.submit_payout_account` (owner or Admin): stored not current and not verified, an Admin task `verify_payout_account`, the security notice. `app.verify_payout_account` (Admin, with how it was verified) makes it current. `app.record_owner_payment_method` (server, after the processor confirms) records a debit authorization or card and its processor ids. `owner_payout_accounts` gains `account_key_version`.
- **Owner portal.** `app.owner_portal_vehicles` (status, mode, fees, listing, the next checklist action and the whole checklist), `app.owner_portal_bookings` (renter name and mobile only on a Self-Managed rental or an Owner Booking; requests and offers not listed), `app.owner_portal_money` (issued invoices, approved or paid statements, payouts), `app.owner_portal_documents` (nothing tied to a renter, booking, incident, claim or investor; Condition Reports only baseline and exit). `app.owner_book_own_vehicle` books the owner's own car through 0016's `app.request_booking` with `booking_type = 'owner'`, making the owner's renter record (`is_owner_account`) the first time.

## 4. Government form pre-fill (part D)

`pdf_templates (form_code, version, kind, file_key, field_map, verified, ...)` with one current version per form; `government_form_fields` (the data sheet rows: label, source path, transform, required, condition); `government_form_fills (form, vehicle, owner, mode pdf or data_sheet, field_values, data_sheet, missing, status draft, ready, printed, signed, filed, file_key, who and when for each step)`. `app.registry_context(vehicle)` gathers owner, private details, corporation, vehicle, method, lender and CarmaCars (legal name, operating name, RIN, address and signing officer from `program_settings`; correct on a government form, never public). `app.fill_government_form` resolves every mapped PDF field and every data sheet row; a required empty value keeps the fill a draft and is named. An unverified template still produces the complete data sheet. `app.fill_vehicle_government_forms` fills every form the situation needs; `app.set_government_form_status` moves printed, signed (owner or staff), filed (staff). The five forms are seeded unverified; SR-LV-006 carries the blueprint's example keys.

## 5. Listing pipeline (part E)

| Object | What it holds |
| --- | --- |
| `listing_shot_types` | The shot list (code, label, order, required, public, background replaced, cover, how many allowed, guide). 15 rows from procedure 17: 8 exteriors on the backdrop, 5 interiors, the odometer (kept, never public), up to 6 optional extras. Editable |
| `listing_intakes` | One open per vehicle. Started by owner, field, va or admin; states `started`, `decoding`, `photos_uploaded`, `drafting`, `processing_photos`, `needs_review`, `approved`, `published`, `failed` (plus `cancelled`); reason, retries, review required, decode and draft failure flags |
| `vin_decodes` | Each decode (raw and mapped fields), so a VIN is decoded once |
| `listing_jobs` | The queue: `decode_vin`, `draft_copy`, `process_photo`, `resize`, `publish`; attempts, max attempts, next attempt, lock, provider, cost in micro-dollars, input and output |
| `provider_calls` | Every provider call with its cost; `app.listing_cost_report` gives the cost per car (Admin, Finance) |
| `listing_drafts` | Each copy draft (AI or person) with model, prompt version, lint problems and the rewrite flag |
| `photo_jobs` + | `vehicle_photo_id`, `intake_id`, `provider`, `next_attempt_at`, `cost_microusd` |
| `vehicle_photos` + | `intake_id`, `shot_type`, `alt_text`, `width`, `height`, `byte_size`, `mime_type`, `variants`, `background_status`, `is_public`, `approved_at`, `replaced_at`, `quality_flags`, `provider`, `preset_version` |

Functions: `app.start_listing_intake` (by vehicle id, VIN or plate; an owner only for their own car, field staff only for a car of their assigned job, Fleet or an Admin any car; customer service reviews only), `app.record_listing_upload` (a second photo of a single shot replaces the first; returns what is missing), `app.submit_listing_intake`, `app.enqueue_listing_job`, `app.claim_listing_jobs` (skip locked; stale locks claimed again; photo work paused for the day once `photo_daily_budget_microusd` is spent), `app.complete_listing_job`, `app.fail_listing_job` (back-off from `listing_job_backoff_minutes` up to `listing_job_max_attempts`; a failed decode or draft does not stop the listing, a failed photo step does until `app.retry_listing_intake`), `app.apply_vin_decode` (never overwrites a value a person entered or confirmed), `app.confirm_vehicle_specs`, `app.store_listing_draft` (fills only empty copy), `app.advance_listing_intake`, `app.review_listing` (approve, with edits and photo decisions, or send back with a note), `app.publish_listing`, `app.unlist_listing`.

**Who needs a review:** `program_settings.listing_review_required_roles`, default owner and field staff. A role on that list publishes only through an approved intake; an Admin or assistant publishes directly (an intake they start publishes itself when the worker finishes, if every requirement is met).

**`app.publish_listing(vehicle, by)` refuses, naming the first missing item:** vehicle not enrolled (status), Turo-Only, no current rates, specifications missing (year, make, model, colour, fuel, body style, seats, transmission), photos (every required public shot processed and approved, at least `listing_min_photos` public, a cover), copy (lengths, feature and FAQ counts, banned phrases from settings, no long dash, no FAQ still marked "check"), a canonical twin that is not live. Then it sets a stable unique slug if none (`year-make-model-trim-colour-` and four characters of the vehicle id, more if needed, never one another car used), publishes, makes approved photos public, moves `ready_to_list` to `available`, closes the listing tasks and tells the owner.

## 6. Website and SEO data (part F)

`vehicle_listings` gains `specs`, `body_style`, `drivetrain`, `doors`, `luggage`, `faq`, `home_area`, `seo_title`, `seo_description`, `staff_note`, `is_featured`, `canonical_vehicle_id`, `publish_at`, `first_published_at`, `unpublished_at`, `unpublished_reason`, `redirect_to`, `needs_rewrite`, `spec_sources`, `draft_id`, `content_updated_at`. A trigger locks the slug once first published and moves `content_updated_at` (the sitemap's lastmod) only when public content changes. Year, make, model, trim, colour and fuel stay on `vehicles`.

`listing_redirects (from_path, to_path, status_code 301 or 410, reason, vehicle_id)`. `app.unlist_listing` follows `docs/blueprint/14-seo.md` section 11: the remaining twin becomes canonical and receives a 301; otherwise a 301 to the model hub while a car of the model is live; otherwise 410. Older redirects to the address follow (single hop), and when a hub loses its last car the redirects sent there become 410. Publishing again removes the car's own redirect and reuses its slug.

Anonymous reads (app functions, wrapped in `public` for the API as invoker functions): `site_settings_public`, `site_content(page)`, `car_page(slug)` (listing, rates, photos, FAQ, canonical path, indexable flag, `vehicle_id`; or `{redirect, status_code}`), `fleet(filters)` (rows only, no totals), `model_hubs()`, `model_hub(hub)`, `vehicle_photos_public(slug)`, `sitemap_rows()` (canonical car pages and hubs with lastmod), `resolve_path(path)`. None returns a VIN, plate, fleet number, owner, original photo path, cost, draft or private field (tested over all of them). Availability and prices for dates are left to 0019's `public_vehicle_calendar`, `quote_booking` and `search_available`, which the page calls with the `vehicle_id` the car page gives; nothing of theirs is duplicated. `04_rls.sql` still passes unchanged: the anonymous role still selects from one view only.

## 7. Permissions on the new tables

| Table | Admin | VA Finance | VA Fleet | VA CS | VA Sales | Field | Owner | Renter | Anonymous |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `site_settings` | RW | R | R | R | R | R | none | none | none (function) |
| `site_content_blocks` | RW | R | R | R | R | none | none | none | none (function) |
| `form_drafts` | R | own | own | own | own | own | own | own | none |
| `leads` | RW | none | none | R W, not owner enquiries | R W | none | none | none | none |
| `owner_private_details` | R | none | none | none | none | none | own, R | none | none |
| `owner_applications` | R | R | R | R | none | none | own, R | none | none |
| `onboarding_situations`, `onboarding_checklist_items`, `listing_shot_types` | RW | R | R | R | R | R | R | R | none |
| `vin_decodes` | R | none | R | R | none | none | none | none | none |
| `pdf_templates`, `government_form_fields` | RW | none | R | R | none | none | none | none | none |
| `government_form_fills` | R | R | R | R | none | none | own, R | none | none |
| `vehicle_term_changes` | R | R | R | R | none | none | own vehicles, R | none | none |
| `listing_redirects` | RW | none | R | R | none | none | none | none | none (function) |
| `listing_intakes` | R | none | R | R | none | started by them, R | own vehicles, R | none | none |
| `listing_drafts`, `listing_jobs` | R | none | R | R | none | none | none | none | none |
| `provider_calls` | R | R | R | none | none | none | none | none | none |

"RW" for an Admin means the portal may insert and update (privilege granted, policy `admin_all`); "R" for an Admin means the server's functions write and the browser only reads. No browser session deletes. Every new table has row-level security, `admin_all` and an audit trigger.

Functions: every function of this migration is revoked from public, anon and authenticated and granted to `service_role`. Opened to anon and authenticated: the public reads above and the helpers they use (`slugify`, `model_hub_path`, `public_listing_row`, `public_listing_photos`). Opened to authenticated: `onboarding_options`, `clean_vin`. `public.submit_lead` is for the server only (as 0019's `submit_booking_request`).

## 8. Event codes emitted

All with dedupe keys `code:entity_id:discriminator`, all present in `emails/catalogue.json`:

| Code | Entity | When | Discriminator |
| --- | --- | --- | --- |
| `owner_application_received` | `lead`, `vehicle_onboarding` | Owner program enquiry; each vehicle added (not for a declined one) | `lead`, `intake` |
| `staff_owner_application_received` | `lead`, `vehicle_onboarding` | Same | `lead`, `intake` |
| `staff_listing_ready_for_review` | `listing_intake` | The intake reaches `needs_review` | retry count |
| `owner_vehicle_listed` | `vehicle` | `app.publish_listing` | intake id (or time) |
| `owner_exit_notice_received`, `staff_exit_notice_received` | `vehicle_exit` | `app.give_exit_notice` | `notice` |
| `owner_exit_completed` | `vehicle_exit` | `app.complete_exit` | `completed` |
| `owner_fee_change_notice` | `vehicle_term_change` | `app.give_fee_change_notice` | `notice` |
| `owner_bank_details_changed` | `owner` | Payout details submitted, verified; payment method recorded | account or method id and `submitted`, `verified`, `payment_method` |

Not emitted here: `owner_upfront_invoice` and `owner_payment_received` (owner invoice status, 0018), `owner_agreement_ready` and `owner_agreement_signed` (document flow), `owner_vehicle_enrolled`, `owner_registry_visit`, `owner_onboarding_steps` (onboarding status, 0018). The catalogue has no `staff_vehicle_listed` or `owner_listing_changes_requested`, so none is emitted.

## 9. Task rules added (0020's `task_rules`, editable)

`owner_lead` (sales), `enquiry` (cs), `onboarding_disclosure`, `approve_vehicle_terms`, `verify_payout_account` (admin), `review_listing` (cs), `listing_failed` (fleet); all due in 1 business day; inserted with `on conflict do nothing`.

## 10. Settings added (`program_settings`)

`company_rin`, `signing_officer_name`, `signing_officer_title`, `listing_review_required_roles`, `listing_min_photos`, `listing_job_max_attempts`, `listing_job_backoff_minutes`, `listing_job_lock_minutes`, `photo_daily_budget_microusd`, `listing_default_home_area`, `listing_headline_chars`, `listing_description_words`, `listing_features_count`, `listing_faq_count`, `listing_banned_phrases`, `form_draft_days`, `form_resume_link_hours`, `form_submitted_keep_days`, `lead_hourly_limit`, `fee_change_notice_days`.

## 11. Values still not editable by an Admin, and why

| Literal | Where | Why |
| --- | --- | --- |
| 30 days as the floor of a Fee notice | `vehicle_fee_history` check (0002); `fee_change_notice_days` check `>= 30` | The setting can lengthen the notice; shortening it needs 0002's check changed |
| 36 hours before and 24 hours after a field job | `app.user_field_has_job` | Mirrors 0012's `app.field_has_job` window, so the server and the policies agree |
| 1 hour window of the lead limit | `app.submit_lead` | The count per window is a setting; the window is part of the rule (as 0019) |
| Checklist item codes | `onboarding_checklist_items.code` check | Each code says how the item is read from the records; labels, wording, order and who it waits on are editable |
| Statuses that may publish or take notice | `app.publish_listing`, `app.give_exit_notice` | They follow the vehicle status model of 0011 |
| URL scheme `/cars/`, `/rent/` | slugs, redirects, sitemap | The URL contract of `docs/blueprint/14-seo.md` section 2 |
| Slug pattern and the 4-character id | `app.listing_slug` | A stable address must not change with settings |
| Photo presets `brand_background_v1`, `normalize_v1` | `app.enqueue_listing_job` | Names of versioned presets in the repository, not business values |
| Alt text pattern | `app.photo_alt_text` | A sentence built from the car's facts; a reviewer can reword any photo |
| Number formats (VIN, institution 3 digits, transit 5 digits, postal code, phone) | validation and transforms | Formats of the outside world |
| Keys removed from drafts (account, licence, card numbers, CVV, SIN) | `app.strip_transient` | A security rule, not a business value |
| `ON` as the default licence province | `owner_private_details` | Default only; the form sends the province |
| Seed rows (site settings from `site.mjs`, situations, checklist, shot list, five templates, data sheet rows, task rules) | data | Starting values an Admin edits |

## 12. Assumptions and decisions to confirm

1. A listing always belongs to a vehicle already in `vehicles` (found by id, VIN or plate). A car with no owner record is first added through the owner application; the blueprint's capture "before the vehicle and owner exist" is not built.
2. A failed decode or copy draft never stops a listing (the reviewer types the facts or the copy); a photo step that fails for good puts the intake in `failed` until someone retries. The blueprint lets a listing reach review with a failed photo; the brief asks for the failed state and the retry, which is what is built.
3. Sending a listing back for changes returns the intake to `started` with the note in `reason` (the brief's states have no `changes_requested`).
4. An intake started by a role that needs no review publishes itself when the worker finishes and everything is met; otherwise it stays `approved` with the reason, and any later `app.publish_listing` completes it.
5. The Exit Date and the transfer-back payer use the settings row in force on the date the notice was received.
6. An application-level task was not kept: each vehicle gets 0020's `owner_intake` task, so one application of three vehicles gives three tasks.
7. The owner booking path goes through 0016's `app.request_booking`; signing and confirmation of the Owner Booking follow 0019's flow.
8. `site_settings.handover_slots` are offered times only; the booking functions of 0016 and 0019 do not yet restrict pickup times to them.
9. Lead enquiries for an owner program emit `owner_application_received` with `is_enquiry: true` in the payload, so the template can tell an enquiry from a full application.

## 13. Existing test assertions changed

None. Final run: every suite passes, including `04_rls.sql` unchanged.

## 14. Not done

- No PDF rendering or upload: the database stores what to put on each form and the generated file key the server writes back.
- No pg_cron schedule for the photo worker sweep or the draft purge: `app.claim_listing_jobs` and `app.purge_form_drafts` are for the worker and the retention job (adding cron jobs would change the job count asserted in `05_jobs.sql`).
- `publish_at` (publish later) is stored but no job publishes on that date yet.
- Copy similarity between listings (the 60% shared five-word check of the blueprint) is not computed in the database.
- Shared documents (`docs/permissions.md`, `docs/data-model.md`, `README.md`) do not yet mention this migration.
