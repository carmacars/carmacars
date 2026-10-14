# Tolls, plates and forms: reading toll notices, covering plates on listing photos, official ServiceOntario PDFs, one turnaround, the tracker interface, October 14, 2026

Migration `supabase/migrations/0042_tolls_plates_forms.sql`, tests `supabase/tests/26_tolls_plates_forms.sql` (87
assertions), end to end `web/tests/e2e/tolls-plates-forms.spec.ts`, unit tests `web/src/features/tolls/parse.test.ts`,
`vision-schema.test.ts`, `web/src/features/official-forms/fill.test.ts`, `web/src/features/listing/plate-cover.test.ts`,
`web/src/integrations/tracker/none.test.ts`. No earlier migration was edited; the functions it changes are wrapped
(`publish_listing`, `door`) or replaced with the same signature (`vehicle_is_available`, `public_vehicle_calendar`,
`sync_turnaround_block`, `turnaround_minutes`, `owner_portal_forms`), as 0029 to 0041 did.

## 1. What was asked, and what there is now

| # | Asked | Now |
| --- | --- | --- |
| 1 | Read toll notices and statements (PDF, image, CSV): 407 ETR and other Ontario tolls, parking tickets, red light and speed camera notices, municipal penalties. Review beside the source, then the existing matching, charges and emails | Admin > Tolls > Read a notice (and Finance's `/va/tolls/read`): a CSV with its column mapping, a PDF from its text with the issuer's reading profile, a scan or photo by the vision model page by page. The lines are checked and corrected beside the file, then confirmed: 0021's import (validation, duplicates, matching), renters matched with high confidence charged with the administration fee when ticked, the existing emails; every line not imported stays as an exception with its reason (section 2) |
| 2 | Cover licence plates on listing photos: a suggested box, boxes drawn by hand on a desktop or a phone, blur, pixelate or a CarmaCars plate; the covered photo public, the original private; publishing waits for every public photo (a setting); also in the pipeline's review step | The plate editor on the listing review screen (Admin and Fleet or customer service): the vision model's box, more drawn by hand, the style, saved in the browser; the covered file replaces the public one and the public file as it was is kept in the private bucket; "No plate visible"; publishing checks every public photo after every other check (section 3) |
| 3 | Official ServiceOntario PDFs: upload, read the AcroForm fields, map each to the data, fill automatically for owners with pdf-lib, offer for signature or download, the data sheet until mapped | Admin > Settings > Forms: upload the fillable PDF, its fields are read in the browser, a mapping table, a filled preview for one car, "Checked: use for owners". Owners then get the official form filled from their records, to download or sign on screen; until then the data sheet (section 4) |
| 4 | The 120-minute cleaning block doubled up with the 2-hour buffer | One turnaround (`turnaround_buffer_minutes`, 120); the cleaning block after a trip is that time, never added to it; removing the block frees the time (section 5) |
| 5 | A tracker adapter interface with no fake behaviour | `web/src/integrations/tracker/`: `locate`, `requestImmobilize`, `mileage`; the `none` adapter answers "not connected"; "Coming soon" on the vehicle page (section 6) |

## 2. Reading toll notices and statements

**Flow.** `/admin/tolls/read` (Admin) and `/va/tolls/read` (Finance):

1. The file is stored first (private `documents` bucket, `tolls/<year>/<id>.<ext>`, a `toll_ticket_notice` document): it is the
   proof a renter or owner is sent.
2. It is read in the browser, never in the Worker:
   - **CSV**: the saved column mapping of 0021 for that header row is applied, or the columns are guessed; staff adjust
     them, choose the issuer, the kind and the date order, and may save the mapping. The fees column is new.
   - **PDF with text**: pdf.js (`pdfjs-dist` 4.10.38, its worker served from `/vendor/pdfjs/`, a unit test checks it is the
     installed one) gives each page's lines with their position. The reading profile is the one whose words appear most
     (or the one chosen), and `web/src/features/tolls/parse.ts` reads the header (statement number, account, statement
     date, due date, total) and either one line per trip (a statement) or one offence (a single notice).
   - **A scan or a photo** (or a PDF whose pages have no text, or whose text gave no line): each page (up to
     `toll_read_max_pages`, 6) is drawn as a JPEG of 1,600 px and sent to `POST /api/staff/vision`, which asks the vision
     model for strict JSON; the answer is checked in the browser (`vision-schema.ts`): dates and times read again,
     amounts to cents, plates to letters and digits, the model's confidence never above what the checks allow.
   - Vision off, the day's allowance used, or the model unavailable: the read is saved with no line and "Type the lines
     beside the notice"; staff add each line by hand.
3. The read is saved (`app.toll_read_save`) with a Finance task `toll_read_review`, and the review screen opens.

**Review** (`/admin/tolls/read/<id>`): the notice on the left (the PDF page drawn in the browser with the line being checked
marked, the photo, or the CSV rows), the lines on the right, 30 at a time. Each line: kind, issuer, notice number, plate,
date and time (Toronto), "time not on the notice", amount, of which fees, entry, exit, location, transponder, due date; the
confidence; the problems in words (plate missing, plate not in the fleet, date missing or in the future, time not stated,
amount missing, notice number missing, issuer missing, already logged, read with low confidence); the car found for the
plate on that date (0021's `resolve_toll_vehicle`); what was read. Actions: Save, "Checked against the notice", "Leave
out" with a reason, "Put it back", "Add a line", "Discard this read" with a reason.

**Confirm and import** (`app.toll_read_confirm`): every line checked by a person, or read at
`toll_read_min_confidence` (80) or more with nothing missing, goes through 0021's `app.import_toll_batch` (one batch per
issuer and kind, the statement number, due date and the notice attached to every toll; the fees noted on the toll and the
read kept in `ocr_raw`). Each line gets the import's result: imported (with its toll and match), already logged, or not
imported with the reason. Every pending line with a problem becomes an exception. With "Charge renters matched with high
confidence now" (default `toll_read_auto_charge`, on), those tolls are charged by 0021's `app.charge_toll_ticket` (the
notice and the administration fee from the booking's fee terms, the later-charge statement, the Deposit first, the existing
`renter_extra_charge` email). Lower-confidence matches, owner and staff matches and unmatched notices go to the existing
work queue (`needs_review`, `unmatched`, `matched_not_billed`, ...) and its emails. Exceptions raise one Finance task
`toll_read_exceptions` naming each line; a fixed line is imported on its own ("Import this line",
`app.toll_read_line_import`) and the task closes when nothing is left. The tolls page lists the reads and every exception.

**Reading profiles** (`/admin/tolls/profiles`, Finance too): 0021's `toll_import_profiles` gain `source` (`csv` or
`pdf_text`), `notice_kind`, `rules`, `is_active`, `priority`, `notes`, `sample_text`. A text profile is edited without
code: the words that identify the issuer, the layout (a statement, one notice, or find out), the date order, the issuer
name, the label words in front of each value (statement number, account, statement date, due date, total, issuer, notice
number, plate, transponder, date, time, location, amount, fees), and for a statement the words of lines that are not trips,
the statement fees kept apart, and which amount on a trip line is its amount (the last, with the rest as fees; the first;
or the sum). "Try it" reads pasted text with the profile as it stands on screen. Seeded: **407 ETR statement**, **Red light
or speed camera (Ontario)**, **Parking or administrative penalty (Ontario)**, **Provincial offence notice (Ontario)**, and
**Any notice (general reading)**, used when no other matches.

The owner has not sent a real 407 ETR statement. The 407 ETR profile follows the public layout of its statements (account
summary, then one line per trip with date, time, entry and exit interchanges, distance, plate or transponder, toll and
camera charges and the line total; account fees apart). Check it with the first real statement: paste its text under "Try
it", adjust the words, save.

**The vision model.** Cloudflare Workers AI through the Worker's `AI` binding (`web/src/integrations/vision/`), no key and
no monthly fee. `ai_vision_model` is `@cf/meta/llama-4-scout-17b-16e-instruct`, `ai_vision_fallback_model`
`@cf/meta/llama-3.2-11b-vision-instruct` (its licence is accepted once by sending "agree", which the adapter does when the
answer asks for it). The image goes as a data URL in the chat message, with JSON mode; a model that refuses that shape is
asked without JSON mode, then with the image on its own. Every call is recorded in `provider_calls` (purpose
`toll_read` or `plate_detect`, neurons) and refused past `ai_vision_daily_neurons` (3,000) or past the listing copy's daily
budget (the free 10,000 neurons are shared). The answer is never stored as a toll: a person checks every line.

## 3. Licence plates on listing photos

- The listing review screen (`/admin/listings/<id>`, `/va/listings/<id>` for Fleet and customer service, which is also the
  AI listing pipeline's review step) shows each public photo's plate state: "Plate not checked", "Plate covered", "No plate
  visible", with "Cover the plate" and "No plate visible"; "No plate visible on the N photos left" asks to confirm, then
  marks them. The odometer shot (never public) is not asked.
- **The editor** (`PlateEditor.tsx`, `plate-cover.ts`): the photo on a canvas; when the photo has not been checked, the
  vision model is asked for the plate box once (`plate_detect_enabled`), and its boxes are shown dashed for staff to check;
  "Suggest the plate" asks again. Boxes are drawn by dragging (mouse, finger or pen, `touch-action: none`), moved by
  dragging, resized from the lower right corner; keyboard: N adds a box, the arrows move it, Shift and the arrows resize
  it, Delete removes it. Styles: a CarmaCars plate (black, white name from Site settings or `plate_cover_text`, the red
  line), pixelation, or blur (made by shrinking and growing the area twice, so it works on phones without the canvas
  filter). The default is `plate_cover_style` (cover).
- **Saving** (`POST /api/listing/plate`): the browser sends the covered photo as a JPEG at its size (at most 3,000 px) and at
  each smaller width the photo had; the server checks the person's right through the database, writes the new files under
  `vehicles/<car>/<name>-c<tag>.jpg` (a new name, so caches never show the old one), copies the public file as it was to
  the private `vehicle-originals` bucket (`vehicles/<car>/uncovered/...`, `vehicle_photos.uncovered_path`) the first time,
  points the photo to the covered file (`app.photo_plate_record`: status, boxes, style, who and when), removes the old
  public files and rebuilds the car's pages. A failed record removes the new files.
- **Publishing** (`app.publish_listing`, wrapped): after every check of 0022 and 0040 passed, any photo the publish makes
  public with no plate decision undoes the publish with "Cover the licence plate or mark it not visible on every public
  photo first: Front, Rear, ..." (`listing_plate_check_required`, on). The pipeline's automatic publish keeps that reason
  on the intake, as for its other checks. Listings already published are not changed; their photos show "Plate not
  checked" until someone checks them.

## 4. Official ServiceOntario PDFs

- **Admin > Settings > Forms** lists the five registry forms with their state: "Data sheet in use", "Mapping to check" or
  "Official PDF in use", and how many owners have each.
- **Upload**: the fillable PDF is read in the browser with pdf-lib (each field's name, type, options and page); a PDF with
  no fillable field is refused with the reason. The file goes to the private `documents` bucket and becomes the form's
  current template version (`app.form_template_upload`); a field of the same name keeps its mapping from the version before.
- **Mapping**: for each field, what goes in it (grouped: owner, corporation, vehicle, the CarmaCars company as registrant,
  lender, onboarding method, today; `app.registry_sources()`), or "The owner signs here"; a format (capitals, postal code,
  phone, yes or no, dates); "only when" (a yes or no value, for example a lease); "needed". "Download a filled preview"
  fills the official PDF for one car in the browser (`app.form_template_preview`). "Checked: use for owners"
  (`app.form_template_map` with `verify`) marks it checked and fills every owner's form of that kind again
  (`app.fill_government_form`), except one already signed or filed.
- **Owners** (`/owner/documents`): a form from a checked template says "Official form, filled for you" and opens
  `/owner/documents/forms/<id>/official`: "Download the filled form" (filled in the browser from the values the database
  resolved, never in the Worker), and when the form maps a signature box and nothing is missing, "Sign on screen" with the
  same signature pad as the agreements; the signed copy (flattened) is stored in the private `agreements` bucket, filed as
  a `registry_form` document of the owner and the car, and the form is marked signed (`app.owner_form_signed`). If the
  registry office wants an ink signature, the owner prints it.
- Until a form's PDF is uploaded and checked, nothing changes for owners: the data sheet stays (`/owner/documents/forms/<id>`).
- Tested with a fillable PDF generated by pdf-lib (`sampleForm()` in `fill.ts`): unit tests, the database test, and the
  end to end test (upload, map, use, the owner downloads it filled and signs it on a phone).

## 5. One turnaround between trips

- `turnaround_buffer_minutes` (0025's 2 hours, 120) is the one turnaround. `turnaround_block_minutes` (0040) is kept equal
  to it by a trigger and no longer shown in Program settings. `vehicles.turnaround_block_minutes` is now the car's own
  turnaround (Vehicles > the car > Calendar), used for both.
- Availability (`app.vehicle_is_available`, `app.public_vehicle_calendar`): before a trip's pickup the turnaround is held;
  after its return the cleaning block holds it, and no buffer is added behind the block. When staff remove a block, that
  time is free. With the block switched off (`turnaround_block_enabled`), the same time is held after the return without a
  block. Changing the turnaround moves the blocks of the trips ahead.
- Before: the block and the buffer covered the same 2 hours, but removing a block freed nothing (the buffer still held it),
  and a car's own cleaning time did not change its availability.
- Program settings shows "Turnaround between trips" with the explanation; the field has a label and a hint.
- Tests: `26_tolls_plates_forms.sql` section 2 (the block is the turnaround; a trip may start 2 hours after the return and
  not a minute sooner; a trip before must end 2 hours before the pickup; removing the block frees the time; a car's own 60
  minutes; a new setting moves the blocks; the block switched off; the legacy column cannot drift).

## 6. The tracker interface

`web/src/integrations/tracker/types.ts`: `locate(device)`, `requestImmobilize(device, request)` (only for a
`tracker_commands` row an Admin approved, as 0020 requires), `mileage(device)`, each returning a result or a reason. The
only adapter, `none`, answers "not connected" to everything and sends nothing. The vehicle page's Tracker card says "Coming
soon: live location, the remote immobilize request and the mileage from the tracker. The tracker company's connection
details are needed first."

## 7. Objects added

**Tables (2):** `toll_notice_reads` (TR-1001...), `toll_notice_read_lines`, each with row-level security, an admin policy,
Finance read and the audit trigger.

**Columns:** `program_settings`: `toll_read_min_confidence`, `toll_read_auto_charge`, `toll_read_max_pages`,
`ai_vision_enabled`, `ai_vision_model`, `ai_vision_fallback_model`, `ai_vision_daily_neurons`,
`listing_plate_check_required`, `plate_cover_style`, `plate_cover_text`, `plate_detect_enabled`.
`toll_import_profiles`: `source`, `notice_kind`, `rules`, `is_active`, `priority`, `notes`, `sample_text`.
`vehicle_photos`: `plate_status`, `plate_boxes`, `plate_style`, `plate_checked_by`, `plate_checked_at`, `uncovered_path`,
`plate_suggestion`. `pdf_templates`: `field_names`, `file_name`, `mapped_by`, `mapped_at`.

**Functions:** `ai_vision_budget`, `ai_call_record`, `ai_vision_gate`, `toll_read_context`, `toll_read_document`,
`toll_read_line_refresh`, `toll_read_save`, `toll_read_get`, `toll_read_line_save`, `toll_read_line_add`,
`toll_read_import_lines`, `toll_read_confirm`, `toll_read_line_import`, `toll_read_discard`, `toll_read_queue`,
`toll_profiles`, `toll_profile_upsert`, `photo_plate_context`, `photo_plate_record`, `photo_plate_suggestion`,
`listing_plate_problems`, `listing_plates`, `registry_sources`, `form_field_values`, `form_templates`,
`form_template_upload`, `form_template_map`, `form_template_preview`, `owner_form_official`, `owner_form_signed`
(and `public.` wrappers of the last two), `program_settings_one_turnaround`, `program_settings_turnaround_resync`, `ops42`.
**Wrapped:** `publish_listing` (as `publish_listing_0040`), `door` (as `door_0040`). **Replaced with the same signature:**
`turnaround_minutes`, `sync_turnaround_block`, `vehicle_is_available`, `public_vehicle_calendar`, `owner_portal_forms`.

**Task rules:** `toll_read_review`, `toll_read_exceptions` (Finance, procedure 11). **Seeded profiles:** five, section 2.

**Web:** pages `/admin/tolls/read`, `/admin/tolls/read/[id]`, `/admin/tolls/profiles`, `/va/tolls/read`,
`/va/tolls/read/[id]`, `/va/tolls/profiles`, `/admin/settings/forms`, `/owner/documents/forms/[id]/official`; routes
`POST /api/staff/vision`, `GET /api/staff/toll-read/[id]/file`, `GET /api/staff/form-template/[id]`,
`POST /api/listing/plate`, `GET /owner/documents/forms/[id]/template`, `POST /owner/documents/forms/[id]/signed`; server
actions `web/src/server/actions/staff-tools.ts`; modules `features/tolls`, `features/official-forms`,
`features/listing/PlateEditor.tsx` and `plate-cover.ts`, `integrations/vision`, `integrations/tracker`.

## 8. Permissions

| Data or action | Admin | VA Finance | VA Fleet | VA CS | Others |
| --- | --- | --- | --- | --- | --- |
| Read notices, check and confirm reads, profiles | yes | yes | no | no | no |
| Vision model for notices | yes | yes | no | no | no |
| Plate editor, plate suggestion, plate decisions | yes | no | yes | yes | no |
| Official form templates and mapping | yes | no | no | no | no |
| The owner's official form, signed copy | | | | | the owner of the car |

Every new function is for the server (`service_role`) through the staff door's `ops_read` and `ops_do` calls; a change is
never accepted as a read. `app.registry_sources()` is a plain list any role may read.

## 9. Existing tests changed

| File | Was | Now | Why |
| --- | --- | --- | --- |
| `supabase/tests/helpers.sql` | no plate check | the plate check before publishing is off for the earlier suites (`listing_plate_check_required` default false in the test database); 26 switches it on and tests it | 11, 12, 19, 20 and 25 test the publish rules of 0022 to 0041 with photos that carry no plate decision |
| `web/tests/e2e/pipeline.spec.ts`, `admin.spec.ts` | approve and publish | "No plate visible on the photos left" first | publishing waits for the plates |

No assertion's expected value changed.

## 10. Tests and live results

| Check | Result |
| --- | --- |
| Database suite (`scripts/test.sh`) | TBD |
| Unit (`npm run test:unit`) | TBD |
| Types, lint, build | TBD |
| End to end, local | TBD |
| Push CI | TBD |
| Deploy | TBD |
| Verify | TBD |

## 11. For the owner

TBD
