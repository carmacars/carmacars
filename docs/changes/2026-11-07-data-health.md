# Data health: the database checks itself every night, and test accounts never get real work (0440, 0441, 0442)

Release 27. The owner: "make sure there isnt more shit like that. i shouldnt be spotting this myself, u should be telling
me this and fixing it urself." What he had found in production: two real website owner leads credited to the deploy
verification's test accounts ("Verify Invitation", "Verify Sales") with their follow-ups stopped and nobody in touch;
"Verify ..." accounts in staff lists and as task assignees; bookings whose cars went out still "confirmed" or "expired",
a confirmed booking of October 25 to 27 never closed; a sales assistant's To do with duplicate tasks and "Offer expiring
soon" for cars already out; licence reviews waiting a week; published cars with no seats.

## 1. Test accounts fenced off at the source (0440)

The live verification (`web/scripts/verify-live.mjs`) signs in as `verify-<name>@carmacars.ca` accounts and invites a
throwaway `delivered+verify-invite-<n>@resend.dev` staff member, which it deletes afterwards. Its clean-up deletes the
user row, which fails while a real record (a task, a lead) points at it: most likely how "Verify Invitation" stayed on
staff lists. These accounts stay usable by
the checks; nothing real is routed to them any more.

- `users.is_test`, generated from the address: `verify-<name>@carmacars.ca` or any `@resend.dev` address.
  `app.is_test_email`, `app.is_test_user`; 0078's `app.staff_is_test` now means the same (it missed the invitation's
  resend.dev account).
- `owners.is_test` is set for a test account's owner record (a trigger, and once now), so every existing exclusion of
  test owners applies (statements, debits, To do, referral codes).
- A record is a test record when its subject is (`app.subject_is_test`, `app.row_is_test`): the booking's renter, the
  owner, the renter, the lead's or chat's address, the vehicle's owner, or the job applicant. A record with no subject is a
  test record only when a test account made it.
- **The fences** (`app.fence_test_accounts`, a BEFORE trigger on each column that routes work or credit to a person):

  | Where | Column | A test account on a real record |
  |---|---|---|
  | tasks, leads, field jobs, live chats, live-map visitors | `assigned_to` | taken off; the record goes back to its queue (an in-progress task goes back to open) |
  | bookings | `sales_staff_id`, `referrer_staff_id`, `sales_claim_by` | taken off, with `sales_sourced`, `referrer_type` and `sales_claim_at` |
  | owner applications | `sourced_by` | taken off |
  | interview scores | `interviewer` | taken off |
  | request claims, staff commissions, referral kickbacks, sales touches | the person | the row is not written |
  | in-app notices, notification emails and texts, phone texts, push alerts | the recipient | not written (the verification Admin's still are: its email is suppressed, 0036) |

  Only a value that changes to a test account is looked at, so old rows never block an unrelated update. The
  verification's own records (its request as `delivered@resend.dev`) can still go to its own accounts.
- **The choosers** skip test accounts: the least busy sales assistant for a buyer, finance, detailing or body shop lead
  (`submit_lead`), the least busy driver for a field job (`field_auto_assignee`), the phone's on-duty assistant
  (`phone_on_duty`, `phone_fn_held`), "is the function staffed" (`va_function_staffed`, through `staff_is_test`).
- **The lists**: the staff picker (`staff_directory`; a test account still sees itself), the sales credit picker
  (`sales_staff_options`), the sales team report (`team_sales`) and Settings > Sales (`sales_modes_admin`) leave them out.
  **People > Portals and view as** keeps them (the verification opens each portal as one) and labels them "Test account".
- **Live map and visitor history**: a test account's visit is excluded (`exclude_reason` `test`).
- **Leads**: a lead from a test address is closed at once ("Test account"), with no follow-up.

### The audit: where test accounts could reach real work

| Area | Found | Now |
|---|---|---|
| Task assignment and round-robin | request claims gave a real request's task to whoever opened it, test accounts included; `staff_is_test` missed resend.dev | fence on `tasks.assigned_to` and `request_claims`; `staff_is_test` covers every test account |
| "Sourced by" and commissions | sales credit, referrer and claim on bookings, `owner_applications.sourced_by`, commissions and kickbacks had no check | fenced; commissions and kickbacks to a test account on a real booking are not written |
| Notifications, emails, texts to staff | staff notices went to every active staff member, test accounts included; the invitation's resend.dev address is not suppressed | fenced on all four outboxes |
| Staff pickers and lists | `staff_directory`, `sales_staff_options`, `team_sales`, `sales_modes_admin` listed them | left out |
| Live map and leads | test sessions counted; the least busy sales assistant could be a test account | excluded; `submit_lead` skips them; test-address leads closed |
| Reports, statements, actuals, usage | test owners only excluded when `is_test` was set by hand | set automatically, so the existing exclusions apply; commissions fenced |
| Hiring and interview slots | an interview score could be credited to a test account | fenced (`interview_scores.interviewer`); test applicants are recognised by address |
| Owner and renter lists | Verify Owner not flagged | `owners.is_test` set; renters recognised by address for the fences |
| Public site | a test owner's car could be published | reported by Data health ("Test accounts in real work") |

Sample cars: the design holds. A request on a sample car (`is_sample`, not `sample_bookable`) never becomes a booking: it
is an enquiry lead (kind `sample_car`) with a customer service task "Suggest a similar real car" carrying the best free
real car (0065, 0102), and the car page offers "Book the X instead" first (SampleMatch). What was missing was anyone
noticing an enquiry nobody answered: Data health now lists real sample-car enquiries still new after 2 hours, and any
real booking on a sample car (which only `sample_bookable`, the local seed's flag, allows).

## 2. Data health (0441)

`app.data_health(now)`: every check in one read. Each check has a plain line, a count and its first 25 records; each
record has its link and, where it is safe, a one-tap fix (`data_health_fix`, Admins only):

| Check | Line | Fix |
|---|---|---|
| `pickup_not_recorded` | Confirmed bookings whose pickup time passed with no pickup recorded | Mark picked up (0195's record-now path, as Bookings > Now) |
| `never_closed` | Confirmed bookings whose return time passed and were never closed | Close (0330's `booking_close_ended`) |
| `dead_with_money` | Bookings marked expired or declined that were paid or have a pickup or return report | link: an Admin's call |
| `on_rent_gaps` | Cars on rent with no signed agreement or no deposit | link |
| `test_accounts` | Real work routed or credited to a test account | Unassign (tasks, leads, field jobs), else link |
| `inactive_assignee` | Open tasks or leads assigned to someone who no longer works here | Unassign |
| `lead_followup` | Real leads with their follow-up stopped or never started (owner leads), other leads still new after 2 days | Restart follow-up (owner leads), else link |
| `licence_waiting` | Licence reviews waiting more than 24 hours | link |
| `duplicate_tasks` | Tasks open more than once for the same thing | Close |
| `resolved_tasks` | Open tasks whose subject is already settled | Close |
| `car_gaps` | Published cars missing seats, plate, real photos, a rate card or owner terms | link |
| `owners_terms` | Owners with cars and no terms entered | link |
| `unmatched_payments` | A renter's payment with no booking; a card processor charge matched to no payment | link |
| `deposits_overdue` | Deposits still held 7 days after the car came back | link |
| `offers_stale` | Offers that expired more than 48 hours ago still in a queue | Close (the task), else link |
| `sample_requests` | Real people who asked for a sample car and were not offered a real one | link |
| `usage_trend` | Email or AI usage on course to go over its included allowance | link to Settings > Usage |

"Pickup not recorded" and "never closed" reuse Bookings > Now's own lists (`app.fleet_board`, 0330), not a copy.
"Settled" tasks: a request's task when the booking is no longer a request; "Offer expiring soon" when the offer is no
longer out; offer follow-ups when the booking went ahead; pre-pickup chases when the rental is over; a late return when
the car came back; a lead's task when the lead is converted, closed or spam.

**Fixed without asking** (`app.data_health_autofix`): test accounts taken off real records (tasks, leads, field jobs,
chats, visitors, bookings still under way, request claims, owner applications), duplicate tasks closed (the one being
worked, else the oldest, stays), settled tasks closed with the reason in their note. It runs with the hourly task hygiene
(0078's `job_task_hygiene`) and nightly. Judgment calls stay on the card: whether an expired booking actually ran, a
booking to close, a follow-up to restart.

**The nightly run** (`app.job_data_health`, pg_cron `carmacars-data-health`, 08:23 UTC, 03:23 Toronto): the auto-fix,
then the checks, kept in `data_health_runs` (the last 30), then one in-app notice a day to each real Admin when something
needs them (`staff_data_health`, no email, no text, no push). The checks are set-based reads on indexed tables plus one
`fleet_board`, once a night (and on Check now), well inside the CPU limits.

**The door**: `ops_read data_health` (the last run, with what the auto-fix did this week), `ops_do data_health_fix`
(one record; it leaves the stored run at once) and `ops_do data_health_run` (Check now). Admins only.

### What the migration fixes in production, by code reasoning

0441 runs the auto-fix once when it is applied:

- The two real owner leads credited to "Verify Invitation" and "Verify Sales" lose that assignee (they go back to the
  sales queue); they stay on the card as "follow-up stopped" with **Restart follow-up**, because restarting sends
  emails to real people and is the Admin's call.
- Every open task assigned to a Verify account on a real record is unassigned (an in-progress one goes back to open):
  the "assigned to Verify Invitation" tasks.
- Bookings under way crediting a Verify account (sales credit, referrer, claim) lose that credit; request claims held by
  one are released.
- Duplicate open tasks on the same record are closed, keeping one.
- "Offer expiring soon" tasks on bookings already confirmed, on rent or over, request tasks whose booking is no longer a
  request, and the other settled tasks above are closed.
- The Verify Owner's record gets `is_test`; Verify visits leave the visitor history.
- Not changed: the Oct 25 to 27 booking and other "confirmed but out" or "expired but ran" bookings. They show on the card
  with **Close** or **Mark picked up**, or a link, for an Admin to decide.

## 3. The card

**Today > To do**, below the usage cards: `DataHealthCard` (`web/src/features/admin/data-health/`), a separate component
slotted into the page with one line, so the To do redesign on another branch is untouched. "Data health" with the count,
when it last checked and **Check now**; one line per problem with its count, most first, each opening to its records with
the link and the fix; "All 17 checks clear." when nothing is wrong; the last line says what was fixed without asking this
week. Admin > Portals shows "Test account" in the Portals column.

Tests: `supabase/tests/99_data_health.sql` (every fence, chooser and list, every check finding its record, each one-tap
fix, each auto-fix, the once-a-day notice, privileges), `web/src/features/admin/data-health/model.test.ts`,
`web/tests/e2e/data-health.spec.ts` (375 and 1440, axe).

## Guides

- `admin/data-health`: new chapter: the card, what it checks, what it fixes by itself, test accounts.
- `admin/people-and-access`: the "Test account" label on Portals.
