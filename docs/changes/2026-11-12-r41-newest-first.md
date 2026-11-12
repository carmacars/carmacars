# Lists show the newest first, in the order records came in (Release 41: 2580)

Branch `r41-order`. Migration `2580_r41_newest_first.sql` (patches `app.admin_list`, `app.hiring_read_pre0211`, `app.sales_leads_pre1152`; no applied migration is edited). SCHEMA_MARKER 2580.

Owner, Nov 12: renters, bookings and offers, leads and hiring were "not ordered the right way. It should be chronological in the order it came in, not alphabetical."
Every Admin and staff list was audited. Default order is now newest first by when the record came in (`created_at`, or the table's own received/submitted/sent time), ending on the id so equal times never shuffle.

| List | Before | Now |
| --- | --- | --- |
| Every list through `admin_list` (Admin and staff: renters, payments, refunds, deposits, payouts, messages, documents, field jobs, and so on) | `created_at` newest first, but a table without `created_at` fell back to its first column (alphabetical or by id); no tie-breaker | first of created, submitted, received, requested, occurred, issued, sent, started, at, changed, updated time; id as tie-breaker |
| Admin > Bookings (All) | newest pickup first | newest booking first (when it came in) |
| Admin > Hiring > Applications | highest screening score first | newest application first |
| Leads (Admin, Sales, customer service; Admin > Renters > Leads, Owners > Leads) | Priority by default | Newest by default; the Sort box still offers Priority and Oldest |
| Admin > Investors | A to Z by name | newest first |

Kept on purpose (a work queue or a calendar, not an inbox): Requests and offers (longest wait first, then offers by expiry), Tasks and the To do queue (priority, due time), Next lead (priority), Hiring > Shortlist (ranked by interview score), Hiring calls and interview days (by time), Calendars and Today's pickups (by time), Out now and Bookings waiting for payment (by return and pickup time), Chauffeur requests (service date), Unanswered (longest waiting), Deposit reviews (soonest), Listings review queue (state, then update), Tolls queue (age), Owners and onboarding (progress), staff bookings search and My bookings (status, then pickup), fleet and car pickers (fleet number, make, name), and month ordered lists (Statements, Invoices, Expenses: already newest month first).

## Guides

No guide change: only the default order of lists changes; no screen, button or step in any chapter changes.
