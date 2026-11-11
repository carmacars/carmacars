# Cloudflare email first, with a daily budget (migration 1750)

The owner, 2026-11-11: Cloudflare Email Service was sending (426 emails this month on Cloudflare's dashboard), yet
Admin > Settings > Usage said "Cloudflare Email Service is not sending ... not set up yet" with the old setup steps, and
emails were held by an hourly pace (43 an hour) and a daily cap (300).

## The rule (the owner's, final)

1. Each Toronto day the outbox sends through Cloudflare first until the day's budget is used: Program setting
   `cf_email_daily_budget`, 100 by default (the free 3,000 a month spread over the month). It never takes the month's
   Cloudflare count past `cf_email_monthly_included` (3,000). Nothing is ever paid.
2. Then Resend's free plan, `notify_resend_daily_budget` (100 a day).
3. When both are used, emails are held by priority as before (the class limits of 0018: booking, payment and sign-in
   emails first; the others wait for the next day).
4. No hourly pace within those budgets: 0583's "even pace plus 30 an hour" and 0530's spreading of the low classes are gone.
5. Within Cloudflare's budget Resend is used only after a Cloudflare error (Cloudflare then rests 15 minutes). The sender
   marks each such email: `status_reason` "sent through Resend after a Cloudflare error: <error>".

## Status

`app.cf_email_setup` is "ok" (sending) whenever an outbox email went through Cloudflare (`provider_id` 'cf:%') in the
last 48 hours, or the sender's last Cloudflare result was a success. Otherwise "off", "absent" (no binding, or no send
and no error) or "failing", with `reason` built from the last Cloudflare error the sender recorded. The setup steps show
only for "absent". The provider row `email_provider_state` is recreated if missing (`server_cf_email_result` upserts):
live, the status read "absent" while the counts showed Cloudflare sending, which a missing row explains.

## Settings > Usage

"Today: Cloudflare N of 100, Resend M of 100. Cloudflare sends (K left today) | Resend's free plan sends the rest |
Both are used for today ... This month through Cloudflare: X of 3,000." Resend's count includes the sign-in emails
Supabase Auth sends through Resend's SMTP (they are not in the outbox and Cloudflare cannot carry them; moving them is an
Auth SMTP setting, not this release).

## Release

The migration re-queues the emails held only by the old pace or caps (`app.email_release_held`); the claim holds again,
by priority, what today's budgets cannot send.

Tests: `supabase/tests/99_r35_email_cloudflare_first.sql` (status from the last 48 hours, no hourly hold, the 101st
email through Resend, the 191st and 201st held by priority, the month never past 3,000, Resend only after an error).
