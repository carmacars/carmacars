# The automatic monthly owner debit, statement emails with their PDFs, and the company statement sections, October 14, 2026

Migration `supabase/migrations/0037_owner_debit.sql`, tests `supabase/tests/24_owner_debit.sql`, Edge Function
`supabase/functions/owner-debit/`, end-to-end `web/tests/e2e/debit.spec.ts`. No earlier migration was edited; the
functions it changes are wrapped (renamed `_00NN` and called from a new function of the same name) or replaced with
the same signature, as 0029 to 0036 did.

## 1. What was missing

| # | Finding | Now |
| --- | --- | --- |
| 1 | The monthly debit on the 15th and the debit results were "not built" (0029, launch audit item 18): owners had to pay each invoice from its page | Built: notice, debit, results, retries, arrears, exceptions, pauses, run log (section 2) |
| 2 | Monthly fee invoices were created as drafts on the 15th and nothing ever issued them, so owners never saw them and no invoice email went | They are issued on the notice day (10 days before the debit), with the `owner_fee_invoice` email |
| 3 | Owners could give a pre-authorized debit only by paying an invoice with it | Banking > Set up pre-authorized debit (a Stripe SetupIntent, no payment) |
| 4 | The debit agreement text and the Stripe mandate said "the 15th", "the 18th" and "$50" in code | Read from Program settings (`app.owner_debit_terms`) |
| 5 | Statement emails carried a 7-day link only; admin company statements were never emailed and had no PDF | Owner and investor statement emails attach their PDF; the company statements (total, by owner, by vehicle) are three PDFs emailed to the Admins on a set day |
| 6 | The company statement had no income summary by account, held-for-others, HST, receivables, cash by method and payout kind, processor payouts, fleet counts, bookings funnel, investor capital or adjustments to earlier months (0021 "not built") | Twelve sections stored with each build (section 4) |

## 2. The automatic debit

Settings (Admin > Settings > Program settings > "Owner debits and statement emails"): `owner_debit_enabled` (on),
`billing_day` (the debit day, 15), `owner_debit_notice_days` (10), `owner_debit_max_attempts` (2),
`retry_day` (18, the first retry), `owner_debit_retry_gap_days` (3), `owner_debit_run_hour` (6, Toronto),
`owner_debit_poll_hours` (24), `owner_debit_kinds` (monthly, upfront, tracker install, adjustment),
`owner_late_fee_cents` (5000). Nothing about dates, amounts or retries is in code.

| When | What | Where |
| --- | --- | --- |
| Notice day (debit day less the notice days), from the run hour | The month's fee invoices are made and issued; for each owner, one notice (`owner_debit_notice`) listing every invoice due on the debit day, the total and the account; one attempt row per invoice. Without an active mandate: `owner_debit_setup_needed` to the owner, `staff_owner_debit_exception` and an `owner_debit_no_mandate` task to the Admins, nothing scheduled | `app.job_owner_debit_notices` (pg_cron `carmacars-owner-debit-notices`, hourly; the run key is the debit day) |
| Debit day, hourly from the run hour | `app.owner_debit_claim` re-checks each attempt (paid, paused, larger than the notice, no mandate) and hands the rest to the Edge Function, which sends one off-session PaymentIntent per invoice and attempt (`payment_method_types=acss_debit`, the mandate, `confirm`, `off_session`), with the attempt's idempotency key; the answer is recorded (`app.owner_debit_submitted`: payment pending, invoice `processing` or `retry_processing`) | `supabase/functions/owner-debit` (pg_cron `carmacars-owner-debit`, hourly, set by `scripts/deploy/supabase.sh debit`) |
| Days later | Stripe's webhook (`payment_intent.succeeded`, `processing`, `payment_failed`, `canceled`) settles it through `app.owner_debit_result`; the Edge Function also asks Stripe again about any debit still processing after `owner_debit_poll_hours` | `web/src/app/api/webhooks/stripe/route.ts`, `run.ts` |
| Cleared | Invoice paid, `owner_payment_received` | 0029's `record_owner_invoice_payment` |
| Returned | Payment failed with the bank's reason; invoice `failed` (payable again from its page) with the Late Fee once; `owner_payment_failed` (with the retry date and amount) and `staff_owner_invoice_failed`; the next attempt is scheduled after `retry_day` and the gap. After `owner_debit_max_attempts` returned debits: `in_arrears` (0007's task and vehicle flag, `owner_in_arrears`, the Admin email) without a second "we retry" email | `app.owner_debit_fail` |
| Refused at once | A mandate Stripe says is invalid: a failed debit and the method revoked. Anything passing (network, 429, 5xx): sent again on the next run with the same key | `app.owner_debit_submit_error` |
| End of the run | Once nothing of the day is waiting, `staff_owner_debit_run` to the Admins with every debit and its status | `app.owner_debit_run_close` |
| Mandate cancelled at the bank | `mandate.updated` (inactive): method revoked, `owner_bank_details_changed` to the owner, exception to the Admins | `app.owner_mandate_inactive` |

Grouping: **one PaymentIntent per invoice and attempt** (each vehicle's invoice is its own debit, as the owner billing
specification bills each vehicle on its own); the notice groups an owner's invoices of one debit day. PAD rule: a debit
is never more than its notice said; a balance that grew since is skipped with an Admin exception and waits for a new notice.

Admin > Owner debits (`/admin/debits`): the policy in words, next debit and notice days, scheduled and processing
debits (pause one), every owner with their mandate (pause, resume, "Send a notice now"), paused invoices, results,
the run log and the notices. Pauses need a reason and are audited. The owner portal shows the next debit on the home
page, on Banking (account, next debit, processing, paused) and on each invoice ("will be debited on", "sent on",
"returned: reason", "(retry)").

Test owners: `owners.is_test`. Staff notices about a test owner go only to `verify-*@carmacars.ca` accounts, at once
(never into a real Admin's digest), so live tests never email a real person.

## 3. Statement emails with their PDFs

- `owner_statement_email_day` (10) and `company_statement_email_day` (10) are Program settings. Approved owner
  statements are emailed on the owner day of the month after; the company statements (draft or final) on theirs; at
  most 45 days back, so no backlog. The Worker's hourly cron renders and stores each PDF first (`app.statement_mail_due`,
  `app.statement_mail_release`).
- `send-outbox` attaches the PDFs `app.outbox_attachments` names, fetched through the site's signed link (so the stored
  copy): the owner statement, the investor statement, and the three company PDFs (`staff_monthly_statements_pdfs`, and
  `staff_monthly_statements_ready` on finalizing). A file that cannot be fetched holds the email for a retry; the third
  attempt goes without it (the 7-day link stays).
- Admin > Company statements: the twelve sections, PDF, PDF by owner, PDF by vehicle (current version, rendered on
  request) and "Email me the PDFs" (to the Admin asking only).
- PDFs: a header with the logo from Admin > Settings > Site (PNG or JPEG; the red and black wordmark otherwise), a red
  rule, black table headers, banded rows, amounts right-aligned, totals with a red rule. Agreements are not changed (their
  bytes and SHA-256 stay as they were).

## 4. CarmaCars' statement: the sections

Stored in `company_statements.sections` at every build (a final month keeps what it showed): income summary by account
(4000 to 4140, 5000 to 5200, costs entered by category), fleet and rentals (vehicles at start, added, removed, end;
days; utilization; average length and rate), insurer bookings, tolls and damage recovered, held for others (2100 to
2150), HST (collected, on refunds, paid, net), receivables (owners, renters, insurers aged 0/30/60/90), cash (by method
and purpose, refunds, releases, paid out by kind, processor payouts and fees), owner fees and debits, bookings funnel
(requests to confirmed, expired, pushed back, declined, cancelled, no-shows, median hours to first offer), investor
capital, the reconciliation checks in words, and adjustments to earlier months (each final month of the last 12 built
again inside a rolled-back savepoint and compared with its frozen total; only what an earlier statement has not shown
yet is listed).

## 5. Emails added (catalogue 131)

`owner_debit_notice`, `owner_debit_setup_needed`, `staff_owner_debit_exception`, `staff_owner_debit_run`,
`staff_monthly_statements_pdfs`. Rows generated by `supabase/seed/0037_gen_catalogue.mjs` into the migration; templates
loaded by the deploy's templates step. Link paths added: `owner_banking`, `admin_debits`, `admin_reports`.

## 6. Existing assertions changed

| File | Was | Now | Why |
| --- | --- | --- | --- |
| `05_jobs.sql` | 20 cron jobs | 21 | the notice job (runs only where pg_cron exists) |
| `07_notifications.sql` | catalogue 126/1, 60 link paths | 131/1, 63 | the five emails and three paths; the completeness block emits the five |

## 7. Tests and live results

| Check | Result |
| --- | --- |
| Database suite | 24 files, 2,841 assertions, 0 failed (`24_owner_debit.sql` 118: notice day, dates, mandates, claim, submit, clear, return with Late Fee and retry, arrears, pauses, notice amount, cancel, passing and permanent errors, setup and mandate events, poll, run close, test owners, payloads, the twelve sections, PDF facts and access, email days, release, attachments, adjustments, privileges, and the 0038 and 0039 fixes) |
| Unit | `debit-run.test.ts` (the Edge Function's run against a mocked database and Stripe), three new Stripe adapter tests; 52 in all |
| End to end (local, fake Stripe), 375 and 1440 | `debit.spec.ts`: Banking setup, Admin notice, the debit day, one cleared and one returned through signed webhooks, the retry, Owner debits results and run log, company statement sections and three PDFs, email me the PDFs, mandate cancelled; axe and overflow on every page. `owner.spec.ts` passes unchanged |
| Push CI | 38567052375 (0037 and the web), 38572682449 (0038), 38581893808 (0039): green (database, web with every e2e test, audit: crawl, SEO, emails) |
| Deploys | 38569336594 failed at the Worker upload: Cloudflare's free KV write quota (1,000 a day) was used up by the day's deploys (code 10048); the Supabase side had applied 0037. A `page_cache` input (assets) was added; 38569845174, 38575451910 (0038) and 38584588227 (0039) green, migrations history 39 rows, 132 templates loaded, `owner-debit` answering, pg_cron `carmacars-owner-debit` and `carmacars-owner-debit-notices` scheduled |
| Live debit, Stripe test mode | Two test owners (`is_test`, emails to `delivered+...@resend.dev`), each with a mandate made by a SetupIntent with micro-deposits; `setup_intent.succeeded` reached the site's webhook and activated both. Notices sent; the `owner-debit` function sent one off-session PaymentIntent per invoice. Clearing account 000123456789: cleared, invoice paid, receipt sent. Account 000222222227: returned `insufficient_funds` through `payment_intent.payment_failed`, invoice failed, $50.00 Late Fee, retry scheduled for the 18th for $72.60, `owner_payment_failed` sent, the staff notices only to the verification accounts. (900123456789, which Stripe documents as a failure, clears in test mode here.) The poll path settled a debit whose webhook had been missed |
| Live statement email | An approved owner statement of a test owner went out from the statement emails job with `CarmaCars statement ST-1001.pdf` attached (Resend: delivered, attachment 7,848 bytes) |
| Verify | 38577509198 and 38585108876: the owner's Banking debit block, Admin > Owner debits and Company statements all load; the statement job answered 200 (sent 1). Both runs failed on Cloudflare Error 1102 only (19 to 37 requests a run, a different page each time: view as, a link, a refusal page), with the page cache on static assets for the day |

Found by the live run and fixed: the debit facts were sent to the database as a JSON string twice encoded (the debits
were in Stripe with their keys, recorded on the next run with the same keys); a run of test owners only was
summarised to every Admin (0038; one summary email, "Owner debits sent Oct 14", went to the real Admin address before
the fix); a webhook before the run's record was dropped (0038); a failed invoice whose retry could not be sent was never
noticed again (0038); the PDF of a statement of an owner with no sign-in could not be made (0039).

Live test data: the owners "Debit Test Clears" and "Debit Test Returns" (with one sample vehicle each, invoices
INV-1001 to INV-1003 and statement ST-1001) are kept, marked `is_test` and paused, their scheduled retry cancelled and
their task closed. "Sample Owner" (the 20 sample cars) is marked `is_test` and paused too, so the sample cars are never
debited and no staff notice about them reaches a real person.

## 8. For the owner

- **Deploy again after 00:00 UTC** with the default page cache (Actions > ci > Run workflow > deploy, page_cache auto)
  so pages are served from the KV cache again; today's deploys serve them as built, which costs more Worker CPU. The
  Workers Paid plan removes Error 1102 altogether.

- **Stripe live mode**: turn on Canadian pre-authorized debits (ACSS) in the live Stripe account, then put the live keys
  in the vault and deploy (launch audit item 9). The deploy subscribes the webhook to the new events itself.
- **The PAD agreement wording** (`web/src/features/owner/OwnerPayForm.tsx`, `mandateText`) should be read by the lawyer. **Approved by the lawyer on 2026-10-19.**
- **Real owners need a mandate**: owners who have not paid an invoice by debit are asked on the notice day to set one up
  in Banking; Admin > Owner debits lists who has none.
