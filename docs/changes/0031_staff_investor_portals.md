# 0031: the staff and investor portals' door

Migration `supabase/migrations/0031_staff_investor_portals.sql`, tests `supabase/tests/18_staff_investor_portals.sql` (45 assertions). Builds on 0001 to 0030. No earlier migration was edited; one function of 0030 (`app.admin_begin`) is replaced, with the same behaviour for an Admin.

The web app's assistant portal (`/va`), field portal (`/field`) and investor area (`/investor`) reach the database only through `public.door`, as the service role, with the signed-in user's id and the assurance level of their session. No business rule is added or copied: every screen and action is an existing function (0016 to 0030) or 0030's admin screen run with the assistant as the actor, so the earlier guards decide.

## Functions

| Function (`app`; `public.door` and `public.my_roles` for the service role only) | Does |
| --- | --- |
| `door(user, aal, call, name, p)` | One entry point. `door_begin` makes the user the acting user (`request.jwt.claim.sub`, and `aal` in the claims, so `app.session_aal()`, `app.is_admin()`, `app.va_has()` and every guard see the second factor), then refuses a staff session without `aal2` while `program_settings.require_staff_two_step` is on. Calls: `roles`, `admin_list`, `admin_read`, `admin_save`, `admin_do`, `va_list`, `va_read`, `va_do`, `field_read`, `field_do`, `investor_read`, `investor_do` |
| `my_roles(user)` | Admin, the assistant's function, field, owner, renter, investor, staff, whether two-step is required, name: the routing after sign-in |
| `admin_begin(admin)` (replaced) | As in 0030, and also accepts an assistant when `va_do`, `va_read` or `va_list` marked the transaction for that user (`app.door_va`) after its own allow-list check |
| `va_list(user, rel, p)` | An allow-list of tables and views per function (finance, fleet, cs, sales); tasks are always the function's own queue, Sales sees only requests and offers, quick replies only active ones; then 0030's list reader |
| `va_read(user, what, p)` | `queue`, `task`, `digest` (today), `booking` (Fleet and Sales without money; nobody with processor identifiers; Fleet sees first names), `requests`, `booking_preview`, `quote_vehicles` (cs, sales), `calendar` (first names only and no moves or Turo trips for cs and sales), `calendar_preview`, `listings`, `listing`, `vehicle` (without owner terms, fees, owner contact or bookings), `tolls`, `toll`, `toll_profile`, `reconciliation` (finance), `finance_board` (failed payments, deposits to take and due back, refunds, cancellations with a refund to request, failed owner invoices, draft statements), `fleet_board` (field staff, jobs of the next three days, handovers and returns without a job, expiry watch, vehicle documents), `verification` (identity documents of one booking: only while customer service has an open `verify_renter` or `chase_verification` task on it; each opening written to `data_access_log`), `messages`, `owner_leads` |
| `va_guard_booking_edit(fn, p)` | An assistant never overrides a price (rates, typed rental charge, staff discount, Deposit, fee terms, the calendar switch); Sales may not price coverage; an assistant's offer is open 48 hours at most |
| `va_do(user, action, p)` | The task sheet (`task_take`, `task_done`, `task_wait`, `task_escalate`, `task_handover`, `task_note`); `verify_upload` (0019's `review_verification_upload`, from an open review task); `send_message` (checked against `staff_blocked_terms`, shown to the renter in the portal); `lead_update`; `request_refund` (Finance: inside the Single Limit and the cancellation table the assistant may approve it; anything else raises an escalated `approve_refund` Admin task and `staff_approval_needed`); `field_job_assign`, `field_job_reschedule`, `field_job_cancel`, `submit_findings` (Fleet); and an allow-list of 0030's admin actions per function |
| `field_read(user, what, p)` | `jobs` (today, tomorrow, open moves, cars of their jobs), `job` (their own, inside the 36-hour window of `field_job_details`: car, renter name and mobile, drivers' licences, card brand and last four, the ready check with the Deposit as taken, waived, declined or not taken, the Tracker reading, the required photo list, the report so far with its problems, the pickup readings and damage to compare, the last recorded damage) |
| `field_do(user, action, p)` | `acknowledge`, `start`, `save_report`, `complete_handover` (the Tracker check is the server's, never the phone's), `complete_return`, `block_handover`, `move_start` (a car of one of their jobs), `move_end` (their move), `late_damage` |
| `investor_read(user, what, p)` | `home`, `statements`, `statement` (another investor's reads as nothing), `documents`: only for a user who is an active or exited investor |
| `investor_do(user, action, p)` | `election_change`, `bank_change` (no account details online), `transfer_request`: each an `investor_request` Admin task; nothing changes until an Admin records it |
| `tracker_reading(vehicle)`, `field_job_of`, `field_report_kind`, `va_fn`, `va_delegate`, `va_booking`, `investor_of`, `staff_message_problem`, `refund_approval_resolve` | Helpers |

## Columns and rows

- `program_settings.staff_blocked_terms text[]` (default empty): words a staff message to a customer may not contain (05-va.md section 6).
- `task_rules`: `approve_refund` (admin, high, 120 opening minutes, procedure 7) and `investor_request` (admin, 2 business days).
- Trigger `refunds_approval_resolve`: the `approve_refund` task closes when the refund leaves `pending_approval`.

## Web app

`src/server/door.ts` (the door, roles, routing, gates); the admin portal now goes through the door as well (`admin_list`, `admin_read`, `admin_save`, `admin_do`), so its session's second factor reaches the database. The shared working screens (`Act`, `BookingReview`, `MasterCalendar`, `ListingReview`, `TollImport`) take their actions from `DoorProvider` (`src/features/admin/door.tsx`): the Admin's or the assistant's. Two-step sign-in: Supabase Auth TOTP (`mfa.enroll`, `mfa.challengeAndVerify`; the local stand-in implements RFC 6238 in `local_auth.factors`), pages `/two-step/setup` and `/two-step`.

## Decisions

1. One door with a call name instead of a public wrapper per portal: the assurance level is passed once and set once.
2. An assistant reuses 0030's dispatcher for allowed actions instead of copies of each branch; the transaction mark (`app.door_va`) is set only by the 0031 functions after their allow-list and only for that user.
3. An assistant's identity review requires an open review task on the booking, which is the "only within their review task" rule; the images are one-minute signed links and never cached.
4. A refund request above the Single Limit is recorded as the refund row the guards already know (`pending_approval`) plus an escalated Admin task; nothing new holds money.
5. An investor's bank change is a call-back request: no account number is typed into the area.
6. The renter sees a staff reply as an in-app notice only when the catalogue has `renter_staff_message`; until then the reply is kept on the booking's messages.

## Not done, or not verified

- Not built: the scorecard, the reconciliation and Turo trips screens for Finance, the Fleet daily checks form, the photo review side-by-side viewer and "Ask for a re-shoot", late-return panel buttons (T13, T14), "Find a renter" lookup, Sales quotes (`/va/sales/quotes/new`), detail, photo shoot, tracker, registry and recovery checklists in the field portal, `/field/report`, `/field/referrals`, `/field/profile`, the investor statement PDF and yearly ZIP, a web app manifest for the field portal, realtime subscriptions (the queue is read again every 30 seconds).
- An assistant with two functions is not possible with one `staff_profiles` row (the switcher of 05-va.md section 1 is not built).
- Two-step sign-in for investors is offered, not required.
- The two-step switch's enforcement is tested in the database (18) and the door; the end-to-end tests do not turn the switch on, because it is one setting for every staff member and the tests run in parallel.
