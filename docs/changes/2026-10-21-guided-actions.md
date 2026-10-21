# Guided actions: Insurer confirmed, renter documents, Admin > Today as prompts (October 21, 2026; migration 0077)

The owner's standing rule: "admins and staff must never hunt through menus or remember processes". Every recurring task is
prompted to the right person at the right moment and done in one small pop-up, pre-filled, on Admin > Today and on the
record itself. This release closes groups A (handover blockers) and B (guided To do and task hygiene) of the audit of
October 21, 2026.

## 1. Insurer confirmed (handover blocker)

Before: no screen marked a car insured. 0070 refused the handover of a car in onboarding and told staff to "confirm it in
the car's onboarding (Insurer confirmation, then the enrollment)", a screen that did not exist. The generic Change status
left `vehicles.on_fleet_policy` false. 7 of the 8 real cars were waiting.

| | What it does |
| --- | --- |
| Action | `app.confirm_fleet_policy` (door `insurer_confirm`): an Admin or fleet; a date (default today, never in the future) and an optional reference |
| Onboarding | Moves to "on the fleet policy", then "enrolled" (new transitions from every step after the terms; the step it was at is kept in `insured_before_paperwork_from`) |
| Car | `on_fleet_policy` true, `fleet_policy_added_on` and the Enrollment Date set to the date; a car still in onboarding becomes ready to list (Available when listed); a car already Available stays Available |
| Owner | The enrollment notice the flow already sends at enrollment (T22, "Written confirmation: your car is on the fleet policy") |
| Paperwork | Agreements, registry visit and tracker stay open on the checklist until really done |
| Record | `audit_log` action `insurer_confirmed` with the date, the reference and the step it came from; the tasks that waited for it close |
| Several cars | `app.confirm_fleet_policy_bulk` (door `insurer_confirm_bulk`): one insurer email, several cars; each car on its own, one that cannot be marked is named with the reason |
| Where | Admin > Today (one line per car, plus "<n> cars wait for the insurer" with Mark several insured); the car's Overview (Insurer confirmed) and its Listing checklist item |
| On the policy | `app.vehicle_on_policy`: a program owner's car with an onboarding is on the policy only once the insurer confirmed it (a listed car never confirmed, like the Malibu, is no longer handed over by mistake) |
| Texts | The checklist, the car's listing state, the booking warning and the handover refusal now name the button Insurer confirmed |

## 2. Renter documents without a task

The Admin could not approve a proof of coverage or an online ID (only `/va/verify`, customer service, with an open
review task). Now `app.doc_review_read`, `doc_review_upload`, `doc_review_coverage` and `doc_review_plan` let an Admin,
or customer service, review the licence images, the selfie, the proof of coverage and the Protection Plan of a booking
with no task. Customer service sees a booking being arranged or under way, or one with a document waiting. Every opening
is logged in `data_access_log`. The pop-up (`features/admin/DocumentReview.tsx`) is on the booking (card Renter documents,
Overview and Drivers and documents) and on Admin > Today ("Check <renter>'s documents for booking <number>"). The
assistants' `/va/verify` screen and its actions follow the same rule.

## 3. Admin > Today as prompts

`app.todo_prompts` (in `admin_todo` as `prompts`): one line per piece of work, "Now", "Today" or "When you can", with what
to do and why, each with its pop-up. A line is computed from the records, so it disappears when the work is done.

| Prompt | Pop-up |
| --- | --- |
| Insurer has not confirmed <car>: mark it insured | Insurer confirmed (date, reference) |
| <n> cars wait for the insurer | Mark several insured: every waiting car ticked, untick the ones not confirmed |
| <car> is not on the site: check its rates and publish it | Rates (the car's, or the suggested daily rate with where it comes from) and Publish now in one step (`todo_publish`) |
| Check <renter>'s documents for booking <n> | The document review |
| <name> asked for a person in live chat <LC-n>: reply | Opens that chat |
| Answer <renter>'s request for <car>, <dates> | Opens the review and offer |
| <renter> asked to change booking <n>: approve or decline | Approve, Decline with a reason, Details |
| Decide <owner>'s owner application (<cars>) | Opens the application |
| <INV-n> from <owner>: <amount> waiting for payment | Record payment (e-Transfer, cash, cheque, bank transfer), the balance filled in |
| Draft <INV-n> for <owner>: send it or void it | Opens the draft |
| <owner> has not signed <n> documents sent <date> | Record paper signature (sent two days ago or more) |
| Check the official form <form> and use it for owners | Checked: use for owners (`form_verify`), Preview it |
| Check the plate on <n> photos of <car> / Add real photos of <car> | Open the car's listing |
| An Admin task, or an assistant task while nobody real holds the function | Its own pop-up when one is registered (`features/admin/todo/registry.tsx`), else the general one: why, Go to where it is done, Done, Later |

The counts that each have a prompt per record (applications, requests, changes, plates, sample photos) are not repeated
below the prompts; the other counts stay. Plates no longer counts sample cars; sample photos counts real cars only and
points at the car.

A task type gets its own pop-up by adding one line to `TASK_PROMPTS` in `web/src/features/admin/todo/registry.tsx`, for
example the first and last month invoice choice (`first_last_decide`, raised in the admin queue). Until then that task
opens the owner's Terms tab.

## 4. Nobody real on staff yet

`app.va_function_staffed`: a real, active assistant holds the function (their own or one they cover). The live
verification's accounts (verify-...@carmacars.ca and the Admin test addresses) do not count.

- Assistant-queue tasks (customer service, sales, finance, fleet) show on Admin > Today while nobody real holds that
  function, with the reason.
- Staff emails and digest lines for those functions also go to the Admin (an allowed Admin address, rent@carmacars.ca),
  and their link opens Admin > Today (`notification_recipients` and `notification_payload` wrapped).
- Task links: a chat waiting for a person opens that chat (`/va/chat?id=`, `/admin/chat?id=`); a Protection Plan request
  opens the review; Admin > Tasks has a link per task to where its work is done (`adminTaskHref`).

## 5. Tasks close by rule

| Rule | How |
| --- | --- |
| An upfront invoice voided or paid closes its collection task (also a failed debit or arrears task) | Trigger `owner_invoices_tasks_close` |
| A day's opening and closing checks close when the day is over | `app.job_task_hygiene` (hourly, pg_cron `carmacars-task-hygiene`) |
| A live chat task closes when the chat is answered, handed back or closed | same |
| "Fleet is below the franchise minimum" closes once the count is above the warning level, and shows only while true | same, and the prompt |
| "List the new vehicle" closes once the car is listed; a car out on rental without confirmed insurance closes when insured | same |

The migration runs the sweep once: the 8 collection tasks of the voided INV-1044 to INV-1051, the past opening and
closing checks, the closed chat's task and the franchise minimum task (if the count is above the warning level) close.

## 6. Labels

The management fee reads "Revenue Share (management fee)" on the Admin car page (Who supplies the car, Owner terms).

## Guides

Admin: To do (the prompts), Renter documents, Publish, Mark a car insured (Insurer confirmed), Why a car is not on the
site, Sample photos, Add a rental by hand (the handover needs Insurer confirmed), Paid and signed (the To do lines), Live
chat, Official forms, the duplicate flag wording, and the quick reference (Publish a car, Mark a car insured, Check renter
documents). Assistants: To do (each task opens where it is done; tasks close by themselves) and Check renter documents.
Published by the migration's guides block (`supabase/seed/0077_gen_guides.mjs`, base 4ff90d1).

## Tests

`supabase/tests/52_guided_actions.sql` (43 assertions); `supabase/tests/50_coverage_proof.sql` follows the review with no
task; `web/src/features/va/tasks.test.ts`; `web/tests/e2e/guided-actions.spec.ts` (each pop-up at 375 and 1440).

## Not done here

- The amounts each owner actually paid for the first and last month (needs the owner's numbers; group C).
- `program_settings.company_address` (group C). The first and last month choice pop-up itself (the owner signing work).
