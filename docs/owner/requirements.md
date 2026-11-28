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
- Proof: branch r50-hotfix2-photos (not on main, not live): docs/changes/2026-11-25-r50-hotfix2-photos.md; migration 5080 (app.photo_render_order = the 8 sample angles; app.public_listing_photos: the views in that order, then the real photos cut out); web r48.ts R48_ANGLES and R48_ROOM_PATH, studio-composite.ts (one room for every view of every car). Live check after deploy: a real car page shows the set first, the same room, real photos after; fresh-eyes fixes: an older render that was live stays on the site until its view is made again (prev_live), only exterior check-in and check-out angles go to the image model (app.photo_r48_handover_shot) with a line on the privacy page, the real-photo extras wait while any standard view is waiting (app.photo_r48_views_waiting)
- Test: supabase/tests/99_r50h2_studio_composite.sql (sections 1, 6, 9); web/src/features/listing/r48.test.ts; web/src/features/listing/studio-gate.test.ts
- Asked: Nov 25 (repeated Nov 25 20:13, Nov 27)
- Owner: "generate each vehicle in every single angle ... same angles as the sample photos, same order ... real photos after, still cut out on the same background"
- Rule: every car gets all the sample photos' angles, in exactly the same angles and order as the samples. When a car has no photo for an angle, AI generates that exact car (same rims, same paint, same everything) in that angle. After the AI angles come the real photos, cut out onto the same AI background. Every background looks exactly the same.
- Done when: a real car shows the full sample angle set first, identical backgrounds, real photos after.

### REQ-002 Cutout only on heroes, home and cards
- Status: in progress
- Proof: branch r50-hotfix2-photos (not on main, not live): migration 5080 (worker_listing_result keeps the cover matte and the side cutout in site_cutouts; app.site_studio_covers gives only the cutout with the room); web components/SlotCars.tsx (home, heroes, fleet, delivery and owner pages: cutouts where the sample car stood), components/Picture.tsx StudioTurn (cards: the room once, the cutouts over it). Live check after deploy: heroes, home and sample cards on every page
- Test: supabase/tests/99_r50h2_studio_composite.sql (section 9); web/src/features/listing/r48.test.ts (the cover matte and the side cutout); e2e not run here: GAP for the rendered pages
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
- Proof: branch r50-hotfix2-photos (not on main, not live): docs/changes/2026-11-25-r50-hotfix2-photos.md ("The cause of a failed check was never stored"); web integrations/photos/gemini.ts geminiCheckImages reports the cause, server/listing-worker.ts records it; migration 5080 app.photo_mark_record keeps it with the photo; the cost guard (app.photo_r48_cost_guard, 3 calls a photo a day, pause and alert). Production cause still unknown: photo_standard fails in production (site_errors Nov 27: POST /api/mcp syntax error at or near ")", fixed in 5080) and no Gemini key here for a real call
- Test: supabase/tests/99_r50h2_studio_composite.sql (sections 3, 4, 7, 10); web/src/integrations/photos/gemini-route.test.ts
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
- Proof: merge 38c7572a (r50-hotfix2-infra); web/src/components/Effects.tsx; web/src/features/admin/BookingReview.tsx
- Test: GAP (no test sends an offer and checks the page moves on)
- Asked: Nov 25 21:52 (repeated three times)
- Owner: "Send the offer button isn't working ... says sent but nothing sent, stays on the page"
- Rule: sending an offer sends it, shows a clear confirmation and moves on.
- Done when: an offer sent from Admin reaches the renter (email and site) and the page moves on.

### REQ-008 Ended and returned bookings never block the calendar
- Status: in progress
- Proof: merge 38c7572a (r50-hotfix2-infra); supabase/migrations/5111_r50h2_ended_never_blocks.sql; Done when needs the live site after the combined deploy (CC-10597 and the named booking closed)
- Test: supabase/tests/99_r50h2_hotfix.sql
- Asked: Nov 25 22:02, Nov 27 01:11
- Owner: "ended is blocking the calendar ... returned bookings stay open"
- Rule: an ended or returned booking releases its dates and closes itself.
- Done when: no ended or returned booking competes for dates (CC-10597 and the Yusuf Abbas booking closed).

### REQ-009 Button flow
- Status: in progress
- Proof: merge 38c7572a (r50-hotfix2-infra); web/src/components/Effects.tsx
- Test: GAP (no site-wide button flow test)
- Asked: Nov 25 21:52
- Owner: "when I click a button it shows working then shows the button again ... bad flow and ugly"
- Rule: after a click show a clear confirmation and move on; never flip back to the same button. Site-wide, every page.
- Done when: every action button on every portal shows working, then done, then moves on.

### REQ-010 Report-a-bug pill on phones
- Status: in progress
- Proof: merge 38c7572a (r50-hotfix2-infra); web/src/features/bug-report/bug-report.css; Done when needs the live site after the combined deploy (every portal at phone width)
- Test: web/tests/e2e/bug-report-over-popup.spec.ts
- Asked: Nov 25 22:02
- Owner: "Report a bug button occupies the entire width"
- Rule: the pill is small and never covers the sheet width on phones.
- Done when: checked at phone width on every portal.

### REQ-011 Renter booking page wording and picture
- Status: in progress
- Proof: merge 38c7572a (r50-hotfix2-infra); web/src/features/portal/next-action.ts (wording); the broken picture is not proven
- Test: web/src/features/portal/next-action.test.ts
- Asked: Nov 25 22:08
- Owner: "wtf is add it and why is there a broken picture"
- Rule: clear wording instead of "Next: Add it"; no broken picture.
- Done when: the booking page has plain wording and a working picture for every car.

### REQ-012 Instant booking
- Status: done
- Proof: merge 38c7572a (r50-hotfix2-infra); supabase/migrations/5113_r50h2_instant_complete_profile.sql
- Test: supabase/tests/99_r50h2_hotfix.sql; supabase/tests/99_r35a_request_offers.sql
- Asked: Nov 25 22:08, Nov 27 06:37
- Owner: "Filter by instant booking, not on sample or 01 Motors cars, shown for complete profiles regardless of tier"
- Rule: an instant booking filter; never on sample or 01 Motors cars; shown to renters with complete profiles whatever their tier.
- Done when: the filter works, and a complete-profile renter of any tier sees Book instantly.

### REQ-013 Renter notes and referrer on a request
- Status: done
- Proof: merge c6c2d8e3 (r50-hotfix2-sales); supabase/migrations/5132_r50s_request_note_referrer.sql
- Test: supabase/tests/99_r50s_sales.sql; web/tests/e2e/r50s-sales.spec.ts
- Asked: Nov 27 01:11, 01:13
- Owner: "Renters should be able to add notes on each booking when making a request"
- Rule: renters can add a note on each request and enter "who referred you".
- Done when: both fields show on the request and in Admin and Sales views.

### REQ-014 Staff list on accept
- Status: done
- Proof: merge c6c2d8e3 (r50-hotfix2-sales); supabase/migrations/5133_r50s_sales_people_extension_credit.sql
- Test: supabase/tests/99_r50s_sales.sql
- Asked: Nov 27 01:11
- Rule: every eligible staff member (Jamal was missing) appears in the list when accepting a request.
- Done when: the list matches the active staff roster.

### REQ-015 Sample car data fix
- Status: in progress
- Proof: merge c63e8525 (r50-hotfix2-insurance); supabase/migrations/5123_r50i_cc10067_off_calendar.sql; Done when needs the live site after the combined deploy (the migration acts on the live CC-10067 and says why when it does not)
- Test: supabase/tests/99_r50i_insurance_replacements.sql
- Asked: Nov 27 07:07
- Owner: "Cybele A10 CC-10067 should not block the calendar and should not inform the owner"
- Done when: CC-10067 blocks nothing and sends no owner notice.

### REQ-016 Notify on every new request
- Status: done
- Proof: merge 450cd017 (r50-hotfix2-errors); supabase/migrations/5102_r50h2_todo_noise.sql
- Test: supabase/tests/99_r50h2_errors_alerts.sql; supabase/tests/99_r50h2_errors.sql
- Asked: Nov 26 17:38
- Owner: "Why am I not getting notified for requests, only when expiring"
- Rule: notify on every new request, not only when it is about to expire.
- Done when: a new request notifies the right roles at once.

### REQ-017 Sample car inquiries become requests
- Status: done
- Proof: merge c6c2d8e3 (r50-hotfix2-sales); supabase/migrations/5130_r50s_sample_requests.sql
- Test: supabase/tests/99_r50s_sales.sql; web/tests/e2e/r50s-sales.spec.ts
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
- Status: done
- Proof: merge 450cd017 (r50-hotfix2-errors); supabase/migrations/5102_r50h2_todo_noise.sql
- Test: supabase/tests/99_r50h2_errors_alerts.sql
- Asked: Nov 26 17:06
- Rule: the return due notice goes out at the return time, not two hours later.
- Done when: the notice time equals the return time.

### REQ-021 Check-in visit email wording
- Status: done
- Proof: merge 450cd017 (r50-hotfix2-errors); supabase/migrations/5103_r50h2_push_checkin_copy.sql
- Test: supabase/tests/99_r50h2_errors_alerts.sql
- Asked: Nov 26 17:33
- Rule: the check-in visit email does not read like a pickup check-in.
- Done when: the email says what the visit is.

### REQ-022 Unfinished rentals section
- Status: done
- Proof: merge c63e8525 (r50-hotfix2-insurance); supabase/migrations/5120_r50i_insurance_replacements.sql
- Test: supabase/tests/99_r50i_insurance_replacements.sql; web/tests/e2e/insurance-replacements.spec.ts
- Asked: Nov 16 to 20
- Rule: the unfinished rentals section sits where it makes sense; an unfinished rental is never lost ("already saved or discarded").
- Done when: an unfinished rental can always be reopened.

## 3. Insurance replacement rentals and invoices

### REQ-023 Insurance replacement page
- Status: done
- Proof: merge c63e8525 (r50-hotfix2-insurance); supabase/migrations/5120_r50i_insurance_replacements.sql
- Test: supabase/tests/99_r50i_insurance_replacements.sql; web/tests/e2e/insurance-replacements.spec.ts
- Asked: Nov 26 22:57 (re-asked Nov 27 07:14)
- Owner: "I don't see you mentioning the insurance portal"
- Rule: a staff page, not a portal: invoices, edit every field, send estimate or invoice, bypass calendar and owner notices, visible to Finance not Field, in the design kit.
- Done when: Finance creates, edits and sends an insurer rental end to end; Field cannot see it.

### REQ-024 Re-send invoices as often as needed
- Status: done
- Proof: merge c63e8525 (r50-hotfix2-insurance); supabase/migrations/5120_r50i_insurance_replacements.sql
- Test: supabase/tests/99_r50i_insurance_replacements.sql; web/tests/e2e/insurance-replacements.spec.ts
- Asked: Nov 27 00:33
- Owner: "nothing left to invoice"
- Rule: updated invoices can be re-sent to the insurer or adjuster any number of times, including end of rental and extensions.
- Done when: a re-send works after every change.

### REQ-025 Manual car entry, optional phone and email
- Status: done
- Proof: merge c63e8525 (r50-hotfix2-insurance); supabase/migrations/5120_r50i_insurance_replacements.sql
- Test: supabase/tests/99_r50i_insurance_replacements.sql
- Asked: Nov 26 20:57, 21:15
- Owner: "I thought we agreed" (phone and email optional)
- Rule: a car not in the fleet can be typed in; phone and email are optional.
- Done when: a rental saves with a manual car and no phone or email.

### REQ-026 Winter tire fee editable
- Status: done
- Proof: merge 4df06de9 (r50-hotfix2-ops); supabase/migrations/5142_r50h2_winter_tire_fee.sql
- Test: supabase/tests/99_r50h2_winter_tire.sql
- Asked: Nov 25 18:35
- Done when: the fee can be edited on an insurer-billed rental.

### REQ-027 Paste a block of text
- Status: done
- Proof: merge c63e8525 (r50-hotfix2-insurance); web/src/features/insurance/model.ts
- Test: web/src/features/insurance/model.test.ts; web/tests/e2e/insurance-replacements.spec.ts
- Asked: Nov 25 20:42
- Rule: pasting a block of text creates a rental with fields sorted.
- Done when: a pasted claim text fills the rental fields.

### REQ-028 Partner API key
- Status: in progress
- Proof: merge c63e8525 (r50-hotfix2-insurance); supabase/migrations/5120_r50i_insurance_replacements.sql (insurer_rental_create through the connector); Done when needs the live site after the combined deploy (a rental made with that partner key)
- Test: supabase/tests/99_r50i_insurance_replacements.sql
- Asked: Nov 27 00:17
- Rule: Mahad's API key creates insurer rentals end to end.
- Done when: a rental created by that key appears with its invoice.

### REQ-029 Direct deposit on invoices
- Status: in progress
- Proof: merge 38c7572a (r50-hotfix2-infra); supabase/migrations/5110_r50h2_pay_offline.sql (the details come from Program settings); Done when needs the live site after the combined deploy (an issued invoice)
- Test: supabase/tests/99_r50h2_hotfix.sql
- Asked: Nov 25 18:35
- Rule: invoices show direct deposit (the account, transit and institution an Admin enters in Program settings; never written in the repository) next to e-Transfer.
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
- Status: done
- Proof: merge 38c7572a (r50-hotfix2-infra); supabase/migrations/5110_r50h2_pay_offline.sql; web/src/features/money/card-pay.ts
- Test: supabase/tests/99_r50h2_hotfix.sql; web/src/features/money/card-pay.test.ts
- Asked: Nov 25 22:38 (repeated Nov 26 18:18, Nov 27 07:07)
- Owner: "people still try to pay via credit card"
- Rule: while there is no card processor, checkout and pay links offer e-Transfer and cash only; the Admin setting is off.
- Done when: checkout and links show no card option.

### REQ-032 Commission only on what the salesperson initiated
- Status: done
- Proof: merge c6c2d8e3 (r50-hotfix2-sales); supabase/migrations/5133_r50s_sales_people_extension_credit.sql
- Test: supabase/tests/99_r50s_sales.sql
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
- Status: done
- Proof: merge 4df06de9 (r50-hotfix2-ops); supabase/migrations/5140_r50h2_tolls_407.sql; supabase/migrations/5147_r50h2_toll_hold.sql
- Test: supabase/tests/99_r50h2_tolls_407.sql; web/src/features/tolls/parse.test.ts
- Asked: Nov 25 20:42 (repeated)
- Owner: "never fixed the tolls and tickets reader ... super broken, especially 407, urgent"
- Done when: a 407 statement is read and matched to bookings.

### REQ-041 Expenses
- Status: done
- Proof: merge 4df06de9 (r50-hotfix2-ops); supabase/migrations/5143_r50h2_expense_receipts.sql
- Test: supabase/tests/99_r50h2_expense_receipts.sql; web/src/features/expenses/receipt-read.test.ts; web/tests/e2e/r50h2-ops-uploads.spec.ts
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
- Status: done
- Proof: merge c6c2d8e3 (r50-hotfix2-sales); supabase/migrations/5137_r50s_call_text_guard.sql (the only migration with it)
- Test: supabase/tests/99_r50s_sales.sql
- Asked: Nov 26 18:07
- Rule: salespeople cannot text phone numbers on the main line; flag phone numbers, swearing and risky words said on calls.
- Done when: both flags raise an Admin item.

### REQ-132 A Twilio line for every staff member behind a Quo extension
- Status: in progress
- Proof: branch r51-staff (not on main, not live): migration 5200 (staff_phone_lines, staff_phone_line_secrets with no browser grant, ringing one person, staff_line_missed and staff_line_ready); web/src/server/staff-lines.ts (Get a number shows Twilio's price, Buy needs that price, never from a test server), features/phone/StaffLine.tsx, MyLine.tsx, twilio-call.ts incoming; the Quo owner steps in docs/changes/2026-11-27-r51-staff.md (Quo's API has no call flow endpoint). Nothing bought yet: the owner presses Buy per person
- Test: supabase/tests/99_r51_staff_lines.sql; web/src/features/phone/staff-lines.test.ts
- Asked: Nov 27 17:29
- Owner: "i need all staff to have a dedicated twilio line that corresponds with an extension number that is on quo, so that all staff can get incoming calls to their portals and their apps via their extension numbers that forward to their twilio phone numbers (nobody will ever know what those numbers are)"
- Rule: each staff member has an extension number and their own Twilio number. A call to that number rings only that person's portal and app (the browser phone). Nobody else rings; a missed call is logged and alerts that person. The Twilio number is never shown to staff or renters; Admin sees its last 4 digits only. Buying a number costs money: only an Admin buys one, with a button that shows the monthly cost and asks for confirmation; tests and jobs never buy numbers. Quo's API cannot create a phone menu option or a forward, so the owner adds each extension in Quo by hand (steps in the change doc).
- Done when: an Admin gets a line for a staff member after confirming the cost shown; a call to that line rings only that person's portal or app; no screen, email or read gives the full number to anyone; the Quo steps are in the change doc.

### REQ-136 Insurer emails that bounce are caught, retried and never silent
- Status: in progress
- Proof: branch r51-staff (not on main, not live): migration 5204 (email_bounces, app.server_email_bounce, insurers.claims_email and claims_phone, the version marked bounced, the To do with the allowlist request, the fallback send, insurer_delivery); web/src/app/api/inbound/bounce, features/email-bounces/ndr.ts, scripts/turo-gmail.gs (owner: paste and run setup), send-outbox X-Outbox-Ref; DMARC recommendation in docs/changes/2026-11-27-r51-staff.md (DNS not changed)
- Test: supabase/tests/99_r51_insurer_bounces.sql; web/src/features/email-bounces/ndr.test.ts
- Asked: Nov 27 18:22
- Owner: "emails coming from blindspotcarrental @ carmacars are not getting passed insurance's firewall. can u fix that and make sure it doesnt happen again"
- Rule: the cause is the insurer's accept list (550 5.7.129 RestrictedToRecipientsPermission; SPF, DKIM and DMARC passed), so the site cannot make the insurer accept the email; it makes every refusal visible and acted on. The site reads bounces (NDR and delivery reports) of insurer emails, marks the send failed on the invoice version and the booking, and raises one Admin To do with the reason, the adjuster, the insurer's general claims contact and an allowlist request ready to send. Insurers have a fallback claims email and phone; a bounced invoice or estimate goes again to the fallback once, in Blind Spot branding, never naming CarmaCars. Admin sees each insurer email's delivery (sent, delivered, bounced). DNS is not changed by Claude: moving DMARC from p=none to p=quarantine is a recommendation once every sender is aligned.
- Done when: a bounce email for an insurer invoice marks that version bounced, logs it on the booking, raises the To do with the allowlist request, and sends the invoice again to the claims email when one is on file; the booking page shows each version's delivery.

### REQ-137 Insurer emails never go from rent@carmacars.ca
- Status: in progress
- Proof: branch r51-staff (not on main, not live): migration 5204 (app.insurer_not_from_rent on notification_catalogue, email_reply_to and notification_outbox); the catalogue already sends as blindspotcarrental@carmacars.ca; docs/changes/2026-11-27-r51-staff.md. SES sends it once the owner sets the SES keys (docs/email-providers.md); Resend until then
- Test: supabase/tests/99_r51_insurer_bounces.sql; web/src/features/insurance/insurer-sender.test.ts
- Asked: Nov 27 18:43
- Owner: "DO NOT SEND IT FROM RENT@CARMACARS.CA"
- Rule: insurer emails never go from rent@carmacars.ca: not as the From, not as the reply-to, not as the envelope sender, not as a Gmail send-as alias of rent@. The site sends them itself as blindspotcarrental@carmacars.ca (SES with its aligned MAIL FROM once the SES keys are set; Resend until then). A check fails the build if any insurer email template or sender setting uses rent@, and the database refuses such a setting. The Gmail alias or Workspace idea is dropped. The Definity bounce (5.7.129) is the recipient's accept list: the bounce To do work (REQ-136) stays.
- Done when: the build check and the database refuse rent@ in any insurer email's template, From, reply-to or outbox row, and every insurer email sent shows blindspotcarrental@carmacars.ca as its sender.

## 7. Alerts, To do's, self-heal

### REQ-048 Alerts and To do's do not pile up
- Status: in progress
- Proof: merge 450cd017 (r50-hotfix2-errors); supabase/migrations/5102_r50h2_todo_noise.sql; supabase/migrations/5104_r50h2_heal_bug_reports.sql; Done when needs the live site after the combined deploy (the open alert count stays at real items)
- Test: supabase/tests/99_r50h2_errors.sql; supabase/tests/99_r50h2_errors_alerts.sql
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
- Proof: branch r50-hotfix2-oldphotos (not on main): migrations 5185 to 5187, docs/changes/2026-11-27-r50h2-old-photos.md; fresh-eyes fixes: photos added later hidden from the renter and the owner, capture time only inside the booking's dates, 200 photos a report, 30 plate reads a person a day
- Test: supabase/tests/99_r50h2_old_photos.sql; web/src/features/old-photos/old-photos.test.ts; web/tests/e2e/r50h2-old-photos.spec.ts
- Asked: Nov 26 14:43, Nov 27 07:12
- Rule: upload check-in and out photos for previous bookings, in bulk; field staff can see those bookings.
- Done when: a past booking accepts bulk photos.

### REQ-056 Shift claims need approval
- Status: done
- Proof: merge c6c2d8e3 (r50-hotfix2-sales); supabase/migrations/5136_r50s_shift_claim_approval.sql
- Test: supabase/tests/99_r50s_sales.sql
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

### REQ-133 Cleaning is not a step after every return
- Status: in progress
- Proof: branch r51-staff (not on main, not live): migration 5202 (booking_after_status: available unless app.return_needs_cleaning; a report changed to need cleaning moves an available car to cleaning)
- Test: supabase/tests/99_r51_return_clean.sql
- Asked: Nov 27 17:29
- Owner: "these cleaning jobs seem like a headache"
- Rule: cleaning never blocks a booking and the detail job closes it (REQ-129, 5195). A car goes straight back to available after a return, unless the return report says it needs cleaning (cleanliness other than clean); only then is it in cleaning until the detail job is done.
- Done when: a return with a clean report leaves the car available; a return whose report says it needs cleaning puts it in cleaning; the detail job marked done makes it available.

## 9. Sales, leads, hiring

### REQ-058 Lead-generator portal
- Status: done
- Proof: merge c6c2d8e3 (r50-hotfix2-sales); supabase/migrations/5134_r50s_lead_generators.sql
- Test: supabase/tests/99_r50s_sales.sql; web/tests/e2e/r50s-sales.spec.ts
- Asked: Nov 25 19:24
- Rule: a portal for Eric: enter owner leads, hand to closers, $100 flat per closed owner lead.
- Done when: a closed lead pays $100.

### REQ-059 Recruit invite links
- Status: done
- Proof: merge c6c2d8e3 (r50-hotfix2-sales); supabase/migrations/5135_r50s_recruit_links.sql
- Test: supabase/tests/99_r50s_sales.sql
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
- Proof: merge 52ff1ccb (r50-hotfix2-seo); supabase/migrations/5161_r50h2_interview_reminders.sql (applicants who skip the interview are chased); Done when needs the live site after the combined deploy (drop-off falls)
- Test: supabase/tests/99_r50h2_seo_hiring_traction.sql
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
- Status: done
- Proof: merge 32e867b2 (r50-hotfix2-ux); web/src/features/demo/DemoPortals.tsx
- Test: web/src/features/demo/model.test.ts; web/tests/e2e/r50h2-ux.spec.ts
- Asked: Nov 25 20:41
- Rule: staff can open a demo renter and a demo owner portal.
- Done when: both open from a staff portal.

### REQ-067 Academy
- Status: in progress
- Proof: branch r50-hotfix2-academy at 31356c07 (not on main): supabase/migrations/5170 to 5172
- Test: supabase/tests/99_r50h2_basics_routing.sql (92 assertions: basics, pay and hours hold and release, stuck sections, Admin access, audit)
- Asked: Nov 27 01:12, 05:02, 12:36, 15:05
- Owner (Nov 27 12:36): "Pay for hours should also be held until academy is passed. Field staff must finish entire academy. Same with customer service and fleet and finance."
- Owner (Nov 27 15:05): "Portal stays locked for field staff and customer service and finance and fleet until they finish the full academy"
- Rule: the first sections (more than 3) unlock work for Admins and Sales; Field, customer service, Finance and Fleet need the full academy before the portal opens; the full academy is needed for payouts; shorter; lessons match questions; stuck or repeated errors force that section; Admin opens any lesson and quiz; wrong-answer wait 2 minutes with one fix. Payouts held until the entire academy is passed cover hours and shift pay too, plus commission, bonus, referral and contractor payouts, for Field, customer service, Fleet and Finance; held pay is never lost (paid in full on the first pay run after the pass); an Admin can waive per person with a reason; one Program setting turns the hours part off (on by default).
- Done when: each rule is testable in the academy; an hourly or shift pay line for a Field, customer service, Fleet or Finance person who has not passed the full academy is held, and is paid on the first pay run after they pass; a Field, customer service, Finance or Fleet person who has not passed the full academy reaches only the academy and onboarding pages (agreement, documents, pay details); every other staff page sends them to the academy.

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

### REQ-130 Academy: answer yourself, no AI or computer use
- Status: in progress
- Proof: branch r51-staff (not on main, not live): docs/changes/2026-11-27-r51-staff.md; migration 5199 (app.academy_integrity_reasons, academy_quiz_submit voids and alerts academy_integrity, Admin read academy_voided); web/src/features/academy/integrity.ts and Study.tsx (the disclaimer on every question, paste and copy blocked, focus, pointer, isTrusted, webdriver, driver markers, devtools probe); the sentence in docs/source/va_agreement.md 2.4 and field_staff_agreement.md 2.3 (for the owner's lawyer); guides 5207. No web page can fully stop an AI agent: detectable, not impossible
- Test: supabase/tests/99_r51_academy_integrity.sql; web/src/features/academy/integrity.test.ts
- Asked: Nov 27 17:29
- Owner: "put it on the academy on each question as a disclaimer somewhere that computer use is not allowed and carmacars will sue u and make sure that it just makes sure that they cant use ai and claude chrome to complete the tests"
- Rule: every academy question shows: "Answer yourself. Using AI tools, browser agents or computer-use software on this test is not allowed and breaks your agreement; CarmaCars may take legal action." The staff agreements say the same (no other legal terms; the owner's lawyer reviews the wording). The quiz blocks paste into answers, records focus loss and tab switches, flags answers faster than a floor per question, hands out questions and options in a random order, and detects automation signals (navigator.webdriver, automation markers that drivers and extensions inject, events not made by a person, a mouse that jumps without moving). A flagged attempt is voided, kept on record with its reasons, and Admin gets an alert. No web page can fully stop an AI agent: these checks make it detectable, not impossible.
- Done when: every question of a started quiz shows the disclaimer; a submit carrying an automation signal, a paste or too many focus losses is recorded as a voided attempt with its reasons, never as a pass, and Admin gets the alert; the staff agreement texts carry the sentence.

### REQ-131 Managers see their team
- Status: in progress
- Proof: branch r51-staff (not on main, not live): migration 5201 (staff_profiles.is_manager, manager_id; staff_manager_set, staff_team_set, my_team, team_member, my_roles manager); web/src/features/team, /staff/team, Admin > Settings > Staff Manager column, the app's Profile My team; guide va/my-team (5207)
- Test: supabase/tests/99_r51_managers.sql; web/src/features/team/model.test.ts; web/src/features/staff/nav.test.ts
- Asked: Nov 27 17:29
- Owner: "also i need to be able to set staff to managers that have insight on the staff that are assigned to them"
- Rule: Admin marks a staff member as a manager and assigns staff to them. A manager sees, read only, each team member's hours, academy progress, KPIs, pay owed, field jobs and activity, with the same masking as Admin, in the staff portal and the app, with a guide chapter. A manager never changes a team member's records from this view.
- Done when: an Admin sets a manager and a team; the manager's My team page shows those facts for their team only and refuses anyone else; the app opens it from Profile; the guide chapter describes it.

### REQ-134 Academy: retry the wrong ones first, shorter wait, fewer steps
- Status: in progress
- Proof: branch r51-staff (not on main, not live): migration 5203 (wait 2 to 1 minute; 4 questions that tested the same thing twice dropped; 2 wrong answers corrected); Study.tsx Try again in one press; the list in docs/changes/2026-11-27-r51-staff.md. The fix of only the wrong ones before any wait is 5070 (r50-hotfix2, not live)
- Test: supabase/tests/99_r50h2_academy_leads.sql; supabase/tests/99_r48_academy_guides.sql
- Asked: Nov 27 17:45
- Owner: "the academy wait time when getting things wrong is too long and they need to have 1 chance to retry the wrong questions before it starts the wait time. also i think theres a lot of redundant sections or questions and just unnecessary steps. it needs to be easier"
- Rule: after a quiz below the pass mark, the person retries only the wrong questions once, straight away; the wait starts only if that retry fails. The wait is half of what it was (REQ-067 set 2 minutes: now 1 minute). Sections and questions are audited per role: duplicates merged, questions that test the same thing twice dropped, steps that add clicks without teaching removed; the change doc lists what was removed.
- Done when: a failed first try offers the retry of only the wrong questions with no wait; a failed retry waits 1 minute; the change doc lists every section, question and step removed.

### REQ-135 Easy onboarding: every blocking screen has its next button
- Status: in progress
- Proof: branch r51-staff (not on main, not live): docs/changes/2026-11-27-r51-staff.md; migrations 5197 (on hotfix 2; was 5304) and 5205 (the pay step last) (app.staff_agreement_now clears the agreements job's wait and 5-try stop; staff_agreement_help alerts the Admins; staff_welcome gains the pay step and next); web/src/app/staff/welcome/page.tsx (a big button per step, stepAction in features/academy/gate.ts), features/staff-onboarding/SignNow.tsx, server/actions/onboarding-now.ts; guides 5198. Why production Jamal had no agreement (waiting, failed or stopped) is not readable through the connector
- Test: supabase/tests/99_r51_easy_onboarding.sql; web/src/features/academy/gate.test.ts
- Asked: Nov 27 17:45
- Owner: "jamal got the academy waived for him and now it says your agreement first and theres no buttons to click anywhere other than resign. this is bad ui, he needs to have things to click to finish up his profile so he can start using his portal. he needs extremely easy steps to follow for getting access to portals. all staff should have easy flows."
- Rule: the agreement step always offers Sign now: it makes the agreement at once when there is none (also after the automatic job gave up) and opens it to sign; if it still waits for something, the page says exactly what, with a button for what the person gives and an alert to Admin for what only Admin gives. Welcome is one checklist for every staff role: each remaining step is one big button (Sign agreement, Set availability, Join the WhatsApp group and Confirm, Pay details), done steps ticked, and the portal opens when the list is done. No blocking screen is a dead end.
- Done when: a staff member in Jamal's state (Sales and Field, academy waived, no agreement made, availability not set, WhatsApp not confirmed) sees a big button for each step left on Welcome, Sign now makes and opens the agreement, and every blocking screen links to its next step.

### REQ-138 Managers follow up on their staff, and pass a Manager academy section
- Status: in progress
- Proof: branch r51-staff (not on main, not live): migration 5206 (team_followups, job_team_followups hourly, job_team_weekly Monday, the Managers academy path and section, team_followup_done); web/src/features/team/pages.tsx (Follow up card: Call, Text, Mark followed up); guide va/my-team (5207). Follow-ups are on My team and the alerts, not the function To do queues
- Test: supabase/tests/99_r51_manager_followups.sql; web/src/features/team/model.test.ts
- Asked: Nov 27 19:45
- Owner: "Managers should be following up on their assigned staff and what not and get academy shit for it"
- Rule: a manager gets To dos for their own team: a member stalled in the academy 2 days or more, onboarding steps still open, a missed field job or shift, KPIs below target, and their own follow-ups that are overdue. Each has one-tap actions: message, call, and mark followed up with a note. The manager gets a weekly team summary. A Manager section of the academy (how to follow up, coach, escalate, approve hours) is on every manager's path, wired like the other role sections, and must be passed before the follow-up tools open.
- Done when: a manager of a stalled or behind team member gets the To do with message, call and followed-up actions; the weekly summary arrives; the Manager section is on their academy path and My team's follow-ups wait until it is passed.

### REQ-139 One deployment: a failed run absorbs the queued work
- Status: in progress
- Proof: this release (r50-hotfix2) carries R50 hotfix 2, R51 and the R51 review fixes in one CI run with deploy
- Test: GAP (process rule, checked by the release log)
- Asked: Nov 27 21:19
- Owner: "every time the run fails, just merge all the future stuff that we've talked about into that same deployment. Don't just create multiple deployments unnecessarily."
- Rule: when a release run fails, the next finished work is merged into that same release before the rerun. No second release is cut while one is pending.
- Done when: every release log shows one deployment per pending release, with queued work folded in after each failure.

### REQ-140 Visitors week over week, on the connector
- Status: in progress
- Proof: supabase/migrations/5211_r51_visitor_weeks.sql (app.visitor_weeks, api_call wrapper); web/src/features/api-access/tools.ts (visitor_weeks)
- Test: supabase/tests/99_r51_visitor_weeks.sql; web/src/features/api-access/tools.test.ts
- Asked: Nov 27 22:28
- Owner: "How many users am I getting week over week"
- Rule: Claude can read the site's visitors week by week (visits, new visits, unique browsers, sign-ups, requests, bookings) through the Admin connector, bots and staff left out.
- Done when: the visitor_weeks tool answers on production with the last 12 weeks.

### REQ-141 The plate is asked after the car is registered, not at the application
- Status: in progress
- Proof: supabase/migrations/5212_r51_plate_later.sql (app.plate_missing; the fleet route and the VIN list no longer refuse a car without a plate; To do plate_needed and the email owner_plate_needed once per car, only while onboarding or ready to list, to an owner with a login who is not a test owner, never on the application insert; ops_do vehicle_plate_set for the owner and staff; no publish or handover without a real plate, no override); web/src/features/owner/apply-schema.ts (plate optional), web/src/features/onboarding/steps.ts (Add the plate step), web/src/app/owner/vehicles/[id]/page.tsx (#plate form), web/src/features/vehicle-page/VehiclePage.tsx (Plate needed, Admin and staff); emails/src/emails/owner_plate_needed.mjs. Live once r50-hotfix2 deploys
- Test: supabase/tests/99_r51_plate_later.sql; web/src/features/vehicles/plate.test.ts; web/src/features/onboarding/steps.test.ts; web/src/features/owner/fleet-route.test.ts
- Asked: Nov 27 23:40
- Owner: "U ask owners for their plate when the plate gets registered after the owners apply. It's a broken process"
- Rule: the owner application never requires the plate (a car is often registered after the owner applies). A car without a real plate (empty or a placeholder such as XXXXXXXX) gets an "Add the plate" step for the owner (portal step, email first) and a To do for Fleet; the plate is required before the car is published or handed over, never at the application.
- Done when: an owner can apply with no plate; the owner portal and Fleet see the missing-plate step; a car with no real plate cannot be published or handed over and says why; adding the plate clears the step.

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
- Status: done
- Proof: merge 32e867b2 (r50-hotfix2-ux); supabase/migrations/5150_r50h2_admin_call.sql
- Test: supabase/tests/99_r50h2ux_admin_call.sql; web/src/features/admin-call/model.test.ts; web/tests/e2e/r50h2-ux.spec.ts
- Asked: Nov 26 18:26, 18:43, Nov 27 07:13
- Rule: Abbas and Mahad weekly call, auto deck with approve and deny buttons: shifts, hours and pay, academy, hiring, social, numbers, owners, deposits, insurance billing, claims, tolls, fleet.
- Done when: the deck builds each week with working buttons.

## 12. Owners and calculator

### REQ-072 Calculator realism
- Status: done
- Proof: merge 4df06de9 (r50-hotfix2-ops); supabase/migrations/5141_r50h2_owner_calc.sql; web/src/features/owner/EarningsCalculator.tsx
- Test: supabase/tests/99_r50h2_owner_calc.sql; web/src/features/owner/earnings.test.ts
- Asked: Nov 25 19:23
- Owner: "2015 RDX beats a 2025 CR-V"
- Rule: 80% occupancy about $1,200 a month, floor $800, higher for better cars; rough-estimate disclaimer.
- Done when: a 2015 RDX never beats a 2025 CR-V.

### REQ-073 Ownership documents
- Status: done
- Proof: merge 4df06de9 (r50-hotfix2-ops); supabase/migrations/5144_r50h2_ownership_documents.sql
- Test: supabase/tests/99_r50h2_ownership_documents.sql; web/tests/e2e/r50h2-ops-uploads.spec.ts
- Asked: Nov 26 01:53
- Rule: every ownership document uploaded; VIN and plate read and attached to the car and owner portal.
- Done when: an upload fills VIN and plate.

### REQ-074 Owner and renter rewards
- Status: done
- Proof: merge 32e867b2 (r50-hotfix2-ux); supabase/migrations/5151_r50h2_rewards_game.sql (renter, owner and staff Rewards pages)
- Test: supabase/tests/99_r50h2ux_rewards_game.sql; web/src/features/rewards/game-model.test.ts
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
- Proof: merge 52ff1ccb (r50-hotfix2-seo); web/src/features/seo (offers module); Done when needs the live site after the combined deploy (every SEO page)
- Test: web/src/features/seo/families-offers.test.ts
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
- Proof: merge 52ff1ccb (r50-hotfix2-seo); supabase/migrations/5160_r50h2_search_console.sql; Done when needs the live site after the combined deploy (an auto-fix with proof and a keyword report)
- Test: supabase/tests/99_r50h2_seo_hiring_traction.sql
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
- Status: done
- Proof: merge 52ff1ccb (r50-hotfix2-seo); web/src/app/rental-software/page.tsx (in no menu)
- Test: web/src/features/software/content.test.ts
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
- Status: done
- Proof: merge 32e867b2 (r50-hotfix2-ux); web/src/features/portal/PickupCountdown.tsx; web/src/features/portal/AddToCalendar.tsx; web/src/components/portal-ui/Milestones.tsx
- Test: web/tests/e2e/r50h2-ux.spec.ts; web/src/features/portal/booking-ics.test.ts
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
- Status: in progress
- Proof: merge 52ff1ccb (r50-hotfix2-seo); supabase/migrations/5162_r50h2_traction.sql (monthly active users and days rented on the deck and investor Home); "units" is not defined: confirm with the owner
- Test: supabase/tests/99_r50h2_seo_hiring_traction.sql; web/src/features/deck/traction.test.ts
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
- Proof: merge 38c7572a (r50-hotfix2-infra); scripts/deploy/cf-site.sh; Done when needs the live site after the combined deploy (certificate and /api/health)
- Test: scripts/deploy/cf-site.test.mjs
- Asked: Nov 20, Nov 25 20:13
- Owner: "server switch still not done, insane"
- Done when: api.carmacars.ca has a valid certificate and /api/health returns 200 on the new server.

### REQ-088 Build and deploy off the OVH server
- Status: in progress
- Proof: merge 38c7572a (r50-hotfix2-infra); .github/workflows/deploy-vps.yml; Done when needs the live site after the combined deploy (builds on GitHub runners)
- Test: GAP
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

### REQ-118 Amazon SES and the server switch
- Status: in progress
- Proof: branch r50-hotfix2-comms (5090 to 5092, not merged yet); branch r50-hotfix2-infra (server deploy)
- Test: GAP
- Asked: Nov 27 12:36
- Owner: "Setup amazon ses and the switch to the server ASAP"
- Rule: site emails send through Amazon SES, and carmacars.ca is served from the company server.
- Done when: site emails send through SES (SES account ca-central-1 is out of sandbox, 50,000 a day, 0 sent so far) and carmacars.ca is served from the company server.

### REQ-119 Insurer emails and phone stay as they are
- Status: done
- Proof: owner decision, Nov 27 12:36: the current insurer sender, invoice link and phone stay (closes the Blind Spot domain and phone question)
- Test: GAP (an owner decision, nothing to build)
- Asked: Nov 27 12:36
- Owner: "The insurer emails are correct. And the phone number is fine"
- Rule: keep the current insurer email sender, invoice link and phone number.
- Done when: no change is made to the insurer sender, invoice link or phone.

### REQ-120 Every CarmaCars change also goes into each Almash build
- Status: in progress
- Proof: none yet (no port since Nov 24)
- Test: GAP
- Asked: Nov 27 12:36
- Owner: "Has always been built on Almash builds as well"
- Rule: every CarmaCars change is also built into each Almash build.
- Done when: each Almash build carries the CarmaCars changes up to the current release.

### REQ-121 Uncertain e-Transfers go to the Rental Desk
- Status: done
- Proof: the Rental Desk page, section "E-Transfers to match": the 9 unmatched or uncertain e-Transfers (outside the repository)
- Test: GAP (a working document, not code)
- Asked: Nov 27 12:36
- Owner: "The e-transfers u don't know for sure what they correlate to should go to the rental desk doc"
- Rule: an e-Transfer that cannot be matched for sure to a booking is listed on the Rental Desk page, not guessed.
- Done when: every unmatched or uncertain e-Transfer is listed on the Rental Desk page under "E-Transfers to match".

### REQ-122 Turo trip emails read by the site
- Status: in progress
- Proof: none yet
- Test: GAP
- Asked: Nov 27 13:14
- Owner: "Turn on the Turo email thing but make sure it doesn't break anything"
- Rule: Turo trip emails forwarded from rent@ go to trips@in.carmacars.ca and the site reads them; the root carmacars.ca mail (Google Workspace) stays as it is.
- Done when: Turo trip emails forwarded from rent@ reach trips@in.carmacars.ca and are read by the site, root carmacars.ca mail (Google Workspace) unchanged.

### REQ-123 Database busy errors after the server switch
- Status: in progress
- Proof: merge of r50-hotfix2-dbbusy (f02c7aa2): web/scripts/vps-server.mjs serves a long-tail page from the copy this build kept (src/lib/edge/page-cache.ts keptCopyFresh), as the Worker's edge copy did
- Test: web/src/lib/edge/page-cache.test.ts
- Asked: Nov 27 12:36
- Owner: "I'm getting a bunch of error notifications from the site, fix it"; "Setup amazon ses and the switch to the server ASAP"
- Rule: the site on the company's server never floods the Admins with "the database is busy" errors; the long-tail pages crawlers read are not rendered again while a good copy is fresh.
- Done when: site_errors shows no "gave up: the database is busy" spike for 24 hours after the deploy, and the 15-minute error spike incident does not reopen.

### REQ-124 Email first, texts only where speed matters
- Status: not started
- Proof: none yet (follow-up release; not built in hotfix 2)
- Test: GAP
- Asked: Nov 27 13:24
- Owner: "Go by email and in general try to move people to the emails because it's cheaper than text"
- Rule: when Quo credits run out, held texts go by email (keep 5090's email fallback; this answers the REQ-045 question). Everywhere a message can go by email or text, email is the default; texts only where speed matters (codes, same-day pickup and return).
- Done when: the notification map defaults every event with both channels to email, with a short list of text-only events.

### REQ-125 3D model of every car (future idea)
- Status: not started
- Proof: none yet (a future idea: not for this release)
- Test: GAP
- Asked: Nov 27 15:05, 15:30
- Owner: "We should be able to have a 3d model of every car eventually because of all the check in and check out photos right"; "No just keep 3d models as a future idea to implement later"
- Rule: later, not now. Note: it needs a walk-around video at each check-in and check-out (8 to 12 photos are too few for photogrammetry or Gaussian splatting), and it runs on our own server.
- Done when: to be set when the owner schedules it (a future idea, no build yet).

### REQ-126 The installed app and every redirect stay on the public host
- Status: in progress
- Proof: see the commit that adds web/src/lib/http/public-origin.ts and the guard test in web/src/lib/http/local-redirect.test.ts
- Test: web/src/lib/http/local-redirect.test.ts
- Asked: Nov 27 15:55
- Owner: "When doing the app bookmark thing, it says localhost and stops working. Wtf fix that"
- Rule: behind Caddy and vps-server.mjs, req.url reads http://localhost:3000. Same-site redirects use localRedirect(path) (relative Location). An absolute address (OAuth redirect_uri, links) uses publicOrigin(req). No route builds a browser-facing address from req.url or u.origin.
- Done when: the installed app (Add to Home Screen) and every redirect on carmacars.ca stay on the public host; no response sends a browser to localhost.

### REQ-127 E-Transfer requests for renters who pay by e-Transfer
- Status: not started
- Proof: none yet (open, next release)
- Test: GAP
- Asked: Nov 27 15:55
- Owner: "Need to implement e-transfer requests when someone wants to pay via e-transfer"
- Rule: open, next release.
- Done when: a renter who chooses e-Transfer gets an email request with the exact amount, the e-Transfer address and the booking number as the message, the booking waits for that payment, and the received e-Transfer is matched to the booking automatically.

### REQ-128 Never accept an offer for the renter
- Status: not started
- Proof: none yet (open; a rule for staff and Claude)
- Test: GAP
- Asked: Nov 27 15:55
- Owner: "don't accept the offer for him"
- Rule: a rule for staff and Claude.
- Done when: Admin tools and Claude never use Book it now (accept an offer without the renter) unless the owner names that action for that booking.

### REQ-129 "Not available" never blocks a free car, and always says why
- Status: in progress
- Proof: migration 5195 (app.vehicle_blocker; every "not available" or "not free" refusal ends with "blocked by" the booking or calendar block; offer_revise takes vehicle_id); 5111 (an ended booking never blocks) ships with it. Cause of CC-10674: the live database (build 97e9b615) has 3810 but not 5111, so the Kia Forte stayed "presumed out" behind CC-10602 (confirmed, pickup never recorded, return Nov 26).
- Test: supabase/tests/99_r50h2_avail.sql
- Asked: Nov 27 15:43, 15:50, 16:51 (CC-10674)
- Owner: "Trying to put this booking through, but it says ... the car is not available. Force the booking."; "Make sure that stops happening, because whatever is causing that has happened before, and that has become a regular issue."; "Why the fuck is it marked cleaning it's already available and put that booking into the Kia forte. Do it for me. And make sure that doesn't happen again"
- Rule: a car is refused only for a real overlap (another booking that holds it, or a calendar block), never for a past trip left open. Every refusal names the exact booking (number, status, dates) or block (reason, source, dates). The connector moves an offer to another car with the checks of Admin > Edit the offer.
- Done when: production runs 5111 and 5195; an offer moves to a car whose last rental was never closed and is booked; a refused car names its blocker on every screen and in the connector.

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
