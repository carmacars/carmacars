# Release 35: no HST on the owner Insurance Fee (0873)

Migration `supabase/migrations/0873_r35_no_hst_on_insurance.sql`. SCHEMA_MARKER 0873.

The owner, November 8: "don't charge HST on insurance payments".

- Owner invoice lines for the Insurance Fee (monthly, first month, last month) and the prepaid credit that offsets it
  carry no HST. Tracker, install, registration and custom lines keep their HST.
- Program settings: "Charge HST on the owner Insurance Fee" (`insurance_fee_hst`), off by default.
- Open invoices with nothing paid yet lose the HST on their insurance lines; their totals follow.
- Invoices already paid keep what was charged; `app.insurance_hst_charged()` lists them for an Admin to credit or refund.
  Nothing is refunded by itself.
- The test suites run with the setting on (they assert the older totals); `99_r35_no_hst_on_insurance.sql` checks the
  default.

## Guides

No guide change: the owner guides do not state HST on the Insurance Fee.
