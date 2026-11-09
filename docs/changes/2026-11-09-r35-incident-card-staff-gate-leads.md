# The incident card in every car, the staff onboarding gate, and leads open to every salesperson (Release 35, part G: 1150, 1151, 1152)

Branch `r35-inc`. Migrations `1150_r35g_incident_card.sql`, `1151_r35g_staff_onboarding_gate.sql`, `1152_r35g_leads_open_list.sql`
(SCHEMA_MARKER left to the integrator). Tests: `supabase/tests/99_r35g_incident_digital.sql`, `99_r35g_staff_onboarding.sql`,
`99_r35g_leads_open_list.sql`; unit tests `web/src/features/incident-cards/model.test.ts`, `digital.test.ts`,
`web/src/features/staff-onboarding/model.test.ts`, `web/src/features/sales-leads/model.test.ts`, `web/src/features/academy/gate.test.ts`.

## A. The incident card (1150)

The owner, November 9: a printable incident card in every car with what to show for each of the three coverage options and our
insurance slip, and a QR code to the renter portal's digital card with the booking's own coverage, the booking and the contract.
Then: one generic card, the same for every car (100 copies), no car, plate, VIN, renter or booking on it.

| Item | What changed |
| --- | --- |
| Printed card | Admin and Fleet **Incident cards** (`/admin/vehicles/incident-cards`, `/staff/vehicles/incident-cards`) print one generic card, two to a Letter page with crop marks (7.5 x 4.75 in, three columns): the steps, **What to show** for Option 1 (your own auto insurance, OPCF 27: this card's slip and your own pink slip), Option 2 (credit card rental coverage: this card's slip; damage claimed on the card), Option 3 (the CarmaCars Protection Plan: this card's slip; the provider and your policy number in the app), the fleet insurance slip (0813, uploaded file or the fields), the support and roadside numbers, and one QR code to `/incident`. Option 4 (insurance included with the car, insurer-paid replacements) is not on the card. No amount of money. The car page's **Incident card** opens the same page |
| QR | `/incident` (fixed) redirects to `/account/incident`, which signs in first |
| Digital card | `/account/incident` (`app.incident_digital`): the signed-in person's bookings in progress (on rent, or confirmed with the pickup within 12 hours and the return not passed) where they are the renter or a driver named on the booking with their own login. One booking: its card; several: a picker; none: the steps and the numbers only, nothing about any booking. The card: car, plate, booking number, pickup and return, the drivers, the coverage option with what to show and its proof (the accident card of 0910), the rental agreement (signed copy first) and the coverage proof as links (`/account/incident/doc/[id]`, `public.server_incident_document`: only those two documents of such a booking, 5-minute links), Call 911, support and roadside, and **Report a problem** (0912's report, now also for a named driver) |
| Links | Renter booking page: **Open the digital incident card** on the accident card; `/account`: **Incident card** on the trip in progress and on each trip where the person is a driver |
| Privacy | `/incident` and `/account` are private paths for crawlers; no personal data in any URL |

## B. Staff onboarding gate (1151)

The owner: staff have access to everything only once they have signed the agreement and confirmed they joined the WhatsApp group,
strictly in order, existing staff included from deploy, no grace period.

| Item | What changed |
| --- | --- |
| Groups | 1060's groups of a person (`app.staff_groups`: the home page card and the team group email) give Sales staff the Team group as well |
| Steps | (1) the academy passed or waived, (2) the staff agreement signed or waived, (3) the WhatsApp groups joined and confirmed, one checkbox a group on Welcome (Sales: CARMA Closers and CarmaCars Team; everyone else CarmaCars Team). Each step opens only after the one before; the join links show at step 3 (when set in Program settings; else "ask your manager"). 1060's "I joined" counts as every group |
| Helper | `app.staff_fully_onboarded(uid)`: an Admin, a test or verify account (`app.staff_is_test`), an exempt person (`staff_profiles.onboarding_exempt`), or the three steps done (`staff_profiles.onboarding_done`, kept by triggers on the academy attempts and waivers, the agreement requests, the profile, the roles, the paths and the settings). Program settings `staff_onboarding_gate` (on) |
| Database | `app.user_is_staff`, `app.user_va_has`, `app.is_field_person` (so `app.user_is_field`), `app.va_has` (so `app.is_va`, `app.is_staff`) and `app.is_field` are false for a staff member not fully onboarded; the door refuses every call but the onboarding screens' own with "Finish your onboarding first"; `app.my_roles` adds `onboarding_locked` and `onboarding_step` |
| Portal | Until done, every staff page sends the person to Welcome (the academy, the guide, the profile, the documents to sign and pay details still open) |
| Admin | Settings > Staff > **Staff onboarding**: each person's step; **Mark WhatsApp joined** or **Take back WhatsApp** per person; **Mark joined** for every signed person who has not confirmed |
| Leads | Never to a person not fully onboarded: an assignment moves to the salesperson who brought or last had the lead (else the open list), a claim is refused, Reassign refuses. Every lead such a person holds is returned now and whenever they stop being onboarded, logged in the lead history (**Returned to**, **Claim released**). Admin **Return lead to previous owner** on a lead (`lead_return`) |
| Deploy | No grace period: from deploy every staff member who has not passed the academy, signed the agreement and confirmed the WhatsApp groups sees only Welcome until they do. Admin can bulk-mark WhatsApp for everyone who signed |
| Kept | The inactivity lock of 1060 (no sign-in for 10 days, counted from the account's creation if never signed in; the hiring job locks it; an Admin unlocks it on the staff list) applies alongside |

## C. Leads open to every salesperson (1152)

The owner: leads were sent to staff by themselves; they should be open for any salesperson to take, one every 5 minutes, and a
person holding too many open leads takes no more until they close or release one; the limit grows as they win more.

| Item | What changed |
| --- | --- |
| No auto-assign | `app.lead_real_assignee` (0343, the least-loaded Sales person) names nobody, `app.submit_lead` picks nobody for the lead or its To do (the To do waits in the Sales queue), and a new lead from any path arrives unassigned on the Sales lead list, except a salesperson's own lead, an Admin's assignment, and a verify account's own test lead (the fences of 0343 and 0440 decide those) |
| Pacing | One new claim every `claim_cooldown_minutes` (5) a person; Admins are not paced |
| Cap | A person's cap (`app.sl_cap`): `lead_cap_base` (3), plus one for every `lead_cap_per_wins` (5) leads won in the last 30 days (the outcome won credited to them, which a confirmed booking of the lead's contact also sets), up to `lead_cap_max` (10). At the cap a claim is refused until one is won, lost, handled, unclaimed, released or runs out |
| Screens | The lead list: "you hold n of N", the wins to the next slot and "next claim in m:ss"; Settings > Sales: the pacing and the three cap settings; the Sales dashboard team table: each person's holding of their cap |
| Once | Leads given by themselves (no claim, contact or outcome by the assignee, not their own lead) are back on the list, logged as **Claim released** ("Auto-assigned"); then part B's return for anyone not onboarded |
