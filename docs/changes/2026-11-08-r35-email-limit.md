# Release 35, part R: the daily email limit is the setting's number, never a written one (migration 0869)

Branch `r35-r`.

The owner, November 8: "There's many spots on the website that still say we only have 100 emails to be able to use per day."

## What changed

Every place that wrote "100 emails a day", "held at 100" or "Resend's 100" now reads the number from Program settings (Emails
a day, `notify_daily_cap`, and the Cloudflare and Resend budgets, `notify_cf_daily_budget` and `notify_resend_daily_budget`)
or says "your daily email limit":

- Settings > Usage, Emails and the usage banner: `cfEmailSentence` takes Resend's allowance from the email pace read or the
  usage row (`resendDay`), and the Cloudflare month from its own read; "a busy day holds emails once Resend's N are used"
  reads N from the pace.
- Admin > Overview: "Email sent today" no longer falls back to 100 when the cap cannot be read.
- Guides: `admin/usage-and-paid-usage` (the banner line and the emails a day line) say "your daily email limit" with where
  to set it.
- `emails/README.md`, the send-outbox function's notes, the deploy scripts' notices (`email-binding.sh`, `owner-steps.sh`) and
  the usage workflow's comment name the setting, not a number.
- Tests: the DB suites `99_overdue_returns.sql` and `99_owner_todo_usage_noise.sql` compare with the setting; the unit test of
  the usage sentence passes other numbers.

Older change records and audits keep their wording: they describe what was true then.

## Guides

Published by `supabase/seed/0869_gen_guides.mjs` into `0869_r35r_guides.sql`: `admin/usage-and-paid-usage`.
