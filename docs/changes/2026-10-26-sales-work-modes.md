# Sales work modes: in person and remote, October 26, 2026

The owner's decision: Sales staff work in one of two modes on the same Sales dashboard (the Sales function of `/va`). In person
(Toronto) keeps the commission tiers; remote (worldwide, contractor) earns 5 points less on every tier and has duties: peak-hour
cover, a daily lead-generation checklist and a monthly activity minimum. The wording everywhere is "in person" and "remote".
Migration `supabase/migrations/0174_sales_work_modes.sql` (SCHEMA_MARKER `0174`), guides by `supabase/seed/0174_gen_guides.mjs`.

## 1. The rules

| | In person (Toronto) | Remote (worldwide contractor) |
| --- | --- | --- |
| Pay | Commission only | Commission only |
| Tiers (rental days of the month, on all that month's rentals) | 10% under 50, 15% from 50, 20% from 100 (unchanged, `sales_tier_*`) | 5%, 10%, 15% on the same days (`sales_remote_tier_low/mid/high_bps`) |
| Commission rule | Unchanged (0058): the rental charge before tax, after discounts, less refunds, of each rental they sourced, once completed and paid in full; Admin approves; none on cancelled, refunded, unpaid, charged-back, own or household rentals | The same |
| Credit | Walk-ins, handovers they close, partner visits and rentals they source (the sourced choice and Admin credit, as before) | Only rentals they source. A walk-in (`source = walk_in`) or a partner deal (`source = partner`, or a referral partner on the booking) earns nothing ("Remote sales: a walk-in or a partner deal earns no commission"). A website request they answer with the first offer during one of their availability blocks is credited to them as sourced (whatever they chose on the offer), with a line in the booking history; off their blocks it stays a claim for an Admin |
| Cover | None | At least `sales_remote_cover_hours` (20) a week of Thursday to Sunday, `sales_remote_peak_from_hour` (12) to `sales_remote_peak_until_hour` (18) Toronto time, from the blocks they submit; reply target `sales_remote_reply_minutes` (15) |
| Daily checklist | None | Marketplace and classified reposts, social DM replies, three follow-ups on every quote, long-term and business outreach |
| Monthly minimum | None | `sales_remote_min_touches` (400) logged touches |

**The tier drop (the rule chosen).** At month close, a remote month under the minimum is paid `sales_remote_drop_tiers` (1) tier
lower: 15% becomes 10%, 10% becomes 5%. Dropping below the lowest tier gives `sales_remote_floor_bps` (2.5%), so 5% becomes 2.5%
(and with a drop of 2, 10% also becomes 2.5%). A drop of 0 switches it off. All of these are Program settings (Settings > Program
settings, Staff commissions). During the month the rate shown is the tier rate, with the rate the month would end at
(`projected_bps`) beside it; the drop is applied by the month's recalculation (`app.job_commission_month`, the 1st after 6:00),
before any approval (a Sales month is approved only after it ends).

**Locked months.** Each person's month is kept in `sales_month_rates` (mode, the three tier rates and days, the minimum, the drop,
the floor, the touches, the rental days, the tier and the rate). When an Admin approves the month (`app.commission_approve`), its
schedule is locked: a later change of the settings, of the person's mode, or a touch voided later, changes nothing. The rental
days still move the tier inside the locked schedule, so a refund after payment lowers the tier and is clawed back as staff
agreement 3.4 says (suite 37 unchanged). `staff_commissions.work_mode` carries the mode on every commission; My sales shows it on
each row and each month's line ("September 2026, remote: 50 rental days reach 10%, but 399 of the 400 touches were logged: the
month's rate is one tier lower, 5%.").

## 2. The database

- `staff_profiles.sales_work_mode` (`in_person` | `remote`): only a Sales assistant has one (trigger `staff_profiles_sales_mode`:
  a Sales assistant without a mode is in person, the rule until now; anyone leaving Sales loses it). Existing Sales assistants
  were set to in person. `app.staff_set_sales_mode(p_by, p_staff, p_mode, p_reason)` is the function an Admin (admin_do
  `staff_sales_mode_set`) and the careers hire flow call; audited. A change of mode works the open months out again (rates and
  the credit rule; trigger `staff_profiles_sales_mode_resync`); approved months keep theirs.
- `sales_touches`: kinds follow_up, repost, dm_reply, outreach_call, outreach_email, outreach_text, owner_outreach. Logged by the
  system for every Sales assistant: an offer sent (follow-up), a message to a renter or owner from the portal (follow-up on a
  booking, else outreach by channel; an internal task note is not one), a live chat answered (one DM reply per chat a day), a
  call or text from the phone line, an ad posted (repost), an owner recruitment call or message. By hand: va_do
  `sales_touch_log` (remote only; type, an optional `https://` link, booking number, note; at most 300 by hand a day). An Admin
  voids one with a reason (admin_do `sales_touch_void`), not in an approved month.
- `sales_availability`: the remote rep's blocks (va_do `sales_availability_save`: one week at a time, this week or up to three
  ahead, days already past stay, no overlaps). `app.swm_on_shift`, `app.swm_peak_minutes`, `app.swm_week`.
- Reply time `app.swm_replies`: live chats assigned to them (from the request for a person to the first reply) and reply tasks
  assigned to them (renter message, missed call, text to check, chat request or contact, booking request: to completion) that
  came in during their blocks; within the target, median, late and open.
- Replaced: `app.commission_retier` (the Sales rate from `app.swm_rate`, the month kept by `app.swm_snapshot`, the mode on each
  commission) and `app.sales_month_progress` (the tiers of the mode; for Sales also `mode`, `tier_bps`, `projected_bps`,
  `touches`, `min_touches`, `below_minimum`, `dropped`, `locked`). Wrapped (`_pre0174`): `commission_own_reason` (the remote
  credit rule), `commission_approve` (locks the month), `staff_commissions_json` (`mode`, `months`, `work_mode` on rows),
  `commission_admin` (the mode of each person, the remote settings), `door`.
- New reads: va_read `sales_duties` (always the person's own), admin_read `sales_modes` and `sales_duties` (Admin only).
- Every new function is for `service_role` only; the three tables have row security (Admin all, the person their own rows).
  `web/src/lib/db/types.ts` regenerated (the three tables and the new columns).

## 3. The website

- `/va` (Sales): the hero ring says In person or Remote; a remote rep gets **Remote duties**: the month's touches against 400 (a
  bar), the rate line (tier now, the rate the month would end at), today's checklist (ticks itself from the day's touches),
  **Log a touch**, the peak hours scheduled this week, replies on time and the median, **My availability** (this week or next,
  **Add a block**, **Save the week**) and the month's touches. In person sees no remote checklist.
- `/va/my-sales`: the mode in the kicker and the lead; Commissions has the mode line, the mode on each row and **By month**.
- Admin > Settings > Staff and roles: the Function column says in person or remote; a new card **Sales staff: in person or
  remote** lists each Sales person with the mode, the rate now, the rate the month would end at, touches, peak hours this week,
  replies on time and **Work mode**.
- Admin > Staff > a person > Sales: **Work mode**, and Remote duties read-only with **Void** beside each touch.
- Settings > Program settings, Staff commissions: the ten `sales_remote_*` settings, with labels and hints.
- Files: `web/src/features/sales/RemoteDuties.tsx`, `AvailabilityForm.tsx`, `SalesModesAdmin.tsx`, `Commissions.tsx`,
  `web/src/app/va/page.tsx`, `web/src/app/va/my-sales/page.tsx`, `web/src/app/admin/staff/[id]/sales/page.tsx`,
  `web/src/app/admin/settings/[section]/page.tsx`, `web/src/features/admin/fields.ts`, `web/src/styles/va.css`.

## 4. Tests

- `supabase/tests/99_sales_work_modes.sql` (fixtures "swm"): settings; the mode (Admin only, Sales only, audited, the hire
  flow's function, cleared outside Sales); in person 10% and 15% with a walk-in credited; remote 5% at 20 days, the floor 2.5%
  with no touches after the month, 5% with 400, 10% at 50 days, one tier lower at 399, the floor with a drop of two, the minimum
  as a setting; the statement lines; the month locked on approval (settings and mode changes do not move it, no void after);
  remote credit (walk-in and partner nothing, sourced by phone accrues, in person walk-in accrues, the switch both ways); a
  website request on shift credited with its history line, off shift a claim; touches logged by offers, portal messages (not
  task notes), live chat (once), the phone line, and by hand (remote only, a type, a real link); the checklist; blocks (overlap
  and past day refused, 8 peak hours); reply time; the projected rate; in person without remote duties; privileges (own
  duties only, Admin reads, row security, no browser execute).
- `web/tests/e2e/sales-work-modes.spec.ts` (375 and 1440, axe): Admin sets a rep remote in Staff and roles; the rep's To do shows
  Remote duties, logs a touch and saves a block; an in person rep sees no checklist; the Admin's Sales page shows the duties
  and voids a touch.

## Guides

- `va/sales`: new tasks "In person or remote" (the table of both modes) and "Remote: your duties"; My sales step 1 by mode.
- `va/commissions`: the Sales row names both modes.
- `admin/people-and-access`: new task "Sales staff: in person or remote".
- `admin/settings`: the remote Sales settings in the Staff commissions line.

## Needs the owner

- **Staff agreement, Schedule A, for both modes: to the lawyer.** The proposed text is in
  `docs/source/va_agreement_sales_modes_draft.md` (pending legal review). It is kept out of `docs/source/va_agreement.md` on
  purpose: the agreements staff sign are generated from that file, so nothing changes in a signed or sent agreement until the
  lawyer approves the text and it is merged there. Points for the lawyer are listed in the draft (contractor status abroad, the
  minimum as a rate rule, the remote credit rule, section 3.4's Rate bullet).
- Until then, a remote rep's agreement says what section 3.4 says (the in person tiers). Set someone remote only once their
  agreement covers it.
- `docs/source/va_hiring_package.md` still describes Sales as one role (10/15/20%); update the job post for remote reps when the
  Schedule A text is approved.
