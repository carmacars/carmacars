# Staff emails in plain words, each debit amount explained, the fee check and the debit preview (release 29, C4, migrations 0583 and 0584)

Branch `r29`. SCHEMA_MARKER 0584. The owner, November 6: the "Owner debit exception" email was insanely confusing, and
the debit emails carry "random amounts".

## What changed

- **Staff emails in plain words** (0583, section 4): each staff email that used the system's words (exception, mandate,
  run key, webhook, usage guard) says what happened, how much, what to do, with one button.
  - `staff_owner_debit_exception`: "Can't collect $X from <owner>: <reason>". One sentence ("We were going to take $X
    from <owner>'s bank on <date> for <invoices>, and we can't: <reason>"), each amount in one line, What to do, one
    button. Reasons (`app.owner_debit_reason_plain`): no bank debit set up, owner cancelled the debit at their bank,
    amount went up after the notice, the bank sent the payment back, and the plain form of each other hold. The button
    (`app.owner_debit_fix`): Send the sign-up link or Send a new notice (Owner money > Debits opens on that owner,
    `?owner=<id>&fix=setup|notice`, with the one action), Open the invoice, or Open Program settings (debits turned off).
  - New action `owner_debit_setup_link` (Finance or an Admin): the owner's bank debit sign-up email again; also on each
    owner without a bank debit in the Owners list of the Debits tab.
  - `staff_owner_invoice_failed` ("Owner payment bounced: $X from <owner>, <car>"), `staff_owner_debit_run` (the
    statuses in plain words), `staff_job_failed` ("Automatic task failed"), `staff_calendar_feed_failing` (no raw error
    in the preheader), `staff_usage_alert` (no "usage guard"); the site check's "Stripe webhook" reads "Card payment
    updates from Stripe". Their catalogue rows get the new subject, preheader and variables only (how each is sent, a
    digest or at once, is kept).
  - `emails/check.mjs`: a check that no staff email subject, preheader or body uses those words.
- **Each amount in one plain line** (0584, `app.owner_invoice_plain`): in every owner-debit email, the owner's
  (`owner_debit_notice`, `owner_debit_setup_needed`, `owner_debit_returned`, `owner_payment_failed`, `owner_in_arrears`)
  and the staff's (`staff_owner_debit_exception`, `staff_owner_debit_run`, `staff_owner_invoice_failed`): the amount,
  the car, the fee as the agreement words it (monthly fee, first and last month, tracker install, adjustment, late
  fee), the period, how it was worked out ("prorated: 20 of 30 days", "none for the 9 days on a flat monthly payment",
  "less the prepaid first month", "plus HST", "plus the late fee") and the invoice link (the owner's invoice page, or
  the owner in Admin for staff).
- **The fee check** (0584, `app.owner_fee_audit`, read only): a month's owner invoices against each car's signed terms:
  no monthly fee on a company or partner car, a Turo-Only or shareholder's car, or a car on a flat monthly payment all
  month; a flag for a flat-rate agreement with a monthly fee; nothing for a month before the Enrollment Date or after the
  fees end; the amount the terms give (one terms period in the month; a mid-month change is not compared). Shown in
  Owner money > Debits ("Fee check") and printed on every production deploy as one annotation
  (`scripts/deploy/fee-audit.sh`, `public.server_owner_fee_audit`, service key only): the owners invoiced (by a short
  reference: the repository is public, so never a name), their invoices and totals, and every invoice that does not
  match, with why. No production invoice is changed by a migration; one that does not match is voided and reissued by
  an Admin after reading the list.
- **Debit preview** (0584, ops_read `owner_debit_preview`, Finance or an Admin; Owner money > Debits): before the debit
  day, each owner with something to debit: the total, whether a bank debit is set up, whether the notice went, each
  invoice in its plain line, and **Hold** (pauses that owner's automatic debit, with a reason; **Resume** undoes it).
- Tests: `supabase/tests/99_owner_debit_amounts.sql` (an owner on a flat monthly payment, Turo-Only, a shareholder's
  car, no-fee terms or a company car is never invoiced a monthly fee in the November run; the 20 of 30 days line; the
  lines in the owner's and the staff's email; the fee check finds a monthly fee on a Turo-Only and on a flat car and a
  wrong amount, changes nothing and names no owner; the preview); `99_email_volume.sql` (the subject, the reasons in the
  owner guide's words, one button each, no staff subject with the system's words, the sign-up link action);
  `web/src/lib/deploy-scripts.test.ts` (the annotation); `tests/e2e/debit.spec.ts` (the Owners list wording).

## Guides

- `admin/owner-money`
- `owner/fees-payments-and-payouts`

Published by migration 0580 (`supabase/seed/0580_gen_guides.mjs`), the guide block of release 29.
