# 10. Tolls, tickets and damages

Owner: workstream D (`src/features/tolls/`, `src/features/incidents/`). Routes under `/admin/tolls`, `/admin/incidents`, `/admin/claims`, mirrored for the Finance VA at `/va/finance/tolls` and for Fleet at `/va/fleet/incidents`.

The owner's requirement: entering tolls, tickets and damages and matching them to an active or past booking must be smooth and well built: single entry, bulk import from a toll operator's statement, upload of the notice with fields read from it where possible, automatic match by plate and timestamp against bookings, staff moves and owner use, a confirm screen showing the evidence, then charging the deposit or the card on file, or billing the owner, with the customer email. Damages found at return and after return are covered.

Rules: operating procedures 5, 9 and 11; Rental Agreement sections 4.2, 5.2, 5.3, 6 and 9; renter billing specification section 1; `toll_tickets`, `incidents`, `incident_costs`, `claims`, `claim_ledger_entries`.

## 1. The amounts

| Who had the car | What is charged | Administration fee | HST | Where it lands |
| --- | --- | --- | --- | --- |
| Renter | The amount on the notice | $15 per toll invoice; $40 per ticket, fine, tow or impound (from `booking_fee_terms`, else `fee_defaults`, via `app.toll_ticket_admin_fee()`) | On the fee only | `booking_line_items` (`toll_amount` or `ticket_amount`, pass-through; `toll_admin_fee` or `ticket_admin_fee`, company only) |
| Owner on an Owner Booking | The amount at cost | None | None added | `owner_deductions (owner_booking_toll or owner_booking_ticket)` on the next statement |
| Owner outside the programme, or a Turo-Only car | Nothing by CarmaCars | None | | The notice is forwarded to the owner |
| CarmaCars staff | CarmaCars pays | None | | Logged against the staff member (`staff_user_id`) |

"Per toll invoice" means one $15 fee for each toll statement per booking, however many trips it lists. The fee is placed on one `toll_tickets` row of each (statement, booking) group and is zero on the others (section 3.4).

## 2. `/admin/tolls` Work list

| Item | Detail |
| --- | --- |
| Tabs | To match (status `logged`), To confirm (auto-matched, awaiting a person), To charge (`matched`), Charged, With owner, Company paid, Disputed, Closed |
| Columns | Received, due date (red inside 5 days), charge-by date (3 business days from receipt), kind, authority, notice number, plate, vehicle, occurred at, amount, matched to, confidence, status |
| Filters | Kind, vehicle, booking, renter, date range, batch, "Due soon", "No match" |
| Buttons | Enter one, Upload a notice, Import a statement; bulk: Confirm selected (high-confidence rows only), Charge selected, Export CSV |
| P layout | Cards with the plate, amount, time and a confidence chip; swipe right to open the confirm screen |
| D layout | Table with a `SidePanel` showing the confirm screen (section 5) |
| Empty | "No notices waiting." |

## 3. Three ways in

### 3.1 Single entry (`/admin/tolls/new`)

| Label | Type | Validation | Default | Stored (`toll_tickets`) |
| --- | --- | --- | --- | --- |
| Kind | radio: toll invoice, ticket, camera offence, parking, fine, tow, impound | Required | Toll invoice | `kind` |
| Issued by | text with suggestions from earlier entries | Required | Last used | `authority` |
| Notice or invoice number | text | Required for everything except a toll trip line; unique per authority (the database has a unique index) and a duplicate shows the existing record | | `notice_number` |
| Plate | text, upper case | Required. On blur: looked up in `vehicles` and in past plates (`vehicle_registrations.plate`); shows the car found. Not found: "No vehicle with this plate. Check the plate, or log it as not ours" | | `plate`, `vehicle_id` |
| Date and time of the event | date-time, Toronto | Required; not in the future. A notice that gives only a date: tick "Time not stated" (matching then uses the whole day, section 4.3) | | `occurred_at`, `time_unknown` **[new]** |
| Place | text | Optional; for a toll, entry and exit points | | `place` |
| Amount | money | Required; 0 or more | | `amount_cents` |
| Due date | date | Optional but asked; drives the red flag | | `due_on` |
| Received on | date | Required | Today | `received_on`, and `charge_by` = 3 business days later (`app.add_business_days()`) |
| The notice | document capture | Required (a renter charge needs its supporting record) | | `document_id` (`documents.kind = 'toll_ticket_notice'`) |
| Note | text | Optional | | `note` **[new]** |

Buttons: "Save and match" (`createTollTicket` -> insert, then `app.match_toll_candidates()` **[new]**, then opens the confirm screen), "Save and add another" (keeps kind, authority, received date and the plate). Keyboard: Enter moves to the next field; the form is usable without a mouse for fast entry of a stack of notices.

### 3.2 Upload the notice and read the fields

"Upload a notice" opens the camera or file picker first. After upload the form above appears beside the image with fields already filled by the `ocr` module.

| Item | Detail |
| --- | --- |
| Module | `src/integrations/ocr/`: `extract(document, 'toll_notice') -> { fields: { kind, authority, notice_number, plate, occurred_at, place, amount_cents, due_on }, confidence per field, raw }`. Adapter: a vision-capable model called through the `llm` module with a fixed JSON schema, pay per use. A `none` adapter returns nothing, and the form is then plain manual entry |
| Display | Each pre-filled field has a small "read from notice" mark and its confidence (high, check). Tapping a field highlights the place on the image where the value was read, when the adapter returns positions |
| Rule | Nothing read by the machine is saved or charged until a person has looked at the form and pressed Save. Low-confidence fields are outlined and must be touched before saving |
| Multi-notice PDFs | A PDF with several notices is split by page; each page becomes one draft row in a small review list |
| Privacy | The image is sent to the provider only for extraction; it contains a plate and sometimes the registered owner's name (CarmaCars). No renter data is sent |
| Failure | Timeout or unreadable: the form opens empty with the image beside it and the message "We could not read this notice. Enter the details." |

### 3.3 Bulk import from a toll operator's statement (`/admin/tolls/import`)

A four-step wizard. A statement is typically a spreadsheet or CSV export of trips by plate or transponder.

| Step | Screen | Detail |
| --- | --- | --- |
| 1. File | Drop zone or file picker | Accepts CSV, XLSX and PDF. The file is stored (`documents.kind = 'toll_ticket_notice'`, one per batch) and parsed in an Edge Function (`toll-import`). CSV and XLSX are parsed directly. A PDF statement goes through the `ocr` module's table extraction, which is best effort: the wizard says so and shows the rows for checking |
| 2. Columns | A preview of the first 20 rows with a select above each column | Map to: plate (or transponder number), date, time (or one date-time column), entry point, exit point, amount, trip or transaction id, statement number. Date format and time zone are chosen (default Toronto). The mapping is saved as a profile per operator in `toll_import_profiles` **[new]** and applied automatically next time the same header row is seen |
| 3. Check | The parsed rows in a table with problems flagged | Problems: plate not in the fleet (kept as "not ours", not imported unless ticked), unreadable date or amount, a duplicate of an existing row (same authority, plate, time and amount, or same transaction id: skipped and shown), time in the future. Totals: rows, amount, by plate. Statement header fields: operator, statement number, statement date, due date, total; the row total must equal the statement total or the user confirms the difference |
| 4. Import and match | Progress, then results | `importTollBatch` -> `app.import_toll_batch()` **[new]**: inserts `toll_import_batches` **[new]** and one `toll_tickets` row per trip (`kind = 'toll_invoice'`, `import_batch_id`), then runs the matcher on every row. Results screen: matched to renters (n rows, m bookings), Owner Bookings, staff moves, outside the programme, unmatched; with "Review and confirm" taking the user to the To confirm tab filtered to the batch |

A statement's own number becomes the `notice_number` for the group; individual trips carry the operator's transaction id in `external_ref` **[new]**. Operators differ in what they export, so the wizard assumes nothing about a specific operator's layout: the first real statement from each operator is mapped once in step 2 and the profile is reused. Getting a sample statement file from the toll operator before launch is an open item (`99-traceability.md`).

### 3.4 Grouping for the "per toll invoice" fee

Rows from one statement that match the same booking form one group (`toll_group_id` **[new]** = batch plus booking). The group is charged together as one statement line set: one `toll_amount` line per trip (date, entry, exit, amount) and one `toll_admin_fee` line of $15. Single-entry toll invoices are a group of one. Tickets are never grouped: $40 each.

## 4. Automatic matching

### 4.1 Who could have had the car

`app.match_toll_candidates(p_vehicle uuid, p_at timestamptz, p_time_unknown boolean)` **[new]** returns every candidate with its evidence. It extends the existing `app.match_toll_ticket()`, which already matches a rental (handover to Check-in), an Owner Booking, a Turo-Only car and a time outside the vehicle's enrollment, but does not know about staff moves and returns one answer without evidence.

| Candidate | Rule | Source |
| --- | --- | --- |
| Renter | The time is inside the Rental Period: `handed_over_at` (else `pickup_at`) up to `checked_in_at` (else still on rent) of a booking in `on_rent`, `returned` or `closed` | `bookings` |
| Owner on an Owner Booking | Same, where `booking_type = 'owner'` | `bookings` |
| Staff move | The time is inside a field job on that vehicle: `started_at` to `completed_at` for delivery, pickup from renter, detail, photo shoot, registry run, tracker install or removal, recovery. For a delivery or collection, the leg before `handed_over_at` and after `checked_in_at` on the same day is staff time even without job timestamps | `field_jobs` |
| Vehicle swap | The time falls on the replacement car during a swapped booking | `booking_vehicle_swaps` |
| Turo-Only car | The vehicle's mode is Turo-Only | `vehicles.management_mode`, `turo_trips` for the trip in question |
| Owner outside the programme | Before the Enrollment Date or after the Exit Date | `vehicles.enrollment_date`, `exit_date` |
| Plate history | The plate belonged to a different vehicle at that time | `vehicle_registrations` |
| Nobody on record | The car was enrolled, not on a booking and not on a job | none: unmatched |

### 4.2 Confidence

| Confidence | Condition | What happens |
| --- | --- | --- |
| High | Exactly one candidate, and the time is at least 15 minutes inside its window at both ends | Row moves to "To confirm" pre-matched; eligible for bulk confirm |
| Medium | Exactly one candidate but within 15 minutes of a handover or a Check-in; or one renter candidate and one staff candidate that touch (a delivery leg) | Pre-selected best candidate; must be confirmed one at a time; the confirm screen asks for tracker proof |
| Low | Two or more candidates overlap; time not stated and more than one party had the car that day; a booking was in `confirmed` but never handed over | No pre-selection; a person chooses |
| None | Nobody on record | Stays in "To match"; a `finance` task `match_toll` escalated to an admin (procedure 11: escalate when there is no match) |

The result is stored on the row: `match_confidence`, `match_evidence jsonb` **[new]** (candidates, windows, margins in minutes, field jobs, the tracker reading if fetched), and a provisional `matched_to`, `booking_id`, `owner_id` or `staff_user_id`.

### 4.3 Time not stated

The whole Toronto calendar day is tested. One party all day: medium. More than one: low, and the confirm screen shows the day's timeline with the handover and Check-in times so the person can decide using the place on the notice and the tracker history.

### 4.4 Tracker proof

Tracker data is the proof of who had the car and where (Rental Agreement 12.2). On the confirm screen, "Fetch tracker position" calls the tracker module for the reading nearest the event time (`tracker.positionAt(vehicleId, at)`; history stays with the tracker service for 12 months). The result (time, coordinates, distance from the notice's place when it can be geocoded) is saved as a small PDF with a map image in the `claims` bucket and linked as `tracker_proof_document_id`. It is required for medium and low confidence matches to a renter and optional for high.

## 5. The confirm screen

One screen answers: is this the right party, what will they be charged, from where.

| Area | Content |
| --- | --- |
| Notice | The document (zoomable), and the entered fields: kind, authority, number, plate, time, place, amount, due date |
| Timeline | A 48-hour strip centred on the event for that vehicle, drawn with the calendar engine: bookings (with handover and Check-in marks), field jobs, blocks. A red marker at the event time. The margin to the nearest handover or Check-in is written in minutes |
| Candidates | A card per candidate: who (renter name and booking number; owner name; staff member), window, margin, confidence. The selected candidate is highlighted. "None of these" opens the manual choices: another booking (search), owner outside the programme, staff member (select), not our vehicle, dispute with the authority |
| Tracker | The fetched position and map, or the button to fetch it |
| Charge preview (renter) | Amount line, administration fee line, HST on the fee, total. "From": the deposit if it still has an unreleased balance (shows the balance and what remains), otherwise the Card on File (brand and last four). When the deposit covers part, the split is shown |
| Bill preview (owner) | Owner Booking: the amount at cost as a deduction on the next statement. Outside the programme or Turo-Only: "Forward to the owner"; no charge |
| Staff | "CarmaCars pays. Logged against [name]." with a note field |
| Paying the authority | A checkbox "We have paid this notice" with date and reference -> `paid_by_company_at`, `payment_reference` **[new]**. Unpaid notices nearing the due date stay flagged on the work list |

| Button | Action -> database | Emails |
| --- | --- | --- |
| Confirm match | `confirmTollMatch` -> sets `matched_to`, `booking_id` or `owner_id` or `staff_user_id`, `matched_by`, `matched_at`, `admin_fee_cents` (from `app.toll_ticket_admin_fee()`), `status = 'matched'` | none |
| Confirm and charge | `chargeTollTicket` -> `app.charge_toll_ticket()` **[new]** in one transaction: inserts the `booking_line_items` (amount and fee, `stage = 'after_return'`, `toll_ticket_id`, `supporting_document_id` = the notice), creates a `booking_statements` row (`kind = 'later_charge'`), applies the deposit (`deposit_events (applied)`) or creates the card `payments` row; sets `amount_line_item_id`, `fee_line_item_id`, `charged_from`, `status = 'charged'`, `notified_at`. The payments module then charges the Card on File off-session when needed | `renter_extra_charge` (T19) with the notice attached and the statement: "Booking [no.]: [toll or ticket] dated [date, time], $[amount], plus $[15 or 40] administration fee. $[total] charged to your [deposit or card]." |
| Bill the owner | `billTollToOwner` -> `owner_deductions` row (kind by notice type, `receipt_document_id` = the notice), `owner_deduction_id`, `status = 'billed_to_owner'` | `owner_toll_ticket` |
| Forward to the owner | `forwardTollToOwner` -> `status = 'forwarded_to_owner'` | `owner_toll_ticket` with the notice |
| Company pays | `markTollCompanyPaid` -> `status = 'company_paid'`, `staff_user_id` | `staff_toll_ticket_logged` to the admins (digest) |
| Name the renter to the authority | Admin only. `nameRenterToAuthority` -> `status = 'named_to_authority'`; generates a letter with the booking details the authority needs and logs it | `renter_named_to_authority` |
| Dispute | `disputeToll` (reason) -> `status = 'disputed'` | none |
| Not our vehicle | `closeToll` with the reason | none |

Rules enforced by the function and the table's checks: a renter or Owner Booking match needs `booking_id`; a staff match needs `staff_user_id`; a non-renter match has no administration fee; a renter is charged only with a notice document attached; the same notice cannot be charged twice (unique index on authority and notice number, and `amount_line_item_id` set once).

**Bulk confirm and charge.** On the To confirm tab, selecting high-confidence rows enables "Confirm and charge selected". A summary lists the bookings, totals and sources (deposit or card) before the final confirm. Each row is processed in its own transaction; failures are listed with reasons and stay in the list.

**Declined card.** The `payment-retries` job adds the $40 declined-payment line once and retries after 1, 3 and 7 days; the renter gets `renter_payment_failed` (T10) with a pay link.

## 6. Edge cases for tolls and tickets

| Case | Handling |
| --- | --- |
| A toll during a delivery leg, minutes before the handover | Medium confidence; staff candidate pre-selected when the time is before `handed_over_at`; tracker position shown |
| Renter returned the car late and the toll is after `return_at` but before `checked_in_at` | Renter: the Rental Period runs to Check-in |
| Booking was extended | The extended `return_at` and the actual `checked_in_at` are used |
| Renewal chain | The matching booking is the one whose Rental Period contains the time; a deposit carried to the renewal is used if still held |
| Deposit hold-back | When a toll or ticket is expected, Finance can hold back part of the deposit for up to 30 days (`03-admin.md` section 11.2); the charge then comes from the held-back amount |
| Notice arrives months later | Charging is allowed until all Charges are paid (Rental Agreement 5.3). The renter's record is opened through a logged lookup if outside the staff window |
| Vehicle has exited | The match still works on history; an owner-outside-programme result forwards the notice |
| Impound or tow | Entered as `kind = 'tow'` or `'impound'`; always escalated to an admin; usually also an incident |
| Court summons | Escalated; not charged |
| Amount corrected by the authority | Void the line (a credit mirrors the charge), enter the corrected notice |
| Renter questions the charge | `disputeCharge` from the renter portal sets `disputed` and creates a `finance` task; the screen shows the evidence pack (notice, timeline, tracker proof, signed agreement section 6) ready to send |
| Staff member responsible for a fine | Logged against them; an admin handles recovery outside the platform (the Field Staff Agreement forbids deducting it from wages) |
| Same plate on two vehicles over time | Plate history decides by date |
| Statement lists a transponder, not a plate | A transponder to vehicle table (`vehicle_transponders` **[new]**) maps it |

## 7. Damages: from finding to charge

Three ways damage arrives, one path after that.

| Entry | Who | Screen | Creates |
| --- | --- | --- | --- |
| At return | Field staff, with the renter present | Return checklist step 7 (`06-field.md` section 5): location on the diagram, type, size, close-up photo | `condition_report_damages (is_new = true)`, `incidents (kind = 'damage_at_return')`, urgent admin task |
| After return, within 48 hours | Fleet, comparing the two photo sets, or a detailer | "Add damage found later" on the booking's Condition tab, or `/field/report` | `condition_report_damages (found_later = true)`, `incidents (kind = 'damage_found_later')`. The screen shows the 48-hour deadline from Check-in (`program_settings.damage_late_report_hours`) as a countdown |
| During the rental | Renter calls the incident line; staff open it | `/admin/incidents/new` (procedure 9): booking, driver, time, place, other party, police report number, anyone hurt, drivable | `incidents (kind = 'accident', 'theft' or 'vandalism')`, `incident_events` |

### 7.1 Reporting late-found damage to the renter

`reportDamageToRenter` (button on the incident, enabled only inside the 48 hours; after that an admin must tick "Report anyway" with a reason, and the screen warns that the agreement's 48-hour condition was missed): sends `renter_damage_found` (T8) with the photos, sets `condition_report_damages.reported_to_renter_at`. Damage first recorded at return needs no T8: the renter saw and signed it.

### 7.2 `/admin/incidents/[id]`

| Section | Content | Actions |
| --- | --- | --- |
| Summary | Number, kind, vehicle, booking, driver, times, place, description, other party, police report number, hurt, drivable, status | Edit; "Rental ended" (not drivable: no replacement, no refund, per agreement 11.5) |
| Timeline | `incident_events`: every call, message, tracker check and command, decision | Add event (kind, detail, document) |
| Evidence | Pickup and return photos side by side for the damaged area; the renter's report and photos (due 48 hours after an accident) | Request the renter's report (`renter_accident_instructions`, T16) |
| Costs | `incident_costs`: estimate or invoice from an approved shop (required: approved shop yes), towing, storage, loss of use (days out of service at the booking's daily rate, at most 30; `calc_loss_of_use()`), other | Add cost with its document; an invoice supersedes its estimate |
| Damage cost | The total from `app.incident_damage_cost()` and the path it selects | |
| Billing | See 7.3 | |
| Owner | T17 status | Send `owner_incident_opened` (T17) |
| Calendar | The repair block on the vehicle | Create or end the block |

### 7.3 What the renter is billed

`openClaim` -> `app.open_claim()` chooses the path with `calc_damage_billing()`:

| Damage cost | Path | Renter is billed | Lines |
| --- | --- | --- | --- |
| Under $2,500 | At cost, no insurer | The actual cost (estimate or invoice, towing, storage, loss of use) plus the $50 administration fee | `damage_at_cost` (pass-through, HST as invoiced), `loss_of_use` (claim funds, no HST), `admin_fee_other` (company, HST) |
| $2,500 or more | Fleet policy claim; an admin notifies the broker the same day | The $2,500 deductible plus the $75 administration fee. Loss of use is not added on top | `deductible` (claim funds, no HST), `admin_fee_claim` (company, HST) |
| Claim denied for the renter's breach | Admin decision | The full cost | `damage_at_cost` for the full amount |
| Owner Booking, under $2,500 | Owner repairs at their own cost | Nothing | none |
| Owner Booking, claim made | | Owner is billed the $2,500 deductible | `owner_deductions (owner_booking_deductible)` |
| Turo-Only car | Turo's process | Nothing here | `claims.path = 'turo'` |

Charge screen (admin, or Finance preparing for an admin: any damage line is an escalation under procedure 5):

| Element | Detail |
| --- | --- |
| Lines | Proposed from the path; each with its supporting document (estimate, invoice, photos). A line without a record cannot be issued |
| Source | The deposit first (including any held-back amount), then the Card on File. The deposit does not cap what the renter owes |
| Coverage | The renter's Coverage Option is shown with "Ask the renter to claim and direct payment to CarmaCars" (agreement 8.4); payments from the coverage provider are recorded as `claim_ledger_entries (renter_coverage_payment)`. The provider is never named in any message |
| Button "Issue statement and charge" | `chargeDamage` -> `app.issue_booking_statement()` **[new]** with `kind = 'later_charge'` (or inside the Check-in statement when known in time), deposit events, card payment; claim-funds lines also write `claim_ledger_entries (renter_deductible or renter_at_cost, payment_id, line_item_id)`. Emits `renter_extra_charge` (or `renter_final_statement` when the lines are on the Check-in statement) with the estimate or invoice and photos |
| Hold back | Before the estimate is in, Finance holds back the expected amount from the deposit at Check-in (up to 30 days), so the 7-business-day release is not missed |

### 7.4 After billing

The claim runs on `/admin/claims/[id]` (`03-admin.md` section 12): ledger of money in and out, settlement with `app.settle_claim()`, total loss with `app.record_total_loss_settlement()`. On a third-party owner's car, claim money pays the repair and claim costs and any balance stays with CarmaCars; a shortfall becomes an owner deduction unless CarmaCars caused it. On a shareholder vehicle profit and shortfall split 90/10 and payment needs both principals. The vehicle's repair block ends when the shop releases the car, then detailing.

### 7.5 Other chargeable matters at or after return

Lost key or fob (replacement cost plus $50), roadside call-out the renter caused (cost plus $50, or the $40 item fee for a tow), recovery costs after a repossession, cleaning grades and smoking: entered on the post-rental charges screen (`03-admin.md` section 11.3) with a supporting record each. They use the same statement, deposit-then-card and email path.

## 8. Emails in this file

Codes are those of `emails/catalogue.json` (`12-notifications.md`). Supporting records are linked as signed file links valid for 7 days.

| Code | Replaces | To | When | Records linked |
| --- | --- | --- | --- | --- |
| `renter_extra_charge` | T19 | Renter | A toll, ticket, damage or other line is charged after the final statement | The notice or estimate or invoice; photos; the statement |
| `renter_final_statement` | T9 | Renter | The Check-in statement, when a damage or other finding is known in time to be on it | Statement; records for each line |
| `renter_damage_found` | T8 | Renter | Damage found after return, within 48 hours | Photos |
| `renter_accident_instructions` | T16 | Renter | An accident, theft or vandalism incident is opened | none |
| `renter_payment_failed` (`is_booking_payment = false`) | T10 | Renter | The Card on File is declined for a charge | none |
| `renter_named_to_authority` | to be added | Renter | An admin names the renter to the authority | The notice |
| `owner_toll_ticket` (`is_forwarded = false`) | | Owner | An Owner Booking toll or ticket is billed at cost | The notice |
| `owner_toll_ticket` (`is_forwarded = true`) | | Owner | A notice for a time outside the programme, or a Turo-Only car, is forwarded | The notice |
| `owner_incident_opened`, `owner_incident_update` | T17 | Owner | An incident or claim on the owner's vehicle opens or changes status | none |
| `staff_toll_ticket_logged`, `staff_toll_ticket_unmatched` | | Finance, admins (digest) | A notice is logged and matched; no match after 2 business days | none |
| `staff_incident_reported`, `staff_return_findings` | T7 | Admins, Fleet, Finance | Damage recorded at or after return; findings saved | none |

## 9. Database additions needed

| Addition | Purpose |
| --- | --- |
| `toll_tickets`: `time_unknown boolean`, `note text`, `external_ref text`, `import_batch_id uuid`, `toll_group_id uuid`, `match_confidence text`, `match_evidence jsonb`, `payment_reference text`, `ocr_raw jsonb` | Sections 3 to 5 |
| `toll_import_batches (id, operator, statement_number, statement_date, due_on, total_cents, row_count, document_id, profile_id, imported_by, created_at)`, `toll_import_profiles (id, operator, header_signature, mapping jsonb, date_format, timezone)` | Bulk import |
| `vehicle_transponders (id, vehicle_id, transponder_number, from_date, to_date)` | Statements keyed by transponder |
| `app.match_toll_candidates(p_vehicle uuid, p_at timestamptz, p_time_unknown boolean) returns jsonb` including field jobs, swaps and plate history; keep `app.match_toll_ticket()` as the single-answer wrapper | Matching with evidence |
| `app.import_toll_batch(p jsonb)`, `app.charge_toll_ticket(p_ids uuid[], p_by uuid)` (groups by booking and statement for the fee), `app.bill_toll_to_owner(p_id uuid, p_by uuid)` | One transaction per step |
| `app.issue_booking_statement()` (also in `03-admin.md`) accepting claim-funds lines and writing `claim_ledger_entries` | Damage billing |
| Trigger: a new `toll_tickets` row or an unmatched result creates the `finance` task `match_toll` with `due_at = charge_by` | Queue |
| Field jobs: make sure `started_at` and `completed_at` are always set by the field portal actions (they are nullable today) | Staff-move matching depends on them |
| Finance VA read policy on `field_jobs` and `tracker_status` already exists ("toll proof"); add read on `booking_vehicle_swaps` | Confirm screen |
