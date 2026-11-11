# Payroll, role KPIs, staff schedules, the townhall deck, lead intent, Search Console on the investor deck and fixes (Release 35, part C: 1500 to 1599)

Branch `r35-c`. No applied migration is edited.

## Fixes

| Item | What changed |
| --- | --- |
| Car change list (item 7) | `1500_r35c_change_vehicles_fix.sql`: `app.ops40` 'change_vehicles' read failed with `column reference "b.id" is ambiguous` (the query's alias `b` clashed with the function's variable `b bookings`), so the list was always empty. The booking is now read into the variable first and the query has no alias `b`. Test: `supabase/tests/99_r35c_change_vehicles.sql` |
| Email figure (item 8) | `1501_r35c_email_capacity.sql`. Why 100: `app.email_day_cap` counts Cloudflare's budget (`notify_cf_daily_budget` 200) only once Cloudflare Email Service has sent (`app.cf_email_counted`); until then the cap is Resend's own (`notify_resend_daily_budget` 100, the free plan). The sending cap is unchanged (the claim must not take emails no provider can send); `app.email_pace` and the booking email box now also carry `capacity` (Cloudflare + Resend, at most `notify_daily_cap`), `limited_by` (`combined`, `resend_only`, `setting`) and `cf_reason` (off, no EMAIL binding, refused with its error, never sent). Web (owner follow-up): the "N of 100" counter is gone from the booking email box, Admin overview, Logs > Emails (a plain count), the Admin Today banner and the usage cards (Resend's daily row filtered); only Settings > Usage shows the day as "N sent today; daily capacity 300 (Cloudflare 200 + Resend 100)" with why Cloudflare is not sending (`emailBudgetLine`). The settings labels name each budget. Test: `supabase/tests/99_r35c_email_capacity.sql`, `web/src/features/usage/usage.test.ts` |

### Cloudflare Email: what the owner or integrator must verify

The code is complete: the send-outbox function posts each email to `/api/email/send`, which sends through the Worker's `EMAIL`
binding and records each success or refusal (`server_cf_email_result`); Resend takes any email Cloudflare refuses. It only
sends when all of these hold:

1. GitHub > Settings > Secrets and variables > Actions > Variables: `CF_EMAIL_BINDING` = `1` (the deploy then adds
   `"send_email": [{ "name": "EMAIL" }]` to wrangler.jsonc; the deploy annotation says "EMAIL binding added").
2. Cloudflare dashboard: Email Service (Email Sending) enabled on the account with `carmacars.ca` onboarded as a sending
   domain (its DNS records verified), so the binding may send from the site's From addresses.
3. The send-outbox function has `LINK_SIGNING_KEY` (the site's key) and `APP_URL`; without the key it never tries Cloudflare.
4. Program settings: `cf_email_enabled` on (default on).
5. After the next send, Admin > Settings > Usage shows "Cloudflare Email Service sends them" and the figure reads "of 300".

## Staff schedules (item 3): `1502_r35c_staff_schedules.sql`

| Item | What changed |
| --- | --- |
| Table | `staff_schedules`: a role default (`user_id` null, one per role) or a person's own (Admin only); ISO `weekdays`, `month_days`, `start_time`/`end_time` (Toronto, same day), `extra_days_per_week`, `starts_on`. Seeded role defaults, no names: cs 1,3,4,5,6,7 08:00-18:00; finance 1,3,5 + 10th, 15th, 10:00-19:00, 1 extra day, from 2026-11-11; fleet 1-6 11:00-21:00 |
| Rules | `app.staff_shifts_on`, `app.staff_on_shift`, `app.staff_day_status` (late after `staff_late_grace_minutes`, 10; absent once the day's hours are over); `app.va_clock_start` (the clock-in reminder) now starts from the schedule; `app.staff_alert_users` (on duty) also reaches a person clocked in within their scheduled hours |
| Door | `staff_schedules` (ops_read: everyone sees the role defaults, their own week and the duty board; Admin also everyone's own), `staff_schedule_save`, `staff_schedule_clear` (Admin) |
| Web | Admin > Team > Schedules (`/admin/schedules`), staff Hours > Schedule (`/staff/schedule`), `features/staff-schedule` |
| Tests | `supabase/tests/99_r35c_staff_schedules.sql`, `web/src/features/staff-schedule/model.test.ts` |

## Payroll (item 1): `1503_r35c_payroll.sql`

| Item | What changed |
| --- | --- |
| Salary | `staff_profiles.monthly_salary_cents`/`salary_currency` (an Admin, `payroll_salary_set`, with a reason) or the role default `program_settings.va_salary_defaults` (`{"cs":…, "fleet":…, "finance":…}`, empty: the integrator or an Admin sets the amounts; the repo is public) in `va_salary_currency` (USD). Biweekly = monthly x 12 / 26, by the days employed in the 14 (`app.pay_salary_period`) |
| Run | 0165's field pay run is the one payroll: `app.fp_run_refresh` adds a line for every salaried office staff member (salary, the period's clocked minutes for the record, currency), keeps field lines as they were, and both carry `pay_adjustments` (bonus or deduction with a reason, kept through refreshes) |
| Who | Finance or an Admin: `field_pay_run_start`, `field_pay_run_refresh` (were Admin only), `payroll_adjust`, `payroll_submit` (Send for approval: alert `payroll_ready` to the Admins). Admin only: `field_pay_run_approve`, `field_pay_line_paid`, `payroll_pay_all`, `field_pay_run_void`. Nothing is paid by a job |
| Stubs | `my_pay_stubs` (every staff member, own only); the PDF (`app.pdf_facts` wrapped: salary, adjustments, currency, clock entries) and the pay statement email now also go to office staff (`app.notification_recipients`, `app.notification_payload` wrapped) |
| Web | Admin > Money > Payroll (`/admin/money/field-pay`, run tab), Finance Hours > Payroll (`/staff/payroll`), My hours pay stubs (`/staff/hours`), `features/payroll/Payroll.tsx`, PDF `payStatement` |
| Tests | `supabase/tests/99_r35c_payroll.sql`; `99_field_pay_rules_mode.sql` no longer expects Finance refused at start (the owner's new rule) |

## Role KPIs (item 2): `1504_r35c_role_kpis.sql`

| Item | What changed |
| --- | --- |
| Targets | Program settings `kpi_rate_target_pct` (90), `kpi_on_time_grace_minutes` (15), `kpi_cs_first_reply_minutes` (5), `kpi_cs_conversations_week` (40), `kpi_cs_licences_week` (5), `kpi_cs_requests_week` (10), `kpi_fleet_photo_reviews_week` (10), `kpi_fleet_dispatch_week` (10), `kpi_fleet_calls_week` (20), `kpi_finance_deposit_review_hours` (48), `kpi_finance_toll_checks_week` (2), `kpi_field_jobs_week` (10), `kpi_field_min_photos` (8) |
| Sources | first reply and conversations: `phone_activity` (Quo texts and calls); licences: `identity_verifications.verified_by`; requests: `booking_events` offer_sent, declined, info_requested; handovers on time: the team's done handovers and deliveries; photo reviews: field jobs and condition reports reviewed; next-day list: the closing `daily_checks` on each scheduled Fleet day (1502); deposits: `deposit_reviews` Finance done within the hours of the Fleet check; statements and invoices: owner statements sent by payout day, owner invoices issued by billing day; tolls: distinct days of `deposit_review_ticket_checks`; field: done jobs, on time, a condition report with the minimum photos. Sales keeps 0057's month target |
| Reads | `app.role_kpis`, `staff_scorecard` + `kpis` (4 weeks), `kpi_board` (Admin all, staff and field their own) |
| Web | scorecards (`features/kpis`, `features/va/Scorecard.tsx`), Admin > Team > KPIs (`/admin/kpis`), field My pay (this week) |
| Tests | `supabase/tests/99_r35c_role_kpis.sql`, `web/src/features/kpis/model.test.ts` |

## Townhall (item 4): `1505_r35c_townhall_deck.sql`

| Item | What changed |
| --- | --- |
| Link | The owner's `townhall_link` is 1062's `program_settings.townhall_call_url` (empty until set; no second column). `townhall_link` read; `features/townhall/TownhallLink.tsx` on the staff frame (office and field): the next call and Join (through `/api/townhall-join`, which records the join) |
| Run | `townhall_minutes` 30 (was 45). `app.townhall_slides` now returns 15 sections with `minutes` (30 in all): opener (cameras on) 1, hires 2, story 3, funnel 3 (leads generated, contacted, offers submitted, requested back = booking requests, closed = confirmed), social 2, fleet week by week (4 weeks added and retired) 3, investors 2 (+ Admin-only committed money), owners 2, top cars 3 (most requested, busiest; + Admin-only revenue), insurer-billed rentals 2 (`bill_to` insurer or split), leaderboard 2, platform updates 1, people 4. The deck page shows each section's clock |
| Stories, social, recording | `townhall_stories` (staff submit up to 3 a week; an Admin picks one: the deck's story slide), `townhall_social` (an Admin enters followers, posts, views per platform and week; growth on the week before), `townhall_decks.recording_url` (Admin; every portal lists the recordings) |
| Attendance | `townhall_attendance.method` adds `admin`; `confirmed_at`: a join counts once confirmed, a check-in or an Admin's mark counts (`app.townhall_attended`, used by the job's absences). `townhall_mark` (Admin, corrects a closed meeting's absences) |
| Lock | `app.townhall_lockouts` (in the job): absent in the last two closed meetings → `inactive_locked_at` with `staff_profiles.lock_reason` 'townhall' (not again after an Admin's Unlock for the same meetings); the door says why; the staff list labels it; the sign-in notice covers both reasons |
| Tests | `supabase/tests/99_r35c_townhall.sql`; `99_r35k_staff_onboarding.sql` (15 and 13 slides; the clock-in start from the schedule) |

## Lead intent (item 5): `1506_r35c_lead_intent.sql`

| Item | What changed |
| --- | --- |
| Rules | `app.intent_extract(text)` (keywords and patterns): budget {amount_cents, per}, car_class, duration_days, dates, urgency, delivery, coverage. `app.intent_inputs`: the last 60 days of phone activity (texts, transcripts, AI summaries, voicemails), inbound emails, site chat (visitor lines), the lead's message, notes and form; behaviour from `visitor_sessions` (visits, pages, cars viewed, visitor score, last 24 hours), booking requests (14 days), conversations. `app.intent_score`: points per signal and behaviour (reasons kept); label by Program settings `intent_hot_score` (70), `intent_warm_score` (40) |
| Storage and refresh | `intent_scores` (renter or lead); `app.job_intent` every 15 minutes (cron `carmacars-intent`) for whoever was active; computed at once when staff open a renter or lead older than 10 minutes |
| AI | Optional (`intent_ai_enabled`, on): `server_intent_ai_due` hands one subject only while `app.ai_allow('intent_enrich')` (background tier of the free daily neurons) has room: a hard stop; `web/src/server/intent-ai.ts` (called from the phone job) asks Workers AI; `server_intent_ai_result` keeps only well-formed values that fill gaps the rules left, and records the neurons in `provider_calls` |
| Shown | Intent card on the lead page (Admin and staff), the Admin renter page and the staff renter view; `app.live_map` adds `intent` to each renter pin (shown in the leads table's details) |
| Tests | `supabase/tests/99_r35c_lead_intent.sql`, `web/src/features/intent/model.test.ts` |

## Search Console on the investor deck (item 6): `1507_r35c_investor_search.sql`

| Item | What changed |
| --- | --- |
| Data | The gsc workflow stored sitemap figures and a coverage sample only, no clicks or impressions: it now also reads Search Analytics by day (`web/scripts/gsc-search.mjs`, 90 days) into `app.gsc_search_daily` (`app.gsc_search_store`). Indexed pages have no API: an Admin types Search Console's figure on Admin > Investors > Deck (`deck_search_indexed`; used for 30 days), else an estimate from the coverage sample, labelled so |
| Deck | `deck_search` (investor while the deck is shown; Admin): clicks and impressions of the last 28 days, growth on the 28 before, indexed pages, the weekly trend (12 weeks). Never fleet size, utilisation, premium or costs. `features/deck/SearchTraction.tsx` under the deck (investor portal and the Admin preview) |
| Owner step | The Search Console OAuth client of the gsc workflow must hold the `webmasters.readonly` (or `webmasters`) scope (it already reads the property's sitemaps); the next scheduled gsc run fills the figures |
| Tests | `supabase/tests/99_r35c_investor_search.sql`, `web/src/features/deck/search.test.ts` |

## Guides: `1508_r35c_guides.sql`

Admin > Owner money (Payroll for everyone, Schedules, KPIs, townhall tools, Intent, Search traction) and the office staff's Your workday (KPIs, schedule, pay stubs, payroll, the townhall's 30 minutes and the lock): `docs/guides/content/*.json` (and `docs/guides/src/guides/*.py`), generator `supabase/seed/1508_gen_guides.mjs` (`--check` up to date).
