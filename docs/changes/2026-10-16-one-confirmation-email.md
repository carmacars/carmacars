# One confirmation email per sign-up, October 16, 2026

Migration `supabase/migrations/0045_one_confirmation_email.sql`, tests `supabase/tests/29_one_confirmation_email.sql`,
end to end `web/tests/e2e/signup.spec.ts` (with changes to `auth.spec.ts`, `owner.spec.ts` and `signin.spec.ts`), live
check in `web/scripts/verify-live.mjs` (verify with `full`). No earlier migration was edited.

## 1. What happened

At 00:01 UTC on October 16 an owner applied from List your car and got four emails:

| Email | From | Its button |
| --- | --- | --- |
| "Confirm your CarmaCars account" | Supabase Auth | `/auth/callback?token_hash=...&type=signup&next=/account`: the only link that confirms |
| "Confirm your email to finish your CarmaCars account" (`renter_account_created`) | the app | "Confirm my email" to `https://carmacars.ca/sign-in` |
| "Confirm your email to open your CarmaCars owner account" (`owner_account_created`) | the app | "Confirm my email" to `https://carmacars.ca/sign-in` |
| "We have your application for the ..." (`owner_application_received`) | the app | the application page |

He pressed the app's button, reached the sign-in page, and sign-in refused him because the address was not confirmed.
The Supabase link expired an hour later (`mailer_otp_exp` 3600).

## 2. Root cause

- 0023's trigger `user_roles_notify` emitted an account email for every renter or owner role granted. The owner
  application grants two roles (the renter role from `register_account`, then the owner role from
  `submit_owner_application`), so it emitted two. It also fired for a guest's booking request (renter role, no sign-in
  at all), for an Admin's owner invitation, and for the verification accounts.
- The templates asked for a `verify_url` that nothing supplied: Supabase Auth makes the confirmation link and sends its
  own email. The outbox sender filled the missing value with the sign-in page (`supabase/functions/send-outbox`), so
  the button looked like a confirmation and confirmed nothing.
- The app's done page after the application offered "Go to your owner portal", which also leads to a sign-in that
  cannot work until the address is confirmed.
- Supabase's confirmation link always carried `next=/account`, so even the real link opened the renter portal.
- One more double email found on the way: creating an account (or applying) with an address already on file from a
  booking request made a Supabase sign-up first (Supabase sent its confirmation), then removed that sign-in and sent a
  password link for the record. Two emails, the first with a dead link.

## 3. What changed

**One email asks to confirm: Supabase Auth's.** Its link is the only one that confirms, so it stays the single
confirmation email. The app's two account emails are now welcomes sent once the address is confirmed:

| Code | Subject now | Button | Sent when |
| --- | --- | --- | --- |
| `owner_account_created` | Your CarmaCars owner account is ready | Open my owner portal (`/owner`) | The address is first confirmed and the person has the owner role |
| `renter_account_created` | Your CarmaCars account is ready | Browse cars (`/cars`) | The address is first confirmed and the person has the renter role and no other portal |

- "First confirmed" is `users.email_verified_at` going from empty to set (0040's `app.account_email_verified`, called by
  the confirmation link, an invitation or password link, and a sign-in). Trigger `users_confirmed_notify`, dedupe key
  `<code>:<user>:confirmed`, so it goes once. Staff, Admins and investors get no welcome.
- `user_roles_notify` is dropped: granting a role emails nothing. Old-style account emails still waiting were skipped
  and their events closed by the migration.
- Accounts Supabase had already confirmed get `email_verified_at` from `auth.users.email_confirmed_at` in the migration
  (a column of our own `users` table; no Auth record is touched), so nobody with a working account gets a late welcome.
  Accounts not yet confirmed (the owner of section 1) get the welcome when they confirm.
- The sender no longer invents a `verify_url`; no catalogue email reads one (checked in `29_one_confirmation_email.sql`).
- An address already on file (a booking request, a record staff made) is checked before any sign-up: it gets a sign-in
  for that record and one email, the link to choose the password. Supabase never sends a confirmation for it.

Emails per path, after the change:

| Path | At sign-up | After the link |
| --- | --- | --- |
| `/create-account` | Supabase: "Confirm your CarmaCars account" | Renter welcome; lands in `/account` |
| List your car, with or without an invitation link | Supabase: "Confirm your CarmaCars account"; the app: "We have your application" | Owner welcome; lands in `/owner` |
| Booking request (no account) | The app's request emails only (no account email) | Nothing until they make an account |
| `/create-account` or List your car with an address on file | Supabase: "Reset your CarmaCars password" (choose the password) | Renter or owner welcome; lands in the portal |
| Admin invitation (staff, owner on file, investor on file) | Supabase: "Your CarmaCars account" (choose your password) | Owner on file: owner welcome; staff and investors none; lands in the portal |

**Landing by role.** The confirmation template's link has no `next` any more
(`/auth/callback?token_hash={{ .TokenHash }}&type=signup`). The callback sends the person to their portal by role
(`landingFor`, as after a password): an owner who applied lands in `/owner`; someone with two or more portals on
"Choose a portal"; a renter in `/account`. A confirmation link still carrying `next=/account` (sent before this change)
is read the same way. Invitation and password links keep `next=/update-password`, which then lands by role as before.

**The owner application's done page** no longer offers "Go to your owner portal" before the address is confirmed. It
says: one more step, confirm your email, with the address, the subject to look for, the 24 hours, and what to do if
nothing arrives.

**Link lifetime: 24 hours.** `mailer_otp_exp` goes from 3600 to 86400 (`scripts/deploy/auth-templates.mjs`, applied by
the deploy's `auth` step). Supabase has one setting for every email link, so the reset and invitation links also last
24 hours. That is a longer window for a forwarded or intercepted link; each link still works once, and for a rental
business whose customers open emails on their own schedule a link that lapses after an hour costs more than it saves.
All copy that said "one hour" now says "24 hours": the templates, the sign-in and reset forms, `/link-expired`, Admin >
Portals and Staff, and the user guides (`docs/guides/src`, re-exported to `docs/guides/content`).

**Confirm first, resend in one click.** Signing in before confirming shows "Confirm your email first" with the button
"Send a new confirmation link" (Supabase's `/resend`). A second press within Supabase's one-minute limit says so instead
of claiming a new email went. `/link-expired?kind=confirm` has the same button, with the address used on this device
filled in.

**The local stand-in for Supabase Auth** (`web/src/lib/auth/local.ts`) now works as Supabase does with confirmations
on: a sign-up writes the confirmation email to `local_auth.mailbox` and has no session until its link is opened, and
sign-in refuses an unconfirmed address with the same message. That is what lets the end-to-end tests check the real
sequence.

## 4. CI on a public repository

The repository is public. `.github/workflows/ci.yml` no longer has a `pull_request` trigger: a pull request from a fork
would have run the fork's code. The triggers are a push to this repository and Run workflow; secrets reach only the
deploy job, which runs only on Run workflow. Run logs are public: no step prints a secret (each is masked) or personal
data (the checks use test addresses: `@example.test` locally, `verify-*@carmacars.ca` and `delivered+...@resend.dev`
live). `docs/ci-minutes.md` notes that Actions minutes are free while the repository is public.

## 5. Tests

- `supabase/tests/29_one_confirmation_email.sql` (25 assertions): no account email when a role is granted (sign-up,
  owner application, guest request, staff); the welcome once after the confirmation, owner over renter, none for staff
  or investors, none for a confirmation of another address; built with every variable; the catalogue has no
  `verify_url` and no "confirm your email" subject; the live verification functions only for their throwaway
  addresses; privileges.
- Changed in `07_notifications.sql`: the completeness block emits the two welcomes itself (no role grant does any more),
  and `verify_url` left the list of values the sender supplies.
- `web/tests/e2e/signup.spec.ts` (375 and 1440): `/create-account` (one confirmation, nothing from the app; sign-in
  first says confirm first and sends a new link; the link lands in `/account`; one welcome; the same link again offers a
  new one; sign out, sign in); the owner application without and with an invitation link (the confirmation plus "We
  have your application", no account email; the done page asks to confirm; the link lands in `/owner`; one owner
  welcome; sign out, sign in); a guest's booking request then `/create-account` with the same address (no email at the
  request; one password link; `/account`; one welcome; sign out, sign in).
- `signin.spec.ts`: the invitations send no account email; after the password the invited owner gets one welcome, the
  assistant none. `auth.spec.ts` and `owner.spec.ts` open the confirmation link before using the account.
- Live (`verify` with `full`): each path with a throwaway address `verify-signup-<path>-<n>@carmacars.ca` on the
  suppression list (nothing is sent): no account email before the link; sign-in first shows "Confirm your email first"
  and the resend button (not pressed, it would send an email); the link exactly as the template carries it lands in the
  portal by role; exactly one welcome, suppressed in the outbox; sign out; sign in. Removed again. The run also checks
  that the project's links last 86400 seconds and the confirmation link has no fixed `next`.

## 6. For the owner of section 1

His sign-in is still waiting for its confirmation (the link he was sent expired after an hour). Nothing needs changing
on his account:

1. Go to https://carmacars.ca/sign-in
2. Enter his email and the password he chose in the application, and press **Sign in**.
3. The page says "Confirm your email first". Press **Send a new confirmation link**.
4. Open the email "Confirm your CarmaCars account" within 24 hours and press **Confirm my email**. He lands in his owner
   portal, signed in, and gets "Your CarmaCars owner account is ready".

## 7. Deploy and results

| Run | Result |
| --- | --- |
| Push CI of the fix (38847822433) | green (fast gates: database suite 3,228 assertions, text check, lint, types, unit tests, generated types) |
| Deploy, `ci` with `deploy` (38847853019) | full suite failed: the owner billing test read the first of three vehicles that share one creation instant (order not fixed), and the crawl met a 404 on a listing's odometer shot (a shot kept as taken has its original as its processed path; the review built a public link for it). Both fixed in 10c3ac6 |
| Deploy, `ci` with `deploy` (38852184301) | green: fast, full (169 end-to-end tests at 375 and 1440, crawl as every role, links, copy, SEO, emails), deploy. Migrations 0044 and 0045 applied (history 45 rows), Auth settings and templates updated, 148 email templates loaded, send-outbox redeployed, guides seeded, committed guide PDFs uploaded |
| `guides-pdf` (38854859791) | green: the six guides printed from the live database and stored (renter 37 pages, owner 27, admin 56, VA 29, field 15, investor 14) |
| `verify` with `full` (38854923680, 38856159056, 38857087460, 38859249333, 38861533645, 38863629274) | Every sign-up path passed on the live site (renter, owner, guest, in several runs each); every portal's guide shown; Admin: the Paid and signed tab, the paper signature form and the month's payments received another way. Each run also had pages the Worker answered with Error 1102 (the free plan's CPU limit), which failed whichever check met them: a portal sign-in, a password save. Reported separately |

Live state after the deploy (read from the project, nothing changed by hand):

- Supabase Auth: `mailer_otp_exp` 86400; the confirmation template links to
  `/auth/callback?token_hash={{ .TokenHash }}&type=signup` (no `next`); subject "Confirm your CarmaCars account".
- The catalogue: "Your CarmaCars owner account is ready" and "Your CarmaCars account is ready", emitted by
  `users_confirmed_notify (0045)`; `user_roles_notify` gone; no account Supabase has confirmed is left without
  `email_verified_at`.
- The owner of section 1: his sign-in is still unconfirmed (as expected), with the renter and owner roles; his welcome
  goes when he confirms, and the link lands him in `/owner`.

Sign-up results of the last live run (`verify` 38863629274: all three sign-up paths, the email links, Admin with the guide and the manual records passed; five portal sign-ins met Error 1102 or a dropped connection): renter, sign-in first says "Confirm your email first" with the
button, the link lands in `/account`, one `renter_account_created` (suppressed for the throwaway address), sign out and
in to `/account`; owner, the same to `/owner` with one `owner_account_created`; guest, no email at the request, the
password link, `/account`, one renter welcome, sign out and in. Each throwaway account removed again.
