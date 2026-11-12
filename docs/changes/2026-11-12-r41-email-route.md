# Email route: SES for booking and system email, Resend for marketing, Cloudflare off (Release 41: 2600)

Branch `r41-email-route`. Migration `2600_r41_email_route.sql` (new Program setting `email_cloudflare_enabled`, off by default;
wraps `app.cf_email_left`, `app.cf_email_setup` and `app.marketing_daily_max` as `_pre2600`; publishes the guide chapter below).
No applied migration is edited (2570 included). Tests: `supabase/tests/99_r41_ses.sql`, `99_r35_email_cloudflare_first.sql` (and
the other suites that switch Cloudflare on now also set `email_cloudflare_enabled`), `web/src/lib/email-ses.test.ts`.

The owner (November 12, 2026): "We're stopping paying for Cloudflare; every email goes through Amazon; cancel Resend", then, told
that SES forbids unsolicited marketing: "keep a free marketing sender".

| Part | What changed |
| --- | --- |
| Booking and system email | Every email that is not marketing: Amazon SES first; when SES is not set up, resting, used up for the day or refuses that email, Resend's free plan sends it (never paid). Cloudflare is not used |
| Marketing | Resend's free plan only: never SES (`email_ses_marketing` stays off), never Cloudflare, never a paid plan. The day's marketing allowance (`app.marketing_daily_max`) is Resend's free capacity less what non-marketing email already used of it through the fallback |
| Cloudflare | `email_cloudflare_enabled` (default off) turns Cloudflare sending off: `app.cf_email_left` is 0, so the claim, the day's capacity and the sender's budgets leave it out; Settings > Usage says it is turned off. The code path stays; the site leaves Cloudflare in a later release. Switched on again it sends after SES for non-marketing email only |
| Sender | `send-outbox` never sends marketing through Cloudflare (also not as Resend's overflow); `emailProviderOrder` returns `['ses', 'resend']` for booking and system email and `['resend']` for marketing |
| Admin | Program settings, Email and notifications: the new switch and the reworded copy of the SES, Resend and Cloudflare settings. `docs/email-providers.md` describes the rule |

## Guides

- `admin/email-backups-and-site-health`: who sends what (SES for booking and system email, Resend for marketing and fallbacks, Cloudflare off), the Sent by column and the settings tip.

## Reliability & security

- Booking and system emails keep a second sender (Resend's free plan) when Amazon SES cannot send, and marketing never uses a paid sender
