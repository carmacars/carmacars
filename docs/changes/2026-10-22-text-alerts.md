# Text alerts: email, text or both (migration 0096)

The owner asked: "people will have the option to verify and get alerts via text instead of email". Every renter, owner,
investor and staff member now chooses how CarmaCars reaches them: **Email**, **Text** or **Both**. Texts go from the
CarmaCars Quo number through the Quo integration of 0085, only to a phone verified with a code (0091). Builds on branch
`rel3` (0085 and 0091 included). Migration `0096_text_alerts.sql` (schema marker 0096); no applied migration was edited.

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
| Never a text | `no_text`: password reset, sign-in link, security notice, chat transcript, a driver's or co-signer's link (sent to someone else), "Continue your request" |
| Marketing | The review request is texted only when its email may go (consent), and for a phone-only account only with marketing consent |
| Opt-outs | A number that replied STOP (or a renter marked no texts): email only |
| US numbers | A US number waits for A2P 10DLC: `signin_phone_us_allowed` (0091, off) also gates every text from the outbox, the missed-call text and staff replies included. Numbers outside Canada and the US: email only |
| A text that does not go after all | STOP while it waited, Quo refusing it, the person choosing email meanwhile (the job checks again before sending): the email it replaced is queued ("By email: the text was not sent (...)") |
| Switched off | `sms_alerts_enabled` off (or the phone line off): email only for everyone |

The texts: `sms_templates` (one row per code, editable in Admin > Settings > Text alerts: the text, on or off, urgent),
or the generic text `CarmaCars: {{subject}}. Details: {{link}}` for any other customer notification. Placeholders are the
email's `{{variables}}`; the booking's own values fill what the email did not carry; `{{link}}` is the page of the email
(the portal page for documents). A template names CarmaCars, keeps `{{link}}`, has no long dash and is at most 320
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
| Also | signed agreement and final statement (documents), cancellation, staff message, breakdown, accident, car disabled (urgent) | 47 templates in all; every other customer notification uses the generic text |

0085's booking texts are replaced: its trigger `notification_outbox_phone_sms` is dropped and its six moments
(`program_settings.phone_sms_*`) are no longer read (a moment an Admin had switched off is switched off on its template;
`phone_sms_booking` off turns `sms_alerts_enabled` off). They used any mobile number on the renter record; texts now need
a verified phone, as the owner asked ("verify and get alerts via text").

## 3. Opt-outs

- STOP, STOPALL, UNSUBSCRIBE, CANCEL, END, QUIT, ARRET (0085) and now also OPT OUT, OPTOUT, REVOKE, STOP ALL, PLEASE STOP
  through the Quo webhook (`server_phone_event`, and the trigger `phone_activity_keywords`) set `phone_threads.opted_out_at`,
  the opt-out list. Texts waiting to the number are skipped and their emails go instead. START, UNSTOP, YES (0085) and
  OPT IN, RESUME turn texts back on.
- Every STOP and START is logged in `sms_opt_out_log` (shown on the person's Admin card).
- "Reply STOP to opt out." ends the first automated text to a number, and the first after a START (`sms_stop_line`).
- Quo and the carriers also block on their side. No confirmation text is sent by the platform (see section 9).

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
| Database `supabase/tests/66_text_alerts.sql` (74 assertions) | See the README row; 55 updated for the new rules (a verified phone, the new texts, a sign-in email instead of a moment with no text), 03 lists the two new log tables among those not audited |
| End to end `web/tests/e2e/text-alerts.spec.ts` (375 and 1440, Quo mocked: `QUO_PROVIDER=fake`) | The profile: Both by default with a verified phone, Text saved, the quiet hours and STOP, the card after a STOP; a booking request with Text: the choice on the account and the renter record, the request email skipped, the text queued with its link and the STOP line (held to 8 am in the quiet hours), sent by the phone job through the fake line; the phone sign-up with Text chosen; the Admin's card (default, Change, audit log), Settings > Text alerts and Site health; axe, overflow and the copy rules on every page |

Results: see the CI run in section 10.

## 8. Guides

| Guide | Section |
| --- | --- |
| Admin | New chapter "Text alerts: email, text or both" (who gets what, a person's channel, STOP, START and quiet hours, the settings and the texts, texts a day); "Booking texts" and "The settings" of the Quo chapter point to it |
| Renter | "Texts or email: how we reach you" (after Sign in with your phone number), with the tip on the request and the phone sign-up |
| Owner | "Texts or email" (Notices, profile and leaving) |
| Investor | "Texts or email" (after Emails you get from us) |
| Assistants | "Email, text or both" (Texts and calls) |
| Field staff | "Texts or email" (Profile) |

Source `docs/guides/src/guides/*.py`; `docs/guides/content/*.json` regenerated with `export.py` (only these sections
changed), the HTML and PDFs rebuilt with `build.py`. The portals' stored guides pick them up through the guides workflow
after the deploy.

## 9. What still needs the owner

1. Nothing to switch on: text alerts are on by default. They reach people only once they verify a phone (profile, or
   phone sign-in), so no one is texted on the deploy day without having verified.
2. US renters: register the Quo number for A2P 10DLC, then turn on "Sign-in by phone: also US numbers" (it gates sign-in
   codes and every text).
3. Check in Quo whether it answers STOP itself with a confirmation; if not, decide whether the platform should send one.
4. The lawyer: section 6.
