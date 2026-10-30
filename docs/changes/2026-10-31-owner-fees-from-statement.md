# Owner fees taken from the revenue statement (0204)

Release 21, item 5. Migration `supabase/migrations/0204_owner_fees_from_statement.sql`. Tests:
`supabase/tests/99_owner_fees_from_statement.sql`.

- Per owner, **How fees are paid** (`owners.fees_paid_from`): Bank debit (the default) or Take from revenue statement.
  Set by an Admin from the owner's page (the **Fees** button, door `ops_do` `owner_fees_paid_from`).
- An owner on the statement: their monthly, adjustment, tracker install and custom invoices are marked
  `owner_invoices.from_statement` when issued (never the upfront invoice, due before the first rental); the debit skips
  them (`owner_debit_block`: "taken from the revenue statement"). Switching takes the invoices still due along.
- The owner statement (`build_owner_statement`, then `app.owner_statement_take_fees`): each such invoice billed by the
  end of the month is taken from the payout, its own car first, then the owner's other cars, never below zero, as the
  line "Invoice INV-..., paid from statement" (`fees_deducted`). Approved, the invoice is deducted ("Paid from
  statement") or partly deducted; the rest is taken by the next statement.
- Still owing 2 months after its billing date (checked daily with the debit notices and on every statement build): back
  to the bank debit after the notice days, and an Admin task "Invoice ... back to the bank debit".
- The owner portal and Admin say "Paid from statement", "Part paid from statement", "Taken from your next statement".

## Guides

- `admin/owner-money`: Fees taken from the revenue statement.
- `owner/fees-payments-and-payouts`: Fees taken from your statement.
