# Calls through the site for Sales, and the caller's own mobile (migrations 2460, 2461)

The owner, 2026-11-12: "since we hid the phone numbers from salespeople ... none of the salespeople have been able to call
the leads or the requests"; "the sales person caller should give u a pop up for a phone number if no phone number is
saved on file"; a salesperson "tries to put his phone number in, it waits for a code and then he never gets it".

## Why calls failed

- The lead page and the lead list (`web/src/features/sales-leads/LeadActions.tsx`) made **Call** and **Text** plain
  `tel:` and `sms:` links from the lead's phone with every non-digit removed (`contactLinks` in `model.ts`). Since 0970
  Sales reads the number masked, "(905) •••-••43", so the link was `tel:90543`: the phone dialled five digits and nothing
  reached the platform. The booking and request pages already used the platform's buttons (`ContactButtons`).
- The platform's Call (Twilio: the staff member's own mobile rings first) refused a staff member with no mobile on the
  profile with an error, and the only way to add one was a texted code.
- With calling from the site not set up, the masked Call button said so without asking the server.

## What changed

- Lead page and lead list: **Call** and **Text** are the platform's buttons (`ContactButtons`, `only` call or text): a
  masked number is called and texted through the server, which finds the real number (`server_phone_unmask`). The lead's
  contact is still logged (and the claim extended) when the button is pressed. Buyer leads, owner leads and chauffeur
  requests show the number with the same buttons.
- `app.server_twilio_call_start` (renamed `_pre2460`, wrapped): a staff member with no mobile on file gets
  `{ok: false, need_phone: true}` instead of an error; otherwise the 0970 start plus `ok: true`.
- `app.staff_set_call_phone` / `public.server_staff_set_call_phone` (service role only): saves the caller's own Canadian or
  US mobile (10 digits, valid area code and exchange, not toll-free, not the CarmaCars number), without a code; a verified
  number on file is never replaced; audited (`staff_call_phone_set`).
- `POST /api/staff/phone {action: 'phone_my_number', phone}`: that save (not in "view as").
- The Call window (`web/src/features/phone/QuoButtons.tsx`, logic in `my-number.ts`): ringing; or **Your mobile number**
  (checked in the browser, then by the database), **Save and call** places the call at once; or the message saying what
  to do, with **Try again**. A masked Call always asks the server (no early "not set up" from a cached setting).
- Profile, Sign-in: after **Text me a code**, **Resend the code** (after 30 seconds) and **Save it without a code** (the
  contact number of 0843, which calls ring). The code path itself is unchanged: an answer that never arrives is either a
  number already on another account (the sign-in service answers as if sent, so nobody learns which numbers have accounts)
  or a text Quo accepted and the carrier did not deliver; `auth_sms_log` tells which (no row for the number: the first).

## Tests

`supabase/tests/99_r40_calls.sql` (the lead's number masked for Sales and found on the server; no mobile asks for it;
the mobile's checks; the call then starts and dials the lead; customer service and Fleet the same; a verified number
kept; the browser can call neither function). `99_r35z_roles_alerts.sql` now expects `need_phone`. Unit:
`web/src/features/phone/my-number.test.ts` (the number box and the call window's states).

## Guides

`va/texts-and-calls` (Calling from the site: your mobile), `admin/texts-and-calls-the-quo-phone-line` (the Call button
through Twilio).
