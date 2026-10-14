# 0036: sign-in for every portal

Migration `supabase/migrations/0036_sign_in.sql`, tests `supabase/tests/23_sign_in.sql`. The whole change (the web app,
the Worker entry, the live verification and what was found) is `docs/changes/2026-10-14-sign-in.md`.

## What was added or changed

| Part | Why | Built |
| --- | --- | --- |
| View as | An Admin could not open the owner, staff, field, investor or renter portals: each checks its own role | `app.view_as_start(admin, person, portal, function)`: an Admin only (`app.assert_admin`), an active person other than the Admin, a portal that person has (renter: a renters row or the renter role; owner; investor active or exited; field; staff in one of their functions, the main one by default). Writes `view_as_start` to the audit log with the portal, the function and the address. Server only (`public.server_view_as_start`) |
| The portals a person has | One answer for the sign-in redirect, the "Choose a portal" page, the switcher and the refusal pages | `app.person_portals(user)`. `app.my_roles` (0033) is replaced with one change: `renter` is also true for an account made on the site before its first booking (its renter role), so "My rentals" is offered to it |
| Admin > Portals | One page to open any portal as one of its people and to invite | `app.admin_portal_people(admin, search, limit)`: everyone with a role or a record, staff first, with their portals; the owners and investors on file without a sign-in. `app.admin_account_index(admin)`: the sign-in of each owner and investor record (the View as and password buttons on Admin > Owners and Investors) |
| Invitations into any role | Admin > Staff invited only staff; owners and investors on file had no way to get a sign-in | `app.admin_invite_account(admin, p)`: admin, assistant (main function and the functions covered), field, an owner on file, an investor on file. The web app makes or finds the sign-in and emails the link; this gives it the role, links the record and writes `invite_account` to the audit log. An address that belongs to another record is refused |
| Password links from Admin | An Admin could not resend an invitation or send a reset | `app.admin_account_link(admin, person)`: the address to send to (active accounts only), written as `send_password_link` to the audit log. `public.server_user_by_email` finds the record that holds an address (server only) |
| The live verification's accounts | There was no Admin test account and only the customer service assistant | `app.verify_accounts` (0033) now also takes `admin` (only for `verify-admin@carmacars.ca`) and `va_finance`, `va_fleet`, `va_sales`. Every one stays on the suppression list; an Admin role found on any other verification account is still taken away |
| Lighter portal frames | The renter and owner frames read 100 whole notices to count them; every Admin page read the whole dashboard (lists, fleet days, setup checks) for five numbers in the rail | `public.my_unread_count()` (the signed-in user's unread count); `app.admin_rail_counts(admin)` (the same five counts as the dashboard) |

Every new function is executable by `service_role` only, except `my_unread_count` (the signed-in user).

## Tests

`23_sign_in.sql` (55 assertions): view as each portal, a function they cover, refused for a function they do not
have, a portal they do not have, a non-Admin, themselves, an unknown portal and an ended account; every start in the
audit log with the portal and function; a browser cannot start it. An account made on the site has the renter portal
before its first booking. Admin > Portals lists portals per person, searches (with `%` and `_` taken literally),
lists records without a sign-in, indexes records with one; Admin only. Invitations for each role (functions covered,
lower-cased address, the owner and investor records linked), refused for a record that already has another sign-in,
an address on another record, a missing function, a role outside the list and a non-Admin; a renter made an assistant
keeps both portals; each in the audit log. The password link's address, audited, Admin only. The verification Admin and
one assistant per function; an Admin role refused on any other verification address and taken away again. The unread
count; the rail counts equal the dashboard's.

`08_booking_app.sql` lists `my_unread_count` among the signed-in session's functions; `20_gap_close.sql` now expects
`verify-boss@carmacars.ca` to be refused as an Admin (only `verify-admin@` may be one).
