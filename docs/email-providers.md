# Email providers

The send-outbox Edge Function (`supabase/functions/send-outbox/index.ts`) sends every email the site queues. The owner's rule
(November 12, 2026; release 41, migration 2600):

| Email | Order |
| --- | --- |
| Booking, payment, sign-in, staff, owner and every other email that is not marketing | 1. **Amazon SES** (region `ca-central-1`), when its keys are set, the Program setting `email_ses_enabled` is on (default) and today's SES sends are under `email_ses_daily_max` (default 200 while the SES account is in the sandbox). 2. **Resend's free plan**, up to `notify_resend_daily_budget` a day, when SES is not set up, is resting, is used up for the day or refuses that email. |
| Marketing (category `marketing`: the weekly and new car campaigns included) | **Resend's free plan only**, up to `notify_resend_daily_budget` a day. Never SES (SES production access is requested for transactional email, and AWS's terms want recipients who asked for the email), never Cloudflare, never a paid plan. |

**Cloudflare Email is not used.** The Program setting `email_cloudflare_enabled` (default off) switches it off: the database
reports a Cloudflare budget of 0 (`app.cf_email_left`), so the claim, the day's capacity and the sender's budgets leave it out.
The code path stays for now; the whole site leaves Cloudflare in a later release. If it is switched on again, it sends after
SES for non-marketing email only, never marketing.

The marketing allowance of the day (`app.marketing_daily_max`, with `marketing_auto_volume` on) is Resend's free capacity
(`least(notify_daily_cap, notify_resend_daily_budget)`) less what non-marketing email already used of Resend's day through the
fallback. The Program setting `email_ses_marketing` (off) would add SES's day to it and let marketing use SES.

When Resend's day is used the claim holds the emails by priority (booking, payment and sign-in first).
Admin > Settings > Logs > Emails shows who sent each email (column Sent by), and the Why column says when an email went
through Resend after an SES refusal.

## Cost

SES is paid per use (about USD 0.10 per 1,000 emails, attachments by size). The owner approved it as the main sender for
booking and system email on November 12, 2026: it is the one exception to the rule "never on a paid plan", and it is held at
`email_ses_daily_max` a day. Resend stays on its free plan; the owner stops paying for Cloudflare.

## What SES refusals do

| SES answers | What happens |
| --- | --- |
| Throttling (429, `TooManyRequestsException`, maximum sending rate) | The email waits a minute and goes again; its attempts are not counted |
| `MessageRejected` (for example a recipient the sandbox has not verified) | Resend sends that email; SES stays first for the others |
| Anything else (bad keys, sending paused, the account's daily quota, the domain not verified, an outage) | Resend sends that email, and SES rests 15 minutes (`email_provider_state.ses_failed_at`) |

Without the keys the function skips SES: nothing changes: Resend sends everything.

## Setting SES up (the owner)

1. In the AWS console, region **Canada (Central) ca-central-1**, open Amazon SES and create the identity `carmacars.ca`
   (domain, Easy DKIM, RSA 2048). Set a custom MAIL FROM domain, for example `mail.carmacars.ca`.
2. Add the DNS records the SES console shows in Cloudflare DNS: the three DKIM `CNAME` records, and for MAIL FROM one `MX`
   record (`feedback-smtp.ca-central-1.amazonses.com`, priority 10) and one `TXT` record (`v=spf1 include:amazonses.com ~all`).
   Copy them from the console; do not type them by hand.
3. Create an IAM user with only the permission `ses:SendEmail` and `ses:SendRawEmail` and make an access key for it.
4. In GitHub, carmacars/carmacars > Settings > Secrets and variables > Actions, add the repository secrets
   `AWS_SES_ACCESS_KEY_ID` and `AWS_SES_SECRET_ACCESS_KEY` (paste the values; they are never committed). Optional
   repository variables: `AWS_SES_REGION` (default `ca-central-1`) and `AWS_SES_CONFIGURATION_SET`.
5. The next deploy (ci workflow, `scripts/deploy/supabase.sh outbox`) gives the function its secrets. SES sends from the
   next minute.
6. While in the sandbox, SES sends only to verified addresses: the others go through Resend on their own.
   Request production access in the SES console; once granted, raise `email_ses_daily_max` in Admin > Settings > Program
   settings, Email and notifications.

## Bounces and complaints

SES keeps its own account-level suppression list (bounced and complaining addresses are not sent to again), and AWS watches
the bounce and complaint rates. To record them here as well, create a configuration set in the SES console with an event
destination (SNS topic) for Bounce and Complaint, and set the repository variable `AWS_SES_CONFIGURATION_SET` to its name:
every SES email then carries it. Feeding those events into Blocked addresses (`email_suppressions`) needs a webhook that
checks SNS signatures; it is not built yet.
