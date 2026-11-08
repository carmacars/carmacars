# A missed owner debit comes off the next revenue statement by itself (Release 35, part S: 0871, 0872)

Branch `r35-s`. Migration `0871_r35s_missed_debit_statement.sql`; guides in `0872_r35s_gov_forms_guides.sql`. No applied
migration is edited. Test: `supabase/tests/99_r35s_missed_debit_statement.sql`.

The owner's rule (November 8, 2026): every owner is debited on the 15th; only the first invoices an Admin chooses are taken
from revenue; a missed (failed or returned) debit is recovered from the owner's next monthly revenue statement, without
staff doing anything. The fee defaults are unchanged (new owners stay on bank debit).

| Item | What changed |
| --- | --- |
| Checked end to end | A debit returned for insufficient funds is retried once within 30 days (0056); returned again, the invoice is in arrears and the next statement deducts it (the statements-draft job, 5 days before the payout date: a `fees_deducted` line on the car, then from the owner's other cars, the rest carried) |
| Gaps found | A debit returned for another reason (a closed account, a revoked mandate), or for insufficient funds too late to retry, left the invoice `failed` with its debit paused: no statement took it, an Admin had to act. A retry still waiting when the statement was built kept the invoice out of that statement |
| Fix | `app.owner_missed_debits_to_statement`, run by `app.build_owner_statement` (wrapped as `build_owner_statement_pre0871`): each of the owner's invoices still `failed`, with a returned debit and nothing being debited now, goes in arrears (a waiting retry is cancelled, "recovered from the revenue statement"; audited `owner_missed_debit_to_statement`; the owner gets the usual in-arrears email saying it comes off the next payout), so the statement deducts it. An invoice being debited, or paid in between, is left alone |

## Guides

- `admin/owner-money`: a missed debit comes off the owner's next statement by itself.
- `owner/fees-payments-and-payouts`: a missed debit comes off your next revenue statement.
