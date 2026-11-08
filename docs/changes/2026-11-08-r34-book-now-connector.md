# Book it now from the connector and the assistant, Replaced by notes, a profile for everyone, incident cards, signal alerts (Release 34, part O: 0810 to 0814)

Branch `r34-o`. Migrations `0810_r34o_book_now_connector.sql`, `0811_r34o_guides.sql` (guide text only, `supabase/seed/0811_gen_guides.mjs`),
`0812_r34o_self_profile.sql`, `0813_r34o_incident_cards.sql`, `0814_r34o_signal_alerts.sql`. SCHEMA_MARKER 0814. Tests: `supabase/tests/99_r34o_book_now_connector.sql`,
`web/src/features/api-access/tools.test.ts`, `web/src/features/assistant/assistant.test.ts`,
`web/tests/e2e/book-now-connector.spec.ts`. No applied migration is edited: `app.door`, `app.api_action` and
`app.assistant_action_door` are wrapped (`*_pre0810`).

## What changed

| Item | How it works |
| --- | --- |
| 1. Book it now (r33, 0770) from Claude's connector | One server function, `app.offer_book_now` (0770), reached three ways. **Make an offer** (`create_offer`) and **Send an offer** (`send_offer`) take `book_now` and `book_now_reason` (the door already booked the offer in the same transaction). New tool **Book an offer now** (`book_offer_now`, `{booking, reason}`) books an offer that is already out: door action `ops_do offer_book_now` (`app.offer_book_now_door`). Every one is two steps as before: without `confirm` it runs and rolls back (the preview shows the booking going to waiting for payment), then `confirm: true` with the `preview_id` does it. The connector acts as an Admin, so it is booked at once: the offer is the approved version, the booking waits for payment and holds the car, the "approve your offer" email is skipped. After a confirmed call the site makes the renter's agreement as the renter (`bookNowAgreement` in `api/mcp/route.ts`), whose email opens Sign and pay |
| 1b. The in-app assistant | `create_offer` takes `book_now` (and `book_now_reason`): the stored action carries the flag, the card gets a **Book it now** section and the summary ends "booked now without the customer's approval". New assistant tool `book_offer_now` for an offer already out (card, then Confirm), for Admin, customer service and Sales (`assistant_action_door` maps it to `ops_do`). The price preview never carries the flag. After Confirm, `decide` makes the agreement (`bookNowAgreement`) and says what happened. **Staff rule unchanged**: the database decides by the role, so customer service and Sales through the assistant send the offer and ask; an Admin approves in one tap (alert and To do). Finance, Fleet and field staff have no tool and the door refuses them |
| 2. Replaced by / Replaces | New read `ops_read booking_chain` (staff and Admin): the booking that replaced this one (`bookings.superseded_by`, 0780) and the ones this booking replaced. The shared booking page (`BookingPage.tsx`, the Admin's and every staff portal's) shows "Replaced by #N" on the old booking and "Replaces #M" on the new one, each a link (`booking-replaced-by`, `booking-replaces`) |

### Added during r34: sections A, B and C

| Item | How it works |
| --- | --- |
| A. A profile for everyone (renter, owner, investor, staff, field staff, Admin) | `features/portal/SelfProfile.tsx` on every portal's profile: **Save my display name** (new `users.display_name`, at once) and **Request a name change** for the legal name (the name on signed agreements). The request makes a row in `name_change_requests` and an Admin To do (`name_change_approve`, one-tap Approve and Decline); it also shows as a card on the owner's, investor's and renter's Admin page. Approving changes `users.full_name` and the `legal_name` of the person's renter, owner (individual) or investor (individual) record; agreements already signed keep their name. **Change my password** opens the existing reset page (renter, owner, investor, Admin; staff and field staff already had it). Email keeps the r33 ChangeEmail confirm link; the phone verify flow (SignInSettings) is now also on the investor and the Admin profile. Door names (any role, `ops_read` and `ops_do`): `self_profile`, `display_name_save`, `name_change_request`, `name_change_decide`, `name_change_pending` |
| B. The incident card | `/admin/vehicles/incident-cards` (also `?car=<id>`, the **Incident card** button on each car page, and `/staff/vehicles/incident-cards` for Fleet): 7.5 x 4.75 in cards, two to a Letter page, crop marks, **Print all cars** and **Print this car**. Each card: the CarmaCars name, the car (year, make, model, plate, VIN), the accident and breakdown steps (safety, 911, photos, exchange details, do not admit fault, support number, roadside number, the app), a QR code to `/account/bookings` (the booking in progress has Report a problem), and the fleet insurance slip. **The fleet insurance policy was not stored as data** (only "Insurer confirmed" per car), so `fleet_insurance_policies` is new: insurer, policy number, dates, named insured (default 18122211 Canada Inc.), roadside and claims numbers, and an optional uploaded slip (a stored document: image or PDF, embedded as is; otherwise the fields print). An Admin sets it on the incident cards page. No premium or amount is stored or shown (the save refuses one). Door names: `incident_cards`, `fleet_policy_save`, `fleet_policy_slip_choices` |
| C. Signal alerts | `visitor_signal_rules.alert_on_own` (on for `same_car_return`), a **Alert on its own** box per signal in Signal settings (`live_signal_alert_save`). When such a signal turns on in a visit, the rule `visitor_signal` (Admins and the on-duty customer service and Sales staff, urgent) alerts once per visitor per signal per day, with the hot alert's guards (analytics consent, renters only, not staff, not test addresses). The alert audit is in the report of this change (see below) |

## Decisions

- No new Book it now logic: the connector, the assistant and the screens all end in `app.offer_book_now`, so the same checks, the same history entry (`offer_booked_now`), the same alert and To do for staff.
- `send_offer`'s input schema was closed, so `book_now` and `book_now_reason` are listed; `create_offer` already passes extra fields.
- The agreement is made in the web layer only when the booking is approved (`bookNowAgreement` ignores a request still waiting for an Admin).

## Alert audit

Checked in a database with every migration applied. Result: nothing was broken; one rule was added (`visitor_signal`).
- 95 alert rules (`staff_alert_rules`): none disabled, none with an empty "who". Each is raised by code: 60 by a direct `staff_alert(...)` call, 13 `sent:*` rules by the outbox mirror trigger, 22 by helper functions (booking and field job and review alerts, the lead and hot-visitor alerts, tracker alerts, data health).
- No call uses a rule name that does not exist (the only dynamic name is `sent:` plus the code, checked against the catalogue).
- 231 notification codes: 12 are not named in any function. Two (`account_password_reset`, `account_security_notice`) are sent by the sign-in service by design; ten are the staff morning and end-of-day digests, built by `staff_email_digests`.
- 35 live-visitor signals: all are written by the signal evaluation; only `same_car_return` alerts on its own (the new setting).
- Rules that reach only people on duty (`on_duty:*`) also reach every Admin; `escalation_duty` and `morning_brief_staff` go to the assigned person only, by design.

## Tests

| File | What |
| --- | --- |
| `supabase/tests/99_r34o_book_now_connector.sql` | connector create_offer with book_now (preview rolls back, confirm needs the preview), book_offer_now (preview, confirm, not repeatable, scope), staff request and Admin approval through the same door action, Finance refused, the assistant door mapping, booking_chain both ways, staff-only |
| `tools.test.ts`, `assistant.test.ts` | the connector tool list and schemas (the SQL check now reads 0732 and 0810); the assistant card, the flag, the staff wording, the offered-only rule, who has the tool |
| `web/tests/e2e/book-now-connector.spec.ts` | MCP book_offer_now preview then confirm; the Replaced by / Replaces notes on the Admin and staff pages (CI only) |

## Not done here

- The e2e spec was written but not run (CI only); the pages were not opened in a browser.
- The assistant has no tool to send the offer of an existing request (`send_offer`); it makes offers (`create_offer`) and books offers that are out.

## Guides

- `admin/requests-offers-and-bookings`: Book it now from Claude and the assistant; A request replaced by a newer one.
- `va/customer-service`, `va/sales`: ask the assistant to book an offer now (an Admin approves).
- `renter/start-here`, `owner/notices-profile-and-leaving`, `investor/profile-and-notices`, `va/start-here`, `field/report-rentals-referrals-and-profile`: Your name and password.
- `admin/settings`: My profile and name changes. `admin/fleet-and-listings`, `va/fleet`: Incident cards. `admin/live-visitors-and-live-chat`: Signals that alert on their own.

Exported to `docs/guides/content`; migration 0811 publishes the 12 changed chapters (`supabase/seed/0811_gen_guides.mjs`).
