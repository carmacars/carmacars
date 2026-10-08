# 0024: gap fixes

Migration `supabase/migrations/0024_gap_fixes.sql`, tests `supabase/tests/12_end_to_end.sql`. Runs after every other migration; the test file runs after every other test file, so it sees all of them. No earlier migration was edited. It closes the gaps that the records of 0018 to 0023 listed as not done.

## 1. Scheduled jobs (pg_cron, 0015 pattern)

Five functions that existed but were never scheduled now run from pg_cron. Each wrapper takes the instant to judge by (`now()` unless a test or an admin passes another), claims a run key in `job_runs` with `app.job_claim()`, records its summary with `app.job_succeed()`, and on an error marks the run failed with `app.job_fail()` (an urgent admin task and `staff_job_failed`, through 0023). A second call with the same key returns `already_run`.

| Job | Wrapper | Cron line (UTC) | Run key | Does |
| --- | --- | --- | --- | --- |
| `rate-limit-purge` | `app.job_rate_limit_purge()` | `22 * * * *` | Toronto day, from `housekeeping_hour` | `app.rate_limit_purge()` (0019) with `rate_limit_keep_hours` |
| `form-drafts-purge` | `app.job_form_drafts_purge()` | `24 * * * *` | Toronto day, from `housekeeping_hour` | `app.purge_form_drafts()` (0022) |
| `lapse-extensions` | `app.job_lapse_extensions()` | `3-59/15 * * * *` | 15-minute slot | `app.lapse_extensions()` (0019): an extension requested or approved but not paid by the current return time lapses |
| `listing-sweep` | `app.job_listing_sweep()` | `7-59/10 * * * *` | 10-minute slot | New `app.sweep_listing_jobs()`: a listing job claimed by a worker and not finished within `listing_job_lock_minutes` is queued again (or fails through `app.fail_listing_job()` once it has used its attempts); jobs waiting out a back-off are left for `app.claim_listing_jobs()`; the summary counts what is due for the worker |
| `listings-publish` | `app.job_publish_listings()` | `2-59/5 * * * *` | 5-minute slot | New `app.publish_scheduled_listings()`: every listing whose `publish_at` has come is published with 0022's `app.publish_listing()` in the name of the person who scheduled it, so every check of an immediate publish applies. A listing that cannot be published keeps the reason in `publish_error`, its time is cleared and Fleet gets the `listing_failed` task |

`app.schedule_listing_publish(by, vehicle, at)` sets or clears the time (an Admin or a customer service or fleet assistant; a time in the past is refused). `app.job_slot(now, minutes)` gives the slot key. The listing worker itself stays an Edge Function: it calls the decode, copy and photo providers.

`05_jobs.sql` now expects 20 `carmacars-` cron jobs where pg_cron exists (it was 15).

## 2. Charge lines added by hand

Trigger `booking_line_items_manual_charge_notify` (function `app.manual_charge_after()`), after insert or after `supporting_document_id` is set, emits `renter_extra_charge` for entity `booking_line_item`, dedupe key `renter_extra_charge:<line id>:manual`, when all of these hold:

- the line is charged to the renter, positive, not voided, at stage `check_in` or `after_return`;
- it carries a supporting record (the catalogue requires one; a line typed without it is emailed when the record is attached, still once);
- it was not made by a function: `assessment_key` is empty (0020's `app.assess_check_in`, and damage through 0021's `app.bill_damage`, always set it) and `toll_ticket_id` is empty (0021's `app.charge_toll_ticket` sets both and emits its own `renter_extra_charge` per statement);
- the booking is `returned` or `closed` and its Check-in statement exists. A line added before that statement goes on it and is told by `renter_final_statement`, so it is not emailed twice.

The merge payload: 0023's builder is kept unchanged under the name `app.ntf_payload_base`, and `app.notification_payload` (same signature, the one entry point `app.process_events` calls) adds, for this entity, `charge_type` (the charge type's label), `charge_lines` (the line and its HST), `charge_total`, `charge_reference` (the statement number once the line is on one, else the booking number and the line's short id), `charge_summary`, `charge_event_date`, `charged_to` and `payment_date`. 0023's case reads a renter statement, which a hand-added line may not have yet. The end-to-end test checks the email is built with no missing variable.

## 3. One flow for changing a confirmed booking

`booking_change_requests.source` (`booking_app` or `staff_calendar`) is new. `app.calendar_preview_change` and `app.calendar_apply_change` (0020) were created again with the same signatures:

- **Confirmed booking billed to the renter, `renter_approval`.** The preview also returns 0019's `app.preview_booking_change` (`change_request_preview`, `flow: change_request`); its total difference replaces 0020's, and a problem 0019 refuses (other than "not free", which stays `available: false`) becomes the refusal. Applying creates (or reuses) a change request with `source = 'staff_calendar'` through `app.request_booking_change` (status `proposed`), and raises 0020's `booking_change_approval` task tied to it. The renter agrees with `app.agree_booking_change`; the server applies with `app.apply_booking_change` and the payment of exactly the difference, or a refund for approval when it costs less. With `p_renter_agreed` (an Admin recording the renter's word), a change that costs nothing more is agreed by phone and applied at once; one that costs more still waits for the renter to agree and pay online (0019's rule). Pricing, payment, refund, events and booking history are therefore 0019's in every case. A calendar proposal that is replaced by a different one is withdrawn first.
- **Confirmed booking billed to an insurer.** Unchanged: 0019 does not take change requests on insurer bookings, so the 0020 path stays for them.
- **Car on rent, `extension`.** The preview also returns 0019's `app.preview_extension` (`extension_preview`) and its total; applying calls 0019's `app.request_extension`, so the extension is priced with its fee lines (young driver, additional driver, extras), emits 0019's events and is approved, paid and lapsed by 0019's functions.
- **Requests and offers.** Unchanged (`apply_now`, `resend_offer`).

New trigger `booking_change_requests_after` (function `app.booking_change_request_after()`): when a change request is applied, declined or withdrawn, the `booking_change_approval` task closes; when applied, the booking's open handover, delivery, return and collection jobs follow it (`app.booking_jobs_follow()`, also used by the calendar). A renter's own change request now moves those jobs too, which 0019 listed as not done.

## 4. The flaky owner portal test

"11 owners forms listings: J the portal lists the owner's three vehicles..." read the second vehicle of `app.owner_portal_vehicles`, which ordered by `vehicles.created_at` only. The three vehicles of one application are inserted in one transaction, so they share `created_at` (checked: one distinct value for three rows) and the order among them was whatever the plan returned. When the second and third swapped, the second vehicle's next checklist item read "Upfront payment" instead of "Ownership permit".

Fix: `vehicles.created_seq` (identity, insertion order) and `app.owner_portal_vehicles` ordering by `created_at, created_seq, id`; the checklist inside it orders by `sort_order, code`. The test was not changed. File 11 was run eight times on fresh copies of the database: 200 passed, 0 failed each time. `12_end_to_end.sql` asserts the order directly.

## 5. The end-to-end test

`supabase/tests/12_end_to_end.sql` (40 assertions) processes everything earlier files left, notes the last event, then drives:

1. a public request (`app.submit_booking_request`), offer, approval, agreement, signature, payment and confirmation; identity and coverage uploads approved;
2. handover (0020), a calendar extension on the car on rent (priced by 0019, young driver line included), its approval and payment, return, review, assessment, Check-in statement and Deposit settlement;
3. two charge lines added by hand, one with its record and one whose record is attached later (and then the same record set again);
4. a toll on a closed September booking, matched automatically and charged on a later-charge statement (0021);
5. a calendar resize of a confirmed booking (a change request from the calendar, agreed and paid by the renter) and a renter's own change request at no cost;
6. an owner application and a listing published through the pipeline (0022).

Then `app.process_events()` runs, and the test asserts: every event processed; one event per code, entity and kind; no recipient with two outbox rows (or a role with two digest lines) for one code and entity; no missing variable; for each renter the exact list of emails, one per action; the staff request notice once per customer service assistant; the owner application once to the applicant and once per sales assistant; the listing once to the owner; and a second run writes nothing. The last part runs each new job (not due, succeeded, already run, and the effect).

## 6. Shared documents

`README.md`, `docs/data-model.md`, `docs/permissions.md` and `docs/architecture.md` were rewritten or extended to cover migrations 0016 to 0024, from these change records.

## 7. Objects added or replaced

| Kind | Objects |
| --- | --- |
| Columns | `program_settings.housekeeping_hour` (3), `rate_limit_keep_hours` (48); `vehicles.created_seq`; `vehicle_listings.publish_scheduled_by`, `publish_error`; `booking_change_requests.source` |
| Functions added | `app.job_slot`, `app.job_rate_limit_purge`, `app.job_form_drafts_purge`, `app.job_lapse_extensions`, `app.sweep_listing_jobs`, `app.job_listing_sweep`, `app.schedule_listing_publish`, `app.publish_scheduled_listings`, `app.job_publish_listings`, `app.manual_charge_after`, `app.booking_jobs_follow`, `app.booking_change_request_after` |
| Functions replaced (same signature) | `app.calendar_preview_change`, `app.calendar_apply_change` (0020), `app.owner_portal_vehicles` (0022), `app.notification_payload` (0023; the 0023 body is now `app.ntf_payload_base`) |
| Triggers | `booking_line_items_manual_charge_notify`, `booking_change_requests_after` |
| Cron jobs | `carmacars-rate-limit-purge`, `carmacars-form-drafts-purge`, `carmacars-lapse-extensions`, `carmacars-listing-sweep`, `carmacars-listings-publish` |
| Data | `notification_catalogue.emitted_by` for `renter_extra_charge` names the new path |

No new table. Every new function is revoked from public, anon and authenticated and granted to `service_role`. `app.attach_audit()` is called at the end.

## 8. Existing test assertions changed

| File | Assertion | Was | Now | Why |
| --- | --- | --- | --- | --- |
| `05_jobs.sql` | "J without pg_cron the migrations schedule nothing; with it, ..." | 15 jobs | 20 jobs (adds the five of 0024) | New pg_cron jobs; runs only where pg_cron exists |
| `09_operations.sql` | "P with it: the booking moves at its stored rates, the difference is a line and a pending card charge, the task is closed" | An Admin's word moved the booking at once; the difference was a line and a `pending` card charge | Replaced by two: "P (0024) a change that costs the renter more is not agreed by word: the calendar's change request waits for the renter to agree and pay online" (`false/true proposed/staff_calendar/staff/13560 true`), then, after the renter agrees and the server applies with the payment, "P (0024) the renter agrees and pays online: the booking moves at its stored rates through 0019, the payment is the difference, the task is closed" (`true/3/32000/600/36160 extension:succeeded:13560 applied done`) | The calendar change now goes through 0019, where a change that costs more is agreed by the renter online and paid before it applies. Booking dates, days, rental charge, allowance and total are unchanged; the payment is recorded `succeeded` with the processor reference instead of a pending charge |

The 09 assertions that follow ("the return job follows the booking", the refund when it is moved back, the calendar extension of $135.60) pass unchanged. No other assertion changed. The flaky test was fixed in the function, not in the test.

## 9. Not done, and decisions to confirm

1. A staff proposal (from the calendar or 0019's `app.request_booking_change`) still sends the renter no email: 0019 emits nothing for `proposed`, and customer service obtains the agreement through the task. The catalogue's closest code, `renter_change_request_approved`, is worded for the renter's own request. A proposal email would need a catalogue entry.
2. An extension and its payment send both `renter_extension_confirmed` (0019) and `renter_payment_receipt` (0023). The catalogue says receipts cover extensions, so both are kept; the end-to-end test records it.
3. Insurer-billed bookings keep 0020's direct change path (0019 refuses change requests on them).
4. A hand-added line is emailed only once the Check-in statement exists; before that it goes on the statement.
5. The cron cadences (5, 10, 15 minutes) and the hours in the cron lines are part of each job, as in 0015; the housekeeping hour and the rate limit retention are settings.
6. pg_cron is not present where the tests run, so the five `cron.schedule` calls were not executed; every wrapper is tested directly.
