# Contact capture from every form (October 21, 2026)

Migration `0090_contact_capture.sql` (SCHEMA_MARKER `0090`); tests `supabase/tests/62_contact_capture.sql` (03, 07 and 34
updated); unit tests `web/src/features/capture/fields.test.ts`; end to end `web/tests/e2e/contact-capture.spec.ts`
(phone 375 and desktop 1440). New email `renter_continue_request`. No applied migration was edited.

The owner's request: someone who starts a booking request or any contact form and does not finish keeps their name,
email and phone, and an account is opened for them at once. Refined by the owner: an automatic sign-in only for a
brand-new address, made safe against someone typing another person's email.

## 1. What is captured, and when

| Form | Fields | Linked to |
| --- | --- | --- |
| Request to book (`RequestWizard.tsx`, step 2) | first and last name, email, mobile | the browser's visitor id (`cc_vid`) and the draft (`form_drafts`, proven by the browser's draft token) |
| Contact form (`ContactForm.tsx`) | name, email, phone | visitor id |
| List your car form (`OwnerForm.tsx`) | name, email, mobile | visitor id |
| Owner application (`ApplyWizard.tsx`, About you) | first, middle and last name, email, mobile | visitor id and the draft (found by the server from its httpOnly draft cookie) |
| Discount game claim (`GamePopup.tsx`) | first name, email, mobile | visitor id; the claim links to the account by email (0069) |
| Live chat | name, email, phone given in the chat (database trigger on `chat_conversations`) | visitor id and the chat; the chat's own lead |

A field is saved when it loses focus and is valid (a name of 2 to 120 characters, an email address, 10 to 15 digits),
600 ms later, once per change (`useCapture`), through `POST /api/capture` (same origin only). Only what the person typed.
Each capture is a `contact_captures` row and a lead (`leads.source = 'unfinished_form'`, `consent_marketing = false`):
no marketing use without consent. Rate limits: `capture_rate_per_minute` (30) per browser and three times that per
salted daily key of the network address (`app.rate_limit`, the limiter behind `app.public_rate_check`; the address is
never stored). Sending the form closes its capture, its lead (status closed, "The form was sent") and its follow-up.

## 2. Account creation rules

| The address | What happens | Browser session |
| --- | --- | --- |
| Brand new: no `users` row, no sign-in (`auth.users`), no renter, driver, owner, investor, cosigner or partner record, no game claim, chat, lead or capture from another browser | `users` row (renter role), renter record once a name is known, and a sign-in account made by the app with **no password and the email not confirmed**, no email sent (`openForCapture`: Supabase `POST /admin/users` with `email_confirm: false`) | yes: the unverified session below |
| This browser's own unconfirmed account | what was typed updates its renter record (only while it has no booking) | the same session |
| Has an account (with or without a password) or any record | linked only; nothing on the account is changed; a sign-in account is made if none exists; the one email goes at once | **never** |
| Phone only | a lead linked to the visitor, until an email is given | no |
| Signed in | linked to the signed-in account; nothing opened or sent | no |
| Corrected in the same form (a mistyped address) | the account the mistyped address opened here, holding nothing else, is removed again (row and sign-in) | moves to the corrected address if it is brand new |

What the person typed after a form shows: brand new "Saved as you type. We opened an account for you with this email:
finish any time on this device, and confirm it with the link we will email you."; an existing account "You have an
account: we sent you a sign-in link." (or "sign in to continue, or use the link we emailed you" when it already went).
Nothing else about an existing account is ever shown.

## 3. The unverified session (automatic sign-in for a brand-new account) and its threat model

**Mechanism.** Supabase confirms the email when a magic link is verified, so the automatic sign-in is not a Supabase
session. It is a random 64-character token in the httpOnly, SameSite=Lax, Secure cookie `cc-pending` (30 days); the
database keeps only its SHA-256 (`capture_sessions`) and binds it to the browser's visitor id. The app treats it as an
unverified renter session that can do exactly one thing: `/my-request` (and `/account`, which forwards there) shows what
this browser made during it, from `capture_session_items` only (its draft, its request, its chat), with "Email not
confirmed yet". The request-to-book draft continues on this device as before (its own draft token). No portal page
accepts the cookie; every portal page and server action still needs a real sign-in.

| Threat | Safeguard | Test |
| --- | --- | --- |
| Someone types another person's email to read their account | A session is opened only for a brand-new address (no record of any kind); an existing address gets only the sign-in link to its inbox | DB 62 sections 2 and 6; e2e both tests |
| The same email later typed in a second browser before it is confirmed | Treated as an existing account: the sign-in link, no second session, nothing on the account changed; a session token from another browser is refused (visitor id mismatch) | DB 62 section 2; e2e "another browser types the same address" |
| The unverified session sees what was made elsewhere | It reads only `capture_session_items`, added only by its own browser's requests (a booking is added only from the server action that sent it, for a booking of that account made after the session began) | DB 62 section 3 |
| The unverified account uploads ID, sees cards, accepts, signs or pays | Structurally impossible (no portal page or action accepts the cookie) and refused by the database for any account capture opened or gave a sign-in until its email is confirmed: `app.capture_gate` in `renter_approve_offer`, `renter_sign_agreement`, `renter_sign_amendment`, `server_record_booking_payment`, `server_confirm_extension_payment`, `renter_register_upload` | DB 62 section 4; e2e (the portal profile asks for sign-in) |
| The real owner of the inbox confirms | The emailed link signs in and confirms in one step; the `users` trigger then **revokes every unverified session** of the account, so only the inbox owner keeps access; the drafts of the account's captures become the account's | DB 62 section 5; e2e (the first browser's session ends) |
| An account nobody confirms | After `capture_close_days` (30): sessions revoked, the link stopped, the sign-in without a password removed (`auth.users`, which the function owner may delete in production: checked read-only), the lead kept | DB 62 section 11 |
| The browser that opened a brand-new account chooses a password (sign-up, owner application) | The password is set and the usual "confirm your email" link sent, as a plain sign-up; nothing signs in before the confirmation. Any other browser gets "You have an account: we sent you a sign-in link", and nothing is attached | e2e signup and owner suites |
| Email scanners opening the link first | The continue link is not spent by opening; each opening makes a fresh one-time sign-in link; it stops an hour after the email is confirmed, and after 72 hours | DB 62 section 5 |
| Floods | Rate limits per browser and per address key; the cookie is useless without the matching visitor id | DB 62 section 7 |

Residual risk, the same as any sign-up: someone who types a brand-new address and sets a password before its owner
confirms could sign in after the owner confirms through the sign-up confirmation email. The continue link does not
remove a password set that way. The address owner can reset the password at any time.

## 4. The "Continue your request" email and link

One email per account, ever (`capture_accounts.continue_sent_at`), code `renter_continue_request`, transactional,
through the outbox (daily cap and the sender's limits apply). A new account: sent by `app.job_capture` (pg_cron
`carmacars-capture`, every 15 minutes) `capture_continue_minutes` (30) after the form was left unfinished, only between
`recovery_send_from_hour` and `recovery_send_until_hour` (9:00 to 21:00 Toronto). An existing account: at once, as the
site says it sent. The link is `/continue?t=<token>` (only its hash kept, `capture_link_hours`, 72): the route makes a
fresh token-hash magic link (`continueLink`: Supabase `generate_link` type magiclink) and redirects to
`/auth/callback?token_hash=...&type=magiclink&next=...`, which signs in AND confirms the email (and calls
`server_account_email_verified`, so earlier requests attach as in 0040), then lands on the draft (`/book/<car>`), the
request (`/account/bookings/<number>`), the owner application or the contact page.

## 5. Staff

| Screen | What |
| --- | --- |
| People > Renters > a renter | "Email not confirmed" beside the email; "Typed into forms" with every capture and whether it was sent |
| Today > Live visitors (Admin and assistants) | On the visitor's line: "Typed into the booking request, not sent: name, email, phone", "Email not confirmed", the renter page |
| Bookings > Leads (Admin), My work > Game leads (customer service, Sales) | "Typed into forms": when, name, on the site now, email, phone, form, sent or not, email not confirmed (`captured_contacts`) |
| To do | "Unfinished requests to follow up"; each task "Unfinished request from <name>: follow up" (queue admin), raised 30 minutes after the form was left, never in the quiet hours of the site alerts (`uptime_quiet_from_hour` to `uptime_quiet_until_hour`), closed by itself when the form is sent |

Program settings (all on by default): `capture_enabled`, `capture_continue_minutes` (30), `capture_link_hours` (72),
`capture_close_days` (30), `capture_rate_per_minute` (30), `capture_followup_tasks`.

## 6. Privacy (for the lawyer)

`docs/source/website_terms_policies.md`, Part 2 section 1, and the live `legal.privacy` block (only where it still has the
discount games row), one new row; "Last updated" October 21, 2026:

> | Forms you start: the name, email and mobile number you type into our forms, saved as you type even if you do not send the form | To open an account in your name so you can continue your request, and to send you one email with a link to continue; never for offers without your consent |

To review: that the email is transactional (it concerns the account opened in the person's name; CASL); that no
retention period is stated for unsent form contacts (the lead is kept; the account's sign-in closes after 30 days); that
section 10 says the discount game counters stay on the device "unless you claim a prize", while a name and email typed
into the claim form are now saved as typed (covered by the new row).

## 7. Guides

- `admin/discount-games-and-leads`: new task "Contact details typed into forms" (the Leads card, Email not confirmed, the To do, the one email, the 30-day close)
- `admin/live-visitors-and-live-chat`: new task "What a visitor typed"
- `va/discount-game-leads`: new task "Contact details typed into forms"
- `renter/find-a-car-and-send-a-request`: new task "Carry on later" (saved as typed, this device, the one email, the existing account message)

Published by the migration (`supabase/seed/0090_gen_guides.mjs`); the Python sources in `docs/guides/src/guides/` match.

## 8. Tests

| Suite | Result |
| --- | --- |
| Database (`scripts/test.sh`) | 4734 passed, 0 failed; new suite 62, 59 assertions (03 lists the four capture tables among those not audited, 07 counts the new email and builds it, 34 counts the new To do item) |
| Unit (`npm run test:unit`) | all passed; new `fields.test.ts` (valid values only, half-typed fields left out, the existing account message never says more) |
| End to end, 375 and 1440 | `contact-capture.spec.ts` 4 of 4; request, auth, signup, owner, live chat, admin, portal, pages and site suites pass locally (the Plinko game test is timing-flaky, unrelated) |

Not done: the Program settings form has no fields for the six capture settings yet (they are on by default; Admins can
change them in the database or a later release adds them to the form).
