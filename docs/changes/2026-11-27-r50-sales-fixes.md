# Sales fixes and tools (Release 50 hotfix 2: 5130 to 5138)

The owner's nine Sales requests of Nov 27, in one branch (`r50-hotfix2-sales`). Tests: `supabase/tests/99_r50s_sales.sql`
(every item) and `web/tests/e2e/r50s-sales.spec.ts` (items 1, 3 and 6).

## What it does

1. **Sample-car enquiries are requests** (5130). A request for a sample car (an example car, not a real one) was a lead
   only (0065), so nobody saw it in Requests and offers. `app.admin_requests` now adds each open sample-car enquiry
   (`app.sample_request_rows`): marked as a sample car, with up to three real cars free for the dates
   (`app.sample_real_cars`: published, not a sample, same class first, then body type, then year). **Send an offer**
   opens the offer form with the first car and the dates; **Open the enquiry** opens the lead. An outcome on the lead
   takes it off the queue. Admin and staff read the same queue.
2. **Duplicate leads merge by themselves** (5131). `app.lead_merge_target`: open leads of one person and the same kind of
   customer, by email, phone (last ten digits) or name variants (the same words in any order, or the same first and last
   word) when their contacts do not disagree, within 30 days for a name match. Any source, any age for email and phone.
   On insert, on a change of name, email or phone, and every hour (`app.job_lead_merge`, pg_cron); the migration merges
   the leads already there. The merge is 3230's (`app.lead_merge`): history under the kept lead and in the audit log.
   Sample-car enquiries are not merged (each is a request).
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

New tables (RLS, `admin_all`, audit trigger): `booking_request_notes`, `lead_gen_credits`, `shift_claims`, `call_flags`,
`call_flag_words`. No applied migration is edited.

## Guides

- `renter/find-a-car-and-send-a-request`: Who referred you, and notes on your request.
- `va/sales`: requests on sample cars, referrals, lead generators and recruits.
- `va/commissions`: extensions and weekly payments.
- `admin/requests-offers-and-bookings`: sample-car requests and renter notes.
- `admin/leads-and-sales-claims`: duplicates, lead generators, call flags, shift claims.
- `admin/hiring`: recruited by a salesperson.
- `field/my-hours-and-pay`: shift claims when you also do Sales.
