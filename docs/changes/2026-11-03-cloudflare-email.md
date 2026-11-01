# Cloudflare Email Service first for the outbox, Resend after (0222)

The owner: Workers Paid includes 3,000 emails a month through Cloudflare Email Service (then US$0.35 per 1,000, beta). The
outbox sends through Cloudflare first and falls back to Resend when Cloudflare fails or its month's included emails are
used; Supabase Auth's sign-in emails stay on Resend; "held until midnight" applies only when both are unavailable.

- send-outbox (the Edge Function on our server, every minute): while `app.cf_email_available()` (Program settings
  cf_email_enabled, on; fewer Cloudflare sends this month than cf_email_monthly_included, 3,000; no Cloudflare failure in
  the last 15 minutes), each rendered email is posted to the site's `/api/email/send` (signed with LINK_SIGNING_KEY like
  the cron jobs), which sends it with the Worker's `EMAIL` binding. A refusal is recorded (`server_cf_email_result`,
  Cloudflare rests 15 minutes) and that email goes through Resend as before.
- An email sent by Cloudflare keeps `provider_id` `cf:<id>`; its message row says provider cloudflare.
- Resend's daily and monthly limits (0018) count Resend's sends only, and hold nothing while Cloudflare may send.
- Settings > Usage: "Emails this month (Cloudflare Email Service)", 3,000 included.

## Setup the owner does once (nothing changes until then: the outbox keeps sending through Resend)

1. Cloudflare dashboard, the account of carmacars.ca: **Compute (Workers) > Email Service** (Email Sending): enable it
   (beta; request access if the page asks).
2. Add the sending domain **carmacars.ca** and add the DNS records it shows (SPF include, DKIM). Keep Resend's records:
   both can sign for the domain. Check the From addresses the outbox uses (bookings@, hello@, ... on carmacars.ca).
3. GitHub, the repository's **Settings > Secrets and variables > Actions > Variables**: add `CF_EMAIL_BINDING` = `1` (0321: `true`, `yes`, `on` or `EMAIL` work too).
   The next production deploy adds `"send_email": [{ "name": "EMAIL" }]` to the Worker (ci.yml) and says so in the run.
4. After the deploy, Settings > Usage shows "Emails this month (Cloudflare)" counting up. If Cloudflare refuses, the
   reason is in `email_provider_state.cf_error` and the emails go through Resend.

The binding's message shape follows the Email Service beta (`env.EMAIL.send({ to, from, subject, html, text, replyTo,
headers, attachments })`); if Cloudflare changes it, the route answers the error and Resend sends.

## Guides

- `admin/usage-and-paid-usage`: Emails through Cloudflare first.
