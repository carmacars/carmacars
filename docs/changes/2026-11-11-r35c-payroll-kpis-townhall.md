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
