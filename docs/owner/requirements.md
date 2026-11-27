# Owner requirements (CarmaCars): standing rules

Every item below is a standing rule from the owner. It stays in force until the owner removes or changes it. Each item has an ID (REQ-###), a status (done, in progress, not started), the owner's own words (short quote), the date first asked, the rule, a Proof line (what implements it) and a "Done when" line (how to prove it works).

How to use this file:
- Read it before any work in this repo (CLAUDE.md).
- Add any new owner instruction here BEFORE work on it starts. Update status and proof in the same commit as the work.
- Every helper brief quotes the relevant items verbatim (REQ id, quote, Done when). Commit messages name the REQ ids.
- Status "done" needs a Proof (change doc, migration or file) and a Test (supabase/tests file or node check). A done item with "Test: GAP" is a known gap: add the test.
- An item is not finished until its Done when line is true in the running site, checked on every relevant page and portal, not a sample. Every Admin upgrade also goes to each relevant staff role's portal.
- Every feature ships with its emails and notifications for every portal type it touches, smooth buttons, no squished text, and the existing design kit look (docs/style-guide.md).
- Only real, cited data on public pages. Never invent a value.

`scripts/check-requirements.mjs` (run by scripts/check-text.sh) fails if this file is missing, an item lacks ID, Status or Done when, or a done item lacks Proof or Test. `node scripts/check-requirements.mjs --export` rewrites docs/owner/requirements.json, which the weekly Admin call deck reads for its "Requirements not done" section (status not done).

Status as of 2026-11-27: "in progress" means built or being built on the named hotfix 2 branch, not yet on main. The ledger of this first pass is hotfix-notes/owner-requests-ledger.md; the first extraction of the owner chat (up to Nov 12) is merged as section 16; the complete pass follows from the owner data export.

## 1. Photos

### REQ-001 Full angle set, identical backgrounds, real photos after
- Status: in progress
- Proof: branch r50-hotfix2-photos (not on main)
- Test: to be added with the work
- Asked: Nov 25 (repeated Nov 25 20:13, Nov 27)
- Owner: "generate each vehicle in every single angle ... same angles as the sample photos, same order ... real photos after, still cut out on the same background"
- Rule: every car gets all the sample photos' angles, in exactly the same angles and order as the samples. When a car has no photo for an angle, AI generates that exact car (same rims, same paint, same everything) in that angle. After the AI angles come the real photos, cut out onto the same AI background. Every background looks exactly the same.
- Done when: a real car shows the full sample angle set first, identical backgrounds, real photos after.

### REQ-002 Cutout only on heroes, home and cards
- Status: in progress
- Proof: branch r50-hotfix2-photos (not on main)
- Test: to be added with the work
- Asked: Nov 27
- Owner: "only the cutout is shown, never the full photo with its background"
- Rule: on home pages, heroes and anywhere sample cars are replaced by real cars, show only the cutout, never the full photo with its background.
- Done when: heroes, home and cards show cutout-only images for real cars.

### REQ-003 Side view first, no approval, drive-off hover
- Status: done
- Proof: docs/changes/2026-11-20-r48-motion-covers-filters.md; docs/changes/2026-11-25-r50-car-cards.md
- Test: supabase/tests/99_r48an_renders_identity.sql
- Asked: Nov 20
- Owner: "Side-view first photo (AI-generated if missing, goes live with NO approval), drive-off hover"
- Rule: the first photo is the side view; no approval step; cards have the drive-off hover.
- Done when: every published car card opens on the side view and the hover works.

### REQ-004 Cars with no render still show
- Status: in progress
- Proof: branch r50-hotfix (not on main)
- Test: to be added with the work
- Asked: Nov 25
- Rule: a car with no AI render must still appear in lists and on its page.
- Done when: a car with zero renders is visible on search, home and its own page.

### REQ-005 Find why Gemini fails
- Status: in progress
- Proof: branch r50-hotfix2-photos (not on main)
- Test: to be added with the work
- Asked: Nov 25 17:17
- Owner: "Find that actual problem"
- Rule: find and fix the cause of failing image generation that burns usage and money; add a pass-rate guard so failures stop early.
- Done when: the cause is named with evidence and a failed run no longer retries without limit.

### REQ-006 Make and model filters normalised
- Status: done
- Proof: docs/changes/2026-11-20-r48-motion-covers-filters.md
- Test: supabase/tests/99_model_family.sql; web/src/features/vin/model-family.test.ts
- Asked: Nov 20
- Rule: "CLA 250" and "CLA-Class" filter as one family (model_family); same for every make.
- Done when: each filter shows one entry per family.

## 2. Bookings, offers, calendar

### REQ-007 Send the offer works
- Status: in progress
- Proof: branch r50-hotfix2-infra (not on main)
- Test: to be added with the work
- Asked: Nov 25 21:52 (repeated three times)
- Owner: "Send the offer button isn't working ... says sent but nothing sent, stays on the page"
- Rule: sending an offer sends it, shows a clear confirmation and moves on.
- Done when: an offer sent from Admin reaches the renter (email and site) and the page moves on.

### REQ-008 Ended and returned bookings never block the calendar
- Status: in progress
- Proof: branch r50-hotfix2-infra (not on main)
- Test: to be added with the work
- Asked: Nov 25 22:02, Nov 27 01:11
- Owner: "ended is blocking the calendar ... returned bookings stay open"
- Rule: an ended or returned booking releases its dates and closes itself.
- Done when: no ended or returned booking competes for dates (CC-10597 and the Yusuf Abbas booking closed).

### REQ-009 Button flow
- Status: in progress
- Proof: branch r50-hotfix2-infra (not on main)
- Test: to be added with the work
- Asked: Nov 25 21:52
- Owner: "when I click a button it shows working then shows the button again ... bad flow and ugly"
- Rule: after a click show a clear confirmation and move on; never flip back to the same button. Site-wide, every page.
- Done when: every action button on every portal shows working, then done, then moves on.

### REQ-010 Report-a-bug pill on phones
- Status: in progress
- Proof: branch r50-hotfix2-infra (not on main)
- Test: to be added with the work
- Asked: Nov 25 22:02
- Owner: "Report a bug button occupies the entire width"
- Rule: the pill is small and never covers the sheet width on phones.
- Done when: checked at phone width on every portal.

### REQ-011 Renter booking page wording and picture
- Status: in progress
- Proof: branch r50-hotfix2-infra (not on main)
- Test: to be added with the work
- Asked: Nov 25 22:08
- Owner: "wtf is add it and why is there a broken picture"
- Rule: clear wording instead of "Next: Add it"; no broken picture.
- Done when: the booking page has plain wording and a working picture for every car.

### REQ-012 Instant booking
- Status: in progress
- Proof: branch r50-hotfix2-infra (not on main)
- Test: to be added with the work
- Asked: Nov 25 22:08, Nov 27 06:37
- Owner: "Filter by instant booking, not on sample or 01 Motors cars, shown for complete profiles regardless of tier"
- Rule: an instant booking filter; never on sample or 01 Motors cars; shown to renters with complete profiles whatever their tier.
- Done when: the filter works, and a complete-profile renter of any tier sees Book instantly.

### REQ-013 Renter notes and referrer on a request
- Status: in progress
- Proof: branch r50-hotfix2-sales (not on main)
- Test: to be added with the work
- Asked: Nov 27 01:11, 01:13
- Owner: "Renters should be able to add notes on each booking when making a request"
- Rule: renters can add a note on each request and enter "who referred you".
- Done when: both fields show on the request and in Admin and Sales views.

### REQ-014 Staff list on accept
- Status: in progress
- Proof: branch r50-hotfix2-sales (not on main)
- Test: to be added with the work
- Asked: Nov 27 01:11
- Rule: every eligible staff member (Jamal was missing) appears in the list when accepting a request.
- Done when: the list matches the active staff roster.

### REQ-015 Sample car data fix
- Status: not started
- Proof: none yet
- Test: to be added with the work
- Asked: Nov 27 07:07
- Owner: "Cybele A10 CC-10067 should not block the calendar and should not inform the owner"
- Done when: CC-10067 blocks nothing and sends no owner notice.

### REQ-016 Notify on every new request
- Status: in progress
- Proof: branch r50-hotfix2-errors (not on main)
- Test: to be added with the work
- Asked: Nov 26 17:38
- Owner: "Why am I not getting notified for requests, only when expiring"
- Rule: notify on every new request, not only when it is about to expire.
- Done when: a new request notifies the right roles at once.

### REQ-017 Sample car inquiries become requests
- Status: in progress
- Proof: branch r50-hotfix2-sales (not on main)
- Test: to be added with the work
- Asked: Nov 26 22:46
- Rule: an inquiry on a sample car (DOST) becomes a request.
- Done when: a sample car inquiry shows in Requests.

### REQ-018 Calendar terms and layout
- Status: done
- Proof: docs/changes/2026-11-20-r48-ops-screens.md
- Test: supabase/tests/99_r48ops_calendar.sql
- Asked: Nov 16 to 20
- Owner: "a return is a checkout, not a check-in"
- Rule: show the return time; return checkout and post-trip cleaning are two jobs; the long car list must not make the calendar unusable.
- Done when: the calendar is usable with the full fleet and uses these terms.

### REQ-019 Owners book their own car
- Status: done
- Proof: docs/changes/2026-11-20-r48-fees-evidence-hiring.md
- Test: supabase/tests/99_r48fe_fees_evidence_hiring.sql
- Asked: Nov 20
- Rule: owners can book their own car for themselves, family and friends, including a car still onboarding.
- Done when: an owner books a car with status onboarding.

### REQ-020 Return due alert on time
- Status: in progress
- Proof: branch r50-hotfix2-errors (not on main)
- Test: to be added with the work
- Asked: Nov 26 17:06
- Rule: the return due notice goes out at the return time, not two hours later.
- Done when: the notice time equals the return time.

### REQ-021 Check-in visit email wording
- Status: in progress
- Proof: branch r50-hotfix2-errors (not on main)
- Test: to be added with the work
- Asked: Nov 26 17:33
- Rule: the check-in visit email does not read like a pickup check-in.
- Done when: the email says what the visit is.

### REQ-022 Unfinished rentals section
- Status: in progress
- Proof: branch r50-hotfix2-insurance (not on main)
- Test: to be added with the work
- Asked: Nov 16 to 20
- Rule: the unfinished rentals section sits where it makes sense; an unfinished rental is never lost ("already saved or discarded").
- Done when: an unfinished rental can always be reopened.

## 3. Insurance replacement rentals and invoices

### REQ-023 Insurance replacement page
- Status: in progress
- Proof: branch r50-hotfix2-insurance (not on main)
- Test: to be added with the work
- Asked: Nov 26 22:57 (re-asked Nov 27 07:14)
- Owner: "I don't see you mentioning the insurance portal"
- Rule: a staff page, not a portal: invoices, edit every field, send estimate or invoice, bypass calendar and owner notices, visible to Finance not Field, in the design kit.
- Done when: Finance creates, edits and sends an insurer rental end to end; Field cannot see it.

### REQ-024 Re-send invoices as often as needed
- Status: in progress
- Proof: branch r50-hotfix2-insurance (not on main)
- Test: to be added with the work
- Asked: Nov 27 00:33
- Owner: "nothing left to invoice"
- Rule: updated invoices can be re-sent to the insurer or adjuster any number of times, including end of rental and extensions.
- Done when: a re-send works after every change.

### REQ-025 Manual car entry, optional phone and email
- Status: in progress
- Proof: branch r50-hotfix2-insurance (not on main)
- Test: to be added with the work
- Asked: Nov 26 20:57, 21:15
- Owner: "I thought we agreed" (phone and email optional)
- Rule: a car not in the fleet can be typed in; phone and email are optional.
- Done when: a rental saves with a manual car and no phone or email.

### REQ-026 Winter tire fee editable
- Status: in progress
- Proof: branch r50-hotfix2-insurance (not on main)
- Test: to be added with the work
- Asked: Nov 25 18:35
- Done when: the fee can be edited on an insurer-billed rental.

### REQ-027 Paste a block of text
- Status: in progress
- Proof: branch r50-hotfix2-insurance (not on main)
- Test: to be added with the work
- Asked: Nov 25 20:42
- Rule: pasting a block of text creates a rental with fields sorted.
- Done when: a pasted claim text fills the rental fields.

### REQ-028 Partner API key
- Status: in progress
- Proof: branch r50-hotfix2-insurance (not on main)
- Test: to be added with the work
- Asked: Nov 27 00:17
- Rule: Mahad's API key creates insurer rentals end to end.
- Done when: a rental created by that key appears with its invoice.

### REQ-029 Direct deposit on invoices
- Status: in progress
- Proof: branch r50-hotfix2-infra (not on main)
- Test: to be added with the work
- Asked: Nov 25 18:35
- Rule: invoices show direct deposit (account 1046242, transit 00085, institution 003) next to e-Transfer.
- Done when: the issued invoice shows both.

### REQ-030 Late fee on unpaid owner insurance
- Status: done
- Proof: docs/changes/2026-11-20-r48-money-rules.md (migration 3271, setting owner_insurance_late_fee_bps = 500)
- Test: supabase/tests/24_owner_debit.sql; supabase/tests/99_r48rw_owner_money.sql
- Asked: Nov 20
- Rule: 5% late fee (with HST) on unpaid owner insurance, added once to the returned invoice.
- Done when: an overdue owner invoice carries the fee.

## 4. Payments, money

### REQ-031 Cards off while there is no processor
- Status: in progress
- Proof: branch r50-hotfix2-infra (not on main)
- Test: to be added with the work
- Asked: Nov 25 22:38 (repeated Nov 26 18:18, Nov 27 07:07)
- Owner: "people still try to pay via credit card"
- Rule: while there is no card processor, checkout and pay links offer e-Transfer and cash only; the Admin setting is off.
- Done when: checkout and links show no card option.

### REQ-032 Commission only on what the salesperson initiated
- Status: in progress
- Proof: branch r50-hotfix2-sales (not on main)
- Test: to be added with the work
- Asked: Nov 25 22:13
- Rule: no commission on an extension or next payment the salesperson did not start (Tibirica case); commission follows whoever did the extension.
- Done when: the Tibirica case pays no commission.

### REQ-033 Owner payouts at each owner's split
- Status: in progress
- Proof: branch r50-hotfix2-ops (not on main)
- Test: to be added with the work
- Asked: Nov 16 to 20
- Owner: "Owner payouts must use each owner's agreed split"
- Rule: audit every owner statement; shareholder cars keep 90% of the total collected; deposits held 30 days.
- Done when: every statement matches the stored terms.

### REQ-034 Extensions, debit deposits, speeding, gift cards
- Status: done
- Proof: docs/changes/2026-11-20-r48-money-rules.md; docs/changes/2026-11-23-r49-gift-cards.md
- Test: supabase/tests/99_r48_money_rules.sql; supabase/tests/99_r49_gift_cards.sql
- Asked: Nov 16 to 20
- Rule: extension money view; salespeople can turn on debit deposits; speeding charges at 180, 220 and 300 km/h (highest tier only); gift cards, vouchers, gifted rentals.
- Done when: each exists and is covered by a test.

### REQ-035 Evidence for every fee
- Status: done
- Proof: docs/changes/2026-11-20-r48-fees-evidence-hiring.md
- Test: supabase/tests/99_r48fe_fees_evidence_hiring.sql
- Asked: Nov 20
- Owner: "EVERY fee instance needs evidence attached"
- Rule: gather evidence automatically; ask staff when it cannot be; a fee with missing evidence is blocked. Dispute kit covers every fee type.
- Done when: no fee can be charged without evidence or an Admin override reason.

### REQ-036 Non-return, improper return, theft, tires and roadside fees
- Status: done
- Proof: docs/changes/2026-11-20-r48-fees-evidence-hiring.md
- Test: supabase/tests/99_r48fe_fees_evidence_hiring.sql
- Asked: Nov 20
- Rule: $1,000, $250, $1,500 plus actual costs; tire and roadside at actual cost plus $50 admin; "Roadside assistance included" wording stays.
- Done when: fee types and agreement clauses exist.

### REQ-037 Stripe dispute pack
- Status: not started
- Proof: none yet
- Test: to be added with the work
- Asked: Nov 25 17:37
- Rule: pack for CC-10468 with renter ID, selfie and partner ID; deadline Dec 7.
- Done when: the pack is complete and submitted by the owner.

### REQ-038 Record e-Transfers
- Status: not started
- Proof: none yet
- Test: to be added with the work
- Asked: Nov 25 23:13
- Rule: e-Transfers paid are recorded on their bookings from Quo and bank emails.
- Done when: no paid e-Transfer is unrecorded.

### REQ-039 Finance dashboard
- Status: done
- Proof: docs/changes/2026-11-23-r49-finance.md
- Test: supabase/tests/99_r49fin_finance.sql
- Asked: Nov 20
- Done when: the finance dashboard shows bank balances and payouts.

## 5. Tolls and expenses

### REQ-040 Tolls and tickets reader
- Status: in progress
- Proof: branch r50-hotfix2-ops (not on main)
- Test: to be added with the work
- Asked: Nov 25 20:42 (repeated)
- Owner: "never fixed the tolls and tickets reader ... super broken, especially 407, urgent"
- Done when: a 407 statement is read and matched to bookings.

### REQ-041 Expenses
- Status: in progress
- Proof: branch r50-hotfix2-ops (not on main)
- Test: to be added with the work
- Asked: Nov 25 23:39
- Rule: several receipt pictures per expense; auto read amount, category and car; posts to the owner statement.
- Done when: a receipt photo creates a posted expense.

## 6. Comms

### REQ-042 Email, Quo, Twilio, SES all working
- Status: in progress
- Proof: branch r50-hotfix2-comms (not on main): docs/changes/2026-11-27-r50-hotfix2-comms.md; 5092 (SES reports read as JSON strings, so SES sends whichever send-outbox build runs), 5090 (Quo texts), 5091 and 5092 (browser calls)
- Test: supabase/tests/99_r50h2_ses_contacts.sql; supabase/tests/99_r50h2_texts_recover.sql; web/src/features/phone/voice.test.ts; web/tests/e2e/r50h2-call-screen.spec.ts
- Asked: Nov 25 17:23
- Owner: "Amazon SES, Quo messages, Twilio calls ... all need to be working"
- Rule: emails go through Amazon SES first, texts through Quo, calls through Twilio in the browser; each one works on its own after a deploy, without a manual step.
- Done when: a test of each channel succeeds.

### REQ-043 No false email usage warnings
- Status: in progress
- Proof: branch r50-hotfix2-comms (not on main): 5091 (the day's limit counts SES, Cloudflare and Resend; the month test counts Resend only; the portal warning stays quiet while SES sends)
- Test: supabase/tests/99_r50h2_email_meter_auto_replies.sql
- Asked: Nov 25 20:13
- Owner: "still getting emails that we're almost out of email usage ... even though we switched to SES"
- Rule: the email usage warning and the email cap track the capacity of every provider that sends (SES included), not Resend's free 100 a day.
- Done when: warnings track SES, not the old cap.

### REQ-044 Auto replies on
- Status: in progress
- Proof: branch r50-hotfix2-comms (not on main): 5091 (the auto-reply gate asks app.ai_allow('faq_reply'), so the server's own model answers once Workers AI's share of the day is used; faq_reply is private: never Gemini's free tier, the owner can change this). WhatsApp auto replies also need the WhatsApp Business phone number id (owner).
- Test: supabase/tests/99_r50h2_email_meter_auto_replies.sql; web/src/integrations/ai/chain.test.ts
- Asked: Nov 26 16:49
- Rule: auto replies work for texts and socials; find why they stopped. A renter's message goes only to our own AI models by default (no owner quote on this default: it is the review's privacy choice, for the owner to confirm).
- Done when: a test text and a social message get a reply.

### REQ-045 No stale text burst
- Status: in progress
- Proof: branch r50-hotfix2-comms (not on main): 5090 (any text Quo takes after the newest failure clears "Sign-in codes by text"; a sign-in code refused for credits pauses texts and one that goes ends the pause; while paused, a due text waits up to text_retry_paused_minutes (30) for the probe, then goes by email). Owner decision open: this holds and retries a waiting text instead of dropping it; texts past their drop rules (app.text_drop_reason) are still dropped.
- Test: supabase/tests/99_r50h2_texts_recover.sql
- Asked: Nov 20
- Rule: when Quo credits return, texts recover by themselves (no manual reset) and stale queued texts are dropped; email is the fallback while credits are out; phone alerts never turn themselves off.
- Done when: each is covered by a test.

### REQ-046 In-site calling
- Status: in progress
- Proof: branch r50-hotfix2-comms (not on main): web/src/features/phone/voice.ts and VoiceDock.tsx (call screen: name, number, timer, Mute, Keypad, Speaker and microphone choice, Hold, End always on, End stops a call still starting, one call per tap, switching apps keeps a connected call); 5092 (contacts: only phone staff, Sales see their own leads masked, names included)
- Test: web/src/features/phone/voice.test.ts; web/tests/e2e/r50h2-call-screen.spec.ts; supabase/tests/99_r50h2_ses_contacts.sql
- Asked: Nov 25 23:06, Nov 26 17:56, Nov 27 07:14 (repeated)
- Owner: "Website calling ugly ... mute, speaker, mic choice, native look"
- Rule: salespeople calls work; hang up works; native-call look; keypad to type any number.
- Done when: a sales call connects, mutes, switches mic and hangs up.

### REQ-047 Restrict numbers and risky words
- Status: in progress
- Proof: branch r50-hotfix2-comms (not on main)
- Test: to be added with the work
- Asked: Nov 26 18:07
- Rule: salespeople cannot text phone numbers on the main line; flag phone numbers, swearing and risky words said on calls.
- Done when: both flags raise an Admin item.

## 7. Alerts, To do's, self-heal

### REQ-048 Alerts and To do's do not pile up
- Status: in progress
- Proof: branch r50-hotfix2-errors (not on main)
- Test: to be added with the work
- Asked: Nov 16 to 20, Nov 26 06:31 (repeated)
- Owner: "permanent fix, I keep having to tell you"
- Rule: the site heals itself from a built-in database of fixes; resolved items close; no "jobs locked and left behind" noise; deduplicate.
- Done when: the open alert count falls to real items only and stays there.

### REQ-049 Less Admin homework
- Status: in progress
- Proof: branch r50-hotfix2-errors (not on main)
- Test: to be added with the work
- Asked: Nov 26 07:25
- Owner: "too much homework in the admin portal ... figure out on its own"
- Done when: what the system can resolve is resolved without a task.

### REQ-050 Guide changes need no owner review
- Status: in progress
- Proof: branch r50-hotfix2-errors (not on main)
- Test: to be added with the work
- Asked: Nov 26 02:46
- Rule: guides and academy match the app automatically; the owner does not approve guide changes. When a layout or flow changes, guides, academy, quizzes and videos stay accurate.
- Done when: the automatic check passes and no approval step remains.

### REQ-051 Customisable notifications
- Status: done
- Proof: docs/changes/2026-11-20-r48-rewards-calendar-notify.md
- Test: supabase/tests/99_r48rw_rewards_calendar_notify.sql
- Asked: Nov 20
- Rule: every user type can customise notifications; locked ones (security, legal, fees, receipts, booking changes, return reminders) cannot be turned off.
- Done when: each portal has a notifications page.

### REQ-052 Quiet admin email
- Status: done
- Proof: docs/changes/2026-11-25-r50-admin-email-quiet.md
- Test: supabase/tests/99_r50_admin_email_quiet.sql
- Asked: Nov 20
- Rule: admin emails come as a digest; crash To do's are grouped.
- Done when: no per-event email flood.

## 8. Field staff

### REQ-053 Pause field shifts
- Status: in progress
- Proof: branch r50-hotfix2-academy (not on main)
- Test: to be added with the work
- Asked: Nov 26 14:42, Nov 27 07:13
- Owner: "Pause the shifts for field staff"
- Done when: field shifts are off until the owner turns them on.

### REQ-054 Field staff see the day's work
- Status: in progress
- Proof: branch r50-hotfix2-ops (not on main)
- Test: to be added with the work
- Asked: Nov 26 18:13 ("I had told you"), Nov 27 07:12
- Rule: field staff on shift see every pickup and return that day; unassigned days go to the nearest shift; unfinished work carries into the next shift; they see work for days before the next shift.
- Done when: a field user on shift sees all that day's jobs.

### REQ-055 Photos for past bookings
- Status: in progress
- Proof: branch r50-hotfix2-oldphotos (not on main)
- Test: to be added with the work
- Asked: Nov 26 14:43, Nov 27 07:12
- Rule: upload check-in and out photos for previous bookings, in bulk; field staff can see those bookings.
- Done when: a past booking accepts bulk photos.

### REQ-056 Shift claims need approval
- Status: in progress
- Proof: branch r50-hotfix2-sales (not on main)
- Test: to be added with the work
- Asked: Nov 26 18:26
- Rule: shift claims for sales need Admin approval.
- Done when: a claim waits for Admin.

### REQ-057 Damage and smoking evidence
- Status: done
- Proof: docs/changes/2026-11-20-r48-fees-evidence-hiring.md
- Test: supabase/tests/99_r48fe_fees_evidence_hiring.sql
- Asked: Nov 20
- Rule: unclean return needs 3 or more guided photos and a description; the fee drafts for review.
- Done when: a return cannot complete without them.

## 9. Sales, leads, hiring

### REQ-058 Lead-generator portal
- Status: in progress
- Proof: branch r50-hotfix2-sales (not on main)
- Test: to be added with the work
- Asked: Nov 25 19:24
- Rule: a portal for Eric: enter owner leads, hand to closers, $100 flat per closed owner lead.
- Done when: a closed lead pays $100.

### REQ-059 Recruit invite links
- Status: in progress
- Proof: branch r50-hotfix2-sales (not on main)
- Test: to be added with the work
- Asked: Nov 26 01:02
- Rule: in-person salespeople refer recruits by invite link; interview required; tracked under the referrer.
- Done when: a recruit is tracked to the referrer.

### REQ-060 No leads in academy
- Status: in progress
- Proof: branch r50-hotfix2 (not on main)
- Test: to be added with the work
- Asked: Nov 25
- Rule: salespeople stuck in the academy get no leads.
- Done when: the lead list is empty for them.

### REQ-061 Duplicate leads merge
- Status: in progress
- Proof: branch r50-hotfix2-sales (not on main)
- Test: to be added with the work
- Asked: Nov 16 to 20, Nov 26 22:52
- Done when: the same person is one lead.

### REQ-062 Visitor numbers are real
- Status: in progress
- Proof: branch r50-hotfix2-errors (not on main)
- Test: to be added with the work
- Asked: Nov 25 20:58
- Owner: "Visitor numbers seem high af"
- Done when: bots are excluded and the count is explained.

### REQ-063 Applicants and referrals
- Status: in progress
- Proof: branch r50-hotfix2-sales (not on main)
- Test: to be added with the work
- Asked: Nov 20, Nov 26 06:23
- Rule: a referral to Sales is one click and pre-filled; applicants who skip the interview are chased; hiring answers pay questions from the known role pay.
- Done when: drop-off falls and referrals pre-fill.

### REQ-064 Rushaan off Sales
- Status: in progress
- Proof: branch r50-hotfix2-sales (not on main)
- Test: to be added with the work
- Asked: Nov 25 19:15
- Done when: the staff role is changed in Admin.

## 10. Staff portals and academy

### REQ-065 No VA label for in-person staff
- Status: in progress
- Proof: branch r50-hotfix2-labels (not on main)
- Test: to be added with the work
- Asked: Nov 27 02:34 (mentioned many times)
- Owner: "still says VA as a role for my in-person staff"
- Done when: no screen, email or guide labels in-person staff as VA.

### REQ-066 Demo portals
- Status: in progress
- Proof: branch r50-hotfix2-ux (not on main)
- Test: to be added with the work
- Asked: Nov 25 20:41
- Rule: staff can open a demo renter and a demo owner portal.
- Done when: both open from a staff portal.

### REQ-067 Academy
- Status: in progress
- Proof: branch r50-hotfix2-academy (not on main)
- Test: to be added with the work
- Asked: Nov 27 01:12, 05:02
- Rule: the first sections (more than 3) unlock work; the full academy is needed for payouts; shorter; lessons match questions; stuck or repeated errors force that section; Admin opens any lesson and quiz; wrong-answer wait 2 minutes with one fix.
- Done when: each rule is testable in the academy.

### REQ-068 Academy videos
- Status: not started
- Proof: none yet
- Test: to be added with the work
- Asked: Nov 27 01:19, 05:04
- Rule: check rendered videos have audio, then cheapest animated option.
- Done when: videos have audio.

### REQ-069 Staff agreement and rewards
- Status: done
- Proof: docs/changes/2026-11-20-r48-rewards-calendar-notify.md; docs/changes/2026-11-24-r50-sign-first.md
- Test: supabase/tests/99_r48rw_rewards_calendar_notify.sql; supabase/tests/99_r50ow_sign_first.sql
- Asked: Nov 20
- Rule: agreement before academy; staff rewards (15% off, free days per 100); VAs get no rental perks.
- Done when: each is built per the rules.

## 11. Townhall and weekly Admin call

### REQ-070 Townhall join and slide
- Status: in progress
- Proof: branch r50-hotfix2-academy (not on main)
- Test: to be added with the work
- Asked: Nov 25 18:35, 20:41
- Owner: "no way to join the town hall ... couldn't see the deck"
- Rule: Join opens the in-site call; the KPI slide shows real staff with KPIs only.
- Done when: both work.

### REQ-071 Weekly Admin call
- Status: in progress
- Proof: branch r50-hotfix2-ux (not on main)
- Test: to be added with the work
- Asked: Nov 26 18:26, 18:43, Nov 27 07:13
- Rule: Abbas and Mahad weekly call, auto deck with approve and deny buttons: shifts, hours and pay, academy, hiring, social, numbers, owners, deposits, insurance billing, claims, tolls, fleet.
- Done when: the deck builds each week with working buttons.

## 12. Owners and calculator

### REQ-072 Calculator realism
- Status: in progress
- Proof: branch r50-hotfix2-ops (not on main)
- Test: to be added with the work
- Asked: Nov 25 19:23
- Owner: "2015 RDX beats a 2025 CR-V"
- Rule: 80% occupancy about $1,200 a month, floor $800, higher for better cars; rough-estimate disclaimer.
- Done when: a 2015 RDX never beats a 2025 CR-V.

### REQ-073 Ownership documents
- Status: in progress
- Proof: branch r50-hotfix2-ops (not on main)
- Test: to be added with the work
- Asked: Nov 26 01:53
- Rule: every ownership document uploaded; VIN and plate read and attached to the car and owner portal.
- Done when: an upload fills VIN and plate.

### REQ-074 Owner and renter rewards
- Status: in progress
- Proof: branch r50-hotfix2-ux (not on main)
- Test: to be added with the work
- Asked: Nov 20
- Rule: rewards per docs/blueprint and areas already built; discount games with points for every user type.
- Done when: each user type has a rewards page.

### REQ-075 Tracker alerts
- Status: done
- Proof: docs/changes/2026-11-20-r48-tracker-alerts.md
- Test: supabase/tests/99_r48trk_tracker_events.sql
- Asked: Nov 20
- Rule: tracker alerts to owners and renters, pound database, location on interactions.
- Done when: alerts fire once trackers are installed.

## 13. SEO and growth

### REQ-076 Every offer on every page
- Status: in progress
- Proof: branch r50-hotfix2-seo (not on main)
- Test: to be added with the work
- Asked: Nov 16 to 20, Nov 26 06:37, repeated Nov 27
- Owner: "I don't think you built them"
- Rule: SEO pages carry every offer: rental, long-term, insurance replacement, chauffeur, GPS trackers and kill switch, owner program, body shop, detailing. They show in list bars and on every page, as designed modules not walls of text.
- Done when: each offer shows in the list bars and on every SEO page, verified on the live site.

### REQ-077 Area details
- Status: not started
- Proof: none yet
- Test: to be added with the work
- Asked: Nov 27
- Rule: area pages carry parking lots, transit, gas prices and local stats, only real cited data.
- Done when: each area page shows these with a source.

### REQ-078 Vehicle details
- Status: not started
- Proof: none yet
- Test: to be added with the work
- Asked: Nov 27
- Rule: vehicle pages carry full-tank price for that car, full-tank range, fuel efficiency, EV kWh and charge cost, tire and rim sizes and all specs, only real cited data.
- Done when: every field has a cited source or is left out.

### REQ-079 Search Console
- Status: in progress
- Proof: branch r50-hotfix2-seo (not on main)
- Test: to be added with the work
- Asked: Nov 26 06:37, Nov 27 04:01
- Owner: "Sure you implemented auto-correct of Search Console errors?"
- Rule: errors auto-fix with proof; full keyword research from Search Console.
- Done when: proof of an auto-fix and a keyword report exist.

### REQ-080 Tracker pages
- Status: in progress
- Proof: branch r50-hotfix2-seo (not on main)
- Test: to be added with the work
- Asked: Nov 20
- Rule: dedicated tracker product page and cluster; prices Owners free tracker with $150 install; monthly fee $25, $20, $15 by car count for everyone; waitlist wording, no in-stock claims.
- Done when: pages match these prices.

### REQ-081 White-label page
- Status: in progress
- Proof: branch r50-hotfix2-seo (not on main)
- Test: to be added with the work
- Asked: Nov 26 06:36
- Rule: descriptive but vague, no pricing, hidden from navigation.
- Done when: the page exists and is not in navigation.

### REQ-082 Lead source
- Status: done
- Proof: docs/changes/2026-11-20-r48-seo.md
- Test: supabase/tests/99_r48seo_leads_trackers.sql
- Asked: Nov 16 to 20
- Rule: lead page shows source, search terms and landing page.
- Done when: each lead shows all three.

## 14. Renter experience

### REQ-083 Countdown and progress
- Status: in progress
- Proof: branch r50-hotfix2-ux (not on main)
- Test: to be added with the work
- Asked: Nov 26 07:00
- Rule: renter countdown to pickup, add to calendar, celebratory progress; progress trackers for booking, owner application, staff closing, loyalty.
- Done when: each shows for its user.

### REQ-084 Widgets and native app
- Status: not started
- Proof: none yet
- Test: to be added with the work
- Asked: Nov 26 06:58, Nov 20
- Rule: iOS and Android home, lock screen, control centre widgets per role; a real native app.
- Done when: widgets and app ship to the stores.

### REQ-085 Investor view
- Status: not started
- Proof: none yet
- Test: to be added with the work
- Asked: Nov 26 15:42
- Rule: investor deck and portal show monthly active users and units.
- Done when: both numbers show.

### REQ-086 Design reels
- Status: not started
- Proof: none yet
- Test: to be added with the work
- Asked: Nov 26, Nov 20
- Rule: each Instagram reel the owner sent is watched in his browser and applied.
- Done when: each reel has written rules and shipped changes.

## 15. Infrastructure and quality

### REQ-087 api.carmacars.ca certificate and server switch
- Status: in progress
- Proof: branch r50-hotfix2-infra (not on main)
- Test: to be added with the work
- Asked: Nov 20, Nov 25 20:13
- Owner: "server switch still not done, insane"
- Done when: api.carmacars.ca has a valid certificate and /api/health returns 200 on the new server.

### REQ-088 Build and deploy off the OVH server
- Status: in progress
- Proof: branch r50-hotfix2-infra (not on main)
- Test: to be added with the work
- Asked: Nov 25 21:58
- Done when: tests and builds run on GitHub runners.

### REQ-089 Full test of every portal
- Status: not started
- Proof: none yet
- Test: to be added with the work
- Asked: Nov 27 00:26
- Owner: "Test every function of every portal with my Chrome. Extremely thorough"
- Done when: a written pass covers every function of every portal.

### REQ-090 Process
- Status: in progress
- Proof: branch r50-hotfix2-req (not on main)
- Test: to be added with the work
- Asked: Nov 20 to Nov 27
- Rule: GitHub is the source of truth for code and database; one combined CI run per release; full checks before every deploy; helpers do not run CI; queue new requests into the unreleased release; cheaper model for routine work; post an update in the Team WhatsApp group when a release goes live; push finished work without asking; watch for and fix machine limits.
- Done when: each release follows these.

### REQ-091 Review everything
- Status: in progress
- Proof: branch r50-hotfix2-req (not on main)
- Test: to be added with the work
- Asked: Nov 27 07:00
- Owner: "Review every single thing I've discussed"
- Rule: nothing the owner asked is dropped; the ledger and this file list all of it.
- Done when: every item here is Done or has a named owner and date.

### REQ-117 CI only on the integration branch
- Status: done
- Proof: .github/workflows/ci.yml (push only to main, r50-hotfix2 and release/**; pull_request; Run workflow; concurrency per ref); hotfix-notes/ci-root-cause-2026-11-27.md
- Test: the db-base, db and db-suite jobs of ci.yml (scripts/test-merge.sh fails when a file is not run exactly once)
- Asked: Nov 27
- Owner: "make sure you're not doing things systematically wrong; that's what's causing the long CI runs and test fails"
- Rule: CI runs only on the integration branch; helpers test locally; never push onto a red base. A helper branch runs the suites it touches locally (scripts/test.sh, or the db file alone on a copy of the base database; npm run test:unit; the node checks) and pushes with [skip ci]. When the integration branch is red, one CI doctor makes it green before anyone branches from it or merges into it. One push of the integration branch runs CI once for all merged helper work. A 99_ test never depends on the data or settings another 99_ test leaves.
- Done when: no CI run starts on a helper branch, and the integration branch is green before helpers branch from it.

## 16. Earlier decisions (Oct to Nov 12, from the chat extraction)

### REQ-092 Corporation, shares and shareholder money
- Status: in progress
- Proof: not yet verified against the code (earlier release); verification pass pending
- Test: to be added with the work
- Asked: Oct 2026 (T2, T12, T14)
- Owner: "CarmaCars.ca is 18122211 Canada Inc. My 50% shares should be under my own corp and Mahad's 50% shares should be under his own corp."
- Rule: Mahad and the owner share all workload, invest equally, own equally and withdraw in equal amounts. Shareholder personally owned cars: 90-10 (10% to the shared corp, 90% to the owner payout). Cohosted cars: revenue goes to the corp, then the owner share is paid out. Staff and owners get a 20% kickback on referred rentals ("referral kickback: 20% of the rental"). Shareholder cars pay the company monthly insurance and trackers and pay first and last upfront. Investor payments: 12 blended payments. Coverage sold to renters comes from a third party.
- Done when: Agreements, statements and payouts all follow these terms.

### REQ-093 One agreement per owner and owner money rules
- Status: in progress
- Proof: not yet verified against the code (earlier release); verification pass pending
- Test: to be added with the work
- Asked: ~Oct 6 (T600)
- Owner: One agreement per owner covers all cars; owner pays ServiceOntario, inspection and appraisal directly
- Rule: CarmaCars collects only $100 tracker install (now $150) plus monthly fees plus first and last month insurance. Self-managed owners are paid 100% of owner revenue on the 10th. Claim leftover after repair on third-party owner cars stays with CarmaCars (lawyer or broker approves). Referral kickback is deducted before owner revenue.
- Done when: Owner agreement and statement code match these rules.

### REQ-094 Public car code, not fleet size
- Status: in progress
- Proof: not yet verified against the code (earlier release); verification pass pending
- Test: to be added with the work
- Asked: ~Oct 24 (T1000)
- Owner: "Fleet numbers or codes r good for when a renter is describing a car they r looking at to us."
- Rule: The public site shows the car code CC-xxxx, never the fleet size. Staff AI assistant with usage alerts at 80%, investor deck, VIN-first car entry, native apps after the website.
- Done when: No public page shows the fleet size; codes show.

### REQ-095 List cars with no roadblocks
- Status: in progress
- Proof: not yet verified against the code (earlier release); verification pass pending
- Test: to be added with the work
- Asked: ~Oct 21 (T901)
- Owner: "It's a necessity to be able to list cars with no roadblocks."
- Rule: A car goes public with only year, make, model, plate or VIN, supply type and rates; missing photos, documents and signatures are warnings. Hard gates only at handover: car on the fleet policy and renter verified. Publish now button; auto-publish on by default.
- Done when: A car with only those fields publishes; handover is blocked until the two gates pass.

### REQ-096 Renter coverage rules (OPCF 27 and credit card)
- Status: in progress
- Proof: not yet verified against the code (earlier release); verification pass pending
- Test: to be added with the work
- Asked: ~Oct 21 (T901)
- Owner: "Renters must be able to upload their insurance policy if using OPCF 27 coverage, and if using credit card rental coverage, they must be paying with a credit card that actually has rental car coverage."
- Rule: Credit card, not debit or prepaid, the same card as the payment; staff approve before confirming.
- Done when: Both routes work and staff approval is required.

### REQ-097 Legal text word for word
- Status: in progress
- Proof: not yet verified against the code (earlier release); verification pass pending
- Test: to be added with the work
- Asked: ~Oct 21 (T800)
- Owner: "CarmaCars: legal text changes before launch" applied word for word
- Rule: PAD payee "[company legal name], operating as CarmaCars"; NSF-only single retry on the later of the 18th or 3 business days after return, never over 30 days; Late Fee as its own invoice line; renter-facing always "Protection Plan", never insurance, coverage or the provider name; investment agreements need an Admin countersign; signing officer Abbas Al-Mashita, Director. The only admin access is through rent@carmacars.ca.
- Done when: Every renter-facing page, email and agreement matches the legal review doc.

### REQ-098 Admin portal easy to navigate
- Status: in progress
- Proof: not yet verified against the code (earlier release); verification pass pending
- Test: to be added with the work
- Asked: ~Oct 21 (T800)
- Owner: Admin portal "super difficult to navigate and intense" (31 nav links)
- Rule: Fewer, grouped navigation links; every upgrade also applies to each relevant staff portal.
- Done when: Admin navigation is grouped and each role sees only its links.

### REQ-099 Edit renter details
- Status: in progress
- Proof: not yet verified against the code (earlier release); verification pass pending
- Test: to be added with the work
- Asked: ~Oct 25 (T1751, T1755, T1757)
- Owner: "There's no way to adjust a renters details. We accidentally entered someone's email wrong and need to change it asap"
- Rule: Admin and CS/Sales can edit name, email, phone, DOB, address and licence; an email change updates the auth user, is audit logged and warns on duplicates (case: yichengchen@gmail.com to yichengchen0923@gmail.com, booking CC-10012).
- Done when: An email edit changes sign-in and is in the audit log.

### REQ-100 Add any fee to any booking
- Status: in progress
- Proof: not yet verified against the code (earlier release); verification pass pending
- Test: to be added with the work
- Asked: ~Oct 25 (T1759, T1763)
- Owner: "the future we should be able to add in any sort of fee at all to any booking"
- Rule: Staff can add a fee line (young driver fee $70 case) to any booking including confirmed and in progress; the outstanding balance recalculates, the renter is notified with a pay link, the renter portal has a Pay button, owner statements update.
- Done when: A fee added to a confirmed booking is payable by the renter at once.

### REQ-101 01 Motors CRM sync excludes partner cars
- Status: in progress
- Proof: not yet verified against the code (earlier release); verification pass pending
- Test: to be added with the work
- Asked: ~Oct 25 (T1767, T1771)
- Owner: "it only syncs over the non-partner cars."
- Rule: The outbound GoHighLevel sync sends only our cars and cohost cars, never supply_type partner; enforced in the database and by a test.
- Done when: A partner car never appears in the outbound sync.

### REQ-102 Discount game rules
- Status: in progress
- Proof: not yet verified against the code (earlier release); verification pass pending
- Test: to be added with the work
- Asked: ~Oct 22 to 25 (T1306, T2012, T2013)
- Owner: "People that win a prize should be able to play again"
- Rule: Re-show after 60 s on site or the 2nd page view; at most 3 a visit and 6 a day; never in checkout; one code per person per day and per booking; codes expire in 7 days; "Play again after claiming" default cooldown 1 day; all admin settings.
- Done when: The game follows each limit.

### REQ-103 SEO page multipliers
- Status: in progress
- Proof: not yet verified against the code (earlier release); verification pass pending
- Test: to be added with the work
- Asked: ~Oct 22 (T1311, T1313, T1317, T1319, T1330)
- Owner: "Need seo multipliers for all those pages for DUI, bad drivers record, uber/ubereats/doordash/hopp/lyft rentals, and whatever else u suggest"
- Rule: Detailing, body shop, DUI, gig driver and occasion pages exist for every car, place, colour and term (terms from the place_terms table). The pages are for SEO only: do not change booking rules or site copy to match. Header menu adds only Chauffeur; no menu links to SEO or vehicle pages; a small quiet footer "Browse" section only. Programmatic SEO is a feature on the investor deck without page-count promises.
- Done when: The page families exist, the menu is as stated and the deck slide exists.

### REQ-104 CarmaCars phone line from settings
- Status: in progress
- Proof: not yet verified against the code (earlier release); verification pass pending
- Test: to be added with the work
- Asked: Oct 21 (T1034, T1036, T1026)
- Owner: Real line is (289) 312-5991 (Quo), not 289-321-5991
- Rule: The number comes from site settings, never hard-coded. Quo set up with caller id, menu, text-backs, contacts, call hold and call transcripts. CarmaCars Quo, Cloudflare and GitHub accounts stay separate from Almash.
- Done when: No hard-coded number in code, emails, agreements or guides.

### REQ-105 VIN-decoded listing data is correct
- Status: in progress
- Proof: not yet verified against the code (earlier release); verification pass pending
- Test: to be added with the work
- Asked: ~Oct 22 (T1304)
- Owner: "the gearbox and seats info seems to be wrong too"
- Rule: Trim lists, gearbox and seats decode correctly (Beetle, Jetta, Forte cases); cited data only.
- Done when: The sample cars show the right trim, gearbox and seats.

### REQ-106 Fleet page filters can hide
- Status: in progress
- Proof: not yet verified against the code (earlier release); verification pass pending
- Test: to be added with the work
- Asked: ~Oct 22 (T1515)
- Owner: "there should be a way to hide the options menu because that takes up a lot of the screen"
- Rule: A small arrow hides and shows the filter menu on the fleet page.
- Done when: The filter menu collapses on desktop and phone.

### REQ-107 Facebook Marketplace
- Status: in progress
- Proof: not yet verified against the code (earlier release); verification pass pending
- Test: to be added with the work
- Asked: ~Oct 25 (T1753, T1765)
- Owner: "For fb marketplace I just need the auto replies and auto posting."
- Rule: Meta auto replies; posting and replying through Chrome; ready-to-post listings; a quick page /fb; Quo auto text reply.
- Done when: Listings and replies run without manual typing.

### REQ-108 Website needs real photos
- Status: in progress
- Proof: not yet verified against the code (earlier release); verification pass pending
- Test: to be added with the work
- Asked: ~Oct 25 (T1769, T1773)
- Owner: "My website also desperately needs photos."
- Rule: Licensed stock photos on SEO pages; real fleet photos through the guided photo flow.
- Done when: Every published page and car has a real or approved photo.

### REQ-109 Admin lists are in the order they came in
- Status: in progress
- Proof: not yet verified against the code (earlier release); verification pass pending
- Test: to be added with the work
- Asked: Nov 12 (T4401)
- Owner: "it should probably be chronological in the order that it came in, not alphabetical."
- Rule: Renters, bookings, offers, leads and hiring lists default to newest or arrival order, not alphabetical.
- Done when: Each list opens in arrival order.

### REQ-110 Town hall and interview reminders
- Status: in progress
- Proof: not yet verified against the code (earlier release); verification pass pending
- Test: to be added with the work
- Asked: Nov 12 (T4403, T4407)
- Owner: "I mean to remind them through notifications and through the actual staff portal."
- Rule: Remind everyone, including the owner, about the town hall and interviews by notifications and the staff portal, not WhatsApp or calendar. Google Calendar connect must work.
- Done when: Reminders arrive in the portal and as notifications.

### REQ-111 Hiring alerts and tough interviews
- Status: in progress
- Proof: not yet verified against the code (earlier release); verification pass pending
- Test: to be added with the work
- Asked: Nov 12 (T4409)
- Owner: "You can notify me when a new applicant comes through, when an AI interview gets done and when a live call gets booked ... Make the interviews difficult, a pre-screening to the academy."
- Rule: Notify the owner on those three events, with no action required except when an interview is booked; interviews act as a hard pre-screen to the academy.
- Done when: The three notices fire and only a booked interview creates a task.

### REQ-112 Secrets in GitHub for setup steps
- Status: in progress
- Proof: not yet verified against the code (earlier release); verification pass pending
- Test: to be added with the work
- Asked: Nov 12 (T4411)
- Owner: "put the values into a GitHub secrets thing, so I literally just have to copy and paste it in and click submit"
- Rule: Every setup the owner must finish is prepared so he only pastes and clicks (Google OAuth values to GitHub secrets).
- Done when: Each owner setup step is one paste and one click.

### REQ-113 Close unused browser tabs
- Status: in progress
- Proof: not yet verified against the code (earlier release); verification pass pending
- Test: to be added with the work
- Asked: Nov 12 (T4413)
- Owner: "There are way too many tabs open. This is a mess."
- Rule: Close tabs when finished; use the CarmaCars Chrome profile for CarmaCars work.
- Done when: No stray tabs remain after a browser task.

### REQ-114 Insurer rental data on the rental
- Status: in progress
- Proof: not yet verified against the code (earlier release); verification pass pending
- Test: to be added with the work
- Asked: Oct 2026 (T2200 to T2211)
- Owner: "insurer rentals can be longer than 30 days"
- Rule: Claim number, policy number, licence and adjuster details are saved on the renter profile or rental; insurer pays HST on top; VLF billed (target $20 a day); insurer rentals may exceed 30 days; the sales portal must let sales staff enter rentals and offers; the numbered company name (not CarmaCars) shows as the sender name on insurer emails.
- Done when: An insurer rental holds all those fields and sales can create it.

### REQ-115 Nightly storage cleanup
- Status: in progress
- Proof: not yet verified against the code (earlier release); verification pass pending
- Test: to be added with the work
- Asked: Oct 21 (T1019)
- Owner: "ya why not"
- Rule: Nightly auto-cleanup of old test reports and guide screenshots (about 3:23am); photos, documents, signed agreements and backups are never touched.
- Done when: The cleanup runs and none of the protected data is deleted.

### REQ-116 Email and To do organiser
- Status: not started
- Proof: not yet verified against the code (earlier release); verification pass pending
- Test: to be added with the work
- Asked: Oct 21 (T1010)
- Owner: "i need ur help with an automatic organizer for the emails and with everything in my to do list"
- Rule: Automatic email organiser and To do handling, running inside the account (not tied to one business inbox).
- Done when: Incoming mail is sorted and tasks are tracked automatically.
