# 06. Field staff portal

Owner: workstream F. Routes under `src/app/field/`; features in `src/features/field-jobs/`. Needs `user_roles.role = 'field'`, an active `staff_profiles` row and two-step sign-in. Field staff are drivers and detailers. They see only their assigned jobs, from 36 hours before to 24 hours after (`field_job_details` view), and can change only the progress of their own jobs (`app.guard_field_job()`).

Sources: operating procedures 3, 4, 10, 12 (tracker), 16 (exit), 17 (photos), 18 (detailing); the Field Staff Agreement; Part 4 of the Rental Agreement.

## 1. Design rules for this portal

| Rule | Detail |
| --- | --- |
| Phone first, one hand | Single column, 56 px targets, primary button fixed at the bottom within thumb reach. On a desktop the same layout is centred at 480 px |
| One thing per screen | A checklist is a sequence of screens, each with one decision or one photo |
| Works on a bad connection | Photos queue on the device and upload in the background with a visible counter ("14 of 22 uploaded"). A job cannot be completed until the queue is empty. Typed answers autosave locally and to the server (`08-forms.md` section 3). The portal needs a connection to load a job; it does not need one for every tap |
| Outdoors | High contrast, no grey-on-grey, large numerals for odometer and fuel entry |
| Install | A web app manifest and icons so "Add to Home Screen" opens it full screen. No service worker caches personal data |
| No money, no prices | The portal never shows amounts except the deposit status (taken or not) and the card's last four for matching |
| Privacy | Licence photos taken at handover upload straight to the `identity` bucket and are never written to the phone's gallery (captured in the page, not with the camera app). The agreement requires staff to keep no copies |

## 2. `/field` Today

| Item | Detail |
| --- | --- |
| Purpose | Today's and tomorrow's jobs in time order |
| Layout | Day switch (Today, Tomorrow). Job cards: time, kind (icon and word), car (year make model, plate, colour), place with "Open in maps", renter first name for booking jobs, status. The next job is expanded |
| Buttons on a card | Acknowledge (`acknowledgeJob` -> `field_jobs.status = 'acknowledged'`, `acknowledged_at`), Start (`startJob` -> `in_progress`, `started_at`), Call CarmaCars (the fleet line; the incident line after hours) |
| Empty | "No jobs today." |
| Notices | A banner for a new or changed job since the last visit (in-app notice plus email `staff_field_job_assigned` or `staff_field_job_changed`) |
| Late | A job not acknowledged 2 hours before its time shows red for Fleet; the field staff member sees "Please acknowledge" |
| Licences to check (0162) | A section above the day switch, only when the licence front, back or selfie of a renter on one of the member's own jobs (today and the next 7 days) waits for a decision: one card per booking with **Review the licence**. The review is the office's (`review_verification_upload`: approve all, or reject an image with a reason the renter reads), recorded with the reviewer's role `field`; coverage proofs and the Protection Plan stay with the office. The same check is on the job page. See docs/changes/2026-10-25-field-licence-review.md |

## 3. `/field/jobs/[id]` Job detail

Header: kind, time, place, car, plate. For booking jobs: renter name and mobile (tap to call), drivers with licence number, class and expiry, card brand and last four, whether the handover is unattended. Then "Start" and the checklist for the job kind. A job outside its window, cancelled, or not assigned to the user returns the 404 page.

## 4. Handover checklist (`kind` handover or delivery; procedure 3)

Each row is one screen. "Stop" outcomes end the flow with "Do not release the car. Call CarmaCars." and create an urgent admin task (`blockHandover` with the reason).

| # | Screen | Input | Validation and stop rules | Stored |
| --- | --- | --- | --- | --- |
| 1 | Ready check | The system shows: identity verified for every driver, coverage confirmed, deposit taken, additional drivers accepted. Each is a green or red line read from the booking | Any red: Stop, with the reason. The field staff member cannot override. (The database also refuses `on_rent`.) | none |
| 2 | Car ready | Fuel full or charge 80% or more (yes or no), clean (yes or no), permit and insurance slip in the car (yes or no), extras ordered are in the car (list from the booking) | A "no" asks for a note and notifies Fleet; does not stop | `field_jobs.fuel_or_charge_ok`, `condition_reports.extras` |
| 3 | Is this the renter | Shows the renter's name. "The person in front of me is the renter named on the booking" | Must be yes. Wrong person: Stop | |
| 4 | Original licence | Take a photo of the original licence, front (in-page camera). Tick: name matches, photo matches the person, not expired | Any mismatch or expired: Stop. Seems unfit to drive: Stop (a separate "The renter seems unfit to drive" button on this screen) | `condition_report_photos (shot = 'licence')` in the `identity` bucket with 90-day retention; `condition_reports.licence_seen` |
| 5 | Each additional driver present | Same as 4 per driver; a driver not present is recorded as "not present" and may not drive until checked by staff later | | same |
| 6 | Card on File | "I have seen the physical card ending in [last four] in the renter's name" | No: Stop | `condition_reports.card_seen` |
| 7 | Odometer | Numeric keypad; a photo of the cluster is taken in step 10, and the typed value is compared with the last known reading | Lower than the last reading: confirm or correct | `condition_reports.odometer_km`, `bookings.odometer_out_km` |
| 8 | Fuel or charge | Slider in eighths for fuel, percentage for electric | Required | `fuel_pct`, `bookings.fuel_out_pct` |
| 9 | Keys and extras | Number of keys and fobs (stepper); extras handed over | Keys at least 1 | `keys_count`, `extras` |
| 10 | Photo set | Guided, fixed order, 21 shots plus damage close-ups (section 6) | All required shots present | `condition_report_photos` |
| 11 | Existing damage | The baseline and last return's damage list is shown on a car diagram; confirm each is still as recorded; add any new mark (location on the diagram, type, size, close-up photo) | Each D needs a close-up | `condition_report_damages` |
| 12 | Tracker | The system shows the tracker's last reading time. "Tracker in place and reporting" is ticked by the system when a reading is under 10 minutes old | Not reporting: Stop | `condition_reports.tracker_reporting` |
| 13 | Renter reviews | The renter is handed the phone: the Part 4 pickup column as a summary (odometer, fuel, keys, damage list with thumbnails) | | |
| 14 | Signatures | Renter signs on the screen; then the field staff member signs | Both required. Unattended handover (approved on the booking): the renter's signature is replaced by their uploaded photo set and the screen says so | `condition_reports.renter_signed_at`, `staff_signed_at`, `signature_requests`, `signature_records` |
| 15 | Hand over | "Hand over the keys" | `completeHandover` -> `app.complete_handover()` **[new]**: finalizes the pickup `condition_reports` row, sets the booking `on_rent` (the database checks every precondition, sets `handed_over_at`, the vehicle `on_rent`, and the owner control block), sets the job `done`. Emits `renter_rental_started`, `owner_rental_started`, `staff_handover_done` (digest) and creates the fleet `review_photos` task | |

Self-Managed vehicle: the owner performs steps 3 to 14 from `/owner` with the same checklist component (`performed_by_role = 'owner'`); Fleet then enables the car for the booked period.

## 5. Return checklist (`kind` return check-in or pickup from renter; procedure 4)

| # | Screen | Input | Stored |
| --- | --- | --- | --- |
| 1 | Car and keys received | "I have the car and all keys." The moment this is confirmed is Check-in; the time is stamped by the server | `bookings.checked_in_at` on completion; `condition_reports.performed_at` |
| 2 | Odometer | Keypad; the app shows kilometres driven and the allowance | `odometer_km`, `bookings.odometer_in_km` |
| 3 | Fuel or charge | As at pickup; the app shows the difference | `fuel_pct`, `bookings.fuel_in_pct` |
| 4 | Keys and extras | Count; anything missing | `keys_count`, `extras` |
| 5 | Cleanliness | Choose: standard, needs cleaning, heavy soiling or odour, pet hair, smoking evidence. Anything beyond standard needs photos before cleaning | `condition_reports.cleanliness`, `odour`; `field_jobs.cleaning_grade` |
| 6 | Photo set | Same 21 shots, same order | `condition_report_photos` |
| 7 | Compare with pickup | Shot by shot, the pickup photo beside the new one. For each pickup damage: unchanged or worse. "Add new damage": location, type, size, close-up | `condition_report_damages (is_new = true)` |
| 8 | Belongings | Anything left in the car: describe; bag and label with the booking number | `field_jobs.belongings_found` |
| 9 | Renter reviews and signs | Summary of the return column and any new damage; the renter signs; a renter who disputes a finding can write a note first (`condition_reports.notes`); a renter who refuses to sign is recorded as "declined to sign" with the reason. Unattended return: no renter signature; the inspection must be done by noon the next business day | `renter_signed_at`, `renter_present`, `unattended` |
| 10 | Staff signs and completes | `completeReturn` -> `app.complete_return()` **[new]**: finalizes the return report, computes `minutes_late`, sets the booking `returned` (the database ends the owner control block, moves the vehicle to `cleaning`, sets the deposit release date, computes the split), sets the job `done`. Emits `renter_return_complete` and creates the fleet `review_photos` and `schedule_detail` tasks. Any new damage opens an incident (`kind = 'damage_at_return'`) and an urgent admin task | |

Escalate (one tap on any screen): car left somewhere else, tracker tampering, renter disputes a finding, any damage.

## 6. The photo set

| Seq | Shot (`condition_report_photos.shot`) | Guide overlay |
| --- | --- | --- |
| 1 | `front` | Outline of a car front; "Stand 3 metres back, whole car in frame" |
| 2 | `front_left` | Corner outline |
| 3 | `left` | Side outline |
| 4 | `rear_left` | |
| 5 | `rear` | |
| 6 | `rear_right` | |
| 7 | `right` | |
| 8 | `front_right` | |
| 9 | `roof` | "From the rear corner, phone held high" |
| 10 | `windshield` | |
| 11 to 14 | `wheel_front_left`, `wheel_front_right`, `wheel_rear_left`, `wheel_rear_right` | Wheel circle |
| 15 | `instrument_cluster` | "Ignition on. Odometer and warning lights readable" |
| 16 | `front_seats` | |
| 17 | `rear_seats` | |
| 18 | `trunk` | |
| 19 | `keys` | "All keys on the seat" |
| 20+ | `damage_closeup` (one per D, linked by `damage_id`) | "Include a coin or key for scale" |

Capture behaviour: landscape is requested; a portrait photo is accepted with a nudge. Each photo is checked in the browser for size (at least 1600 px on the long side), blur (edge variance) and darkness (mean luminance) and offered a retake; the staff member may keep it. The server stamps `taken_at`; the device time and GPS position, when the browser grants them, are stored in the photo's metadata record for evidence. Photos are resized in the browser to 2400 px on the long side at JPEG quality 85 before upload, direct to R2 with a signed upload link per photo (`13-security.md` section 7), path `bookings/{booking_id}/{pickup|return}/{seq}-{shot}.jpg`. A shot can be retaken until the report is signed; after that it is fixed.

## 7. Other job kinds

| Kind | Checklist | Completion |
| --- | --- | --- |
| `detail` (procedure 18) | 1 Photograph anything beyond a standard clean and choose the grade. 2 Belongings bagged and labelled. 3 Exterior washed and dried, wheels, glass, mirrors. 4 Interior vacuumed and wiped, glass, no odour. 5 Washer fluid, tire pressures, warning lights (a light on: note, photo, Stop and tell Fleet). 6 Fuel full or charge at 80% or more. 7 Items in the car: permit, insurance slip, charging cable, spare, tools, extras for the next booking. 8 Four "ready" photos: front, rear, front seats, instrument cluster | `completeDetail` -> `condition_reports (kind = 'ready')` with the four photos, `field_jobs.cleaning_grade`, `fuel_or_charge_ok`, job `done`; Fleet's review moves the vehicle `cleaning -> available` and ends the cleaning block. Damage or a warning light moves it to `out_of_service` |
| `photo_shoot` (procedure 17) | The listing capture of `09-listing-pipeline.md` section 4 (14 shots in daylight, landscape, plain background) and a baseline Condition Report | `submitListingCapture` |
| `tracker_install` (procedure 12 step 10) | Scan or type the device serial; install; the app polls for the first reading; test screens for Locate, Lock, Unlock, Alarm and Shut-off while parked (each sends a command through the server and waits for confirmation) | `completeTrackerInstall` -> `tracker_devices (vehicle_id, status = 'installed', installed_at, installed_by, tested_at)`, `tracker_commands (reason_code = 'install_test')`, onboarding `tracker_installed` |
| `tracker_removal` (procedure 16) | Remove device; record odometer; exit photo set | `completeTrackerRemoval` -> `tracker_devices.status = 'removed'`, `vehicle_exits.tracker_removed_at`, `exit_odometer_km`, `condition_reports (kind = 'exit')` |
| `registry_run` | Place, time, documents to carry (list), upload of the new permit photo | `completeRegistryRun` (Fleet records the registration) |
| `recovery` | Place from the tracker, instructions; photos on arrival; the repossession rules shown on the first screen: peacefully, from a street, driveway or open lot; never by force, never from a dwelling or locked garage | `completeRecovery`, then the return checklist |
| Vehicle swap (procedure 10) | Return checklist on the old car (`swap_out`), handover checklist on the new car (`swap_in`) | Two reports linked to one booking |

## 8. `/field/list-a-car`

The listing capture for a car in front of the staff member: VIN scan or type, plate, the 14 listing photos. Allowed with or without a `photo_shoot` job; without one it creates a draft that Fleet attaches to an owner. Detail in `09-listing-pipeline.md` section 4.

## 9. `/field/report`

| Label | Type | Validation | Stored |
| --- | --- | --- | --- |
| Vehicle | select: the vehicles of today's jobs | Required | `incidents.vehicle_id` |
| What happened | select: new damage found, warning light, collision while I was driving, ticket or toll while I was driving, lost property found, something else | Required | `incidents.kind` or a `tasks` row |
| Details | textarea | Required, 10 characters or more | `incidents.description` |
| Photos | up to 10 | Required for damage | `documents` linked to the incident |
| Anyone hurt | yes or no | Shown for a collision. Yes shows "Call 911 now" above everything | `incidents.anyone_hurt` |

`submitFieldReport` creates the incident with `staff_user_id` set when staff had the car, an urgent `fleet` task and, for a collision or injury, an urgent admin task and `staff_approval_needed` at once. A toll or ticket report pre-creates a `toll_tickets` row matched to staff (`10-tolls-tickets-damages.md` section 5).

## 10. `/field/referrals` and `/field/profile`

| Route | Content |
| --- | --- |
| `/field/referrals` | The staff member's referral link and QR code (`staff_profiles.referral_code`); kickbacks from `referral_kickbacks` (own, read): booking month, amount, status, payroll period. Rule text: 20% of the rental charge on the first completed rental of a renter you referred |
| `/field/profile` | Name, phone, password, two-step sign-in, licence expiry reminder (staff record), sign out everywhere |

## 11. States and edge cases

| Case | Handling |
| --- | --- |
| Connection drops mid-checklist | Answers and photos stay on the device; a banner shows the queue; completion waits for the upload |
| Phone dies | The job reopens on any device at the last saved screen (server draft) |
| Renter is not there | "Renter not here" after 15 minutes: notifies Fleet; the job stays open; no-show is a staff decision |
| Camera permission denied | Instructions for enabling it, and a file picker fallback |
| Two staff on one job | Only the assignee can write; Fleet reassigns |
| Wrong car | The checklist's first photo screen asks to confirm the plate shown; a mismatch stops the job |
| Job time changed by Fleet | In-app notice and email; the card shows "Changed" until acknowledged again |

## 12. Database additions needed

| Addition | Purpose |
| --- | --- |
| `app.complete_handover(p_job uuid, p_report jsonb)`, `app.complete_return(p_job uuid, p_report jsonb)` executable by `service_role`, called by a server action after checking the job belongs to the user | One transaction for report, booking status and job |
| `condition_report_photos`: `device_taken_at timestamptz`, `latitude`, `longitude`, `width`, `height`, `quality_flags jsonb` | Evidence and quality |
| `condition_reports`: `renter_declined_to_sign boolean`, `renter_decline_reason text`, `car_diagram jsonb` (damage positions) | Section 5 |
| `condition_report_damages`: `kind text`, `size_cm numeric`, `position jsonb`, `status_vs_pickup text` | Sections 4 and 5 |
| Licence photos at handover: allow `condition_report_photos.storage_bucket = 'identity'` with a purge date, or store as `documents (kind = 'id_front')` linked to the condition report | Retention of ID images taken in person |
| Field insert policy on `incidents` through server action only (no direct policy) | Section 9 |
