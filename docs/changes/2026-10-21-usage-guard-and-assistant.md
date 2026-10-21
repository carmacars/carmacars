# Usage guard and staff assistant (migration 0080)

October 21, 2026. Branch `assistant`.

## What the owner asked

1. "I don't want to be paying a lot if the free stuff that's included in my plan runs out. Give me an alert when the included usage for the server and AI and anything else is finished, and it asks me to confirm before we resume paying for usage. Tools should not break but show that they are temporarily unavailable until the next day due to usage limits."
2. A staff assistant in the Admin portal and every staff portal: answers from live data, prepares changes as cards that run only on Confirm, through the same database functions as the screens, under the signed-in person's own permissions.

## Part 1: the usage guard

### The ledger

| Table | What it holds |
| --- | --- |
| `usage_services` | Each metered service: included allowance (Admin-editable in Settings > Usage), period (day, month or a size), early warning (80% by default), what happens when it is used up (`pause`, `hold`, `alert`), the paid rate, how it is measured. Also the last refresh (used, state, the paid allowance for today). |
| `usage_readings` | One figure per service, Toronto day and source (`app`, `cloudflare`, `supabase`, `manual`). Where two sources report a day, the larger counts. A month adds up its days; a size takes the latest day. |
| `usage_decisions` | An Admin's answer: allow paid usage until the end of today or this month, up to US$X, or keep paused. Audited. |
| `usage_alerts` | One row per service, level (80 or 100) and period: one card on Admin > To do and one email. |

### Services and how each is measured

| Service | Included (default) | Measured by | When used up |
| --- | --- | --- | --- |
| Workers AI | 10,000 neurons a day | `provider_calls` neurons (the app's record) and, when reported, Cloudflare's `aiInferenceAdaptiveGroups` | Paused until tomorrow unless paid usage is allowed |
| Worker requests | 10M a month | Cloudflare `workersInvocationsAdaptive` (every Worker of the account) | Never paused; alert with the estimated cost (US$0.30 per million) |
| Worker CPU | 30M ms a month | Same, `cpuTimeUs` | Never paused; alert with the estimated cost (US$0.02 per million ms) |
| Image transformations | 5,000 a month | `provider_calls` transformations | Paused: photos keep their original background, retried later |
| Resend, day / month | 100 / 3,000 emails | The outbox's sent emails plus Supabase Auth's (0043) | Held by the existing priority classes (booking, payment, sign-in first); a plan upgrade is needed to pay |
| Supabase database | 500 MB | `pg_database_size` | Never blocked by us; alert with what to clean or Supabase Pro (US$25 a month) |
| Supabase storage | 1 GB | Sum of `storage.objects` sizes | Same |
| Supabase egress | 5 GB a month | Not readable from the database or the Management API: an Admin enters the figure (Enter a figure) | Same |
| R2 storage | 10 GB | Cloudflare `r2StorageAdaptiveGroups` | Never paused; alert with the cost (US$0.015 per GB a month) |
| GitHub Actions | Free while the repository is public | Not metered | Nothing to pause |
| Claude assistant | US$0 a day | `provider_calls` unit `microusd` (tokens at the prices in Program settings) | Paused: it asks before spending anything |

Note found while building this: every Workers AI call so far was recorded with 0 neurons (the binding often returns no token counts), so the existing daily gates never closed. `integrations/llm/workers-ai.ts` now estimates the tokens from the text when the binding gives none, and the ledger also takes Cloudflare's own count when it is reported.

### Refresh, every hour

- `app.job_usage_refresh()`: pg_cron `carmacars-usage` at minute 11, and the Worker's cron (`/api/jobs/usage`, minutes 10 to 14 of each hour).
- Cloudflare figures: the Worker reads them itself only if it has `CLOUDFLARE_ANALYTICS_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` (none today). Today they come from the new workflow `.github/workflows/usage.yml` (hourly at minute 41, free while the repository is public): `web/scripts/cf-usage.mjs` reads the month to date with the existing `CLOUDFLARE_API_TOKEN` secret and hands it to `app.usage_record_external()` through the Management API. The token needs "Account Analytics: Read"; a dataset it cannot read is a notice, not a failure.

### Alerts

- 80%: one quiet card on Admin > To do (Dismiss) and one email to the alert address of Program settings (`uptime_alert_email`, rent@carmacars.ca).
- 100%: the card "Included Workers AI used up for today: Allow paid usage" and one email. The pop-up shows the rate and an example cost, and asks: allow paid usage until the end of today or this month, up to US$X, or keep paused. Nobody answering keeps it paused.
- Quiet: once per service, level and period; never during the site check's quiet hours (they wait for the morning); at most `usage_alert_max_emails` (4) a day. When 100% is reached the 80% email is skipped.
- Email `staff_usage_alert` (emails/src/emails/staff_usage_alert.mjs; catalogue rows generated by `supabase/seed/0080_gen_catalogue.mjs`).

### Pause behaviour per feature

| Feature | While paused |
| --- | --- |
| AI live chat | The visitor reads "Our assistant is resting until tomorrow. A person will answer you here" and the chat goes to staff (handoff), also when Workers AI itself refuses for its quota |
| AI listing copy and search copy | Wait for tomorrow (their existing gates now stop at the included neurons); the template text stays |
| Turo email reading | Rules only; emails the rules cannot read wait in the review list |
| Photo studio backgrounds | The original photo goes on the site (no transformation spent), flagged; `app.usage_retry_photos` queues the background again once transformations may be used |
| Staff assistant | "The assistant is unavailable until tomorrow (daily included usage reached). Everything still works from the screens and pop-ups." |
| Emails | The existing priority holds (booking, payment, security first); a banner on Admin > To do while emails are held |
| Website requests and CPU | Never paused (that would stop bookings): the card says so, with the estimated overage cost |
| Database and storage size | Alert at 80% with what to clean or the upgrade; writes are never blocked by us |

How the gates work: `app.settings()` (0001) is wrapped. The daily Workers AI gates of 0032, 0042, 0060, 0061 and 0063 read `chat_ai_total_daily_neurons` and `listing_ai_daily_neurons`; they now stop at the smaller of the setting and the included neurons, plus what a paid-usage decision allows today (cap / US$0.011 per 1,000). The email caps never exceed Resend's included emails. Stored Program settings are untouched (Admin edits read the table itself).

### Admin

- Admin > To do: the usage cards and the held-emails banner (`ops_read usage_cards`).
- Admin > Settings > Usage (`/admin/settings/usage`): every service with a meter, used against included, reset time, paid usage and cap, rate, how measured, the last 30 days (chart and table), Change the allowance, Enter a figure, the recent alerts.

## Part 2: the staff assistant

- A button "Assistant" in the header of the Admin, VA and field portals, and Ctrl+/ (Cmd+/). Esc closes. Off while viewing as someone.
- `POST /api/staff/assistant`: a question, or Confirm or Cancel on a card. The person must have the portal's role (and two-step sign-in when required).
- Model: Workers AI Llama 3.3 70B (`@cf/meta/llama-3.3-70b-instruct-fp8-fast`, JSON step schema) by default; Claude through Anthropic's Messages API with native tool calling when the Worker has `ANTHROPIC_API_KEY` (model and prices in Program settings: `assistant_claude_model`, default `claude-haiku-4-5`, US$1 and US$5 per million tokens; check them against Anthropic's price list). A deterministic stub locally and in the tests. Both real models go through the usage guard (`workers_ai` with its own daily share `assistant_daily_neurons` 3,000, or `claude` with US$0 included).
- Small requests: a short system prompt with only the person's tools, the last 6 turns, one model call per message (a read's result is the answer; no second call).
- Tools (schemas in `web/src/features/assistant/tools.ts`, checked with zod; names looked up in the database; ambiguity is a question listing the candidates):

| Tool | Kind | Door |
| --- | --- | --- |
| today | read | `ops_read admin_todo`, `va_read digest` and `queue`, `field_read jobs` |
| find (booking, renter, owner, car, invoice, toll) | read | `ops_read assistant_find` (scoped by portal and function) |
| availability | read | `search_available` (public) |
| who_has_car | read | `assistant_find car_now` |
| owner_balance | read | `assistant_find owner_balance` (Admin, Finance) |
| draft_message | draft | none: staff copy and send it |
| record_payment | change | `ops_do manual_payment_record` |
| add_rental (upcoming, underway or past) | change | `ops_do manual_rental_create` (payment link or paid another way) |
| publish_car | change | `admin_do` / `va_do listing_publish_now` |
| set_rates | change | `ops_do rate_card_save` |
| send_payment_link | change | `admin_do` / `va_do resend_offer` (booking), `ops_do owner_invoice_resend` (owner invoice) |
| confirm_toll | change | `admin_do` / `va_do toll_confirm` |
| create_task | change | `ops_do task_create` (new: Admin any queue, an assistant their own queue or the Admins') |

- Mark a car insured: skipped. The guided branch's function (0077) is not on main; the assistant says it is done on the car's page.
- Every change: `app.assistant_propose` stores the card (portal, door, function, arguments, the assistant's function); `app.assistant_confirm` runs it through `app.door` as the person, inside one transaction marked `app.via = 'via assistant'`. The audit log gets an `assistant_action` row (actor: the staff member, note "via assistant"), and every audit row written by the action carries `request_id = 'via assistant'` (a column default, so `app.audit_row` is not changed). A refusal marks the card failed with the reason (audited); a card runs once, only for the person who asked, within 30 minutes.

## Tests

- DB: `supabase/tests/60_usage_guard_assistant.sql` (102 assertions): ledger and sources, thresholds and once-per-period alerts, the email (address, quiet hours, daily maximum, values), pause by default, allow up to a cap and keep paused, never-paused services, Admin-only pages and answers, assistant reads by portal and function, propose and confirm through the door, a VA refused an Admin's action, audit actor and "via assistant", Cancel and expiry, Claude's US$0 budget.
- Unit: `web/src/features/assistant/assistant.test.ts` (tool lists, argument checks, card texts, the one-call flow, ambiguity, paused states and their words, the stub and the Claude adapter), `web/src/features/usage/usage.test.ts` (paused photos, Toronto days, the Cloudflare figures).
- End to end: `web/tests/e2e/assistant-usage.spec.ts` at 375 and 1440 (run with `--workers=1`: it changes the day's Workers AI figures): the usage card and pop-up, Settings > Usage, the Admin assistant (header button, Ctrl+/, a read, a confirmed change audited "via assistant", Cancel, a question listing the candidates), a VA refused an Admin's action, the paused assistant, a visitor's live chat while the assistant rests.
- Results on October 21: the whole database suite 4,699 assertions passed (`scripts/test.sh`, `ALL TESTS PASSED`); unit 59 passed (the two new files with the listing worker and chat guardrail tests); the five end-to-end tests passed at 1440 and at 375. The machine was short of memory (other builds running), so `next build` was killed by the system each time: the end-to-end tests ran against `next dev`, each test on its own when a browser tab crashed for memory. Typecheck of every new and changed file and its imports passed; ESLint passed.
- Also fixed for axe: the live chat's message log (and the assistant's) can take keyboard focus (a scrollable region).

## Not done

- Supabase egress is entered by hand (no API reads it).
- Cloudflare's GraphQL dataset and field names for Workers AI neurons and R2 were written from the documentation and could not be tried here (no Cloudflare token in this environment); a part the token cannot read is reported by the workflow and skipped. The app's own neuron record always counts.
- Image transformations served by `/cdn-cgi/image` (if any) are not counted; the photo worker's are.
