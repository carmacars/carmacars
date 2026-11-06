# Kickbacks and repair costs in the profit numbers (release 29, C2, migration 0581)

Branch `r29`, on top of r28's partner invoices (0547, A12). SCHEMA_MARKER 0581.

## What changed

- **Kickbacks tied to a car**: `partner_invoices.vehicle_id` and `claim_id`, filled by themselves from the invoice's
  booking or its claim number (a trigger; the invoices already made are filled once). The builder has **Car (empty:
  from the booking or the claim)**; an invoice already sent has **Choose the car** (ops_do `partner_invoice_car`). The
  invoices and the money received on them stay the only source: a kickback is a payment received (not voided) on an
  invoice that is not void, its share before HST, on the day it came in. Body shop (repair), tow and storage invoices
  are the lines **Body shop kickback**, **Tow kickback** and **Storage kickback** ("other" invoices: Other kickback).
- **Repair costs** (`vehicle_repair_costs`): date, vendor (a partner shop or free text), what was done, amount, tax,
  receipt (photo or PDF, private storage through `/api/staff/profit-extras`), paid by (CarmaCars, the owner or the
  insurer), claim. Added, changed and removed by Admin, Finance and Fleet (ops_do `repair_cost_save`,
  `repair_cost_void`) on the car's page and on the claim (the incident's page).
- **The profit lines at three levels** (`app.profit_extras`, ops_read `profit_extras`, `features/profit-extras`): the
  business (Admin > Company > **Kickbacks and repairs**, `/admin/money/kickbacks`; Finance: Money > **Kickbacks and
  repairs**), an owner (Admin: the owner's **Kickbacks and repairs** tab) and a car (Admin: the car's **Kickbacks and
  repairs** tab; Fleet and Finance: the car's page). Each has a period (default: this year to today), the lines, by
  owner and by car, every row, and a CSV. Repair costs paid by the owner or the insurer are shown apart and are not a
  CarmaCars cost. The monthly company statements are unchanged.
- **Owners**: `owners.show_profit_extras`, "Show repair costs and kickbacks to this owner", off by default, set by an
  Admin or Finance only (ops_do `owner_profit_extras_visibility`). On: the owner sees the lines and repairs of their own
  cars under Money > Statements (ops_read `profit_extras_mine`: no partner, invoice, claim id or receipt); off: nothing.
  Owner statements, payouts and every public page show none of it.
- Tests: `supabase/tests/99_kickbacks_repair_costs.sql` (the links, who may write and read, the rollups by business,
  owner and car, the period, the owner's visibility); `features/profit-extras/model.test.ts` (the period and the CSV).

## Guides

- `admin/referral-partners-and-rentalcoverage`
- `va/finance`
- `va/fleet`
- `owner/fees-payments-and-payouts`

Published by migration 0580 (`supabase/seed/0580_gen_guides.mjs`), the guide block of release 29.
