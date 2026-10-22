# Sign in with a phone number (migration 0091)

The owner asked for "signing in with your phone number instead of email, for verification codes and sign in". People can
now sign in, sign up and verify a phone with a 6-digit code texted from the CarmaCars Quo number, (289) 312-5991. No
password is needed for phone sign-in. Builds on the Quo phone line (branch `quo`, migration 0085): merge it after `quo`.

## 1. How it fits together

| Piece | Where |
| --- | --- |
| Codes | Supabase Auth's phone provider (`POST /auth/v1/otp`, `verifyOtp` type `sms`; adding a number: `updateUser({ phone })`, `verifyOtp` type `phone_change`). 6 digits, valid 5 minutes, one code a minute per number |
| Texting the code | Supabase's Send SMS hook calls `POST /api/webhooks/auth-sms` (`web/src/app/api/webhooks/auth-sms/route.ts`, `web/src/server/auth-sms.ts`). The Standard Webhooks signature is checked on the raw body (`web/src/features/auth/sms-hook.ts`; secret `v1,whsec_...`, 5 minutes of clock tolerance, a new and an old secret both accepted). Then `app.server_auth_sms` decides, and the text goes out through the Quo client of 0085 (`phoneLine().sendText`) from the CarmaCars number: "CarmaCars code: 123456. It expires in 5 minutes. Don't share it." |
| When Quo fails | The hook answers with a non-2xx status and `{ error: { http_code, message } }` (502 for a Quo failure, 403 for a refused number, 429 for the limit), so Supabase reports the failure to the request; the page says "We could not text a code right now. Try again in a minute, or sign in with your email." |
| Only codes the site asked for | The server action records each request (`app.auth_sms_intent`) after its checks; the hook texts a code only for a number with a request of the last 3 minutes. A code asked for around the site (straight from Supabase's API with the public key) is never texted, and a phone change texts the new number, never an old one |
| Limits | Ours: 5 codes per number and 20 per connection (IP) an hour, 10 code checks per number and 60 per connection an hour (`app.signin_phone_request`, `app.rate_limit`), Turnstile on the public request; the hook's own backstop: twice the per-number limit an hour. Supabase's: one code a minute per number (`sms_max_frequency` 60) and its project limits |
| Log | `app.auth_sms_log`: the number, the account, sent / failed / refused and why, Quo's message id. Never the code. Kept 30 days. Outside the API and the audit log |
| Server actions | `web/src/server/actions/phone-auth.ts`: `requestPhoneCode`, `verifyPhoneCode`, `savePhoneName`, `setSignInMethod`, `saveAccountEmail` |
| Local stand-in | `web/src/lib/auth/local.ts` and `web/local/local_auth.sql` (`local_auth.otps`, phone columns): the same rules as Supabase, the codes through the same SMS path (database checks, the fake Quo line) and written to `local_auth.mailbox` (`to_phone`), where the tests read them like the emails |

## 2. Screens

- **Sign in** (`/sign-in`): "Use my phone number instead": the mobile number, "Text me a code", the 6-digit code
  (`autocomplete="one-time-code"`, `inputmode="numeric"`, so phones fill it in; it signs in as soon as 6 digits are in),
  "Send a new code" after a minute, "Use another number", "Use my email instead". A new account with no record behind the
  number is asked its name once. The device remembers the last sign-in used (cookie `cc-signin`), and `?method=phone`
  opens it directly. Two-step sign-in still applies after the code (staff with an authenticator app).
- **Create account**: "Sign up with my phone number instead": name, mobile number, the terms box, then the code.
- **Request to book**: signed in by phone, the form fills the verified mobile number and the email is optional ("You
  can also add it before you pay"); a visitor still gives both.
- **Contact form**: an email or a mobile number (either one) so we can reply.
- **Profiles** (renter `/account/profile`, owner `/owner/profile`, assistants `/va/profile`, field staff
  `/field/profile`): a Sign-in card: the email (confirmed or not), the phone ("Verified"), "Add and verify my phone
  number" (a number on file is filled in), "Save my email" for an account made by phone, and "Sign in with": my phone
  number (a code by text) or my email and password.
- **Pay**: an account with no email gets "We send your receipt and the signed agreement by email. Add your email to
  pay." before the card form; the email is saved and the sign-in service sends a link to confirm it.
- **Admin > Settings > Program settings > Sign-in by phone**: the settings of section 5.

## 3. Linking (only after the code is verified; nobody learns whether a number has an account)

`app.phone_signed_in` (the account's users row, made when new: no email, the number verified, the renter role, the
name given or from the record) then `app.account_phone_verified`:

1. The number is the signed-in account's (`users.phone`, `phone_verified_at`). A phone verified on an account signed in
   by email is attached to that account; it then also signs in by phone (Supabase keeps the number on the same user).
2. A renter record with the number (its mobile or its account holder's) that has no confirmed sign-in of its own (a
   guest's booking request, a record staff made) becomes this account's, with its requests and bookings, when this
   account has no renter record yet.
3. An owner record with the number and no account at all (an owner lead) becomes this account's, with the owner role.
   An owner record that has an account is never taken over.
4. An additional driver's place with the number is attached, as an email does it.
5. Leads with the number (contact form, discount game, live chat, calls) are listed for staff; a lead's name fills an
   empty name.
6. A record of another confirmed account, a second renter record, or an owner record with an account becomes the task
   "A verified phone matches another record" (customer service). The person sees the same screens either way.
7. The Quo thread of the number now shows the renter record.

Every answer reads the same whether or not a number has an account: Supabase makes the account of a number at its first
verified code; adding a number that belongs to another account answers "We texted a code" and sends nothing (the code
then never matches).

## 4. Confirmation and the email before the first payment

Migration 0090 (branch `capture`, "unverified accounts") is not merged, so the rule is here and configurable:
`app.account_gate` before accepting an offer, signing and paying (`web/src/server/actions/portal.ts`, the pay page). With
`signin_confirm_required` (on), the account must be confirmed: a confirmed email, or a phone verified with a code when
`signin_confirm_by_phone` (on). Paying also needs an email for the receipts: an account made by phone gives it on the
pay page. When 0090 lands, its rule should call `app.account_confirmed(user)`, which already counts a verified phone.

## 5. Settings (Program settings, "Sign-in by phone")

| Setting | Default |
| --- | --- |
| `signin_phone_enabled` | on |
| `signin_phone_us_allowed` | **off** (Canada only; see section 7) |
| `signin_phone_hourly_per_number` | 5 |
| `signin_phone_hourly_per_ip` | 20 |
| `signin_confirm_required` | on |
| `signin_confirm_by_phone` | on |

## 6. Production configuration (the deploy only; nothing was changed in production by this work)

`scripts/deploy/supabase.sh`, run by the ci workflow's deploy job:

- `smshook` (with the other Supabase steps, before the Worker is deployed): the hook secret in the vault
  (`deploy_auth_sms_hook_secret`, `v1,whsec_` and 32 random bytes, made once), exported as the Worker secret
  `AUTH_SMS_HOOK_SECRET`.
- `phoneauth` (production only, after the Worker is deployed and only when `/api/webhooks/auth-sms` refuses an unsigned
  call with 401): `PATCH /v1/projects/{ref}/config/auth` with the settings that differ from these:
  `external_phone_enabled: true`, `sms_autoconfirm: false`, `sms_otp_length: 6`, `sms_otp_exp: 300`,
  `sms_max_frequency: 60`, `sms_template: "CarmaCars code: {{ .Code }}. It expires in 5 minutes. Don't share it."`,
  `hook_send_sms_enabled: true`, `hook_send_sms_uri: https://carmacars.ca/api/webhooks/auth-sms`,
  `hook_send_sms_secrets: <the vault secret>`. Idempotent: a second run sends nothing (or only the secret, when Supabase
  does not show it back, which changes nothing). It checks the result and reports what changed.

## 7. Texting US numbers: not yet

Texts to US numbers from a business number need A2P 10DLC registration, and the CarmaCars Quo number is not registered
(Quo: Settings, Trust center). Until it is, US carriers block the codes. So phone sign-in is restricted to Canadian
numbers (+1 with a Canadian area code; the list is in the migration and `web/src/features/auth/phone.ts`, and a unit
test keeps them the same). US numbers are behind the Admin setting `signin_phone_us_allowed`, off by default: turn it on
only after the registration is approved. Numbers outside +1 never get a code.

## 8. Privacy policy

One line in section 10, after the paragraph on calls and texts (`docs/source/website_terms_policies.md`, and the live
`legal.privacy` block by the migration where it still has our text):

> If you sign in or verify your phone number with us, we text a one-time sign-in code to the phone number you give.

## Guides

Renter: "Sign in with your phone number" (after Documents, notifications and profile), with the tip on signing up by
phone, the email asked before the first payment and an earlier request being added. Owner: a first-sign-in step. VA: a
first-sign-in step (two-step sign-in still asks for the authenticator code). Field: "Sign in with your phone number"
(Profile, Sign-in). Admin: Program settings, the Sign-in by phone group. Source `docs/guides/src/guides/*.py`;
`docs/guides/content/*.json` regenerated with `export.py` (only these sections changed). The portals' stored guides pick
them up through the guides workflow after the deploy.

## Tests

- Unit (`npm run test:unit`): `web/src/features/auth/sms-hook.test.ts` (the Standard Webhooks signature against an
  independent HMAC, a changed body, another secret, the timestamp both ways, rotation, the payload and the phone-change
  number, the text and the error shape), `web/src/features/auth/phone.test.ts` (E.164 from the ways people type a number,
  Canadian area codes including the newest overlays, CA / US / other, who may get a code, the lists equal to the
  migration's).
- Database (`supabase/tests/56_phone_sign_in.sql`, 76 assertions): settings and who may get a code, the limits per
  number, per connection and for code checks, the hook texting only requested codes (and the new number of a phone
  change), its backstop limit and the log; the account made by phone (a booking request without an email); linking (a
  guest record with its booking, a record with no account, never another confirmed account's record, owner leads, never
  an owner with an account, driver places, leads, a second record as a task); a phone added to an email account and a
  number moving between accounts; confirmation (a verified phone counts, configurable, the rule off), the email before
  paying (taken, invalid, saved, confirmed later); the chosen sign-in, the profile card; privileges; the privacy policy.
- End to end at 375 and 1440 (`web/tests/e2e/phone-signin.spec.ts`, SMS sender mocked: codes read from the local
  outbox): sign in by phone with a new number (a US number refused, a wrong code, the text, the name once, the profile,
  the device remembering), the hook refusing unsigned calls and unrequested codes, adding a phone to an email account and
  signing in with it on another device, a phone sign-in for a number on an earlier booking request (attached only after
  the code; an email added later). axe, overflow and the copy rules on each screen.

## What still needs the owner

- Register the Quo number for A2P 10DLC (US texting) if US renters should sign in by phone, then turn on
  `signin_phone_us_allowed`.
- The next deploy switches the phone provider on (section 6). Nothing else to set up.
