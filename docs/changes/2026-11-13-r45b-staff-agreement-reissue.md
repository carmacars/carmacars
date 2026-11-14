# Send a new agreement for a staff agreement already sent or signed (Release 45: 2862)

Migration `2862_r45b_staff_agreement_reissue.sql`.

- **Send a new agreement**: Settings > Staff, Staff agreements has it for an agreement waiting for a signature or signed. It prepares the current terms (`app.staff_agreement_prepare`, so a person who lives in Canada gets Canada, CAD and Interac e-Transfer or direct deposit) and sends it to sign the same way as the first. The one waiting is voided; a signed one stays on file, marked superseded (`sign_requests.superseded_at`, `superseded_by`), and keeps the person's portal open until they sign the new one.
- **Who needs it**: `app.staff_agreement_needs_canada` is an active staff member who lives in Canada (`app.staff_in_canada`) whose current agreement carries terms that are not Canadian (a country other than Canada, a currency other than CAD, or OnlineJobs.ph). The list shows **Lives in Canada: needs the Canadian terms** beside them.
- **One To do** (staff_agreement_canada) lists everyone affected when the migration runs, for the owner's assistant to send; it closes by itself once none is left. Not sent by the migration: the agreement is rendered to a PDF and stored by the website (`web/src/server/person-agreements.ts`), which SQL cannot call.

## Guides

`admin/settings` (migration 2865).
