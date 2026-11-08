# Release 33, part G: one-step Hire, the academy gate on, the Claude connector as the Admin (0730 to 0732, 0739)

Branch `r33-g` from main (r32). Migrations 0730 (one-step Hire, pay details, academy enrollments), 0731 (the academy gate
on, the new sections), 0732 (the connector's Admin actions), 0739 (the guide chapters). SCHEMA_MARKER 0739.

The owner is about to pick hires and wants onboarding easy. Before: Hire sent only the invitation (the "next steps" email
went separately from the decision emails), then the agreement was sent by hand, pay was recorded by hand with no pay
details collected, the academy gate shipped off and its content predated r28, and the connector could only read and
lightly edit bookings, requests and owners.

## 1. One-step Hire (0730)

- **Admin > Hiring > the candidate > Hire** opens one short form: the role (customer service, fleet, finance, Sales in
  person, Sales remote, field work), the start date (tomorrow by default) and the pay, filled with the role's standard
  (`app.hire_standard_pay`): the hiring role's posted pay when it is the role's own function (US$ a month for the
  assistants), else the agreement defaults of Program settings (US$ a month by function; CA$ an hour for field work);
  Sales is commission only, with the tier rule of its work mode (in person 10/15/20%; remote 5/10/15%, one tier lower
  after a month under the minimum, never under 2.5%). Editable, then **Confirm: hire and start onboarding**.
- One confirm, as the Admin (`web/src/server/hire.ts`, `oneStepHire`):
  1. the staff sign-in and its invitation email (the existing invitation, moved to `server/invite.ts` so the connector can
     call it as the key's Admin; the screen's `inviteAccount` still checks the Admin first);
  2. `app.hire_onboard`, one transaction: the staff profile (start date, hourly rate for field, sales work mode); hired
     (`app.hiring_hire`, with the rubric's decision trigger held so it no longer refuses a candidate whose rubric said
     something else); the interview items closed (a future call slot freed, an open AI interview link expired, the
     candidate's open To do's done); the welcome email `applicant_hired` once, with the next steps and the pay details
     link in its personal line; the academy enrollment of their paths with the gate on; five first-day To do's assigned
     to the hire, due 9:00 Toronto time on the start date (sign in and two-step, the agreement, pay details, the academy,
     the guide), and one for the Admins;
  3. the staff agreement generated from the record with the Hire form's pay and start date and sent to sign in their
     portal (the existing e-signature flow). A field hire's agreement needs their home address and licence number: the
     step waits for them, and **Send the agreement** on the card sends it once they are in.
- **Pay details** (`staff_payout_accounts`): the hire enters them in Profile > Pay details (bank account, GCash, PayPal,
  Wise, e-Transfer or through OnlineJobs.ph). The account number is encrypted in the web layer like an owner's
  (`encryptField`), only the last 4 digits are ever shown (`app.staff_payout_masked`), the table has no grant to
  browsers and its audit rows are redacted. A new entry raises "Verify new pay details" for the Admins; **Verify** on the
  card records how they were checked.
- **The Onboarding card** (`app.hire_status`) on the candidate shows each step Done, Waiting or To do: sign-in (signed in
  yet or not), agreement (sent, signed, or what it waits for), pay details (entered, verified), academy (sections passed
  per path), first-day To do's, hired.
- Hire again is safe: no second email, no second set of To do's.
- Staff Sales: the staff portal has no hiring pages (applications are Admin only), so nothing to mirror there; Sales
  staff are hired, not hiring.

## 2. The academy (0731)

- The gate is on by default and on now (`academy_gate`). A section opens only once the one before it is passed (as
  before), and a staff member who has not passed their paths opens only the academy, the guide and their profile.
- Who is held is per enrollment (`academy_enrollments`, `lock_from`): a hire from one-step Hire is held from the start;
  every staff member already working was enrolled with a week before the hold starts, so nobody is shut out mid-shift by
  the new sections. Lessons watched, quizzes passed and sections opened early are kept. Admins are never held.
- Four new sections at the end of each path, written from the change records of releases 28 to 32: "New since release
  28: bookings, handovers and returns" (customer service, both Sales, fleet, field, Admin), "... licences, photos and
  agreements" (customer service, both Sales, field, Admin), "... money" (finance, Admin), "... cars and listings"
  (fleet, Admin). 9 lessons, 20 quiz questions (at least 5 a section). Every path has at least one.

## 3. The Claude connector as the Admin (0732)

- `/api/mcp` adds 6 reads (`get_settings`, `list_cars`, `get_car`, `list_applicants`, `get_hire_status`, `list_staff`)
  and 22 writes, each one door action of the Admin screens run as the key's Admin (aal2) with the same database checks:
  bookings (`send_offer`, `create_offer`, `revise_offer`, `withdraw_offer`, `change_booking`, `change_booking_fees`,
  `record_payment`, `request_refund`, `cancel_booking`, `record_handover`), cars (`set_car_rates`, `set_car_fee`,
  `publish_car`, `unlist_car`), owners (`change_owner_terms`, `issue_owner_invoice`, `void_owner_invoice`,
  `resend_owner_invoice`), staff (`hire_applicant`, `set_staff_functions`, `end_staff_access`, `verify_staff_pay_details`).
- Every write is two calls. Without `confirm` it is a preview: the action runs inside a savepoint that is always rolled
  back, so it passes or fails every check the screen would, and answers the record before and after, the fields that
  would change and a `preview_id` (`api_previews`, 10 minutes). With `confirm: true`, the `preview_id` and the same
  arguments it is done; the database refuses a confirm without its preview, with other arguments, too old or used.
  `hire_applicant` previews with `app.hire_preview`; its confirm runs one-step Hire in the web layer as the Admin and
  logs the outcome (`server_api_hire_result`).
- New scopes `admin:read` and `admin:write`. Keys and connections that had every scope (full access) got them; keys with
  fewer scopes are unchanged. The rate limit and the call log are those of 0562 (a preview is logged as
  `<tool>:preview`).
- Admin > Settings > API access: a one-line **Connect from Claude** (custom connector URL https://carmacars.ca/api/mcp).
- Tests: `web/tests/e2e/mcp-connector.spec.ts` (initialize, the initialized notification, tools/list, a read, a preview
  that changes nothing, a confirm without the preview refused, the confirm, the reuse refused, the log) against the route
  with a test key; `tools.test.ts` checks that every write tool is two-step and that the tool list matches the
  database's.

## Tests

`supabase/tests/99_r33_hire_academy_connector.sql` (49 assertions: standard pay, preview, onboarding in one call, the
card, idempotence, pay details masked and verified, the gate and the week, the new sections and the order, the
connector's preview, confirm, reuse, scopes, log, a refused action at the preview, a hire through the connector),
`features/careers/hire.test.ts`, `features/staff/pay-details.test.ts`, `features/api-access/tools.test.ts`.

## Guides

- `admin/hiring`: one-step Hire, the form, the onboarding card, Send the agreement, Verify.
- `admin/academy`: the gate on, the week for existing staff, the new sections.
- `admin/settings`: API access, Connect from Claude, previews then confirms, the Admin scopes.
- `va/start-here`: Pay details at the first sign-in.
- `va/academy`: the gate on, the newest section.
- `field/academy`: the rest of the portal waits until the path is passed.
- `field/report-rentals-referrals-and-profile`: Pay details on the profile.
