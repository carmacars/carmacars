# Insurance replacements, one page for every insurer rental (R50 hotfix 2: 5120 to 5123)

The owner, November 27: one list of insurer rentals with progress at a glance; a short entry form (a fleet car or one typed
in, Paste text filled by AI after a check); off the calendar and owner notices on a switch (CC-10067); every field of the
invoice editable, sent as an estimate or an invoice as many times as needed, each a version with its history and its
differences; getting paid (approved, paid, partial, written off, aging); the CarmaCars_Admin connector able to do all of it.
Two bugs: "Nothing is left to invoice to the insurer on booking X" after one invoice, and an unfinished rental (Marlene's)
that vanished with "already added or discarded".

Migrations `5120_r50i_insurance_replacements.sql` (tables, functions, door, connector), `5121_r50i_insurance_notices.sql`
(emails), `5122_r50i_insurance_guides.sql` (guides), `5123_r50i_cc10067_off_calendar.sql` (CC-10067 off the calendar and owner
notices, REQ-015: a Hyundai Palisade of the fleet with its claim and a Definity adjuster on the booking, so the switch is set on the booking, not by a typed-in car). DB test `supabase/tests/99_r50i_insurance_replacements.sql`; unit tests
`web/src/features/insurance/model.test.ts`, `web/src/features/documents/invoice-blocks.test.ts`; e2e
`web/tests/e2e/insurance-replacements.spec.ts`.

## What it is

| Part | What it does |
| --- | --- |
| The page | `/admin/insurance-replacements` (Money > Insurers > Replacements) and `/staff/insurance-replacements` (Finance: Money; customer service: the button on Bookings). Never Field. One row a rental: claim, insurer and adjuster, renter, car, dates, days, stage (upcoming, on rent, returned, invoiced, negotiating, approved, paid, written off), invoice and versions, billed, approved, paid, balance, aging. Search, stage chips, aging tiles |
| Add | Only the renter's name, insurer, claim number and dates are required. A fleet car, or a car typed in (year, make, model, plate): a `vehicles` row with `outside_fleet`, retired at once so it is never listed, booked or on a calendar. Made through Add a rental's own path (`app.manual_rental_create`), billed to the insurer, with no contact needed |
| Paste text | Rules first (`features/insurance/model.ts parseClaimText`), then the AI (`claim_read`, private: never Gemini) for what they left empty. Shown for the person to check, then **Use these** |
| Off the calendar | The booking's calendar switch. An insurer-billed booking off the calendar is not its owner's (2480): no owner email, not on statements. Always on for a car typed in |
| Invoice versions | `insurer_invoices` stays one row a booking (its number, payments and every report). The next version is edited in `pending`; Send applies it and keeps what was sent in `insurer_invoice_versions` (frozen by a trigger). An estimate is a version that bills nothing. Each version has its own PDF (`/files/insurer_invoice/<id>:v<n>`, stored once) and email (`insurer_invoice` or the new `insurer_estimate`, to the bill-to email, else the adjuster, else the insurer's billing email), as Blind Spot Car Rental |
| Re-invoicing | `app.draft_insurer_invoice` returns the booking's invoice once it has one; a sent one gets the booking's figures as its next version. The "Nothing is left to invoice" refusal is gone |
| Extension | **Extend** moves the return when the insurer authorizes it: priced as the calendar prices it, refused when the car is not free, a rental line of the extension, never a charge to the renter's card |
| Getting paid | Payments (cheque, e-Transfer, direct deposit as bank_transfer; part payments), approved amount, negotiating with its note, write-off of the rest with its reason (`written_off_cents`). The 30-day reminder (`staff_insurer_invoice_due`) now opens this page |
| Notices | `staff_insurer_rental_added` (Finance and Admins, email and the bell), `insurer_estimate` (the insurer) |
| Who | An Admin, Finance or customer service (`app.insurer_rentals_may`); money (send, payments, approved, write-off) Finance or an Admin |

## The connector

`list_insurer_rentals` and `get_insurer_rental` (admin:read); `insurer_rental_create`, `insurer_rental_update`,
`insurer_rental_extend`, `insurer_invoice_edit`, `insurer_invoice_send` and `insurer_money` (admin:write). A preview runs
the action and rolls it back, so it shows the outcome or the refusal; the confirm needs the same arguments and the
preview_id. The key's person must be an Admin, Finance or customer service.

## Unfinished rentals never vanish

The cause found in the code: **Discard** sat next to **Save draft**, worked in one press with no question and could not
be undone; and **Restore what you were typing on this device** adopted the device copy's draft id, which could be a draft
already discarded or added (saves then failed) or someone else's (Discard then closed it). Unfinished rentals also hid any
draft not saved for 30 days. The production data was not read (no tool reads drafts), so which of these lost Marlene's
rental is not proven. Now Discard asks first, a discarded draft opened from its link says who discarded it and when and
**Restore it** brings it back, an added one names its booking, the device copy saves as a new draft, and every open draft
is listed whatever its age.

## Guides

- `admin/insurance-replacements-rates-and-billing`
- `va/finance`
