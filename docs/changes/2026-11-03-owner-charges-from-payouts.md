# Owner charges deducted from payouts (0238)

The owner, Release 23 (real money): an owner invoice (the first and last month, a one-off fee such as the registration
costs) could only be debited from the owner's bank on the 15th, marked paid, kept as a draft or skipped.

- **How it's paid** on every owner invoice (`owner_invoices.collect_by`): **Bank debit on the 15th** (as before) or
  **Deduct from payouts**. An invoice deducted from payouts is issued quietly (no debit email), never debited (the debit
  run passes it by, `app.owner_debit_block`), and scheduled debits of it are cancelled.
- **The statements deduct it** like an unpaid invoice (`app.build_owner_statement`): a "fees_deducted" line on its car for
  as much as that car's payout allows (Fees with HST first), then "arrears_moved" lines from the owner's other cars, and
  what is left waits for the next statement until paid. Approving the statement records what was taken (partially
  deducted, then deducted). The owner sees each as an itemized deduction (the invoice and the amount); Admin sees the
  amount deducted and the balance on the invoice screen.
- **Where it is chosen:** the invoice screen (**How it's paid**, Change), the first and last month decision (Terms tab:
  **Deduct from payouts**, which, like No invoice, does not hold the car back after signing), the approval step (Deduct from
  payouts), and **Charge the agreed one-off fees** on the owner's Terms tab: the one-off fees agreed on the owner's terms
  (all, or the ones named) as one invoice for a car, deducted from payouts or debited.
- **Existing invoices are not changed by the migration.** After the release an Admin converts them: open the draft
  invoice noted "deduct from payouts, do not issue", **How it's paid**, Change, Deduct from payouts (it is issued quietly
  and the statements take it); and **Charge the agreed one-off fees** for each of that owner's cars.
- Tests: `supabase/tests/99_release_23.sql` section 12.

## Guides

- `admin/owner-money`: How it's paid: bank debit or deducted from payouts.
