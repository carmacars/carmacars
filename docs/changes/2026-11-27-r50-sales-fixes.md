# Sales fixes and tools (Release 50 hotfix 2: 5130 to 5139)

The owner's nine Sales requests of Nov 27, in one branch (`r50-hotfix2-sales`). Tests: `supabase/tests/99_r50s_sales.sql`
(every item) and `web/tests/e2e/r50s-sales.spec.ts` (items 1, 3 and 6).

## What it does

1. **Sample-car enquiries are requests** (5130). A request for a sample car (an example car, not a real one) was a lead
   only (0065), so nobody saw it in Requests and offers. `app.admin_requests` now adds each open sample-car enquiry
   (`app.sample_request_rows`): marked as a sample car, with up to three real cars free for the dates
   (`app.sample_real_cars`: published, not a sample, same class first, then body type, then year). **Send an offer**
   opens the offer form with the first car and the dates; **Open the enquiry** opens the lead. An outcome on the lead
   takes it off the queue. Admin and staff read the same queue.
2. **Duplicate leads merge by themselves, keeping live work** (5131). `app.lead_merge_target`: open leads of one person and
   the same kind of customer. The same email or phone (last ten digits) counts when the names fit (the same last name,
   the same first initial, or one has no name). Name variants (the same words in any order, or the same first and last
   word) count only within 30 days, with no disagreeing contact, and the same city or car asked about; a name alone stays
   a suggestion. `app.lead_merge_auto` keeps the lead with live work (a live claim or hold, a logged contact, an assigned
   salesperson, a stage past New, a lead generator, a first contact) and folds the other into it; when both have live work
   they stay apart and the lead page offers the merge. A new enquiry into a handled lead merges and reopens it as New, with
   the same salesperson, who is told (`lead_reopened`). `app.lead_merge` (replaced) carries the lead generator, first
   contact, stage, assignee and sourced-by, and moves a live claim or hold instead of deleting it. On insert, on a change
   of name, email or phone, and every hour (`app.job_lead_merge`, pg_cron); the migration itself merges nothing. Sample-car
   enquiries are not merged. Lookups go by index (email, phone key, two name keys), so a bulk import stays fast.
3. **Renter notes and Who referred you** (5132). `booking_request_notes`: the renter adds notes to their open request
   (`public.renter_request_note`, account page card "Notes to our team"); staff are told (`request_note`) and see them on
   the request row and the booking ("Notes added"). The request form's **Who referred you?** searches the team and the
   referral partners (`public.server_referrer_search`, 3 letters, first name and last initial); the choice travels as
   `referred_by`: a salesperson is credited with the sale (`sales_source` referral, sourced) when nobody is yet, field
   staff and partners get their referral code. The booking history says who was named; they are told (`referral_named`).
4. **Every salesperson in the lists** (5133). Root cause: `app.sales_staff_options` gave each person one function word
   (va_function, else 'field'), and the extension's "Give to" list keeps only 'sales'. Jamal is field staff who added
   Sales (0931: staff_type field, functions {field, sales}), so he was listed as Field and missing from Give to. The word
   is now 'sales' for everyone with the Sales function (`app.user_va_has_sales`), with `sales` and `functions` on each
   option; the booking page filters on `sales`. Onboarding and the inactivity lock never removed anyone from the list.
5. **Commission on extensions** (5133). A new extension is handled by whoever started it (`requested_by`, else the
   session's user): a salesperson earns on it; the renter's own, the weekly job's or an Admin's goes to Admin (no
   commission). Extensions defaulted to the booking's salesperson who did not start them move to Admin unless that
   commission is approved or paid (the Tibirica case, CC-10131); each move is audited and the commission synced.
   `99_r48_money_rules` now starts its extension as the salesperson (the old default it tested is the rule this replaces).
   Every new extension records who started it (the caller, else the signed-in session). The backfill
   (`app.extension_credit_backfill`) leaves an extension with no recorded starter as it is.
6. **Lead generators** (5134). `staff_profiles.lead_generator` (Admin: Lead generators, beside Sales team). **Owners I found**:
   **Add an owner** makes an owner lead (`generated_by`, source lead_gen, no automatic follow-ups) for the closers, who
   call it through the site. Duplicates of an open lead or an owner are refused. Lead generators cannot claim leads.
   When the owner signs (pipeline Signed or Car onboarded, or an enrollment agreement signed by the lead's owner, email
   or phone), `lead_gen_credits` gets one credit of Program settings `lead_gen_flat_cents` ($100); Admin approves,
   marks paid with the reference, or voids with the reason. Alerts `lead_gen_closed`, `lead_gen_credit_due`.
7. **Recruit invite links** (5135). In-person salespeople make one link (**My recruits** > **Make my invite link**):
   `/careers/<in-person Sales role>/apply?by=<code>&src=referral`. `public.server_hiring_apply` sets
   `job_applications.recruited_by`; the candidate is screened and interviewed as usual. Alerts `recruit_applied`,
   `recruit_hired`; Admin sees **Recruited by** on the candidate.
8. **Shift claims need Admin approval** (5136). A salesperson's `shift_take` or `offer_claim` makes a pending
   `shift_claims` row (the shift's checks first); Admin approves (the shift is booked by 0880/0931's own functions) or
   denies with the reason on Team > Shift claims. Alerts both ways (`shift_claim_pending`, `shift_claim_decided`); My
   shifts lists the claims.
9. **Calls and texts** (5137). A salesperson's text with a phone number (written or spelled out) is refused before it is
   queued, with the reason, and kept as a flag. Call transcripts of salespeople are checked line by line (our side; the
   whole call when the transcript has no speakers) for a phone number and `call_flag_words` (swearing, off-platform
   payment, personal number, cash only, threats, discrimination; Admin edits the list). `call_flags` keep the line;
   Admin is alerted (`call_flagged`) and reviews them on Call flags (beside Sales team).

10. **Find a renter is masked for Sales** (5139, privacy). `app.phone_renter_search` (the phone inbox's Find a renter)
   gave Sales the renter's email in full, and the mobile in full when their active function was not Sales, against 0970.
   It now masks both for Sales (`app.user_sales_only` or `app.viewer_masks_phones`): the masked mobile is kept in
   `phone_masks` so the server's Call and Text find it, and the link goes by the renter's record id. Admins and customer
   service see full values.

New tables (RLS, `admin_all`, audit trigger): `booking_request_notes`, `lead_gen_credits`, `shift_claims`, `call_flags`,
`call_flag_words`. No applied migration is edited.

## Review fixes (Nov 27)

- 5130: sample-car rows show only to a viewer who may open the lead (`app.sl_sees`) and follow the queue's state and
  search filters.
- 5132: a renter who names themself credits nobody; a renter-named credit pays only after an Admin approves it, like
  every commission (0058). The referrer search treats % and _ as text and lists names in order. Request notes are read
  by Admins, Sales and customer service only.
- 5134: a lead generator's credit follows the lead their lead was merged into (one credit an owner); an Admin cannot
  decide a credit on their own lead.
- 5137: dates, times, prices and booking numbers are not phone numbers (`app.phone_text_clean`); every other path that
  queues a salesperson's text (`phone_outbox`) refuses one with a phone number.
- 5139: for a masked viewer, a number matches by its last 4 digits or in full, an email only in full.
- Second review: a run of 10 digits or more is never cleaned away ("647.575.3377", "tel-6475753377", "$6475753377" are
  numbers); a reopened lead keeps Contacted or Qualified; a manual merge of two leads claimed by different people is
  refused (both claims kept) and a folded lead's claim moves with its holder; credits move with the merge and partial
  unique indexes hold one live credit an owner (a voided credit blocks nothing). 5131, 5133 and 5137 are re-run safe.

## Guides

- `renter/find-a-car-and-send-a-request`: Who referred you, and notes on your request.
- `va/sales`: requests on sample cars, referrals, lead generators and recruits.
- `va/commissions`: extensions and weekly payments.
- `admin/requests-offers-and-bookings`: sample-car requests and renter notes.
- `admin/leads-and-sales-claims`: duplicates, lead generators, call flags, shift claims.
- `admin/hiring`: recruited by a salesperson.
- `field/my-hours-and-pay`: shift claims when you also do Sales.
