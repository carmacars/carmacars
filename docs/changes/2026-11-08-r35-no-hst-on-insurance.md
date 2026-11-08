# Release 35: no HST on the owner Insurance Fee or the Registration Fee (0873)

Migration `supabase/migrations/0873_r35_no_hst_on_insurance.sql`. SCHEMA_MARKER 0873.

The owner, November 8: "don't charge HST on insurance payments", "nobody has paid HST" and "All the registration cost
per car were also not HST applicable either". The amounts the owner gave on November 7 (for example $284 a car a
month for 2.5 months, $350 a car for two months plus $59 plates, first and last month at $350) were the amounts paid,
without HST; the invoices made from them had added HST and been marked paid at the higher total.

- Owner invoice lines for the Insurance Fee (monthly, first month, last month), the prepaid credit that offsets it and
  the Registration Fee carry no HST, and so do lines typed by hand (custom, adjustment) that are the Insurance Fee,
  registration or plates (`app.owner_line_no_hst`). Tracker, install and other custom lines keep their HST.
- Program settings: "Charge HST on the owner Insurance Fee" (`insurance_fee_hst`), off by default.
- Every invoice that is not void loses that HST now; its total follows. Prepaid months lose theirs too.
- An invoice that was fully paid by a payment recorded by hand (paid outside the platform) has that payment corrected
  to the new total, so it equals what the owner actually paid; the payment's note says so and the change is audited
  (`owner_payment_hst_corrected`). Payments through the card processor or taken from a payout are never changed;
  `app.insurance_hst_charged()` lists anything left for an Admin.
- The test suites run with the setting on (they assert the older totals); `99_r35_no_hst_on_insurance.sql` checks the
  default and the hand-typed lines.

## Guides

No guide change: the owner guides do not state HST on the Insurance Fee.
