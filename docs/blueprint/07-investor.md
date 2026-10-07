# 07. Investor area

Owner: workstream E. Routes under `src/app/investor/`; features in `src/features/investors/`. Scope set by the owner: **an area limited to statements for existing investors.** No public page, no sign-up, no offering material, no calculator, nothing that could be read as soliciting an investment. Source: `docs/source/v2_investment.md`.

## 1. Access

| Rule | Detail |
| --- | --- |
| Who | A user whose id is in `investors.user_id` with `investors.status = 'active'` (or `exited`, read-only). There is no `investor` value in `app_role`; the guard is `app.is_my_investor()` |
| How they get in | An admin invites an existing investor from `/admin/investors/[id]` (`inviteInvestor`: creates the auth user, `users (status = 'invited')`, links `investors.user_id`). No self-registration. The sign-in page has no link to this area |
| Sign-in | Email link, then two-step sign-in is required (TOTP) |
| Not indexed | `robots.txt` disallows `/investor`; pages carry `noindex`; the area is absent from the sitemap and from all navigation for other roles |
| What they can read | Their own `investors`, `investor_bank_accounts` (last four only on screen), `investment_agreements`, `investments`, `investment_elections`, `investment_returns`, `investment_redemptions`, `investment_transfers`, and `documents` of the investor kinds (existing row-level security policies) |
| What they can change | Nothing directly. Two requests are server actions that create an admin task: change of reinvestment election, change of bank account |

## 2. Routes

### `/investor` Home

| Item | Detail |
| --- | --- |
| Layout | P and D: a single column, 720 px maximum. Header with the investor's legal name. Cards per investment |
| Card content | Invested Amount today (`investments.invested_amount_cents`), principal, reinvested to date, redeemed to date, Yearly Percentage (`yearly_bps`), Investment Date, Lockup End Date ("No return is earned for the lockup period" until that date), current election (paid monthly or reinvested, from `app.investment_mode()`), next Payment Date (the 15th of the month after each Return Month) |
| Latest statement | Month, Return, paid or reinvested, link |
| Notices | A redemption notice from the Company (`investment_redemptions` with status `noticed`): amount and Redemption Date. A return on hold (`investment_returns.status = 'held'`) with the reason, for example tax information outstanding |
| Empty | During the lockup: "Your first Return Month starts on [Lockup End Date]. Statements will appear here." |

### `/investor/statements` and `/investor/statements/[id]`

List: one row per `investment_returns` row: Return Month, opening Invested Amount, days earning of days in month, Return, paid or reinvested, Payment Date, status, PDF.

Statement (screen and PDF, `documents.kind = 'investor_statement'`), as section 3.6 of the agreement requires (the Return, whether it was paid or reinvested, and the Invested Amount):

| Line | Source |
| --- | --- |
| Investor, agreement number, statement month | `investors.legal_name`, `investment_agreements.agreement_number`, `investment_returns.return_month` |
| Invested Amount at the start of the month | `opening_invested_cents` |
| Yearly Percentage | `yearly_bps` |
| Days earning in the month | `days_earning` of `days_in_month` |
| Return for the month | `return_cents` (from `calc_investment_return()`) |
| Tax withheld, if any | `withheld_tax_cents` |
| Paid to your account ending [last four] on [date], or Reinvested on [last day of the month] | `disposition`, `status`, `payouts.paid_at`, `payouts.reference` |
| Invested Amount at the end of the month | `closing_invested_cents` |
| Footer | "This statement is given under section 3.6 of your Investment Agreement. The Company gives no tax advice." Company legal name and address |

Buttons: Download PDF. Year view: "Download all [year] statements" (a ZIP built by an Edge Function) and a yearly summary table (returns paid, returns reinvested, tax withheld) as CSV.

### `/investor/documents`

The signed Investment Agreement, Schedule A (and each updated Schedule A), Schedules C and D, notices, statements. Open and download only.

### `/investor/profile`

Contact details (read-only; "Ask us to update"), bank account last four, two-step sign-in settings.

| Request | Form | Action |
| --- | --- | --- |
| Change how returns are handled | Radio: pay monthly / reinvest. The page shows the rule: a change applies from the first Return Month that starts at least 10 days after CarmaCars receives it, with the computed month (`calc_election_effective_month()`) | `requestElectionChange` -> admin task with the request; an admin records `investment_elections (received_on = the request date, notice_document_id)`. Emits `investor_notice_received` once the admin records it |
| Change bank account | Account holder (must be the investor's name), institution, transit, account number | `requestInvestorBankChange` -> admin task; the admin verifies by a known phone number and saves (`investor_bank_accounts`, encrypted, `notified_on`; a change applies 10 days after notice). Emits `investor_notice_received` to the contact details on file before the change |

No other action exists: an investor cannot request repayment from the portal (the agreement gives no right to demand it; a purchase request under section 7.3 is made in writing to an admin and recorded by them).

## 3. Emails

Codes from `emails/catalogue.json`. Investor emails are neutral servicing notices; the email checker requires the line that they are not an offer or a solicitation.

| Code | When | Content |
| --- | --- | --- |
| `account_sign_in_link` | An admin invites an existing investor | Sign-in link |
| `investor_statement_ready` | The monthly statement is issued | "Your [month] statement is ready" with a link |
| `investor_return_paid` | The return's payout is marked paid on the 15th (not sent for a reinvested return) | Amount and date as the template provides |
| `investor_notice_received` | An admin logs a notice from the investor: an election change, a bank change, a contact change. Requests made from `/investor/profile` are logged by the admin who handles them, which sends this acknowledgement | What was received and what happens next |
| `investor_return_held` (to be added) | A return is put on hold | The reason and what is needed |
| `investor_redemption_notice` (to be added) | An admin issues a redemption notice | A formal notice document; the email links to it |

## 4. Admin: investor records (`/admin/investors`, `/admin/investors/[id]`)

Admin only. No VA policy exists on any investor table.

| Tab | Content | Actions |
| --- | --- | --- |
| Register | Legal name, type, address, contact, tax residency, tax information complete, identification verified, status | `saveInvestor`; `inviteInvestor`; mark exited |
| Agreement | Agreement number, status, Schedules C and D documents, legal advice choice, exemption category and paragraph, verification notes, exempt distribution report date, company signed date | Upload signed documents (signed outside or on screen through `SignDocument`); `setAgreementSigned` (the database requires Schedules C and D, an exemption category and the legal advice choice) |
| Investments | Each amount: principal, Yearly Percentage, Investment Date (cleared funds), Lockup End Date (set by the database to six months later), reinvested, redeemed, status | `addInvestment` (minimum initial $20,000 from `program_settings.investor_min_cents`; an additional investment needs an updated Schedule A document) |
| Elections | History and the mode in force for each month | `recordElection` |
| Returns | Per month: opening amount, days, return, disposition, payment date, status, payout | Generated on the 1st by `app.accrue_investment_returns()` (job `returns-accrue`). "Hold" with a reason; "Release"; "Create payout" for the 15th (`payouts (kind = 'investor_return')`, approved by an admin, paid by bank transfer, then marked paid: `app.investor_payout_paid()` updates the return) |
| Redemptions and transfers | Notices, requests, consents | `issueRedemptionNotice` (six months' notice unless a shorter-notice document is attached), `recordPurchaseRequest`, `recordTransfer` |
| Statements | Generated PDFs with sent times | `generateInvestorStatement` (also run by the `investor-statements` job after the 15th payout or the month-end reinvestment), resend |
| Bank | Last four, notified date | Change (admin only, encrypted) |

## 5. Database additions needed

| Addition | Purpose |
| --- | --- |
| Job `investor-statements`: for each `investment_returns` row that is `paid` or `reinvested` without `statement_document_id`, render the PDF and emit `investor_statement_ready` | Automatic monthly statements |
| `investor_requests (id, investor_id, kind, payload jsonb, status, created_at, handled_by, handled_at)` or reuse `tasks` with `related_table = 'investors'` | Section 2 requests; reuse of `tasks` is enough at launch |
| No new row-level security: existing `self_read` policies cover every table the area reads | |
