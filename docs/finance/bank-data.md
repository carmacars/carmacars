# Bank data for the Finance dashboard (release 49)

The owner (Nov 20): "RBC new account may have API access for payouts and balances: check, then build a finance
dashboard." This note is what was checked on 2026-11-23, the path chosen, and what the owner does to connect the bank.

## What exists

| Route | What it gives | Who can use it | Verdict for CarmaCars (a small Ontario corporation, one RBC business account) |
| --- | --- | --- | --- |
| RBC Balance and Transactions API (RBC's business APIs) | Real-time balances and transactions. The same family has Move Money (Interac e-Transfer), RBC Pay, Tracking and Validation APIs | Business clients, by request through their RBC advisor. RBC publishes no price, no self-serve sign-up and no eligibility rule ([RBC business APIs](https://www.rbcroyalbank.com/business/api/index.html)) | **Ask the advisor first.** It is the bank's own API, needs no third party, and would also answer the payouts question. It is most likely tied to RBC Express, RBC's enterprise platform (unlimited users, host-to-host files, "automated file-based integrations into client ERP for large volume transactions and reconciliation"; [RBC Express](https://rbcroyalbank.com/business/ways-to-bank-for-business/rbc-express-online-banking.html)). RBC Online Banking for Business, the small business tier, supports one user and lists no API ([RBC Online Banking for Business](https://www.rbcroyalbank.com/business/ways-to-bank-for-business/rbc-online-banking-for-business.html)) |
| RBC's 2018 developer portal | Location, rates and similar public data | Developers ([Finextra, 2018](https://finextra.com/newsarticle/31842/royal-bank-of-canada-opens-api-developer-portal)) | No account data; not usable |
| Canada's consumer-driven banking framework (open banking) | Read access to deposit, payment, investment and loan account data, with consent, for individuals **and businesses** | The Consumer-Driven Banking Act received royal assent in March 2026; the proposed Regulations were prepublished on June 27, 2026 for a 60-day comment period. Large banks above a retail volume threshold must take part; third parties need Bank of Canada accreditation ($2,500 application, $10,000 a year) ([Canada Gazette, Part I, June 27, 2026](https://gazette.gc.ca/rp-pr/p1/2026/2026-06-27/html/reg3-eng.html); [DLA Piper, April 2026](https://www.dlapiper.com/en-ca/insights/publications/2026/04/the-new-consumer-driven-banking-act-explained)) | **Not live yet.** No go-live date for read access was published as of this check; write access (payments) is aimed at mid-2027 at the earliest, after Real-Time Rail. CarmaCars would use it through an accredited aggregator, not directly |
| Plaid (Canada) | Balances and transactions through an RBC data access agreement (a direct API, no shared password) | RBC clients, through apps on Plaid's network ([FinTech Futures](https://www.fintechfutures.com/?p=15253369); [Finextra](https://www.finextra.com/pressarticle/93056/rbc-connects-with-plaid)) | Possible, but the announcements speak of personal banking and do not say business accounts are covered. A Plaid production account for Canada is a sales process with monthly fees |
| Flinks (Montreal) | Balances and transactions, read only, with consent | RBC is supported; "business accounts may have limited support" ([Open Banking Tracker, January 2026](https://openbankingtracker.com/flinks/royal-bank-of-canada); [Flinks Connect](https://flinks.com/products/connect)) | Possible fallback; same caveat on business accounts; paid per connection |
| RBC online banking export | Transactions as CSV (also Excel; OFX for Quicken and Money), up to 7 years of history on RBC Edge ([RBC Edge](https://www.rbcroyalbank.com/dms/business/campaign/rbcedge/)) | Anyone with online banking | **Always available, free.** Built now |

RBC's classic CSV download has the columns `Account Type, Account Number, Transaction Date, Cheque Number, Description 1,
Description 2, CAD$, USD$`, dates as M/D/YYYY and one signed amount per currency (negative is money out); the download
holds the transactions posted up to the last business day ([a converter that reads it](https://github.com/mominoes/monarch-import)).
RBC Edge's newer export may name its columns differently (Date, Description, Debit, Credit, Balance), so the reader maps
columns by their header, not by position.

## The path chosen

1. **Now: file import (always on).** Finance or an Admin downloads the account's CSV or OFX from RBC online banking and
   drops it on Admin > Company > Finance (Finance: Money > Finance). The browser reads the file
   (`web/src/features/finance/bank-file.ts`), the database stores each line once (`app.bank_import`, migration 3480):
   - OFX lines are keyed by their FITID; CSV lines by date, amount and description, with the line's position among
     identical lines of the same file, so the same file twice, or two overlapping downloads, add nothing.
   - Only the last four digits of the account number are kept, plus a SHA-256 of the full number to recognise the account.
   - The balance: OFX carries it (LEDGERBAL); a CSV with a Balance column gives the last one; otherwise the person types
     the balance shown in online banking.
2. **Reconciliation.** Each new line is matched automatically when exactly one record fits: money in to a Stripe payout
   (same amount, within the match window) or to an e-Transfer or bank transfer recorded on a booking or owner invoice; money out to an
   owner payout, a commission payout or an expense. Anything else is a To do for Finance after two days (Program
   settings), with a morning digest email, and is matched by hand or set aside with a reason (a bank fee, a transfer
   between CarmaCars accounts).
3. **Next: a live feed through the adapter** (`web/src/integrations/bank/`: `BankFeed`, with a fake for tests). The
   feed writes through the same `bank_import`, so dedupe and matching are the same. Order of preference:
   1. RBC's own Balance and Transactions API, if the advisor offers it on CarmaCars' plan at a sensible price.
   2. An aggregator (Flinks or Plaid) once it confirms RBC business accounts in writing.
   3. An accredited provider under the consumer-driven banking framework once read access is live.
   Program setting `bank_data_provider` stays `file` until one is connected.

## What the owner does to connect RBC

1. Call the RBC business advisor (or 1-800-769-2520) and ask: "Is the RBC Balance and Transactions API available on our
   business account, does it need RBC Express, and what does it cost?" Ask the same for the Move Money (e-Transfer) API
   for owner payouts.
2. Until then, once a week (or before each payout run on the 10th): RBC online banking, the account, Download
   transactions, CSV or OFX (OFX also gives the balance), and drop the file on the Finance page. Finance can do this too
   if given online banking access to view.
3. If RBC offers the API: send its onboarding pack to the build; the `rbc_api` adapter is written against it and the
   setting is switched. Never paste online banking passwords into the platform.
