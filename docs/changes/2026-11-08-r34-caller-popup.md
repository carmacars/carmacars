# Release 34, part N: who is calling, and renter notes (migrations 0800, 0801)

Branch `r34-n`. SCHEMA_MARKER 0802 (raise to the highest merged migration when merging).

The owner, November 8: "when customers call, customer service should get a popup for whos on the phone on their portal so
they can see everything live and they should also be able to keep notes to update on each situation with each renter."

## What changed

1. **The caller pop-up.** A call to the CarmaCars Quo number already reaches `/api/webhooks/quo` (0085), is verified, kept in
   `phone_activity` and matched to a renter on the normalised E.164 number (`app.phone_match`, the renter's mobile or their
   account holder's). The new read `caller_live` (door: `admin_read`, `va_read`, `ops_read`) lists the incoming calls ringing
   or in progress (a call Quo never closes drops after 30 minutes) and those ended or missed in the last 3 minutes, newest
   first, at most 3. For a renter it carries the booking on rent or coming next (`app.caller_booking`), the balance owed now
   (`app.caller_balance`: the open rental payments of confirmed, out and returned bookings from `app.booking_pay_schedule`,
   plus unpaid charges after a rental from `app.booking_balance_open`; overdue when a payment is late), the deposit
   (`app.caller_deposit`: held, waived, released, failed, not taken, none), open requests (`app.caller_requests`: booking
   requests and offers, change requests, unanswered questions, open tasks) and the last 3 notes. Unknown numbers show
   "Unknown caller" with **Create lead** (0085's `phone_create_lead`). Admins and customer service only
   (`app.caller_popup_ok`); Fleet and Sales are refused.
2. **How it is live.** `CallerPopup` (web/src/features/caller) is in the Admin frame and in the staff frame of anyone who holds
   customer service. It asks `/api/staff/phone?what=caller_live` every 10 seconds through `lib/poll` (once a minute when the
   page is idle, never in a hidden tab), as the Live chat inbox does: no new vendor, one light read. Closing a call is kept in
   the browser's localStorage for 2 hours (per viewer only; a private window just forgets).
3. **Renter notes.** `renter_notes`: the renter, the text (1 to 4,000 characters), the author and their role (Admin, customer
   service, Sales, Fleet, Finance), the booking and the call it was written during, the time. Read and added by Admins and office
   staff who may see the renter (`app.va_sees_renter`, or for customer service a call from the renter in the last hour);
   never edited (trigger `renter_notes_guard`); removed only by an Admin with a reason (kept and marked, `renter_note_remove`).
   Every insert and update is in `audit_log` (`app.audit_row`). Browser roles have no grant on the table. Shown on the Admin
   renter page, the staff portal's renter (Find a renter, Open), the caller pop-up and a renter's thread in Texts and calls.
4. **Open from the call.** Staff outside a renter's window open the record from the pop-up (`caller_open`): a
   `data_access_log` opening for 24 hours with the reason "Incoming call", as Open with a reason does; only for a call from
   that renter in the last hour.
5. **Admin and staff portals.** Every part is in both: the pop-up in Admin and customer service's portal, the notes on both
   renter pages and on the shared Texts and calls thread.

Tests: DB suite `99_r34n_caller_popup.sql` (37 assertions), unit `features/caller/model.test.ts`, e2e
`tests/e2e/caller-popup.spec.ts` (a signed Quo ringing delivery, the pop-up for customer service, a note from it, the notes on
the renter page, an unknown caller made a lead).

## Guides

Changed chapters (published by `supabase/seed/0801_gen_guides.mjs` into `0801_r34n_caller_popup_guides.sql`):
`admin/texts-and-calls-the-quo-phone-line`, `va/texts-and-calls` (the Academy chapters of the same block belong to 2026-11-08-r34-academy-gate.md).
