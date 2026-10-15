# Portal facts for the user guides

Facts for writing one PDF guide per portal. Button and link labels are copied from the code (`web/src/app/**`,
`web/src/features/**`) as of October 15, 2026; quote them exactly. Screens to illustrate each step are in
`docs/guides/screens/<portal>/` (see `manifest.json` there: portal, step, file, path, viewport, what the screen is
for). Screens were taken on the local stack (the same build as carmacars.ca) with sample data; every person shown is
fictional (`@example.com`).

## Everyone: signing in

| Fact | Detail |
| --- | --- |
| Sign-in page | https://carmacars.ca/sign-in (one page for every portal). Fields "Email" and "Password", button "Sign in". |
| Where you land | The page you asked for (`?next=`), otherwise your portal: Admin `/admin`, staff `/va`, field `/field`, investor `/investor`, owner `/owner`, renter `/account`. Someone with two or more portals lands on "Choose a portal" (one button each). |
| Other portals | Every portal's frame lists your other portals ("Your other portals"). |
| Wrong password or unknown email | "That email and password do not match an account." with "Invited by CarmaCars and never chose a password, or forgot it? Set a new password". |
| Email not confirmed | The form offers "Send the confirmation link again". |
| Too many tries | "Too many tries. Wait a minute, then try again." |
| Forgot the password | https://carmacars.ca/reset-password: "Email", "Send the link". The email "Reset your CarmaCars password" has "Choose a new password"; on the page: "New password" (8 characters or more), "Save the new password". |
| Email links last one hour | Invitation, confirmation and reset links work for one hour, once. An expired or used link opens "Link expired" with "Send me a new link" (one step, the address is filled in). |
| Two-step sign-in | Offered to staff, field staff and investors from their profile ("Set up two-step sign-in"; page `/two-step/setup`: "Set up an authenticator app", scan the code, type the 6 digits, "Continue"). Required for staff only when an Admin switches on `require_staff_two_step` (off today). After that, every sign-in asks for the 6-digit code. |
| Signing out | "Sign out" in the portal header. It signs out this device only. |
| A page shows "Error 1102" | Cloudflare's free plan stopped the page for using too much processing time. Reload the page; you are still signed in. (Goes away with the Workers Paid plan.) |
| A page says you have no access | It names the account you are signed in with and lists its portals, with "Sign out" (sign in with the right account). |

## Public site (no account)

| Fact | Detail |
| --- | --- |
| Address | https://carmacars.ca |
| Main menu | "Fleet", "How it works", "Delivery", "Requirements", "List your car", "FAQ"; "Your portal"; "Find a car". |

**Request to book (never instant):**

1. "Find a car", pick a car, choose dates on its page, "Request to book".
2. Step 1 (trip): pickup and return times, where to get and return the car ("Deliver it to an address" or our location), additional drivers and baby seats, the price. "Continue to driver details".
3. Step 2: first and last name, email, phone, date of birth. "Continue to licence".
4. Step 3: licence (for example "Ontario G2") and how the car is covered (Option 1, 2 ...). "Review request".
5. Step 4: check everything, tick the agreement, "Send request". Nothing is charged.
6. The confirmation page shows the request number (CC-...). CarmaCars replies with an offer by email and in the renter portal.

## Renter portal (`/account`)

| Fact | Detail |
| --- | --- |
| Sign-in URL | https://carmacars.ca/sign-in (lands on `/account`) |
| Who gets an account | Anyone, by themselves: https://carmacars.ca/create-account ("Full name", "Email", "Password", "Create account"), then the confirmation email "Confirm your CarmaCars account". A request sent while signed out also makes the account; earlier requests with the same email are attached once the address is confirmed ("We found earlier requests made with your email"). |

Navigation:

| Item | What it does |
| --- | --- |
| Trips | The next step for your nearest booking first (for example "Review offer"), then current, upcoming and past trips. Opening a trip shows status, progress, pickup details, drivers, documents, price and payments and the actions. |
| Documents | Agreements, receipts, statements and uploads: "View", "Download". |
| Notifications | Notices from CarmaCars: "Mark as read", "Mark all as read"; which optional emails you get. |
| Profile | Contact details ("Save"), drivers, the Card on File, marketing choice. |

Main tasks:

1. **Approve an offer.** Trips > "Review offer". Read the price, what changed and the time left ("This offer does not hold the car."). "Approve and continue". Or "Ask for a change" (write what, "Send request") or "Decline offer" ("Decline this offer").
2. **Sign the agreement.** Fill your address and licence, "Save details". Read the agreement (also as a PDF), tick the consents, sign in the box with a finger or the mouse ("Clear" to redo) or "Type my name instead". "Sign and continue to payment".
3. **Pay.** "Name on the card" and the card details, "Pay $...". The card is authorized now and charged once the booking is confirmed; it becomes the Card on File for the deposit at pickup. If someone else confirmed the car first: "This car was just taken" (the authorization is released).
4. **Upload documents before pickup.** The booking > "Licence and coverage" (or "Upload documents"): licence front and back, a selfie ("Take photo"), proof of coverage ("Upload proof").
5. **Extend.** The booking > "Extend": new return date and time, "See the price", "Request extension"; once approved, "Pay for the extension" before the current return time.
6. **Change dates.** "Ask to change dates": new pickup and return, "See the difference", send. A change CarmaCars proposes shows "We suggest a change to your booking": "Review and answer", then "Accept and sign the amendment" (sign, "Accept and sign") or "Decline this change". If more is owed: "Pay and apply the change".
7. **Cancel.** "Cancel booking": the refund by the cancellation table is shown; type to confirm, "Cancel booking".
8. **Additional driver's link.** On the booking: "Copy their signing link" or "Send a new link" (links expire after 72 hours; a new link ends the older one).
9. **Review after the trip.** "Review your rental": stars, "Title (optional)", "Your review (optional)", "Show my review on the site with my first name", "Send my review".

## Owner portal (`/owner`)

| Fact | Detail |
| --- | --- |
| Sign-in URL | https://carmacars.ca/sign-in?next=/owner |
| Who gets an account | Owners apply themselves: https://carmacars.ca/list-your-car > "Apply to list your car" (the account is made at the end of the application). An Admin can also invite an owner on file (Admin > Owners "Invite an owner", or Admin > Portals "Invite"). |

Applying: "About you" (individual or corporation, address, licence and date of birth), "Continue to vehicles"; per car the VIN and "Look up", "Add another vehicle"; how it will work; "Continue"; "Review"; "Submit application" ("Email me a link" saves a resume link). Then "Go to your owner portal".

Navigation:

| Item | What it does |
| --- | --- |
| Home | The next thing to do (sign, pay, upload), your cars with their next action, money this month, the next debit date. |
| Vehicles | Each car: status, fees and terms, the onboarding checklist, uploads (ownership permit, lender permission, insurance), listing photos, bookings, invoices, "Leaving" (exit notice). "Add a vehicle". |
| Bookings | Two months of your cars on a calendar and every booking; "Book my own car". |
| Invoices | Fee invoices: due, processing, paid, failed; each with "Pay $...". |
| Statements | One a month once approved by CarmaCars: every booking, revenue share, deductions, payout; "Download PDF". |
| Payouts | What was paid to you and when. |
| Documents | Signed agreements, uploads, government forms ("Data sheet", "Pre-filled PDF" or "Official form, filled for you"), and "Forms to sign with witnesses" (Forms C and D). |
| Banking | "Automatic debit of your fees" (the account and the next debit), "Where we pay you", "Saved payment methods". |
| Notifications | Messages and notices from CarmaCars. |
| Profile | Contact details, password. |

Main tasks:

1. **Sign the agreements.** Home > "Read and sign". Read, tick the three initialled confirmations, draw or type ("Type my name instead") your signature, "Sign all 2" (or "Sign").
2. **Set up the monthly debit.** Banking > "Set up pre-authorized debit" > "Continue to my bank details" > bank details > "Save the bank account". Fees are debited on the debit day (the 15th) after a notice 10 days before; each invoice says "will be debited on".
3. **Pay an invoice now.** Invoices > the invoice > "Pay $..." (card) or "Authorize debit of $..." (pre-authorized debit).
4. **Payout details.** Banking > Where we pay you: "Account holder", "Institution number", "Transit number", "Account number" (or "e-Transfer email"), "Submit payout details". CarmaCars verifies them before the first payout.
5. **Forms C and D.** Documents > Forms to sign with witnesses: "Download the pre-filled form", print, sign with the witnesses, fill the witnesses' names ("First witness", "Witness"), "Upload the signed form". CarmaCars approves it or sends it back with what to fix (by email and on the page).
6. **Official government forms.** Documents > a form marked "Official form, filled for you": "Download the filled form", or "Sign on screen" then "Sign and save".
7. **Book your own car.** Bookings > "Book my own car" (or the vehicle's "Book it for myself"): pickup, return, "Note (optional)", "Book my car".
8. **Listing photos.** The vehicle > "Add listing photos" (or "Take new photos"): "Take photo" for each shot, "Retake" if needed, "Submit for listing".
9. **Leave the program.** The vehicle > Leaving > "Give notice": "Reason (optional)", "Give exit notice".

## Investor portal (`/investor`)

| Fact | Detail |
| --- | --- |
| Sign-in URL | https://carmacars.ca/sign-in?next=/investor (the site footer's "Investor sign in") |
| Who gets an account | Invitation only: an Admin invites the investor on file (Admin > Investors, or Admin > Portals > "Invite" with "Investor on file"). |

| Item | What it does |
| --- | --- |
| Investments | Each investment, its returns ("Paid monthly" or "Reinvested") and what was paid. |
| Statements | One per month; open one for the figures and "Download PDF". |
| Profile and notices | Contact details, notices to CarmaCars, "Set up two-step sign-in" (offered, not required). |

## Admin portal (`/admin`)

| Fact | Detail |
| --- | --- |
| Sign-in URL | https://carmacars.ca/sign-in?next=/admin |
| Who gets an account | Invitation only, by another Admin (Admin > Portals > "Invite", Role "Admin"). The owner's account is `rent@carmacars.ca`: first time, use https://carmacars.ca/reset-password, "Send the link", open "Reset your CarmaCars password", "Choose a new password", "Save the new password". |
| Keyboard | "g" then a letter: t Today, r Requests, b Bookings, c Calendar, k Tasks, v Vehicles, l Listings, m Money, o Tolls, s Settings; "/" focuses the page's search. |

Navigation (the left rail; on a phone one scrolling strip):

| Group | Item | What it does |
| --- | --- | --- |
| Operate | Today | Alerts (site setup, failed scheduled jobs, email use), requests waiting, pickups and returns, late returns, payments failed, deposits due, approvals waiting, email sent today. |
| | Requests | Every request to book, offers out, waiting for signature or payment, expired offers. |
| | Bookings | All bookings; a booking has tabs Overview, Review, Money, Documents, Changes, History. |
| | Calendar | The master calendar: Timeline, Agenda, Vehicles by day; "Today", "Week", "2 weeks", "Month". |
| | Tasks | Every queue's tasks. |
| Fleet | Vehicles | The fleet; a car has tabs Overview, Calendar, Rates, Fees, Listing, Records. |
| | Listings | The listing pipeline: drafts to review, published. "Start a listing". |
| | Similar cars | Possible duplicate listings: "Not a duplicate" or "Same car". |
| | Bulk rates | Change rates of many cars at once ("Preview"). |
| Money | Payments and refunds | Payments, refunds to approve, deposits. |
| | Insurer invoices | Invoices to insurers for insurer-billed bookings. |
| | Owner invoices | Fee invoices: "Run the monthly invoices", "Issue all tracker invoices"; record an offline payment ("Mark paid"). |
| | Owner debits | The debit policy, next notice and debit days, scheduled and processing debits, owners and mandates ("Pause", "Resume", "Send a notice now"), results, the run log, notices. |
| | Owner statements | "Build all for a month", "Build one"; a statement: "Rebuild", "Preview PDF", "Approve", "Issue to the owner", "Reissue", "CSV". |
| | Payouts | Payouts to approve and record. |
| | Company statements | CarmaCars' monthly statement, twelve sections; PDF, PDF by owner, PDF by vehicle; "Email me the PDFs". |
| | Expenses, Reconciliation | Company expenses; processor payouts matched to payments. |
| Recover | Tolls and tickets | The work queue; "Read a notice", "Log one", "Import a CSV", "Bulk confirm high-confidence"; reading profiles. |
| | Damage, Incidents and claims | Damage after a rental; incidents and the claim ledger. |
| People | Portals and sign-in | Every portal with "Its sign-in page" and "Open as this person"; "Invite a person"; everyone who can sign in, with "Send password link" and "View as (...)". |
| | Staff | Invite staff, functions, limits, "End access", "Restore". |
| | Owners | Applications and owners; "Invite an owner". |
| | Owner forms | Forms C and D uploaded by owners: "Approve" or "Send back". |
| | Investors | Investors and their sign-in. |
| | Reviews | Renter reviews to publish (only with the renter's consent). |
| | Email | The outbox (filter All, Queued, Held, Sent, Failed, Suppressed, Skipped), today's use against the daily limit, "Resend", "Cancel"; Suppressions ("Suppress an address", "Lift"). |
| | Audit log | Who changed what, including every View as. |
| Setup | Settings | Site settings, Site content, Program settings, Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Coverage prices, Forms, Email aliases and reply-to, Staff and roles, Insurers, Promo codes, Quick replies. |

Main tasks:

1. **Answer a request.** Requests > the booking > Review tab: "Adjust the booking" (car, dates, places, price, extras), "Save changes", then "Send the offer" (or "Save and send the offer"); the panel "The offer as the renter sees it" shows the result. To refuse: "Decline" with "Reason and any alternative". Other actions on the booking: "Ask the renter" (a question), "Withdraw to edit", "Send again, later expiry", "Renter approved by phone".
2. **Change a confirmed booking.** The booking > Changes tab: new pickup, return, car or rental charge and a reason, "Preview the price", "Send to the renter". The renter has 48 hours to accept (and sign the amendment) or decline.
3. **Calendar.** Calendar: drag a booking to move it, then "Confirm the move"; double-click a car's row where the block starts, then "Create the block"; open a block and "Remove the block". A car's own calendar: Vehicles > the car > Calendar (its turnaround time is set there).
4. **Publish a listing.** Listings > the draft: check the copy and photos; for each public photo "Cover the plate" (the editor suggests a box; "Suggest the plate" asks again; drag to draw more boxes; choose "Cover the plate with" cover, pixelate or blur; "Save the covered photo") or "No plate visible on this photo". Then "Approve and publish", "Approve, publish later" or "Send back".
5. **New owner.** Owners > the application > "Approve and set terms" (or "Set terms (standard grid)"); the owner signs and pays the upfront invoice in their portal. An offline payment: "Mark paid" with "Reference", "Date received", "Amount ($)".
6. **Monthly owner money.** Owner statements > "Build all for a month" > open each > "Approve" > "Issue to the owner"; Payouts. Owner debits run by themselves; watch Owner debits for returned debits and owners without a mandate.
7. **Tolls.** Tolls and tickets > "Read a notice": upload the PDF, photo or CSV, "Read it"; check each line beside the notice ("Checked against the notice", "Leave out", "Put it back", "Save as checked"), then "Confirm and import". A single toll: "Log one" > "Save and match". In a toll: "Charge the renter", "Bill to the owner", "CarmaCars pays", "Dispute".
8. **Forms C and D.** Owner forms > open the scan > "Approve", or "Send back" with "What to fix (the owner reads this)".
9. **Official ServiceOntario PDFs.** Settings > Forms: upload the fillable PDF, choose what goes in each field, "Download a filled preview", then "Checked: use for owners".
10. **Let someone in.** Portals and sign-in > Invite a person: "Name", "Email", "Role" (Admin, Staff (assistant) with "Main function" and "Also covers", Field staff with "Field function", Owner on file, Investor on file), "Invite". They get the invitation email (one hour). Someone who forgot: "Send password link".
11. **See what someone sees.** Portals and sign-in > a portal > choose the person > "Open as this person" (or "View as (...)" on their row). A red banner says "Viewing as Name (email), read only." with "Exit". Nothing can be changed; it ends after 30 minutes; every view is in the audit log.
12. **End a staff member's access.** Settings > Staff > "End access" (their staff portal closes at once); "Restore" to undo.

## Staff portal (`/va`), one per function

| Fact | Detail |
| --- | --- |
| Sign-in URL | https://carmacars.ca/sign-in?next=/va |
| Who gets an account | Invitation only, by an Admin (Admin > Portals or Staff > "Invite", Role "Staff (assistant)", "Main function", optionally "Also covers"). |
| Several functions | "Working as" at the top of the rail switches function (Customer service, Finance, Fleet, Sales). |

Every function starts with **Queue** (the function's tasks, oldest due first: "Take it"; a task: "Done", "Waiting", "Escalate", "Hand over", "Add a note", "Open the working screen") and **Today** (pickups, returns and what is due). Then:

| Function | Navigation (after Queue and Today) |
| --- | --- |
| Customer service | Requests; New quote; Renter messages; Find a renter; Calendar; Listings; Similar cars; Owners and enquiries; Owner forms; Scorecard |
| Finance | Payments, deposits, refunds; Tolls and tickets (with "Read a notice" and reading profiles); Reconciliation; Turo trips; Find a renter; Calendar; Scorecard |
| Fleet | Field jobs; Daily checks; Photo reviews; Calendar; Listings; Similar cars; Find a renter; Scorecard |
| Sales | Requests and offers; New quote; Owner leads; Calendar; Scorecard |

Main tasks:

- **Customer service, answer a request:** Requests > the booking > Review tab, as an Admin does ("Adjust the booking", "Save changes", "Send the offer"); "Approve (within my limit)"; "Approve and send the pay link". New quote for a caller: fill the trip and the renter, "Create the request". Renter messages: reply, "Send". Find a renter: search, "Open with a reason" (the reason is kept in the access log). Owner forms: "Approve" or "Send back".
- **Finance:** Payments, deposits, refunds: "Request the refund" (above your limit it goes to an Admin), "Issue the refund". Tolls as the Admin does (Read a notice, Confirm and import, "Match again", "Dispute"). Reconciliation: "Record a processor payout", "Match". Turo trips: "Add a trip" or "Import".
- **Fleet:** Field jobs: "Schedule" (kind, car, when, place, field staff, instructions), "Assign", "Reassign", "Move", "Cancel". Daily checks: "Opening check", "Closing check". Photo reviews after a return: "Review done" or "Ask for a re-shoot". Similar cars: "Not a duplicate" or "Same car". Listings: review and the plate editor as an Admin does.
- **Sales:** Owner leads: "Take it", "Update" (status and the reason when closed). Requests and offers, New quote as customer service.
- **Late return panel** (on a late booking): "Log a call", "Send T13", "Send T14 (final notice)", "Request disable", "Open an incident".

## Field portal (`/field`)

| Fact | Detail |
| --- | --- |
| Sign-in URL | https://carmacars.ca/sign-in?next=/field |
| Who gets an account | Invitation only, by an Admin (Role "Field staff", "Field function": Driver, Detailer, or Driver and detailer). |
| On the phone | Phone first. In the browser's menu, "Add to Home Screen" opens it full screen like an app. It needs a connection: photos and signatures are saved as they are taken. |

| Item | What it does |
| --- | --- |
| My jobs | Today's jobs in order (handovers, returns, deliveries, moves, photo shoots); each card shows the kind, time, car, plate, place ("Open in maps"). "Start a move" / "End the move" for car moves. |
| Report | Report an incident, damage, a breakdown or a ticket, with photos ("Take a photo", "Send the report"). |
| Referrals | Your referral link ("Copy the link") and its QR code. |
| Profile | "Save my phone", "Set up two-step sign-in", "Change my password", "Sign out". |

**A handover:** the job > "Acknowledge" > "Start". The ready check lists what must be done first (signed, paid, ID checked, deposit); if something fails, "Stop: do not release the car". Then each step with "Next" and "Back": Car ready ("Yes"/"No"), Is this the renter?, Original licence, Card on File, Odometer, Fuel or charge, Keys ("+" and "−"), Photo set (19 photos in order, "Take", "Retake"; the count shows "19 of 19 photos taken · all uploaded"), Damage (tap the car diagram, "Add the damage"), Tracker, Renter reviews, Signatures (the renter signs, then you), and "Hand over the keys". Done: "Handed over. The rental has started."

**A return:** Car and keys received, Odometer, Fuel or charge, Keys and extras, Cleanliness, Photo set, Compare with pickup (new damage: tap the diagram, "Where", "What it is", "Add the damage", a close-up photo), Belongings, Renter reviews and signs, You sign and complete: "Complete the return".

**A photo shoot:** the job > "Start the listing photos": "Take photo" for each shot in the list, "Retake" or "Send again" if one failed, the progress bar of required photos, "Submit for listing".

## Common problems (all portals)

| Problem | What to do |
| --- | --- |
| The invitation or reset link says it expired | Links work for one hour, once. Press "Send me a new link" on that page, or ask an Admin for "Send password link". |
| "That email and password do not match an account." | Check the address; if you were invited and never chose a password, use "Set a new password" on the sign-in page. |
| No confirmation email | Check spam; on the sign-in form use "Send the confirmation link again". |
| Asked for a 6-digit code | Open your authenticator app (two-step sign-in). Lost the phone: there is no reset button in Admin yet; the owner removes the factor in the Supabase dashboard (Authentication > Users > the person). |
| "Error 1102" from Cloudflare | Reload the page. |
| "You are signed in as ..." with no access | You are in the wrong account for this portal: "Sign out", then sign in with the right one, or choose the portal under "Your other portals". |
| An Admin cannot change anything | They are viewing as someone (red banner): press "Exit". |
