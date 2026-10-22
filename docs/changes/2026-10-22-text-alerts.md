# Text alerts: email, text or both (migration 0096)

The owner asked: "people will have the option to verify and get alerts via text instead of email". Every renter, owner,
investor and staff member now chooses how CarmaCars reaches them: **Email**, **Text** or **Both**. Texts go from the
CarmaCars Quo number through the Quo integration of 0085, only to a phone verified with a code (0091). Built on branch
`rel3` (0085 and 0091 included), then merged with `vehiclepages` (477a976: release 4, the Worker size fix, the games fix
and the vehicle pages, migrations through 0101). Migration `0096_text_alerts.sql`; no applied migration was edited.

**Deploy order.** 0096 is numbered below migrations production already has (0097 to 0101). The deploy applies the
missing migrations in filename order, so production gets 0096 alone, after 0101. Checked locally both ways: every
migration in filename order (CI, a fresh database), and production's own order (..., 0091, 0094, 0099, 0093, 0095, 0098,
0100, 0097, 0101, then 0096). Both apply cleanly and end with the same schema (functions, triggers, policies and
columns compared; only the internal names of the `app.door` chain differ, as each migration renames the one before it).
Suite 69 passes on both. Schema marker 0101 (the highest migration).

## 1. The choice

| Where | What |
| --- | --- |
| Profiles: renter `/account/profile`, owner `/owner/profile`, investor `/investor/profile`, assistants `/va/profile`, field staff `/field/profile` | The card **Messages**, "How should we reach you?": Email, Text or Both, saved as soon as it is chosen; what is used now; why texts are not going (no verified phone, STOP, a US number, switched off); the quiet hours and STOP |
| The booking request (step 2, The driver) | The same choice. Signed in with a verified phone: Both is chosen, and the hint names the number. A visitor may choose Text: it is kept on the renter record and used once they verify a phone (sign in with their phone number). The review step shows "Messages" |
| The phone sign-up (`/create-account`, Sign up with my phone number instead) | The same choice with **Text** chosen, saved with the account |
| Admin: People > a renter, owner or investor | The card **How we reach them**: chosen, used now, verified phone, why not text, texts in 30 days, STOP and START; **Change** (audit log). Admins and assistants change a renter's or owner's; an investor's only Admins |

Stored on `users.notify_channel` (empty: the default) and, for a record without an account (a guest's request, a record
staff made), on `renters`, `owners` or `investors.notify_channel`; the account's choice wins.

**Default** (Program settings, Text alerts): Both for a person with a verified phone and an email (`sms_default_with_phone`),
Text for an account with a verified phone and no email (`sms_default_phone_only`), otherwise Email.

## 2. Routing (the notification layer)

Emails are queued in `notification_outbox` by `app.process_events` (and a few direct inserts) and sent by the
`send-outbox` Edge Function; texts are queued in `phone_outbox` and sent by the five-minute phone job
(`/api/jobs/phone`, `server_phone_due`, Quo `POST /v1/messages`). 0096 puts two triggers on `notification_outbox`, so
every path is covered:

- `notification_outbox_route` (before insert): for a renter, owner or investor notification, `app.notify_reach` works out
  the person's channel now. **Text**: the email is `skipped` ("Sent by text (the person chose text)") and a text is
  planned. **Both**: the email and a text. **Email**: the email only. Staff notices are never routed.
- `notification_outbox_route_text` (after insert): queues the text (`phone_outbox.kind = 'notify'`, the person's
  `user_id`, `sms_kind` = the email's code, dedupe `sms:<email dedupe key>`).

| Rule | How |
| --- | --- |
| No verified phone | Email only (`why_not = no_verified_phone`) |
| No email address | Text, whatever was chosen, when the phone can be texted (a phone-only account) |
| Always by email | Codes flagged `notification_catalogue.always_email` (signed agreements, final statement, receipts, extra charges, refunds, damage, the authority notice; owner statements, signed documents, invoices, voids, payment receipts, PAD confirmation, debit notice, fee change notice, enrolment, exit; investor statement and notice) are emailed whenever there is an address. A Text person also gets a text with a link to the page in their portal, behind sign-in, where they view or download it |
| Never a text | `no_text`: only the sign-in and security emails: password reset, sign-in link, security notice, and "Continue your request" (a one-tap sign-in link) |
| Sent to someone else | `text_to_recipient`: an additional driver's link (`renter_driver_link`) and a co-signer's (`owner_cosigner_sign`) are texted to that person: the account of the address the email goes to, its own channel and verified phone, never the renter's or owner's. No account with a verified phone: email only |
| Chat transcript | Always emailed (the visitor typed the address for it); someone on Text or Both also gets "we emailed you a copy of your chat" |
| Marketing | The review request is texted only when its email may go (consent), and for a phone-only account only with marketing consent |
| Opt-outs | A number that replied STOP (or a renter marked no texts): email only |
| US numbers | A US number waits for A2P 10DLC: `signin_phone_us_allowed` (0091, off) also gates every text from the outbox, the missed-call text and staff replies included. Numbers outside Canada and the US: email only |
| A text that does not go after all | STOP while it waited, Quo refusing it, the person choosing email meanwhile (the job checks again before sending): the email it replaced is queued ("By email: the text was not sent (...)") |
| Switched off | `sms_alerts_enabled` off (or the phone line off): email only for everyone |

The texts: `sms_templates`, one row per customer email (editable in Admin > Settings > Text alerts: the text, on or off,
urgent). The generic text `CarmaCars: {{subject}}. Details: {{link}}` is only for an email added later without a row
(Settings shows how many; suite 69 fails if a customer email has none). Placeholders are the
email's `{{variables}}`; the booking's own values fill what the email did not carry; `{{link}}` is the page of the email
(the portal page for documents); an email without a page uses its own link (a driver's signing link, the Google review
page, the car of an unsent request), else the person's portal. A template names CarmaCars, keeps `{{link}}`, has no long dash and is at most 320
characters (`app.sms_template_ok`).

| Notification | Code | Text (with sample values, one text unless noted) |
| --- | --- | --- |
| Booking received | `renter_request_received` | CarmaCars: we have your request CC-10482 for the 2024 Mercedes-Benz C 300 4MATIC Sedan, Fri, Oct 23, 2026. Track it: (link) |
| Offer ready | `renter_offer_ready`, `renter_offer_reminder` | CarmaCars: your offer for the ... is ready, $1,468.95. Review and accept: (link) |
| Offer accepted, booking confirmed | `renter_booking_confirmed`, `renter_rental_added`, `renter_recovery_pay` | CarmaCars: booking CC-10482 is confirmed. ..., pickup ... at 10:00 am. Details: (link) |
| Payment received or failed | `renter_payment_receipt`, `renter_payment_failed`, `renter_balance_overdue`, `owner_payment_failed` | CarmaCars: payment of $468.95 received for booking CC-10482. Receipt: (link) |
| Deposit hold | `renter_deposit_declined`, `renter_deposit_released` | CarmaCars: the deposit hold of $1,000.00 for booking CC-10482 was declined. Fix it here: (link) |
| Pickup and return reminders | `renter_booking_reminder`, `renter_pickup_details` (urgent), `renter_return_reminder`, `renter_return_details` (urgent) | CarmaCars: pickup tomorrow at 10:00 am for the ... (CC-10482). What to bring: (link) |
| Extension | `renter_extension_approved`, `renter_extension_confirmed`, `renter_extension_declined` | CarmaCars: extension confirmed. New return ... at 10:00 am. Details: (link) |
| Late return | `renter_late_return_first`, `renter_late_return_final` (both urgent) | CarmaCars: booking CC-10482 ended at 10:00 am. Please return the car now or extend: (link) |
| Documents to sign | `renter_agreement_ready`, `owner_agreement_ready`, `owner_schedule_resign`, `person_document_to_sign` | CarmaCars: your rental agreement for booking CC-10482 is ready to sign: (link) |
| Verification steps | `renter_identity_needed`, `renter_identity_rejected`, `renter_coverage_needed`, `renter_identity_approved` | CarmaCars: upload your licence and proof of coverage for booking CC-10482 by ...: (link) |
| Review request | `renter_review_request` | CarmaCars: how was the ...? Rate your rental: (link) |
| Owner: car booked | `owner_new_booking` | CarmaCars: your ... is booked, ... to .... Details: (link) |
| Owner: payout sent, statement ready | `owner_payout_sent`, `owner_statement_ready` | CarmaCars: payout of $2,140.55 sent for October 2026. Details: (link) |
| Owner: invoice due | `owner_fee_invoice`, `owner_invoice_issued`, `owner_upfront_invoice`, `owner_debit_notice` | CarmaCars: invoice INV-2026-0142 for $545.00 is due Nov 1, 2026. View it: (link) |
| Investor | `investor_statement_ready`, `investor_return_paid` | CarmaCars: your October 2026 investor statement is ready. View or download it: (link) |
| Also | signed agreement and final statement (documents), cancellation, staff message, breakdown, accident, car disabled (urgent) | |

**Every customer email has its own text (the owner: "47 text versions is too few").** The 176 email templates are 113
customer emails (renter 67, owner 42, investor 4) and 63 others (staff 62, the insurer's invoice 1). 109 of the 113
have their own text: the 47 above and 62 added, one for each email that had none:

| Who | Texts added (code: label) |
| --- | --- |
| Renters and leads (30) | `renter_account_created` Account ready; `renter_request_needs_info` Request: one question; `renter_request_declined` Request declined; `renter_recovery_request` Request not sent yet; `renter_recovery_offer` Offer waiting; `renter_offer_expired`; `renter_offer_withdrawn`; `renter_refund_issued`; `renter_extra_charge`; `renter_rental_started`; `renter_return_complete`; `renter_extension_requested`; `renter_change_request_received`, `_approved`, `_declined`; `renter_change_proposed`; `renter_change_proposal_reminder`; `renter_recovery_change`; `renter_change_proposal_expired`; `renter_change_applied`; `renter_damage_found`; `renter_named_to_authority`; `renter_booking_cancelled_by_us`; `renter_google_review_request`; `renter_comeback_1w`, `_1m`; `renter_game_code`, `renter_game_code_reminder`; `renter_chat_transcript` |
| Additional drivers (1) | `renter_driver_link` Additional driver: accept (with the signing link) |
| Owners (30) | `owner_account_created`; `owner_application_received`, `_info_requested`, `_approved`, `_declined`; `owner_onboarding_steps`; `owner_registry_visit`; `owner_car_set_up`; `owner_vehicle_enrolled`; `owner_vehicle_listed`; `owner_booking_changed`; `owner_booking_confirmed`; `owner_payment_received`; `owner_payment_recorded`; `owner_payment_reversed`; `owner_invoice_voided`; `owner_debit_setup_needed`; `owner_pad_confirmed`; `owner_debit_returned`; `owner_in_arrears`; `owner_bank_details_changed`; `owner_fee_change_notice`; `owner_document_due`; `owner_form_approved`, `_rejected`; `owner_incident_opened`, `_update`; `owner_toll_ticket`; `owner_exit_notice_received`; `owner_exit_completed` |
| Co-signers (1) | `owner_cosigner_sign` Co-signer: documents to sign (with the signing link) |
| Investors (1) | `investor_notice_received` |

Every placeholder of the 109 texts is a variable of its email (checked), the longest template is 148 characters, none
has a long dash. **Still on the generic text: none.** Never texted (4): `account_password_reset`, `account_sign_in_link`,
`account_security_notice` (security, email or link only) and `renter_continue_request` (a one-tap sign-in link: the
same reason). Not routed at all: `insurer_invoice` (an insurer's claims office, a business address, not a person with a
channel) and the 62 staff notices.

0085's booking texts are replaced: its trigger `notification_outbox_phone_sms` is dropped and its six moments
(`program_settings.phone_sms_*`) are no longer read (a moment an Admin had switched off is switched off on its template;
`phone_sms_booking` off turns `sms_alerts_enabled` off). They used any mobile number on the renter record; texts now need
a verified phone, as the owner asked ("verify and get alerts via text").

## 3. Opt-outs

- STOP, STOPALL, UNSUBSCRIBE, CANCEL, END, QUIT, ARRET (0085) and now also OPT OUT, OPTOUT, REVOKE, STOP ALL, PLEASE STOP
  through the Quo webhook (`server_phone_event`, and the trigger `phone_activity_keywords`) set `phone_threads.opted_out_at`,
  the opt-out list. Texts waiting to the number are skipped and their emails go instead. START, UNSTOP, YES (0085) and
  OPT IN, RESUME turn texts back on.
- Every STOP and START is logged in `sms_opt_out_log` (shown on the person's Admin card), with its source: `stop` (a
  reply), `carrier`, `staff`, or `start` (a reply).
- **The confirmation (owner's decision: Quo sends none).** After a STOP reply the person gets one text, "CarmaCars:
  you're unsubscribed and won't get more texts. Reply START to resubscribe."; after a START reply, "CarmaCars: texts are
  back on. Reply STOP to opt out." (Program settings `sms_stop_confirm_text` and `sms_start_confirm_text`, editable in
  Settings > Text alerts; each must name CarmaCars and the keyword that undoes it). How: the webhook marks its
  transaction as a reply (`app.sms_reply`); the trigger `phone_threads_opt_log` (after update) logs the change and, for a
  reply, queues a `phone_outbox` row of kind `opt_confirm` (`sms_kind` `opt_stop` or `opt_start`, dedupe
  `optconfirm:<log id>`) already being sent; `server_phone_event` returns it with the delivery's texts and the Worker
  sends it at once through Quo (`handleQuoWebhook`). Quiet hours do not apply. Once per change: a second STOP to a number
  already stopped changes nothing and sends nothing, and a confirmation that never reported back is marked failed after 10
  minutes rather than tried again (a Quo error is retried like any text). The log row links it (`confirm_id`); the
  Admin card shows "confirmed by text"; the phone inbox labels it "STOP confirmation" or "START confirmation". A STOP or
  START set by staff, or a carrier block, is logged and sends nothing. The US gate still holds: a US number while US
  texting waits for A2P 10DLC is opted out and logged, and its confirmation is skipped with that reason.
- "Reply STOP to opt out." ends the first automated text to a number, and the first after a START (`sms_stop_line`).
- Quo and the carriers also block on their side.

## 4. Quiet hours

No text that is not urgent from 9 pm to 8 am Toronto time (`sms_quiet_hours`, `sms_quiet_from_hour` 21,
`sms_quiet_until_hour` 8): it waits in the outbox (`send_after`) and the phone job sends it at 8 am. Urgent templates
(late return, pickup and return details on the day, breakdown, accident, car disabled) go at once. Sign-in codes (0091),
staff replies and the missed-call text are not held. The site check's own quiet hours (23 to 7) are unchanged.

## 5. Admin

- **Settings > Text alerts** (new section): the defaults and quiet hours (Program settings `sms_*`, with US numbers), how
  many people chose each channel and the STOP count, and every text with a preview (edit, on or off, urgent; refused
  when it breaks the rules). Program settings also lists a "Text alerts" group; the old "Booking text" settings are hidden.
- **People**: the card How we reach them on each renter, owner and investor page.
- **Site health** (To do): "Texts today" with the last 7 days: sent, notification texts among them, failed, not sent, sign-in
  codes, and the texts waiting for 8 am (`app.sms_volume`, in `site_health`).

## 6. Privacy policy (for the lawyer)

Section 10, a new paragraph after the sign-in code line (`docs/source/website_terms_policies.md`, and the live
`legal.privacy` block by the migration where it still has our text). "Last updated" is not changed:

> If you choose to get our messages by text, we text you service messages about your bookings, account, payments and
> documents from our phone number, instead of or as well as email. Legal documents, statements and receipts are still
> emailed when we have your email address. You can reply STOP at any time to stop texts, and START to turn them back on;
> we then reach you by email. Message and data rates may apply.

To review: CASL (these texts as transactional; the review request texted only with the email's consent), the STOP line
on the first text, whether "Message and data rates may apply" is wanted.

## 7. Tests

| Suite | What |
| --- | --- |
| Unit `web/src/features/phone/alerts.test.ts` | Every template of the migration (parsed from the SQL): no long dash, names CarmaCars, has the link, at most 110 fixed characters, plain GSM characters, two texts at most with a long car name, the link and the STOP line (most fit in one); the renderer tidies empty values like the database; what an Admin may not save; the words of each screen |
| Database `supabase/tests/71_text_alerts.sql` (86 assertions; renumbered from 67, then 69, as 67 to 70 are taken by the games fix, the exit intent, the listing cache and the heartbeat) | See the README row; 55 updated for the new rules (a verified phone, the new texts, a sign-in email instead of a moment with no text), 03 lists the two new log tables among those not audited |
| End to end `web/tests/e2e/text-alerts.spec.ts` (375 and 1440, Quo mocked: `QUO_PROVIDER=fake`) | The profile: Both by default with a verified phone, Text saved, the quiet hours and STOP; STOP texted to the line (a signed Quo delivery): one confirmation sent at once through the fake line, none for a second STOP, the card after a STOP; START: its confirmation, the log with both;  a booking request with Text: the choice on the account and the renter record, the request email skipped, the text queued with its link and the STOP line (held to 8 am in the quiet hours), sent by the phone job through the fake line; the phone sign-up with Text chosen; the Admin's card (default, Change, audit log), Settings > Text alerts and Site health; axe, overflow and the copy rules on every page |

Results (local, after the merge with `vehiclepages`): database suite 5969 passed, 0 failed (suite 69: 86); unit 409
passed; lint and typecheck (app and tests) clean; types regenerated from a database with every migration; `npm run
cf:build` passed (server bundle 20.8 MiB, budget 40 MiB); end to end `text-alerts`, `phone-signin`, `signup` and
`request` at 375 and 1440: 28 passed, and `phone` (the webhook): 4 passed. In `text-alerts`, the booking request's text
may already be sent by the other width's phone job when it is read (both widths run at once): the check accepts queued,
sending or sent. The guide content JSON (admin, renter) is re-exported; the portals print each published guide's PDF from it
(the Guide PDFs workflow, `scripts/guides-pdf.mjs` without `--committed`). The committed PDFs in `docs/guides/pdf` were
not rebuilt for these two lines.

## 8. Guides

| Guide | Chapter | Section |
| --- | --- | --- |
| Admin | `admin/text-alerts-email-text-or-both` (new) | Who gets what (every customer email has its own text; a driver's or co-signer's link to that person), a person's channel, STOP, START and quiet hours (the confirmation texts), the settings and the texts, texts a day |
| Admin | `admin/texts-and-calls-the-quo-phone-line` | "Booking texts" and "The settings" point to Text alerts |
| Renter | `renter/after-your-trip` | "Texts or email: how we reach you" (after Sign in with your phone number), with the tip on the request and the phone sign-up; STOP is confirmed with one text |
| Owner | `owner/notices-profile-and-leaving` | "Texts or email" |
| Investor | `investor/how-your-returns-work` | "Texts or email" (after Emails you get from us) |
| Assistants | `va/texts-and-calls` | "Email, text or both" |
| Field staff | `field/report-rentals-referrals-and-profile` | "Texts or email" |

Source `docs/guides/src/guides/*.py`; `docs/guides/content/*.json` regenerated with `export.py` (only these sections
changed), the HTML and PDFs rebuilt with `build.py`. The portals' stored guides pick them up through the guides workflow
after the deploy.

## 9. What still needs the owner

1. Nothing to switch on: text alerts are on by default. They reach people only once they verify a phone (profile, or
   phone sign-in), so no one is texted on the deploy day without having verified.
2. US renters: register the Quo number for A2P 10DLC, then turn on "Sign-in by phone: also US numbers" (it gates sign-in
   codes and every text).
3. Done: Quo sends no STOP confirmation, so the platform sends one (section 3).
4. The lawyer: section 6.
