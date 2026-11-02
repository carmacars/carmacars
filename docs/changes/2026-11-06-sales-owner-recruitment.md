# Sales bring in car owners, and ask for a commission on each (0340, 0341)

The owner, November 1, 2026: "sales staff dont have a way to add vehicle owners and get commission on that, can u fix
that". Then: "dont set any values for commission, set it so that the sales person has to request either a flat rate or
a percent for each owner they bring on". No amount is set anywhere by default: each salesperson asks, an Admin decides.

- **Where (no new page for Sales):** My sales, card **Owners you bring in** (Sales function only): the pipeline in five
  figures (Invited, Applied, Approved, Car live, First paid rental), **Invite an owner**, **Start an application**,
  **Copy my owner link**, and each owner with their cars, stage, request and what it has earned. "Start an application"
  is the existing Add a car for an owner page, now open to Sales in a Sales form.
- **Invite:** name, email, phone and "The owner asked me to send it" (required). It makes an owner lead credited to the
  salesperson (`leads.sourced_by`), with no automatic follow-ups (the invitation is the one email), and sends a signed
  link to the application (30 days; the lead and the salesperson in it). An owner already on file, or invited by another
  salesperson in the last 90 days, is refused with "Ask an Admin". The personal link carries only the salesperson (a
  year).
- **Start it:** the same Add-a-car form with the permit photo reader of 0290, the owner new, no terms or invoices (the
  Admin's), "Sourced by you. Only an Admin can change it.", and always an application for an Admin to approve with the
  usual task. Its documents are filed as for customer service. The permit reader allows Sales 10 reads a day (the
  applicant's count of 0290).
- **Sourced by:** `owners.recruited_by` (0002), with `recruited_at` and `recruited_via` (invite, link, started,
  staff_entry, admin, referral_code). The owner's cars follow the owner. Set once: the signed invitation or link (checked
  again when the application is sent, `public.server_owner_sales_credit`), an application from an address the salesperson
  invited before it came in (trigger on `owner_applications`, 90 days), Start it for a new owner, or an Admin. The first
  credit stands; an owner already on file is never credited by an invitation. Customer service or fleet adding a car for
  an owner already on file no longer makes them its sourcer (0067's rule stays for a new owner and for an Admin).
  Browser sessions cannot write these columns (guard triggers). **Only an Admin reassigns**: the owner's page,
  **Sourced by**, with a reason (`admin_do owner_sourced_set`). A waiting request of the person before is withdrawn; an
  approved one and what it has not paid yet go to the new person; what was paid stays paid.
- **The request (one per owner, `owner_recruit_requests`):** a flat amount (CA$, up to CA$10,000), or a percent of the
  company's share of the owner's cars' rentals (the default) or of the cars' rental revenue, for a number of months (1 to
  120, required) or for as long as the car is with us. A note for the Admin. Revised while it waits (counted); after a
  decision only an Admin changes it. Each request or revision raises an Admin task.
- **The Admin's decision:** Money > Staff commissions > **Owner requests**: **Approve** (as asked), **Change and approve**
  (other terms, marked "changed"; the salesperson sees both), or **Decline**, each with an optional note. Nothing accrues
  before approval.
- **What it earns (staff commissions of kind `owner_recruit`):**
  - a flat amount: once per owner, ever, at the owner's first paid rental (the first completed rental of any of their
    cars, paid in full, not charged back); if that rental stops counting before it is paid, the commission moves to the
    next one;
  - a percent: on each completed, paid rental of the owner's cars that ends after the approval, from the month of the
    first such rental, for the months approved (or with no end); the base is the booking split's company share, or the
    rental charge counted as for Sales (before tax, after discounts, net of refunds); a rental without its split yet waits
    as not earned yet.
  - Then the usual flow: pending approval, approved by an Admin (Approve on the row or on the person), paid by hand with
    the person's other commissions. A cancellation, a refund to nothing or a lost chargeback reverses it; after payment a
    clawback comes off the next payment (or an adjustment when the base rose). An Admin may reverse one with a reason.
    The salesperson's mode (in person or remote) is kept on each commission; there is no automatic remote reduction now
    that the amounts are asked for, the Admin decides each one.
- **Never:** on CarmaCars-owned or partner cars, a shareholder's cars or a shareholder owner (the request is refused),
  or the salesperson's own cars.
- **Owner revenue is unaffected.** It is a company expense, not a booking expense: `app.booking_staff_commission_cents`
  (what is deducted before Owner Revenue) leaves these commissions and their clawbacks out, so the booking split, the
  owner statement and the payout are unchanged. Admin > Staff commissions shows them as "Owner brought in: a CarmaCars
  expense, never before Owner Revenue".
- **What a salesperson sees:** only the owners they sourced (`va_read sales_owners`): the owner's name, the cars' names
  and whether each is live, the stage, their request and their own commissions. No owner contact details (except the
  invitations they sent), no terms, revenue or statements. Row security: their own requests and commissions only; no
  owner rows. Admins read anyone's (`admin_read sales_owners` with `staff`). Every write goes through the door and is
  checked in the database (Sales function, the owner theirs, Admin for decisions and reassignment).
- **Unchanged:** the owner's own application; an invited applicant sees nothing different. (The owner pipeline: 0342 below.)
- **The door:** `va_read sales_owners`; `va_do sales_owner_invite`, `sales_owner_commission_request`, and
  `staff_add_owner_car` / `staff_vehicle_document` from a Sales page (`as_sales`) or a person who is Sales only;
  `admin_read sales_owners`, `owner_recruit_requests`, `owner_sourced`; `admin_do owner_recruit_decide`,
  `owner_sourced_set`. An hourly job (`carmacars-owner-recruit`) re-checks every approved request; the triggers on
  bookings, payments, refunds, disputes, lines and splits do it at once.

## Sales see only their own owner leads (0342)

The owner, viewing a salesperson's portal: "Darren sees an owner pipeline with shit I've never seen before". The owner
pipeline (0217) and Owner leads (0031) showed every prospective owner, classified-ad leads included, with contact details,
to anyone working as Sales.

- The full owner pipeline is for Admins and customer service (a person who also works as customer service keeps it).
  `/staff/owner-pipeline` sends anyone else to My sales (`#owners`); the Sales menu no longer lists it.
- Sales see, of the owner leads, only the ones they invited (`sourced_by`), added (`payload.added_by`) or were given
  (`assigned_to`: a website owner lead still goes to the least busy Sales person with its task). They are on My sales,
  Owners you bring in. The Sales "Owner leads" screen is now **Buyer leads** (buyer leads only).
- Enforced in the database: `va_read owner_pipeline` and `va_do owner_pipeline_*` refuse Sales; `va_read owner_leads`
  returns only their leads and the applications of owners they brought in; `va_list leads` leaves out every other owner
  lead; `va_do lead_update` refuses one; row security on `leads` (policies `sales_read`, `sales_update`) does the same.

## Test accounts never get real leads, owners or tasks; leads nobody followed up (0343)

On production two website owner leads (October 27 and 28) were assigned to the live verification's accounts ("Verify
Invitation", "Verify Sales") and said "Follow-ups stopped: On file before the automatic follow-ups".

- One rule for a test account (`app.staff_is_test`, widened; `app.email_is_test`): an address `verify-...@carmacars.ca`,
  an address in `site_settings.admin_test_emails`, the invitation check's `...+verify-...@` addresses and the
  `resend.dev` test inbox.
- Never picked: a new owner lead given to a test account goes to the least busy real Sales person, or stays unassigned;
  a test account is never "sourced by" on a real lead, owner or application, nor assigned a task about a real lead or
  owner (triggers on `leads`, `owners`, `owner_applications`, `tasks`); the invitation credit refuses one. The
  verification's own test leads and test owners keep their test accounts.
- Clean-up on deploy (`app.clear_test_account_credit`): real leads, owners, applications and open tasks held by a test
  account become unassigned.
- The owner leads on file before the automatic follow-ups that nobody moved get an Admin To do task "Follow up now"
  (high, once per lead; `app.owner_leads_follow_up_now`), and say "an Admin follows up (To do)".
- Not changed: bookings credited to a test account (the verification's own bookings).

## Owner leads from the application as it is filled in (0344)

The owner: "the owner leads should be farmed as well, with forms saving their info as they go so we can chase incomplete
form fills as leads. they can either input their vin or their year make and model and they need to input their phone
number and email and name".

- **The first step** of `/list-your-car/apply` asks only the first and last name, the mobile and the email (all
  required), with one line: "So we can save your progress and send your quote. We keep your details private." Then the
  car: **I have the VIN** or **Year, make and model**. **Add my car later** keeps the account-only path of 0087. The
  later steps no longer ask the name, mobile and email again (a line shows them, with Change). An owner on file skips it.
- **Saved as they go:** the whole draft autosaves (form_drafts, 1.2 seconds after the last change, on every step, signed
  in or not), and the contact capture of 0090 records the name, email and mobile as each becomes valid. That capture's
  lead is now an **owner lead** in the owner pipeline: source "Website form, unfinished" (`pipeline_source`
  `unfinished_form`), stage New, the car of the draft on it (and kept up to date as the draft changes). An open owner lead
  with the same email or phone (last 10 digits) takes the capture instead of a second lead.
- **Unfinished for 30 minutes** (`capture_continue_minutes`): the least busy real Sales person gets the lead and a task
  "Unfinished owner application" in the Sales queue (it opens My sales), and the owner recruitment follow-ups start
  (day 0, 2, 5 and 10). Consent and sending rules are those of 0217 and of contact capture: only what the person typed,
  an inquiry counts for 6 months, the marketing class under the daily cap and the sending hours, the unsubscribe link,
  stopped by a reply or "do not contact". Their words: "Finish your application to list <car>", with a link that opens
  the saved draft on any device (a new one-time link in each email, valid for `form_resume_link_hours`). The capture's
  own Admin task and "Continue your request" email are not sent for it: one chase.
- **Sent:** the lead moves to the new stage **Applied** (between Call booked and Agreement sent, also a column on the
  board and a choice in Move), takes the owner, and its follow-ups and task stop. 0217's stages that follow the owner's
  records now include Applied.
- **Calculator hand-off:** the application reads `?year=&make=&model=&vin=&est=` (est: the monthly estimate in cents),
  fills the first car with it, shows "Your estimate: about CA$1,450 a month for your 2021 Toyota RAV4", and keeps it in the
  draft (`calc`), so the lead carries the car they priced and the estimate (`payload.calculator`). The calculator on List your car
  links there with **Apply with this car** (`applyHref({ year, make, model, vin, estimate_cents })` from
  `web/src/features/owner/apply-schema.ts`). The name, mobile and email are usually captured before the first autosave
  of the draft: the draft, once saved, takes that capture by its email or mobile, so the lead gets the car, the estimate
  and the link to the draft.

Files: `supabase/migrations/0340_sales_owner_recruitment.sql`, `0341_sales_owner_recruitment_guides.sql`, `0342_sales_owner_leads_scope.sql`,
`0343_test_accounts_never_credited.sql`, `0344_owner_unfinished_applications.sql`
(`supabase/seed/0341_gen_guides.mjs`), `web/src/features/sales/SalesOwners.tsx`, `SalesOwnersClient.tsx`,
`web/src/server/actions/sales-owners.ts`, `web/src/app/staff/my-sales/page.tsx`, `web/src/app/staff/owners/add-car/page.tsx`,
`web/src/features/owner-billing/AddOwnerCar.tsx`, `web/src/app/list-your-car/apply/page.tsx`, `web/src/server/actions/apply.ts`,
`web/src/app/admin/money/commissions/page.tsx`, `web/src/app/admin/owners/[id]/page.tsx`, `web/src/features/sales/Commissions.tsx`.
Tests: `supabase/tests/99_sales_owner_recruitment.sql`, `99_test_accounts_never_credited.sql`, `99_owner_unfinished_applications.sql`,
`99_owner_pipeline.sql`, `web/tests/e2e/r26-sales-owners.spec.ts`, `r26-owner-start.spec.ts`, `release-22.spec.ts` (and the application
specs that now pass the first step).

## Guides

- `va/sales`: Owners you bring in; Ask for your commission on an owner.
- `va/commissions`: the line for an owner you bring in.
- `admin/owner-money`: Owner requests; Sourced by.
- `admin/advertising-and-owner-recruitment`: the pipeline is customer service's; test accounts; Follow up now.
- `va/your-workday`, `va/customer-service`, `va/quick-reference`: Buyer leads for Sales.
- `owner/apply-and-get-your-car-listed`: the first step and saving as you go.
