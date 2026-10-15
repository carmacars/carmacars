# 0043: the email daily cap, safe on Resend's free plan

Migration `supabase/migrations/0043_email_cap.sql`, tests `supabase/tests/27_email_cap.sql` (23 assertions), Edge
Function `supabase/functions/send-outbox/index.ts`, Admin > Today and Admin > Email.

## Why

Resend's free plan sends 100 emails a day for the whole account. Supabase Auth's own emails (confirmation,
invitation, password reset, sign-in link, email change, verification code) go out through the same account by SMTP,
but the outbox counted only its own rows, so on a busy day the outbox could take all 100 and the next sign-in link
would fail at Resend. Resend's own refusals (HTTP 429: its rate of 2 requests a second, or the day's quota) were
treated as ordinary failures: three of them in a row and the email was marked failed and never sent, with nobody told.

## What changed

| # | Change | Where |
| --- | --- | --- |
| 1 | Supabase Auth's emails are counted in the day's total (Toronto day), from the send times `auth.users` records; an invitation sets two of them at the same instant and counts once. Links an Admin makes through the admin API set them too, so the count errs high | `app.auth_emails_today`, `app.outbox_sent_today` (same signature) |
| 2 | The priority classes leave room for sign-in emails: customer booking emails stop at 97, owner and investor emails at 95, immediate staff emails at 90, digests and summaries at 80, marketing at 60 (and its own daily maximum of 15). Was 100, 100, 95, 95, 60 | `program_settings.notify_class_limits` (Admin > Settings > Program settings > Email and notifications, with a hint) |
| 3 | At 80% of the cap (`notify_cap_warn_bps`, 8000) every Admin gets one in-app notice that day (`staff_email_cap_warning`, no email); Admin > Today shows the day's use with the sign-in emails and an alert; Admin > Email shows the use, the held and the failed counts, and a "Held" filter | `app.outbox_claim` (wraps 0035's), `app.email_usage`, `app.admin_dashboard` (wraps 0030's), `app.admin_read` `email_usage` |
| 4 | Resend's 429 holds the row without spending an attempt: a rate refusal for a minute, a quota refusal until the next Toronto midnight together with the rest of the batch; a quota refusal tells the Admins in the portal. The sender spaces its requests (550 ms) to stay under 2 a second | `app.outbox_defer`, `send-outbox` |
| 5 | An email that finally fails (refused for good or after its attempts) tells every Admin in the portal, one notice per email naming the code, the address and the reason (marketing excepted); Admin > Today counts the day's failures | `app.outbox_mark_failed` (wraps 0018's) |
| 6 | `notify_count_auth_emails` (on) switches the counting of Auth emails off if the Auth SMTP ever moves to another provider | `program_settings` |

What cannot go today is held (`delayed`) until after midnight, booking emails first; nothing is dropped. The
existing "Email limit reached for today" notice (0018) still comes when something is held for the cap.

## Existing assertions changed

| File | Was | Now | Why |
| --- | --- | --- | --- |
| `07_notifications.sql` | `notify_class_limits` 100, 100, 95, 95, 60; catalogue `142/1` | 97, 95, 90, 80, 60; `142/3` | the room for sign-in emails; the two in-app codes |

## Not done

- Supabase Auth's emails themselves cannot be held by the outbox: if the day's quota is already used by other mail,
  Resend refuses them and Supabase shows the person an error. The class limits keep 3 to 20 sends free for them; above
  about 80 emails a day the plan to move to is Resend Pro (US$20 a month, 50,000 a month).
