# Field expenses: whose money (Release 50: 3720)

Migrations `3720_r50_field_reimbursements.sql` and `3721_r50_guides.sql`, generators `supabase/seed/3720_gen_catalogue.mjs` and `supabase/seed/3721_gen_guides.mjs`.

## What it does

- **Field staff** (Add, Money spent; and a service with a cost): **Whose money?** must be chosen, **My own money (pay me back)** or **Company card/cash** (one full-width tick each, nothing preselected). The database refuses an expense without it.
- **Own money** makes a reimbursement owed to the person (`staff_reimbursements`): pending while Finance checks it, owed once approved, declined with the reason, paid once Finance marks it paid back. It follows the expense (a trigger on `field_spends`), so Approve, Decline and Mark paid back are the same buttons as before.
- **Finance and the Admins**: Field spending shows whose money it was; **Decline** needs the reason (the person sees it). **Reimbursements owed** per person on the payroll (Admin, Money, Payroll; Finance, Payroll) and on Field spending, each with **Mark paid back**.
- **The person**: My shifts, **Owed to you** (approved and waiting totals, each item's status and any decline reason).
- **Notices** (email, in-app, push): `staff_expense_submitted` to Finance and the Admins (topic alerts); `staff_expense_approved` and `staff_expense_declined` to the person at their own address (topic bookings). Never a text.
- **Connector**: `add_expense` takes `paid_with` (company, the default, or own) and `staff` (id or email) for own: owed at once. `list_expenses` returns `paid_with`, the staff member and the reimbursement, and filters by `paid_with`. Approved field expenses carry `paid_with` on the company expense.
- **Security**: functions security definer with `search_path = public, app, pg_temp`, server role only; the table is read by Finance and the Admins, and by each person for their own rows.

## Guides

- `field/my-jobs`: Money spent asks Whose money?, the decision is told, and Owed to you on My shifts.
- `va/finance`: Field spending, Approve or Decline with the reason, Reimbursements owed and Mark paid back.
