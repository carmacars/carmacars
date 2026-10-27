# Quo contacts that match the site, and names for live visitors (0182)

The owner: "The contacts on Quo should be saved to match the contacts saved on the website." And: "We should be able to
name the live visitors if we learn their name."

## Quo contacts
- Everyone the site knows with a phone number is a contact in the CarmaCars Quo workspace under the same name, with their
  email and company when known: staff, renters, drivers, owners, partners, investors, referral partners, job applicants,
  named visitors (below), leads (including callers made leads in Texts and calls), chauffeur clients, live chats, discount
  game claims, forms left unfinished and other accounts (`app.quo_people_v`).
- One contact per number (`quo_contacts`, keyed by the E.164 number). When records share a number the strongest names
  the contact (staff, renter, driver, owner, partner, investor, referral partner, applicant, named visitor, lead,
  chauffeur, chat, game, form, account), the newest within a kind. The email falls back to any record of the number; the
  role says what they are to us ("Renter", "Owner", "CarmaCars staff"...). A number with no name and the CarmaCars number
  itself are never sent.
- Trigger: inserts and changes of the name, phone or email (and a staff role given or taken) on those tables only mark
  the number (`app.quo_contact_touch`, `app.quo_contact_mark`): no call to Quo happens in a booking's transaction.
- Queue: the Worker's five-minute phone job (`/api/jobs/phone`) runs the sync after the booking texts
  (`web/src/features/phone/quo-contacts.ts`, `web/src/server/phone.ts`). `public.server_jobs_due` says "phone" while a
  number waits, so an idle tick still loads nothing. `server_quo_contacts_due` gives out up to 40 numbers, leased for 10
  minutes; `server_quo_contact_done` records each result (a change made meanwhile is sent next time). Errors back off
  from 5 minutes, doubling, to a day; a 400 waits for the next change. Quo's "slow down" (429) ends the run early;
  a refused key (401, 403) pauses the sync for 6 hours with the error shown.
- Duplicates: before the first create the job reads Quo's own contact list once (10 pages of 50 a run;
  `server_quo_contacts_found`), and a contact Quo already has for one of our numbers becomes ours (updated, its other
  numbers and emails kept). New contacts carry `externalId` "cc-<digits>" and `source` "carmacars", looked up before
  creating, so a create whose answer was lost never makes a second contact; a 409 is resolved the same way. A contact
  deleted in Quo is made again. The Quo id is kept, so later changes patch that contact (read first, our number and
  email added to theirs).
- Polite: calls at least 150 ms apart (Quo allows 10 a second per key), a 45-second budget a run.
- Keys: no new secret. It uses `QUO_PROVIDER` and `QUO_API_KEY` of 0085 (base `QUO_API_BASE`, default
  https://api.openphone.com, Quo's public API v1 `/v1/contacts`). With `QUO_PROVIDER=quo` and no key the run records
  "QUO_API_KEY is not set" and pauses for 6 hours; locally (`fake`) the contacts are kept in memory.
- Backfill: the migration marks every number of everyone already on the site; the job sends them in runs of 40.
- Settings > Quo contacts (new tile): in Quo, waiting, errors, no name, the last run, the last good run, a pause, the
  last error, Quo's own list read, the recent errors, and Sync everyone again (`quo_contacts_resync`: everyone sent again
  after Quo's list is read again; audited). Program setting `phone_quo_contacts` (on by default) in "Phone and texts
  (Quo)".
- The privacy policy (live `legal.privacy` block, where it still has our text): one sentence, our contact list in the
  business phone provider.

## Names for live visitors
- Live visitors: Name (Edit name once named) on each visitor opens a small form: name, and optionally phone, email and a
  note. Save the name; Remove the name. Admins, customer service and Sales (`live_name`, `app.assert_live_staff`).
- Kept per browser (`visitor_names`, by `visitor_id`, audited), so it shows on every later visit. `app.visitor_who` and
  `app.visitor_chat_name` put it first: Live visitors (the line, hot visitors, signals), the visit's pages, Visitor
  history and Live chat. `visitor_session_row` carries the label (who named them, phone, email, note); a named visitor
  counts as known. The visitor never sees it: the session's own name (used in the chat greeting) is untouched.
- Consistent: a named visitor who books or signs in takes the renter's name ("Booked"); a renter whose email or phone is
  on a label gives it their name; a chat from another browser with the label's email or phone gets the same name; a chat
  fills in the label's empty phone or email.
- A phone on the label makes a Quo contact (role "Website visitor"), and a call or text from it shows the name in
  Texts and calls (`app.phone_match`; linked to the visit only when a record of the site names the number, so the
  name staff gave never becomes the visit's own name, which the chat greeting uses).

## Tests
- `supabase/tests/99_quo_contacts.sql`: who a number is (kinds, staff first, the CarmaCars number, no name), the marks
  (name, phone moved, unrelated change), due and leases, Quo's list first, done (and a change during the call), errors
  and back-off, the pause, the setting off, the cron gate, status for Admins only, Sync everyone again; naming (who may,
  validation, shown in the row, the next visit, chat, another browser, booking, the phone in Quo and in Texts and calls,
  removal); privileges.
- `web/src/features/phone/quo-contacts.test.ts`: the API mapping with a mocked fetch (fields, kept numbers and emails,
  external id, pages, update, lost create, deleted contact, 401 and 429, spacing) and a sync run (list first, created
  and updated, no key, one refused, 429 and refused key stop, time budget).

## Guides
- `admin/live-visitors-and-live-chat`: Name a visitor.
- `admin/texts-and-calls-the-quo-phone-line`: Quo contacts.
- `admin/settings`: the Quo contacts tile.
- `va/live-visitors-and-live-chat`: Name a visitor.
- `va/texts-and-calls`: Quo's contacts follow the site.
