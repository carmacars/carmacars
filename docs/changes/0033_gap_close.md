# 0033: closing the gaps of 0031 and 0032

Migration `supabase/migrations/0033_gap_close.sql`, tests `supabase/tests/20_gap_close.sql` (102 assertions). Builds on 0001 to 0032. No earlier migration was edited.

Wrapped (renamed and called from a new function of the same name, with the same behaviour and the new branches): `app.door` (0032, now `app.door_0032`), `app.notification_payload` (0032, now `app.ntf_payload_0032`), `app.outbox_file_refs` (0032, now `app.outbox_file_refs_0032`). Replaced with the same behaviour for a person with one function: `app.va_has` and `app.user_va_has` (0019) and `app.my_roles` (0031), which now read the assistant's active function.

## 1. Emails

| Piece | Built |
| --- | --- |
| `renter_staff_message` (new, renter) | A customer service or Sales assistant (or an Admin, `admin_do send_message`) replies on a booking: `app.staff_send_message` keeps the message on the booking and emits the email with the message and a "Reply in your account" link to `/account/bookings/<n>#messages`. Replaces 0031's `send_message`, which only kept the reply (and wrote an in-app notice directly; the in-app notice now comes from the event, once) |
| `staff_renter_replied` (new, staff_va_cs, digest) | The renter writes from the booking page (`public.renter_send_message`, service role, after the server checks the booking is theirs): the message joins the thread, one open "Renter replied" task (`renter_message`, customer service, 15 opening minutes) per booking, and the notice: next digest, or at once while the car is out or the pickup is within 48 hours. A staff reply closes the task |
| The thread | `public.my_booking_messages(number)` (authenticated, `app.is_my_booking`): portal messages of the booking, never task notes or the T7 summary. The renter page shows it with a reply form |
| Owner statements on the 10th, investor statements on their date | `app.statement_mail_due` lists approved owner statements on or after their payout date (the 10th) and paid or reinvested investor returns on or after their Payment Date, not yet sent and at most 45 days old (a first run sends no backlog). The Worker's cron (hourly, `custom-worker.ts` -> `POST /api/jobs/statements`, `web/src/server/statement-mail.ts`) renders and stores each PDF first (`generatedFile`), then `app.statement_mail_release` refuses unless the PDF is stored, marks the statement sent and emits the email (the owner one with the same dedupe key as `app.issue_owner_statement`, so an Admin's earlier send is not repeated; the investor one through 0023's trigger on `statement_sent_at`). The Admin's "Issue to the owner" also renders and stores the PDF first |
| 7-day links | `owner_statement_ready` gains `statement_url` (a sender value, signed by `send-outbox` for 7 days: `app.outbox_file_refs` maps it to the owner statement); the template gains the PDF link. `investor_statement_ready` and `investor_return_paid` already carried theirs (0032) |
| Every catalogue code accounted for | Test 20 section 13 searches every database function for each code (the digest and field-list codes are built from a prefix). Every one of the 126 is emitted by a function or trigger except `account_password_reset` and `account_security_notice`, which the sign-in service sends itself. `account_sign_in_link` was documented as sender-only but is emitted by 0029's `app.send_link_email` (owner invitations and form resume links): its `emitted_by` is corrected. **No code is dead.** |
| Email links | 36 paths of `emails/src/links.mjs` had no page (for example `/va/cs/bookings/<n>`, `/account/bookings/<n>/pickup`, `/owner/billing`). `web/next.config.ts` redirects each to the page that holds it |

## 2. Assistants (05-va.md)

| Gap | Built |
| --- | --- |
| Function switcher | `staff_profiles.cover_functions` (an Admin sets them: `admin_do staff_cover`, "Covers" on `/admin/settings/staff`). The portal sends the chosen function with every door call (`_va`, from a cookie); `app.va_active_fn` accepts it only if it is one of the person's, and every function check (`app.va_has`, `app.user_va_has`, `app.va_fn`) reads it. The rail shows "Working as" with a button per function when there is more than one |
| Scorecard | `app.staff_scorecard`: the measures of the VA hiring package section 7 per function, each the share of its tasks done by their due time in the week (a task still open past its due time missed), the daily checks by 9:00 and 18:00, six weeks; "review" after two weeks under 90%. `/va/scorecard` (own, read-only), `/admin/staff/[id]/scorecard` |
| Finance: reconciliation | `/va/reconciliation` (0030's reconciliation read; record a payout, match an item) |
| Finance: Turo trips | `app.save_turo_trip` (the car by id, plate or VIN; the Revenue Share in force on the end date; the statement month; a reference is corrected while it is on no statement), `turo_trip_import` (good rows saved, bad rows listed). `/va/turo` with a CSV import |
| Fleet: daily checks | `app.daily_check_form` pre-answers the lines the system knows (Trackers reporting, today's jobs acknowledged, tomorrow's pickups ready, late returns and unpaid charges; signed reports and T7, tomorrow's cars cleaned, payouts matched); `app.save_daily_check` needs OK or Problem (with a note) on every line, closes the opening or closing task, and escalates any Problem to an Admin (`daily_check_problem`). `/va/checks` |
| Photo review side by side, re-shoot | `app.photo_review`: both sets by shot, the missing shots, re-shoots asked for; `/va/review/[n]` (five-minute signed links, tap to enlarge), `/va/reviews`. "Ask for a re-shoot" (`app.request_reshoot`): a field job for the chosen shots, given by default to whoever took the set (`field_jobs.reshoot_report_id`, `reshoot_shots`); the field staff member takes them on the job page and the photos replace the shots on the report |
| Late-return panel | `app.late_panel` and `app.late_action`: the clock, the four steps of procedure 8, calls logged, T13 and T14 (the same events as the late-returns job, so never twice; T14 from 2 hours late), request disable (the notice time is the T14's; an Admin approves), open an incident. On `/va/bookings/[n]` for Fleet and customer service |
| Find a renter | 0012's `staff_find_renter` and `staff_open_renter` through the door; `/va/renters` (in-window records open at once, others with a logged reason for 24 hours) |
| Sales quotes | `app.staff_quote_request`: the request as the web form makes it (renter and driver, the request with its source and who took it, drivers, fee terms, places, the price), without recording consent for the lead. `/va/quotes/new` (blueprint path `/va/sales/quotes/new` redirects) then the review screen |
| Live refresh | Polling every 30 seconds (0031), as allowed |

## 3. Field staff (06-field.md)

| Gap | Built |
| --- | --- |
| Checklists for detail, photo shoot, tracker install and removal, registry run, recovery, other | `app.field_checklist(kind)` (steps), `field_jobs.checklist` (answers, saved as each is given), `app.field_job_checklist` (what is missing), `app.field_complete_job`: refuses until every required step is done; detail (grade, belongings, fuel, the four ready photos on the ready report), tracker install (the device on the car, tested, the onboarding step), tracker removal (device off, odometer, exit record), registry run (the new permit filed on the car, a Fleet task to record it), recovery (the rules, arrival photos, an urgent Fleet task); any Problem becomes a `field_job_problem` task. Photo shoot: the listing capture of 0032 on the job page (field staff of the car's job may start it), done when submitted |
| Incident report | `/field/report`, `app.field_report`: a car of their jobs; new damage (photo required) and a collision open an incident (0020's tasks, an Admin at once for a collision; the staff member recorded on a collision), a warning light an urgent Fleet task, a toll Finance, lost property customer service |
| Referrals | `/field/referrals`: the code (made once), the link `/r/<code>` (kept 30 days in a cookie and sent with a request to book as `referred_by_code`), a QR code, the kickbacks |
| Profile | `/field/profile`: details, phone, password, two-step sign-in, sign out |
| Add to home screen | `/field/manifest.webmanifest`, icons in `web/public/field` (`node scripts/gen-field-icons.mjs`); no service worker |

## 4. Investors

Statement PDFs exist (0032). Added: "All [year] statements (ZIP)" and the year's summary table as CSV (`/investor/statements/year/[year]`, own rows only; the ZIP holds each month's stored PDF, the yearly summary for a past year and the CSV; `web/src/lib/zip.ts`, no dependency). Two-step sign-in: offered on the profile, which now says whether it is on; still not required for investors.

## 5. The live verification's accounts

`app.verify_accounts` (`public.server_verify_accounts`, service role): for addresses `verify-<name>@carmacars.ca` only, one account per portal (renter, owner, investor, customer service, field; never an Admin, and an Admin role found on one is removed), each on the email suppression list. `web/scripts/verify-live.mjs --auth` creates or resets them through the Supabase admin API, removes any authenticator left from an earlier run, signs each in through the live form (enrolling one if staff two-step sign-in is on), checks the home loads without errors and that each is refused the other portals; the verify workflow fails when one does not.

## 6. Existing test assertions changed

- `07_notifications.sql`: the catalogue count (124 to 126 emails) and the link paths (59 to 60); "only the sign-in service emails are emitted by nobody" now lists two (the sign-in link email is emitted by 0029); the completeness block emits the two message emails and one sign-in link email so "every wired email code has been built" still holds.
- `08_booking_app.sql`: the read-only functions a signed-in session may call gain `my_booking_messages`.

## 7. Decisions

1. One door again: the new screens and actions are names on the existing calls, routed before 0032's door, so the second-factor rule and the acting user are set once as before.
2. The function switcher keeps one `staff_profiles` row: the main function stays the default everywhere (digests, the queue a task lands in); covering is a per-call choice the database validates.
3. A statement email is sent only once its PDF is stored, by the server that renders PDFs; the database refuses the release otherwise.
4. Re-shot photos replace the shots on the original report rather than creating a new report, so the review compares the same report; the job records which report and shots it was for.
5. A field report never prices anything and never touches money; it raises the incident or task the procedures name.
6. A staff quote records no consent for the lead: the renter accepts the terms when signing the agreement.

## 8. Not done

- Realtime subscriptions: the queue is read again every 30 seconds (as allowed).
- Tracker test commands (locate, lock, unlock, alarm, shut-off) are confirmed by the installer's tick; the Tracker provider's command API is not integrated.
- The scorecard's Fleet "Roadside dispatched" and Sales "Quotes matching the rate sheet" are approximated by their tasks (late returns, breakdowns and incidents; requests and offers): there is no separate record of a dispatch time or a rate-sheet check.
