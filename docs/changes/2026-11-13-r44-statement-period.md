# Owner statement periods: a partial month is named, a hidden booking never sets the start (Release 44: 2783)

Migration `2783_r44_statement_period.sql`.

- **Partial month**: a statement whose period is shorter than a full period (usually a car's first) shows "This statement covers a partial month (Oct 24 to Nov 7, 2026), not a full month." on the statement page for Admin, in the owner portal and on the PDF. The issued statements get it too: their stored PDF is made again on the next download.
- **Where the first period starts**: at the first booking the owner sees and that counts for them, or the car's program start (its enrollment date), whichever is first. A booking hidden from the owner (an insurer replacement hidden from them, a booking never shown) no longer sets it, so the period no longer reveals it. Every owner's first statement was put right once.

## Guides

No guide change: no step changes; the statement itself says when it covers a partial month.
