# Release 34, part N: the academy is mandatory (migration 0802, guides in 0801)

Branch `r34-n`. SCHEMA_MARKER 0802 (raise to the highest merged migration when merging).

The owner, November 8: "academy should be mandatory and it should be well built and updated and describes every part of the
business necessary and describes all workflows that they should know. they must pass the academy to continue".

## What changed

1. **The gate.** Already on since 0731 (per enrollment, a hire held from the start). Kept: passing is every section of the
   person's paths (one per staff function: customer service, Fleet, Finance, Sales in person or remote, field work), each
   quiz at `academy_pass_bps` (80%), retakes allowed (every attempt kept). New: a held person lands on **Welcome**
   (`/staff/welcome`) instead of the academy, and Welcome joins the pages a held person opens (`features/academy/gate.ts`
   `ACADEMY_OPEN`: the academy, the guide, the profile, Welcome, no-access); `requireStaff` sends every other page there.
2. **Waive for one person.** `academy_waivers` (one row a person, the reason, who and when, `revoked_at` when taken back;
   audited by `app.audit_row`). `app.academy_locked` (0731) now also checks `app.academy_waived`. Admin action
   `academy_waive` {user_id, reason, on} (reason required, Admins only); read `academy_gate_state`. The **Academy gate** card
   (`features/academy/GateCard.tsx`) is on the person's academy page (`/admin/academy/staff/[id]`) and on the candidate page in
   Hiring (`/admin/hiring/[id]`, once hired): held or open, sections passed, Waive the academy / Take the waiver back.
   Progress stays in Settings > Staff (the Academy column) as before.
3. **Welcome, the first-login flow.** Read `staff_welcome` (ops_read, staff only): welcome, profile and phone (home address
   and mobile), the academy (sections passed, or waived), first tasks (the first-day To do's of one-step Hire, 0730), ticked
   off on the page (`staff_welcome_task`: the person's own `first_day` tasks only). **Go to your portal** once open.
4. **Content audit and gaps.** Four new sections (`supabase/seed/academy/r34.mjs`, block written by
   `supabase/seed/0802_gen_academy.mjs`), each with lessons and a quiz, appended to the paths that use them:
   `new-r33-bookings` (check-in is the pickup and check-out the return, Sign and pay, Book it now, overrides, past trips:
   customer service, both Sales, Fleet, field, Admin), `new-r33-money` (Charge the renter, reasons, Hold expired, the debit
   deposit fee, owner invoices paid outside the platform: Finance, Admin), `new-r33-photos` (listing photos from a shared
   folder link: Fleet, customer service, Admin), `new-r34-caller-notes` (the caller panel and renter notes: customer service,
   both Sales, Admin). Every role gets at least one; every section of every path has lessons and a quiz (DB test). No vendor
   names (unit test, DB test). Staff who had passed everything get a week before the new sections hold them (`lock_from`,
   0731's rule); nothing is reset.
5. **Kept updated from the guides.** `academy_sections.guide_refs` names the guide chapters a section was written from (the
   new ones, and 15 existing sections mapped once). Trigger `guide_sections_flag_academy`: a chapter published again
   (`published_version` changes) flags every section naming it (`review_due_at`, `review_note`). Admin > Academy lists them
   under **To review: the guide changed** with **Mark reviewed** (`academy_review_done`). The generator refuses a guide
   chapter that does not exist, a section without a quiz, an answer out of range or a long dash; `--check` runs in the unit
   tests.

Every new section has 5 questions (99_academy's rule); 4 of 5 (80%) passes, 3 of 5 does not.

## Existing assertions changed

| File | Was | Now | Why |
| --- | --- | --- | --- |
| `supabase/tests/99_marketing_team.sql` | the Academy section is last on the Sales paths, apart from `new-%-r28-r32` | also apart from the release 33 and 34 sections (`new-r3%`) | item 4 appends sections to the Sales paths |
| `supabase/tests/99_r33_hire_academy_connector.sql` | `new-bookings-r28-r32` is second to last on cs and field | the same, counted without the `new-r3%` sections | item 4 |

Tests: DB `99_r34n_academy_gate.sql` (29 assertions), unit `features/academy/gate.test.ts`, e2e
`tests/e2e/academy-gate.spec.ts` (held on Welcome, work pages sent back, Admin waives, work pages open).

## Guides

Changed chapters (published by `supabase/seed/0801_gen_guides.mjs` into `0801_r34n_caller_popup_guides.sql`):
`admin/academy`, `va/academy`, `field/academy`.
